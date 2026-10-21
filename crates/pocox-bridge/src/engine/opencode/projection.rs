//! Native messages become shared UI items without guessing missing prefixes or
//! authorizing host file reads from attachment paths.

use pocox_host_svc::opencode::{host::Snapshot, public, schema::Message};
use serde_json::{json, Value};

use super::super::app_session::{AppEvent, ThreadHistory, ThreadItem, TurnSummary};

pub(super) fn event(kind: &str, thread: Option<&str>, raw: Value) -> AppEvent {
    AppEvent {
        kind: kind.into(),
        thread_id: thread.map(str::to_owned),
        item_id: None,
        item_type: None,
        title: None,
        text: None,
        images: vec![],
        request_id: None,
        raw: raw.to_string(),
    }
}

pub(super) fn health(healthy: bool) -> AppEvent {
    event(
        "acp/host/state",
        None,
        json!({"connected":healthy,"phase":{"state":if healthy {"ready"} else {"reconnecting"}}}),
    )
}

fn text(value: &Value, key: &str) -> String {
    value[key].as_str().unwrap_or_default().into()
}

fn item(id: String, turn: &str, kind: &str, body: String) -> ThreadItem {
    ThreadItem {
        id,
        turn_id: turn.into(),
        item_type: kind.into(),
        text: if kind == "dynamicToolCall" { body } else { clip(&body, 128 * 1024) },
        title: String::new(),
        images: vec![],
        questions_json: None,
        turn_completed_at: None,
        turn_duration_ms: None,
    }
}

fn clip(value: &str, limit: usize) -> String {
    if value.len() <= limit {
        return value.into();
    }
    let mut end = limit;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\n[… truncated]", &value[..end])
}

fn attachments<'a>(target: &mut ThreadItem, files: impl Iterator<Item = &'a Value>) -> bool {
    let mut omitted = false;
    for file in files {
        let url = file["url"].as_str().unwrap_or_default();
        if [
            "data:image/png;base64,",
            "data:image/jpeg;base64,",
            "data:image/webp;base64,",
            "data:image/gif;base64,",
        ]
        .iter()
        .any(|prefix| url.starts_with(prefix))
            && url.len() <= 512 * 1024
            && target.images.len() < 4
        {
            target.images.push(url.into());
        } else {
            omitted = true;
        }
    }
    omitted
}

