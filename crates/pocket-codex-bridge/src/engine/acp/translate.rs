//! Gateway events → the item and event shapes the shared session UI renders.
//!
//! Only what ACP actually carries is produced: no Codex approval policy,
//! sandbox, Guardian review, turn timing or model catalog is synthesized.
//! Agent permission requests become `acp/permission/requested` (answered
//! with the agent's own option ids), not Codex approval kinds.
//!
//! Recovery (a reconnect or a `reset`) never patches the UI with deltas it
//! cannot vouch for: a rebuilt fold is announced with the full text of each
//! item (which replaces what the UI shows), and a turn that ended while
//! this controller was away is completed from the host's final fold. Turns
//! that ended are completed *before* their successors are announced, and
//! every item event names its turn, so a late completion can never end or
//! regroup a newer turn.
//!
//! Content the host could not keep (an oversized image, diff or input) or
//! that this controller could not read (`unavailable`) appears as a
//! `contentOmitted` item next to where it belongs, never as silence. A
//! notice is state of the item it belongs to: when a later update of that
//! tool call or plan replaces the content with one that fits, the notice is
//! sent again empty, which removes it.
//!
//! # Identifiers
//!
//! Folded items carry the host's ids, which start with a host turn id
//! (`<uuid>:…`, `replay:<n>:…`) or with `tool:` followed by the agent's own
//! tool call id — any string. Items synthesized here (notices, gaps) use ids
//! starting with `#` ([`synthetic_id`]), which no folded id does, so an
//! agent can never name a tool call that collides with one.

use std::collections::{HashMap, HashSet};

use pocket_codex_host_svc::acp::fold::{Change, Item, ItemKind, Tool, Turn};
use serde::Deserialize as _;
use serde_json::{json, Value};

use super::Shared;
use crate::engine::app_session::{encode_plan, format_content_diff, AppEvent, ThreadItem};

/// Event kind of an agent permission request.
pub const PERMISSION_REQUESTED: &str = "acp/permission/requested";
/// Event kind of a session settings / state change.
pub const SESSION_UPDATED: &str = "acp/session/updated";
/// Event kind of a host phase / generation / reachability change.
pub const HOST_STATE: &str = "acp/host/state";
/// Most live folds kept per connection (running turns are always kept).
const MAX_LIVE: usize = 16;

pub(super) fn event(kind: &str, thread: Option<&str>, raw: Value) -> AppEvent {
    AppEvent {
        kind: kind.to_string(),
        thread_id: thread.map(str::to_string),
        item_id: None,
        item_type: None,
        title: None,
        text: None,
        images: Vec::new(),
        request_id: None,
        raw: raw.to_string(),
    }
}

fn str_of<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key].as_str().unwrap_or("")
}

fn diff_text(path: &str, old: Option<&str>, new: &str) -> String {
    match old {
        None => format_content_diff(path, new, true),
        Some(old) => {
            let mut diff = format!(
                "--- a/{path}\n+++ b/{path}\n@@ -1,{} +1,{} @@",
                old.lines().count(),
                new.lines().count()
            );
            for line in old.lines() {
                diff.push_str(&format!("\n-{line}"));
            }
            for line in new.lines() {
                diff.push_str(&format!("\n+{line}"));
            }
            diff
        },
    }
}

/// The shared-UI item for one folded ACP item.
pub fn app_item(item: &Item, turn: &str) -> ThreadItem {
    let (item_type, title, text) = match item.kind {
        ItemKind::UserMessage => ("userMessage", String::new(), item.text.clone()),
        ItemKind::AgentMessage => ("agentMessage", String::new(), item.text.clone()),
        ItemKind::Thought => ("reasoning", String::new(), item.text.clone()),
        ItemKind::Plan => {
            let plan: Vec<Value> = item
                .plan
                .iter()
                .flatten()
                .map(|entry| json!({"step": entry.content, "status": entry.status}))
                .collect();
            ("plan", String::new(), encode_plan(&json!({"plan": plan})))
        },
        ItemKind::ToolCall => tool_parts(item),
    };
    ThreadItem {
        id: item.id.clone(),
        item_type: item_type.to_string(),
        title,
        text,
        questions_json: None,
        images: item.images.clone(),
        turn_id: turn.to_string(),
        // ACP carries no turn timing; nothing is invented.
        turn_completed_at: None,
        turn_duration_ms: None,
    }
}

