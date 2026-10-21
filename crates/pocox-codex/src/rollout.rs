//! Read codex session *rollout* files directly from `CODEX_HOME`.
//!
//! Every codex client (the CLI, the desktop app, the VS Code extension,
//! and POCOX's own spawned app-server) appends a JSON-Lines
//! transcript — a *rollout* — under `$CODEX_HOME/sessions/YYYY/MM/DD/`
//! as it runs. Because all those clients share one `CODEX_HOME`, reading
//! the rollouts lets POCOX *observe* sessions it did not create
//! (e.g. the ones the desktop app is driving) without going through any
//! app-server.
//!
//! This module is deliberately transport-free and side-effect-free: it
//! parses the on-disk JSONL and classifies a session's most recent turn
//! ([`TurnState`](crate::rollout::TurnState)). Whether a session is *owned by a
//! live process* — and therefore unsafe to resume — is a separate, liveness
//! question answered by [`crate::liveness`]; the two are combined in
//! [`crate::takeover`].
//!
//! ## Rollout wire shape
//!
//! Each line is one JSON object `{"timestamp", "type", "payload"}` where
//! `type` is the rollout-item kind and `payload` its body. The first
//! line is always `"type":"session_meta"`. Turn lifecycle is carried by
//! `"type":"event_msg"` lines whose `payload.type` is one of
//! `task_started`, `task_complete`, or `turn_aborted`.
//!
//! Codex compresses rollouts that have been idle for a week into a single
//! zstd frame beside the original name (`….jsonl.zst`), and decompresses one
//! back to plain `.jsonl` before appending to it. Every reader here accepts
//! both representations ([`open_rollout`]); when both exist the plain file is
//! the current one.

use std::{
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

use pocox_core::{Error, Result};
use serde_json::Value;
use tracing::debug;

use self::{message::extract_preview, meta::parse_session_meta};

mod inline_image;
mod message;
mod meta;
mod state_cache;
mod transcript;
mod turn_state;

pub use inline_image::inline_user_image;
pub use message::{is_context_fragment, realtime_delegation_input};
pub use meta::{parent_thread_id, thread_source, SessionMeta};
pub use transcript::{guardian_review, read_transcript, TranscriptItem};
pub use turn_state::{classify_turn_state, TurnState};

/// How many leading lines to scan for a human-readable preview.
const PREVIEW_HEAD_LINES: usize = 64;

/// Suffix Codex appends to a rollout name when it compresses the file.
const COMPRESSED_SUFFIX: &str = ".zst";

/// A session discovered on disk, with its rollout path, header metadata
/// and classified most-recent-turn state.
#[derive(Debug, Clone)]
pub struct SessionInfo {
    /// Thread / conversation id.
    pub thread_id: String,
    /// Absolute path to the rollout: plain `.jsonl` or compressed `.jsonl.zst`.
    pub rollout_path: PathBuf,
    /// Working directory the session controls, when recorded.
    pub cwd: Option<String>,
    /// Client that created the session, when recorded.
    pub source: Option<String>,
    /// Parent thread recorded by Codex for spawned sessions.
    pub parent_thread_id: Option<String>,
    /// Persisted thread classification, including Guardian reviewers.
    pub thread_source: Option<String>,
    /// Best-effort one-line preview (the first user message text).
    pub preview: String,
    /// Last-modified time of the rollout file, in unix seconds.
    pub updated_at: i64,
    /// Classified state of the most recent turn.
    pub turn_state: TurnState,
}

/// Resolve `CODEX_HOME`: the `CODEX_HOME` environment variable when set
/// and non-empty, otherwise `~/.codex`.
///
/// This mirrors how the codex binaries themselves resolve their home, so
/// the path POCOX reads matches the one the desktop app / CLI
/// write to (assuming the same environment).
pub fn codex_home() -> Result<PathBuf> {
    if let Some(dir) = std::env::var_os("CODEX_HOME") {
        let path = PathBuf::from(dir);
        if !path.as_os_str().is_empty() {
            return Ok(path);
        }
    }
    let base = directories::BaseDirs::new()
        .ok_or_else(|| Error::Path("cannot determine home directory for CODEX_HOME".into()))?;
    Ok(base.home_dir().join(".codex"))
}

/// The `sessions` directory under [`codex_home`].
pub fn sessions_dir() -> Result<PathBuf> {
    Ok(codex_home()?.join("sessions"))
}

/// Enumerate every session under [`sessions_dir`], newest first.
///
/// Missing directories yield an empty list rather than an error (a fresh
/// install simply has no sessions). Individual files that fail to parse
/// are skipped (logged at debug) so one corrupt rollout cannot hide the
/// rest.
pub fn scan_sessions() -> Result<Vec<SessionInfo>> {
    let files = session_paths()?;
    let mut out = Vec::with_capacity(files.len());
    for path in files {
        match read_session_info(&path) {
            Ok(info) => out.push(info),
            Err(err) => debug!(path = %path.display(), %err, "skipping unreadable rollout"),
        }
    }
    out.sort_by_key(|info| std::cmp::Reverse(info.updated_at));
    Ok(out)
}

/// Enumerate rollout paths without reading any transcript contents.
pub fn session_paths() -> Result<Vec<PathBuf>> {
    rollout_paths_in(&sessions_dir()?)
}

/// Every rollout beneath `dir`, one path per session: a compressed copy is
/// skipped when its plain sibling exists (the plain file is the live one).
fn rollout_paths_in(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    collect_rollouts(dir, &mut files)?;
    let plain: std::collections::HashSet<PathBuf> = files
        .iter()
        .filter(|path| !is_compressed(path))
        .cloned()
        .collect();
    files.retain(|path| !is_compressed(path) || !plain.contains(&path.with_extension("")));
    Ok(files)
}

/// Whether `path` names a compressed (`.jsonl.zst`) rollout.
pub fn is_compressed(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name.ends_with(COMPRESSED_SUFFIX))
}

