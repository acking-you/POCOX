//! Read codex session *rollout* files directly from `CODEX_HOME`.
//!
//! Every codex client (the CLI, the desktop app, the VS Code extension,
//! and Pocket-Codex's own spawned app-server) appends a JSON-Lines
//! transcript — a *rollout* — under `$CODEX_HOME/sessions/YYYY/MM/DD/`
//! as it runs. Because all those clients share one `CODEX_HOME`, reading
//! the rollouts lets Pocket-Codex *observe* sessions it did not create
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

use std::{
    path::{Path, PathBuf},
    time::UNIX_EPOCH,
};

use pocket_codex_core::{Error, Result};
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

/// A session discovered on disk, with its rollout path, header metadata
/// and classified most-recent-turn state.
#[derive(Debug, Clone)]
pub struct SessionInfo {
    /// Thread / conversation id.
    pub thread_id: String,
    /// Absolute path to the rollout JSONL file.
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
/// the path Pocket-Codex reads matches the one the desktop app / CLI
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
    let mut files = Vec::new();
    collect_jsonl(&sessions_dir()?, &mut files)?;
    Ok(files)
}

/// Locate the rollout file for a given `thread_id`.
///
/// The thread id is embedded verbatim at the end of the rollout filename
/// (`rollout-<timestamp>-<thread_id>.jsonl`), so this anchors the match to that
/// exact suffix — a bare `contains` would let one id match another whose id (or
/// timestamp) merely contains it, resolving the wrong session. Returns `None`
/// when no rollout exists for the id.
pub fn rollout_path_for_thread(thread_id: &str) -> Result<Option<PathBuf>> {
    rollout_path_in(&sessions_dir()?, thread_id)
}

/// Locate a thread under an explicit sessions directory without changing the
/// process environment, for isolated hosts and read-only fixtures.
pub fn rollout_path_in(dir: &Path, thread_id: &str) -> Result<Option<PathBuf>> {
    if thread_id.is_empty() {
        return Ok(None);
    }
    let suffix = format!("-{thread_id}.jsonl");
    let mut files = Vec::new();
    collect_jsonl(dir, &mut files)?;
    Ok(files.into_iter().find(|p| {
        p.file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.ends_with(&suffix))
    }))
}

/// Read header metadata, preview, mtime and turn state for one rollout.
pub fn read_session_info(path: &Path) -> Result<SessionInfo> {
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
/// (`rollout-<ts>-<thread_id>.jsonl`): the id is the trailing five
/// dash-separated groups of the stem. Returns `None` when the stem is
/// too short to contain one.
fn thread_id_from_path(path: &Path) -> Option<String> {
    let stem = path.file_stem().and_then(|s| s.to_str())?;
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
    use std::io::BufRead;
    let file = std::fs::File::open(path)?;
    let mut reader = std::io::BufReader::new(file);
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

/// Recursively collect `*.jsonl` files beneath `dir` into `out`.
///
/// A missing `dir` is not an error (it just contributes nothing).
fn collect_jsonl(dir: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
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
            collect_jsonl(&path, out)?;
        } else if path.extension().and_then(|e| e.to_str()) == Some("jsonl") {
            out.push(path);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
