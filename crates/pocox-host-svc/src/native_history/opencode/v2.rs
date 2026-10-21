//! Canonical v2 session_message windows ordered by native sequence.
use anyhow::{ensure, Context, Result};
use futures::TryStreamExt;
use serde_json::Value;
use sqlx::{Row, SqliteConnection};

use super::{projection, Records, Session, MAX_PAGE_BYTES, MAX_ROWS, MAX_ROW_BYTES};

pub(super) async fn read(
    connection: &mut SqliteConnection,
    metadata: &Session,
    session: &str,
    before: Option<&str>,
    limit: usize,
) -> Result<Records> {
    let revert = match metadata
        .revert
        .as_ref()
        .and_then(|value| value["messageID"].as_str())
    {
        Some(id) => sqlx::query_scalar::<_, i64>(
            "SELECT seq FROM session_message WHERE session_id=? AND id=?",
        )
        .bind(session)
        .bind(id)
        .fetch_optional(&mut *connection)
        .await?
        .context("OpenCode revert boundary is unavailable")?,
        None => i64::MAX,
    };
    let end = boundary(connection, session, before).await?.min(revert);
    let mut boundaries: Vec<i64> = sqlx::query_scalar(
        "SELECT seq FROM session_message WHERE session_id=? AND type='user' AND seq<? ORDER BY \
         seq DESC LIMIT ?",
    )
    .bind(session)
    .bind(end)
    .bind((limit + 1) as i64)
    .fetch_all(&mut *connection)
    .await?;
    let has_older = boundaries.len() > limit;
    boundaries.truncate(limit);
    let start = if has_older { boundaries.last().copied().unwrap_or(0) } else { 0 };
    let mut rows = sqlx::query(
        "SELECT id,type,seq,CASE WHEN length(CAST(data AS BLOB))<=? THEN data END AS data FROM \
         session_message WHERE session_id=? AND seq>=? AND seq<? ORDER BY seq LIMIT ?",
    )
    .bind(MAX_ROW_BYTES as i64)
    .bind(session)
    .bind(start)
    .bind(end)
    .bind(MAX_ROWS + 1)
    .fetch(&mut *connection);
    let mut messages = Vec::new();
    let mut bytes = 0;
    let mut truncated = metadata
        .revert
        .as_ref()
        .is_some_and(|value| value["partID"].is_string());
    while let Some(record) = rows.try_next().await? {
        let data = record.try_get::<Option<String>, _>("data")?;
        bytes += data.as_ref().map_or(0, String::len);
        if messages.len() >= MAX_ROWS as usize || bytes > MAX_PAGE_BYTES {
            truncated = true;
            break;
        }
        let data = match data {
            Some(text) => {
                serde_json::from_str(&text).context("invalid OpenCode message projection")?
            },
            None => {
                truncated = true;
                Value::Null
            },
        };
        messages.push(projection::Message {
            id: record.try_get("id")?,
            kind: record.try_get("type")?,
            data,
        });
    }
    drop(rows);
    Ok(Records {
        messages,
        has_older,
        next_before: has_older.then(|| format!("oc2:{start}")),
        truncated,
    })
}

async fn boundary(
    connection: &mut SqliteConnection,
    session: &str,
    before: Option<&str>,
) -> Result<i64> {
    let Some(cursor) = before else {
        return Ok(i64::MAX);
    };
    if let Some(seq) = cursor.strip_prefix("oc2:") {
        let seq = seq.parse::<i64>()?;
        ensure!(seq >= 0, "invalid native cursor");
        return Ok(seq);
    }
    let (target, single) = match cursor.strip_prefix("turn:") {
        Some(id) => (id, true),
        None => (cursor, false),
    };
    let id = super::message_id(target)?;
    let seq: i64 =
        sqlx::query_scalar("SELECT seq FROM session_message WHERE session_id=? AND id=?")
            .bind(session)
            .bind(id)
            .fetch_optional(&mut *connection)
            .await?
            .context("native turn not found")?;
    if !single {
        return Ok(seq);
    }
    Ok(sqlx::query_scalar::<_, Option<i64>>(
        "SELECT MIN(seq) FROM session_message WHERE session_id=? AND type='user' AND seq>?",
    )
    .bind(session)
    .bind(seq)
    .fetch_one(connection)
    .await?
    .unwrap_or(i64::MAX))
}
