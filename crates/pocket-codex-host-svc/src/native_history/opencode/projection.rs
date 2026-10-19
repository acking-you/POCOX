//! Public transcript content only; native reasoning and provider metadata stay
//! private.

use serde_json::Value;

use crate::acp::fold::{Item, ItemKind, Tool, Turn};

pub(super) struct Message {
    pub id: String,
    pub kind: String,
    pub data: Value,
}

pub(super) fn clip(text: &str, max: usize) -> (String, bool) {
    if text.len() <= max {
        return (text.into(), false);
    }
    let mut end = max;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    (format!("{}\n[… truncated]", &text[..end]), true)
}

fn text(value: &Value, key: &str) -> String {
    value[key].as_str().unwrap_or_default().to_owned()
}

fn item(id: String, kind: ItemKind, text: &str) -> Item {
    let (text, truncated) = clip(text, 128 * 1024);
    Item {
        id,
        kind,
        title: String::new(),
        text,
        images: vec![],
        tool: None,
        plan: None,
        message_id: None,
        truncated,
        text_full: truncated,
        omitted: vec![],
    }
}

fn omit(item: &mut Item, reason: &str) {
    item.truncated = true;
    if !item.omitted.iter().any(|known| known == reason) {
        item.omitted.push(reason.into());
    }
}

const IMAGES: [&str; 4] = ["image/png", "image/jpeg", "image/gif", "image/webp"];
const MAX_IMAGE_URL: usize = 512 * 1024;

fn files(item: &mut Item, values: &Value) {
    for file in values.as_array().into_iter().flatten() {
        match image(file) {
            Some(url) if item.images.len() < 4 => item.images.push(url),
            // File paths and remote URLs are not automatic read authority.
            _ => omit(item, "attachments"),
        }
    }
}

/// A stored image as a bounded data URL: 1.x keeps the URL, 2.x the bytes.
/// 2.x also keeps the bytes of a path attachment, which stay unread.
fn image(file: &Value) -> Option<String> {
    if let Some(url) = file["url"].as_str() {
        let mime = url.strip_prefix("data:")?.split_once(";base64,")?.0;
        return (IMAGES.contains(&mime) && url.len() <= MAX_IMAGE_URL).then(|| url.into());
    }
    let mime = file["mime"].as_str()?;
    let data = file["data"].as_str()?;
    (file["source"]["type"] == "inline"
        && IMAGES.contains(&mime)
        && data.len() + mime.len() + 13 <= MAX_IMAGE_URL)
        .then(|| format!("data:{mime};base64,{data}"))
}

fn tool(id: String, block: &Value) -> Item {
    let state = &block["state"];
    let mut result = item(id.clone(), ItemKind::ToolCall, "");
    let mut output = String::new();
    for part in state["content"].as_array().into_iter().flatten() {
        if part["type"] == "text" {
            if !output.is_empty() {
                output.push('\n');
            }
            output.push_str(&text(part, "text"));
        } else {
            omit(&mut result, "tool content");
        }
    }
    if state["status"] == "error" {
        output.push_str(&text(&state["error"], "message"));
    }
    let (output, cut) = clip(&output, 128 * 1024);
    result.text = output;
    if cut {
        omit(&mut result, "tool output");
    }
    result.title = clip(&text(block, "name"), 4096).0;
    let input = &state["input"];
    let input = if input.to_string().len() <= 64 * 1024 {
        Some(input.clone())
    } else {
        omit(&mut result, "input");
        None
    };
    files(&mut result, &state["attachments"]);
    result.tool = Some(Tool {
        call_id: text(block, "id"),
        kind: "other".into(),
        status: match state["status"].as_str() {
            Some("completed") => "completed",
            Some("error") => "failed",
            Some("running") => "in_progress",
            _ => "pending",
        }
        .into(),
        name: Some(result.title.clone()),
        raw_input: input,
        ..Tool::default()
    });
    result
}

