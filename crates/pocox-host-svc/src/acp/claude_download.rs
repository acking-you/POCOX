//! Numeric-only telemetry from the npm child; all other stdout is discarded.

use std::{collections::VecDeque, time::Duration};

use tokio::{
    io::{AsyncRead, AsyncReadExt as _},
    sync::watch,
    time::Instant,
};

pub(super) const HOOK: &str = include_str!("claude_download.cjs");
const MAX_LINE: usize = 128;
const WINDOW: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct Sample {
    pub bytes: u64,
    pub active: u64,
}

fn parse(line: &[u8]) -> Option<Sample> {
    let line = std::str::from_utf8(line)
        .ok()?
        .strip_prefix("POCOX_DOWNLOAD ")?;
    let mut parts = line.split_whitespace();
    let bytes = parts.next()?.parse().ok()?;
    let active = parts.next()?.parse().ok()?;
    if parts.next().is_some() {
        return None;
    }
    Some(Sample {
        bytes,
        active,
    })
}

pub(super) async fn drain(
    mut stdout: impl AsyncRead + Unpin,
    samples: watch::Sender<Option<Sample>>,
) {
    let mut buf = [0; 8192];
    let mut line = Vec::with_capacity(MAX_LINE);
    let mut overflow = false;
    while let Ok(n) = stdout.read(&mut buf).await {
        if n == 0 {
            break;
        }
        for byte in &buf[..n] {
            if *byte == b'\n' {
                if !overflow {
                    if let Some(sample) = parse(&line) {
                        let previous = *samples.borrow();
                        if previous.is_none_or(|p| sample.bytes >= p.bytes) {
                            samples.send_replace(Some(sample));
                        }
                    }
                }
                line.clear();
                overflow = false;
            } else if line.len() < MAX_LINE && !overflow {
                line.push(*byte);
            } else {
                overflow = true;
            }
        }
    }
}

pub(super) struct Rate {
    points: VecDeque<(Instant, u64)>,
}

impl Rate {
    pub fn new(now: Instant) -> Self {
        Self {
            points: VecDeque::from([(now, 0)]),
        }
    }

    pub fn sample(&mut self, now: Instant, bytes: u64) -> u64 {
        self.points.push_back((now, bytes));
        while self.points.len() > 2 && now.duration_since(self.points[1].0) >= WINDOW {
            self.points.pop_front();
        }
        let (at, before) = self.points[0];
        let elapsed = now.duration_since(at).as_secs_f64();
        if elapsed == 0.0 {
            return 0;
        }
        (bytes.saturating_sub(before) as f64 / elapsed) as u64
    }
}

#[cfg(test)]
mod tests {
    use tokio::io::AsyncWriteExt as _;

    use super::*;

    #[tokio::test]
    async fn only_bounded_numeric_records_survive_the_pipe() {
        let (mut write, read) = tokio::io::duplex(8192);
        let (tx, rx) = watch::channel(None);
        let task = tokio::spawn(drain(read, tx));
        write
            .write_all(b"secret-token\nPOCOX_DOWNLOAD 10 1\n")
            .await
            .expect("write");
        write.write_all(&[b'x'; 4096]).await.expect("write");
        write.write_all(b"POCOX_DOWNLOAD 999 1\nPOCOX_DOWNLOAD 20 0\nPOCOX_DOWNLOAD 3 0\nPOCOX_DOWNLOAD 22 0 secret\n").await.expect("write");
        drop(write);
        task.await.expect("drained");
        assert_eq!(
            *rx.borrow(),
            Some(Sample {
                bytes: 20,
                active: 0
            })
        );
    }

    #[test]
    fn rate_uses_real_bytes_and_decays_to_zero_on_a_stall() {
        let start = Instant::now();
        let mut rate = Rate::new(start);
        assert_eq!(rate.sample(start + Duration::from_millis(500), 1000), 2000);
        assert_eq!(rate.sample(start + Duration::from_secs(1), 2000), 2000);
        assert_eq!(rate.sample(start + Duration::from_secs(2), 2000), 0);
        assert_eq!(parse(b"POCOX_DOWNLOAD -1 2"), None);
        assert_eq!(parse(b"POCOX_DOWNLOAD 3 4 5"), None);
    }
}
