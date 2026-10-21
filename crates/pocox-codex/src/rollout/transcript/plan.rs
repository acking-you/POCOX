//! `update_plan` tool calls as one evolving checklist row per turn.

use serde_json::Value;

use super::TranscriptItem;

/// The `plan` row of an `update_plan` snapshot from either a direct tool call
/// or the JavaScript wrapper used by Codex's composed tool runner. The
/// wrapper's argument is JSON5-compatible JavaScript object syntax; parsing it
/// with a real parser keeps quoted punctuation and escaped text intact.
pub(super) fn snapshot(payload: &Value, fallback_id: &str) -> Option<TranscriptItem> {
    let name = payload.get("name").and_then(Value::as_str)?;
    let plan = if name == "update_plan" {
        let value = payload.get("arguments").or_else(|| payload.get("input"))?;
        parse_json5_value(value)?
    } else if name == "exec" {
        let source = payload.get("input").and_then(Value::as_str)?;
        let argument = js_call_argument(source, "tools.update_plan")?;
        json5::from_str::<Value>(argument).ok()?
    } else {
        return None;
    };
    let text = encode_plan(&plan)?;
    let turn_id = payload
        .get("internal_chat_message_metadata_passthrough")
        .and_then(|metadata| metadata.get("turn_id"))
        .and_then(Value::as_str)
        .or_else(|| payload.get("turn_id").and_then(Value::as_str))
        .filter(|id| !id.is_empty())
        .or_else(|| {
            payload
                .get("call_id")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
        })
        .unwrap_or(fallback_id);
    Some(TranscriptItem::new(format!("plan-{turn_id}"), "plan", "", text))
}

fn parse_json5_value(value: &Value) -> Option<Value> {
    match value {
        Value::Object(_) => Some(value.clone()),
        Value::String(raw) => serde_json::from_str(raw)
            .ok()
            .or_else(|| json5::from_str(raw).ok()),
        _ => None,
    }
}

/// Return the first call argument for `callee(...)`, respecting quoted strings
/// and nested parentheses. The returned slice excludes the outer parentheses.
fn js_call_argument<'a>(source: &'a str, callee: &str) -> Option<&'a str> {
    let callee_start = source.find(callee)?;
    let open_rel = source[callee_start + callee.len()..].find('(')?;
    let open = callee_start + callee.len() + open_rel;
    let mut depth = 0_u32;
    let mut quote = None;
    let mut escaped = false;
    for (offset, ch) in source[open..].char_indices() {
        if let Some(delimiter) = quote {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == delimiter {
                quote = None;
            }
            continue;
        }
        if matches!(ch, '\'' | '"' | '`') {
            quote = Some(ch);
            continue;
        }
        match ch {
            '(' => depth += 1,
            ')' => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    return source.get(open + 1..open + offset);
                }
            },
            _ => {},
        }
    }
    None
}

/// The plan as Markdown: its explanation, then a `- [x]` / `- [~]` / `- [ ]`
/// line per non-empty step; `None` without any step.
fn encode_plan(plan: &Value) -> Option<String> {
    let steps = plan.get("plan")?.as_array()?;
    if steps.is_empty() {
        return None;
    }
    let mut lines = Vec::with_capacity(steps.len() + 1);
    if let Some(explanation) = plan
        .get("explanation")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
    {
        lines.push(explanation.to_string());
    }
    let explanation_lines = lines.len();
    lines.extend(steps.iter().filter_map(|step| {
        let text = step.get("step").and_then(Value::as_str)?.trim();
        if text.is_empty() {
            return None;
        }
        let mark = match step.get("status").and_then(Value::as_str) {
            Some("completed") => "x",
            Some("in_progress") | Some("inProgress") => "~",
            _ => " ",
        };
        Some(format!("- [{mark}] {text}"))
    }));
    (lines.len() > explanation_lines).then(|| lines.join("\n"))
}
