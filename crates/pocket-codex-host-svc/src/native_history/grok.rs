//! Grok Build's own persisted sessions under `$GROK_HOME/sessions`, read
//! without starting an agent.
//!
//! The layout and replay rules mirror upstream Grok Build
//! (`deps/grok-build`, `xai-grok-shell/src/session/storage`): one
//! `<encoded-cwd>/<session-id>/` directory per session holding
//! `summary.json` (title, cwd, timestamps) and `updates.jsonl`, the durable
//! log of the ACP `session/update` notifications the agent sent. Replay
//! drops rewound branches the way Grok's own `session/load` does, so the
//! read-only view shows what reopening the session would show.

use std::{collections::HashMap, path::PathBuf};

use anyhow::{ensure, Context, Result};
use serde_json::{json, Value};
use tokio::sync::Mutex;

use super::{ownership, NativePage};

mod inventory;
mod owners;
mod transcript;

use owners::Probe;

/// Read Grok Build's local sessions without an ACP process.
///
/// Construction performs no I/O. Listing scans session summaries; a page
/// read indexes the session's update log once and then only its appended
/// bytes, and folds just the requested turns.
pub struct GrokHistory {
    home: PathBuf,
    indexes: Mutex<HashMap<PathBuf, transcript::Index>>,
    ownership: Option<Probe>,
}

impl GrokHistory {
    /// Read the sessions of the Grok home `home` (`$GROK_HOME`, normally
    /// `~/.grok`).
    pub fn new(home: PathBuf) -> Result<Self> {
        ensure!(home.is_absolute(), "native history requires an absolute Grok home");
        Ok(Self {
            home,
            indexes: Mutex::new(HashMap::new()),
            ownership: None,
        })
    }

    /// Report the sessions Grok's terminal clients register as open
    /// (`active_sessions.json`), verified against their OS process. Grok's
    /// ACP agents (`grok agent stdio`) do not register, so a missing entry is
    /// never proof that no editor holds a session.
    pub fn with_owner_probe(mut self) -> Self {
        self.ownership = Some(Probe::new(self.home.clone()));
        self
    }

    /// The Grok home this source reads.
    pub fn home(&self) -> &std::path::Path {
        &self.home
    }

    fn sessions_root(&self) -> PathBuf {
        self.home.join("sessions")
    }

    /// List persisted sessions newest first. Cursors are bounded offsets.
    pub async fn list_sessions(&self, cursor: Option<&str>, limit: usize) -> Result<Value> {
        ensure!((1..=100).contains(&limit), "invalid native inventory limit");
        let offset = cursor
            .map(str::parse::<usize>)
            .transpose()
            .context("invalid cursor")?
            .unwrap_or(0);
        ensure!(offset <= 100_000, "invalid cursor");
        // A Grok home that does not exist is an unavailable source, not an
        // empty history; an existing home may simply have no sessions yet.
        ensure!(
            self.home.is_dir(),
            "Grok's home {} does not exist on this computer",
            self.home.display()
        );
        let root = self.sessions_root();
        let summaries = tokio::task::spawn_blocking(move || inventory::summaries(&root))
            .await
            .context("native inventory task failed")??;
        let more = summaries.len() > offset + limit;
        let sessions: Vec<Value> = summaries
            .into_iter()
            .skip(offset)
            .take(limit)
            .map(|summary| {
                json!({
                    "sessionId": summary.id,
                    "cwd": summary.cwd,
                    "title": summary.title,
                    "parentSessionId": summary.parent,
                    "updatedAt": summary.updated,
                })
            })
            .collect();
        Ok(json!({"sessions": sessions, "nextCursor": more.then(|| (offset + limit).to_string())}))
    }

    /// Cheap source revision; reading it claims no owner.
    pub async fn revision(&self, session: &str) -> Result<Value> {
        let root = self.sessions_root();
        let session = valid_session(session)?.to_owned();
        tokio::task::spawn_blocking(move || {
            let dir = inventory::locate(&root, &session)?;
            let stamp = transcript::Stamp::read(&dir)?;
            Ok(json!({"generation": stamp.generation(), "revision": stamp.revision()}))
        })
        .await
        .context("native revision task failed")?
    }

