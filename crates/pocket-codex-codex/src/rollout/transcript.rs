//! A rollout's full transcript as the rows the live conversation renders,
//! so a session can be viewed read-only without resuming it.

use std::{
    collections::{HashMap, HashSet},
    io::BufRead,
    path::Path,
};

use pocket_codex_core::Result;
use serde_json::Value;

use super::{message::split_message_content, non_empty};

mod activity;
mod plan;

/// One displayable item parsed from a rollout transcript, in the same
/// `{type, title, text}` shape the live conversation renders, so the
/// read-only session viewer can reuse that rendering.
#[derive(Debug, Clone)]
pub struct TranscriptItem {
    /// Stable row id (the source line index).
    pub id: String,
    /// Item kind aligned with app-server v2 (`userMessage`, `agentMessage`,
    /// `reasoning`, `commandExecution`, `mcpToolCall`, `fileChange`,
    /// `contextCompaction`, `plan`, and the other activity item variants).
    pub item_type: String,
    /// One-line title (the command for tool calls; empty for messages).
    pub title: String,
    /// Body text: message markdown, reasoning summary, or command output.
    pub text: String,
    /// Image URLs attached to a user message (`data:image/...;base64,...` —
    /// codex inlines attachments into the model request, so that is what the
    /// rollout records). Empty for every other item kind.
    pub images: Vec<String>,
}

impl TranscriptItem {
    /// A row without images.
    fn new(id: String, item_type: &str, title: impl Into<String>, text: impl Into<String>) -> Self {
        Self {
            id,
            item_type: item_type.to_string(),
            title: title.into(),
            text: text.into(),
            images: Vec::new(),
        }
    }
}

/// Parse a rollout's FULL transcript into displayable [`TranscriptItem`]s so
/// a session can be viewed read-only without resuming it. Maps codex's
/// on-disk `response_item` records:
///
/// * `message` (role `user` / `assistant`) → user / agent message
/// * `function_call` + its matching `function_call_output` (by `call_id`) → one
///   `commandExecution` item (title = command, text = output, ANSI stripped)
/// * `update_plan` tool calls → one evolving `plan` checklist per turn
/// * `reasoning` with a non-empty `summary` → a reasoning item
///
/// Modern `event_msg.item_completed` records contribute the richer app-server
/// activity variants (MCP/dynamic tools, agent collaboration, search, image
/// work, waits, hooks, and review-mode transitions). The `turn_context`
/// records written at each turn boundary become
/// synthetic `turnContext` items so the viewer can show WHICH model (and
/// effort / permissions) actually handled each turn — the read-only analogue
/// of the live conversation's per-turn model stamp.
///
/// Encrypted reasoning (no readable `summary`), redundant lifecycle edges and
/// token events are skipped. Unreadable lines are skipped rather than failing
/// the whole read, so a partially-written rollout (one a live writer is
/// appending to) still renders what is parseable.
pub fn read_transcript(path: &Path) -> Result<Vec<TranscriptItem>> {
    let reader = super::open_rollout(path)?;
    let mut transcript = Transcript::default();
    for (idx, line) in reader.lines().enumerate() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if let Some(payload) = value.get("payload") {
            let line_type = value.get("type").and_then(Value::as_str);
            transcript.record(format!("t{idx}"), line_type, payload);
        }
    }
    Ok(transcript.rows)
}

/// The rows read so far, and where later records amend them.
#[derive(Default)]
struct Transcript {
    rows: Vec<TranscriptItem>,
    /// Row of the `commandExecution` awaiting its output, by call_id.
    pending: HashMap<String, usize>,
    /// Direct `update_plan` calls still produce a function-call output. Once
    /// rendered as a plan, suppress that otherwise-empty command row.
    plan_outputs: HashSet<String>,
    /// A Guardian review's row shows its latest status.
    reviews: HashMap<String, usize>,
    /// The agent can update the same plan several times during one turn.
    /// Keep the latest snapshot in one row, matching the live app-server.
    plans: HashMap<String, usize>,
    /// Some rollout producers persist both lifecycle edges of a compaction.
    /// Keep a single row and mark it complete in place; current codex
    /// versions persist only the completed edge.
    compactions: HashMap<String, usize>,
}

