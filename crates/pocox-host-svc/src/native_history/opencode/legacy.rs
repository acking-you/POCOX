//! Legacy message/part storage; keysets mirror upstream time/id ordering.

use anyhow::{ensure, Context, Result};
use serde_json::{json, Value};
use sqlx::{Row, SqliteConnection};

use super::{projection, Records, Session, MAX_PAGE_BYTES, MAX_ROWS, MAX_ROW_BYTES};

type Key = (i64, String);

async fn key(connection: &mut SqliteConnection, session: &str, id: &str) -> Result<Key> {
    sqlx::query_as("SELECT time_created,id FROM message WHERE session_id=? AND id=?")
        .bind(session)
        .bind(id)
        .fetch_optional(connection)
        .await?
        .context("OpenCode message boundary is unavailable")
}

async fn end_key(
    connection: &mut SqliteConnection,
    session: &str,
    before: Option<&str>,
) -> Result<Key> {
    let Some(before) = before else {
        return Ok((i64::MAX, String::new()));
    };
    let (target, single) = match before.strip_prefix("turn:") {
        Some(id) => (id, true),
        None => (before, false),
    };
    let start = key(connection, session, super::message_id(target)?).await?;
    if !single {
        return Ok(start);
    }
    Ok(sqlx::query_as(
        "SELECT time_created,id FROM message WHERE session_id=? AND CASE WHEN length(CAST(data AS \
         BLOB))<=262144 THEN json_extract(data,'$.role') END='user' AND (time_created,id)>(?,?) \
         ORDER BY time_created,id LIMIT 1",
    )
    .bind(session)
    .bind(start.0)
    .bind(start.1)
    .fetch_optional(connection)
    .await?
    .unwrap_or((i64::MAX, String::new())))
}

pub(super) async fn read(
    connection: &mut SqliteConnection,
    metadata: &Session,
    session: &str,
    before: Option<&str>,
    limit: usize,
) -> Result<Records> {
    ensure!(
        super::table_exists(connection, "part").await?,
        "unsupported OpenCode legacy parts schema"
    );
    let revert = match metadata
        .revert
        .as_ref()
        .and_then(|v| v["messageID"].as_str())
    {
        Some(id) => key(connection, session, id).await?,
        None => (i64::MAX, String::new()),
    };
    // A partial reverted message is omitted conservatively and visibly. No
    // reverted tool output or following assistant response may leak through.
    let end = end_key(connection, session, before)
        .await?
        .min(revert.clone());
    let mut boundaries: Vec<Key> = sqlx::query_as(
        "SELECT time_created,id FROM message WHERE session_id=? AND CASE WHEN length(CAST(data AS \
         BLOB))<=262144 THEN json_extract(data,'$.role') END='user' AND (time_created,id)<(?,?) \
         ORDER BY time_created DESC,id DESC LIMIT ?",
    )
    .bind(session)
    .bind(end.0)
    .bind(&end.1)
    .bind((limit + 1) as i64)
    .fetch_all(&mut *connection)
    .await?;
    let has_older = boundaries.len() > limit;
    boundaries.truncate(limit);
    let start = if has_older {
        boundaries
            .last()
            .cloned()
            .context("missing page boundary")?
    } else {
        (0, String::new())
    };
    let rows = sqlx::query(
        "SELECT id,CASE WHEN length(CAST(data AS BLOB))<=262144 THEN json_object( \
         'role',json_extract(data,'$.role'),'error',json_object('data',json_object( \
         'message',substr(json_extract(data,'$.error.data.message'),1,1024)))) END AS data FROM \
         message WHERE session_id=? AND (time_created,id)>=(?,?) AND (time_created,id)<(?,?) \
         ORDER BY time_created,id LIMIT ?",
    )
    .bind(session)
    .bind(start.0)
    .bind(&start.1)
    .bind(end.0)
    .bind(&end.1)
    .bind(MAX_ROWS + 1)
    .fetch_all(&mut *connection)
    .await?;
    let mut records = Records {
        messages: Vec::new(),
        has_older,
        next_before: has_older.then(|| format!("oc1:{}", start.1)),
        truncated: metadata
            .revert
            .as_ref()
            .is_some_and(|v| v["partID"].is_string()),
    };
    let mut bytes = 0;
    for row in rows {
        let id: String = row.try_get("id")?;
        let data: Option<String> = row.try_get("data")?;
        bytes += data.as_ref().map_or(0, String::len);
        if bytes > MAX_PAGE_BYTES || records.messages.len() >= MAX_ROWS as usize {
            records.truncated = true;
            break;
        }
        let data: Value = data
            .map(|v| serde_json::from_str(&v))
            .transpose()?
            .unwrap_or(Value::Null);
        let kind = data["role"].as_str().unwrap_or("unknown").to_owned();
        let parts =
            read_parts(connection, session, &id, &mut bytes, &mut records.truncated).await?;
        records.messages.push(projection::Message {
            id,
            kind: kind.clone(),
            data: project(&kind, &data, parts),
        });
    }
    Ok(records)
}

