//! The output of a child launched with a supplied key. None of its raw bytes
//! reach its log file: a child may print the key in any number of pieces,
//! which no per-line rule contains (see [`pocox_core::redact`]). The
//! log receives this app's fixed notices instead: [`OUTPUT_WITHHELD`] once,
//! and [`ADDR_IN_USE`] for each line reporting an address-in-use bind
//! failure, so a failed start is still diagnosed (and offered another port).

use std::{
    fs::File,
    io::{ErrorKind, Read, Write},
};

use pocox_core::redact::{Lines, Piece, ADDR_IN_USE, OUTPUT_WITHHELD};

/// Longest partial line kept for classification; a longer line is dropped.
pub(crate) const LINE_CAP: usize = 64 * 1024;

/// Read `source` (a child's stdout or stderr pipe) on its own thread until
/// the child closes it, writing only notices to `sink` (its log file, opened
/// for appending); `header` writes [`OUTPUT_WITHHELD`] first. `false` when
/// the thread could not be started (the pipe is then closed, so nothing
/// reaches the log).
pub(crate) fn pump(source: impl Read + Send + 'static, mut sink: File, header: bool) -> bool {
    std::thread::Builder::new()
        .name("codex-output".into())
        .spawn(move || {
            if header {
                let _ = sink.write_all(format!("{OUTPUT_WITHHELD}\n").as_bytes());
            }
            notices(source, |notice| {
                // One write per notice, so the two streams never interleave
                // within a line.
                let _ = sink.write_all(format!("{notice}\n").as_bytes());
            });
        })
        .is_ok()
}

/// Read `source` to its end, emitting [`ADDR_IN_USE`] for each complete
/// line that reports an address-in-use bind failure; nothing else of it.
fn notices(mut source: impl Read, mut emit: impl FnMut(&'static str)) {
    let mut lines = Lines::new(LINE_CAP);
    let mut buf = [0u8; 8192];
    loop {
        let n = match source.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        lines.feed(&buf[..n], |piece| {
            if let Piece::Line(line) = piece {
                if crate::readiness::line_mentions_addr_in_use(&String::from_utf8_lossy(line)) {
                    emit(ADDR_IN_USE);
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use super::*;

    const KEY: &str = "sk-ABC0123";

    /// A reader yielding `text` in pieces of `size` bytes, one per read.
    struct Chunks<'a> {
        text: &'a [u8],
        size: usize,
    }

    impl Read for Chunks<'_> {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            let n = self.size.min(self.text.len()).min(buf.len());
            buf[..n].copy_from_slice(&self.text[..n]);
            self.text = &self.text[n..];
            Ok(n)
        }
    }

    /// The dummy key split at every pair of positions into pieces of zero
    /// to its full length over separate lines, read in chunks of one to five
    /// bytes, plus an over-long line: no read ever produces anything but
    /// the bind-failure notice.
    #[test]
    fn no_split_of_the_key_reaches_the_log() {
        let mut texts = Vec::new();
        for i in 0..=KEY.len() {
            for j in i..=KEY.len() {
                let (a, rest) = KEY.split_at(i);
                let (b, c) = rest.split_at(j - i);
                texts.push(format!("auth {a}\n{b}\r\n{c} ok\n{c}"));
            }
        }
        texts.push(format!("{}{KEY}\n{}\n", "x".repeat(LINE_CAP), &KEY[..2]));
        for text in &texts {
            for size in 1..=5 {
                let mut emitted = Vec::new();
                notices(
                    Chunks {
                        text: text.as_bytes(),
                        size,
                    },
                    |n| emitted.push(n),
                );
                assert!(emitted.is_empty(), "{emitted:?}");
            }
        }
        let mut emitted = Vec::new();
        let bind = format!("{KEY} Error: Address already in use (os error 48)\n");
        notices(
            Chunks {
                text: bind.as_bytes(),
                size: 3,
            },
            |n| emitted.push(n),
        );
        assert_eq!(emitted, [ADDR_IN_USE], "only the fixed notice, never the line");
    }

    /// A real pipe written in separate writes: the log holds the header and
    /// the bind notice, and no byte of what the child wrote.
    #[test]
    fn the_log_receives_only_notices() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("child.log");
        let sink = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .expect("log");
        let (reader, mut writer) = std::io::pipe().expect("pipe");
        assert!(pump(reader, sink, true));
        let writes: [&[u8]; 6] = [
            b"starting\r\n",
            b"auth s",
            b"k-\nA",
            b"BC\n0123 ok\n",
            b"bind: EADDRINUSE\n",
            b"done",
        ];
        for chunk in writes {
            writer.write_all(chunk).expect("write");
            writer.flush().expect("flush");
            std::thread::sleep(Duration::from_millis(20));
        }
        drop(writer);
        let deadline = Instant::now() + Duration::from_secs(5);
        let log = loop {
            let log = std::fs::read_to_string(&path).expect("read");
            if log.contains(ADDR_IN_USE) || Instant::now() >= deadline {
                break log;
            }
            std::thread::sleep(Duration::from_millis(20));
        };
        let lines: Vec<&str> = log.lines().collect();
        assert_eq!(lines, [OUTPUT_WITHHELD, ADDR_IN_USE]);
        for raw in ["starting", "sk-", "ABC", "0123", "done"] {
            assert!(!log.contains(raw), "{log}");
        }
        assert!(crate::readiness::line_mentions_addr_in_use(ADDR_IN_USE));
    }
}
