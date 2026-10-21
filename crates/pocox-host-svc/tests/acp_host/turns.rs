//! Turns: permissions, cancellation and dispatch order, refused agent
//! requests, crashes and leader exits, versions and authentication.

use super::*;

#[tokio::test]
async fn permissions_keep_opaque_ids_reject_invalid_choices_and_resolve_once() {
    let root = tempfile::tempdir().expect("tempdir");
    let (host, started) = host(root.path(), "alpha", &[]).await;
    started.expect("started");
    let session = new_session(&host, root.path()).await;
    let mut events = Events::from(&host);
    host.prompt(&session, "permission", &[], None)
        .await
        .expect("admitted");
    let asked = events.until(is("permission")).await;
    let handle = asked["handle"].as_str().expect("handle").to_string();
    assert_eq!(asked["options"][0]["optionId"], "opt:allow ✓");
    assert_eq!(
        host.answer_permission(&handle, "opt:invented").await,
        Err(HostError::InvalidOption)
    );
    assert_eq!(
        host.snapshot()["permissions"][0]["handle"],
        handle,
        "invalid answer keeps it pending"
    );
    let (a, b) = tokio::join!(
        host.answer_permission(&handle, "opt:allow ✓"),
        host.answer_permission(&handle, "opt:deny")
    );
    assert!(a.is_ok() ^ b.is_ok(), "exactly one answer wins: {a:?} {b:?}");
    let winner = if a.is_ok() { "opt:allow ✓" } else { "opt:deny" };
    assert_eq!(host.answer_permission(&handle, winner).await, Err(HostError::AlreadyResolved));
    events.until(is("turn_ended")).await;
    let history = host.history(&session, None, None, None).expect("history");
    assert!(message_texts(&history).contains(&format!("selected:{winner}")));
    host.stop().await;
}

#[tokio::test]
async fn cancellation_answers_permissions_and_waits_for_the_real_stop_reason() {
    let root = tempfile::tempdir().expect("tempdir");
    let (host, started) = host(root.path(), "alpha", &[]).await;
    started.expect("started");
    let session = new_session(&host, root.path()).await;
    let mut events = Events::from(&host);
    host.prompt(&session, "permission", &[], None)
        .await
        .expect("admitted");
    let asked = events.until(is("permission")).await;
    assert!(host.cancel(&session, None, None).await.expect("cancel"));
    let resolved = events.until(is("permission_resolved")).await;
    assert_eq!(resolved["handle"], asked["handle"]);
    assert_eq!(resolved["outcome"], "cancelled");
    let ended = events.until(is("turn_ended")).await;
    assert_eq!(ended["outcome"]["stopReason"], "cancelled");
    let history = host.history(&session, None, None, None).expect("history");
    assert!(message_texts(&history).contains(&"cancelled".to_string()), "agent saw cancelled");

    // A slow turn stays busy after cancel until the agent answers, and the
    // trailing update sent after cancel is still folded.
    let turn = host
        .prompt(&session, "slow", &[], None)
        .await
        .expect("admitted");
    events
        .until(|b| b["type"] == "update" && b["turnId"] == turn)
        .await;
    assert_eq!(host.prompt(&session, "again", &[], None).await, Err(HostError::Busy));
    host.cancel(&session, Some(&turn), None)
        .await
        .expect("cancel");
    assert_eq!(
        host.prompt(&session, "again", &[], None).await,
        Err(HostError::Busy),
        "admission stays locked until the agent answers the cancelled prompt"
    );
    let ended = events.until(is("turn_ended")).await;
    assert_eq!(ended["turnId"], turn);
    assert_eq!(ended["outcome"]["stopReason"], "cancelled");
    let history = host
        .history(&session, None, Some(&turn), None)
        .expect("turn");
    let items = history["window"][0]["items"]
        .as_array()
        .expect("items")
        .clone();
    assert!(items.iter().any(|i| i["title"] == "Trailing update"));
    host.stop().await;
}

