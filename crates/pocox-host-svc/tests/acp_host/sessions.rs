//! Sessions: argv, listing, reopening, persisted titles and directories,
//! and invocation-scoped stores.

use super::*;

#[tokio::test]
async fn a_core_only_agent_runs_turns_and_receives_argv_verbatim() {
    let root = tempfile::tempdir().expect("tempdir");
    let literal = ["--literal", "$HOME;*", "two words", ""];
    let (host, started) = host(root.path(), "alpha", &literal).await;
    started.expect("started");
    let info = host.info();
    assert_eq!(info["phase"]["state"], "ready");
    assert_eq!(info["capabilities"]["loadSession"], false);
    assert_eq!(info["capabilities"]["listSessions"], false);
    let mut expected = vec!["--profile".to_string(), "alpha".to_string()];
    expected.extend(literal.iter().map(|s| s.to_string()));
    assert_eq!(info["agent"]["title"], serde_json::to_string(&expected).expect("json"));
    assert_eq!(info["authRequired"], false, "listing auth methods is not auth-required");

    let opened = host
        .new_session(&root.path().to_string_lossy(), None)
        .await
        .expect("session");
    let session = opened["sessionId"].as_str().expect("id").to_string();
    let mut events = Events::from(&host);
    let turn = host
        .prompt(&session, "hello", &[], None)
        .await
        .expect("admitted");
    let ended = events.until(is("turn_ended")).await;
    assert_eq!(ended["turnId"], turn);
    assert_eq!(ended["outcome"], json!({"kind": "stopped", "stopReason": "end_turn"}));
    let history = host.history(&session, None, None, None).expect("history");
    assert_eq!(message_texts(&history), vec!["Hi there".to_string()]);
    assert_eq!(history["session"]["usage"], json!({"used": 10, "size": 100}));
    assert_eq!(
        host.prompt(&session, "", &["data:image/png;base64,AAAA".into()], None)
            .await,
        Err(HostError::Unsupported("this agent does not accept images".into()))
    );
    assert_eq!(host.open_session("never-seen", None).await, Err(HostError::UnknownSession));
    let listed = host.list_sessions(None).await.expect("list");
    assert_eq!(listed["source"], "host");
    assert_eq!(listed["reopen"], "none");
    assert_eq!(listed["sessions"][0]["sessionId"], session);
    assert_eq!(host.session_dir(&session), opened["cwd"].as_str().map(str::to_string));
    host.stop().await;
    assert_eq!(host.info()["phase"]["state"], "stopped");
}

#[tokio::test]
async fn a_second_agent_with_optional_features_lists_loads_and_configures() {
    let root = tempfile::tempdir().expect("tempdir");
    let (host, started) = host(root.path(), "beta", &[]).await;
    started.expect("started");
    let caps = host.info()["capabilities"].clone();
    assert_eq!(caps["loadSession"], true);
    assert_eq!(caps["listSessions"], true);
    assert_eq!(caps["resumeSession"], true);
    assert_eq!(caps["image"], true);

    let listed = host.list_sessions(None).await.expect("list");
    assert_eq!(listed["source"], "agent");
    assert_eq!(listed["reopen"], "load");
    assert_eq!(listed["sessions"][0]["sessionId"], "old-1");
    let opened = host.open_session("old-1", None).await.expect("load");
    assert_eq!(opened["mode"], "load");
    let history = host.history("old-1", None, None, None).expect("history");
    assert_eq!(
        history["turns"].as_array().expect("turns").len(),
        2,
        "replay grouped by user message"
    );
    assert_eq!(message_texts(&history), vec![
        "first answer".to_string(),
        "second answer".to_string()
    ]);
    assert_eq!(history["truncated"], false);
    assert_eq!(
        host.session_dir("old-1"),
        Some(canonical(&std::env::temp_dir())),
        "an imported directory is canonical"
    );

    assert_eq!(opened["configOptions"][0]["currentValue"], "fast-1");
    assert!(matches!(
        host.set_config_option("old-1", "model", "invented", None)
            .await,
        Err(HostError::InvalidInput(_))
    ));
    let configured = host
        .set_config_option("old-1", "model", "large-2", None)
        .await
        .expect("grouped value");
    assert_eq!(configured["configOptions"][0]["currentValue"], "large-2");
    let stale = Identity {
        host_id: Some(host.host_id().to_string()),
        generation: host.snapshot()["generation"].as_u64().map(|g| g + 1),
    };
    assert_eq!(
        host.set_config_option("old-1", "model", "fast-1", Some(&stale))
            .await,
        Err(HostError::Stale),
        "a stale identity is refused before the agent sees it"
    );
    assert_eq!(host.set_mode("old-1", "code", Some(&stale)).await, Err(HostError::Stale));
    let moded = host.set_mode("old-1", "code", None).await.expect("mode");
    assert_eq!(moded["modes"]["currentModeId"], "code");
    assert!(host.set_mode("old-1", "invented", None).await.is_err());
    host.stop().await;
}

