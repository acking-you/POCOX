//! Explicit release on the connection that admitted the session. Browsing
//! never enters this path, and an idle turn alone is not release evidence.

use super::*;

mod access;
mod acquire;
mod claims;
mod status;
pub(super) use claims::HeldClaim;

impl AgentHost {
    /// Close this host's idle session, preserving its native history. Both
    /// identity fields are mandatory. Once closing begins, prompts and
    /// settings stay blocked until closure is verified or the host stops.
    /// A disconnected caller does not cancel the owned cleanup operation.
    pub async fn release_session(
        &self,
        session: &str,
        expected: &Identity,
    ) -> Result<Value, HostError> {
        valid_id(session)?;
        if expected.host_id.is_none() || expected.generation.is_none() {
            return Err(HostError::Stale);
        }
        let host = self.clone();
        let session = session.to_owned();
        let expected = expected.clone();
        tokio::spawn(async move {
            let mut stopping = host.inner.stopping.subscribe();
            tokio::select! {
                result = host.release_owned(&session, &expected) => result,
                _ = stopping.wait_for(|stopped| *stopped) => Err(HostError::NotReady),
            }
        })
        .await
        .map_err(|_| HostError::NotReady)?
    }

    async fn release_owned(&self, session: &str, expected: &Identity) -> Result<Value, HostError> {
        // Teardown cannot replace the connection during a close. Configuration
        // already in flight completes before admission is frozen.
        let _lifecycle = self.inner.lifecycle.lock().await;
        let _control = self.inner.session_control.lock().await;
        if self.stopping() {
            return Err(HostError::NotReady);
        }
        let (generation, peer, caps) = self.ready_for(Some(expected))?;
        if !caps.close_session {
            return Err(HostError::Unsupported(
                "this agent cannot release one session; continue on its existing host, or stop \
                 that host before moving the session"
                    .into(),
            ));
        }
        let reader = self.inner.native_history.as_ref();
        {
            let mut state = self.state();
            let entry = state
                .sessions
                .get_mut(session)
                .ok_or(HostError::UnknownSession)?;
            if entry.active.is_some() {
                return Err(HostError::Busy);
            }
            if entry.pending && !entry.releasing {
                return Err(HostError::Loading);
            }
            entry.pending = true;
            entry.releasing = true;
            state.session_event(session);
        }
        let observed = match reader {
            Some(reader) => reader
                .idle_owners(session)
                .await
                .map_err(|e| HostError::Agent(e.to_string()))?,
            None => Vec::new(),
        };
        let owners = {
            let mut state = self.state();
            let entry = state.sessions.get_mut(session).ok_or(HostError::Stale)?;
            entry.release_owners.retain(|owner| {
                pocox_core::process::process_start_time(owner.pid) == Some(owner.started)
            });
            for owner in observed {
                if !entry.release_owners.contains(&owner) {
                    if entry.release_owners.len() >= 8 {
                        return Err(HostError::Limit);
                    }
                    entry.release_owners.push(owner);
                }
            }
            entry.release_owners.clone()
        };
        // This is the owning peer, not a new connection whose close could be
        // a no-op. A timeout leaves the session frozen and retryable.
        peer.request("session/close", json!({"sessionId":session}), Some(CLOSE_TIMEOUT))
            .await
            .map_err(|e| self.call_error(generation, e))?;
        if let Some(reader) = reader {
            let verified = tokio::time::timeout(CLOSE_TIMEOUT, async {
                loop {
                    let empty = reader
                        .idle_owners(session)
                        .await
                        .map_err(|e| HostError::Agent(e.to_string()))?
                        .is_empty();
                    let old_gone = owners.iter().all(|owner| {
                        pocox_core::process::process_start_time(owner.pid) != Some(owner.started)
                    });
                    if empty && old_gone {
                        return Ok::<_, HostError>(());
                    }
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            })
            .await;
            match verified {
                Ok(Ok(())) => {},
                Ok(Err(error)) => return Err(error),
                Err(_) => {
                    return Err(HostError::Agent(format!(
                        "{} acknowledged close but a native writer remains; the session stays \
                         read-only. Release it in its owning application and retry",
                        reader.display_name()
                    )))
                },
            }
        }
        let mut state = self.state();
        if state.generation != generation {
            return Err(HostError::Stale);
        }
        state.sessions.remove(session);
        state.session_event(session);
        self.forget_native_claim(session, generation);
        drop(state);
        // What the released session was granted ends with it.
        let mcp = lock(&self.inner.session_mcp).clone();
        if let Some(mcp) = mcp {
            mcp.closed(session);
        }
        Ok(
            json!({"sessionId":session,"released":true,"hostId":self.host_id(),"generation":generation}),
        )
    }
}

#[cfg(all(test, unix))]
mod tests;

#[cfg(all(test, unix))]
mod native_tests;

#[cfg(all(test, unix))]
mod acquire_tests;
