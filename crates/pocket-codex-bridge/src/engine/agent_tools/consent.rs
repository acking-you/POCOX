//! The user's consent before an agent shares a port or connects another
//! device's Responses API (which spends that device's model account).
//!
//! POCOX asks on the user's own devices (the catalog's event stream), for any
//! harness and whatever its approval policy: harness prompts can be answered
//! automatically by the harness itself, so they are not used for this. The
//! call waits a while for the answer; a later call with the same owner and
//! the same request picks up an answer given after it returned.
//!
//! An answer covers what the user was shown: "Allow once" admits that exact
//! request only, while "Allow in this conversation" and "Deny" apply to the
//! owner's sharing, or connecting, and settle its other waiting requests for
//! it at once.

use std::{collections::BTreeSet, sync::Arc, time::Duration};

use tokio::sync::Notify;

use super::{
    builtin::{CONNECT, SHARE},
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
    Waiting(Box<ConsentView>, Arc<Notify>),
}

/// What an agent asks the user for.
#[derive(Clone, Copy)]
enum Ask<'a> {
    /// Share `ports` of this device, as `title`.
    Share { title: &'a str, ports: &'a [u16] },
    /// Connect the Responses API with relay key `service`, named `title`.
    Connect { service: &'a str, title: &'a str },
}

impl Ask<'_> {
    fn tool(self) -> &'static str {
        match self {
            Self::Share {
                ..
            } => SHARE,
            Self::Connect {
                ..
            } => CONNECT,
        }
    }

    /// Whether `consent` asked for exactly this: an answer to a request
    /// with more or fewer ports is not one to this.
    fn is(self, consent: &Consent) -> bool {
        let set = |ports: &[u16]| ports.iter().copied().collect::<BTreeSet<u16>>();
        match self {
            Self::Share {
                ports, ..
            } => consent.view.service.is_none() && set(&consent.view.ports) == set(ports),
            Self::Connect {
                service, ..
            } => consent.view.service.as_deref() == Some(service),
        }
    }

    /// Whether a concurrent call of the same owner was admitted to it first.
    fn held(self, state: &State, key: &OwnerKey) -> bool {
        match self {
            Self::Share {
                ports, ..
            } => ports.iter().all(|port| {
                state
                    .share_with_port(*port)
                    .is_some_and(|share| share.key.as_ref() == Some(key))
            }),
            Self::Connect {
                service, ..
            } => state.connections.iter().any(|connection| {
                connection.service == service
                    && connection.holders.iter().any(|(holder, _)| holder == key)
            }),
        }
    }
}