/// Open a rollout for line reading, decoding a compressed one on the fly.
/// A rollout replaced by its other representation since `path` was listed is
/// opened in that one.
pub fn open_rollout(path: &Path) -> Result<Box<dyn std::io::BufRead + Send>> {
    Ok(match open_representation(path) {
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            open_representation(&sibling(path))?
        },
        opened => opened?,
    })
}

fn open_representation(path: &Path) -> std::io::Result<Box<dyn std::io::BufRead + Send>> {
    let file = std::fs::File::open(path)?;
    Ok(if is_compressed(path) {
        Box::new(std::io::BufReader::new(zstd::stream::read::Decoder::new(file)?))
    } else {
        Box::new(std::io::BufReader::new(file))
    })
}

/// The representation of `path`'s rollout that exists now. Codex replaces a
/// plain rollout with its compressed copy when it goes cold, and the other way
/// round before appending, so a path listed a moment ago may name the other.
/// Each replacement writes the new file before removing the old one.
pub fn current_rollout(path: &Path) -> PathBuf {
    if path.exists() {
        return path.to_path_buf();
    }
    let other = sibling(path);
    if other.exists() {
        other
    } else {
        path.to_path_buf()
    }
}

/// The same rollout's other representation.
fn sibling(path: &Path) -> PathBuf {
    if is_compressed(path) {
        path.with_extension("")
    } else {
        let mut compressed = path.as_os_str().to_owned();
        compressed.push(COMPRESSED_SUFFIX);
        PathBuf::from(compressed)
    }
}

/// Locate the rollout file for a given `thread_id`.
///
/// The thread id is embedded verbatim at the end of the rollout filename
/// (`rollout-<timestamp>-<thread_id>.jsonl`), so this anchors the match to that
/// exact suffix — a bare `contains` would let one id match another whose id (or
/// timestamp) merely contains it, resolving the wrong session. A compressed
/// rollout counts when no plain one exists. Returns `None` when no rollout
/// exists for the id.
pub fn rollout_path_for_thread(thread_id: &str) -> Result<Option<PathBuf>> {
    rollout_path_in(&sessions_dir()?, thread_id)
}

