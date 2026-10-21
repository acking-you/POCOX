//! Bounded non-blocking admission to one disk writer, with timed flushes.
use std::{
    fs::{self, File, OpenOptions},
    io::{self, BufWriter, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc, Arc,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use super::{clock, date_stamp, LogLine};

pub(super) const FILE_RETENTION: Duration = Duration::from_secs(6 * 60 * 60);
const FLUSH_INTERVAL: Duration = Duration::from_millis(200);
const MAINTENANCE_INTERVAL: Duration = Duration::from_secs(60);
const QUEUE_BYTES: usize = 4 << 20;
const FILE_BYTES: u64 = 16 << 20;
const DIRECTORY_BYTES: u64 = 64 << 20;

enum Entry {
    Line(LogLine),
    Flush(mpsc::SyncSender<bool>),
}

#[derive(Default)]
struct Counters {
    queued: AtomicUsize,
    dropped: AtomicUsize,
    errors: AtomicUsize,
}

pub(super) struct DiskLog {
    tx: mpsc::SyncSender<Entry>,
    counters: Arc<Counters>,
}

impl DiskLog {
    pub(super) fn start(dir: PathBuf) -> io::Result<Self> {
        let (tx, rx) = mpsc::sync_channel(256);
        let counters = Arc::new(Counters::default());
        let worker = counters.clone();
        std::thread::Builder::new()
            .name("pcx-log-writer".into())
            .spawn(move || {
                let mut log = RotatingFile::new(dir);
                let mut last_flush = std::time::Instant::now();
                loop {
                    match rx.recv_timeout(FLUSH_INTERVAL) {
                        Ok(Entry::Line(line)) => {
                            worker.queued.fetch_sub(line.weight(), Ordering::Relaxed);
                            if log.write(&line, SystemTime::now()).is_err() {
                                worker.errors.fetch_add(1, Ordering::Relaxed);
                            }
                        },
                        Ok(Entry::Flush(done)) => {
                            let flushed = log.flush().is_ok();
                            if !flushed {
                                worker.errors.fetch_add(1, Ordering::Relaxed);
                            }
                            let _ = done.send(flushed);
                        },
                        Err(mpsc::RecvTimeoutError::Timeout) => log.maintain(SystemTime::now()),
                        Err(mpsc::RecvTimeoutError::Disconnected) => {
                            let _ = log.flush();
                            break;
                        },
                    }
                    // A busy queue must not postpone flushes indefinitely.
                    if last_flush.elapsed() >= FLUSH_INTERVAL {
                        if log.flush().is_err() {
                            worker.errors.fetch_add(1, Ordering::Relaxed);
                        }
                        last_flush = std::time::Instant::now();
                    }
                }
            })?;
        Ok(Self {
            tx,
            counters,
        })
    }

    pub(super) fn push(&self, line: LogLine) {
        let weight = line.weight();
        let reserved =
            self.counters
                .queued
                .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |used| {
                    used.checked_add(weight).filter(|next| *next <= QUEUE_BYTES)
                });
        if reserved.is_err() {
            self.counters.dropped.fetch_add(1, Ordering::Relaxed);
        } else if self.tx.try_send(Entry::Line(line)).is_err() {
            self.counters.queued.fetch_sub(weight, Ordering::Relaxed);
            self.counters.dropped.fetch_add(1, Ordering::Relaxed);
        }
    }

    pub(super) fn flush(&self) -> bool {
        let (tx, rx) = mpsc::sync_channel(1);
        // A full queue must not skip the shutdown barrier. Its admission and
        // acknowledgement share one bounded deadline, even on a stuck disk.
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        let mut entry = Entry::Flush(tx);
        loop {
            match self.tx.try_send(entry) {
                Ok(()) => break,
                Err(mpsc::TrySendError::Full(returned)) if std::time::Instant::now() < deadline => {
                    entry = returned;
                    std::thread::sleep(Duration::from_millis(5));
                },
                Err(_) => return false,
            }
        }
        rx.recv_timeout(deadline.saturating_duration_since(std::time::Instant::now()))
            .unwrap_or(false)
    }

    pub(super) fn lost(&self) -> usize {
        self.counters.dropped.load(Ordering::Relaxed) + self.counters.errors.load(Ordering::Relaxed)
    }
}

pub(super) struct RotatingFile {
    dir: PathBuf,
    hour: Option<u64>,
    part: u32,
    size: u64,
    pub(super) file: Option<BufWriter<File>>,
    path: Option<PathBuf>,
    last_prune: Option<SystemTime>,
}

impl RotatingFile {
    pub(super) fn new(dir: PathBuf) -> Self {
        Self {
            dir,
            hour: None,
            part: 0,
            size: 0,
            file: None,
            path: None,
            last_prune: None,
        }
    }

    pub(super) fn maintain(&mut self, now: SystemTime) {
        let hour = now.duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() / 3600;
        if self.hour != Some(hour) {
            let _ = self.flush();
            self.file = None;
            self.path = None;
            self.hour = Some(hour);
            self.part = 0;
        }
        if self
            .last_prune
            .and_then(|last| now.duration_since(last).ok())
            .is_none_or(|elapsed| elapsed >= MAINTENANCE_INTERVAL)
        {
            prune(&self.dir, self.path.as_deref(), now);
            self.last_prune = Some(now);
        }
    }

    pub(super) fn flush(&mut self) -> io::Result<()> {
        if let Some(file) = &mut self.file {
            file.flush()?;
        }
        Ok(())
    }

    pub(super) fn write(&mut self, line: &LogLine, now: SystemTime) -> io::Result<()> {
        self.maintain(now);
        let text = format!(
            "{} {:5} {} {}\n",
            clock(line.timestamp_ms),
            line.level,
            line.target,
            line.message
        );
        if self.file.is_some() && self.size + text.len() as u64 > FILE_BYTES {
            self.flush()?;
            self.file = None;
            self.part += 1;
        }
        while self.file.is_none() {
            fs::create_dir_all(&self.dir)?;
            let hour = self.hour.unwrap_or(0);
            let path = self.dir.join(format!(
                "pocox-{}-{:02}-{:04}.log",
                date_stamp(hour * 3600),
                hour % 24,
                self.part
            ));
            let file = OpenOptions::new().create(true).append(true).open(&path)?;
            self.size = file.metadata()?.len();
            if self.size + text.len() as u64 > FILE_BYTES {
                self.part += 1;
                continue;
            }
            self.file = Some(BufWriter::new(file));
            self.path = Some(path);
            // Reserve a whole current file so the directory stays bounded
            // between maintenance ticks, including during a log storm.
            prune(&self.dir, self.path.as_deref(), now);
        }
        if let Some(file) = &mut self.file {
            file.write_all(text.as_bytes())?;
        }
        self.size += text.len() as u64;
        Ok(())
    }
}

fn prune(dir: &Path, active: Option<&Path>, now: SystemTime) {
    let Ok(entries) = fs::read_dir(dir) else { return };
    let mut retained = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.starts_with("pocox-") || !name.ends_with(".log") {
            continue;
        }
        let path = entry.path();
        if active == Some(path.as_path()) {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        if !meta.is_file() {
            continue;
        }
        let modified = meta.modified().unwrap_or(UNIX_EPOCH);
        if now
            .duration_since(modified)
            .is_ok_and(|age| age > FILE_RETENTION)
        {
            let _ = fs::remove_file(&path);
        } else {
            retained.push((modified, path, meta.len()));
        }
    }
    retained.sort_by_key(|entry| entry.0);
    let mut total = retained.iter().map(|entry| entry.2).sum::<u64>() + FILE_BYTES;
    for (_, path, size) in retained {
        if total <= DIRECTORY_BYTES {
            break;
        }
        if fs::remove_file(path).is_ok() {
            total = total.saturating_sub(size);
        }
    }
}