/// The `dynamicToolCall` detail, serialized from borrows. Fields are in the
/// key order of the sorted JSON object this text has always had.
#[derive(serde::Serialize)]
struct ToolDetail<'a> {
    input: Option<&'a Value>,
    output: &'a str,
    tool: &'a str,
}

fn tool_parts(item: &Item) -> (&'static str, String, String) {
    let missing = Tool::default();
    let tool = item.tool.as_ref().unwrap_or(&missing);
    let mut text = item.text.clone();
    if tool.terminals > 0 {
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str("[terminal output is not available in this client]");
    }
    if tool.status == "failed" {
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str("[failed]");
    }
    // The agent's own finer kind (Grok's `x.ai/tool`) tells more apart than
    // ACP's: a listing is ACP `other`, a web search ACP `search`.
    let kind = match (tool.category.as_deref(), tool.kind.as_str()) {
        (Some("execute" | "monitor"), _) | (None, "execute") => "execute",
        (Some("read" | "memory_get"), _) | (None, "read") => "read",
        (Some("list" | "list_dir"), _) => "list",
        (Some("search" | "memory_search" | "lsp"), _) | (None, "search") => "search",
        (Some("web_search" | "web_fetch"), _) | (None, "fetch") => "web",
        (Some("task" | "active_agent_message"), _) => "subagent",
        (Some("plan"), _) => "plan",
        // Grok calls MCP tools through its `use_tool`.
        (Some("use_tool"), _) => "mcp",
        (Some("image_gen" | "video_gen" | "image_to_video" | "reference_to_video"), _) => {
            "generate"
        },
        (_, kind) => kind,
    };
    let dynamic = |item_type: &'static str| {
        let detail = ToolDetail {
            input: tool.raw_input.as_ref(),
            output: &text,
            tool: tool.name.as_deref().unwrap_or(&tool.kind),
        };
        // reason: a struct of strings and a JSON value always serializes.
        let detail = serde_json::to_string(&detail).expect("serializable");
        (item_type, item.title.clone(), detail)
    };
    match kind {
        "execute" => ("commandExecution", item.title.clone(), text),
        "read" => ("fileRead", item.title.clone(), text),
        "list" => ("fileList", item.title.clone(), text),
        "search" => ("fileSearch", item.title.clone(), text),
        "web" => ("webSearch", item.title.clone(), text),
        "plan" => ("planUpdate", item.title.clone(), text),
        "subagent" => dynamic("subAgentActivity"),
        "mcp" => {
            let (_, title, detail) = dynamic("mcpToolCall");
            // `<server>__<tool>` reads as `<server>.<tool>`, as Codex names
            // MCP calls.
            let named = tool
                .raw_input
                .as_ref()
                .and_then(|input| input["tool_name"].as_str())
                .and_then(|name| name.split_once("__"))
                .map(|(server, tool)| format!("{server}.{tool}"));
            ("mcpToolCall", named.unwrap_or(title), detail)
        },
        "generate" => dynamic("imageGeneration"),
        "edit" | "delete" | "move" | "write" if !tool.diffs.is_empty() => {
            let title = match tool.diffs.as_slice() {
                [one] => one.path.clone(),
                many => format!("{} files", many.len()),
            };
            let body = tool
                .diffs
                .iter()
                .map(|d| diff_text(&d.path, d.old_text.as_deref(), &d.new_text))
                .collect::<Vec<_>>()
                .join("\n");
            ("fileChange", title, body)
        },
        _ => dynamic("dynamicToolCall"),
    }
}

/// The id of a synthesized item of `kind` for `owner` (an item, turn or
/// thread id). Disjoint from every folded item id (see the module docs), and
/// one-to-one: different owners or kinds never share an id.
pub fn synthetic_id(kind: &str, owner: &str) -> String {
    format!("#{kind}:{owner}")
}

