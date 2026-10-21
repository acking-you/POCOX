//! Tool activity that newer codex rollouts persist as `event_msg`
//! `item_completed` records, mapped to the app-server item variants.

use serde_json::Value;

use super::{strip_ansi, TranscriptItem};

/// Newer codex rollouts persist the UI-ready result of tool activity as an
/// `event_msg.item_completed` record. The legacy `response_item` parser
/// already covers messages/reasoning and function-call commands; this adds the
/// modern command and file-edit shapes that otherwise vanished from read-only
/// history entirely.
pub(super) fn completed_activity_item(item: &Value, fallback_id: String) -> Option<TranscriptItem> {
    let id = item
        .get("id")
        .and_then(Value::as_str)
        .map_or(fallback_id, str::to_string);
    let row = match item.get("type").and_then(Value::as_str)? {
        "CommandExecution" => completed_command_item(item, id),
        "FileChange" => return completed_file_change_item(item, id),
        "McpToolCall" => TranscriptItem::new(
            id,
            "mcpToolCall",
            qualified_tool_title(item),
            selected_json(item, &[&["arguments"], &["app_context", "appContext"], &["result"], &[
                "error",
            ]]),
        ),
        "DynamicToolCall" => TranscriptItem::new(
            id,
            "dynamicToolCall",
            qualified_tool_title(item),
            selected_json(item, &[
                &["arguments"],
                &["content_items", "contentItems"],
                &["success"],
                &["error"],
            ]),
        ),
        "CollabAgentToolCall" => TranscriptItem::new(
            id,
            "collabAgentToolCall",
            event_string(item, &["tool"]),
            selected_json(item, &[
                &["status"],
                &["prompt"],
                &["model"],
                &["reasoning_effort", "reasoningEffort"],
                &["receiver_thread_ids", "receiverThreadIds"],
                &["agents_states", "agentsStates"],
            ]),
        ),
        "SubAgentActivity" => TranscriptItem::new(
            id,
            "subAgentActivity",
            event_string(item, &["kind"]),
            selected_json(item, &[
                &["agent_path", "agentPath"],
                &["agent_thread_id", "agentThreadId"],
                &["model"],
                &["reasoning_effort", "reasoningEffort"],
            ]),
        ),
        "WebSearch" => TranscriptItem::new(
            id,
            "webSearch",
            event_string(item, &["query"]),
            selected_json(item, &[&["action"], &["results"]]),
        ),
        "ImageView" => TranscriptItem::new(id, "imageView", event_string(item, &["path"]), ""),
        "ImageGeneration" => completed_image_generation_item(item, id),
        "EnteredReviewMode" => {
            TranscriptItem::new(id, "enteredReviewMode", event_string(item, &["review"]), "")
        },
        "ExitedReviewMode" => {
            TranscriptItem::new(id, "exitedReviewMode", event_string(item, &["review"]), "")
        },
        "HookPrompt" => {
            let fragments = item
                .get("fragments")
                .and_then(Value::as_array)
                .map(Vec::as_slice)
                .unwrap_or_default();
            let joined = |field: &[&str], separator: &str| {
                fragments
                    .iter()
                    .filter_map(|fragment| event_value(fragment, field).and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join(separator)
            };
            TranscriptItem::new(
                id,
                "hookPrompt",
                joined(&["hook_run_id", "hookRunId"], ", "),
                joined(&["text"], "\n"),
            )
        },
        "Plan" => TranscriptItem::new(id, "plan", "", event_string(item, &["text"])),
        "Extension" => completed_extension_item(item, id),
        _ => return None,
    };
    Some(row)
}

fn completed_command_item(item: &Value, id: String) -> TranscriptItem {
    let title = item
        .get("parsed_cmd")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|command| command.get("cmd").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n");
    let title = if title.is_empty() { completed_command_title(item) } else { title };
    let text = ["formatted_output", "aggregated_output", "stdout"]
        .into_iter()
        .find_map(|field| {
            item.get(field)
                .and_then(Value::as_str)
                .filter(|text| !text.is_empty())
        })
        .unwrap_or_else(|| item.get("stderr").and_then(Value::as_str).unwrap_or(""));
    TranscriptItem::new(id, "commandExecution", title, strip_ansi(text))
}

fn completed_extension_item(item: &Value, id: String) -> TranscriptItem {
    let kind = event_string(item, &["kind"]);
    let (item_type, title) = if kind == "clock.sleep" {
        let duration = event_value(item, &["duration_ms", "durationMs"]).and_then(Value::as_u64);
        ("sleep", format!("{} ms", duration.unwrap_or(0)))
    } else if kind.contains("web_search") || kind.contains("web-search") {
        ("webSearch", event_string(item, &["query"]))
    } else if kind == "image_gen.generation" {
        return completed_image_generation_item(item, id);
    } else {
        ("dynamicToolCall", kind)
    };
    TranscriptItem::new(
        id,
        item_type,
        title,
        selected_json(item, &[
            &["status"],
            &["arguments"],
            &["action"],
            &["results"],
            &["content_items", "contentItems"],
            &["success"],
            &["saved_path", "savedPath"],
            &["failure"],
        ]),
    )
}

fn completed_image_generation_item(item: &Value, id: String) -> TranscriptItem {
    let title = ["revised_prompt", "revisedPrompt", "saved_path", "savedPath", "status"]
        .into_iter()
        .find_map(|field| item.get(field).and_then(Value::as_str))
        .unwrap_or("");
    TranscriptItem {
        images: crate::protocol::image_generation_images(item),
        // Deliberately omit `result`: it may contain the entire base64 image.
        ..TranscriptItem::new(
            id,
            "imageGeneration",
            title,
            selected_json(item, &[&["status"], &["saved_path", "savedPath"], &["failure"]]),
        )
    }
}

fn qualified_tool_title(item: &Value) -> String {
    let namespace = event_string(item, &["server", "namespace"]);
    let tool = event_string(item, &["tool"]);
    if namespace.is_empty() {
        tool
    } else {
        format!("{namespace}.{tool}")
    }
}

fn event_value<'a>(item: &'a Value, aliases: &[&str]) -> Option<&'a Value> {
    aliases.iter().find_map(|field| item.get(*field))
}

