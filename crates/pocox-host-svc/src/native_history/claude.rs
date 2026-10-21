//! Canonical Claude history via the installed SDK's read-only API.

use std::{collections::VecDeque, ffi::OsString, path::PathBuf};

use anyhow::{ensure, Context, Result};
use serde_json::{json, Value};
use tokio::sync::Mutex;

use super::{command, ownership, NativePage};

const READER: &str = include_str!("claude_reader.mjs");
const CACHE_BYTES: usize = 32 * 1024 * 1024;
const CACHE_PAGES: usize = 8;

/// Read Claude's local canonical conversation without an ACP process.
///
/// The caller supplies the selected host's resolved Node executable, installed
/// official SDK entry and Claude config directory. Construction performs no
/// download or login. SDK reads are memory/time/output bounded; unchanged
/// windows reuse the cache, while a changed selected transcript is parsed by
/// the SDK again. This is not an incremental transcript index.
pub struct ClaudeHistory {
    node: PathBuf,
    sdk: PathBuf,
    root: PathBuf,
    cache: Mutex<VecDeque<CachedPage>>,
    ownership: Option<ownership::Probe>,
}

struct CachedPage {
    session: String,
    before: Option<String>,
    limit: usize,
    page: NativePage,
    bytes: usize,
    identity: String,
}

impl ClaudeHistory {
    /// Configure a read-only source with explicit host-local paths.
    pub fn new(node: PathBuf, sdk: PathBuf, root: PathBuf) -> Result<Self> {
        ensure!(
            node.is_absolute() && sdk.is_absolute() && root.is_absolute(),
            "native history requires absolute host paths"
        );
        Ok(Self {
            node,
            sdk,
            root,
            cache: Mutex::new(VecDeque::new()),
            ownership: None,
        })
    }

    /// Inspect the native CLI actually selected by this host. The probe has no
    /// model credentials and never grants write or takeover permission.
    pub fn with_owner_probe(mut self, program: PathBuf, home: PathBuf) -> Self {
        self.ownership = Some(ownership::Probe::new(program, home, self.root.clone()));
        self
    }

    /// Report only a native owner verified against its OS process identity.
    /// Missing, stale or incomplete evidence remains read-only and unknown.
    pub async fn liveness(&self, session: &str) -> crate::sessions::SessionLiveness {
        match &self.ownership {
            Some(probe) => probe.inspect(session).await,
            None => ownership::unknown(session),
        }
    }

    pub(crate) async fn idle_owners(
        &self,
        session: &str,
    ) -> Result<Vec<pocox_core::process::ProcessIdentity>> {
        self.ownership
            .as_ref()
            .context("this Claude source has no ownership probe")?
            .idle_owners(session)
            .await
    }

    pub(crate) async fn handoff_liveness(&self, session: &str) -> crate::sessions::SessionLiveness {
        match &self.ownership {
            Some(probe) => probe.inspect_fresh(session).await,
            None => ownership::unknown(session),
        }
    }

    pub(crate) async fn writer_owners(
        &self,
        session: &str,
    ) -> Result<Vec<pocox_core::process::ProcessIdentity>> {
        self.ownership
            .as_ref()
            .context("this Claude source has no ownership probe")?
            .owners(session, true)
            .await
    }

    pub(crate) fn claim_session(
        &self,
        session: &str,
    ) -> Result<super::SessionClaim, super::ClaimError> {
        super::SessionClaim::acquire(&self.root, session)
    }

    pub(crate) async fn unowned_sessions(&self, sessions: &[String]) -> Result<Vec<String>> {
        self.ownership
            .as_ref()
            .context("this Claude source has no ownership probe")?
            .unowned_sessions(sessions)
            .await
    }

    async fn request(
        &self,
        action: &str,
        session: &str,
        before: Option<&str>,
        limit: usize,
    ) -> Result<Value> {
        ensure!(uuid::Uuid::parse_str(session).is_ok(), "invalid native session id");
        ensure!((1..=100).contains(&limit), "native history page limit must be 1..100");
        ensure!(before.is_none_or(|value| value.len() <= 128), "invalid cursor");
        self.run(json!({
            "action": action, "session": session,
            "before": before.filter(|value| !value.starts_with("turn:")),
            "turn": before.and_then(|value| value.strip_prefix("turn:")), "limit": limit,
        }))
        .await
    }

