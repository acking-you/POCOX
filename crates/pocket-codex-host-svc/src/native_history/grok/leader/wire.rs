//! Grok's leader IPC as a read-only follower speaks it
//! (`xai-grok-shell/src/leader/protocol.rs`): frames are a 4-byte
//! big-endian length and a JSON message of at most 64 MiB, and ACP travels
//! as JSON-RPC text inside `acp` messages.

use anyhow::{bail, ensure, Context, Result};
use bytes::{Buf, BytesMut};
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// The leader's own frame bound.
const MAX_FRAME: u32 = 64 * 1024 * 1024;
/// The leader protocol this follower speaks (`LEADER_PROTOCOL_VERSION`).
pub(super) const PROTOCOL_VERSION: u32 = 1;
/// How this follower names itself to the leader (its logs and telemetry).
const CLIENT_TYPE: &str = "pocox-follower";

/// Request id of the `_x.ai/session/info` that subscribes this follower.
pub(super) const INFO_ID: &str = "pocox-follow-info";
/// Request id of the `_x.ai/sessions/list` roster read.
pub(super) const ROSTER_ID: &str = "pocox-follow-roster";

/// The leader's messages a follower acts on (`ServerMessage`).
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(super) enum Server {
    Registered {
        #[serde(default = "ready_default")]
        ready: bool,
        #[serde(default)]
        leader_protocol_version: Option<u32>,
        #[serde(default)]
        leader_binary_version: Option<String>,
    },
    LeaderReady,
    Acp {
        payload: String,
    },
    Error {
        code: i32,
        message: String,
    },
    ShuttingDown {},
    Shutdown,
    #[serde(other)]
    Other,
}

/// Leaders that predate `ready` were ready when they answered.
fn ready_default() -> bool {
    true
}

/// Frames read into a buffer that outlives each read, so a read that loses
/// a `select!` leaves a partial frame for the next one (as the leader's own
/// `FrameReader`).
pub(super) struct Frames<R> {
    reader: R,
    buf: BytesMut,
}

impl<R: AsyncRead + Unpin> Frames<R> {
    pub(super) fn new(reader: R) -> Self {
        Self {
            reader,
            buf: BytesMut::new(),
        }
    }

    /// The next message; cancel-safe. Larger frames than the leader itself
    /// allows end the connection, and so does malformed JSON; an unknown
    /// message kind is [`Server::Other`].
    pub(super) async fn next(&mut self) -> Result<Server> {
        loop {
            if let Some(header) = self.buf.first_chunk::<4>() {
                let len = u32::from_be_bytes(*header);
                ensure!(len <= MAX_FRAME, "the Grok leader sent an oversized frame");
                let end = 4 + len as usize;
                if self.buf.len() >= end {
                    self.buf.advance(4);
                    let body = self.buf.split_to(len as usize);
                    return serde_json::from_slice(&body)
                        .context("the Grok leader sent an unreadable message");
                }
                self.buf.reserve(end - self.buf.len());
            }
            if self.reader.read_buf(&mut self.buf).await? == 0 {
                bail!("the Grok leader closed the connection");
            }
        }
    }
}

async fn write<W: AsyncWrite + Unpin>(writer: &mut W, message: &Value) -> Result<()> {
    let body = serde_json::to_vec(message)?;
    let len = u32::try_from(body.len()).context("message too large")?;
    writer.write_all(&len.to_be_bytes()).await?;
    writer.write_all(&body).await?;
    writer.flush().await?;
    Ok(())
}

/// Register as a stdio client with no capabilities. Stdio, not headless:
/// a headless client makes the leader connect to Grok's web relay. No
/// capability is claimed, and this client never sends `initialize` or
/// `session/load`, so the leader injects nothing into the session.
pub(super) async fn register<W: AsyncWrite + Unpin>(writer: &mut W) -> Result<()> {
    write(
        writer,
        &json!({"type": "register", "client_type": CLIENT_TYPE, "mode": "stdio",
            "capabilities": {}}),
    )
    .await
}

/// One JSON-RPC request of this follower, carried as ACP.
pub(super) async fn request<W: AsyncWrite + Unpin>(
    writer: &mut W,
    id: &str,
    method: &str,
    params: Value,
) -> Result<()> {
    let payload = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
    write(writer, &json!({"type": "acp", "payload": payload.to_string()})).await
}

/// Tell the leader this client leaves.
pub(super) async fn disconnect<W: AsyncWrite + Unpin>(writer: &mut W) -> Result<()> {
    write(writer, &json!({"type": "disconnect"})).await
}

