use super::*;
use crate::acp::session_control::SessionControl;

impl AgentHost {
    /// Inspect explicit session operations without loading or claiming a
    /// native session. The resulting identity must accompany the action.
    pub async fn session_control(
        &self,
        session: &str,
        expected: &Identity,
    ) -> Result<SessionControl, HostError> {
        valid_id(session)?;
        if expected.host_id.is_none() || expected.generation.is_none() {
            return Err(HostError::Stale);
        }
        let generation = self.state().generation;
        if !self.is_current(Some(expected), generation) {
            return Err(HostError::Stale);
        }
        let mut view = SessionControl {
            session_id: session.into(),
            host_id: self.host_id().into(),
            generation,
            source_generation: None,
            provider: match &self.inner.native_history {
                Some(reader) => reader.access_provider().into(),
                None => self.inner.spec.profile_id.clone(),
            },
            status: "unsupported".into(),
            can_continue: false,
            can_release: false,
            can_acquire: false,
        };
        let admitted = self.state().sessions.contains_key(session);
        if !admitted {
            if let Some(reader) = &self.inner.native_history {
                view.status = "unknown".into();
                if let Ok(stamp) = reader.revision(session).await {
                    view.source_generation = stamp["generation"].as_str().map(str::to_owned);
                    let live = reader.handoff_liveness(session).await;
                    view.status = match live.safety.as_str() {
                        "nativeUnowned" => "released",
                        "nativeOwnedIdle" => "external_idle",
                        "nativeOwnedRunning" => "external_running",
                        "nativeOwned" => "external_open",
                        _ => "unknown",
                    }
                    .into();
                }
            }
        }
        let state = self.state();
        if !self.is_current(Some(expected), state.generation) {
            return Err(HostError::Stale);
        }
        if state.phase != Phase::Ready
            || self.stopping()
            || state.peer.as_ref().is_none_or(Peer::is_closed)
        {
            view.status = "stopped".into();
            return Ok(view);
        }
        let caps = &state
            .negotiated
            .as_ref()
            .ok_or(HostError::NotReady)?
            .capabilities;
        if let Some(entry) = state.sessions.get(session) {
            view.status = if entry.releasing {
                "releasing"
            } else if entry.pending {
                "loading"
            } else if entry.active.is_some() {
                "running"
            } else {
                "owned"
            }
            .into();
            view.can_continue = !entry.pending;
            view.can_release = self.inner.native_history.is_some()
                && caps.close_session
                && entry.active.is_none()
                && (!entry.pending || entry.releasing);
        } else {
            view.can_acquire = view.status == "released"
                && view.source_generation.is_some()
                && caps.load_session
                && caps.close_session;
        }
        Ok(view)
    }
}