async fn read_parts(
    connection: &mut SqliteConnection,
    session: &str,
    message: &str,
    bytes: &mut usize,
    truncated: &mut bool,
) -> Result<Vec<Value>> {
    use futures::TryStreamExt;
    let mut rows = sqlx::query(
        "SELECT id,CASE WHEN length(CAST(data AS BLOB))<=? THEN data END AS data FROM part WHERE \
         session_id=? AND message_id=? ORDER BY id LIMIT ?",
    )
    .bind(MAX_ROW_BYTES as i64)
    .bind(session)
    .bind(message)
    .bind(MAX_ROWS + 1)
    .fetch(connection);
    let mut parts = Vec::new();
    while let Some(row) = rows.try_next().await? {
        let data: Option<String> = row.try_get("data")?;
        *bytes += data.as_ref().map_or(0, String::len);
        if *bytes > MAX_PAGE_BYTES || parts.len() >= MAX_ROWS as usize {
            *truncated = true;
            break;
        }
        let mut part: Value = data
            .map(|v| serde_json::from_str(&v))
            .transpose()?
            .unwrap_or(Value::Null);
        if part.is_null() {
            *truncated = true;
        } else {
            part["id"] = json!(row.try_get::<String, _>("id")?);
        }
        parts.push(part);
    }
    Ok(parts)
}

fn project(kind: &str, info: &Value, parts: Vec<Value>) -> Value {
    if info.is_null() {
        return Value::Null;
    }
    let mut text = String::new();
    let mut files = Vec::new();
    let mut content = Vec::new();
    for part in parts {
        match part["type"].as_str() {
            Some("text") if part["synthetic"]!=true && part["ignored"]!=true => {
                if kind=="user" {
                    if !text.is_empty() { text.push('\n'); }
                    text.push_str(part["text"].as_str().unwrap_or_default());
                } else { content.push(json!({"type":"text","id":part["id"],"text":part["text"]})); }
            },
            Some("file") => files.push(json!({"url":part["url"]})),
            Some("tool") => content.push(json!({"type":"tool","id":part["callID"],"name":part["tool"],
                "state":{"status":part["state"]["status"],"input":part["state"]["input"],
                  "content":[{"type":"text","text":part["state"]["output"]}],
                  "error":{"message":part["state"]["error"]},"attachments":part["state"]["attachments"]}})),
            Some("compaction") => content.push(json!({"type":"text","text":"[Earlier context compacted]"})),
            Some("text"|"reasoning"|"step-start"|"step-finish"|"snapshot"|"patch"|"agent") => {},
            _ => content.push(json!({"type":"unsupported"})),
        }
    }
    if kind == "user" {
        json!({"text":text,"files":files,"omitted":!content.is_empty()})
    } else {
        json!({"content":content,"files":files,"error":{"message":info["error"]["data"]["message"]}})
    }
}
