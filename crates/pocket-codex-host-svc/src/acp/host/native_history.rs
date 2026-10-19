//! Native browsing is separate from ACP admission and mutation authority.

use super::*;
use crate::acp::fold::ItemKind;

impl AgentHost {
    /// Read admitted live folds or the independent persisted source. Reading
    /// an external session never calls `session/load` or `session/resume`.
    pub async fn read_history(
        &self,
        session: &str,
        before: Option<&str>,
        turn: Option<&str>,
        limit: Option<usize>,
    ) -> Result<Value, HostError> {
        valid_id(session)?;
        let generation = {
            let state = self.state();
            if self.inner.native_history.is_none() || state.sessions.contains_key(session) {
                drop(state);
                return self.history(session, before, turn, limit);
            }
            state.generation
        };
        let source = self
            .inner
            .native_history
            .as_ref()
            .ok_or(HostError::UnknownSession)?;
        let page = match turn {
            Some(turn) => source.read_turn(session, turn).await,
            None => {
                source
                    .read_page(
                        session,
                        before,
                        limit
                            .unwrap_or(DEFAULT_WINDOW_TURNS)
                            .clamp(1, MAX_WINDOW_TURNS),
                    )
                    .await
            },
        }
        .map_err(|error| HostError::Agent(error.to_string()))?;
        let state = self.state();
        if state.generation != generation || state.sessions.contains_key(session) {
            return Err(HostError::Stale);
        }
        let index: Vec<Value> = page.turns.iter().map(|turn| json!({
            "turnId":turn.id, "userText":turn.items.iter().find(|item| item.kind == ItemKind::UserMessage)
                .map(|item| clip(&item.text, 200)).unwrap_or_default(),
            "replayed":true, "outcome":turn.outcome, "omitted":turn.omitted,
        })).collect();
        Ok(json!({
            "available":true, "sessionId":session, "source":"native",
            "historyEpoch":page.generation, "historyRevision":page.revision,
            "truncated":page.truncated, "hasOlder":page.has_older,
            "turns":index, "window":page.turns,
            "session":{"sessionId":session,"cwd":page.cwd,"title":page.title,"readOnly":true},
            "seq":state.log.last(), "generation":generation, "hostId":self.inner.host_id,
        }))
    }

    /// Live interest in an unadmitted native session, for a follow stream:
    /// held, it keeps the provider's live follow (Grok's leader) open.
    pub fn native_follow(&self, session: &str) -> Option<crate::native_history::NativeFollow> {
        self.inner.native_history.as_ref()?.follow(session)
    }

    /// Revision and verified native ownership for a read-only follow stream.
    /// Missing evidence never grants permission to resume.
    pub async fn native_status(&self, session: &str) -> Result<Value, HostError> {
        valid_id(session)?;
        let generation = self.state().generation;
        let source = self
            .inner
            .native_history
            .as_ref()
            .ok_or(HostError::UnknownSession)?;
        let revision = source
            .revision(session)
            .await
            .map_err(|error| HostError::Agent(error.to_string()))?;
        let liveness = source.liveness(session).await;
        let state = self.state();
        if state.generation != generation {
            return Err(HostError::Stale);
        }
        Ok(json!({"liveness":liveness,"items":[],"history_revision":revision["revision"],
            "hostId":self.inner.host_id,"generation":generation}))
    }
}

#[cfg(test)]
mod tests;
