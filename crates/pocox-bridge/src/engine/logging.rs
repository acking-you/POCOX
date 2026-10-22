//! In-process log capture for the UI's real-time log viewer.
//!
//! Installs a `tracing` layer as the process-global subscriber. Every event is
//! formatted into a [`LogLine`] and retained in a bounded native ring. The
//! viewer queries filtered snapshots after coalesced revision notifications.
mod disk;

use std::{
    collections::VecDeque,
    path::Path,
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};

use disk::DiskLog;
use once_cell::sync::OnceCell;
use tracing::{Event, Level, Subscriber};
use tracing_subscriber::{layer::Context, prelude::*, registry::LookupSpan, EnvFilter, Layer};

/// One captured log event, mirrored to Dart as `LogLineDto`.
#[derive(Clone, Debug)]
pub struct LogLine {
    /// `TRACE` / `DEBUG` / `INFO` / `WARN` / `ERROR`.
    pub level: String,
    /// Event target (crate / module path).
    pub target: String,
    /// The rendered message (plus any structured fields).
    pub message: String,
    /// Capture time, unix milliseconds.
    pub timestamp_ms: i64,
}

/// How many recent lines to retain for late-opening viewers.
const RING_CAPACITY: usize = 2000;
const RING_BYTES: usize = 2 << 20;
const MESSAGE_BYTES: usize = 16 << 10;

static RING: OnceCell<Mutex<LogBuffer>> = OnceCell::new();
static REVISION: OnceCell<tokio::sync::watch::Sender<u64>> = OnceCell::new();
static FILE: OnceCell<DiskLog> = OnceCell::new();

#[derive(Default)]
struct LogBuffer {
    lines: VecDeque<LogLine>,
    bytes: usize,
    revision: u64,
}

impl LogLine {
    fn weight(&self) -> usize {
        self.level.capacity()
            + self.target.capacity()
            + self.message.capacity()
            + std::mem::size_of::<Self>()
    }
}

impl LogBuffer {
    fn push(&mut self, line: LogLine) {
        self.bytes += line.weight();
        self.lines.push_back(line);
        while self.lines.len() > RING_CAPACITY || self.bytes > RING_BYTES {
            if let Some(old) = self.lines.pop_front() {
                self.bytes -= old.weight();
            }
        }
        self.revision = self.revision.wrapping_add(1);
    }
}

fn truncate(text: &mut String, limit: usize) {
    if text.len() <= limit {
        if text.capacity() > limit + 32 {
            text.shrink_to_fit();
        }
        return;
    }
    let mut end = limit;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text.truncate(end);
    text.push_str("…[truncated]");
    text.shrink_to_fit();
}

/// One bounded, filtered view of the native log buffer.
pub struct LogView {
    /// Matched lines, oldest first.
    pub lines: Vec<LogLine>,
    /// All retained lines before filtering.
    pub total: usize,
    /// Dropped disk records plus disk write/flush failures.
    pub disk_lost: usize,
}

/// Query the native ring, copying only the lines that match.
pub fn query(level: Option<&str>, keyword: &str) -> LogView {
    let minimum = level.and_then(priority);
    let keyword = keyword.trim().to_lowercase();
    let matches = |line: &&LogLine| {
        minimum
            .zip(priority(&line.level))
            .is_none_or(|(min, current)| current >= min)
            && (keyword.is_empty()
                || format!("{} {} {}", line.level, line.target, line.message)
                    .to_lowercase()
                    .contains(&keyword))
    };
    let (total, lines) = RING.get().map_or((0, Vec::new()), |ring| {
        let ring = ring.lock().unwrap_or_else(|e| e.into_inner());
        (ring.lines.len(), ring.lines.iter().filter(matches).cloned().collect())
    });
    LogView {
        lines,
        total,
        disk_lost: FILE.get().map_or(0, DiskLog::lost),
    }
}

fn priority(level: &str) -> Option<u8> {
    match level.trim().to_ascii_uppercase().as_str() {
        "TRACE" => Some(0),
        "DEBUG" => Some(1),
        "INFO" => Some(2),
        "WARN" => Some(3),
        "ERROR" => Some(4),
        _ => None,
    }
}

/// Observe only revision changes; slow viewers always see the latest value.
pub fn changes() -> Option<tokio::sync::watch::Receiver<u64>> {
    REVISION.get().map(tokio::sync::watch::Sender::subscribe)
}

/// Clear retained UI history; persisted diagnostic files are left intact.
pub fn clear() {
    if let Some(ring) = RING.get() {
        let mut ring = ring.lock().unwrap_or_else(|e| e.into_inner());
        ring.lines.clear();
        ring.bytes = 0;
        ring.revision = ring.revision.wrapping_add(1);
        if let Some(revision) = REVISION.get() {
            revision.send_replace(ring.revision);
        }
    }
}

/// Record controller diagnostics in the same bounded ring and disk sink.
pub fn record(level: String, target: String, message: String) {
    emit(LogLine {
        level,
        target,
        message,
        timestamp_ms: now_ms(),
    });
}

/// Flush admitted disk records, bounded to two seconds on shutdown.
pub fn flush() -> bool {
    FILE.get().is_none_or(DiskLog::flush)
}