impl Transcript {
    fn record(&mut self, id: String, line_type: Option<&str>, payload: &Value) {
        match line_type {
            Some("turn_context") => self.turn_context(id, payload),
            Some("event_msg") => self.event(id, payload),
            Some("response_item") => self.response_item(id, payload),
            _ => {},
        }
    }

    fn turn_context(&mut self, id: String, payload: &Value) {
        let Some(item) = turn_context_item(id, payload) else {
            return;
        };
        // Consecutive context records with no displayable item between them
        // (e.g. mid-turn settings updates) collapse to the LAST — the
        // effective one — so each rendered caption marks a real turn
        // boundary. Popping is safe: no index map refers to a turnContext
        // row, and only a trailing one is ever removed, so no stored index
        // shifts.
        if self
            .rows
            .last()
            .is_some_and(|prev| prev.item_type == "turnContext")
        {
            self.rows.pop();
        }
        self.rows.push(item);
    }

    fn event(&mut self, id: String, payload: &Value) {
        if let Some(review) = guardian_review(payload) {
            let item = TranscriptItem::new(
                format!("auto-review:{}", review["reviewId"].as_str().unwrap_or_default()),
                "autoApprovalReview",
                review["review"]["status"].as_str().unwrap_or_default(),
                review.to_string(),
            );
            upsert(&mut self.rows, &mut self.reviews, item);
            return;
        }
        let Some(item) = payload.get("item") else {
            return;
        };
        let event_type = payload.get("type").and_then(Value::as_str);
        if item.get("type").and_then(Value::as_str) == Some("ContextCompaction") {
            let id = item
                .get("id")
                .and_then(Value::as_str)
                .map_or(id, str::to_string);
            match event_type {
                Some("item_started") if !self.compactions.contains_key(&id) => {
                    let row = TranscriptItem::new(id, "contextCompaction", "inProgress", "");
                    upsert(&mut self.rows, &mut self.compactions, row);
                },
                Some("item_completed") => {
                    let row = TranscriptItem::new(id, "contextCompaction", "", "");
                    upsert(&mut self.rows, &mut self.compactions, row);
                },
                _ => {},
            }
            return;
        }
        if event_type == Some("item_completed") {
            if let Some(row) = activity::completed_activity_item(item, id) {
                self.rows.push(row);
            }
        }
    }

    fn response_item(&mut self, id: String, payload: &Value) {
        let call_id = payload.get("call_id").and_then(Value::as_str);
        match payload.get("type").and_then(Value::as_str) {
            Some("message") => self.message(id, payload),
            Some("function_call") => {
                if let Some(plan) = plan::snapshot(payload, &id) {
                    if let Some(call_id) = call_id {
                        self.plan_outputs.insert(call_id.to_string());
                    }
                    upsert(&mut self.rows, &mut self.plans, plan);
                    return;
                }
                if let Some(call_id) = call_id {
                    self.pending.insert(call_id.to_string(), self.rows.len());
                }
                let title = command_title(payload);
                self.rows
                    .push(TranscriptItem::new(id, "commandExecution", title, ""));
            },
            Some("custom_tool_call") => {
                if let Some(plan) = plan::snapshot(payload, &id) {
                    upsert(&mut self.rows, &mut self.plans, plan);
                }
            },
            Some("function_call_output") => {
                if call_id.is_some_and(|call_id| self.plan_outputs.remove(call_id)) {
                    return;
                }
                let output =
                    strip_ansi(payload.get("output").and_then(Value::as_str).unwrap_or(""));
                match call_id.and_then(|call_id| self.pending.get(call_id).copied()) {
                    // Merge the output into its originating command item.
                    Some(at) => self.rows[at].text = output,
                    None => self
                        .rows
                        .push(TranscriptItem::new(id, "commandExecution", "", output)),
                }
            },
            Some("reasoning") => {
                let summary = reasoning_summary(payload);
                if !summary.trim().is_empty() {
                    self.rows
                        .push(TranscriptItem::new(id, "reasoning", "", summary));
                }
            },
            _ => {},
        }
    }

