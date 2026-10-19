//! The `/acp/v1` gateway and controller recovery: watermarks, stream slots,
//! mid-turn joins, replacement hosts, replay overflow, and stopping during
//! a slow handshake.

use super::*;

#[tokio::test]
async fn the_gateway_resumes_from_the_snapshot_watermark_and_resets_stale_streams() {
    let root = tempfile::tempdir().expect("tempdir");
    let (host, started) = host(root.path(), "beta", &[]).await;
    started.expect("started");
    let (client, server) = serve(&host).await;

    let info = client.info().await.expect("info");
    assert_eq!(info["api"], 1);
    let host_id = info["hostId"].as_str().expect("host id").to_string();
    let session = client
        .new_session(&root.path().to_string_lossy(), None)
        .await
        .expect("new")["sessionId"]
        .as_str()
        .expect("id")
        .to_string();
    let snapshot = client.snapshot().await.expect("snapshot");
    let generation = snapshot["generation"].as_u64().expect("generation");
    let watermark = snapshot["seq"].as_u64().expect("seq");
    let identity = Identity {
        host_id: Some(host_id.clone()),
        generation: Some(generation),
    };
    let mut stream = client
        .events(Some(&host_id), generation, watermark)
        .await
        .expect("events");
    let turn = client
        .prompt(&session, "hello", &[], Some(&identity))
        .await
        .expect("prompt");
    let mut seen = Vec::new();
    while let Some(event) = tokio::time::timeout(WAIT, stream.next())
        .await
        .expect("event in time")
    {
        let event = event.expect("event");
        assert!(event["seq"].as_u64().expect("seq") > watermark, "strictly after the watermark");
        seen.push(event["type"].as_str().unwrap_or("").to_string());
        if event["type"] == "turn_ended" {
            assert_eq!(event["turnId"], turn);
            break;
        }
    }
    assert!(seen.iter().any(|kind| kind == "turn_started"));
    assert!(seen.iter().any(|kind| kind == "update"));

    let mut stale = client
        .events(Some(&host_id), generation + 7, 0)
        .await
        .expect("stream");
    let reset = stale.next().await.expect("reset").expect("event");
    assert_eq!(reset["type"], "reset");
    let mut replaced = client
        .events(Some("another-host"), generation, watermark)
        .await
        .expect("stream");
    let reset = replaced.next().await.expect("reset").expect("event");
    assert_eq!(reset["type"], "reset", "a watermark of another host incarnation is refused");
    let next_generation = Identity {
        generation: Some(generation + 1),
        ..identity.clone()
    };
    match client
        .prompt(&session, "hello", &[], Some(&next_generation))
        .await
    {
        Err(ClientError::Host {
            status,
            code,
            ..
        }) => assert_eq!((status, code.as_str()), (409, "stale_host")),
        other => panic!("unexpected {other:?}"),
    }

    match client.answer("no-such-handle", "x").await {
        Err(ClientError::Host {
            status,
            code,
            ..
        }) => {
            assert_eq!((status, code.as_str()), (404, "unknown_permission"));
        },
        other => panic!("unexpected {other:?}"),
    }
    server.abort();
    host.stop().await;
}

#[tokio::test]
async fn idle_event_streams_release_their_slots_when_dropped() {
    let root = tempfile::tempdir().expect("tempdir");
    let (host, started) = host(root.path(), "alpha", &[]).await;
    started.expect("started");
    let (client, server) = serve(&host).await;
    let info = client.info().await.expect("info");
    let host_id = info["hostId"].as_str().expect("host id").to_string();
    let generation = info["generation"].as_u64().expect("generation");
    // More open/drop cycles than there are slots, while the host stays idle.
    for cycle in 0..(api::MAX_STREAMS * 2) {
        let snapshot = client.snapshot().await.expect("snapshot");
        let seq = snapshot["seq"].as_u64().expect("seq");
        let deadline = tokio::time::Instant::now() + WAIT;
        let stream = loop {
            match client.events(Some(&host_id), generation, seq).await {
                Ok(stream) => break stream,
                Err(ClientError::Host {
                    status: 503, ..
                }) if tokio::time::Instant::now() < deadline => {
                    tokio::time::sleep(Duration::from_millis(25)).await;
                },
                Err(error) => panic!("cycle {cycle}: {error:?}"),
            }
        };
        drop(stream);
    }
    server.abort();
    host.stop().await;
}

/// Read `turn` of `session` from the host as a fold.
fn host_turn(host: &AgentHost, session: &str, turn: &str) -> Turn {
    let history = host.history(session, None, Some(turn), None).expect("turn");
    serde_json::from_value(history["window"][0].clone()).expect("turn")
}

