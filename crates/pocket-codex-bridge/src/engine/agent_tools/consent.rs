//! The user's consent before an agent shares a port.
//!
//! POCOX asks on the user's own devices (the catalog's event stream), for any
//! harness and whatever its approval policy: harness prompts can be answered
//! automatically by the harness itself, so they are not used for this. The
//! call waits a while for the answer; a later call with the same owner and
//! ports picks up an answer given after it returned.
//!
//! An answer covers what the user was shown: "Allow once" admits the ports of
//! that request only, while "Allow in this conversation" and "Deny" apply to
//! the owner and settle its other waiting requests at once.

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

/// Most requests waiting for the user at once (what a phone lists).
const MAX_PENDING: usize = 16;

/// Most requests one token keeps waiting, so a client cannot flood the
/// user's devices by naming new conversations.
const MAX_PENDING_PER_TOKEN: usize = 4;

enum Answer {
    Allowed,
    Declined,
    Waiting(ConsentView, Arc<Notify>),
}

/// Apply the answer that covers this call, or open a request, without
/// waiting. Fails once the caller may no longer act at all.
fn look(
    state: &mut State,
    caller: &Caller,
    key: &OwnerKey,
    title: &str,
    ports: &[u16],
) -> Result<Answer, ToolError> {
    state.admits(caller)?;
    let now = now_ms();
    // A concurrent call of this owner already shared them all.
    if ports.iter().all(|port| {
        state
            .share_with_port(*port)
            .is_some_and(|share| share.key.as_ref() == Some(key))
    }) {
        return Ok(Answer::Allowed);
    }
    if !state.settings.ask_before_sharing || state.allowed.contains(key) {
        return Ok(Answer::Allowed);
    }
    if state
        .declined
        .iter()
        .any(|(owner, until)| owner == key && *until > now)
    {
        return Ok(Answer::Declined);
    }
    let covers = |consent: &Consent| {
        &consent.key == key && ports.iter().all(|p| consent.view.ports.contains(p))
    };
    if let Some(index) = state
        .consents
        .iter()
        .position(|c| covers(c) && c.decision == Some(Decision::AllowOnce))
    {
        state.consents.remove(index);
        state::changed(state);
        return Ok(Answer::Allowed);
    }
    if let Some(consent) = state
        .consents
        .iter()
        .find(|c| covers(c) && c.decision.is_none())
    {
        return Ok(Answer::Waiting(consent.view.clone(), consent.answered.clone()));
    }
    let (all, mine) = state
        .consents
        .iter()
        .filter(|c| c.decision.is_none())
        .fold((0, 0), |(all, mine), c| (all + 1, mine + usize::from(c.key.token == key.token)));
    if all >= MAX_PENDING || mine >= MAX_PENDING_PER_TOKEN {
        return Err(ToolError::Invalid(
            "Too many share requests are waiting for the user. Wait for an answer before asking \
             again."
                .into(),
        ));
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
    Ok(Answer::Waiting(view, answered))
}

/// Whether `caller` may share `ports` now: `Ok(Ok(()))` when allowed, a
/// pending result while the user has not answered.
pub async fn admit(
    caller: &Caller,
    key: &OwnerKey,
    title: &str,
    ports: &[u16],
) -> Result<Result<(), Pending>, ToolError> {
    let deadline = tokio::time::Instant::now() + caller.consent_wait();
    loop {
        let answer = look(&mut state::lock(), caller, key, title, ports)?;
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
            tracing::debug!(consent = %view.id, "no answer within the call; it stays open");
            return Ok(Err(Pending::WaitingForUser));
        }
    }
}

/// Record the user's answer to request `id`.
pub fn answer(id: &str, decision: Decision) -> Result<(), ToolError> {
    let mut state = state::lock();
    let woken = answer_in(&mut state, id, decision)?;
    drop(state);
    for answered in woken {
        answered.notify_waiters();
    }
    Ok(())
}

