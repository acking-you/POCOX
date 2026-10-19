use std::sync::Condvar;

use super::*;
use crate::acp::{schema::SteerOutcome, store::SourceId};

const WAIT: Duration = Duration::from_secs(15);

/// The example agent Cargo builds next to the test binaries.
pub(super) fn mock_binary() -> PathBuf {
    let exe = std::env::current_exe().expect("test executable");
    let dir = exe
        .parent()
        .and_then(|deps| deps.parent())
        .expect("target dir");
    let mock = dir.join("examples").join("mock_acp_agent");
    assert!(
        mock.is_file(),
        "{} is missing: run the package tests (`cargo test -p pocket-codex-host-svc`), which \
         build examples",
        mock.display()
    );
    mock
}

async fn mock_host() -> AgentHost {
    let program = mock_binary();
    let spec = AgentSpec {
        profile_id: "custom-mock".into(),
        display_name: "Mock".into(),
        program: program.to_string_lossy().into_owned(),
        args: vec!["--profile".into(), "alpha".into()],
    };
    start_mock(program, spec).await
}

pub(super) async fn start_mock(program: PathBuf, spec: AgentSpec) -> AgentHost {
    let store = SessionStore::memory(SourceId::with_key(&"k".repeat(32), &program, &spec.args));
    let (host, launched) = AgentHost::start(HostOptions {
        spec,
        program,
        path: None,
        env: Vec::new(),
        env_remove: Vec::new(),
        store,
    })
    .await;
    launched.expect("launch");
    host
}