/// Install the capture layer as the global subscriber. Idempotent — safe to
/// call once at boot; a second call (or codex's own `try_init`) is a no-op.
pub fn init() {
    RING.get_or_init(|| Mutex::new(LogBuffer::default()));
    REVISION.get_or_init(|| tokio::sync::watch::channel(0).0);
    // Honour RUST_LOG when set, else a useful default: everything at info, our
    // own bridge at debug. The viewer queries native filtering only while open.
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info,pocox_bridge=debug"));
    let _ = tracing_subscriber::registry()
        .with(filter)
        .with(CaptureLayer)
        .try_init();
}

/// Feed a log line from an EXTERNAL source into the same stream — used to tail
/// a spawned (外接) codex process's own log file, so the viewer shows its logs
/// into the same viewer as POCOX logs. The level is a best-effort
/// parse of the raw line (for coloring); the raw line itself is the message.
pub fn push_external(target: &str, raw: &str) {
    emit(LogLine {
        level: parse_level(raw).to_string(),
        target: target.to_string(),
        message: raw.to_string(),
        timestamp_ms: now_ms(),
    });
}

/// Best-effort level from a formatted log line (codex writes `<ts> LEVEL
/// target: msg`), scanning the first few tokens so a later "error" in the
/// message body doesn't mis-color the line.
fn parse_level(raw: &str) -> &'static str {
    for tok in raw.split_whitespace().take(4) {
        match tok
            .trim_matches(|c: char| !c.is_ascii_alphabetic())
            .to_ascii_uppercase()
            .as_str()
        {
            "ERROR" => return "ERROR",
            "WARN" | "WARNING" => return "WARN",
            "INFO" => return "INFO",
            "DEBUG" => return "DEBUG",
            "TRACE" => return "TRACE",
            _ => {},
        }
    }
    "INFO"
}

/// Write hourly logs under `<dir>/logs/` and prune inactive files after six
/// hours. Maintenance runs every minute, including while the app is idle in the
/// tray.
///
/// Separate from [`init`] because the support directory isn't known that early.
/// Failure is silent: the in-memory viewer is the primary sink, and losing the
/// file copy must not stop the app from starting.
pub fn init_file(support_dir: &Path) {
    let dir = support_dir.join("logs");
    let _ = FILE.get_or_try_init(|| DiskLog::start(dir));
}

/// `YYYY-MM-DD` in UTC, for the log file name.
fn date_stamp(secs: u64) -> String {
    let days = secs / 86_400;
    // Civil-from-days (Howard Hinnant's algorithm), so no date dependency here.
    let z = days as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}")
}

/// Milliseconds since the unix epoch rendered as `HH:MM:SS.mmm` UTC.
fn clock(timestamp_ms: i64) -> String {
    let total_ms = timestamp_ms.rem_euclid(86_400_000);
    let ms = total_ms % 1000;
    let secs = total_ms / 1000;
    format!("{:02}:{:02}:{:02}.{ms:03}", secs / 3600, (secs % 3600) / 60, secs % 60)
}

fn emit(mut line: LogLine) {
    truncate(&mut line.level, 16);
    truncate(&mut line.target, 256);
    truncate(&mut line.message, MESSAGE_BYTES);
    if let Some(file) = FILE.get() {
        file.push(line.clone());
    }
    if let Some(ring) = RING.get() {
        let mut ring = ring.lock().unwrap_or_else(|e| e.into_inner());
        ring.push(line);
        if let Some(revision) = REVISION.get() {
            revision.send_replace(ring.revision);
        }
    }
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
#[path = "logging_tests.rs"]
mod tests;

/// A `tracing` layer that funnels every (filtered) event into [`emit`].
struct CaptureLayer;

impl<S> Layer<S> for CaptureLayer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_event(&self, event: &Event<'_>, _ctx: Context<'_, S>) {
        let meta = event.metadata();
        let level = match *meta.level() {
            Level::TRACE => "TRACE",
            Level::DEBUG => "DEBUG",
            Level::INFO => "INFO",
            Level::WARN => "WARN",
            Level::ERROR => "ERROR",
        };
        let mut visitor = MessageVisitor::default();
        event.record(&mut visitor);
        emit(LogLine {
            level: level.to_string(),
            target: meta.target().to_string(),
            message: visitor.message,
            timestamp_ms: now_ms(),
        });
    }
}

/// Renders an event's `message` plus any structured fields into one line.
#[derive(Default)]
struct MessageVisitor {
    message: String,
}

impl MessageVisitor {
    fn append(&mut self, text: String) {
        if self.message.is_empty() {
            self.message = text;
        } else {
            self.message.push_str(", ");
            self.message.push_str(&text);
        }
    }
}

impl tracing::field::Visit for MessageVisitor {
    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        if field.name() == "message" {
            self.append(value.to_string());
        } else {
            self.append(format!("{}={value}", field.name()));
        }
    }

    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        if field.name() == "message" {
            self.append(format!("{value:?}"));
        } else {
            self.append(format!("{}={value:?}", field.name()));
        }
    }
}
