//! Provider-neutral automatic admission. A native idle process is still an
//! owner; only fresh no-owner evidence permits loading the original UUID.

use super::*;
use crate::{native_history::ClaimError, session_access::SessionAccess};

impl AgentHost {
    /// Observe current access without loading or closing any writer.
    pub async fn session_access(
        &self,
        session: &str,
        expected: &Identity,
    ) -> Result<SessionAccess, HostError> {
        let view = self.session_control(session, expected).await?;
        let mut access =
            SessionAccess::unknown(session, &view.host_id, view.generation, &view.provider);
        access.source_generation = view.source_generation;
        access.can_release = view.can_release;
        let (mode, writer, turn, reason) = match view.status.as_str() {
            "owned" => ("write", "this_host", "idle", "owned"),
            "running" => ("write", "this_host", "running", "owned"),
            "loading" | "releasing" => ("follow", "this_host", "unknown", "transition"),
            "released" => ("follow", "none", "idle", "released"),
            "external_idle" => ("follow", "native_client", "idle", "external_idle"),
            "external_open" => ("follow", "native_client", "unknown", "external_open"),
            "external_running" => ("follow", "native_client", "running", "external_running"),
            "stopped" => ("blocked", "unknown", "unknown", "host_stopped"),
            "unsupported" | "engine_required" => ("blocked", "unknown", "unknown", "unsupported"),
            _ => ("follow", "unknown", "unknown", "source_unknown"),
        };
        access.mode = mode.into();
        access.writer = writer.into();
        access.turn = turn.into();
        access.reason = reason.into();
        if access.reason == "external_open" && self.inner.native_history.is_some() {
            access.holder = Some(crate::session_access::AccessHolder {
                client: self
                    .inner
                    .native_history
                    .as_ref()
                    .map(|reader| reader.access_provider().to_string())
                    .unwrap_or_default(),
                pid: None,
                started_at: None,
                host_name: None,
                service_key: None,
            });
        }
        if let Some(reader) = &self.inner.native_history {
            access.source_generation = reader
                .revision(session)
                .await
                .ok()
                .and_then(|stamp| stamp["generation"].as_str().map(str::to_owned));
            if access.mode == "write" {
                if self
                    .recheck_native_writer(session, view.generation)
                    .await
                    .is_err()
                    || access.source_generation.is_none()
                {
                    access.mode = "follow".into();
                    access.writer = "unknown".into();
                    access.turn = "unknown".into();
                    access.reason = "source_unknown".into();
                } else {
                    access.exclusion = "pocket".into();
                }
            } else if access.reason == "released" {
                match reader.claim_session(session) {
                    Ok(claim) => drop(claim),
                    Err(ClaimError::Busy) => {
                        access.writer = "pocket_host".into();
                        access.reason = "pocket_host".into();
                    },
                    Err(ClaimError::Unavailable) => {
                        access.writer = "unknown".into();
                        access.reason = "source_unknown".into();
                    },
                }
            }
        } else if access.mode == "write" {
            access.exclusion = "engine".into();
        }
        if access.reason == "released" && lock(&self.inner.released_here).contains_key(session) {
            access.reason = "released_here".into();
        }
        if !self.is_current(Some(expected), self.state().generation) {
            return Err(HostError::Stale);
        }
        Ok(access)
    }

    /// Open the original native session automatically when no writer remains.
    /// A failed acquisition is never retried, forked or forced.
    pub async fn session_open(
        &self,
        session: &str,
        expected: &Identity,
    ) -> Result<SessionAccess, HostError> {
        let before = self.session_access(session, expected).await?;
        if before.mode == "write" {
            return Ok(before);
        }
        let result = if self.inner.native_history.is_none() {
            self.open_session(session, Some(expected)).await
        } else if matches!(before.reason.as_str(), "released" | "released_here") {
            let source = before
                .source_generation
                .as_deref()
                .ok_or(HostError::ReadOnly)?;
            self.acquire_session(session, source, expected).await
        } else {
            return Ok(before);
        };
        match result {
            Ok(_) => {
                lock(&self.inner.released_here).remove(session);
            },
            Err(
                HostError::ReadOnly | HostError::PocketOwned | HostError::Loading | HostError::Busy,
            ) => {},
            Err(error) => return Err(error),
        }
        self.session_access(session, expected).await
    }

    /// Release the idle writer on its actual owning connection, against the
    /// exact displayed host and native source. It never closes another client.
    pub async fn session_release(
        &self,
        snapshot: &SessionAccess,
    ) -> Result<SessionAccess, HostError> {
        let identity = Identity {
            host_id: Some(snapshot.host_id.clone()),
            generation: Some(snapshot.generation),
        };
        let current = self.session_access(&snapshot.session_id, &identity).await?;
        if current.source_generation != snapshot.source_generation
            || current.provider != snapshot.provider
        {
            return Err(HostError::Stale);
        }
        if !current.can_release {
            return Err(HostError::ReadOnly);
        }
        self.release_session(&snapshot.session_id, &identity)
            .await?;
        {
            let mut released = lock(&self.inner.released_here);
            if released.len() >= crate::acp::state::MAX_SESSIONS {
                if let Some(oldest) = released
                    .iter()
                    .min_by_key(|(_, at)| *at)
                    .map(|(id, _)| id.clone())
                {
                    released.remove(&oldest);
                }
            }
            released.insert(snapshot.session_id.clone(), std::time::Instant::now());
        }
        self.session_access(&snapshot.session_id, &identity).await
    }
}