/// `#[tokio::test]` runs on one thread, so nothing else runs between two
/// awaits that complete without yielding: the prompt task cannot dispatch
/// between admission and the cancel below.
#[tokio::test]
async fn cancel_and_dispatch_are_ordered_per_turn() {
    let root = tempfile::tempdir().expect("tempdir");
    let (host, started) = host(root.path(), "alpha", &[]).await;
    started.expect("started");
    let session = new_session(&host, root.path()).await;
    let mut events = Events::from(&host);

    // Cancelled right after admission: the agent never receives it.
    let early = host
        .prompt(&session, "slow", &[], None)
        .await
        .expect("admitted");
    assert!(host
        .cancel(&session, Some(&early), None)
        .await
        .expect("cancel"));
    let ended = events.until(is("turn_ended")).await;
    assert_eq!(ended["turnId"], early);
    assert_eq!(ended["outcome"], json!({"kind": "cancelled"}));
    host.prompt(&session, "count", &[], None)
        .await
        .expect("admitted");
    events.until(is("turn_ended")).await;
    let history = host.history(&session, None, None, None).expect("history");
    assert_eq!(
        message_texts(&history),
        vec!["prompts:1".to_string()],
        "the cancelled prompt never reached the agent"
    );

    // Cancelled after dispatch: the cancel follows the prompt and the agent
    // reports its own stop reason.
    let sent = host
        .prompt(&session, "slow", &[], None)
        .await
        .expect("admitted");
    eventually(
        || host.snapshot()["sessions"][0]["turnDispatched"] == true,
        "the prompt to be dispatched",
    )
    .await;
    assert!(host
        .cancel(&session, Some(&sent), None)
        .await
        .expect("cancel"));
    let ended = events.until(is("turn_ended")).await;
    assert_eq!(ended["turnId"], sent);
    assert_eq!(ended["outcome"], json!({"kind": "stopped", "stopReason": "cancelled"}));

    // A late cancel of an earlier turn leaves the next one running.
    let first = host
        .prompt(&session, "hello", &[], None)
        .await
        .expect("admitted");
    events.until(is("turn_ended")).await;
    let second = host
        .prompt(&session, "slow", &[], None)
        .await
        .expect("admitted");
    let current = Identity {
        host_id: Some(host.host_id().to_string()),
        generation: host.snapshot()["generation"].as_u64(),
    };
    assert!(!host
        .cancel(&session, Some(&first), Some(&current))
        .await
        .expect("stale cancel"));
    let other_generation = Identity {
        generation: current.generation.map(|g| g + 1),
        ..current.clone()
    };
    assert!(
        !host
            .cancel(&session, Some(&second), Some(&other_generation))
            .await
            .expect("other generation"),
        "a cancel for another generation does nothing"
    );
    let other_host = Identity {
        host_id: Some("another-host".into()),
        ..current.clone()
    };
    assert!(
        !host
            .cancel(&session, Some(&second), Some(&other_host))
            .await
            .expect("other host"),
        "a cancel for another host incarnation does nothing"
    );
    let snapshot = host.snapshot();
    assert_eq!(snapshot["sessions"][0]["runningTurnId"], second);
    assert_eq!(snapshot["sessions"][0]["cancelRequested"], false);
    assert!(host
        .cancel(&session, Some(&second), Some(&current))
        .await
        .expect("cancel"));
    let ended = events.until(is("turn_ended")).await;
    assert_eq!(ended["turnId"], second);
    assert_eq!(outcomes_of(&host, &second).len(), 1);
    host.stop().await;
}

#[tokio::test]
async fn agent_file_requests_are_refused_without_reading() {
    let root = tempfile::tempdir().expect("tempdir");
    let (host, started) = host(root.path(), "alpha", &[]).await;
    started.expect("started");
    let session = new_session(&host, root.path()).await;
    let mut events = Events::from(&host);
    host.prompt(&session, "fs", &[], None)
        .await
        .expect("admitted");
    events.until(is("turn_ended")).await;
    let history = host.history(&session, None, None, None).expect("history");
    assert_eq!(message_texts(&history), vec!["fs:-32601".to_string()]);
    host.stop().await;
}