    fn message(&mut self, id: String, payload: &Value) {
        // Fragment parts are already dropped by `split_message_content`, so a
        // message that was nothing but machinery arrives here empty.
        let (text, images) = split_message_content(payload);
        // Keep image-only user messages (empty text, ≥1 image) — they are
        // real turns; only fully empty messages are noise.
        if text.trim().is_empty() && images.is_empty() {
            return;
        }
        let item_type = match payload.get("role").and_then(Value::as_str) {
            Some("user") => "userMessage",
            Some("assistant") => "agentMessage",
            // `developer` and `system` messages are codex's own plumbing
            // (permission instructions, app context). They are not turns,
            // and calling them assistant replies puts wire text in the
            // model's mouth.
            _ => return,
        };
        // A voice handoff is kept VERBATIM here: it carries a whole stretch
        // of spoken turns, and the UI renders it as its own kind of card.
        // Only the one-line preview unwraps it.
        self.rows.push(TranscriptItem {
            images,
            ..TranscriptItem::new(id, item_type, "", text)
        });
    }
}

/// Replace the row with `item`'s id, or append it and remember where it is.
fn upsert(
    rows: &mut Vec<TranscriptItem>,
    index: &mut HashMap<String, usize>,
    item: TranscriptItem,
) {
    match index.get(&item.id) {
        Some(&at) => rows[at] = item,
        None => {
            index.insert(item.id.clone(), rows.len());
            rows.push(item);
        },
    }
}

/// Normalize a persisted Guardian lifecycle into the app-server notification
/// shape. Only explicit Guardian records authorize this display-only
/// interpretation.
pub fn guardian_review(payload: &Value) -> Option<Value> {
    if payload.get("type").and_then(Value::as_str) != Some("guardian_assessment") {
        return None;
    }
    let id = payload.get("id")?.as_str().filter(|id| !id.is_empty())?;
    let status = match payload.get("status")?.as_str()? {
        "in_progress" => "inProgress",
        "timed_out" => "timedOut",
        other => other,
    };
    Some(serde_json::json!({
        "reviewId": id, "turnId": payload.get("turn_id"),
        "targetItemId": payload.get("target_item_id"),
        "startedAtMs": payload.get("started_at_ms"),
        "completedAtMs": payload.get("completed_at_ms"),
        "review": {"status": status, "riskLevel": payload.get("risk_level"),
            "userAuthorization": payload.get("user_authorization"), "rationale": payload.get("rationale")},
        "action": payload.get("action"),
    }))
}