pub(super) async fn eventually(mut check: impl FnMut() -> bool, what: &str) {
    let deadline = Instant::now() + WAIT;
    while !check() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

pub(super) fn outcome(host: &AgentHost, session: &str, turn: &str) -> Option<TurnOutcome> {
    host.state()
        .outcomes_of(session, turn)
        .first()
        .map(|outcome| (*outcome).clone())
}

/// The race the dispatch lane closes: cancel A passes its last check
/// (A running and dispatched), A then ends on its own and B is admitted
/// and dispatched, and only then is the cancel written. Without one lane
/// for dispatch and cancel, the session-wide `session/cancel` lands after
/// B's prompt and cancels B.
#[tokio::test]
async fn a_cancel_for_an_ended_turn_never_reaches_the_next_one() {
    let host = mock_host().await;
    let cwd = tempfile::tempdir().expect("tempdir");
    let opened = host
        .new_session(&cwd.path().to_string_lossy(), None)
        .await
        .expect("session");
    let session = opened["sessionId"].as_str().expect("id").to_string();
    let a = host
        .prompt(&session, "linger", &[], None)
        .await
        .expect("turn a");
    eventually(
        || {
            let generation = host.state().generation;
            host.dispatched(generation, &session, &a)
        },
        "a dispatched",
    )
    .await;
    let reached = Arc::new(tokio::sync::Barrier::new(2));
    let resume = Arc::new(tokio::sync::Barrier::new(2));
    *lock(&host.inner.cancel_pause) = Some((reached.clone(), resume.clone()));
    let canceller = tokio::spawn({
        let (host, session, a) = (host.clone(), session.clone(), a.clone());
        async move { host.cancel(&session, Some(&a), None).await }
    });
    reached.wait().await;
    // A ends on its own while the cancel is between its check and its
    // write; B is admitted and its dispatch starts.
    eventually(|| outcome(&host, &session, &a).is_some(), "a ended").await;
    let b = host
        .prompt(&session, "probe", &[], None)
        .await
        .expect("turn b");
    tokio::time::sleep(Duration::from_millis(150)).await;
    resume.wait().await;
    assert_eq!(canceller.await.expect("join"), Ok(true));
    eventually(|| outcome(&host, &session, &b).is_some(), "b ended").await;
    assert_eq!(
        outcome(&host, &session, &b),
        Some(TurnOutcome::Stopped {
            stop_reason: "end_turn".into()
        }),
        "the cancel meant for A must not cancel B"
    );
    host.stop().await;
}

// ---- Delivery budgets against an agent that stops reading ----------
//
// The `deaf` script asks for a permission and then never reads its input
// again, while the process stays alive. A prompt far larger than a pipe
// buffer then blocks the writer in the middle of its frame while the
// queue still has room. Budgets are shortened per test; the production
// ones are unchanged.

/// A host with a live permission request from an agent that stopped
/// reading, and that request's handle.
async fn deaf_host() -> (AgentHost, String, String, Peer, tempfile::TempDir) {
    let host = mock_host().await;
    let cwd = tempfile::tempdir().expect("tempdir");
    let new = |host: AgentHost, cwd: String| async move {
        host.new_session(&cwd, None).await.expect("session")["sessionId"]
            .as_str()
            .expect("id")
            .to_string()
    };
    let path = cwd.path().to_string_lossy().into_owned();
    let deaf = new(host.clone(), path.clone()).await;
    let other = new(host.clone(), path).await;
    host.prompt(&deaf, "deaf", &[], None).await.expect("turn");
    eventually(|| !host.state().permissions.is_empty(), "the agent's permission request").await;
    let handle = host
        .state()
        .permissions
        .keys()
        .next()
        .cloned()
        .expect("handle");
    let peer = host.state().peer.clone().expect("peer");
    (host, other, handle, peer, cwd)
}

fn budgets(host: &AgentHost, dispatch: Duration, control: Duration) {
    *lock(&host.inner.budgets) = Budgets {
        dispatch,
        control,
        ..Budgets::default()
    };
}

/// A prompt the agent does not read: its delivery (not just its queue
/// admission) is bounded, it fails truthfully, and the possibly
/// half-written connection is closed — that generation ends.
#[tokio::test]
async fn a_prompt_the_agent_never_reads_fails_boundedly_and_ends_the_generation() {
    let (host, other, _, peer, _cwd) = deaf_host().await;
    budgets(&host, Duration::from_millis(300), Duration::from_millis(300));
    let started = Instant::now();
    let big = "x".repeat(1024 * 1024);
    let turn = host
        .prompt(&other, &big, &[], None)
        .await
        .expect("admitted");
    eventually(|| outcome(&host, &other, &turn).is_some() || peer.is_closed(), "bounded").await;
    assert!(started.elapsed() < Duration::from_secs(5));
    assert!(peer.is_closed(), "a partly written prompt closes the connection");
    eventually(
        || {
            let state = host.state();
            state.phase != Phase::Ready || state.peer.is_none()
        },
        "the generation ends",
    )
    .await;
    host.stop().await;
}

/// The writer is stalled while the queue has room; a permission answer
/// cannot be delivered in time. The request was consumed, so the
/// generation is closed rather than left waiting on a live connection,
/// and a retry cannot pretend to answer it.
#[tokio::test]
async fn an_undeliverable_permission_answer_ends_the_generation() {
    let (host, other, handle, peer, _cwd) = deaf_host().await;
    // A long dispatch budget: the stalled prompt keeps the writer busy.
    budgets(&host, WAIT, Duration::from_millis(300));
    host.prompt(&other, &"x".repeat(1024 * 1024), &[], None)
        .await
        .expect("admitted");
    tokio::time::sleep(Duration::from_millis(100)).await;
    let started = Instant::now();
    assert_eq!(host.answer_permission(&handle, "allow").await, Err(HostError::Timeout));
    assert!(started.elapsed() < Duration::from_secs(5));
    assert!(peer.is_closed(), "no consumed request stays unanswered on a live connection");
    assert!(host.answer_permission(&handle, "allow").await.is_err(), "first answer wins");
    host.stop().await;
}

/// The dispatch lane is held by a prompt the agent does not read. A
/// cancel's budget includes waiting for the lane: it fails in time,
/// ends the generation, and a retry reports that nothing runs any more
/// instead of a cancel that never happened.
#[tokio::test]
async fn a_cancel_behind_a_stalled_lane_fails_in_time_and_a_retry_is_truthful() {
    let (host, other, _, peer, _cwd) = deaf_host().await;
    budgets(&host, WAIT, Duration::from_millis(300));
    let stalled = host
        .prompt(&other, &"x".repeat(1024 * 1024), &[], None)
        .await
        .expect("admitted");
    eventually(
        || {
            let generation = host.state().generation;
            host.dispatched(generation, &other, &stalled)
        },
        "the big prompt holds the lane",
    )
    .await;
    let started = Instant::now();
    assert_eq!(host.cancel(&other, Some(&stalled), None).await, Err(HostError::Timeout));
    assert!(started.elapsed() < Duration::from_secs(5));
    assert!(peer.is_closed());
    let retried = host.cancel(&other, Some(&stalled), None).await;
    assert!(
        matches!(retried, Ok(false) | Err(HostError::NotReady)),
        "a retry is not a silent success: {retried:?}"
    );
    host.stop().await;
}

#[tokio::test]
async fn dropping_a_consumed_permission_answer_ends_the_generation() {
    let (host, _other, handle, peer, _cwd) = deaf_host().await;
    budgets(&host, WAIT, WAIT);
    let mut stalled = Box::pin(peer.notify(
        "fixture/block",
        json!("x".repeat(1024 * 1024)),
        Instant::now() + WAIT,
    ));
    assert!(
        tokio::time::timeout(Duration::from_millis(50), &mut stalled)
            .await
            .is_err(),
        "writer must really be blocked before the answer"
    );
    let mut answer = Box::pin(host.answer_permission(&handle, "allow"));
    assert!(tokio::time::timeout(Duration::from_millis(50), &mut answer)
        .await
        .is_err());
    assert!(host.state().was_resolved(&handle), "actual permission was consumed");
    drop(answer);
    assert!(peer.is_closed());
    drop(stalled);
    host.stop().await;
}

#[tokio::test]
async fn dropping_cancel_while_waiting_for_the_lane_ends_the_generation() {
    let (host, other, _, peer, _cwd) = deaf_host().await;
    budgets(&host, WAIT, WAIT);
    let turn = host
        .prompt(&other, &"x".repeat(1024 * 1024), &[], None)
        .await
        .expect("prompt");
    eventually(
        || {
            let generation = host.state().generation;
            host.dispatched(generation, &other, &turn)
        },
        "dispatch owns lane",
    )
    .await;
    let mut cancel = Box::pin(host.cancel(&other, Some(&turn), None));
    assert!(tokio::time::timeout(Duration::from_millis(50), &mut cancel)
        .await
        .is_err());
    assert!(
        host.state().sessions[&other]
            .active
            .as_ref()
            .expect("active")
            .cancel_requested
    );
    drop(cancel);
    assert!(peer.is_closed());
    host.stop().await;
}

#[tokio::test]
async fn automatic_permission_cancellation_has_an_owned_write_deadline() {
    let (host, other, _, peer, _cwd) = deaf_host().await;
    budgets(&host, WAIT, Duration::from_millis(50));
    // No active turn in this admitted session: production on_permission
    // automatically replies cancelled, using the agent's legal string id.
    let generation = host.state().generation;
    host.on_permission(
        generation,
        &peer,
        RequestId::Str("x".repeat(128 * 1024)),
        Some(json!({
            "sessionId": other,
            "toolCall": {"toolCallId":"late", "title":"Late request"},
            "options": [{"optionId":"allow", "name":"Allow", "kind":"allow_once"}]
        })),
    );
    eventually(|| peer.is_closed(), "automatic response deadline").await;
    host.stop().await;
}

/// Stall the writer of session records while titles flood in: pending
/// work stays one change, a flush gives up in time, and once the store
/// answers the newest title is what was written.
#[tokio::test]
async fn a_stalled_store_keeps_titles_coalesced_and_flushes_boundedly() {
    let gate = Arc::new((Mutex::new(false), Condvar::new()));
    let applied: Arc<Mutex<Vec<Change>>> = Arc::default();
    let apply: Apply = {
        let (gate, applied) = (gate.clone(), applied.clone());
        Arc::new(move |changes: Vec<Change>| {
            let (open, wake) = &*gate;
            let mut open = lock(open);
            while !*open {
                open = wake.wait(open).unwrap_or_else(|poison| poison.into_inner());
            }
            lock(&applied).extend(changes);
        })
    };
    let persist = Persist::spawn(apply);
    persist.submit(|pending| pending.record("s", "/w", None));
    // Let the worker take the admission and block on the store.
    tokio::time::sleep(Duration::from_millis(50)).await;
    for n in 0..10_000 {
        persist.submit(|pending| pending.title("s", Some(format!("v{n}"))));
    }
    assert_eq!(persist.pending(), 1, "titles coalesce while the store is stalled");
    let started = Instant::now();
    assert!(!persist.flush(Duration::from_millis(100)).await, "a stalled flush gives up");
    assert!(started.elapsed() < Duration::from_secs(2));
    {
        let (open, wake) = &*gate;
        *lock(open) = true;
        wake.notify_all();
    }
    assert!(persist.flush(WAIT).await);
    let applied = lock(&applied);
    assert_eq!(applied.len(), 2, "the admission, then one coalesced title");
    assert_eq!(applied[0].cwd.as_deref(), Some("/w"));
    assert_eq!(applied[1].title, Some(Some("v9999".to_string())));
}

// ---- Supplements (`_session/steering`) and the turn-end session state ---

/// A host of the mock agent advertising steering in `mode` (see the mock's
/// `--steering`), with one session.
async fn steering_host(mode: &str) -> (AgentHost, String, tempfile::TempDir) {
    let program = mock_binary();
    let spec = AgentSpec {
        profile_id: "custom-mock".into(),
        display_name: "Mock".into(),
        program: program.to_string_lossy().into_owned(),
        args: vec!["--steering".into(), mode.into()],
    };
    let host = start_mock(program, spec).await;
    let cwd = tempfile::tempdir().expect("tempdir");
    let opened = host
        .new_session(&cwd.path().to_string_lossy(), None)
        .await
        .expect("session");
    let session = opened["sessionId"].as_str().expect("id").to_string();
    (host, session, cwd)
}

/// Every retained event body.
pub(super) fn bodies(host: &AgentHost) -> Vec<Value> {
    host.state()
        .log
        .since(0)
        .unwrap_or_default()
        .iter()
        .filter_map(|entry| serde_json::from_str(&entry.body).ok())
        .collect()
}

pub(super) async fn dispatched_turn(host: &AgentHost, session: &str, script: &str) -> String {
    let turn = host.prompt(session, script, &[], None).await.expect("turn");
    eventually(
        || {
            let generation = host.state().generation;
            host.dispatched(generation, session, &turn)
        },
        "dispatched",
    )
    .await;
    turn
}

fn supplements(host: &AgentHost) -> usize {
    bodies(host)
        .iter()
        .filter(|body| body["type"] == "supplement")
        .count()
}

#[tokio::test]
async fn an_agent_without_steering_is_refused_before_anything_is_sent() {
    let host = mock_host().await;
    let cwd = tempfile::tempdir().expect("tempdir");
    let opened = host
        .new_session(&cwd.path().to_string_lossy(), None)
        .await
        .expect("session");
    let session = opened["sessionId"].as_str().expect("id").to_string();
    let turn = dispatched_turn(&host, &session, "slow").await;
    assert!(matches!(
        host.steer(&session, Some(&turn), "more", &[], None).await,
        Err(HostError::Unsupported(_))
    ));
    host.stop().await;
}

#[tokio::test]
async fn a_supplement_reaches_the_running_turn_and_is_recorded_once() {
    let (host, session, _cwd) = steering_host("ok").await;
    // Idle: nothing is consumed and the agent is not asked.
    assert_eq!(
        host.steer(&session, None, "early", &[], None).await,
        Ok((SteerOutcome::PromptRequired, None))
    );
    let turn = dispatched_turn(&host, &session, "slow").await;
    assert_eq!(
        host.steer_as(&session, Some(&turn), "more", &[], Some("pocox-view-2"), None)
            .await,
        Ok((SteerOutcome::Injected, Some(turn.clone())))
    );
    assert_eq!(supplements(&host), 1);
    let event = bodies(&host)
        .into_iter()
        .find(|body| body["type"] == "supplement")
        .expect("event");
    assert_eq!(event["clientId"], "pocox-view-2", "the sender's name for its message");
    let item = host
        .state()
        .transcript_ref(&session)
        .and_then(|t| t.turn(&turn).cloned())
        .and_then(|t| {
            t.items
                .into_iter()
                .find(|i| i.id.starts_with(&format!("{turn}:s")))
        })
        .expect("supplement item");
    assert_eq!(item.text, "more");
    // The agent saw it inside the turn.
    eventually(
        || {
            bodies(&host)
                .iter()
                .any(|b| b["type"] == "update" && b["update"]["content"]["text"] == "steered:more")
        },
        "the agent's echo",
    )
    .await;
    host.cancel(&session, Some(&turn), None)
        .await
        .expect("cancel");
    host.stop().await;
}

#[tokio::test]
async fn a_supplement_for_another_turn_host_or_a_cancelled_turn_is_refused() {
    let (host, session, _cwd) = steering_host("ok").await;
    let turn = dispatched_turn(&host, &session, "slow").await;
    assert_eq!(
        host.steer(&session, Some("an-older-turn"), "x", &[], None)
            .await,
        Err(HostError::TurnChanged)
    );
    let other_host = Identity {
        host_id: Some("another-incarnation".into()),
        generation: None,
    };
    assert_eq!(
        host.steer(&session, Some(&turn), "x", &[], Some(&other_host))
            .await,
        Err(HostError::Stale)
    );
    assert!(host
        .cancel(&session, Some(&turn), None)
        .await
        .expect("cancel"));
    // Still finishing, but being cancelled: nothing more is added.
    assert_eq!(
        host.steer(&session, Some(&turn), "x", &[], None).await,
        Err(HostError::TurnChanged)
    );
    assert_eq!(supplements(&host), 0);
    host.stop().await;
}

/// The host still runs the turn, the agent already finished it: the
/// agent's `promptRequired` comes back as such, and nothing is recorded.
#[tokio::test]
async fn an_agent_that_finished_first_answers_prompt_required() {
    let (host, session, _cwd) = steering_host("ok").await;
    let turn = dispatched_turn(&host, &session, "settle").await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(
        host.steer(&session, Some(&turn), "late", &[], None).await,
        Ok((SteerOutcome::PromptRequired, None))
    );
    assert_eq!(supplements(&host), 0);
    host.stop().await;
}

#[tokio::test]
async fn an_unrecognized_or_missing_answer_is_reported_and_not_recorded() {
    let (host, session, _cwd) = steering_host("odd").await;
    let turn = dispatched_turn(&host, &session, "slow").await;
    assert!(matches!(
        host.steer(&session, Some(&turn), "x", &[], None).await,
        Err(HostError::Agent(_))
    ));
    assert_eq!(supplements(&host), 0);
    host.stop().await;

    let (host, session, _cwd) = steering_host("silent").await;
    lock(&host.inner.budgets).answer = Duration::from_millis(200);
    let turn = dispatched_turn(&host, &session, "slow").await;
    assert_eq!(host.steer(&session, Some(&turn), "x", &[], None).await, Err(HostError::Timeout));
    assert_eq!(supplements(&host), 0);
    // The connection loss of a later unanswered supplement is reported.
    lock(&host.inner.budgets).answer = WAIT;
    let waiting = tokio::spawn({
        let (host, session, turn) = (host.clone(), session.clone(), turn.clone());
        async move { host.steer(&session, Some(&turn), "y", &[], None).await }
    });
    tokio::time::sleep(Duration::from_millis(100)).await;
    host.stop().await;
    assert_eq!(waiting.await.expect("join"), Err(HostError::NotReady));
    assert_eq!(supplements(&host), 0);
}

/// Controllers cache the session state; when a turn ends they get a state
/// that no longer names it, after the `turn_ended` event.
#[tokio::test]
async fn the_session_state_after_a_turn_ends_names_no_running_turn() {
    let host = mock_host().await;
    let cwd = tempfile::tempdir().expect("tempdir");
    let opened = host
        .new_session(&cwd.path().to_string_lossy(), None)
        .await
        .expect("session");
    let session = opened["sessionId"].as_str().expect("id").to_string();
    let turn = host
        .prompt(&session, "hello", &[], None)
        .await
        .expect("turn");
    eventually(|| outcome(&host, &session, &turn).is_some(), "ended").await;
    let events = bodies(&host);
    let ended = events
        .iter()
        .position(|b| b["type"] == "turn_ended" && b["turnId"] == turn.as_str())
        .expect("turn_ended");
    let state = events[ended..]
        .iter()
        .find(|b| b["type"] == "session_state" && b["sessionId"] == session.as_str())
        .expect("a session state after the end");
    assert!(state["runningTurnId"].is_null());
    assert_eq!(state["turnDispatched"], false);
    host.stop().await;
}

/// A configured host adds its `_meta` to session creation and reopening
/// (an instance's provider route), and an ordinary host adds none.
#[tokio::test]
async fn session_requests_carry_only_the_configured_meta() {
    let options = |profile: &str| {
        let program = PathBuf::from("/nonexistent/agent");
        let spec = AgentSpec {
            profile_id: profile.into(),
            display_name: "Agent".into(),
            program: program.to_string_lossy().into_owned(),
            args: Vec::new(),
        };
        HostOptions {
            store: SessionStore::memory(SourceId::with_key(&"k".repeat(32), &program, &spec.args)),
            spec,
            program,
            path: None,
            env: Vec::new(),
            env_remove: Vec::new(),
        }
    };
    let mut meta = serde_json::Map::new();
    meta.insert("claudeCode".into(), json!({"options": {"settings": {"apiKeyHelper": ""}}}));
    let configured = AgentHost::create_configured(options("claude"), None, Some(meta));
    let params = configured.session_params(json!({"cwd": "/p", "mcpServers": []}));
    assert_eq!(params["_meta"]["claudeCode"]["options"]["settings"]["apiKeyHelper"], "");
    assert_eq!(params["cwd"], "/p", "the request itself is unchanged");
    let plain = AgentHost::create(options("custom-x"));
    let params = plain.session_params(json!({"cwd": "/p", "mcpServers": []}));
    assert!(params.get("_meta").is_none());
}
