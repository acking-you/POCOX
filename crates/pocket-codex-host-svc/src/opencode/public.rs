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
        result["error"] = error(&value["error"]);
    }
    result
}

/// Describe a provider failure without forwarding its response or credentials.
/// The same projection accepts its own output for history/live reconciliation.
pub fn error(value: &Value) -> Value {
    let data = value.get("data").unwrap_or(value);
    let name = value["name"]
        .as_str()
        .filter(|name| {
            matches!(
                *name,
                "APIError"
                    | "ProviderAuthError"
                    | "MessageAbortedError"
                    | "MessageOutputLengthError"
                    | "ContextOverflowError"
            )
        })
        .unwrap_or("UnknownError");
    let status = data["statusCode"]
        .as_u64()
        .filter(|code| (400..600).contains(code));
    // Inspect only bounded classification fields. Even the provider's message
    // can contain echoed request bodies, URLs or secrets, so never publish it.
    let body = data["responseBody"]
        .as_str()
        .filter(|body| body.len() <= 8192)
        .and_then(|body| serde_json::from_str::<Value>(body).ok())
        .unwrap_or_default();
    let native_code = body["error"]["code"]
        .as_str()
        .or(body["error"]["type"].as_str())
        .unwrap_or_default();
    let hint = if value.get("data").is_none() {
        value["code"].as_str().unwrap_or_default()
    } else {
        match native_code {
            "RegionError" | "unsupported_country_region_territory" => "region_unavailable",
            "model_not_found" | "ModelNotFoundError" => "model_unavailable",
            "insufficient_quota" | "quota_exceeded" | "usage_not_included" => "quota_exceeded",
            "context_length_exceeded" => "context_length",
            _ if data["message"] == "This model is not available in your country" => {
                "region_unavailable"
            },
            _ => "",
        }
    };
    let code = match name {
        "MessageAbortedError" => "cancelled",
        "ProviderAuthError" => "authentication",
        "ContextOverflowError" => "context_length",
        "MessageOutputLengthError" => "output_length",
        _ => match hint {
            "region_unavailable"
            | "authentication"
            | "permission_denied"
            | "model_unavailable"
            | "rate_limited"
            | "quota_exceeded"
            | "context_length"
            | "output_length"
            | "provider_unavailable"
            | "invalid_request"
            | "cancelled" => hint,
            _ => match status {
                Some(401) => "authentication",
                Some(403) => "permission_denied",
                Some(404) => "model_unavailable",
                Some(429) => "rate_limited",
                Some(413) => "context_length",
                Some(400 | 422) => "invalid_request",
                Some(408 | 500..=599) => "provider_unavailable",
                _ => "unknown",
            },
        },
    };
    let message = match code {
        "region_unavailable" => "This model is unavailable in your region. Choose another model.",
        "authentication" => "The provider could not authenticate. Check its API key or sign-in.",
        "permission_denied" => {
            "The provider denied access. Check your permissions or choose another model."
        },
        "model_unavailable" => {
            "The selected model or provider endpoint is unavailable. Check the configuration or \
             choose another model."
        },
        "rate_limited" => "The provider is receiving too many requests. Wait before retrying.",
        "quota_exceeded" => {
            "The provider's usage allowance is exhausted. Check your account or choose another \
             provider."
        },
        "context_length" => {
            "The conversation exceeds this model's input limit. Shorten it or start a new \
             conversation."
        },
        "output_length" => {
            "The model reached its output limit before finishing. Ask it to continue."
        },
        "provider_unavailable" => {
            "The provider is temporarily unavailable. Retry later or choose another model."
        },
        "invalid_request" => {
            "The provider rejected this request. Check the model and input before retrying."
        },
        "cancelled" => "The response was stopped.",
        _ => "The model could not complete the response. Retry or choose another model.",
    };
    let retryable = matches!(code, "rate_limited" | "provider_unavailable" | "unknown")
        && data["isRetryable"]
            .as_bool()
            .or(data["retryable"].as_bool())
            .unwrap_or(code != "unknown");
    let mut result =
        serde_json::json!({"name":name,"code":code,"message":message,"retryable":retryable});
    if let Some(status) = status {
        result["statusCode"] = status.into();
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
    fn provider_errors_keep_actionable_classification_without_private_response_data() {
        for (name, status, body, expected, retryable) in [
            ("APIError", 403, json!({"error":{"type":"RegionError"}}), "region_unavailable", false),
            ("APIError", 401, Value::Null, "authentication", false),
            ("APIError", 403, Value::Null, "permission_denied", false),
            ("APIError", 404, Value::Null, "model_unavailable", false),
            ("APIError", 429, Value::Null, "rate_limited", true),
            (
                "APIError",
                429,
                json!({"error":{"code":"insufficient_quota"}}),
                "quota_exceeded",
                false,
            ),
            ("APIError", 503, Value::Null, "provider_unavailable", true),
            ("APIError", 400, Value::Null, "invalid_request", false),
            ("ContextOverflowError", 400, Value::Null, "context_length", false),
            ("MessageOutputLengthError", 400, Value::Null, "output_length", false),
            ("MessageAbortedError", 400, Value::Null, "cancelled", false),
        ] {
            let value = json!({"name":name,"data":{"statusCode":status,"isRetryable":true,
                "responseBody":body.to_string(),"message":"SECRET echoed request",
                "responseHeaders":{"authorization":"SECRET"},"metadata":{"token":"SECRET"}}});
            let mapped = error(&value);
            assert_eq!(mapped["code"], expected);
            assert_eq!(mapped["retryable"], retryable);
            assert_eq!(mapped["statusCode"], status);
            assert!(!mapped.to_string().contains("SECRET"));
            assert_eq!(error(&mapped), mapped, "live/history projection is idempotent");
        }
    }

    #[test]
    fn unknown_or_oversized_error_bodies_are_never_exposed_or_guessed() {
        for body in [
            "<html>SECRET</html>".to_owned(),
            "SECRET".repeat(2000),
            json!({"error":{"type":"SECRET","message":"SECRET"}}).to_string(),
        ] {
            let mapped = error(&json!({"name":"SECRET", "data":{
                "message":"SECRET", "responseBody":body,"statusCode":999,"isRetryable":false}}));
            assert_eq!(mapped["code"], "unknown");
            assert!(mapped.get("statusCode").is_none());
            assert_eq!(mapped["retryable"], false);
            assert!(!mapped.to_string().contains("SECRET"));
        }
        let legacy = error(&json!({"name":"ProviderAuthError"}));
        assert_eq!(legacy["code"], "authentication");
    }

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