/// The agent names the session while its reopen is still pending, before
/// the admission is recorded. The title must be written with the admission,
/// not dropped as an update to an entry that does not exist yet.
#[tokio::test]
async fn a_title_reported_while_a_reopen_is_pending_is_persisted_with_it() {
    let root = tempfile::tempdir().expect("tempdir");
    let (host, started) = host(root.path(), "beta", &[]).await;
    started.expect("started");
    host.list_sessions(None).await.expect("list");
    host.open_session("old-1", None).await.expect("load");
    assert_eq!(host.snapshot()["sessions"][0]["title"], "Loaded title");
    host.stop().await;
    let (spec, program) = spec_of(root.path(), "beta", &[]);
    let entry = store_of(root.path(), "mock", &spec, &program)
        .lookup("old-1")
        .expect("the admission was recorded");
    assert_eq!(entry.title.as_deref(), Some("Loaded title"));
}

/// A stored title, then a reopen during which the agent explicitly clears
/// it (`title: null`) before answering: the clear is persisted with the
/// admission instead of the old title coming back. (That an admission
/// without any title signal keeps the stored title is covered by the
/// store's own test.)
#[tokio::test]
async fn a_title_cleared_while_a_reopen_is_pending_stays_cleared() {
    let root = tempfile::tempdir().expect("tempdir");
    let extra = ["--clear-title"];
    let (spec, program) = spec_of(root.path(), "beta", &extra);
    let dir = canonical(&std::env::temp_dir());
    store_of(root.path(), "mock", &spec, &program).record(
        "old-1",
        &dir,
        Some("Old title".into()),
        None,
    );
    let (host, started) = host(root.path(), "beta", &extra).await;
    started.expect("started");
    host.open_session("old-1", None).await.expect("load");
    assert_eq!(host.snapshot()["sessions"][0]["title"], Value::Null);
    assert!(host.flush_store(WAIT).await);
    host.stop().await;
    let entry = store_of(root.path(), "mock", &spec, &program)
        .lookup("old-1")
        .expect("still recorded");
    assert_eq!(entry.title, None, "the explicit clear is persisted");
}

#[tokio::test]
async fn a_persisted_directory_always_wins_and_a_failed_load_grants_nothing() {
    let root = tempfile::tempdir().expect("tempdir");
    let (a, b) = (root.path().join("a"), root.path().join("b"));
    std::fs::create_dir_all(&a).expect("a");
    std::fs::create_dir_all(&b).expect("b");
    let b_arg = b.to_string_lossy().into_owned();
    let extra = ["--list-cwd", b_arg.as_str(), "--open-delay-ms", "600", "--fail-open"];
    // This source admitted `old-1` under A before.
    let (spec, program) = spec_of(root.path(), "beta", &extra);
    store_of(root.path(), "mock", &spec, &program).record("old-1", &canonical(&a), None, None);

    let (host, started) = host(root.path(), "beta", &extra).await;
    started.expect("started");
    // The agent now lists `old-1` under B.
    host.list_sessions(None).await.expect("list");
    let opening = tokio::spawn({
        let host = host.clone();
        async move { host.open_session("old-1", None).await }
    });
    eventually(|| host.snapshot()["sessions"][0]["pending"] == true, "the pending load").await;
    assert_eq!(host.session_dir("old-1"), Some(canonical(&a)), "never B, even while pending");
    assert_eq!(host.open_session("old-1", None).await, Err(HostError::Loading));
    assert_eq!(host.prompt("old-1", "hello", &[], None).await, Err(HostError::Loading));
    assert!(opening.await.expect("join").is_err(), "the load fails");
    assert_eq!(host.session_dir("old-1"), Some(canonical(&a)), "and B is still not granted");
    assert!(host.snapshot()["sessions"]
        .as_array()
        .expect("sessions")
        .is_empty());
    host.stop().await;
}