/// Map a `turn_context` record to a synthetic `turnContext` item: `title` =
/// the model handling the turn, `text` = a compact JSON object with the rest
/// of the effective settings (`effort`, `approvalPolicy`, `sandboxMode`,
/// `collaborationMode`; a key is absent when the rollout didn't record it).
/// Reusing the existing `{type, title, text}` row shape — exactly like the
/// live view's `plan` item — keeps the wire format (host-svc `TranscriptItem`,
/// bridge DTOs) untouched, and an older client renders an unknown type as a
/// generic activity row instead of failing.
///
/// Rollouts store codex-core serde shapes: snake_case fields, kebab-case
/// approval strings (`never`, `on-request`, …; the granular variant is an
/// externally-tagged object) and an internally-tagged sandbox policy whose
/// `type` values (`read-only`, `workspace-write`, `danger-full-access`) match
/// the app's wire strings directly. `model`/`effort` live at the top level,
/// mirrored inside `collaboration_mode.settings` (used as fallback for older
/// records). No model at all → nothing worth a caption → `None`.
fn turn_context_item(id: String, payload: &Value) -> Option<TranscriptItem> {
    let collab = payload.get("collaboration_mode");
    let collab_settings = collab.and_then(|c| c.get("settings"));
    let model = non_empty(payload.get("model"))
        .or_else(|| non_empty(collab_settings.and_then(|s| s.get("model"))))?;
    let effort = non_empty(payload.get("effort"))
        .or_else(|| non_empty(collab_settings.and_then(|s| s.get("reasoning_effort"))));
    // Approval: a plain kebab string, or the externally-tagged `granular`
    // object → its tag.
    let approval = payload.get("approval_policy").and_then(|v| {
        non_empty(Some(v)).or_else(|| v.as_object().and_then(|o| o.keys().next().cloned()))
    });
    let sandbox = payload.get("sandbox_policy").and_then(|v| {
        non_empty(v.get("type"))
            // Tolerate a bare-string form, should the on-disk shape drift.
            .or_else(|| non_empty(Some(v)))
    });
    let collab_mode = non_empty(collab.and_then(|c| c.get("mode")));
    let mut details = serde_json::Map::new();
    for (key, value) in [
        ("effort", effort),
        ("approvalPolicy", approval),
        ("sandboxMode", sandbox),
        ("collaborationMode", collab_mode),
    ] {
        if let Some(value) = value {
            details.insert(key.to_string(), Value::String(value));
        }
    }
    Some(TranscriptItem::new(id, "turnContext", model, Value::Object(details).to_string()))
}

/// One-line title for a `function_call`: the shell command when present,
/// else the tool name. `arguments` is a JSON *string* that must be
/// re-parsed; `command` may be a string or an argv array.
fn command_title(payload: &Value) -> String {
    let name = payload
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("tool");
    let args: Option<Value> = payload
        .get("arguments")
        .and_then(Value::as_str)
        .and_then(|s| serde_json::from_str(s).ok());
    if let Some(args) = args.as_ref() {
        match args.get("command") {
            Some(Value::String(s)) => return s.clone(),
            Some(Value::Array(parts)) => {
                let joined = parts
                    .iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(" ");
                if !joined.is_empty() {
                    return joined;
                }
            },
            _ => {},
        }
    }
    name.to_string()
}

/// Join a `reasoning` payload's `summary[].text`. codex stores the model's
/// raw reasoning under `encrypted_content` (unreadable); only the optional
/// `summary` is human-readable, and is often empty.
fn reasoning_summary(payload: &Value) -> String {
    payload
        .get("summary")
        .and_then(Value::as_array)
        .map(|parts| {
            parts
                .iter()
                .filter_map(|p| p.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

/// Strip ANSI/VT escape sequences (CSI `ESC [ … final-byte` and a few
/// common others) from command output so it reads cleanly in the UI.
/// Avoids a regex dependency; keeps everything else verbatim.
fn strip_ansi(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            out.push(c);
            continue;
        }
        match chars.peek() {
            // CSI: ESC [ ... <final byte 0x40..=0x7E>
            Some('[') => {
                chars.next();
                for ec in chars.by_ref() {
                    if ('\u{40}'..='\u{7e}').contains(&ec) {
                        break;
                    }
                }
            },
            // OSC: ESC ] ... terminated by BEL or ESC \
            Some(']') => {
                chars.next();
                while let Some(ec) = chars.next() {
                    if ec == '\u{7}' {
                        break;
                    }
                    if ec == '\u{1b}' {
                        chars.next(); // consume the trailing backslash
                        break;
                    }
                }
            },
            // Lone ESC or two-char sequence: drop the next char.
            _ => {
                chars.next();
            },
        }
    }
    out
}

#[cfg(test)]
mod tests;