fn assert_same_items(replica: &Turn, host: &Turn) {
    let ids = |turn: &Turn| {
        turn.items
            .iter()
            .map(|item| (item.id.clone(), item.text.clone()))
            .collect::<Vec<_>>()
    };
    assert_eq!(ids(replica), ids(host), "ids and text match the host");
    assert!(replica.items[0].id.ends_with(":u"), "the prompt is part of the fold");
}

/// Recover a controller the way the bridge does: snapshot, then the
/// running turn's fold with its watermark, then the events after it.
async fn follow_turn(
    client: &GatewayClient,
    host_id: &str,
    session: &str,
    turn: &str,
    cancel: bool,
) -> Turn {
    let snapshot = client.snapshot().await.expect("snapshot");
    let generation = snapshot["generation"].as_u64().expect("generation");
    let watermark = snapshot["seq"].as_u64().expect("seq");
    let mut replica = Replica::default();
    assert!(replica.needs_fold(session, Some(turn)));
    let history = client
        .history(session, None, Some(turn), None)
        .await
        .expect("history");
    assert!(replica.install(session, &history));
    let mut stream = client
        .events(Some(host_id), generation, watermark)
        .await
        .expect("events");
    if cancel {
        let identity = Identity {
            host_id: Some(host_id.to_string()),
            generation: Some(generation),
        };
        assert!(client
            .cancel(session, Some(turn), Some(&identity))
            .await
            .expect("cancel"));
    }
    loop {
        let event = tokio::time::timeout(WAIT, stream.next())
            .await
            .expect("event in time")
            .expect("open stream")
            .expect("event");
        assert_ne!(event["type"], "reset", "the recovered watermark is retained");
        replica.apply(&event);
        if event["type"] == "turn_ended" && event["turnId"] == turn {
            break;
        }
    }
    replica.turn(session, turn).expect("fold").clone()
}

#[tokio::test]
async fn a_controller_joining_mid_turn_ends_with_the_hosts_items() {
    let root = tempfile::tempdir().expect("tempdir");
    let (host, started) = host(root.path(), "alpha", &[]).await;
    started.expect("started");
    let (client, server) = serve(&host).await;
    let host_id = client.info().await.expect("info")["hostId"]
        .as_str()
        .expect("host id")
        .to_string();
    let session = new_session(&host, root.path()).await;
    let mut events = Events::from(&host);
    let turn = host
        .prompt(&session, "stream", &[], None)
        .await
        .expect("admitted");
    // Join after several chunks have streamed.
    for _ in 0..5 {
        events
            .until(|b| b["type"] == "update" && b["turnId"] == turn.as_str())
            .await;
    }
    let followed = follow_turn(&client, &host_id, &session, &turn, false).await;
    let host_view = host_turn(&host, &session, &turn);
    assert_same_items(&followed, &host_view);
    assert!(host_view.items.len() >= 3, "message, tool call, message");
    assert!(followed.items[1].text.starts_with("part-0 "), "no missing prefix");
    server.abort();
    host.stop().await;
}

/// A stop issued while the agent is still negotiating (as on app quit right
/// after a start) must not wait for the handshake, must end the process,
/// and must leave a host that never launches again.
#[tokio::test]
async fn stopping_during_a_slow_handshake_cuts_the_launch_short_and_ends_the_agent() {
    let root = tempfile::tempdir().expect("tempdir");
    let pid_file = root.path().join("agent.pid");
    let pid_arg = pid_file.to_string_lossy().into_owned();
    let extra = ["--init-delay-ms", "10000", "--pid-file", pid_arg.as_str()];
    let (spec, program) = spec_of(root.path(), "alpha", &extra);
    let host = AgentHost::create(HostOptions {
        store: store_of(root.path(), "slow-start", &spec, &program),
        spec,
        program,
        path: None,
        env: Vec::new(),
        env_remove: Vec::new(),
    });
    let launching = tokio::spawn({
        let host = host.clone();
        async move { host.launch().await }
    });
    let read_pid = || {
        std::fs::read_to_string(&pid_file)
            .ok()
            .and_then(|pid| pid.trim().parse::<i32>().ok())
    };
    eventually(|| read_pid().is_some(), "the agent to start").await;
    let pid = read_pid().expect("pid");
    assert!(alive(pid));
    let started = tokio::time::Instant::now();
    host.stop().await;
    assert!(
        started.elapsed() < Duration::from_secs(8),
        "a stop does not wait out the 10 s handshake"
    );
    assert!(launching.await.expect("join").is_err(), "the launch was cut short");
    eventually(|| !alive(pid), "the agent process to be gone").await;
    assert_eq!(host.info()["phase"]["state"], "stopped");
    assert!(host.launch().await.is_err(), "a stopped host never launches again");
    assert_eq!(host.restart().await, Err(HostError::NotReady));
}