#[tokio::test]
async fn a_pending_resume_admits_nothing_until_it_succeeds() {
    let root = tempfile::tempdir().expect("tempdir");
    let b = root.path().join("b");
    std::fs::create_dir_all(&b).expect("b");
    let b_arg = b.to_string_lossy().into_owned();

    // A failing resume: no authority before, during or after.
    let failing = ["--list-cwd", b_arg.as_str(), "--open-delay-ms", "400", "--fail-open"];
    let (host, started) = host_named(root.path(), "failing", "gamma", &failing).await;
    started.expect("started");
    assert_eq!(host.info()["capabilities"]["loadSession"], false);
    host.list_sessions(None).await.expect("list");
    let opening = tokio::spawn({
        let host = host.clone();
        async move { host.open_session("old-1", None).await }
    });
    eventually(|| host.snapshot()["sessions"][0]["pending"] == true, "the pending resume").await;
    assert_eq!(host.session_dir("old-1"), None);
    assert!(opening.await.expect("join").is_err());
    assert_eq!(host.session_dir("old-1"), None, "a failed resume is revoked");
    host.stop().await;

    // A slow resume: blocked while pending, usable once confirmed.
    let slow = ["--list-cwd", b_arg.as_str(), "--open-delay-ms", "600"];
    let (host, started) = host_named(root.path(), "slow", "gamma", &slow).await;
    started.expect("started");
    host.list_sessions(None).await.expect("list");
    let opening = tokio::spawn({
        let host = host.clone();
        async move { host.open_session("old-1", None).await }
    });
    eventually(|| host.snapshot()["sessions"][0]["pending"] == true, "the pending resume").await;
    assert_eq!(host.session_dir("old-1"), None, "no authority while pending");
    assert_eq!(host.open_session("old-1", None).await, Err(HostError::Loading));
    assert_eq!(
        host.prompt("old-1", "hello", &[], None).await,
        Err(HostError::Loading),
        "another controller cannot prompt it yet"
    );
    let opened = opening.await.expect("join").expect("resumed");
    assert_eq!(opened["mode"], "resume");
    assert_eq!(host.session_dir("old-1"), Some(canonical(&b)));
    let history = host.history("old-1", None, None, None).expect("history");
    assert_eq!(history["truncated"], true, "resume does not claim complete history");
    let mut events = Events::from(&host);
    host.prompt("old-1", "hello", &[], None)
        .await
        .expect("usable now");
    events.until(is("turn_ended")).await;
    host.stop().await;
}

#[tokio::test]
async fn reusing_a_name_with_another_invocation_transfers_no_sessions_or_authority() {
    let root = tempfile::tempdir().expect("tempdir");
    let work = root.path().join("work");
    std::fs::create_dir_all(&work).expect("work");
    let (first, started) = host(root.path(), "alpha", &["--model", "one"]).await;
    started.expect("started");
    let session = new_session(&first, &work).await;
    first.stop().await;

    // Same host name and profile id, different arguments.
    let (other, started) = host(root.path(), "alpha", &["--model", "two"]).await;
    started.expect("started");
    assert_eq!(other.session_dir(&session), None, "no file authority");
    let listed = other.list_sessions(None).await.expect("list");
    assert!(
        listed["sessions"]
            .as_array()
            .expect("sessions")
            .iter()
            .all(|s| s["sessionId"] != session.as_str()),
        "no sessions"
    );
    other.stop().await;

    // The original invocation still has them.
    let (again, started) = host(root.path(), "alpha", &["--model", "one"]).await;
    started.expect("started");
    assert_eq!(again.session_dir(&session), Some(canonical(&work)));
    again.stop().await;
}
