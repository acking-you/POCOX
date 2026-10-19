//! Read-only OpenCode SQLite projections. No runtime, migrations or server.

use std::{path::PathBuf, time::Duration};

use anyhow::{ensure, Context, Result};
use pocket_codex_core::history_sync::digest_bytes;
use serde_json::{json, Value};
use sqlx::{sqlite::SqliteConnectOptions, ConnectOptions, Connection, Row, SqliteConnection};

use super::NativePage;

mod legacy;
mod projection;
mod v2;

const MAX_ROW_BYTES: usize = 256 * 1024;
const MAX_PAGE_BYTES: usize = 8 * 1024 * 1024;
const MAX_ROWS: i64 = 1024;

/// An existing host-local OpenCode database, opened without write permission.
/// Construction never creates directories, installs packages or starts agents.
pub struct OpenCodeHistory {
    path: PathBuf,
}

/// Where sessions are kept. OpenCode 2 copies them into `session_v2` when it
/// opens a database and leaves the 1.x table behind; a session 1.x writes
/// after that exists only there.
#[derive(Clone, Copy)]
enum Sessions {
    V1,
    V2,
    Both,
}

/// One session query over the tables in use; the columns it reads have the
/// same names in both.
macro_rules! sessions {
    ($head:literal, $table:ident, $tail:literal) => {
        match $table {
            Sessions::V1 => concat!($head, " FROM session ", $tail),
            Sessions::V2 => concat!($head, " FROM session_v2 ", $tail),
            Sessions::Both => concat!(
                $head,
                " FROM (SELECT id,directory,title,parent_id,time_created,time_updated,revert FROM \
                 session_v2 UNION ALL SELECT \
                 id,directory,title,parent_id,time_created,time_updated,revert FROM session WHERE \
                 id NOT IN (SELECT id FROM session_v2)) ",
                $tail
            ),
        }
    };
}

impl Sessions {
    async fn detect(connection: &mut SqliteConnection) -> Result<Self> {
        let current = table_exists(connection, "session_v2").await?;
        Ok(match (current, table_exists(connection, "session").await?) {
            (true, true) => Self::Both,
            (true, false) => Self::V2,
            (false, _) => Self::V1,
        })
    }
}

struct Session {
    cwd: String,
    title: String,
    created: i64,
    updated: i64,
    revert: Option<Value>,
}

impl OpenCodeHistory {
    /// Select an explicit, absolute database path on the source host.
    pub fn new(path: PathBuf) -> Result<Self> {
        ensure!(path.is_absolute(), "native history requires an absolute database path");
        Ok(Self {
            path,
        })
    }

    fn identity(&self) -> Result<String> {
        let meta =
            std::fs::metadata(&self.path).context("OpenCode history database is unavailable")?;
        ensure!(meta.is_file(), "OpenCode history source is not a file");
        #[cfg(unix)]
        let file = {
            use std::os::unix::fs::MetadataExt;
            format!("{}:{}", meta.dev(), meta.ino())
        };
        #[cfg(not(unix))]
        let file = format!("{:?}", meta.created().context("database identity unavailable")?);
        Ok(digest_bytes(
            format!("{}:{file}:{:?}", self.path.display(), meta.created().ok()).as_bytes(),
        ))
    }

    fn revision_stamp(&self) -> Result<String> {
        let mut stamp = self.identity()?;
        for path in [self.path.clone(), PathBuf::from(format!("{}-wal", self.path.display()))] {
            if let Ok(meta) = std::fs::metadata(path) {
                stamp.push_str(&format!(":{}:{:?}", meta.len(), meta.modified().ok()));
            }
        }
        Ok(digest_bytes(stamp.as_bytes()))
    }

    async fn connect(&self) -> Result<(SqliteConnection, String)> {
        let identity = self.identity()?;
        let options = SqliteConnectOptions::new()
            .filename(&self.path)
            .read_only(true)
            .create_if_missing(false)
            .busy_timeout(Duration::from_secs(2))
            .pragma("query_only", "ON")
            .disable_statement_logging();
        let connection = SqliteConnection::connect_with(&options)
            .await
            .context("opening the existing OpenCode history database read-only")?;
        ensure!(identity == self.identity()?, "native source changed; retry");
        Ok((connection, identity))
    }