fn message(message: &Message) -> Vec<ThreadItem> {
    let id = text(&message.info, "id");
    let user = message.info["role"] == "user";
    let turn = if user { id.as_str() } else { message.info["parentID"].as_str().unwrap_or(&id) };
    let mut out = vec![];
    if user {
        let body = message
            .parts
            .iter()
            .filter(|p| p["type"] == "text" && p["ignored"] != true)
            .filter_map(|p| p["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n");
        let truncated = body.len() > 128 * 1024;
        let mut mapped = item(id.clone(), turn, "userMessage", body);
        let omitted =
            attachments(&mut mapped, message.parts.iter().filter(|p| p["type"] == "file"));
        out.push(mapped);
        if truncated {
            out.push(item(format!("#input:{id}"), turn, "contentOmitted", "input".into()));
        }
        if omitted {
            out.push(item(
                format!("#attachments:{id}"),
                turn,
                "contentOmitted",
                "attachments".into(),
            ));
        }
        return out;
    }
    // Some providers finish with reasoning only, even embedding their answer
    // in it. Keep the original content/type provenance visible; never guess a
    // natural-language boundary or relabel it as a normal assistant answer.
    let reasoning_only = message.info["finish"] == "stop"
        && message.info["time"]["completed"].is_number()
        && !message.info["error"].is_object()
        && message.parts.iter().any(|part| {
            part["type"] == "reasoning"
                && part["text"]
                    .as_str()
                    .is_some_and(|text| !text.trim().is_empty())
        })
        && !message.parts.iter().any(|part| {
            part["type"] == "file"
                || (part["type"] == "text"
                    && part["ignored"] != true
                    && part["text"]
                        .as_str()
                        .is_some_and(|text| !text.trim().is_empty()))
        });
    for part in &message.parts {
        let part_id = text(part, "id");
        if part_id.is_empty() {
            continue;
        }
        let mut mapped = match part["type"].as_str() {
            Some("text") if part["ignored"] != true => {
                item(part_id, turn, "agentMessage", text(part, "text"))
            },
            Some("reasoning") => item(
                part_id,
                turn,
                if reasoning_only { "reasoningOutput" } else { "reasoning" },
                text(part, "text"),
            ),
            Some("tool") => {
                let state = &part["state"];
                let input = if state["input"].to_string().len() <= 64 * 1024 {
                    state["input"].clone()
                } else {
                    out.push(item(
                        format!("#input:{part_id}"),
                        turn,
                        "contentOmitted",
                        "input".into(),
                    ));
                    Value::Null
                };
                let body = json!({"tool":part["tool"],"input":input,
                    "output":clip(state["output"].as_str().unwrap_or_default(),128*1024),
                    "error":clip(state["error"].as_str().unwrap_or_default(),4096),"status":state["status"]}).to_string();
                let mut mapped = item(part_id, turn, "dynamicToolCall", body);
                mapped.title = clip(
                    state["title"]
                        .as_str()
                        .or(part["tool"].as_str())
                        .unwrap_or_default(),
                    4096,
                );
                if attachments(&mut mapped, state["attachments"].as_array().into_iter().flatten()) {
                    out.push(item(
                        format!("#attachments:{}", mapped.id),
                        turn,
                        "contentOmitted",
                        "attachments".into(),
                    ));
                }
                mapped
            },
            Some("file") => {
                let mut mapped = item(part_id, turn, "agentMessage", String::new());
                if attachments(&mut mapped, std::iter::once(part)) {
                    mapped.item_type = "contentOmitted".into();
                    mapped.text = "attachments".into();
                }
                mapped
            },
            Some("compaction") => item(part_id, turn, "contextCompaction", String::new()),
            Some("step-start" | "step-finish" | "agent" | "retry") => continue,
            _ => item(part_id, turn, "contentOmitted", "unsupported content".into()),
        };
        mapped.turn_completed_at = message.info["time"]["completed"]
            .as_i64()
            .map(|ms| ms / 1000);
        out.push(mapped);
    }
    if message.info["error"].is_object() {
        let error = model_error(&message.info);
        let cancelled = error["code"] == "cancelled";
        out.push(item(
            format!("#error:{id}"),
            turn,
            if cancelled { "interrupted" } else { "modelError" },
            if cancelled { String::new() } else { error.to_string() },
        ));
    }
    out
}

fn model_error(info: &Value) -> Value {
    let mut error = public::error(&info["error"]);
    if let Some(fields) = error.as_object_mut() {
        fields.remove("name");
    }
    error["model"] = clip(info["modelID"].as_str().unwrap_or_default(), 256).into();
    error["provider"] = clip(info["providerID"].as_str().unwrap_or_default(), 128).into();
    // A supplement has its own native prompt ID inside the admitted turn.
    // Terminal notifications must identify the same failure as history/items.
    let id = text(info, "id");
    error["itemId"] = format!("#error:{id}").into();
    error["turnId"] = info["parentID"].as_str().unwrap_or(&id).into();
    error
}

pub(super) fn items(snapshot: &Snapshot) -> Vec<ThreadItem> {
    let mut items: Vec<_> = snapshot.window.messages.iter().flat_map(message).collect();
    for gap in &snapshot.window.gaps {
        let turn = items
            .iter()
            .find(|item| item.id == *gap)
            .map(|item| item.turn_id.clone())
            .unwrap_or_default();
        items.push(item(
            format!("#stream-gap:{gap}"),
            &turn,
            "contentOmitted",
            "unavailable".into(),
        ));
    }
    items
}

pub(super) fn history(snapshot: &Snapshot) -> ThreadHistory {
    let items = items(snapshot);
    let mut turns: Vec<TurnSummary> = vec![];
    for item in &items {
        if !turns.iter().any(|turn| turn.turn_id == item.turn_id) {
            turns.push(TurnSummary {
                turn_id: item.turn_id.clone(),
                user_text: String::new(),
                assistant_text: String::new(),
                loaded: true,
            });
        }
        if let Some(turn) = turns.iter_mut().find(|turn| turn.turn_id == item.turn_id) {
            match item.item_type.as_str() {
                "userMessage" => turn.user_text = item.text.chars().take(400).collect(),
                "agentMessage" => turn.assistant_text = item.text.chars().take(400).collect(),
                _ => {},
            }
        }
    }
    let has_older = snapshot.window.next_before.is_some();
    ThreadHistory {
        history_epoch: snapshot.access.source_generation.clone(),
        first_turn_id: (!has_older)
            .then(|| turns.first().map(|turn| turn.turn_id.clone()))
            .flatten(),
        items,
        turns,
        has_older,
        running: snapshot.turn_id.is_some(),
        active_turn_id: snapshot.turn_id.clone(),
        cwd: Some(snapshot.session.directory.clone()),
        model: snapshot.options.model.clone(),
        ..ThreadHistory::default()
    }
}

pub(super) fn item_event(thread: &str, item: &ThreadItem) -> AppEvent {
    let mut event = event(
        "item/completed",
        Some(thread),
        json!({"threadId":thread,"turnId":item.turn_id,"itemId":item.id,
        "item":{"id":item.id,"type":item.item_type}}),
    );
    event.item_id = Some(item.id.clone());
    event.item_type = Some(item.item_type.clone());
    event.title = Some(item.title.clone());
    event.text = Some(item.text.clone());
    event.images = item.images.clone();
    event
}

pub(super) fn ended(snapshot: &Snapshot, turn: &str) -> AppEvent {
    let last = snapshot.window.messages.iter().rev().find(|m| {
        // Native IDs are time-ordered. Supplements have their own parent
        // IDs inside this admitted turn, up to the next admitted prompt.
        m.info["role"] == "assistant"
            && m.info["parentID"].as_str().is_some_and(|parent| {
                parent >= turn && snapshot.turn_id.as_deref().is_none_or(|next| parent < next)
            })
    });
    let error = last
        .filter(|m| m.info["error"].is_object())
        .map(|m| model_error(&m.info));
    // A stopped supplement has its own prompt/item identity. Preserve it
    // without turning cancellation into an error or changing the admitted turn.
    let interruption = error
        .as_ref()
        .filter(|error| error["code"] == "cancelled")
        .map(|error| json!({"itemId":error["itemId"],"turnId":error["turnId"]}));
    let (status, detail) = match error {
        Some(error) if error["code"] == "cancelled" => ("interrupted", None),
        Some(error) => ("failed", Some(error)),
        None if last.is_some_and(|m| {
            m.info["time"]["completed"].is_number() && m.info["finish"] == "stop"
        }) =>
        {
            ("completed", None)
        },
        _ => (
            "failed",
            Some(json!({"message":snapshot.operation_error.clone().unwrap_or_else(|| {
                "OpenCode turn outcome is unavailable; refresh the conversation.".into()
            })})),
        ),
    };
    let mut body = json!({"threadId":snapshot.session.id,
        "turn":{"id":turn,"status":status,"error":detail}});
    if let Some(interruption) = interruption {
        body["turn"]["interruption"] = interruption;
    }
    event("turn/completed", Some(&snapshot.session.id), body)
}