/// The marker shown where a turn's earlier items were evicted.
pub fn gap_item(id: String, turn: &str) -> ThreadItem {
    ThreadItem {
        id,
        item_type: "historyGap".into(),
        title: String::new(),
        text: "Earlier history is not available from this agent host.".into(),
        questions_json: None,
        images: Vec::new(),
        turn_id: turn.to_string(),
        turn_completed_at: None,
        turn_duration_ms: None,
    }
}

/// Item type of a notice for content that is not shown (see the module
/// docs); its text lists the reasons, comma separated.
pub const CONTENT_OMITTED: &str = "contentOmitted";
/// Reason of a notice for a turn this controller could not read.
const UNAVAILABLE: &str = "unavailable";

fn omission_item(id: String, turn: &str, reasons: String) -> ThreadItem {
    ThreadItem {
        id,
        item_type: CONTENT_OMITTED.into(),
        title: String::new(),
        text: reasons,
        questions_json: None,
        images: Vec::new(),
        turn_id: turn.to_string(),
        turn_completed_at: None,
        turn_duration_ms: None,
    }
}

/// The notice for what `item` dropped (images, diffs, input, …), if any.
pub fn omission_notice(item: &Item, turn: &str) -> Option<ThreadItem> {
    (!item.omitted.is_empty())
        .then(|| omission_item(synthetic_id("omitted", &item.id), turn, item.omitted.join(",")))
}

/// The notice for a turn whose items could not be read from the host.
pub fn unavailable_item(turn: &str) -> ThreadItem {
    omission_item(synthetic_id("unavailable", turn), turn, UNAVAILABLE.into())
}

/// Whether later updates replace `item`'s content (so an omission can
/// clear).
fn replaceable(item: &Item) -> bool {
    matches!(item.kind, ItemKind::ToolCall | ItemKind::Plan)
}

/// `item`'s notice as owner state (see the module docs): its reasons, or
/// an empty notice that removes an earlier one; `None` for an item whose
/// omissions never clear and which has none.
fn notice_state(thread: &str, item: &Item, turn: &str) -> Option<AppEvent> {
    let notice = match omission_notice(item, turn) {
        Some(notice) => notice,
        None if replaceable(item) => {
            omission_item(synthetic_id("omitted", &item.id), turn, String::new())
        },
        None => return None,
    };
    Some(item_event("item/completed", thread, &notice, Some(notice.text.clone())))
}

/// Removals of notices that `turn`'s items no longer have (after a
/// recovery, an earlier notice may be stale).
fn cleared_notices(thread: &str, turn: &Turn) -> Vec<AppEvent> {
    turn.items
        .iter()
        .filter(|item| item.omitted.is_empty())
        .filter_map(|item| notice_state(thread, item, &turn.id))
        .collect()
}

/// The UI items of a folded turn: a gap where items were evicted, the
/// retained items, and a notice after each item that dropped content.
pub fn turn_items(turn: &Turn) -> Vec<ThreadItem> {
    let mut items = Vec::new();
    let mut gap = turn.omitted > 0;
    for item in &turn.items {
        if gap && item.kind != ItemKind::UserMessage {
            items.push(gap_item(synthetic_id("gap", &turn.id), &turn.id));
            gap = false;
        }
        items.push(app_item(item, &turn.id));
        items.extend(omission_notice(item, &turn.id));
    }
    if gap {
        items.push(gap_item(synthetic_id("gap", &turn.id), &turn.id));
    }
    items
}

fn item_event(kind: &str, thread: &str, item: &ThreadItem, text: Option<String>) -> AppEvent {
    let raw = json!({
        "threadId": thread, "turnId": item.turn_id, "itemId": item.id,
        "item": {"id": item.id, "type": item.item_type},
    });
    AppEvent {
        kind: kind.to_string(),
        thread_id: Some(thread.to_string()),
        item_id: Some(item.id.clone()),
        item_type: Some(item.item_type.clone()),
        title: Some(item.title.clone()),
        text,
        images: item.images.clone(),
        request_id: None,
        raw: raw.to_string(),
    }
}

fn tool_done(item: &Item) -> bool {
    item.tool
        .as_ref()
        .is_some_and(|tool| matches!(tool.status.as_str(), "completed" | "failed"))
}

fn is_message(item: &Item) -> bool {
    matches!(item.kind, ItemKind::AgentMessage | ItemKind::Thought)
}