/// [`answer`] on `state`; returns the calls to wake once it is unlocked.
fn answer_in(
    state: &mut State,
    id: &str,
    decision: Decision,
) -> Result<Vec<Arc<Notify>>, ToolError> {
    let index = state
        .consents
        .iter()
        .position(|consent| consent.view.id == id && consent.decision.is_none())
        .ok_or_else(|| ToolError::NotFound("That request".into()))?;
    let key = state.consents[index].key.clone();
    let woken = match decision {
        Decision::AllowOnce => {
            state.consents[index].decision = Some(decision);
            vec![state.consents[index].answered.clone()]
        },
        // About the owner, not one request: its other requests are settled.
        Decision::AllowConversation | Decision::Deny => {
            if decision == Decision::AllowConversation {
                state.allowed.insert(key.clone());
            } else {
                state.declined.push((key.clone(), now_ms() + DECLINED_MS));
            }
            remove(state, |owner| *owner == key)
        },
    };
    tracing::info!(consent = %id, ?decision, "the user answered");
    state::changed(state);
    Ok(woken)
}

fn remove(state: &mut State, which: impl Fn(&OwnerKey) -> bool) -> Vec<Arc<Notify>> {
    let (gone, kept): (Vec<Consent>, Vec<Consent>) = std::mem::take(&mut state.consents)
        .into_iter()
        .partition(|consent| which(&consent.key));
    state.consents = kept;
    gone.into_iter().map(|consent| consent.answered).collect()
}

/// Withdraw the requests of the owners `which` selects (their token ended,
/// the switch went off, the account changed) and wake their waiting calls,
/// which then fail.
pub fn withdraw(which: impl Fn(&OwnerKey) -> bool) {
    let mut state = state::lock();
    let woken = remove(&mut state, which);
    if woken.is_empty() {
        return;
    }
    state::changed(&mut state);
    drop(state);
    for answered in woken {
        answered.notify_waiters();
    }
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
    use crate::engine::agent_tools::tokens::Kind;

    fn setup() -> (State, Caller) {
        let mut state = State {
            hosting: true,
            ..State::default()
        };
        state.settings.ask_before_sharing = true;
        let (principal, _) = state
            .tokens
            .mint(Kind::Installed, "Claude Code", Some("claude"), None)
            .expect("mint");
        let caller = Caller {
            principal,
            conversation: Some("c1".into()),
        };
        (state, caller)
    }

    fn waiting(answer: Result<Answer, ToolError>) -> ConsentView {
        match answer {
            Ok(Answer::Waiting(view, _)) => view,
            _ => panic!("expected a request waiting for the user"),
        }
    }

    #[test]
    fn allowing_once_covers_only_the_ports_the_user_was_shown() {
        let (mut state, caller) = setup();
        let key = caller.key();
        let page = waiting(look(&mut state, &caller, &key, "Landing", &[5173]));
        // Another port of the same owner is a request of its own.
        let database = waiting(look(&mut state, &caller, &key, "DB", &[5432]));
        assert_ne!(page.id, database.id);
        answer_in(&mut state, &page.id, Decision::AllowOnce).expect("answer");
        waiting(look(&mut state, &caller, &key, "DB", &[5432]));
        assert!(matches!(look(&mut state, &caller, &key, "Landing", &[5173]), Ok(Answer::Allowed)));
        // Used once: sharing again asks again.
        waiting(look(&mut state, &caller, &key, "Landing", &[5173]));
    }

    #[test]
    fn owner_answers_settle_its_requests_and_calls_end_with_their_token() {
        let (mut state, caller) = setup();
        let key = caller.key();
        let page = waiting(look(&mut state, &caller, &key, "Landing", &[5173]));
        waiting(look(&mut state, &caller, &key, "API", &[8000]));
        let woken = answer_in(&mut state, &page.id, Decision::AllowConversation).expect("answer");
        assert_eq!((woken.len(), state.consents.len()), (2, 0));
        assert!(matches!(look(&mut state, &caller, &key, "Docs", &[9000]), Ok(Answer::Allowed)));
        let other = Caller {
            conversation: Some("c2".into()),
            ..caller.clone()
        };
        let asked = waiting(look(&mut state, &other, &other.key(), "API", &[8000]));
        answer_in(&mut state, &asked.id, Decision::Deny).expect("deny");
        assert!(matches!(
            look(&mut state, &other, &other.key(), "API", &[8001]),
            Ok(Answer::Declined)
        ));
        state.tokens.forget_where(|p| p.id == caller.principal.id);
        assert!(matches!(
            look(&mut state, &caller, &key, "Docs", &[9000]),
            Err(ToolError::Revoked)
        ));
    }
}
