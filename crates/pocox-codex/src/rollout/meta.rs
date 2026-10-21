//! A rollout's session header and the thread hierarchy Codex records.

use serde_json::Value;

use super::non_empty;

/// Session header parsed from a rollout's first `session_meta` line.
#[derive(Debug, Clone)]
pub struct SessionMeta {
    /// Thread / conversation id (equals the UUID embedded in the rollout
    /// filename).
    pub id: String,
    /// Working directory the session controls, when recorded.
    pub cwd: Option<String>,
    /// Client that created the session (`cli` / `vscode` / …), when
    /// recorded. Useful for badging "from desktop app" in the UI.
    pub source: Option<String>,
    /// Parent thread recorded by Codex for spawned sessions.
    pub parent_thread_id: Option<String>,
    /// Persisted thread classification, including Guardian reviewers.
    pub thread_source: Option<String>,
    /// The recorded `originator` string, when present.
    pub originator: Option<String>,
}

/// Parse a rollout's first line into [`SessionMeta`]; `None` when the
/// line is not a `session_meta` record or lacks an id.
pub(super) fn parse_session_meta(line: &str) -> Option<SessionMeta> {
    let value: Value = serde_json::from_str(line).ok()?;
    if value.get("type").and_then(Value::as_str)? != "session_meta" {
        return None;
    }
    let payload = value.get("payload")?;
    let id = payload.get("id").and_then(Value::as_str)?.to_string();
    Some(SessionMeta {
        id,
        cwd: non_empty(payload.get("cwd")),
        source: source_label(payload.get("source")),
        parent_thread_id: parent_thread_id(payload),
        thread_source: thread_source(payload),
        originator: non_empty(payload.get("originator")),
    })
}

/// Read the explicit parent link, including older thread-spawn headers.
pub fn parent_thread_id(value: &Value) -> Option<String> {
    value
        .get("parentThreadId")
        .or_else(|| value.get("parent_thread_id"))
        .and_then(Value::as_str)
        .or_else(|| {
            value
                .pointer("/source/subagent/thread_spawn/parent_thread_id")
                .or_else(|| value.pointer("/source/subAgent/thread_spawn/parent_thread_id"))
                .and_then(Value::as_str)
        })
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
}

/// Read an explicit classification; recognize the legacy Guardian source too.
pub fn thread_source(value: &Value) -> Option<String> {
    non_empty(
        value
            .get("threadSource")
            .or_else(|| value.get("thread_source")),
    )
    .or_else(|| {
        (value
            .pointer("/source/subagent/other")
            .or_else(|| value.pointer("/source/subAgent/other"))
            .and_then(Value::as_str)
            == Some("guardian"))
        .then(|| "guardian_review".into())
    })
}

/// Reduce a `source` value (a bare string, or an object with a `kind` /
/// `type` discriminant) to a short label.
fn source_label(source: Option<&Value>) -> Option<String> {
    match source? {
        Value::String(s) if !s.is_empty() => Some(s.clone()),
        Value::Object(map) => non_empty(map.get("kind").or_else(|| map.get("type"))),
        _ => None,
    }
}
