//! Session directories and summaries, as Grok's own listing finds them
//! (`session/storage/relocation` candidate scan and the recent-session list
//! of `session/storage/jsonl`).

use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
};

use anyhow::{bail, Context, Result};
use chrono::{DateTime, SecondsFormat, Utc};
use serde::Deserialize;

pub(super) const SUMMARY_FILE: &str = "summary.json";
/// Largest summary read; real ones are well under a kilobyte.
const MAX_SUMMARY: u64 = 256 * 1024;
/// Most session directories examined in one scan.
const MAX_DIRS: usize = 50_000;

/// What a listing row shows of one session.
pub(super) struct Summary {
    pub id: String,
    pub cwd: String,
    pub title: String,
    pub parent: Option<String>,
    /// RFC 3339, the time Grok sorts its own list by.
    pub updated: String,
    updated_ms: i64,
}

#[derive(Deserialize)]
struct Raw {
    info: Info,
    #[serde(default)]
    session_summary: String,
    #[serde(default)]
    generated_title: Option<String>,
    updated_at: DateTime<Utc>,
    #[serde(default)]
    last_active_at: Option<DateTime<Utc>>,
    #[serde(default)]
    num_messages: u64,
    #[serde(default)]
    parent_session_id: Option<String>,
    #[serde(default)]
    forked_at: Option<serde_json::Value>,
    #[serde(default)]
    session_kind: Option<String>,
    #[serde(default)]
    hidden: Option<bool>,
}

#[derive(Deserialize)]
struct Info {
    id: String,
    cwd: String,
}

impl Raw {
    /// `generated_title` if non-empty, else `session_summary`.
    fn title(&self) -> &str {
        self.generated_title
            .as_deref()
            .map(str::trim)
            .filter(|title| !title.is_empty())
            .unwrap_or(self.session_summary.trim())
    }

    /// Left out of Grok's recent-session list: subagent children (`hidden`),
    /// one-shot `grok -p` runs, and a never-used session that a client
    /// opened optimistically (untitled, no messages, not a fork).
    fn unlisted(&self) -> bool {
        let kind = self.session_kind.as_deref();
        let hidden = self
            .hidden
            .unwrap_or(kind.is_some_and(|kind| kind.starts_with("subagent")));
        let fork = kind == Some("fork")
            || self
                .parent_session_id
                .as_deref()
                .is_some_and(|id| !id.is_empty())
            || self.forked_at.is_some();
        let husk = !fork && self.num_messages == 0 && self.title().is_empty();
        hidden || kind == Some("headless") || husk
    }
}

/// Every listed session under `root`, newest first.
pub(super) fn summaries(root: &Path) -> Result<Vec<Summary>> {
    let mut rows = Vec::new();
    for (id, dir) in unique_dirs(root)? {
        let Ok(raw) = read_summary(&dir) else { continue };
        if raw.info.id != id || raw.unlisted() {
            continue;
        }
        let updated = raw.last_active_at.unwrap_or(raw.updated_at);
        rows.push(Summary {
            title: clip(raw.title(), 4096),
            cwd: raw.info.cwd,
            parent: raw.parent_session_id.filter(|id| !id.is_empty()),
            updated: updated.to_rfc3339_opts(SecondsFormat::Millis, true),
            updated_ms: updated.timestamp_millis(),
            id,
        });
    }
    rows.sort_by(|a, b| {
        b.updated_ms
            .cmp(&a.updated_ms)
            .then_with(|| a.id.cmp(&b.id))
    });
    Ok(rows)
}

/// The one directory holding `id`'s persisted session.
pub(super) fn locate(root: &Path, id: &str) -> Result<PathBuf> {
    let buckets = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            bail!("native session not found")
        },
        Err(error) => return Err(error).context("reading Grok's sessions directory"),
    };
    let mut found = None;
    for bucket in buckets.take(MAX_DIRS) {
        let bucket = bucket.context("reading Grok's sessions directory")?;
        if !plain_dir(&bucket.path()) {
            continue;
        }
        let dir = bucket.path().join(id);
        if plain_dir(&dir) && plain_file(&dir.join(SUMMARY_FILE)) {
            if found.is_some() {
                // Grok itself skips an id stored under two directories.
                bail!("this Grok session is stored twice; Grok does not open it either");
            }
            found = Some(dir);
        }
    }
    found.context("native session not found")
}

/// Session directories by id, without ids present under several cwd
/// buckets (ambiguous to Grok too) or symlinked entries.
fn unique_dirs(root: &Path) -> Result<Vec<(String, PathBuf)>> {
    let buckets = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error).context("reading Grok's sessions directory"),
    };
    let mut seen = std::collections::HashMap::<String, Option<PathBuf>>::new();
    let mut examined = 0usize;
    for bucket in buckets {
        let bucket = bucket.context("reading Grok's sessions directory")?;
        if !plain_dir(&bucket.path()) {
            continue;
        }
        // A bucket can disappear between the two reads.
        let Ok(sessions) = fs::read_dir(bucket.path()) else { continue };
        for session in sessions.flatten() {
            examined += 1;
            if examined > MAX_DIRS {
                bail!("Grok's sessions directory holds more sessions than this reader lists");
            }
            let path = session.path();
            let Some(id) = session.file_name().to_str().map(str::to_owned) else { continue };
            if id.starts_with('.') || !plain_dir(&path) || !plain_file(&path.join(SUMMARY_FILE)) {
                continue;
            }
            seen.entry(id)
                .and_modify(|slot| *slot = None)
                .or_insert(Some(path));
        }
    }
    Ok(seen
        .into_iter()
        .filter_map(|(id, path)| path.map(|path| (id, path)))
        .collect())
}

fn read_summary(dir: &Path) -> Result<Raw> {
    let mut bytes = Vec::new();
    fs::File::open(dir.join(SUMMARY_FILE))?
        .take(MAX_SUMMARY + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_SUMMARY {
        bail!("session summary is too large");
    }
    Ok(serde_json::from_slice(&bytes)?)
}

/// The created time of the session in `dir`, part of its source identity.
pub(super) fn created_at(dir: &Path) -> Option<String> {
    #[derive(Deserialize)]
    struct Created {
        created_at: Option<String>,
    }
    let mut bytes = Vec::new();
    fs::File::open(dir.join(SUMMARY_FILE))
        .ok()?
        .take(MAX_SUMMARY + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    serde_json::from_slice::<Created>(&bytes).ok()?.created_at
}

/// The listed title and cwd of the session in `dir`.
pub(super) fn describe(dir: &Path) -> (String, String, i64) {
    match read_summary(dir) {
        Ok(raw) => {
            let updated = raw.last_active_at.unwrap_or(raw.updated_at);
            (clip(raw.title(), 4096), raw.info.cwd, updated.timestamp_millis())
        },
        Err(_) => (String::new(), String::new(), 0),
    }
}

fn plain_dir(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|meta| meta.file_type().is_dir())
}

fn plain_file(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|meta| meta.file_type().is_file())
}

fn clip(text: &str, max: usize) -> String {
    if text.len() <= max {
        return text.to_owned();
    }
    let mut end = max;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].to_owned()
}
