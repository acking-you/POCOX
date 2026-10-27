//! Translate installer output into bounded, language-neutral progress. Raw
//! output (which can contain paths, URLs and credentials) never leaves the
//! host. Silent installers stay indeterminate; output bytes are never download
//! bytes.

use pocox_core::process::bounded::OutputStream;

use super::view::Download;

/// One observed phase or download measurement.
pub(super) struct Update {
    pub(super) stage: &'static str,
    pub(super) download: Option<Download>,
}

/// Separate framing for stdout and stderr; reads may split UTF-8 or CR updates.
#[derive(Default)]
pub(super) struct Parser {
    lines: [Vec<u8>; 2],
    overflow: [bool; 2],
}

impl Parser {
    pub(super) fn push(&mut self, stream: OutputStream, bytes: &[u8]) -> Option<Update> {
        let index = match stream {
            OutputStream::Stdout => 0,
            OutputStream::Stderr => 1,
        };
        let mut update = None;
        for byte in bytes {
            if matches!(byte, b'\r' | b'\n') {
                if !self.overflow[index] {
                    if let Some(found) = parse(&String::from_utf8_lossy(&self.lines[index])) {
                        update = Some(found);
                    }
                }
                self.lines[index].clear();
                self.overflow[index] = false;
            } else if self.lines[index].len() < 4096 {
                self.lines[index].push(*byte);
            } else {
                self.overflow[index] = true;
            }
        }
        update
    }
}

fn parse(line: &str) -> Option<Update> {
    let line = line.trim();
    if let Some(download) = curl_meter(line)
        .or_else(|| byte_bar(line))
        .or_else(|| percent_bar(line))
    {
        return Some(Update {
            stage: "downloading",
            download: Some(download),
        });
    }
    let stage = if line.contains("Downloading ") || line.contains("Fetching downloads for:") {
        "downloading"
    } else if line.contains("Installing ")
        || line.contains("Upgrading ")
        || line.contains("Reinstalling ")
    {
        "installing"
    } else {
        return None;
    };
    Some(Update {
        stage,
        download: None,
    })
}

/// curl's standard 12-column transfer meter, including its current speed.
fn curl_meter(line: &str) -> Option<Download> {
    let fields: Vec<&str> = line.split_whitespace().collect();
    if fields.len() != 12
        || !fields[8..11]
            .iter()
            .all(|time| time.matches(':').count() == 2)
    {
        return None;
    }
    let percent = fields[2]
        .parse::<u8>()
        .ok()
        .filter(|percent| *percent <= 100)?;
    let received = quantity(fields[3], 1024.0)?;
    let total = quantity(fields[1], 1024.0)?;
    let speed = quantity(fields[11], 1024.0)?;
    Some(Download {
        downloaded_bytes: Some(received),
        total_bytes: (total > 0).then_some(total),
        bytes_per_second: Some(speed),
        percent: (total > 0).then_some(percent),
    })
}

/// indicatif's byte bar used by Grok: `... 12.5 MiB/100 MiB (5s)`.
fn byte_bar(line: &str) -> Option<Download> {
    let fields: Vec<&str> = line.split_whitespace().collect();
    for fields in fields.windows(3) {
        let Some((unit, total)) = fields[1].split_once('/') else { continue };
        let Some(received) = human_bytes(fields[0], unit) else { continue };
        let Some(total) =
            human_bytes(total, fields[2]).filter(|total| *total > 0 && *total >= received)
        else {
            continue;
        };
        return Some(Download {
            downloaded_bytes: Some(received),
            total_bytes: Some(total),
            percent: Some((u128::from(received) * 100 / u128::from(total)) as u8),
            ..Download::default()
        });
    }
    None
}

fn human_bytes(number: &str, unit: &str) -> Option<u64> {
    let (suffix, base) = match unit {
        "B" => ("", 1.0),
        "kB" | "KB" => ("k", 1000.0),
        "MB" => ("m", 1000.0),
        "GB" => ("g", 1000.0),
        "KiB" => ("k", 1024.0),
        "MiB" => ("m", 1024.0),
        "GiB" => ("g", 1024.0),
        _ => return None,
    };
    quantity(&format!("{number}{suffix}"), base)
}

fn quantity(text: &str, base: f64) -> Option<u64> {
    let (number, power) = match text.as_bytes().last()? {
        b'k' | b'K' => (&text[..text.len() - 1], 1),
        b'm' | b'M' => (&text[..text.len() - 1], 2),
        b'g' | b'G' => (&text[..text.len() - 1], 3),
        _ => (text, 0),
    };
    let value = number.parse::<f64>().ok()? * base.powi(power);
    (value.is_finite() && value >= 0.0 && value < u64::MAX as f64).then_some(value as u64)
}

/// curl's compact bar: only bar characters followed by a percentage qualify.
fn percent_bar(line: &str) -> Option<Download> {
    let body = line.strip_suffix('%')?;
    let (bar, value) = body.rsplit_once(char::is_whitespace)?;
    if !bar
        .chars()
        .all(|c| c.is_whitespace() || matches!(c, '#' | '-' | '=' | '>'))
    {
        return None;
    }
    let value = value.parse::<f64>().ok()?;
    (value.is_finite() && (0.0..=100.0).contains(&value)).then_some(Download {
        percent: Some(value as u8),
        ..Download::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn progress_is_framed_per_pipe_and_contains_only_measurements() {
        let mut parser = Parser::default();
        assert!(parser
            .push(OutputStream::Stderr, b" 25 100M 25 25M 0 0 ")
            .is_none());
        let phase = parser
            .push(OutputStream::Stdout, b"Downloading https://secret@example.invalid/file\n")
            .expect("phase");
        assert_eq!(phase.stage, "downloading");
        assert!(phase.download.is_none());
        let measured = parser
            .push(OutputStream::Stderr, b"1250k 0 0:01:20 0:00:20 0:01:00 1250k\r")
            .expect("measurement")
            .download
            .expect("download");
        assert_eq!(measured.downloaded_bytes, Some(25 * 1024 * 1024));
        assert_eq!(measured.total_bytes, Some(100 * 1024 * 1024));
        assert_eq!(measured.bytes_per_second, Some(1250 * 1024));
        assert_eq!(measured.percent, Some(25));
        let bar = parse("  ━━━━━╸─── 12.5 MiB/100 MiB (5s)")
            .expect("grok bar")
            .download
            .expect("download");
        assert_eq!(bar.downloaded_bytes, Some(13_107_200));
        assert_eq!(bar.percent, Some(12));
        assert_eq!(
            parse("####---- 50.0%")
                .expect("curl bar")
                .download
                .expect("download")
                .percent,
            Some(50)
        );
        assert!(parse("disk 50% full").is_none());
        assert!(parse("####---- NaN%").is_none());
        assert!(parser
            .push(OutputStream::Stdout, &vec![b'x'; 8192])
            .is_none());
        assert!(
            parser.push(OutputStream::Stdout, b"#### 100%\n").is_none(),
            "an oversized line is discarded whole"
        );
    }
}