    /// Read one explicit native turn.
    pub async fn read_turn(&self, session: &str, turn: &str) -> Result<NativePage> {
        let mut page = self
            .read_page(session, Some(&format!("turn:{turn}")), 1)
            .await?;
        ensure!(page.turns.iter().any(|item| item.id == turn), "native turn not found");
        page.turns.retain(|item| item.id == turn);
        Ok(page)
    }

    /// Read the newest `limit` turns, or those just before the `before`
    /// turn. Reads never grant write authority.
    pub async fn read_page(
        &self,
        session: &str,
        before: Option<&str>,
        limit: usize,
    ) -> Result<NativePage> {
        ensure!((1..=100).contains(&limit), "invalid native history limit");
        ensure!(before.is_none_or(|cursor| cursor.len() <= 128), "invalid native cursor");
        let session = valid_session(session)?.to_owned();
        let root = self.sessions_root();
        let before = before.map(str::to_owned);
        // One reader per source updates the shared index; the bounded read
        // runs off the async worker.
        let mut indexes = self.indexes.lock().await;
        let dir = {
            let (root, session) = (root.clone(), session.clone());
            tokio::task::spawn_blocking(move || inventory::locate(&root, &session))
                .await
                .context("native history task failed")??
        };
        let mut index = indexes.remove(&dir).unwrap_or_default();
        let read = {
            let dir = dir.clone();
            tokio::task::spawn_blocking(move || {
                let page = transcript::read(&dir, &session, &mut index, before.as_deref(), limit);
                (page, index)
            })
            .await
            .context("native history task failed")?
        };
        let (page, index) = read;
        // A failed read keeps no index, so a retry starts from the log
        // itself and never serves a partial one as complete.
        if page.is_ok() {
            if indexes.len() >= MAX_INDEXES {
                indexes.clear();
            }
            indexes.insert(dir, index);
        }
        page
    }

    /// Verified native ownership; anything unverifiable is unknown.
    pub async fn liveness(&self, session: &str) -> crate::sessions::SessionLiveness {
        match &self.ownership {
            Some(probe) => probe.inspect(session).await,
            None => ownership::unknown(session),
        }
    }

    /// Fresh evidence that no Grok terminal client holds `session`, for an
    /// operation that must not race one (rename, delete). Editors running
    /// `grok agent stdio` do not register and cannot be seen.
    pub async fn ensure_unheld(&self, session: &str) -> Result<()> {
        let probe = self
            .ownership
            .as_ref()
            .context("this Grok source has no ownership probe")?;
        match probe.inspect_fresh(session).await.safety.as_str() {
            "nativeUnowned" => Ok(()),
            "nativeOwned" => anyhow::bail!("Grok has this session open; close it there first"),
            _ => anyhow::bail!("whether Grok has this session open cannot be told; retry"),
        }
    }

    pub(crate) async fn owners(
        &self,
        session: &str,
    ) -> Result<Vec<pocket_codex_core::process::ProcessIdentity>> {
        self.ownership
            .as_ref()
            .context("this Grok source has no ownership probe")?
            .owners(session)
            .await
    }

    pub(crate) async fn handoff_liveness(&self, session: &str) -> crate::sessions::SessionLiveness {
        match &self.ownership {
            Some(probe) => probe.inspect_fresh(session).await,
            None => ownership::unknown(session),
        }
    }

    pub(crate) fn claim_session(
        &self,
        session: &str,
    ) -> Result<super::SessionClaim, super::ClaimError> {
        super::SessionClaim::acquire(&self.home, session)
    }

    pub(crate) async fn unowned_sessions(&self, sessions: &[String]) -> Result<Vec<String>> {
        self.ownership
            .as_ref()
            .context("this Grok source has no ownership probe")?
            .unowned_sessions(sessions)
            .await
    }
}

/// Most update-log indexes kept per source (one per recently read session).
const MAX_INDEXES: usize = 32;

/// Grok session ids are UUIDs (v7 since 1.0); the id is also a directory
/// name, so anything else is refused before it reaches a path.
fn valid_session(id: &str) -> Result<&str> {
    ensure!(
        uuid::Uuid::parse_str(id).is_ok_and(|uuid| uuid.hyphenated().to_string() == id),
        "invalid Grok session id"
    );
    Ok(id)
}

#[cfg(test)]
mod tests;
