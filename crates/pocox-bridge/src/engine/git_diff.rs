//! Display-oriented unified diff parsing. Partial hunks from streamed tool
//! output remain readable; unlike an apply-patch parser, incomplete counts are
//! not an error. Headers are only recognized outside an active hunk.
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
};

use once_cell::sync::Lazy;

/// One numbered row in a unified diff.
#[derive(Clone, Debug)]
pub struct Line {
    /// `context`, `added`, `removed` or `hunk`.
    pub kind: String,
    /// Content without the diff marker; hunk headers retain their marker.
    pub text: String,
    /// Old-file line number, or the old start for a hunk header.
    pub old_line: Option<u32>,
    /// New-file line number, or the new start for a hunk header.
    pub new_line: Option<u32>,
}
/// One changed file.
#[derive(Clone, Debug, Default)]
pub struct FileDiff {
    /// Decoded new path, or the old path for a deletion.
    pub path: String,
    /// Ordered display rows.
    pub lines: Vec<Line>,
    /// Added lines.
    pub added: u32,
    /// Removed lines.
    pub removed: u32,
}
/// Parsed display diff, cached by a content digest.
#[derive(Clone, Debug, Default)]
pub struct Diff {
    /// Content identity for controller view caches.
    pub revision: String,
    /// Changed files, in source order.
    pub files: Vec<FileDiff>,
    /// Added lines across files.
    pub added: u32,
    /// Removed lines across files.
    pub removed: u32,
    /// The source exceeded the bounded display parser's capacity.
    pub truncated: bool,
}

const MAX_INPUT: usize = 16 << 20;
const MAX_LINES: usize = 100_000;
const CACHE_BYTES: usize = 8 << 20;
type CacheEntry = (String, Arc<Diff>, usize);
static CACHE: Lazy<Mutex<VecDeque<CacheEntry>>> = Lazy::new(|| Mutex::new(VecDeque::new()));

/// Parse once per content revision, keeping only a bounded cache of results.
pub fn parse(raw: &str) -> Arc<Diff> {
    let revision = pocox_core::history_sync::digest_bytes(raw.as_bytes());
    {
        let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(at) = cache.iter().position(|(key, _, _)| *key == revision) {
            if let Some(entry) = cache.remove(at) {
                let value = entry.1.clone();
                cache.push_back(entry);
                return value;
            }
        }
    }
    let mut result = parse_inner(raw);
    result.revision = revision.clone();
    let weight = std::mem::size_of::<Diff>()
        + revision.len()
        + result
            .files
            .iter()
            .map(|file| {
                file.path.capacity()
                    + std::mem::size_of::<FileDiff>()
                    + file.lines.capacity() * std::mem::size_of::<Line>()
                    + file
                        .lines
                        .iter()
                        .map(|line| line.text.capacity() + line.kind.capacity())
                        .sum::<usize>()
            })
            .sum::<usize>();
    let result = Arc::new(result);
    if weight <= CACHE_BYTES {
        let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
        cache.retain(|(key, _, _)| *key != revision);
        let mut total = cache.iter().map(|entry| entry.2).sum::<usize>() + weight;
        while total > CACHE_BYTES || cache.len() >= 128 {
            let Some((_, _, bytes)) = cache.pop_front() else { break };
            total -= bytes;
        }
        cache.push_back((revision, result.clone(), weight));
    }
    result
}

fn range(token: &str, sign: char) -> Option<(u32, u32)> {
    let text = token.strip_prefix(sign)?;
    let (start, count) = text.split_once(',').unwrap_or((text, "1"));
    Some((start.parse().ok()?, count.parse().ok()?))
}
fn hunk(line: &str) -> Option<((u32, u32), (u32, u32))> {
    let mut fields = line.split_whitespace();
    if fields.next()? != "@@" {
        return None;
    }
    let old = range(fields.next()?, '-')?;
    let new = range(fields.next()?, '+')?;
    (fields.next()? == "@@").then_some((old, new))
}