/// Apply the answer that covers this call, or open a request, without
/// waiting. Fails once the caller may no longer act at all.
fn look(
    state: &mut State,
    caller: &Caller,
    key: &OwnerKey,
    ask: Ask<'_>,
) -> Result<Answer, ToolError> {
    state.admits(caller)?;
    let now = now_ms();
    let tool = ask.tool();
    if ask.held(state, key)
        || !state.settings.ask_before_sharing
        || state.allowed.contains(&(key.clone(), tool))
        || state.granted(caller, key, tool)
    {
        return Ok(Answer::Allowed);
    }
    if state
        .declined
        .iter()
        .any(|(owner, declined, until)| owner == key && *declined == tool && *until > now)
    {
        return Ok(Answer::Declined);
    }
    let asked = |consent: &Consent| &consent.key == key && ask.is(consent);
    if let Some(index) = state
        .consents
        .iter()
        .position(|c| asked(c) && c.decision == Some(Decision::AllowOnce))
    {
        state.consents.remove(index);
        state::changed(state);
        return Ok(Answer::Allowed);
    }
    if let Some(consent) = state
        .consents
        .iter()
        .find(|c| asked(c) && c.decision.is_none())
    {
        return Ok(Answer::Waiting(Box::new(consent.view.clone()), consent.answered.clone()));
    }
    let (all, mine) = state
        .consents
        .iter()
        .filter(|c| c.decision.is_none())
        .fold((0, 0), |(all, mine), c| (all + 1, mine + usize::from(c.key.token == key.token)));
    if all >= MAX_PENDING || mine >= MAX_PENDING_PER_TOKEN {
        return Err(ToolError::Invalid(
            "Too many requests are waiting for the user. Wait for an answer before asking again."
                .into(),
        ));
    }
    let (title, ports, service) = match ask {
        Ask::Share {
            title,
            ports,
        } => (title, ports.to_vec(), None),
        Ask::Connect {
            service,
            title,
        } => (title, Vec::new(), Some(service.to_string())),
    };
    let view = ConsentView {
        id: uuid::Uuid::new_v4().simple().to_string()[..10].to_string(),
        owner: caller.owner(),
        title: title.to_string(),
        ports,
        service,
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
    tracing::info!(consent = %view.id, owner = %view.owner.label, tool, "asking the user");
    Ok(Answer::Waiting(Box::new(view), answered))
}

/// Whether `caller` may share `ports` now: `Ok(Ok(()))` when allowed, a
/// pending result while the user has not answered.
pub async fn admit(
    caller: &Caller,
    key: &OwnerKey,
    title: &str,
    ports: &[u16],
) -> Result<Result<(), Pending>, ToolError> {
    wait(caller, key, Ask::Share {
        title,
        ports,
    })
    .await
}

/// Whether `caller` may connect the Responses API with relay key `service`
/// (named `title`) now, as [`admit`] answers.
pub async fn admit_connect(
    caller: &Caller,
    key: &OwnerKey,
    service: &str,
    title: &str,
) -> Result<Result<(), Pending>, ToolError> {
    wait(caller, key, Ask::Connect {
        service,
        title,
    })
    .await
}

async fn wait(
    caller: &Caller,
    key: &OwnerKey,
    ask: Ask<'_>,
) -> Result<Result<(), Pending>, ToolError> {
    let deadline = tokio::time::Instant::now() + caller.consent_wait();
    loop {
        let answer = look(&mut state::lock(), caller, key, ask)?;
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
    let (key, tool) = (state.consents[index].key.clone(), state.consents[index].tool());
    let woken = match decision {
        Decision::AllowOnce => {
            state.consents[index].decision = Some(decision);
            vec![state.consents[index].answered.clone()]
        },
        // About the owner's sharing (or connecting), not one request: its
        // other requests for it are settled.
        Decision::AllowConversation | Decision::Deny => {
            if decision == Decision::AllowConversation {
                state.allowed.insert((key.clone(), tool));
            } else {
                state
                    .declined
                    .push((key.clone(), tool, now_ms() + DECLINED_MS));
            }
            remove(state, |consent| consent.key == key && consent.tool() == tool)
        },
    };
    tracing::info!(consent = %id, ?decision, "the user answered");
    state::changed(state);
    Ok(woken)
}

/// The user handed the gated built-in `tools` to conversation
/// `conversation` of hosted instance `host` from the composer: its requests
/// for them waiting for an answer go ahead (the woken calls find the grant).
/// Returns the calls to wake once the state is unlocked.
pub fn settle_granted(
    state: &mut State,
    host: &str,
    conversation: Option<&str>,
    tools: &[String],
) -> Vec<Arc<Notify>> {
    remove(state, |consent| {
        consent.decision.is_none()
            && consent.view.owner.host.as_deref() == Some(host)
            && consent.key.conversation.as_deref() == conversation
            && tools.iter().any(|tool| tool == consent.tool())
    })
}

fn remove(state: &mut State, which: impl Fn(&Consent) -> bool) -> Vec<Arc<Notify>> {
    let (gone, kept): (Vec<Consent>, Vec<Consent>) = std::mem::take(&mut state.consents)
        .into_iter()
        .partition(|consent| which(consent));
    state.consents = kept;
    gone.into_iter().map(|consent| consent.answered).collect()
}

/// Withdraw the requests of the owners `which` selects (their token ended,
/// the switch went off, the account changed) and wake their waiting calls,
/// which then fail.
pub fn withdraw(which: impl Fn(&OwnerKey) -> bool) {
    let mut state = state::lock();
    let woken = remove(&mut state, |consent| which(&consent.key));
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
    state.declined.retain(|(_, _, until)| *until > now);
    if before != (state.consents.len(), state.declined.len()) {
        state::changed(state);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::agent_tools::{state::Granted, tokens::Kind};

    const API: &str = "pcx:devbox:api:main";

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

    fn share<'a>(title: &'a str, ports: &'a [u16]) -> Ask<'a> {
        Ask::Share {
            title,
            ports,
        }
    }

    fn connect(service: &str) -> Ask<'_> {
        Ask::Connect {
            service,
            title: "main",
        }
    }

    fn waiting(answer: Result<Answer, ToolError>) -> ConsentView {
        match answer {
            Ok(Answer::Waiting(view, _)) => *view,
            _ => panic!("expected a request waiting for the user"),
        }
    }

    #[test]
    fn allowing_once_covers_only_the_request_the_user_was_shown() {
        let (mut state, caller) = setup();
        let key = caller.key();
        let page = waiting(look(&mut state, &caller, &key, share("Landing", &[5173, 8000])));
        // Fewer ports of the same owner are a request of their own.
        let part = waiting(look(&mut state, &caller, &key, share("Landing", &[5173])));
        assert_ne!(page.id, part.id);
        answer_in(&mut state, &page.id, Decision::AllowOnce).expect("answer");
        waiting(look(&mut state, &caller, &key, share("Landing", &[5173])));
        assert!(matches!(
            look(&mut state, &caller, &key, share("Landing", &[8000, 5173])),
            Ok(Answer::Allowed)
        ));
        // Used once: sharing again asks again.
        waiting(look(&mut state, &caller, &key, share("Landing", &[5173, 8000])));
    }

    #[test]
    fn owner_answers_settle_its_requests_and_calls_end_with_their_token() {
        let (mut state, caller) = setup();
        let key = caller.key();
        let page = waiting(look(&mut state, &caller, &key, share("Landing", &[5173])));
        waiting(look(&mut state, &caller, &key, share("API", &[8000])));
        let woken = answer_in(&mut state, &page.id, Decision::AllowConversation).expect("answer");
        assert_eq!((woken.len(), state.consents.len()), (2, 0));
        assert!(matches!(
            look(&mut state, &caller, &key, share("Docs", &[9000])),
            Ok(Answer::Allowed)
        ));
        let other = Caller {
            conversation: Some("c2".into()),
            ..caller.clone()
        };
        let asked = waiting(look(&mut state, &other, &other.key(), share("API", &[8000])));
        answer_in(&mut state, &asked.id, Decision::Deny).expect("deny");
        assert!(matches!(
            look(&mut state, &other, &other.key(), share("API", &[8001])),
            Ok(Answer::Declined)
        ));
        state.tokens.forget_where(|p| p.id == caller.principal.id);
        assert!(matches!(
            look(&mut state, &caller, &key, share("Docs", &[9000])),
            Err(ToolError::Revoked)
        ));
    }

    #[test]
    fn an_answer_covers_sharing_or_connecting_not_both() {
        let (mut state, caller) = setup();
        let key = caller.key();
        let page = waiting(look(&mut state, &caller, &key, share("Landing", &[5173])));
        let model = waiting(look(&mut state, &caller, &key, connect(API)));
        assert_eq!(model.service.as_deref(), Some(API));
        answer_in(&mut state, &page.id, Decision::AllowConversation).expect("answer");
        // Sharing more goes ahead; the connection still waits for its answer.
        assert!(matches!(
            look(&mut state, &caller, &key, share("Docs", &[9000])),
            Ok(Answer::Allowed)
        ));
        assert_eq!(waiting(look(&mut state, &caller, &key, connect(API))).id, model.id);
        answer_in(&mut state, &model.id, Decision::Deny).expect("deny");
        assert!(matches!(
            look(&mut state, &caller, &key, connect("pcx:devbox:api:other")),
            Ok(Answer::Declined)
        ));
        assert!(matches!(
            look(&mut state, &caller, &key, share("API", &[8000])),
            Ok(Answer::Allowed)
        ));
    }

    #[test]
    fn a_tool_picked_in_the_composer_admits_its_own_conversation_only() {
        let mut state = State {
            hosting: true,
            ..State::default()
        };
        state.settings.ask_before_sharing = true;
        let (principal, _) = state
            .tokens
            .mint(Kind::Hosted, "Codex · live", Some("codex"), Some("live"))
            .expect("mint");
        let caller = |conversation: &str| Caller {
            principal: principal.clone(),
            conversation: Some(conversation.into()),
        };
        let (here, elsewhere) = (caller("t1"), caller("t2"));
        // The agent already waits for the user when the user picks Share.
        waiting(look(&mut state, &here, &here.key(), share("Landing", &[5173])));
        let model = waiting(look(&mut state, &here, &here.key(), connect(API)));
        state.granted.insert(Granted {
            host: "live".into(),
            conversation: Some("t1".into()),
            tool: SHARE.into(),
        });
        assert_eq!(settle_granted(&mut state, "live", Some("t1"), &[SHARE.into()]).len(), 1);
        assert!(matches!(
            look(&mut state, &here, &here.key(), share("Landing", &[5173])),
            Ok(Answer::Allowed)
        ));
        // Connecting was not picked: it still waits for the user.
        assert_eq!(waiting(look(&mut state, &here, &here.key(), connect(API))).id, model.id);
        // Another conversation of the same instance still asks.
        waiting(look(&mut state, &elsewhere, &elsewhere.key(), share("API", &[8000])));
    }
}