/// Item events for folded changes.
pub fn changes(thread: &str, turn: &str, changes: Vec<Change>) -> Vec<AppEvent> {
    let mut out = Vec::new();
    for change in changes {
        match change {
            Change::Started(item) if is_message(&item) => {
                let mapped = app_item(&item, turn);
                out.push(item_event("item/started", thread, &mapped, Some(String::new())));
                if !item.text.is_empty() {
                    out.push(delta_event(thread, &mapped, item.text.clone()));
                }
                out.extend(notice_event(thread, &item, turn));
            },
            Change::Delta {
                item_id,
                kind,
                delta,
            } => {
                let item_type =
                    if kind == ItemKind::Thought { "reasoning" } else { "agentMessage" };
                let mapped = ThreadItem {
                    id: item_id,
                    item_type: item_type.to_string(),
                    title: String::new(),
                    text: String::new(),
                    questions_json: None,
                    images: Vec::new(),
                    turn_id: turn.to_string(),
                    turn_completed_at: None,
                    turn_duration_ms: None,
                };
                out.push(delta_event(thread, &mapped, delta));
            },
            change @ (Change::Started(_) | Change::Updated(_)) => {
                let (item, updated) = match change {
                    Change::Updated(item) => (item, true),
                    Change::Started(item) => (item, false),
                    Change::Delta {
                        ..
                    } => continue,
                };
                let mapped = app_item(&item, turn);
                let done = item.kind == ItemKind::Plan
                    || item.kind == ItemKind::UserMessage
                    || tool_done(&item)
                    || item.kind == ItemKind::AgentMessage;
                let kind = if done { "item/completed" } else { "item/started" };
                out.push(item_event(kind, thread, &mapped, Some(mapped.text.clone())));
                // An update replaces the item's content, so its notice is
                // re-stated (and removed when nothing is omitted any more).
                if updated {
                    out.extend(notice_state(thread, &item, turn));
                } else {
                    out.extend(notice_event(thread, &item, turn));
                }
            },
        }
    }
    out
}

/// The notice event for what `item` dropped, if anything.
fn notice_event(thread: &str, item: &Item, turn: &str) -> Option<AppEvent> {
    let notice = omission_notice(item, turn)?;
    Some(item_event("item/completed", thread, &notice, Some(notice.text.clone())))
}

fn delta_event(thread: &str, item: &ThreadItem, delta: String) -> AppEvent {
    let method = if item.item_type == "reasoning" {
        "item/reasoning/textDelta"
    } else {
        "item/agentMessage/delta"
    };
    item_event(method, thread, item, Some(delta))
}

/// Full-text events for a fold rebuilt from history while its turn runs:
/// each replaces what the UI shows for that item.
pub fn recovered(thread: &str, turn: &Turn, agent_started: bool) -> Vec<AppEvent> {
    let mut out: Vec<AppEvent> = turn_items(turn)
        .into_iter()
        // A view holds its own copy of a prompt it sent; a turn the agent
        // started has none, so its messages come from the fold.
        .filter(|mapped| agent_started || mapped.item_type != "userMessage")
        .map(|mapped| {
            // A reasoning or reply that another item follows has ended.
            let followed = |at: usize| at + 1 < turn.items.len();
            let done = mapped.item_type == "historyGap"
                || mapped.item_type == CONTENT_OMITTED
                || turn
                    .items
                    .iter()
                    .position(|item| item.id == mapped.id)
                    .is_some_and(|at| {
                        let item = &turn.items[at];
                        item.kind == ItemKind::Plan
                            || tool_done(item)
                            || (is_message(item) && followed(at))
                    });
            let kind = if done || mapped.item_type == "userMessage" {
                "item/completed"
            } else {
                "item/started"
            };
            item_event(kind, thread, &mapped, Some(mapped.text.clone()))
        })
        .collect();
    out.extend(cleared_notices(thread, turn));
    if agent_started {
        mark_agent_started(&mut out);
    }
    out
}

/// Mark `events` as belonging to a turn the agent started by itself.
fn mark_agent_started(events: &mut [AppEvent]) {
    for event in events {
        if let Ok(mut raw) = serde_json::from_str::<Value>(&event.raw) {
            raw["agentStarted"] = Value::Bool(true);
            event.raw = raw.to_string();
        }
    }
}