#[tokio::test]
async fn a_crash_ends_turns_as_exited_and_the_next_generation_is_isolated() {
    let root = tempfile::tempdir().expect("tempdir");
    let (host, started) = host(root.path(), "alpha", &[]).await;
    started.expect("started");
    let session = new_session(&host, root.path()).await;
    let before = host.snapshot()["generation"].as_u64().expect("generation");
    let mut events = Events::from(&host);
    let turn = host
        .prompt(&session, "crash", &[], None)
        .await
        .expect("admitted");
    let ended = events.until(is("turn_ended")).await;
    assert_eq!(ended["turnId"], turn);
    assert_eq!(ended["outcome"]["kind"], "agentExited", "never reported as success");
    let snapshot = host.snapshot();
    assert!(snapshot["generation"].as_u64().expect("generation") > before);
    assert_eq!(snapshot["recentTurns"][0]["outcome"]["kind"], "agentExited");
    assert!(host.subscribe(before, 0).is_none(), "stale generation must resync");
    // The bounded restart brings up a fresh generation without the old session.
    eventually(|| host.info()["phase"]["state"] == "ready", "the restart").await;
    assert_eq!(host.prompt(&session, "hello", &[], None).await, Err(HostError::UnknownSession));
    host.stop().await;
}

#[tokio::test]
async fn a_leader_exit_is_detected_while_a_descendant_holds_the_output_open() {
    let root = tempfile::tempdir().expect("tempdir");
    let (host, started) = host(root.path(), "alpha", &[]).await;
    started.expect("started");
    let session = new_session(&host, root.path()).await;
    let before = host.snapshot()["generation"].as_u64().expect("generation");
    let mut events = Events::from(&host);
    let turn = host
        .prompt(&session, "orphan", &[], None)
        .await
        .expect("admitted");
    let reported = events
        .until(|b| b["type"] == "update" && b["turnId"] == turn.as_str())
        .await;
    let descendant: i32 = reported["update"]["content"]["text"]
        .as_str()
        .and_then(|text| text.strip_prefix("orphan:"))
        .and_then(|pid| pid.parse().ok())
        .expect("descendant pid");
    assert!(descendant > 0);
    let ended = events.until(is("turn_ended")).await;
    assert_eq!(ended["turnId"], turn);
    assert_eq!(ended["outcome"]["kind"], "agentExited");
    assert_eq!(outcomes_of(&host, &turn).len(), 1, "exactly one outcome");
    assert!(host.snapshot()["generation"].as_u64().expect("generation") > before);
    eventually(|| !alive(descendant), "the descendant to be cleaned up").await;
    eventually(|| host.info()["phase"]["state"] == "ready", "the bounded restart").await;
    host.stop().await;
}

#[tokio::test]
async fn unsupported_versions_and_auth_required_are_reported_honestly() {
    let root = tempfile::tempdir().expect("tempdir");
    let (old, started) = host(root.path(), "alpha", &["--version", "2"]).await;
    match started {
        Err(HostError::Start(reason)) => assert!(reason.contains("version 2"), "{reason}"),
        other => panic!("unexpected {other:?}"),
    }
    assert_eq!(old.info()["phase"]["state"], "failed");
    old.stop().await;

    let root = tempfile::tempdir().expect("tempdir");
    let (host, started) = host(root.path(), "alpha", &["--auth-required"]).await;
    started.expect("started");
    assert_eq!(
        host.new_session(&root.path().to_string_lossy(), None).await,
        Err(HostError::AuthRequired)
    );
    assert_eq!(host.info()["authRequired"], true);
    assert!(matches!(
        host.new_session("relative/dir", None).await,
        Err(HostError::InvalidInput(_))
    ));
    host.stop().await;
}

#[tokio::test]
async fn authentication_required_by_a_prompt_is_reported_with_one_outcome() {
    let root = tempfile::tempdir().expect("tempdir");
    let (host, started) = host(root.path(), "alpha", &["--auth-prompt"]).await;
    started.expect("started");
    let session = new_session(&host, root.path()).await;
    assert_eq!(host.info()["authRequired"], false);
    let mut events = Events::from(&host);
    let turn = host
        .prompt(&session, "hello", &[], None)
        .await
        .expect("admitted");
    // The sign-in state is published first, then the turn's one outcome.
    let state = events.until(is("host_state")).await;
    assert_eq!(state["authRequired"], true);
    let ended = events.until(is("turn_ended")).await;
    assert_eq!(ended["turnId"], turn);
    assert_eq!(ended["outcome"]["kind"], "failed");
    assert_eq!(host.info()["authRequired"], true);
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(outcomes_of(&host, &turn).len(), 1, "exactly one outcome");
    host.stop().await;
}