fn project(message: &Message) -> Vec<Item> {
    let id = format!("opencode:{}", message.id);
    let data = &message.data;
    if data.is_null() {
        let mut result =
            item(id, ItemKind::AgentMessage, "[Message exceeds the local reader limit]");
        omit(&mut result, "content");
        return vec![result];
    }
    match message.kind.as_str() {
        "user" => {
            let mut result = item(id, ItemKind::UserMessage, &text(data, "text"));
            files(&mut result, &data["files"]);
            if data["omitted"] == true {
                omit(&mut result, "unsupported content");
            }
            vec![result]
        },
        "assistant" => {
            let mut items = Vec::new();
            for (index, part) in data["content"].as_array().into_iter().flatten().enumerate() {
                let part_id = format!("{id}:{index}");
                match part["type"].as_str() {
                    Some("text") => {
                        items.push(item(part_id, ItemKind::AgentMessage, &text(part, "text")))
                    },
                    Some("tool") => items.push(tool(part_id, part)),
                    Some("reasoning") => {},
                    _ => {
                        let mut notice = item(part_id, ItemKind::AgentMessage, "");
                        omit(&mut notice, "unsupported content");
                        items.push(notice);
                    },
                }
            }
            if data["files"]
                .as_array()
                .is_some_and(|files| !files.is_empty())
            {
                let mut attachments = item(format!("{id}:files"), ItemKind::AgentMessage, "");
                files(&mut attachments, &data["files"]);
                items.push(attachments);
            }
            if let Some(error) = data["error"]["message"].as_str() {
                items.push(item(format!("{id}:error"), ItemKind::AgentMessage, error));
            }
            items
        },
        "shell" => {
            // 2.x keeps the output page and status in objects of its own.
            let output = data["output"]["output"]
                .as_str()
                .or_else(|| data["output"].as_str())
                .unwrap_or_default();
            let mut result = item(id.clone(), ItemKind::ToolCall, output);
            result.title = clip(&text(data, "command"), 4096).0;
            let status = match (data["status"].as_str(), data["time"]["completed"].is_null()) {
                (Some("running"), _) | (None, true) => "in_progress",
                (Some("timeout" | "killed"), _) => "failed",
                _ => "completed",
            };
            result.tool = Some(Tool {
                call_id: data["callID"]
                    .as_str()
                    .or_else(|| data["shellID"].as_str())
                    .unwrap_or_default()
                    .into(),
                kind: "execute".into(),
                status: status.into(),
                ..Tool::default()
            });
            vec![result]
        },
        "compaction" => vec![item(id, ItemKind::AgentMessage, "[Earlier context compacted]")],
        "system" | "synthetic" => vec![],
        // A run can fail outside a reply; then only its end marker says why.
        "idle" => match data["error"]["message"].as_str() {
            Some(error) if data["outcome"] == "failed" => {
                vec![item(id, ItemKind::AgentMessage, error)]
            },
            _ => vec![],
        },
        "agent-switched" | "model-switched" | "location-switched" => vec![],
        _ => {
            let mut result = item(id, ItemKind::AgentMessage, "");
            omit(&mut result, "unsupported message");
            vec![result]
        },
    }
}

pub(super) fn turns(messages: Vec<Message>) -> (Vec<Turn>, bool) {
    let mut turns: Vec<Turn> = Vec::new();
    let mut truncated = false;
    for message in messages {
        let items = project(&message);
        if message.kind == "user" || (turns.is_empty() && !items.is_empty()) {
            turns.push(Turn {
                id: format!("native:{}", message.id),
                items: vec![],
                outcome: None,
                replayed: true,
                next_item: 0,
                omitted: 0,
            });
        }
        if let Some(turn) = turns.last_mut() {
            for item in items {
                // A failed reply already shows the error its end marker repeats.
                if message.kind == "idle" && turn.items.iter().any(|known| known.text == item.text)
                {
                    continue;
                }
                truncated |= item.truncated;
                if turn.items.len() < 4000 {
                    turn.items.push(item);
                } else {
                    turn.omitted += 1;
                    truncated = true;
                }
            }
        }
    }
    (turns, truncated)
}
