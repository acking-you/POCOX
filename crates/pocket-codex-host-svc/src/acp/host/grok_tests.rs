//! Grok Build's own extensions, against the mock agent's `--grok` mode
//! (modelled on what Grok 1.0.62 sends; see `docs/grok-build.md`).

use super::{
    tests::{bodies, dispatched_turn, eventually, mock_binary, start_mock},
    *,
};
use crate::acp::schema::{self, SteerOutcome};

async fn grok_host() -> (AgentHost, String, tempfile::TempDir) {
    let program = mock_binary();
    let spec = AgentSpec {
        profile_id: "grok".into(),
        display_name: "Grok".into(),
        program: program.to_string_lossy().into_owned(),
        args: vec!["--grok".into()],
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

fn agent_said(host: &AgentHost, text: &str) -> bool {
    bodies(host)
        .iter()
        .any(|b| b["type"] == "update" && b["update"]["content"]["text"] == text)
}

/// Waits until the agent holds a request and returns its handle.
async fn held_request(host: &AgentHost) -> String {
    eventually(|| !host.state().permissions.is_empty(), "the agent's request").await;
    host.state()
        .permissions
        .keys()
        .next()
        .cloned()
        .expect("handle")
}

#[test]
fn only_a_grok_with_its_extensions_negotiates_them() {
    let negotiate = |meta: Value| {
        schema::negotiate(&json!({"protocolVersion": 1, "agentCapabilities": {}, "_meta": meta}))
            .expect("negotiated")
            .capabilities
    };
    let grok = negotiate(json!({"grokShell": true, "agentVersion": "1.0.62"}));
    assert!(grok.grok && grok.steering);
    // 1.0.4 sends no agent version, and nothing older than the reference
    // source qualifies.
    assert!(!negotiate(json!({"grokShell": true})).grok);
    assert!(!negotiate(json!({"grokShell": true, "agentVersion": "1.0.44"})).grok);
    assert!(!negotiate(json!({"agentVersion": "1.0.62"})).grok);
}

/// A supplement goes to the turn Grok reports running; a turn Grok then
/// starts by itself (a stranded interjection) is opened, folded, asks for
/// permission and ends with its own turn event.
#[tokio::test]
async fn supplements_reach_the_running_turn_and_grok_turns_are_followed() {
    let (host, session, _cwd) = grok_host().await;
    let turn = dispatched_turn(&host, &session, "slow").await;
    let generation = host.state().generation;
    eventually(|| host.grok_runs(generation, &session, &turn), "Grok running the turn").await;
    assert_eq!(
        host.steer(&session, Some(&turn), "more", &[], None).await,
        Ok((SteerOutcome::Injected, Some(turn.clone())))
    );
    eventually(|| agent_said(&host, "interjected:more"), "the interjection").await;
    // Shown where Grok merged it: after the response it arrived during
    // (which kept streaming into the same message), before the next one.
    let texts: Vec<String> = host
        .state()
        .transcript_ref(&session)
        .and_then(|t| t.turn(&turn).cloned())
        .expect("turn")
        .items
        .iter()
        .map(|item| item.text.clone())
        .collect();
    assert_eq!(texts, ["slow", "working still", "more", "interjected:more"], "{texts:?}");
    host.cancel(&session, Some(&turn), None)
        .await
        .expect("cancel");
    eventually(|| host.state().sessions[&session].active.is_none(), "the end").await;

    host.prompt(&session, "strand", &[], None)
        .await
        .expect("turn");
    let fallback = "interject-fallback-2";
    eventually(
        || {
            host.state().sessions[&session]
                .active
                .as_ref()
                .is_some_and(|active| active.id == fallback && active.agent_started)
        },
        "Grok's own turn",
    )
    .await;
    assert!(bodies(&host).iter().any(|b| b["type"] == "turn_started"
        && b["turnId"] == fallback
        && b["userText"] == "late"
        && b["agentStarted"] == true));
    let handle = held_request(&host).await;
    host.answer_permission(&handle, "allow")
        .await
        .expect("answer");
    eventually(|| agent_said(&host, "chosen:allow"), "the answer reaching it").await;
    eventually(
        || matches!(outcome_of(&host, &session, fallback), Some(TurnOutcome::Stopped { .. })),
        "its end",
    )
    .await;
    // Its content was folded into its own turn.
    let folded = host
        .state()
        .transcript_ref(&session)
        .and_then(|t| t.turn(fallback).cloned())
        .expect("folded");
    assert!(folded
        .items
        .iter()
        .any(|i| i.text.contains("fallback:late")));
    host.stop().await;
}

/// Grok can name its next prompt before this host's turn has ended and
/// been answered: the turn ends with Grok's own event and the next one
/// opens then, receiving its content.
#[tokio::test]
async fn grok_moving_on_before_the_answer_opens_its_next_turn() {
    let (host, session, _cwd) = grok_host().await;
    let turn = host
        .prompt(&session, "chain", &[], None)
        .await
        .expect("turn");
    let next = "interject-fallback-3";
    eventually(|| agent_said(&host, "chained:next"), "the next prompt's output").await;
    assert!(matches!(outcome_of(&host, &session, &turn), Some(TurnOutcome::Stopped { .. })));
    let folded = host
        .state()
        .transcript_ref(&session)
        .and_then(|t| t.turn(next).cloned())
        .expect("its own turn");
    assert!(folded.items.iter().any(|i| i.text == "chained:next"), "{folded:?}");
    eventually(|| outcome_of(&host, &session, next).is_some(), "its end").await;
    assert!(host.state().sessions[&session].active.is_none());
    host.stop().await;
}

fn outcome_of(host: &AgentHost, session: &str, turn: &str) -> Option<TurnOutcome> {
    super::tests::outcome(host, session, turn)
}

/// A question set is shown whole or refused: too many questions or
/// options, or one malformed entry, is never cut down to what fits.
#[test]
fn a_question_set_is_shown_whole_or_refused() {
    let option = json!({"label": "A", "description": ""});
    let set = |questions: usize, options: usize| {
        json!({"sessionId": "s", "questions": (0..questions)
            .map(|i| json!({"question": format!("q{i}"), "options": vec![option.clone(); options]}))
            .collect::<Vec<_>>()})
    };
    assert!(super::grok::question(&set(8, 16)).is_some());
    assert!(super::grok::question(&set(9, 1)).is_none(), "too many questions");
    assert!(super::grok::question(&set(1, 17)).is_none(), "too many options");
    let mut broken = set(2, 1);
    broken["questions"][1]["options"][0] = json!({"description": "no label"});
    assert!(super::grok::question(&broken).is_none(), "one malformed option");
}

/// Questions and plan approval are held for their turn and answered in
/// Grok's own shapes; a label it did not offer is refused.
#[tokio::test]
async fn questions_and_plan_approvals_are_answered_in_groks_shapes() {
    let (host, session, _cwd) = grok_host().await;
    host.prompt(&session, "ask", &[], None).await.expect("turn");
    let handle = held_request(&host).await;
    let body = bodies(&host)
        .into_iter()
        .find(|b| b["type"] == "permission")
        .expect("request event");
    assert_eq!(body["questions"][0]["question"], "Pick one");
    assert!(matches!(
        host.answer_question(&handle, &json!({"q0": ["Z"]})).await,
        Err(HostError::InvalidInput(_))
    ));
    assert_eq!(host.answer_permission(&handle, "A").await, Err(HostError::InvalidOption));
    host.answer_question(&handle, &json!({"q0": ["B"]}))
        .await
        .expect("answer");
    eventually(
        || agent_said(&host, r#"asked:{"answers":{"Pick one":["B"]},"outcome":"accepted"}"#),
        "the answers",
    )
    .await;
    eventually(|| host.state().sessions[&session].active.is_none(), "the end").await;

    host.prompt(&session, "plan", &[], None)
        .await
        .expect("turn");
    let handle = held_request(&host).await;
    host.answer_permission(&handle, "approved")
        .await
        .expect("approve");
    eventually(|| agent_said(&host, "plan:approved"), "the approval").await;
    host.stop().await;
}

/// Rename goes through Grok, and the context in use follows its update
/// metadata against the model's window.
#[tokio::test]
async fn renames_and_context_usage_come_from_grok() {
    let (host, session, _cwd) = grok_host().await;
    let body = host
        .rename(&session, "  Renamed  ", None)
        .await
        .expect("rename");
    assert_eq!(body["title"], "Renamed");
    let turn = host
        .prompt(&session, "hello", &[], None)
        .await
        .expect("turn");
    eventually(|| super::tests::outcome(&host, &session, &turn).is_some(), "the end").await;
    assert_eq!(host.state().sessions[&session].usage, Some((250, 1000)));
    assert_eq!(host.info()["commands"][0]["name"], "compact");
    host.stop().await;
}

/// Grok's plan and permission modes are offered, the permission mode reaches
/// Grok (and later sessions start in it), its usage window maps to the
/// app's rate limits, and image prompts are accepted.
#[tokio::test]
async fn grok_modes_permissions_usage_window_and_images() {
    let (host, session, cwd) = grok_host().await;
    assert_eq!(host.info()["capabilities"]["image"], true);
    let state = host.state().session_body(&session);
    assert_eq!(state["modes"]["availableModes"][1]["id"], "plan");
    let permission = state["configOptions"]
        .as_array()
        .and_then(|options| {
            options
                .iter()
                .find(|o| o["id"] == "x.ai/permission_mode")
                .cloned()
        })
        .expect("permission option");
    assert_eq!(permission["currentValue"], "ask");

    let body = host
        .set_config_option(&session, "x.ai/permission_mode", "auto", None)
        .await
        .expect("set");
    assert!(body["configOptions"]
        .to_string()
        .contains("\"currentValue\":\"auto\""));
    let turn = host
        .prompt(&session, "perm", &[], None)
        .await
        .expect("turn");
    eventually(|| agent_said(&host, "perm:auto"), "the mode reaching Grok").await;
    eventually(|| outcome_of(&host, &session, &turn).is_some(), "the end").await;
    host.set_mode(&session, "plan", None)
        .await
        .expect("plan mode");

    // A later session starts in it.
    host.set_config_option(&session, "x.ai/permission_mode", "always-approve", None)
        .await
        .expect("set");
    let second = host
        .new_session(&cwd.path().to_string_lossy(), None)
        .await
        .expect("session")["sessionId"]
        .as_str()
        .expect("id")
        .to_string();
    let turn = host.prompt(&second, "perm", &[], None).await.expect("turn");
    eventually(|| agent_said(&host, "perm:always-approve"), "a new session's mode").await;
    eventually(|| outcome_of(&host, &second, &turn).is_some(), "the end").await;

    let limits = host.rate_limits().await.expect("usage window");
    assert_eq!(limits["rateLimits"]["secondary"]["usedPercent"], 12.0);
    assert_eq!(limits["rateLimits"]["secondary"]["windowDurationMins"], 10080);
    assert_eq!(limits["planType"], "SuperGrok Heavy");
    host.stop().await;
}