/// Check a registration answer against the protocol this follower speaks.
/// A leader that names no version predates the versioned protocol.
pub(super) fn accept_registration(version: Option<u32>, binary: Option<&str>) -> Result<()> {
    match version {
        Some(PROTOCOL_VERSION) => Ok(()),
        Some(other) => bail!(
            "the Grok leader speaks protocol {other} ({}); only {PROTOCOL_VERSION} is followed",
            binary.unwrap_or("unknown version")
        ),
        None => bail!("the Grok leader does not name its protocol version"),
    }
}

/// What one ACP payload from the leader is.
#[derive(Debug, PartialEq)]
pub(super) enum Payload {
    /// An answer to one of this follower's requests.
    Answer { id: String, result: Option<Value>, error: bool },
    /// A request the session's user answers in their own client: a tool
    /// permission, a question, a plan approval or an MCP elicitation. Every
    /// subscriber receives it and the first answer wins; this follower
    /// never answers.
    Interaction,
    /// A request only the session's driver receives: this follower became
    /// the driver, so its terminal client has gone.
    DriverRequest,
    /// A notification, with its method unwrapped from the gateway form.
    Notification { method: String, params: Value },
    /// Anything else.
    Ignored,
}

/// Grok's interaction requests (`leader/server.rs` `is_interaction_request`).
const INTERACTIONS: [&str; 4] = [
    "session/request_permission",
    "x.ai/ask_user_question",
    "x.ai/exit_plan_mode",
    "x.ai/mcp/elicit",
];

/// Classify a payload. Gateway-forwarded extensions arrive wrapped as
/// `{"method": "_x.ai/foo", "params": {"method": "x.ai/foo", "params": …}}`
/// and direct ones as `{"method": "_x.ai/foo", "params": …}`; both name
/// `x.ai/foo` here (`leader/server.rs` `method_of`).
pub(super) fn classify(payload: &str) -> Payload {
    let Ok(mut message) = serde_json::from_str::<Value>(payload) else { return Payload::Ignored };
    let id = message.get("id").cloned();
    let Some(top) = message["method"].as_str().map(str::to_owned) else {
        return match id {
            Some(Value::String(id)) => Payload::Answer {
                id,
                error: message.get("error").is_some_and(|e| !e.is_null()),
                result: message.get_mut("result").map(Value::take),
            },
            _ => Payload::Ignored,
        };
    };
    let mut params = message
        .get_mut("params")
        .map(Value::take)
        .unwrap_or(Value::Null);
    let method = match top.strip_prefix('_') {
        Some(stripped) => match params["method"].as_str() {
            Some(inner) => {
                let inner = inner.to_owned();
                params = params
                    .get_mut("params")
                    .map(Value::take)
                    .unwrap_or(Value::Null);
                inner
            },
            None => stripped.to_owned(),
        },
        None => top,
    };
    if id.is_some() {
        return if INTERACTIONS.contains(&method.as_str()) {
            Payload::Interaction
        } else {
            Payload::DriverRequest
        };
    }
    Payload::Notification {
        method,
        params,
    }
}

/// Grok wraps extension answers as `{"result": …, "error"?: …}`.
pub(super) fn ext_result(result: &Value) -> Option<&Value> {
    match result.get("error") {
        Some(Value::Null) | None => Some(result.get("result").unwrap_or(result)),
        Some(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn payloads_are_classified_like_the_leader_routes_them() {
        assert_eq!(
            classify(r#"{"jsonrpc":"2.0","id":"pocox-follow-info","result":{"result":{}}}"#),
            Payload::Answer {
                id: INFO_ID.into(),
                result: Some(json!({"result": {}})),
                error: false
            }
        );
        let permission = r#"{"jsonrpc":"2.0","id":"7|3","method":"session/request_permission",
            "params":{"sessionId":"s","toolCall":{"toolCallId":"t"}}}"#;
        assert_eq!(classify(permission), Payload::Interaction);
        let wrapped_question = r#"{"jsonrpc":"2.0","id":4,"method":"_x.ai/ask_user_question",
            "params":{"method":"x.ai/ask_user_question","params":{"sessionId":"s"}}}"#;
        assert_eq!(classify(wrapped_question), Payload::Interaction);
        let fs =
            r#"{"jsonrpc":"2.0","id":5,"method":"fs/read_text_file","params":{"sessionId":"s"}}"#;
        assert_eq!(classify(fs), Payload::DriverRequest);
        assert_eq!(
            classify(
                r#"{"jsonrpc":"2.0","method":"_x.ai/queue/changed","params":{"sessionId":"s"}}"#
            ),
            Payload::Notification {
                method: "x.ai/queue/changed".into(),
                params: json!({"sessionId": "s"})
            }
        );
        assert_eq!(classify("not json"), Payload::Ignored);
    }

    #[test]
    fn only_the_known_protocol_is_followed() {
        assert!(accept_registration(Some(1), Some("1.0.62")).is_ok());
        assert!(accept_registration(Some(2), Some("9.0.0")).is_err());
        assert!(accept_registration(None, None).is_err());
    }
}
