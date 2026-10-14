//! Whitelisted native conversation fields. Provider metadata, credentials,
//! configuration and tool implementation details never enter the gateway.

use serde_json::{Map, Value};

use super::schema::Message;

fn fields(value: &Value, names: &[&str]) -> Value {
    Value::Object(
        names
            .iter()
            .filter_map(|name| {
                value
                    .get(*name)
                    .map(|value| ((*name).into(), value.clone()))
            })
            .collect::<Map<_, _>>(),
    )
}

/// Project native message metadata onto the conversation wire contract.
pub fn info(value: &Value) -> Value {
    let mut result = fields(value, &[
        "id",
        "sessionID",
        "role",
        "parentID",
        "agent",
        "mode",
        "variant",
        "modelID",
        "providerID",
        "finish",
        "cost",
    ]);
    for (name, names) in [
        ("time", &["created", "completed"][..]),
        ("model", &["providerID", "modelID", "variant"][..]),
        ("tokens", &["input", "output", "reasoning"][..]),
    ] {
        if value[name].is_object() {
            result[name] = fields(&value[name], names);
        }
    }
    if value["error"].is_object() {
        // API errors may carry response headers, bodies and provider details.
        result["error"] = fields(&value["error"], &["name"]);
    }
    result
}

/// Keep only supported native parts; unknown provider-private parts are
/// omitted.
pub fn part(value: &Value) -> Option<Value> {
    let names: &[&str] = match value["type"].as_str()? {
        "text" | "reasoning" => &["text", "synthetic", "ignored"],
        "tool" => &["callID", "tool"],
        "file" => &["mime", "filename", "url"],
        "step-start" | "step-finish" => &["reason", "cost"],
        "subtask" => &["prompt", "description", "agent"],
        "agent" => &["name"],
        "compaction" => &["auto", "overflow"],
        "retry" => &["attempt"],
        _ => return None,
    };
    let mut result = fields(value, &["id", "sessionID", "messageID", "type"]);
    for &name in names {
        if let Some(field) = value.get(name) {
            // The controller cannot display larger inline previews. Keep the
            // file part so it renders an explicit unavailable attachment,
            // without relaying a large original image on every history read.
            result[name] =
                if name == "url" && field.as_str().is_some_and(|url| url.len() > 512 * 1024) {
                    Value::String(String::new())
                } else {
                    field.clone()
                };
        }
    }
    if value["time"].is_object() {
        result["time"] = fields(&value["time"], &["start", "end"]);
    }
    if value["type"] == "tool" {
        let state = &value["state"];
        result["state"] = fields(state, &["status", "input", "title", "output", "error"]);
        if state["time"].is_object() {
            result["state"]["time"] = fields(&state["time"], &["start", "end"]);
        }
        if let Some(attachments) = state["attachments"].as_array() {
            result["state"]["attachments"] = Value::Array(
                attachments
                    .iter()
                    .filter(|attachment| attachment["type"] == "file")
                    .filter_map(part)
                    .collect(),
            );
        }
    }
    Some(result)
}

/// Sanitize an HTTP history window using the same schema as the live fold.
pub fn message(message: Message) -> Message {
    Message {
        info: info(&message.info),
        parts: message.parts.iter().filter_map(part).collect(),
    }
}

/// Public pending permission/question fields, never tool permission metadata.
pub fn pending(value: &Value, question: bool) -> Value {
    let mut result = fields(value, &["id", "sessionID"]);
    if question {
        result["questions"] = Value::Array(
            value["questions"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|q| {
                    let mut question = fields(q, &["question", "header", "multiple", "custom"]);
                    question["options"] = Value::Array(
                        q["options"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .map(|option| fields(option, &["label", "description"]))
                            .collect(),
                    );
                    question
                })
                .collect(),
        );
    } else {
        for name in ["permission", "patterns", "always"] {
            if let Some(value) = value.get(name) {
                result[name] = value.clone();
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn private_metadata_does_not_escape_through_history_or_pending_requests() {
        let value = json!({"id":"prt_x","type":"tool","metadata":{"token":"SECRET"},
            "state":{"status":"completed","output":"visible", "metadata":{"secret":"SECRET"},
            "attachments":[{"type":"file","url":"data:image/png;base64,AA==","metadata":"SECRET"}]}});
        let output = part(&value).expect("supported part").to_string();
        assert!(output.contains("visible"));
        assert!(!output.contains("SECRET"));
        assert!(!info(
            &json!({"error":{"name":"APIError","data":{"responseHeaders":{"key":"SECRET"}}}})
        )
        .to_string()
        .contains("SECRET"));
        assert!(!pending(&json!({"permission":"bash","metadata":{"token":"SECRET"}}), false)
            .to_string()
            .contains("SECRET"));
    }
}