    /// List one bounded page of persisted sessions, without ACP admission.
    pub async fn list_sessions(&self, cursor: Option<&str>, limit: usize) -> Result<Value> {
        ensure!((1..=100).contains(&limit), "invalid native inventory limit");
        let offset = cursor
            .map(str::parse::<u32>)
            .transpose()
            .context("invalid cursor")?
            .unwrap_or(0);
        ensure!(offset <= 100_000, "invalid cursor");
        let (mut connection, identity) = self.connect().await?;
        let table = Sessions::detect(&mut connection).await?;
        let rows = sqlx::query(sessions!(
            "SELECT id,CASE WHEN length(CAST(directory AS BLOB))<=16384 THEN directory END AS \
             directory, substr(title,1,4096) AS title,parent_id, \
             strftime('%Y-%m-%dT%H:%M:%fZ',time_updated/1000.0,'unixepoch') AS updated",
            table,
            "ORDER BY time_updated DESC,id DESC LIMIT ? OFFSET ?"
        ))
        .bind((limit + 1) as i64)
        .bind(i64::from(offset))
        .fetch_all(&mut connection)
        .await?;
        let has_more = rows.len() > limit;
        let sessions: Result<Vec<_>> = rows
            .iter()
            .take(limit)
            .map(|row| {
                Ok(json!({
                    "sessionId":row.try_get::<String,_>("id")?,
                    "cwd":row.try_get::<String,_>("directory")?,
                    "title":projection::clip(&row.try_get::<String,_>("title")?,4096).0,
                    "parentSessionId":row.try_get::<Option<String>,_>("parent_id")?,
                    "updatedAt":row.try_get::<Option<String>,_>("updated")?,
                }))
            })
            .collect();
        ensure!(identity == self.identity()?, "native source changed; retry");
        Ok(
            json!({"sessions":sessions?,"nextCursor":has_more.then(|| (offset + limit as u32).to_string())}),
        )
    }

    /// Cheap persisted-source revision. It deliberately claims no live owner.
    pub async fn revision(&self, session: &str) -> Result<Value> {
        valid_session(session)?;
        let (mut connection, identity) = self.connect().await?;
        let row = load_session(&mut connection, session).await?;
        let revision = self.revision_stamp()?;
        ensure!(identity == self.identity()?, "native source changed; retry");
        Ok(json!({"generation":generation(&identity,&row),"revision":revision}))
    }

    /// Read one explicit turn without admitting or resuming the session.
    pub async fn read_turn(&self, session: &str, turn: &str) -> Result<NativePage> {
        message_id(turn)?;
        let mut page = self
            .read_page(session, Some(&format!("turn:{turn}")), 1)
            .await?;
        ensure!(page.turns.iter().any(|item| item.id == turn), "native turn not found");
        page.turns.retain(|item| item.id == turn);
        Ok(page)
    }