    async fn run(&self, mut request: Value) -> Result<Value> {
        let args = vec![
            "--max-old-space-size=256".into(),
            "--input-type=module".into(),
            "--eval".into(),
            READER.into(),
            "--".into(),
            "--pcx-read".into(),
        ];
        // No inherited NODE_OPTIONS, model keys, proxy credentials or shell
        // hooks. The SDK's filesystem reader only needs its explicit root.
        let env: Vec<(OsString, OsString)> = vec![
            ("CLAUDE_CONFIG_DIR".into(), self.root.as_os_str().to_owned()),
            ("DISABLE_TELEMETRY".into(), "1".into()),
        ];
        request["sdk"] = json!(self.sdk);
        request["root"] = json!(self.root);
        command::read_json(&self.node, &args, &env, &request).await
    }

    /// List native sessions without starting an ACP runtime. Cursors are
    /// bounded offsets into the SDK's newest-first inventory.
    pub async fn list_sessions(&self, cursor: Option<&str>, limit: usize) -> Result<Value> {
        ensure!((1..=100).contains(&limit), "invalid native inventory limit");
        let offset = cursor
            .map(str::parse::<u32>)
            .transpose()
            .context("invalid cursor")?
            .unwrap_or(0);
        ensure!(offset <= 100000, "invalid cursor");
        self.run(json!({"action":"list", "offset":offset, "limit":limit}))
            .await
    }

    /// Read a source revision without parsing conversation messages.
    pub async fn revision(&self, session: &str) -> Result<Value> {
        self.request("revision", session, None, 1).await
    }

    /// Read one canonical native turn for an explicit timeline selection.
    pub async fn read_turn(&self, session: &str, turn: &str) -> Result<NativePage> {
        self.read_page(session, Some(&format!("turn:{turn}")), 1)
            .await
    }

    /// Read a tail or an explicitly requested older page. Reads never grant
    /// write authority, even when the native CLI reports no active owner.
    pub async fn read_page(
        &self,
        session: &str,
        before: Option<&str>,
        limit: usize,
    ) -> Result<NativePage> {
        // Coalesce source reads, including identical concurrent follow polls.
        // The bounded child timeout also bounds time spent holding this lock.
        let mut cache = self.cache.lock().await;
        let stamp = self.request("revision", session, before, limit).await?;
        let revision = stamp["revision"]
            .as_str()
            .context("missing native history revision")?;
        if let Some(index) = cache.iter().position(|entry| {
            entry.session == session
                && entry.before.as_deref() == before
                && entry.limit == limit
                && entry.page.revision == revision
        }) {
            let entry = cache
                .remove(index)
                .context("native history cache entry disappeared")?;
            let page = entry.page.clone();
            cache.push_back(entry);
            return Ok(page);
        }
        let response = self.request("page", session, before, limit).await?;
        let bytes = serde_json::to_vec(&response)?.len();
        let mut page: NativePage =
            serde_json::from_value(response).context("invalid native history page")?;
        ensure!(
            page.session_id == session && page.turns.len() <= limit,
            "native history returned a different session or oversized page"
        );
        let identity = page.generation.clone();
        if let Some(previous) = cache
            .iter()
            .rev()
            .find(|entry| entry.session == session && entry.identity == identity)
        {
            page.generation = if page.source_bytes < previous.page.source_bytes {
                pocox_core::history_sync::digest_bytes(
                    format!("{}:{}", previous.page.generation, page.revision).as_bytes(),
                )
            } else {
                previous.page.generation.clone()
            };
        }
        cache.retain(|entry| entry.session != session || entry.page.revision == page.revision);
        while cache.len() >= CACHE_PAGES
            || cache.iter().map(|entry| entry.bytes).sum::<usize>() + bytes > CACHE_BYTES
        {
            if cache.pop_front().is_none() {
                break;
            }
        }
        if bytes <= CACHE_BYTES {
            cache.push_back(CachedPage {
                session: session.into(),
                before: before.map(str::to_owned),
                limit,
                page: page.clone(),
                bytes,
                identity,
            });
        }
        Ok(page)
    }
}

#[cfg(test)]
mod tests;
