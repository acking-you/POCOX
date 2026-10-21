//! Supplements: user input added to the running turn through the
//! `_session/steering` extension, when the agent advertised it, or Grok's
//! own `_x.ai/interject` (see `grok.rs` for what Grok does with it).
//!
//! The request opts into the `promptRequired` idle behaviour, so an idle
//! agent answers that it consumed nothing instead of starting a turn by
//! itself; the caller then sends an ordinary prompt. Which turn runs is
//! checked before the dispatch lane and again under it, and the request is
//! written under the lane, so it can never reach a turn admitted after the
//! one it was meant for (see the parent module docs). Any answer other than
//! `injected` / `promptRequired`, and any failure after the write, leaves
//! the outcome unknown: it is reported, never retried and never turned into
//! a prompt.

use super::{
    grok,
    schema::{steering_params, SteerOutcome, STEERING_METHOD},
    turns::{check_message, content_blocks},
    *,
};
use crate::acp::state::HeldSupplement;

impl AgentHost {
    /// Add `text` / `images` to the running turn of `session` (to
    /// `expected_turn` only, when given). Returns the outcome and the turn
    /// the input went to; [`SteerOutcome::PromptRequired`] (no turn: the
    /// input was not consumed) comes without a turn.
    pub async fn steer(
        &self,
        session: &str,
        expected_turn: Option<&str>,
        text: &str,
        images: &[String],
        expected: Option<&Identity>,
    ) -> Result<(SteerOutcome, Option<String>), HostError> {
        self.steer_as(session, expected_turn, text, images, None, expected)
            .await
    }

    /// [`AgentHost::steer`] for a caller that named its message with
    /// `client_id`, which the `supplement` event carries (see
    /// [`AgentHost::prompt_as`]).
    pub async fn steer_as(
        &self,
        session: &str,
        expected_turn: Option<&str>,
        text: &str,
        images: &[String],
        client_id: Option<&str>,
        expected: Option<&Identity>,
    ) -> Result<(SteerOutcome, Option<String>), HostError> {
        valid_id(session)?;
        if let Some(turn) = expected_turn {
            valid_id(turn)?;
        }
        if let Some(client_id) = client_id {
            valid_id(client_id)?;
        }
        check_message(text, images)?;
        // The control budget covers the lane and the write.
        let deadline = Instant::now() + self.budgets().control;
        let (generation, peer, caps) = self.ready_for(expected)?;
        if !caps.steering {
            return Err(HostError::Unsupported(
                "this agent cannot add to a running turn; queue the message instead".into(),
            ));
        }
        let blocks = content_blocks(text, images, &caps)?;
        let Some(turn) = self.steer_target(generation, session, expected_turn, false)? else {
            return Ok((SteerOutcome::PromptRequired, None));
        };
        let Ok(lane) = tokio::time::timeout_at(deadline, self.inner.dispatch.lock()).await else {
            // Nothing was written: the agent never saw it.
            return Err(HostError::Timeout);
        };
        tokio::time::timeout_at(deadline, self.recheck_native_writer(session, generation))
            .await
            .map_err(|_| HostError::Timeout)??;
        if self
            .steer_target(generation, session, Some(&turn), true)?
            .is_none()
        {
            // It ended while this waited for the lane.
            return Ok((SteerOutcome::PromptRequired, None));
        }
        // Grok takes an interjection only for the turn it reports running:
        // one it has finished (or not started) would run it as a turn of
        // its own instead (see `grok.rs`).
        if caps.grok && !self.grok_runs(generation, session, &turn) {
            return Ok((SteerOutcome::PromptRequired, None));
        }
        let interjection = caps.grok.then(|| uuid::Uuid::new_v4().to_string());
        let (method, params) = match &interjection {
            Some(id) => (
                grok::INTERJECT,
                json!({"sessionId": session, "text": text, "content": blocks,
                       "interjectionId": id}),
            ),
            None => (STEERING_METHOD, steering_params(session, blocks)),
        };
        // Held before it is written: Grok may merge it at its next model
        // response before its answer is seen here.
        if let Some(id) = &interjection {
            self.hold_supplement(generation, session, HeldSupplement {
                id: id.clone(),
                turn: turn.clone(),
                text: text.to_string(),
                images: images.len(),
                stream: None,
                client_id: client_id.map(str::to_string),
            });
        }
        let answered = async {
            let call = peer
                .send_request(method, params, Some(deadline))
                .await
                .map_err(|error| self.call_error(generation, error))?;
            drop(lane);
            let answer = call
                .wait(Some(self.budgets().answer))
                .await
                .map_err(|error| self.call_error(generation, error))?;
            if caps.grok {
                grok::interject_accepted(&answer).then_some(SteerOutcome::Injected)
            } else {
                SteerOutcome::from_result(&answer)
            }
            .ok_or_else(|| {
                HostError::Agent(
                    "it answered in an unrecognized way, so the message may or may not have been \
                     added"
                        .into(),
                )
            })
        }
        .await;
        if let Some(id) = &interjection {
            if !matches!(answered, Ok(SteerOutcome::Injected)) {
                self.withdraw_supplement(generation, session, id);
            }
        }
        match answered? {
            outcome @ SteerOutcome::Injected if caps.grok => Ok((outcome, Some(turn))),
            outcome @ SteerOutcome::Injected => {
                self.record_supplement(generation, session, &turn, text, images.len(), client_id);
                Ok((outcome, Some(turn)))
            },
            outcome @ SteerOutcome::PromptRequired => Ok((outcome, None)),
        }
    }

    /// The turn a supplement goes to: `None` when the session is idle (the
    /// input is to be sent as a prompt). A different turn than `expected`,
    /// one being cancelled, or — under the lane (`dispatched_only`) — one
    /// not yet sent to the agent is refused.
    fn steer_target(
        &self,
        generation: u64,
        session: &str,
        expected: Option<&str>,
        dispatched_only: bool,
    ) -> Result<Option<String>, HostError> {
        let state = self.state();
        if state.generation != generation {
            return Err(HostError::NotReady);
        }
        let entry = state
            .sessions
            .get(session)
            .ok_or(HostError::UnknownSession)?;
        if entry.pending {
            return Err(HostError::Loading);
        }
        let Some(active) = entry.active.as_ref() else { return Ok(None) };
        if expected.is_some_and(|turn| turn != active.id)
            || active.cancel_requested
            || (dispatched_only && !active.dispatched)
        {
            return Err(HostError::TurnChanged);
        }
        Ok(Some(active.id.clone()))
    }

    /// Record an accepted supplement in `turn`'s transcript and tell the
    /// controllers, whose folds add the same item (see
    /// `Transcript::supplement`), naming its sender's `client_id`.
    fn record_supplement(
        &self,
        generation: u64,
        session: &str,
        turn: &str,
        text: &str,
        images: usize,
        client_id: Option<&str>,
    ) {
        let mut state = self.state();
        if state.generation == generation {
            record_supplement(&mut state, session, turn, text, images, client_id);
        }
    }
}

/// Fold an accepted supplement into `turn`'s transcript and tell the
/// controllers, whose folds add the same item, naming its sender's
/// `client_id`.
pub(super) fn record_supplement(
    state: &mut State,
    session: &str,
    turn: &str,
    text: &str,
    images: usize,
    client_id: Option<&str>,
) {
    let text = clip(text, MAX_PROMPT_TEXT);
    if let Some(transcript) = state.transcript_mut(session) {
        transcript.supplement(turn, &text, images);
    }
    state.event(json!({
        "type": "supplement", "sessionId": session, "turnId": turn,
        "text": text, "imageCount": images, "clientId": client_id,
    }));
}
