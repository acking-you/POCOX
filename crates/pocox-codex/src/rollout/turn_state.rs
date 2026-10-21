//! Classify a session's most recent turn from its rollout's lifecycle events.

use std::{
    io::{Read, Seek, SeekFrom},
    path::Path,
};

use pocox_core::Result;
use serde_json::Value;

/// Only the trailing window of a rollout is scanned to classify the most
/// recent turn: the lifecycle markers (`task_started` / `task_complete` /
/// `turn_aborted`) are tiny events that land at the very end of the
/// transcript, so a bounded tail keeps scanning many sessions cheap. A
/// full-file fallback covers the rare case where the last turn's markers
/// predate this window (see [`classify_turn_state`]).
pub(super) const MAX_TAIL_BYTES: u64 = 256 * 1024;

/// Lifecycle state of a session's most recent turn, derived purely from
/// the rollout transcript (no liveness probe).
///
/// `Incomplete` alone cannot tell *running* from *crashed* — a live
/// writer and a dead one both leave a turn without its terminal marker.
/// Disambiguating requires the liveness probe in [`crate::liveness`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TurnState {
    /// The transcript carries no turn lifecycle events yet (a freshly
    /// created session that has not run a turn).
    Empty,
    /// The most recent turn ended normally (`task_complete`).
    Completed,
    /// The most recent turn was aborted; carries the reason token
    /// (`interrupted` / `replaced` / `reviewEnded` / `budgetLimited` /
    /// …) as serialized on the wire.
    Aborted(String),
    /// A turn was started but has no matching `task_complete` or
    /// `turn_aborted` after it — it is either running right now or was
    /// left dangling by a crashed writer.
    Incomplete,
    /// The rollout is stored compressed. Codex compresses only rollouts left
    /// idle for a week and decompresses one before writing to it again, so
    /// no turn runs in it; its lifecycle markers are not decoded, since that
    /// would inflate the whole file.
    Unknown,
}

impl TurnState {
    /// Whether the most recent turn has reached a terminal state
    /// (completed or aborted), i.e. the session is *not* mid-turn from
    /// the transcript's point of view. `Empty` counts as finished (there
    /// is nothing in flight).
    pub fn is_finished(&self) -> bool {
        matches!(self, TurnState::Completed | TurnState::Aborted(_) | TurnState::Empty)
    }

    /// Stable lowercase tag for FFI / UI (`empty` / `completed` /
    /// `aborted` / `incomplete` / `unknown`).
    pub fn tag(&self) -> &'static str {
        match self {
            TurnState::Empty => "empty",
            TurnState::Completed => "completed",
            TurnState::Aborted(_) => "aborted",
            TurnState::Incomplete => "incomplete",
            TurnState::Unknown => "unknown",
        }
    }
}

/// Classify the most recent turn of a rollout from its tail.
///
/// Reads only the trailing [`MAX_TAIL_BYTES`]; if that window contains no
/// lifecycle markers yet the file is larger than the window (a long turn
/// whose `task_started` predates the tail), it falls back to a full
/// scan so a long-running turn is never misread as [`TurnState::Empty`].
/// A bounded cache reuses unchanged results and scans only appended bytes
/// after a complete line boundary; replacement and truncation restart it.
/// A compressed rollout is [`TurnState::Unknown`].
pub fn classify_turn_state(path: &Path) -> Result<TurnState> {
    let path = super::current_rollout(path);
    if super::is_compressed(&path) {
        return Ok(TurnState::Unknown);
    }
    super::state_cache::classify(&path)
}

/// Classify turn state from an ordered iterator of rollout lines.
///
/// Pure and allocation-light: a cheap substring prefilter skips the
/// overwhelming majority of lines (messages, reasoning, tool output)
/// before any JSON parsing, so only the tiny lifecycle events are
/// deserialized. The classification is the state left by the *last*
/// lifecycle event in file order:
///
/// * `task_started`  ⇒ [`TurnState::Incomplete`]
/// * `task_complete` ⇒ [`TurnState::Completed`]
/// * `turn_aborted`  ⇒ [`TurnState::Aborted`]
///
/// with [`TurnState::Empty`] when none are present.
pub(super) fn classify_lines<'a, I: Iterator<Item = &'a str>>(lines: I) -> TurnState {
    lines
        .filter_map(turn_state_of_line)
        .last()
        .unwrap_or(TurnState::Empty)
}

/// Classify a single rollout line as a turn lifecycle transition, or `None`
/// when it is not a `task_started` / `task_complete` / `turn_aborted`
/// `event_msg`. Shared by the tail scan and the streaming full-file fallback.
pub(super) fn turn_state_of_line(line: &str) -> Option<TurnState> {
    if !(line.contains("task_started")
        || line.contains("task_complete")
        || line.contains("turn_aborted"))
    {
        return None;
    }
    let value: Value = serde_json::from_str(line).ok()?;
    if value.get("type").and_then(Value::as_str) != Some("event_msg") {
        return None;
    }
    let payload = value.get("payload")?;
    match payload.get("type").and_then(Value::as_str) {
        Some("task_started") => Some(TurnState::Incomplete),
        Some("task_complete") => Some(TurnState::Completed),
        Some("turn_aborted") => Some(TurnState::Aborted(parse_abort_reason(payload))),
        _ => None,
    }
}

/// Extract a `turn_aborted` reason token, tolerating either a plain
/// string (`"reason":"interrupted"`) or a tagged object
/// (`"reason":{"replaced":…}`). Falls back to `"unknown"`.
fn parse_abort_reason(payload: &Value) -> String {
    match payload.get("reason") {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Object(map)) => map
            .keys()
            .next()
            .cloned()
            .unwrap_or_else(|| "unknown".to_string()),
        _ => "unknown".to_string(),
    }
}

/// Read the trailing `max` bytes of a file as lossy UTF-8, returning the
/// text and whether the file was larger than `max` (so the first
/// recovered line may be partial and should be dropped by the caller).
pub(super) fn read_tail(path: &Path, max: u64) -> Result<(String, bool)> {
    let mut file = std::fs::File::open(path)?;
    let len = file.metadata()?.len();
    let truncated = len > max;
    if truncated {
        file.seek(SeekFrom::Start(len - max))?;
    }
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    Ok((String::from_utf8_lossy(&bytes).into_owned(), truncated))
}