fn event_string(item: &Value, aliases: &[&str]) -> String {
    event_value(item, aliases)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

/// Pretty-print selected fields while preserving their first known wire name.
/// Extension/core rollouts use snake_case while app-server snapshots use
/// camelCase, so each entry is an alias set for one logical field.
fn selected_json(item: &Value, fields: &[&[&str]]) -> String {
    let mut selected = serde_json::Map::new();
    for aliases in fields {
        let Some((field, value)) = aliases
            .iter()
            .find_map(|field| item.get(*field).map(|value| (*field, value)))
        else {
            continue;
        };
        if !value.is_null() {
            selected.insert(field.to_string(), value.clone());
        }
    }
    if selected.is_empty() {
        return String::new();
    }
    serde_json::to_string_pretty(&Value::Object(selected)).unwrap_or_else(|_| "{}".to_string())
}

fn completed_command_title(item: &Value) -> String {
    match item.get("command") {
        Some(Value::String(command)) => command.clone(),
        Some(Value::Array(parts)) => {
            let parts = parts.iter().filter_map(Value::as_str).collect::<Vec<_>>();
            match parts.as_slice() {
                [_, flag, command] if matches!(*flag, "-Command" | "-c" | "/C") => {
                    (*command).to_string()
                },
                _ => parts.join(" "),
            }
        },
        _ => "command".to_string(),
    }
}

fn completed_file_change_item(item: &Value, id: String) -> Option<TranscriptItem> {
    let changes = item.get("changes")?.as_object()?;
    if changes.is_empty() {
        return None;
    }
    let diffs: Vec<String> = changes
        .iter()
        .filter_map(|(path, change)| completed_file_diff(path, change))
        .collect();
    let title = if changes.len() == 1 {
        changes.keys().next().cloned().unwrap_or_default()
    } else {
        format!("{} files", changes.len())
    };
    let text = if diffs.is_empty() {
        changes.keys().cloned().collect::<Vec<_>>().join("\n")
    } else {
        diffs.join("\n")
    };
    Some(TranscriptItem::new(id, "fileChange", title, text))
}

fn completed_file_diff(path: &str, change: &Value) -> Option<String> {
    let raw = change
        .get("unified_diff")
        .or_else(|| change.get("diff"))
        .and_then(Value::as_str)
        .filter(|diff| !diff.trim().is_empty())?;
    if raw.lines().any(|line| line.starts_with("--- "))
        && raw.lines().any(|line| line.starts_with("+++ "))
    {
        return Some(raw.to_string());
    }
    let kind = change
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("update");
    let moved = change
        .get("move_path")
        .or_else(|| change.get("movePath"))
        .and_then(Value::as_str)
        .unwrap_or(path);
    let body = raw.trim_end_matches(['\r', '\n']);
    let (old_path, new_path) = match kind {
        "add" => ("/dev/null".to_string(), format!("b/{moved}")),
        "delete" => (format!("a/{path}"), "/dev/null".to_string()),
        _ => (format!("a/{path}"), format!("b/{moved}")),
    };
    Some(format!("--- {old_path}\n+++ {new_path}\n{body}"))
}