fn parse_inner(raw: &str) -> Diff {
    let mut result = Diff::default();
    let mut file = FileDiff::default();
    let mut old_path = None;
    let (mut old_no, mut new_no) = (None, None);
    let (mut old_left, mut new_left) = (0u32, 0u32);
    let mut used = 0;
    for (index, line) in raw.lines().enumerate() {
        used += line.len() + 1;
        if index >= MAX_LINES || used > MAX_INPUT {
            result.truncated = true;
            break;
        }
        let active = old_left > 0 || new_left > 0;
        if line.starts_with("diff --git ") {
            flush(&mut result, &mut file);
            old_path = None;
            old_no = None;
            new_no = None;
            old_left = 0;
            new_left = 0;
            continue;
        }
        if !active && line.starts_with("--- ") {
            flush(&mut result, &mut file);
            old_path = path(&line[4..]);
            continue;
        }
        if !active && line.starts_with("+++ ") {
            file.path = path(&line[4..])
                .or_else(|| old_path.clone())
                .unwrap_or_default();
            continue;
        }
        if file.path.is_empty() {
            continue;
        }
        if let Some(((old, old_count), (new, new_count))) = hunk(line) {
            old_no = Some(old);
            new_no = Some(new);
            old_left = old_count;
            new_left = new_count;
            file.lines.push(Line {
                kind: "hunk".into(),
                text: line.into(),
                old_line: old_no,
                new_line: new_no,
            });
            continue;
        }
        let (kind, old, new) = match line.as_bytes().first() {
            Some(b'+') => {
                file.added += 1;
                ("added", None, new_no)
            },
            Some(b'-') => {
                file.removed += 1;
                ("removed", old_no, None)
            },
            Some(b' ') => ("context", old_no, new_no),
            _ => continue,
        };
        file.lines.push(Line {
            kind: kind.into(),
            text: line[1..].into(),
            old_line: old,
            new_line: new,
        });
        if kind != "added" {
            old_no = old_no.map(|n| n.saturating_add(1));
            old_left = old_left.saturating_sub(1);
        }
        if kind != "removed" {
            new_no = new_no.map(|n| n.saturating_add(1));
            new_left = new_left.saturating_sub(1);
        }
    }
    flush(&mut result, &mut file);
    result
}
fn flush(result: &mut Diff, file: &mut FileDiff) {
    if !file.path.is_empty() && !file.lines.is_empty() {
        result.added += file.added;
        result.removed += file.removed;
        result.files.push(std::mem::take(file));
    } else {
        *file = FileDiff::default();
    }
}

fn path(raw: &str) -> Option<String> {
    let raw = raw.trim();
    let value = if let Some(quoted) = raw.strip_prefix('"') {
        let mut bytes = Vec::new();
        let mut input = quoted.bytes().peekable();
        while let Some(byte) = input.next() {
            if byte == b'"' {
                break;
            }
            if byte != b'\\' {
                bytes.push(byte);
                continue;
            }
            let Some(escaped) = input.next() else { break };
            if (b'0'..=b'7').contains(&escaped) {
                let mut value = u16::from(escaped - b'0');
                for _ in 0..2 {
                    let Some(next) = input.peek().copied().filter(|b| (b'0'..=b'7').contains(b))
                    else {
                        break;
                    };
                    input.next();
                    value = value * 8 + u16::from(next - b'0');
                }
                bytes.push(value as u8);
            } else {
                bytes.push(match escaped {
                    b'n' => b'\n',
                    b't' => b'\t',
                    b'r' => b'\r',
                    b'b' => 8,
                    b'f' => 12,
                    b'v' => 11,
                    other => other,
                });
            }
        }
        String::from_utf8_lossy(&bytes).into_owned()
    } else {
        raw.split('\t')
            .next()
            .unwrap_or_default()
            .trim()
            .to_string()
    };
    if value.is_empty() || value == "/dev/null" {
        return None;
    }
    Some(
        value
            .strip_prefix("a/")
            .or_else(|| value.strip_prefix("b/"))
            .unwrap_or(&value)
            .to_string(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn hunk_content_that_looks_like_file_headers_is_content() {
        let diff = parse(
            "diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -1 +1 @@\n--- old\n+++ new\n",
        );
        assert_eq!((diff.added, diff.removed), (1, 1));
        assert_eq!(diff.files[0].lines[1].text, "-- old");
        assert_eq!(diff.files[0].lines[2].new_line, Some(1));
    }
    #[test]
    fn quoted_utf8_paths_deletions_and_partial_hunks_are_preserved() {
        let diff = parse(
            "--- /dev/null\n+++ \"b/\\344\\270\\255\\346\\226\\207 a\\t.txt\"\n@@ -0,0 +1,3 \
             @@\n+one\n",
        );
        assert_eq!(diff.files[0].path, "中文 a\t.txt");
        assert_eq!(diff.added, 1);
        let deleted =
            parse("--- a/old name.txt\tstamp\n+++ /dev/null\n@@ -2,2 +0,0 @@\n-old\n-last\n");
        assert_eq!(deleted.files[0].path, "old name.txt");
        assert_eq!(deleted.removed, 2);
        assert_eq!(deleted.files[0].lines[2].old_line, Some(3));
        assert!(parse("").files.is_empty());
    }
}