/// Locate a thread under an explicit sessions directory without changing the
/// process environment, for isolated hosts and read-only fixtures.
pub fn rollout_path_in(dir: &Path, thread_id: &str) -> Result<Option<PathBuf>> {
    if thread_id.is_empty() {
        return Ok(None);
    }
    let plain = format!("-{thread_id}.jsonl");
    let compressed = format!("{plain}{COMPRESSED_SUFFIX}");
    Ok(rollout_paths_in(dir)?.into_iter().find(|p| {
        p.file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.ends_with(&plain) || n.ends_with(&compressed))
    }))
}

/// Read header metadata, preview, mtime and turn state for one rollout.
pub fn read_session_info(path: &Path) -> Result<SessionInfo> {
    let path = &current_rollout(path);
    let head = read_head(path, PREVIEW_HEAD_LINES)?;
    let meta = head.lines().next().and_then(parse_session_meta);
    let thread_id = meta
        .as_ref()
        .map(|m| m.id.clone())
        .or_else(|| thread_id_from_path(path))
        .ok_or_else(|| Error::Config(format!("no thread id for rollout {}", path.display())))?;
    let updated_at = mtime_unix_secs(path);
    let turn_state = classify_turn_state(path)?;
    let preview = extract_preview(&head);
    Ok(SessionInfo {
        thread_id,
        rollout_path: path.to_path_buf(),
        cwd: meta.as_ref().and_then(|m| m.cwd.clone()),
        source: meta.as_ref().and_then(|m| m.source.clone()),
        parent_thread_id: meta.as_ref().and_then(|m| m.parent_thread_id.clone()),
        thread_source: meta.as_ref().and_then(|m| m.thread_source.clone()),
        preview,
        updated_at,
        turn_state,
    })
}

/// `value` as a string, when it is a non-empty one.
fn non_empty(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// Derive the thread id from a rollout filename
/// (`rollout-<ts>-<thread_id>.jsonl[.zst]`): the id is the trailing five
/// dash-separated groups of the stem. Returns `None` when the stem is
/// too short to contain one.
fn thread_id_from_path(path: &Path) -> Option<String> {
    let name = path.file_name().and_then(|s| s.to_str())?;
    let stem = name
        .strip_suffix(COMPRESSED_SUFFIX)
        .unwrap_or(name)
        .strip_suffix(".jsonl")?;
    let parts: Vec<&str> = stem.split('-').collect();
    if parts.len() < 5 {
        return None;
    }
    Some(parts[parts.len() - 5..].join("-"))
}

/// Last-modified time of `path` in unix seconds (0 when unavailable).
fn mtime_unix_secs(path: &Path) -> i64 {
    std::fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Read at most the first `max_lines` lines of a file as lossy UTF-8.
///
/// Reads raw bytes per line and decodes lossily rather than `lines()` (which
/// errors on the first invalid-UTF-8 byte): rollouts are written by external
/// processes, and one malformed byte must not hide the whole session.
fn read_head(path: &Path, max_lines: usize) -> Result<String> {
    let mut reader = open_rollout(path)?;
    let mut out = String::new();
    let mut line = Vec::new();
    for _ in 0..max_lines {
        line.clear();
        if reader.read_until(b'\n', &mut line)? == 0 {
            break;
        }
        out.push_str(&String::from_utf8_lossy(&line));
    }
    Ok(out)
}

/// Recursively collect `*.jsonl` and `*.jsonl.zst` files beneath `dir`.
///
/// A missing `dir` is not an error (it just contributes nothing).
fn collect_rollouts(dir: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(err) => return Err(err.into()),
    };
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            collect_rollouts(&path, out)?;
        } else if path
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.ends_with(".jsonl") || n.ends_with(".jsonl.zst"))
        {
            out.push(path);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
