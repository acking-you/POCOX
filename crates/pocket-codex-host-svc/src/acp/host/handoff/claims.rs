//! Claims outlive replay state and failed loads. Native clients do not honor
//! these locks, so every acquired session also needs native ownership checks.

use pocket_codex_core::process::{is_process_descendant, process_start_time, ProcessIdentity};

use super::*;
use crate::native_history::SessionClaim;

pub(in crate::acp::host) struct HeldClaim {
    pub(super) generation: u64,
    _claim: SessionClaim,
    owners: Vec<ProcessIdentity>,
}

impl AgentHost {
    pub(in crate::acp::host) fn claim_native_session(
        &self,
        id: &str,
        generation: u64,
    ) -> Result<(), HostError> {
        let Some(reader) = &self.inner.native_history else { return Ok(()) };
        let state = self.state();
        if state.generation != generation {
            return Err(HostError::Stale);
        }
        let mut claims = lock(&self.inner.native_claims);
        if claims.contains_key(id) {
            return Err(HostError::ReadOnly);
        }
        if claims.len() >= crate::acp::state::MAX_SESSIONS {
            return Err(HostError::Capacity);
        }
        let claim = reader.claim_session(id).map_err(|e| match e {
            crate::native_history::ClaimError::Busy => HostError::PocketOwned,
            crate::native_history::ClaimError::Unavailable => HostError::ReadOnly,
        })?;
        claims.insert(id.to_owned(), HeldClaim {
            generation,
            _claim: claim,
            owners: Vec::new(),
        });
        Ok(())
    }

    /// Called only before admission is confirmed, while the lifecycle lock
    /// still pins the ACP leader. No user prompt can reach this writer yet.
    pub(in crate::acp::host) async fn verify_native_writer(
        &self,
        id: &str,
        generation: u64,
        root: (u32, u64),
    ) -> Result<(), HostError> {
        self.verify_writer(id, generation, root, false).await
    }

    /// Revalidate immediately before new input. A native client may have
    /// opened the same UUID after Pocket's original admission.
    pub(in crate::acp::host) async fn recheck_native_writer(
        &self,
        id: &str,
        generation: u64,
    ) -> Result<(), HostError> {
        if self.inner.native_history.is_none() {
            return Ok(());
        }
        let lifecycle = self.inner.lifecycle.lock().await;
        if self.state().generation != generation || self.stopping() {
            return Err(HostError::Stale);
        }
        let root = Self::native_claim_root(lifecycle.as_ref())?;
        self.verify_writer(id, generation, root, true).await
    }

    async fn verify_writer(
        &self,
        id: &str,
        generation: u64,
        root: (u32, u64),
        allow_running: bool,
    ) -> Result<(), HostError> {
        let Some(reader) = &self.inner.native_history else { return Ok(()) };
        let owners = if allow_running {
            reader.writer_owners(id).await
        } else {
            reader.idle_owners(id).await
        }
        .map_err(|_| HostError::ReadOnly)?;
        let checked = owners.clone();
        let owns = tokio::task::spawn_blocking(move || {
            checked.len() == 1
                && checked[0].pid != root.0
                && is_process_descendant(checked[0].pid, checked[0].started, root.0, root.1)
        })
        .await
        .unwrap_or(false);
        if !owns {
            return Err(HostError::ReadOnly);
        }
        let mut claims = lock(&self.inner.native_claims);
        let claim = claims
            .get_mut(id)
            .filter(|c| c.generation == generation)
            .ok_or(HostError::Stale)?;
        if !claim.owners.is_empty() && claim.owners != owners {
            return Err(HostError::ReadOnly);
        }
        claim.owners = owners;
        Ok(())
    }

    pub(in crate::acp::host) fn native_claim_root(
        running: Option<&Running>,
    ) -> Result<(u32, u64), HostError> {
        let pid = running
            .and_then(|r| r.process.id())
            .ok_or(HostError::NotReady)?;
        let started = process_start_time(pid).ok_or(HostError::NotReady)?;
        Ok((pid, started))
    }

    pub(in crate::acp::host) fn forget_native_claim(&self, id: &str, generation: u64) {
        let mut claims = lock(&self.inner.native_claims);
        if claims.get(id).is_some_and(|c| c.generation == generation) {
            claims.remove(id);
        }
    }

    /// A bounded, fresh probe follows actual process teardown. A failed probe
    /// retains the claim instead of treating missing evidence as release.
    pub(in crate::acp::host) async fn release_stopped_claims(&self, generation: u64) {
        let Some(reader) = &self.inner.native_history else { return };
        let ids: Vec<String> = lock(&self.inner.native_claims)
            .iter()
            .filter(|(_, c)| c.generation == generation)
            .map(|(id, _)| id.clone())
            .collect();
        if ids.is_empty() {
            return;
        }
        let Ok(unowned) = reader.unowned_sessions(&ids).await else { return };
        let mut claims = lock(&self.inner.native_claims);
        for id in unowned {
            if claims.get(&id).is_some_and(|c| {
                c.generation == generation
                    && c.owners
                        .iter()
                        .all(|p| process_start_time(p.pid) != Some(p.started))
            }) {
                claims.remove(&id);
            }
        }
    }
}
