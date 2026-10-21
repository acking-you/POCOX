//! Mapping app-server notifications and thread items into bridge events and
//! display rows.

use super::*;

/// Stable per-turn id for the synthesized `plan` item. The evolving plan
/// streams as a `turn/plan/updated` notification (not a thread item), so it's
/// keyed off the turn. Shared by `map_event` (live) and `buffer_item` (resume)
/// so the two reconcile by id — no duplicate plan card after a re-open.
fn plan_item_id(params: &Value) -> String {
    let turn_id = params.get("turnId").and_then(Value::as_str).unwrap_or("");
    format!("plan-{turn_id}")
}

fn approval_review_item(params: &Value) -> Option<ThreadItem> {
    let id = params
        .get("reviewId")?
        .as_str()
        .filter(|id| !id.is_empty())?;
    let review = params.get("review")?.as_object()?;
    Some(ThreadItem {
        id: format!("auto-review:{id}"),
        item_type: "autoApprovalReview".into(),
        title: review
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .into(),
        text: params.to_string(),
        questions_json: None,
        images: Vec::new(),
        turn_id: params
            .get("turnId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .into(),
        turn_completed_at: None,
        turn_duration_ms: None,
    })
}

fn is_approval_review(method: &str) -> bool {
    matches!(method, "item/autoApprovalReview/started" | "item/autoApprovalReview/completed")
}

/// Retain streamed text and full item snapshots by id for resume and durable
/// checkpoints. A completed snapshot replaces its preceding deltas. The plan
/// notification has no item envelope and uses a stable per-turn identity.
pub(super) fn buffer_item(transcript: &Mutex<LiveTranscript>, inbound: &Inbound) {
    let Some(params) = inbound.params.as_ref() else {
        return;
    };
    let Some(thread_id) = params.get("threadId").and_then(Value::as_str) else {
        return;
    };
    // The evolving plan streams as a `turn/plan/updated` notification
    // (`params.plan`, no `params.item`), which the generic item path below
    // skips — so without this a resumed thread loses its plan card and the
    // proposal message re-reads as a misplaced plan. Buffer the same singleton
    // `plan` item `map_event` builds (stable id per turn) so `thread_read`
    // restores it at the tail, where it lived.
    // An item notification names its turn (`turnId`) and, on completion, when
    // the item itself finished (`completedAtMs`). The turn's own duration isn't
    // known until it closes, so that arrives later via `thread/read`.
    //
    // Read `turnId` only — NOT via `extract_turn_id`, whose `id` fallback would
    // pick up this notification's own item id here.
    let live_turn = TurnStamp {
        id: params
            .get("turnId")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        completed_at: params
            .get("completedAtMs")
            .and_then(Value::as_i64)
            .map(|ms| ms / 1000),
        duration_ms: None,
    };
    if matches!(
        inbound.method.as_str(),
        "item/agentMessage/delta"
            | "item/commandExecution/outputDelta"
            | "item/reasoning/textDelta"
            | "item/reasoning/summaryTextDelta"
    ) {
        let Some(id) = params
            .get("itemId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
        else {
            return;
        };
        let Some((item_type, title, text)) = summarize_item_notification(&inbound.method, params)
        else {
            return;
        };
        let Ok(mut map) = transcript.lock() else { return };
        if !map.append(thread_id, id, &text) {
            map.upsert(thread_id, ThreadItem {
                id: id.into(),
                item_type,
                title,
                text,
                questions_json: None,
                images: Vec::new(),
                turn_id: live_turn.id,
                turn_completed_at: None,
                turn_duration_ms: None,
            });
        }
        return;
    }
    let mut parsed = if is_approval_review(&inbound.method) {
        let Some(item) = approval_review_item(params) else { return };
        item
    } else if inbound.method == "turn/plan/updated" {
        ThreadItem {
            id: plan_item_id(params),
            item_type: "plan".to_string(),
            title: String::new(),
            text: encode_plan(params),
            questions_json: None,
            images: Vec::new(),
            turn_id: live_turn.id.clone(),
            turn_completed_at: None,
            turn_duration_ms: None,
        }
    } else {
        let Some(parsed) = params
            .get("item")
            .and_then(|i| parse_turn_item(i, &live_turn))
        else {
            return;
        };
        parsed
    };
    if inbound.method == "item/completed" {
        parsed.questions_json = params
            .get("item")
            .and_then(|item| item.get("questions"))
            .filter(|value| value.is_array())
            .map(Value::to_string);
    }
    if parsed.id.is_empty() {
        return;
    }
    let mut map = transcript.lock().expect("transcript poisoned");
    map.upsert(thread_id, parsed);
}

/// Map an inbound server message to a flattened [`AppEvent`].
pub(super) fn map_event(inbound: Inbound) -> AppEvent {
    let mut params = inbound.params.unwrap_or(Value::Null);
    if is_approval_review(&inbound.method) {
        if let Some(item) = approval_review_item(&params) {
            return AppEvent {
                kind: inbound.method,
                thread_id: params
                    .get("threadId")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                item_id: Some(item.id),
                item_type: Some(item.item_type),
                title: Some(item.title),
                text: Some(item.text),
                images: Vec::new(),
                request_id: None,
                raw: params.to_string(),
            };
        }
    }
    // v2 streams the evolving plan via a top-level notification (`params.plan`),
    // not as a thread item, so the generic item path below never sees it.
    // Synthesize a per-turn singleton `plan` item (stable id keyed on the turn)
    // so the plan card + implement-prompt render it exactly like thread history.
    if inbound.method == "turn/plan/updated" {
        return AppEvent {
            kind: inbound.method.clone(),
            thread_id: params
                .get("threadId")
                .and_then(Value::as_str)
                .map(str::to_string),
            item_id: Some(plan_item_id(&params)),
            item_type: Some("plan".to_string()),
            title: None,
            text: Some(encode_plan(&params)),
            images: Vec::new(),
            request_id: inbound.request_id,
            raw: params.to_string(),
        };
    }
    let item = params.get("item");
    // Most lifecycle notifications carry a full item snapshot. Output/progress
    // notifications do not, but they still name the item in their method and
    // carry useful live text. Normalize both shapes so the Flutter transcript
    // can update command output, reasoning, patches, and MCP progress in place.
    let summary = item
        .map(summarize_item)
        .or_else(|| summarize_item_notification(&inbound.method, &params));
    let (item_type, title) = match &summary {
        Some((t, ti, _)) => (Some(t.clone()), Some(ti.clone())),
        None => (None, None),
    };
    let text = if inbound.method.contains("failed") || inbound.method.contains("error") {
        error_message(&params).or_else(|| summary.as_ref().map(|(_, _, tx)| tx.clone()))
    } else if let Some(d) = params.get("delta").and_then(Value::as_str) {
        // Streaming delta chunk (e.g. item/agentMessage/delta).
        Some(d.to_string())
    } else {
        summary
            .as_ref()
            .map(|(_, _, tx)| tx.clone())
            .filter(|s| !s.is_empty())
            .or_else(|| {
                params
                    .get("text")
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
    };
    let mut event = AppEvent {
        kind: inbound.method.clone(),
        thread_id: params
            .get("threadId")
            .and_then(Value::as_str)
            .map(str::to_string),
        item_id: params
            .get("itemId")
            .and_then(Value::as_str)
            .or_else(|| item.and_then(|i| i.get("id")).and_then(Value::as_str))
            .map(str::to_string),
        item_type,
        title,
        text,
        images: item.map(item_images).unwrap_or_default(),
        request_id: inbound.request_id,
        raw: String::new(),
    };
    if event.item_type.as_deref() == Some("imageGeneration") {
        if let Some(item) = params.get_mut("item").and_then(Value::as_object_mut) {
            // Images already have a bounded DTO field; never duplicate the
            // upstream base64 payload through the raw notification channel.
            item.remove("result");
        }
    }
    event.raw = params.to_string();
    event
}

/// Summarize an item-scoped notification that does not include `params.item`.
///
/// App-server v2 emits the complete item only at lifecycle edges. Keeping the
/// intermediate shapes here aligned with [`summarize_item`] lets clients show
/// more than a spinner while a command, reasoning block, patch, or MCP call is
/// actively producing output.
fn summarize_item_notification(method: &str, params: &Value) -> Option<(String, String, String)> {
    let item_type = if method.contains("agentMessage") {
        "agentMessage"
    } else if method.contains("reasoning") {
        "reasoning"
    } else if method.contains("commandExecution") {
        "commandExecution"
    } else if method.contains("fileChange") {
        "fileChange"
    } else if method.contains("mcpToolCall") {
        "mcpToolCall"
    } else if method.contains("plan") {
        "plan"
    } else {
        return None;
    };

    if method == "item/fileChange/patchUpdated" {
        let snapshot = json!({
            "type": "fileChange",
            "changes": params.get("changes").cloned().unwrap_or_else(|| json!([])),
        });
        return Some(summarize_item(&snapshot));
    }

    let text = params
        .get("delta")
        .or_else(|| params.get("message"))
        .or_else(|| params.get("text"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    Some((item_type.to_string(), String::new(), text))
}

/// Pull a human error string out of `{error:{message}}` / `{error}` /
/// `{message}`.
fn error_message(params: &Value) -> Option<String> {
    if let Some(m) = params
        .get("error")
        .and_then(|e| e.get("message"))
        .and_then(Value::as_str)
    {
        return Some(m.to_string());
    }
    if let Some(e) = params.get("error").and_then(Value::as_str) {
        return Some(e.to_string());
    }
    params
        .get("message")
        .and_then(Value::as_str)
        .map(str::to_string)
}

/// [`parse_turn_item`] with no turn envelope — for tests that exercise item
/// parsing itself, where the turn stamp is not what is under test.
#[cfg(test)]
pub(super) fn parse_item(item: &Value) -> Option<ThreadItem> {
    parse_turn_item(item, &TurnStamp::default())
}

/// The turn-level facts every item in a `thread/read` turn payload inherits.
///
/// `ThreadItem` carries no time of its own in the protocol — the timestamps
/// live on the enclosing `Turn` (`startedAt` / `completedAt` / `durationMs`),
/// so they have to be stamped onto each item as the turns are flattened or
/// they are lost.
#[derive(Clone, Debug, Default)]
pub(super) struct TurnStamp {
    pub(super) id: String,
    pub(super) completed_at: Option<i64>,
    pub(super) duration_ms: Option<i64>,
}

pub(super) fn turn_stamp(stamps: &HashMap<String, TurnStamp>, turn_id: &str) -> TurnStamp {
    stamps.get(turn_id).cloned().unwrap_or_else(|| TurnStamp {
        id: turn_id.to_string(),
        ..TurnStamp::default()
    })
}

impl TurnStamp {
    /// Read the stamp off a `Turn` object.
    pub(super) fn of(turn: &Value) -> Self {
        Self {
            id: turn
                .get("id")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            completed_at: turn.get("completedAt").and_then(Value::as_i64),
            duration_ms: turn.get("durationMs").and_then(Value::as_i64),
        }
    }
}

pub(super) fn parse_turn_items(item: &Value, turn: &TurnStamp) -> Vec<ThreadItem> {
    let mut reviews = item
        .get("autoApprovalReviews")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(approval_review_item)
        .filter(|review| review.turn_id == turn.id)
        .collect::<Vec<_>>();
    if let Some(parsed) = parse_turn_item(item, turn) {
        if parsed.item_type == "userMessage" {
            reviews.insert(0, parsed);
        } else {
            reviews.push(parsed);
        }
    }
    reviews
}

pub(super) fn parse_turn_item(item: &Value, turn: &TurnStamp) -> Option<ThreadItem> {
    item.get("type").and_then(Value::as_str)?;
    let id = item
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let (item_type, title, text) = summarize_item(item);
    Some(ThreadItem {
        id,
        item_type,
        title,
        text,
        questions_json: None,
        images: item_images(item),
        turn_id: turn.id.clone(),
        turn_completed_at: turn.completed_at,
        turn_duration_ms: turn.duration_ms,
    })
}

/// Encode a plan payload (`{explanation, plan:[{step,status}]}`) into the
/// `explanation` + `- [x|~| ] step` lines the Flutter plan card parses. Accepts
/// both the snake_case `in_progress` (thread-history items) and the camelCase
/// `inProgress` (the v2 `turn/plan/updated` notification) status tokens. Falls
/// back to a `text` field, then empty.
pub(in crate::engine) fn encode_plan(v: &Value) -> String {
    let explanation = v
        .get("explanation")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    let steps: Vec<String> = v
        .get("plan")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|p| {
                    let step = p.get("step").and_then(Value::as_str)?;
                    let mark = match p.get("status").and_then(Value::as_str) {
                        Some("completed") => "x",
                        Some("in_progress") | Some("inProgress") => "~",
                        _ => " ",
                    };
                    Some(format!("- [{mark}] {step}"))
                })
                .collect()
        })
        .unwrap_or_default();
    if steps.is_empty() {
        if explanation.is_empty() {
            v.get("text")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string()
        } else {
            explanation
        }
    } else if explanation.is_empty() {
        steps.join("\n")
    } else {
        format!("{explanation}\n{}", steps.join("\n"))
    }
}

/// Reduce a `ThreadItem` JSON value to `(type, one-line title, detail text)`
/// for the UI. Messages return an empty title (their `text` is the body); tool
/// / activity items return a human title (command, query, tool name, …) and a
/// detail body (output, args, result, paths) shown in an expandable card.
pub(super) fn summarize_item(item: &Value) -> (String, String, String) {
    let item_type = item
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_string();
    let s = |k: &str| {
        item.get(k)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    };
    let (title, text) = match item_type.as_str() {
        "agentMessage" => (String::new(), s("text")),
        // A plan is a structured checklist (`{explanation, plan:[{step,status}]}`).
        // Encode it as `explanation` + one `- [x|~| ] step` line per step so the
        // UI can render a status-iconed checklist; fall back to plain text.
        "plan" => (String::new(), encode_plan(item)),
        "userMessage" => (
            String::new(),
            item.get("content")
                .and_then(Value::as_array)
                .map(|c| {
                    c.iter()
                        .filter_map(|p| p.get("text").and_then(Value::as_str))
                        .collect::<Vec<_>>()
                        .join("")
                })
                .unwrap_or_default(),
        ),
        "reasoning" => {
            let join = |k: &str| {
                item.get(k)
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .filter_map(Value::as_str)
                            .collect::<Vec<_>>()
                            .join("\n")
                    })
                    .unwrap_or_default()
            };
            let content = join("content");
            let body = if content.is_empty() { join("summary") } else { content };
            (String::new(), body)
        },
        "commandExecution" => {
            let mut detail = item
                .get("aggregatedOutput")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            if let Some(code) = item.get("exitCode").and_then(Value::as_i64) {
                detail = format!("{detail}\n[exit {code}]");
            }
            (s("command"), detail.trim().to_string())
        },
        "hookPrompt" => {
            let fragments = item
                .get("fragments")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let title = fragments
                .iter()
                .filter_map(|fragment| fragment.get("hookRunId").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join(", ");
            let text = fragments
                .iter()
                .filter_map(|fragment| fragment.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n");
            (title, text)
        },
        "webSearch" => (s("query"), selected_json(item, &["action", "results"])),
        "fileChange" => {
            let changes = item
                .get("changes")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let paths: Vec<String> = changes
                .iter()
                .filter_map(|c| c.get("path").and_then(Value::as_str).map(str::to_string))
                .collect();
            let title = match paths.as_slice() {
                [one] => one.clone(),
                _ => format!("{} files", changes.len()),
            };
            // App-server update diffs contain hunks but no file markers, while
            // add/delete diffs contain raw file contents. Normalize each shape
            // before handing it to the UI's unified-diff parser.
            let diffs: Vec<String> = changes
                .iter()
                .filter_map(normalize_file_change_diff)
                .collect();
            let detail = if diffs.is_empty() { paths.join("\n") } else { diffs.join("\n") };
            (title, detail)
        },
        "mcpToolCall" => {
            let title = format!("{}.{}", s("server"), s("tool"));
            (title, selected_json(item, &["arguments", "appContext", "result", "error"]))
        },
        "dynamicToolCall" => {
            let namespace = s("namespace");
            let tool = s("tool");
            let title = if namespace.is_empty() { tool } else { format!("{namespace}.{tool}") };
            (title, selected_json(item, &["arguments", "contentItems", "success"]))
        },
        "collabAgentToolCall" => (
            s("tool"),
            selected_json(item, &[
                "status",
                "prompt",
                "model",
                "reasoningEffort",
                "receiverThreadIds",
                "agentsStates",
            ]),
        ),
        "subAgentActivity" => (
            s("kind"),
            selected_json(item, &["agentPath", "agentThreadId", "model", "reasoningEffort"]),
        ),
        "imageView" => (s("path"), String::new()),
        "sleep" => {
            let duration = item.get("durationMs").and_then(Value::as_u64).unwrap_or(0);
            (format!("{duration} ms"), String::new())
        },
        "imageGeneration" => {
            let title = ["revisedPrompt", "savedPath", "status"]
                .into_iter()
                .find_map(|field| item.get(field).and_then(Value::as_str))
                .unwrap_or("")
                .to_string();
            (
                title,
                // `result` can be a very large base64 image. The saved path,
                // status, and failure are the useful transcript details.
                selected_json(item, &["status", "savedPath", "failure"]),
            )
        },
        "enteredReviewMode" | "exitedReviewMode" => (s("review"), String::new()),
        // Unknown / other item types: best-effort text grab.
        _ => (
            item_type.clone(),
            item.get("text")
                .and_then(Value::as_str)
                .map(str::to_string)
                .or_else(|| recursive_text(item))
                .unwrap_or_default(),
        ),
    };
    (item_type, title, text)
}

/// Pretty-print a small, ordered subset of an item's structured fields.
/// Null/absent fields are omitted so an expandable activity row stays useful
/// without dumping the entire protocol object (which may include image bytes).
fn selected_json(item: &Value, fields: &[&str]) -> String {
    let mut selected = serde_json::Map::new();
    for field in fields {
        if let Some(value) = item.get(field).filter(|value| !value.is_null()) {
            selected.insert((*field).to_string(), value.clone());
        }
    }
    if selected.is_empty() {
        return String::new();
    }
    serde_json::to_string_pretty(&Value::Object(selected))
        .unwrap_or_else(|_| Value::Object(serde_json::Map::new()).to_string())
}

fn normalize_file_change_diff(change: &Value) -> Option<String> {
    let raw = change
        .get("diff")
        .and_then(Value::as_str)
        .filter(|diff| !diff.trim().is_empty())?;
    if raw.lines().any(|line| line.starts_with("--- "))
        && raw.lines().any(|line| line.starts_with("+++ "))
    {
        return Some(raw.to_string());
    }

    let path = change.get("path").and_then(Value::as_str)?;
    let kind = change.get("kind");
    let kind_type = kind
        .and_then(|value| value.get("type").and_then(Value::as_str))
        .or_else(|| kind.and_then(Value::as_str))
        .unwrap_or("update");
    let body = raw.trim_end_matches(['\r', '\n']);
    match kind_type {
        "add" => Some(format_content_diff(path, body, true)),
        "delete" => Some(format_content_diff(path, body, false)),
        _ => {
            let new_path = kind
                .and_then(|value| value.get("movePath"))
                .and_then(Value::as_str)
                .unwrap_or(path);
            Some(format!("--- a/{path}\n+++ b/{new_path}\n{body}"))
        },
    }
}

pub(in crate::engine) fn format_content_diff(path: &str, content: &str, added: bool) -> String {
    let lines: Vec<&str> = content.lines().collect();
    let count = lines.len();
    let (old_path, new_path, hunk, marker) = if added {
        ("/dev/null".to_string(), format!("b/{path}"), format!("@@ -0,0 +1,{count} @@"), '+')
    } else {
        (format!("a/{path}"), "/dev/null".to_string(), format!("@@ -1,{count} +0,0 @@"), '-')
    };
    let mut diff = format!("--- {old_path}\n+++ {new_path}\n{hunk}");
    for line in lines {
        diff.push('\n');
        diff.push(marker);
        diff.push_str(line);
    }
    diff
}

/// Image URLs attached to a `userMessage` item's `content` array. A v2
/// `{"type":"image"}` input carries the renderable `url` (a `data:image/...`
/// base64 URL for anything sent by this app); a `{"type":"localImage"}` input
/// (a host-side codex client attached a file) carries only the HOST filesystem
/// `path`, which the UI can resolve through the host's file service.
/// `fileId` references have no downloadable URL in this protocol. Preserve
/// them as `codex-file:` references so the UI can show an unavailable preview
/// without treating an opaque cloud ID as a host filesystem path.
pub(super) fn item_images(item: &Value) -> Vec<String> {
    if item.get("type").and_then(Value::as_str) == Some("imageGeneration") {
        return pocox_codex::protocol::image_generation_images(item);
    }
    if item.get("type").and_then(Value::as_str) != Some("userMessage") {
        return Vec::new();
    }
    item.get("content")
        .and_then(Value::as_array)
        .map(|c| {
            c.iter()
                .filter_map(|p| match p.get("type").and_then(Value::as_str) {
                    Some("image") => p
                        .get("url")
                        .and_then(Value::as_str)
                        .map(str::to_string)
                        .or_else(|| {
                            p.get("fileId")
                                .and_then(Value::as_str)
                                .map(|id| format!("codex-file:{id}"))
                        }),
                    Some("localImage") => p.get("path").and_then(Value::as_str).map(str::to_string),
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default()
}

fn recursive_text(v: &Value) -> Option<String> {
    match v {
        Value::Object(m) => {
            if let Some(Value::String(t)) = m.get("text") {
                if !t.trim().is_empty() {
                    return Some(t.clone());
                }
            }
            m.values().find_map(recursive_text)
        },
        Value::Array(a) => a.iter().find_map(recursive_text),
        _ => None,
    }
}