async fn bind_at(addr: std::net::SocketAddr) -> tokio::net::TcpListener {
    let deadline = tokio::time::Instant::now() + WAIT;
    loop {
        match tokio::net::TcpListener::bind(addr).await {
            Ok(listener) => return listener,
            Err(error) => {
                assert!(tokio::time::Instant::now() < deadline, "rebinding {addr}: {error}");
                tokio::time::sleep(Duration::from_millis(50)).await;
            },
        }
    }
}

fn stale_host(result: Result<impl std::fmt::Debug, ClientError>) {
    match result {
        Err(ClientError::Host {
            status,
            code,
            ..
        }) => assert_eq!((status, code.as_str()), (409, "stale_host")),
        other => panic!("expected a stale-host refusal, got {other:?}"),
    }
}

/// A relay endpoint keeps its address when the host behind it is replaced;
/// the replacement starts at the same generation and its agent hands out the
/// same session ids. Requests carrying the old host's identity must be
/// refused before anything reaches the new agent.
#[tokio::test]
async fn a_replacement_host_behind_the_same_endpoint_refuses_the_old_identity() {
    let root = tempfile::tempdir().expect("tempdir");
    let cwd = root.path().to_string_lossy().into_owned();
    let (first, started) = host_named(root.path(), "first", "alpha", &[]).await;
    started.expect("started");
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let addr = listener.local_addr().expect("addr");
    let origin = format!("http://{addr}/");
    let server = tokio::spawn(api::serve(listener, first.clone()));
    let client = GatewayClient::new(&origin).expect("client");
    let info = client.info().await.expect("info");
    let old = Identity {
        host_id: info["hostId"].as_str().map(str::to_string),
        generation: info["generation"].as_u64(),
    };
    let session = client.new_session(&cwd, Some(&old)).await.expect("new")["sessionId"]
        .as_str()
        .expect("id")
        .to_string();
    server.abort();
    let _ = server.await;
    first.stop().await;

    let (second, started) = host_named(root.path(), "second", "alpha", &[]).await;
    started.expect("started");
    let server = tokio::spawn(api::serve(bind_at(addr).await, second.clone()));
    let reused = new_session(&second, root.path()).await;
    assert_eq!(reused, session, "the new agent reuses the session id");
    assert_eq!(second.info()["generation"].as_u64(), old.generation, "and the generation");
    let client = GatewayClient::new(&origin).expect("client");
    stale_host(client.prompt(&session, "hello", &[], Some(&old)).await);
    stale_host(client.open_session(&session, Some(&old)).await);
    stale_host(client.new_session(&cwd, Some(&old)).await);
    assert_eq!(client.cancel(&session, None, Some(&old)).await, Ok(false));
    assert!(second.snapshot()["sessions"][0]["runningTurnId"].is_null());

    let fresh = Identity {
        host_id: Some(second.host_id().to_string()),
        generation: second.info()["generation"].as_u64(),
    };
    let mut events = Events::from(&second);
    client
        .prompt(&session, "count", &[], Some(&fresh))
        .await
        .expect("current identity");
    events.until(is("turn_ended")).await;
    let history = second.history(&session, None, None, None).expect("history");
    assert_eq!(
        message_texts(&history),
        vec!["prompts:1".to_string()],
        "the stale prompt never reached the new agent"
    );
    server.abort();
    second.stop().await;
}

#[tokio::test]
async fn a_replay_overflow_in_the_same_generation_recovers_the_full_text() {
    let root = tempfile::tempdir().expect("tempdir");
    let (host, started) = host(root.path(), "alpha", &[]).await;
    started.expect("started");
    let (client, server) = serve(&host).await;
    let host_id = client.info().await.expect("info")["hostId"]
        .as_str()
        .expect("host id")
        .to_string();
    let session = new_session(&host, root.path()).await;
    let before = client.snapshot().await.expect("snapshot");
    let generation = before["generation"].as_u64().expect("generation");
    let watermark = before["seq"].as_u64().expect("seq");
    let turn = host
        .prompt(&session, "flood", &[], None)
        .await
        .expect("admitted");
    eventually(
        || {
            host.history(&session, None, Some(&turn), None)
                .ok()
                .and_then(|h| h["window"][0]["items"][1]["text"].as_str().map(str::len))
                .is_some_and(|len| len >= 5000)
        },
        "the flood",
    )
    .await;
    // The old watermark is gone from the log: the stream says so.
    let mut stale = client
        .events(Some(&host_id), generation, watermark)
        .await
        .expect("stream");
    let first = stale.next().await.expect("event").expect("event");
    assert_eq!(first["type"], "reset");
    assert_eq!(host.snapshot()["generation"].as_u64(), Some(generation), "same generation");
    // Recover while the turn still runs, then let it finish.
    let followed = follow_turn(&client, &host_id, &session, &turn, true).await;
    let host_view = host_turn(&host, &session, &turn);
    assert_same_items(&followed, &host_view);
    assert_eq!(followed.items[1].text, format!("{}tail", "x".repeat(5000)));
    server.abort();
    host.stop().await;
}