/// Completion events for a turn that ended: every retained item with its
/// final full text, then `turn/completed` with the recorded outcome. A turn
/// whose items could not be read says so instead of ending silently empty.
fn completion(
    thread: &str,
    turn_id: &str,
    turn: Option<&Turn>,
    outcome: Option<&Value>,
) -> Vec<AppEvent> {
    let items = match turn {
        Some(turn) => turn_items(turn),
        None => vec![unavailable_item(turn_id)],
    };
    let mut out: Vec<AppEvent> = items
        .into_iter()
        .filter(|mapped| mapped.item_type != "userMessage")
        .map(|mapped| item_event("item/completed", thread, &mapped, Some(mapped.text.clone())))
        .collect();
    out.push(turn_completed(thread, turn_id, outcome));
    out
}

/// Completion of a turn that ended while this controller was away, from
/// the host's history answer (when it could still be read).
pub fn finished(
    thread: &str,
    turn_id: &str,
    history: Option<&Value>,
    outcome: Option<&Value>,
) -> Vec<AppEvent> {
    let turn = history
        .and_then(|history| history["window"].as_array())
        .into_iter()
        .flatten()
        .filter_map(|turn| Turn::deserialize(turn).ok())
        .find(|turn| turn.id == turn_id);
    let mut out = completion(thread, turn_id, turn.as_ref(), outcome);
    // Updates missed while away may have cleared notices shown before.
    if let Some(turn) = &turn {
        let end = out.pop();
        out.extend(cleared_notices(thread, turn));
        out.extend(end);
    }
    out
}

/// Install `turn`'s fold from a history answer and announce it.
pub fn install(shared: &mut Shared, thread: &str, turn: &str, history: &Value) -> Vec<AppEvent> {
    if !shared.live.install(thread, history) {
        return Vec::new();
    }
    if history["session"]["runningTurnId"] == turn {
        shared.running.insert(thread.to_string(), turn.to_string());
    }
    let agent_started = history["session"]["runningTurnId"] == turn
        && history["session"]["runningAgentStarted"] == true;
    shared
        .live
        .turn(thread, turn)
        .map(|fold| recovered(thread, fold, agent_started))
        .unwrap_or_default()
}

/// `turn/completed` for a host outcome (`{"kind": ...}`), mapping honestly:
/// a natural end completes, a cancellation interrupts, and every other stop
/// reason or failure is shown as an error with its reason.
pub fn turn_completed(thread: &str, turn: &str, outcome: Option<&Value>) -> AppEvent {
    let (status, message) = match outcome {
        Some(outcome) => match (str_of(outcome, "kind"), str_of(outcome, "stopReason")) {
            ("stopped", "end_turn") => ("completed", None),
            ("stopped", "cancelled") | ("cancelled", _) => ("interrupted", None),
            ("stopped", "max_tokens") => {
                ("failed", Some("The agent stopped: it reached its token limit.".to_string()))
            },
            ("stopped", "max_turn_requests") => (
                "failed",
                Some("The agent stopped: it reached its request limit for this turn.".to_string()),
            ),
            ("stopped", "refusal") => (
                "failed",
                Some(
                    "The agent refused to continue; this message will not be part of the next \
                     prompt."
                        .to_string(),
                ),
            ),
            ("stopped", other) => ("failed", Some(format!("The agent stopped ({other})."))),
            ("failed", _) => ("failed", Some(str_of(outcome, "message").to_string())),
            ("agentExited", _) => {
                ("failed", Some("The agent process exited before finishing this turn.".to_string()))
            },
            _ => ("failed", Some("The agent ended this turn in an unrecognized way.".to_string())),
        },
        None => (
            "failed",
            Some(
                "This turn's outcome is unknown after the connection to the agent host was \
                 restored."
                    .to_string(),
            ),
        ),
    };
    let mut turn_raw = json!({"id": turn, "status": status});
    if let Some(message) = message {
        turn_raw["error"] = json!({"message": message});
    }
    event("turn/completed", Some(thread), json!({"threadId": thread, "turn": turn_raw}))
}

