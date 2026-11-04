//! A takeover stops a session's owner, so it must not start until the target
//! host can actually open that session.

use std::path::PathBuf;
use std::process::Command;
use std::sync::Arc;

use futures::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::net::TcpListener;
use tokio_tungstenite::accept_async_with_config;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message;

use super::thread_fork_live_tests::{
    start_turn, wait_for_completion, write_config, AppServer, ModelEndpoint,
};
use super::{app_session, runtime, sessions};

const CHILD_HOME: &str = "POCOX_TAKEOVER_TARGET_HOME";
const SESSION: &str = "01000000-0000-7000-8000-00000000abcd";

/// A host that has never heard of the session: it answers `thread/read` with
/// `invalid request` and everything else with an empty result.
fn host_without_the_session() -> (String, tokio::task::JoinHandle<Vec<String>>) {
    runtime::runtime().block_on(async {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let address = listener.local_addr().expect("address").to_string();
        let peer = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.expect("accept");
            let mut socket = accept_async_with_config(stream, Some(WebSocketConfig::default()))
                .await
                .expect("handshake");
            let mut methods = Vec::new();
            while let Some(Ok(frame)) = socket.next().await {
                let Ok(text) = frame.into_text() else {
                    break;
                };
                let Ok(request) = serde_json::from_str::<Value>(&text) else {
                    continue;
                };
                let Some(method) = request["method"].as_str().map(str::to_owned) else {
                    continue;
                };
                let reply = if method == "thread/read" {
                    json!({"id": request["id"], "error": {
                        "code": -32600,
                        "message": "no rollout found for thread",
                    }})
                } else {
                    json!({"id": request["id"], "result": {}})
                };
                methods.push(method);
                if request.get("id").is_some()
                    && socket.send(Message::text(reply.to_string())).await.is_err()
                {
                    break;
                }
            }
            methods
        });
        (address, peer)
    })
}

/// Runs in its own process, because the rollout lookup reads `CODEX_HOME`.
#[test]
fn a_host_without_the_session_is_refused_before_anything_is_released() {
    if std::env::var_os(CHILD_HOME).is_some() {
        let support = tempfile::tempdir().expect("support");
        runtime::init(support.path().to_path_buf()).expect("runtime");
        let (address, peer) = host_without_the_session();
        let key = "pcx:elsewhere:app:default";
        app_session::connect_local(key.into(), &address).expect("connect");
        let refused = sessions::force_resume(key, SESSION);
        app_session::disconnect(key);
        let methods = runtime::runtime().block_on(peer).expect("peer");
        assert!(
            refused.is_err(),
            "a release must not start for a host that cannot open the session"
        );
        assert!(!methods.iter().any(|method| method == "thread/resume"), "{methods:?}");
        return;
    }
    let home = tempfile::tempdir().expect("home");
    let day = home.path().join("sessions/2026/11/02");
    std::fs::create_dir_all(&day).expect("sessions");
    std::fs::write(
        day.join(format!("rollout-2026-11-02T10-00-00-{SESSION}.jsonl")),
        format!(
            "{}\n",
            json!({"type": "session_meta", "payload": {"id": SESSION, "source": "cli"}})
        ),
    )
    .expect("rollout");
    let output = Command::new(std::env::current_exe().expect("test binary"))
        .args([
            "--exact",
            "engine::takeover_target_tests::a_host_without_the_session_is_refused_before_anything_is_released",
            "--nocapture",
        ])
        .env("CODEX_HOME", home.path())
        .env(CHILD_HOME, "1")
        .output()
        .expect("isolated run");
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

/// With real Codex processes: the owner survives a takeover aimed at a host
/// that lacks the session, and is still released for one that has it.
///
/// Set `POCOX_TEST_CODEX_BINARY` to the native binary and run with `--ignored`.
/// This must run alone, because it sets `CODEX_HOME` for the whole process.
#[test]
#[ignore = "requires POCOX_TEST_CODEX_BINARY; starts isolated external app-servers"]
fn a_takeover_stops_the_owner_only_for_a_host_that_has_the_session() {
    let binary = PathBuf::from(
        std::env::var_os("POCOX_TEST_CODEX_BINARY").expect("POCOX_TEST_CODEX_BINARY required"),
    );
    let scratch = tempfile::tempdir().expect("scratch");
    runtime::init(scratch.path().to_path_buf()).expect("runtime");
    let endpoint = Arc::new(ModelEndpoint::default());
    let model = runtime::runtime().block_on(async {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("model port");
        let url = format!("http://{}", listener.local_addr().expect("address"));
        tokio::spawn(Arc::clone(&endpoint).serve(listener));
        url
    });
    let home = scratch.path().join("codex-home");
    let other_home = scratch.path().join("other-device");
    write_config(&home, &model);
    write_config(&other_home, &model);
    std::env::set_var("CODEX_HOME", &home);

    let mut owner = AppServer::start(&binary, &home, scratch.path(), "owner");
    let (owning, mut owner_events) = owner.client();
    let elsewhere = AppServer::start(&binary, &other_home, scratch.path(), "elsewhere");
    let _elsewhere_client = elsewhere.client();
    let here = AppServer::start(&binary, &home, scratch.path(), "here");
    let _here_client = here.client();
    let elsewhere_key = "pcx:elsewhere:app:default";
    let here_key = "pcx:thisdevice:app:default";
    app_session::connect_local(elsewhere_key.into(), &elsewhere.address).expect("connect");
    app_session::connect_local(here_key.into(), &here.address).expect("connect");

    let started = runtime::runtime()
        .block_on(owning.request("thread/start", json!({"cwd": scratch.path()})))
        .expect("thread/start");
    let session = started["thread"]["id"]
        .as_str()
        .expect("thread id")
        .to_owned();
    start_turn(&owning, &session, "owner-turn");
    wait_for_completion(&mut owner_events, &session);

    let refused = sessions::force_resume(elsewhere_key, &session);
    assert!(owner.is_running(), "nothing may be stopped for it: {refused:?}");
    assert!(refused.is_err(), "the other device cannot open this session");

    let taken = sessions::force_resume(here_key, &session).expect("takeover");
    assert!(taken.resumed, "{:?}", taken.resume_error);
    assert!(!taken.killed.is_empty(), "the owner was released");

    app_session::disconnect(elsewhere_key);
    app_session::disconnect(here_key);
}
