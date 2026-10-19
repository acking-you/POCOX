//! V2 `{id, type, data}` frames as fold events. Execution start and end become
//! the 1.x busy and idle status, which the fold needs to see before it ends a
//! turn; boundaries that change a session's history or pending requests become
//! payload-free invalidations; the rest, including every per-token delta, are
//! dropped after reading their type alone.

use std::borrow::Cow;

use serde::{de::DeserializeOwned, Deserialize};
use serde_json::{json, Value};

use crate::opencode::{client::ClientError, events::Event};

/// Kinds that end a visible step or change pending requests, each carrying
/// `data.sessionID`.
const CHANGES: &[&str] = &[
    "permission.asked",
    "permission.replied",
    "form.replied",
    "form.cancelled",
    "session.text.ended",
    "session.reasoning.ended",
    "session.tool.called",
    "session.tool.success",
    "session.tool.failed",
    "session.step.ended",
    "session.step.failed",
    "session.renamed",
    "session.deleted",
];

#[derive(Deserialize)]
struct Kind<'a> {
    #[serde(rename = "type", borrow)]
    kind: Cow<'a, str>,
}

#[derive(Deserialize)]
struct Frame<T> {
    data: T,
}

#[derive(Deserialize)]
struct Owner<'a> {
    #[serde(rename = "sessionID", borrow)]
    session: Cow<'a, str>,
}

#[derive(Deserialize)]
struct Created<'a> {
    #[serde(borrow)]
    form: Owner<'a>,
}

fn parse<'a, T: Deserialize<'a>>(data: &'a [u8]) -> Result<T, ClientError> {
    serde_json::from_slice(data).map_err(|_| ClientError::InvalidResponse)
}

fn payload<T: DeserializeOwned>(data: &[u8]) -> Result<T, ClientError> {
    parse::<Frame<T>>(data).map(|frame| frame.data)
}

pub(super) fn decode(data: &[u8]) -> Result<Option<Event>, ClientError> {
    let Kind {
        kind,
    } = parse(data)?;
    let status = match &*kind {
        "session.execution.started" => Some("busy"),
        "session.execution.succeeded"
        | "session.execution.failed"
        | "session.execution.interrupted" => Some("idle"),
        _ => None,
    };
    if let Some(status) = status {
        let Owner {
            session,
        } = parse::<Frame<Owner>>(data)?.data;
        let properties = json!({"sessionID": session, "status": {"type": status}});
        return Ok(Some(event("session.status".into(), properties)));
    }
    let session = match &*kind {
        "server.connected" => return Ok(Some(event(kind.into_owned(), Value::Null))),
        // Already the 1.x `{sessionID, status: {type}}` shape, retry included.
        "session.status" => return Ok(Some(event(kind.into_owned(), payload(data)?))),
        // MCP elicitations use a `global` owner that is not a session.
        "form.created" => parse::<Frame<Created>>(data)?.data.form.session,
        kind if CHANGES.contains(&kind) => parse::<Frame<Owner>>(data)?.data.session,
        _ => return Ok(None),
    };
    Ok((session != "global").then(|| event("host.changed".into(), json!({ "sessionID": session }))))
}

fn event(kind: String, properties: Value) -> Event {
    Event {
        directory: None,
        kind,
        properties,
    }
}