/// Completion of the reasoning or reply that an item started in `changes`
/// follows: the agent moved on, so it stops showing as in progress (ACP
/// reports no end of a message; the turn's end would settle it much later).
fn settled(shared: &Shared, thread: &str, turn: &str, changes: &[Change]) -> Vec<AppEvent> {
    let Some(fold) = shared.live.turn(thread, turn) else { return Vec::new() };
    changes
        .iter()
        .filter_map(|change| match change {
            Change::Started(item) => {
                let at = fold.items.iter().position(|kept| kept.id == item.id)?;
                let before = fold.items.get(at.checked_sub(1)?)?;
                is_message(before).then(|| {
                    let mapped = app_item(before, turn);
                    item_event("item/completed", thread, &mapped, Some(mapped.text.clone()))
                })
            },
            _ => None,
        })
        .collect()
}

fn turn_started(thread: &str, turn: &str, agent_started: bool) -> AppEvent {
    event(
        "turn/started",
        Some(thread),
        json!({"threadId": thread, "turnId": turn, "turn": {"id": turn, "status": "inProgress"},
               "agentStarted": agent_started}),
    )
}

/// The request event for a pending permission body.
pub fn permission_event(body: &Value) -> AppEvent {
    let thread = str_of(body, "sessionId");
    if let Some(questions) = body["questions"].as_array() {
        return question_event(body, thread, questions);
    }
    let title = body["toolCall"]["title"].as_str().unwrap_or("").to_string();
    let raw = json!({
        "threadId": thread,
        "turnId": body["turnId"],
        "toolCall": body["toolCall"],
        "options": body["options"],
    });
    AppEvent {
        kind: PERMISSION_REQUESTED.to_string(),
        thread_id: Some(thread.to_string()),
        item_id: None,
        item_type: None,
        title: Some(title),
        text: None,
        images: Vec::new(),
        request_id: body["handle"].as_str().map(str::to_string),
        raw: raw.to_string(),
    }
}

/// A host-held agent question (Grok's `ask_user_question`), as the app's
/// structured question request; answered through
/// [`super::respond_question`] with `{"q<i>": [labels]}`.
fn question_event(body: &Value, thread: &str, questions: &[Value]) -> AppEvent {
    let questions: Vec<Value> = questions
        .iter()
        .enumerate()
        .map(|(index, question)| {
            json!({
                "id": format!("q{index}"),
                "header": "",
                "question": question["question"],
                "multiple": question["multiSelect"] == true,
                "isOther": false,
                "isSecret": false,
                "options": question["options"],
            })
        })
        .collect();
    let mut out = event(
        "item/tool/requestUserInput",
        Some(thread),
        json!({"threadId": thread, "turnId": body["turnId"], "questions": questions}),
    );
    out.request_id = body["handle"].as_str().map(str::to_string);
    out
}

fn resolved(thread: &str, handle: &str) -> AppEvent {
    event("serverRequest/resolved", Some(thread), json!({"threadId": thread, "requestId": handle}))
}

/// The host can no longer be reached through this connection.
pub fn host_unreachable() -> AppEvent {
    event(HOST_STATE, None, json!({"connected": false}))
}

/// The event stream failed: nothing the UI holds can be vouched for any
/// more. Capabilities fall back to the unnegotiated set, pending
/// permissions leave the UI (they return on recovery), and the UI is told.
pub fn disconnected(shared: &mut Shared) -> Vec<AppEvent> {
    let was_healthy = std::mem::replace(&mut shared.healthy, false);
    let mut out: Vec<AppEvent> = shared
        .permissions
        .drain()
        .map(|(handle, body)| resolved(str_of(&body, "sessionId"), &handle))
        .collect();
    if was_healthy {
        out.push(host_unreachable());
    }
    out
}