    /// Read canonical v2 or legacy projections as bounded user-turn windows.
    /// Unknown schemas fail explicitly, never as empty history.
    pub async fn read_page(
        &self,
        session: &str,
        before: Option<&str>,
        limit: usize,
    ) -> Result<NativePage> {
        valid_session(session)?;
        ensure!((1..=100).contains(&limit), "invalid native history limit");
        ensure!(before.is_none_or(|cursor| cursor.len() <= 256), "invalid native cursor");
        let (mut connection, identity) = self.connect().await?;
        let revision = self.revision_stamp()?;
        let mut transaction = connection.begin().await?;
        let row = load_session(&mut transaction, session).await?;
        let v2_exists = table_exists(&mut transaction, "session_message").await?;
        let v2_rows: bool = if v2_exists {
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM session_message WHERE session_id=?)")
                .bind(session)
                .fetch_one(&mut *transaction)
                .await?
        } else {
            false
        };
        let legacy_exists = table_exists(&mut transaction, "message").await?;
        let legacy_rows: bool = if legacy_exists {
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM message WHERE session_id=?)")
                .bind(session)
                .fetch_one(&mut *transaction)
                .await?
        } else {
            false
        };
        ensure!(v2_exists || legacy_exists, "unsupported OpenCode history schema");
        let mut records = if v2_rows || (v2_exists && !legacy_rows) {
            v2::read(&mut transaction, &row, session, before, limit).await?
        } else {
            legacy::read(&mut transaction, &row, session, before, limit).await?
        };
        transaction.rollback().await?;
        // A concurrent append may advance the revision while this read uses
        // its SQLite snapshot. Returning the older stamp triggers a refresh.
        ensure!(identity == self.identity()?, "native source changed; retry");
        let (mut turns, omitted) = projection::turns(records.messages);
        // A source may begin with an assistant-only prefix. Keep that real
        // turn pageable instead of exceeding the requested window size.
        if turns.len() > limit {
            turns = turns.split_off(turns.len() - limit);
            records.has_older = true;
            records.next_before = turns.first().map(|turn| turn.id.clone());
        }
        let truncated = records.truncated || omitted;
        if truncated {
            if let Some(last) = turns.last_mut() {
                last.omitted += 1;
            }
        }
        Ok(NativePage {
            session_id: session.into(),
            generation: generation(&identity, &row),
            revision,
            source_bytes: std::fs::metadata(&self.path)?.len(),
            cwd: row.cwd,
            title: row.title,
            updated_at: row.updated.max(0) as u64,
            turns,
            has_older: records.has_older,
            next_before: records.next_before,
            total_turns: None,
            truncated,
        })
    }
}

async fn load_session(connection: &mut SqliteConnection, id: &str) -> Result<Session> {
    let table = Sessions::detect(connection).await?;
    let row = sqlx::query(sessions!(
        "SELECT CASE WHEN length(CAST(directory AS BLOB))<=16384 THEN directory END AS directory, \
         substr(title,1,4096) AS title,time_created,time_updated, CASE WHEN revert IS NULL OR \
         length(CAST(revert AS BLOB))<=16384 THEN revert ELSE 'oversized revert' END AS revert",
        table,
        "WHERE id=?"
    ))
    .bind(id)
    .fetch_optional(connection)
    .await?
    .context("native session not found")?;
    let revert: Option<String> = row.try_get("revert")?;
    Ok(Session {
        cwd: row.try_get("directory")?,
        title: row.try_get("title")?,
        created: row.try_get("time_created")?,
        updated: row.try_get("time_updated")?,
        revert: revert.map(|text| serde_json::from_str(&text)).transpose()?,
    })
}

fn generation(identity: &str, session: &Session) -> String {
    digest_bytes(
        format!(
            "{identity}:{}:{}:{}",
            session.created,
            session.cwd,
            session.revert.as_ref().unwrap_or(&Value::Null)
        )
        .as_bytes(),
    )
}

fn valid_session(id: &str) -> Result<()> {
    ensure!(
        id.starts_with("ses_")
            && id.len() <= 128
            && id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_'),
        "invalid OpenCode session id"
    );
    Ok(())
}

struct Records {
    messages: Vec<projection::Message>,
    has_older: bool,
    next_before: Option<String>,
    truncated: bool,
}

async fn table_exists(connection: &mut SqliteConnection, name: &str) -> Result<bool> {
    Ok(sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
    )
    .bind(name)
    .fetch_one(connection)
    .await?
        == 1)
}

fn message_id(turn: &str) -> Result<&str> {
    let id = turn
        .strip_prefix("native:")
        .or_else(|| turn.strip_prefix("oc1:"))
        .context("invalid native cursor")?;
    ensure!(
        id.starts_with("msg")
            && id.len() <= 128
            && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_'),
        "invalid native message id"
    );
    Ok(id)
}

#[cfg(test)]
mod legacy_tests;
#[cfg(test)]
mod tests;
