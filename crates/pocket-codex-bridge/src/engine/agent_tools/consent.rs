//! The user's consent before an agent shares a port.
//!
//! POCOX asks on the user's own devices (the catalog's event stream), for any
//! harness and whatever its approval policy: harness prompts can be answered
//! automatically by the harness itself, so they are not used for this. The
//! call waits a while for the answer; a later call with the same owner picks up
//! an answer given after it returned.

use std::{sync::Arc, time::Duration};

use tokio::sync::Notify;

use super::{
    error::{Pending, ToolError},
    model::{ConsentView, Decision},
    shares::Caller,
    state::{self, now_ms, Consent, OwnerKey, State},
};

/// How long a request waits for an answer before it lapses.
const REQUEST_TTL_MS: i64 = 10 * 60 * 1000;

/// How long a declined owner is not asked again.
const DECLINED_MS: i64 = 10 * 60 * 1000;

enum Answer {
    Allowed,
    Declined,
    Waiting(ConsentView, Arc<Notify>),
}

/// Apply a decided request of `key` or open one, without waiting.
fn look(state: &mut State, caller: &Caller, key: &OwnerKey, title: &str, ports: &[u16]) -> Answer {
    let now = now_ms();
    if !state.settings.ask_before_sharing || state.allowed.contains(key) {
        return Answer::Allowed;
    }
    if state
        .declined
        .iter()
        .any(|(owner, until)| owner == key && *until > now)
    {
        return Answer::Declined;
    }
    if let Some(index) = state.consents.iter().position(|c| &c.key == key) {
        let decision = state.consents[index].decision;
        match decision {
            Some(decision) => {
                state.consents.remove(index);
                state::changed(state);
                return match decision {
                    Decision::AllowOnce => Answer::Allowed,
                    Decision::AllowConversation => {
                        state.allowed.insert(key.clone());
                        Answer::Allowed
                    },
                    Decision::Deny => {
                        state.declined.push((key.clone(), now + DECLINED_MS));
                        Answer::Declined
                    },
                };
            },
            None => {
                let consent = &state.consents[index];
                return Answer::Waiting(consent.view.clone(), consent.answered.clone());
            },
        }
    }
    let view = ConsentView {
        id: uuid::Uuid::new_v4().simple().to_string()[..10].to_string(),
        owner: caller.owner(),
        title: title.to_string(),
        ports: ports.to_vec(),
        created_ms: now,
        expires_ms: now + REQUEST_TTL_MS,
    };
    let answered = Arc::new(Notify::new());
    state.consents.push(Consent {
        view: view.clone(),
        key: key.clone(),
        decision: None,
        answered: answered.clone(),
    });
    state::changed(state);
    tracing::info!(consent = %view.id, owner = %view.owner.label, "asking the user to share");
    Answer::Waiting(view, answered)
}

/// Whether `caller` may share now: `Ok(Ok(()))` when allowed, a pending
/// result while the user has not answered.
pub async fn admit(
    caller: &Caller,
    key: &OwnerKey,
    title: &str,
    ports: &[u16],
) -> Result<Result<(), Pending>, ToolError> {
    let deadline = tokio::time::Instant::now() + caller.consent_wait();
    loop {
        let answer = look(&mut state::lock(), caller, key, title, ports);
        let (view, answered) = match answer {
            Answer::Allowed => return Ok(Ok(())),
            Answer::Declined => return Err(ToolError::Declined),
            Answer::Waiting(view, answered) => (view, answered),
        };
        let notified = answered.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();
        // An answer between the look and `enable` is caught by the next look.
        tokio::select! {
            _ = notified => {},
            _ = tokio::time::sleep(Duration::from_secs(1)) => {},
        }
        if tokio::time::Instant::now() >= deadline {
            return Ok(Err(Pending::WaitingForUser(Box::new(view))));
        }
    }
}

/// Record the user's answer to request `id`.
pub fn answer(id: &str, decision: Decision) -> Result<(), ToolError> {
    let mut state = state::lock();
    let consent = state
        .consents
        .iter_mut()
        .find(|consent| consent.view.id == id && consent.decision.is_none())
        .ok_or_else(|| ToolError::NotFound("That request".into()))?;
    consent.decision = Some(decision);
    let answered = consent.answered.clone();
    tracing::info!(consent = %id, ?decision, "the user answered");
    state::changed(&mut state);
    drop(state);
    answered.notify_waiters();
    Ok(())
}

/// Requests still waiting for the user.
pub fn pending(state: &State) -> Vec<ConsentView> {
    state
        .consents
        .iter()
        .filter(|consent| consent.decision.is_none())
        .map(|consent| consent.view.clone())
        .collect()
}

/// Drop lapsed requests and old declines.
pub fn prune(state: &mut State) {
    let now = now_ms();
    let before = (state.consents.len(), state.declined.len());
    state
        .consents
        .retain(|consent| consent.view.expires_ms > now);
    state.declined.retain(|(_, until)| *until > now);
    if before != (state.consents.len(), state.declined.len()) {
        state::changed(state);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::agent_tools::tokens::{Kind, Principal};

    fn agent() -> Caller {
        Caller {
            principal: Principal {
                id: "t1".into(),
                kind: Kind::Installed,
                label: "Claude Code".into(),
                harness: Some("claude".into()),
                host: None,
                session: None,
            },
            conversation: Some("c1".into()),
        }
    }

    #[test]
    fn an_answer_given_after_the_call_returned_applies_to_the_next_call() {
        let caller = agent();
        let key = caller.key();
        let mut state = State::default();
        state.settings.ask_before_sharing = true;
        let Answer::Waiting(view, _) = look(&mut state, &caller, &key, "Landing", &[5173]) else {
            panic!("asks first")
        };
        assert!(matches!(look(&mut state, &caller, &key, "Landing", &[5173]), Answer::Waiting(..)));
        state.consents[0].decision = Some(Decision::AllowOnce);
        assert!(matches!(look(&mut state, &caller, &key, "Landing", &[5173]), Answer::Allowed));
        // Allowed once: the next share asks again.
        assert!(matches!(look(&mut state, &caller, &key, "Landing", &[8000]), Answer::Waiting(..)));
        state.consents[0].decision = Some(Decision::Deny);
        assert!(matches!(look(&mut state, &caller, &key, "API", &[8000]), Answer::Declined));
        assert!(matches!(look(&mut state, &caller, &key, "API", &[8000]), Answer::Declined));
        assert_ne!(view.id, "");
    }

    #[test]
    fn allowing_a_conversation_lets_it_share_again_without_asking() {
        let caller = agent();
        let key = caller.key();
        let mut state = State::default();
        state.settings.ask_before_sharing = true;
        assert!(matches!(look(&mut state, &caller, &key, "Landing", &[5173]), Answer::Waiting(..)));
        state.consents[0].decision = Some(Decision::AllowConversation);
        assert!(matches!(look(&mut state, &caller, &key, "Landing", &[5173]), Answer::Allowed));
        assert!(matches!(look(&mut state, &caller, &key, "API", &[8000]), Answer::Allowed));
        let other = Caller {
            conversation: Some("c2".into()),
            ..agent()
        };
        assert!(matches!(
            look(&mut state, &other, &other.key(), "API", &[8000]),
            Answer::Waiting(..)
        ));
    }
}