/// Translate one gateway event, updating the connection's view.
pub fn gateway_event(shared: &mut Shared, body: &Value) -> Vec<AppEvent> {
    let thread = str_of(body, "sessionId").to_string();
    let turn = str_of(body, "turnId").to_string();
    match str_of(body, "type") {
        "turn_started" => {
            shared.running.insert(thread.clone(), turn.clone());
            let folded = shared.live.apply(body);
            let agent_started = body["agentStarted"] == true;
            let mut out = vec![turn_started(&thread, &turn, agent_started)];
            // No controller sent a turn the agent started (Grok's own), so
            // no view holds its message yet: it comes from the host, marked
            // like the turn's start.
            if agent_started {
                let mut message = changes(&thread, &turn, folded);
                mark_agent_started(&mut message);
                out.extend(message);
            }
            out
        },
        "update" | "supplement" => {
            let folded = shared.live.apply(body);
            let turn = body["turnId"].as_str().unwrap_or("");
            let mut out = settled(shared, &thread, turn, &folded);
            out.extend(changes(&thread, turn, folded));
            out
        },
        "turn_ended" => {
            // Only the end of the turn this view shows running releases it: a
            // late end of an older turn leaves a newer one running (and its
            // live fold protected from eviction).
            if shared.running.get(&thread) == Some(&turn) {
                shared.running.remove(&thread);
            }
            let mut out = completion(
                &thread,
                &turn,
                shared.live.turn(&thread, &turn),
                Some(&body["outcome"]),
            );
            let running = &shared.running;
            shared
                .live
                .bound(MAX_LIVE, |session| running.contains_key(session));
            out.extend(clear_running(shared, &thread, &turn));
            out
        },
        "permission" => {
            if let Some(handle) = body["handle"].as_str() {
                shared.permissions.insert(handle.to_string(), body.clone());
            }
            vec![permission_event(body)]
        },
        "permission_resolved" => {
            let handle = str_of(body, "handle").to_string();
            shared.permissions.remove(&handle);
            vec![resolved(&thread, &handle)]
        },
        "session_state" => session_state(shared, body),
        "host_state" => {
            shared.info["phase"] = body["phase"].clone();
            shared.info["authRequired"] = body["authRequired"].clone();
            // Older hosts send no commands: keep what their info said.
            if let Some(commands) = body.get("commands") {
                shared.info["commands"] = commands.clone();
            }
            vec![event(
                HOST_STATE,
                None,
                json!({"phase": body["phase"], "authRequired": body["authRequired"], "connected": true}),
            )]
        },
        _ => Vec::new(),
    }
}

/// The cached session state still names `turn` as running once it ended
/// (a host may not send a fresh state): clear it, so the controls it gates
/// are released. A state naming a newer turn is left alone.
fn clear_running(shared: &mut Shared, thread: &str, turn: &str) -> Option<AppEvent> {
    let session = shared.sessions.get_mut(thread)?;
    if turn.is_empty() || session["runningTurnId"] != turn {
        return None;
    }
    session["runningTurnId"] = Value::Null;
    session["turnDispatched"] = Value::Bool(false);
    session["cancelRequested"] = Value::Bool(false);
    Some(event(SESSION_UPDATED, Some(thread), session.clone()))
}

fn session_state(shared: &mut Shared, body: &Value) -> Vec<AppEvent> {
    let thread = str_of(body, "sessionId").to_string();
    let previous_title = shared.sessions.get(&thread).map(|old| old["title"].clone());
    if body["admitted"] == false {
        shared.sessions.remove(&thread);
    } else {
        shared.sessions.insert(thread.clone(), body.clone());
    }
    let mut out = vec![event(SESSION_UPDATED, Some(&thread), body.clone())];
    if body["admitted"] != false && previous_title.is_some_and(|old| old != body["title"]) {
        out.push(event(
            "thread/name/updated",
            Some(&thread),
            json!({"threadId": thread, "name": body["title"]}),
        ));
    }
    out
}

/// What a recovery has to do after reconciling with a snapshot, in this
/// order: complete `ended`, announce `started`, rebuild `running`, then emit
/// `events` and finally `host_state`.
pub struct Plan {
    /// Session and permission events.
    pub events: Vec<AppEvent>,
    /// The host-state event, last.
    pub host_state: AppEvent,
    /// Generation of the snapshot.
    pub generation: u64,
    /// Turns that ended meanwhile: `(thread, turn, recorded outcome)`.
    pub ended: Vec<(String, String, Option<Value>)>,
    /// Running turns this view had not seen begin, and whether the agent
    /// started them by itself.
    pub started: Vec<(String, String, bool)>,
    /// Turns running now, whose folds must be rebuilt.
    pub running: Vec<(String, String)>,
}

