//! Explicit original-session admission after the previous writer released it.

use super::*;

impl AgentHost {
    /// Restore the exact Claude session, after confirming that no registered
    /// native writer remains. `source_generation` must come from this host's
    /// native history view. A Pocket claim excludes other Pocket hosts, not
    /// independent native clients; those must stay closed while this host
    /// writes.
    pub async fn acquire_session(
        &self,
        session: &str,
        source_generation: &str,
        expected: &Identity,
    ) -> Result<Value, HostError> {
        valid_id(session)?;
        if source_generation.is_empty() || source_generation.len() > 128 {
            return Err(HostError::InvalidInput("missing native source generation".into()));
        }
        if expected.host_id.is_none() || expected.generation.is_none() {
            return Err(HostError::Stale);
        }
        let host = self.clone();
        let (session, source_generation, expected) =
            (session.to_owned(), source_generation.to_owned(), expected.clone());
        tokio::spawn(async move {
            let mut stopping = host.inner.stopping.subscribe();
            tokio::select! {
                result = host.acquire_owned(&session, &source_generation, &expected) => result,
                _ = stopping.wait_for(|stop| *stop) => Err(HostError::NotReady),
            }
        })
        .await
        .map_err(|_| HostError::NotReady)?
    }

    async fn acquire_owned(
        &self,
        session: &str,
        source_generation: &str,
        expected: &Identity,
    ) -> Result<Value, HostError> {
        let lifecycle = self.inner.lifecycle.lock().await;
        let _control = self.inner.session_control.lock().await;
        if self.stopping() {
            return Err(HostError::NotReady);
        }
        let (generation, _, caps) = self.ready_for(Some(expected))?;
        let Some(reader) = &self.inner.native_history else {
            return Err(HostError::Unsupported(
                "this provider needs its existing engine; a second ACP engine cannot safely take \
                 over its session"
                    .into(),
            ));
        };
        {
            let state = self.state();
            if let Some(entry) = state.sessions.get(session) {
                if entry.pending {
                    return Err(HostError::Loading);
                }
                if entry.active.is_some() {
                    return Err(HostError::Busy);
                }
                drop(state);
                return Ok(self.opened(session, "live"));
            }
        }
        if !caps.load_session || !caps.close_session {
            return Err(HostError::NotReopenable);
        }
        let root = Self::native_claim_root(lifecycle.as_ref())?;
        let page = reader
            .read_page(session, None, 1)
            .await
            .map_err(|e| HostError::Agent(e.to_string()))?;
        if page.generation != source_generation {
            return Err(HostError::Stale);
        }
        let cwd = match self.inner.store.lookup(session) {
            Some(entry) => validate_cwd(&entry.cwd).await?,
            None => validate_cwd(&page.cwd).await?,
        };
        let old_generation = lock(&self.inner.native_claims)
            .get(session)
            .map(|c| c.generation);
        if let Some(old) = old_generation.filter(|old| *old != generation) {
            self.release_stopped_claims(old).await;
        }
        self.claim_native_session(session, generation)?;
        let preflight = async {
            let owners = reader
                .idle_owners(session)
                .await
                .map_err(|_| HostError::ReadOnly)?;
            if !owners.is_empty() {
                return Err(HostError::ReadOnly);
            }
            let stamp = reader
                .revision(session)
                .await
                .map_err(|e| HostError::Agent(e.to_string()))?;
            if stamp["generation"].as_str() != Some(source_generation) {
                return Err(HostError::Stale);
            }
            Ok(())
        }
        .await;
        if let Err(error) = preflight {
            self.forget_native_claim(session, generation);
            return Err(error);
        }
        let result = self
            .reopen_session(session, &cwd, Some(expected), Some(root))
            .await;
        if result.is_err() && !self.state().sessions.contains_key(session) {
            // The request was refused before loading. Failed/uncertain loads
            // retain a provisional entry and therefore retain their claim.
            self.forget_native_claim(session, generation);
        }
        result
    }
}