/// Reconcile with an authoritative snapshot after a connect, reconnect or
/// reset. Live folds are dropped (the caller rebuilds the running ones from
/// history); turns that ended meanwhile are handed to the caller with their
/// recorded outcome — never an assumed success; permissions and session
/// state are replaced. A snapshot says nothing about the event stream, so
/// the view's health is left to whoever opens the stream.
pub fn reconcile(shared: &mut Shared, snapshot: &Value) -> Plan {
    let mut events = Vec::new();
    let generation = snapshot["generation"].as_u64().unwrap_or(0);
    let host_id = str_of(&snapshot["info"], "hostId").to_string();
    let replaced = host_id != shared.host_id;
    shared.host_id = host_id;
    shared.generation = generation;
    shared.info = snapshot["info"].clone();
    shared.live.clear();
    shared.unsynced.clear();
    if replaced {
        shared.oldest.clear();
        shared.history_epochs.clear();
    }
    let recent: HashMap<(String, String), Value> = snapshot["recentTurns"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|r| {
            (
                (str_of(r, "sessionId").to_string(), str_of(r, "turnId").to_string()),
                r["outcome"].clone(),
            )
        })
        .collect();
    let mut running = HashMap::new();
    let mut sessions = HashMap::new();
    for session in snapshot["sessions"].as_array().into_iter().flatten() {
        let id = str_of(session, "sessionId").to_string();
        if let Some(turn) = session["runningTurnId"].as_str() {
            running.insert(id.clone(), turn.to_string());
        }
        sessions.insert(id, session.clone());
    }
    let previous = std::mem::take(&mut shared.running);
    let ended: Vec<(String, String, Option<Value>)> = previous
        .iter()
        .filter(|(thread, turn)| running.get(*thread) != Some(*turn))
        .map(|(thread, turn)| {
            let outcome = recent.get(&(thread.clone(), turn.clone())).cloned();
            (thread.clone(), turn.clone(), outcome)
        })
        .collect();
    let mut started: Vec<(String, String, bool)> = running
        .iter()
        .filter(|(thread, turn)| previous.get(*thread) != Some(*turn))
        .map(|(thread, turn)| {
            let agent = sessions
                .get(thread)
                .is_some_and(|session| session["runningAgentStarted"] == true);
            (thread.clone(), turn.clone(), agent)
        })
        .collect();
    started.sort();
    let mut running_list: Vec<(String, String)> = running
        .iter()
        .map(|(thread, turn)| (thread.clone(), turn.clone()))
        .collect();
    running_list.sort();
    shared.running = running;
    let pending: HashMap<String, Value> = snapshot["permissions"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|p| Some((p["handle"].as_str()?.to_string(), p.clone())))
        .collect();
    let kept: HashSet<&String> = pending.keys().collect();
    for (handle, body) in &shared.permissions {
        if !kept.contains(handle) {
            events.push(resolved(str_of(body, "sessionId"), handle));
        }
    }
    for (handle, body) in &pending {
        if !shared.permissions.contains_key(handle) {
            events.push(permission_event(body));
        }
    }
    shared.permissions = pending;
    for id in shared
        .sessions
        .keys()
        .filter(|id| !sessions.contains_key(*id))
    {
        events.push(event(SESSION_UPDATED, Some(id), json!({"sessionId":id,"admitted":false})));
    }
    shared.sessions = sessions;
    for body in shared.sessions.values() {
        events.push(event(SESSION_UPDATED, Some(str_of(body, "sessionId")), body.clone()));
    }
    let host_state = event(
        HOST_STATE,
        None,
        json!({
            "phase": shared.info["phase"], "authRequired": shared.info["authRequired"],
            "generation": generation, "connected": true, "replaced": replaced,
        }),
    );
    Plan {
        events,
        host_state,
        generation,
        ended,
        started,
        running: running_list,
    }
}

/// `turn/started` for a running turn a recovery found.
pub fn started(thread: &str, turn: &str, agent_started: bool) -> AppEvent {
    turn_started(thread, turn, agent_started)
}

#[cfg(test)]
#[path = "translate_tests.rs"]
mod tests;
