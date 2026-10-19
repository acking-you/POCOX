//! Opt-in acceptance of the Grok preset against an installed Grok Build:
//!
//! ```sh
//! PCX_TEST_GROK=~/.grok/bin/grok cargo test -p pocket-codex-host-svc \
//!   --test grok_live -- --ignored --nocapture
//! ```
//!
//! The host runs the real `grok agent --no-leader stdio` with a custom
//! provider in a throwaway Grok home, aimed at a deterministic loopback
//! Chat Completions endpoint in this test (no account, no network). It
//! covers a real turn, the native reader over what Grok stored, handing the
//! session back and reopening it (Grok's agent is its own, unregistered
//! writer), and renaming and deleting it through Grok itself.
#![cfg(unix)]

use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};

use pocket_codex_core::provider::{ApiProtocol, ProviderEndpoint, Secret};
use pocket_codex_host_svc::{
    acp::{
        grok, grok_control::GrokControl, spec, AgentHost, HostOptions, Identity, SessionStore,
        SourceId,
    },
    native_history::{GrokHistory, NativeHistory},
};
use serde_json::{json, Value};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};

const KEY: &str = "sk-pocox-live-test";
const REPLY: &str = "pong from the loopback model";
const WAIT: Duration = Duration::from_secs(60);

/// A loopback model: `GET /v1/models` and streamed `POST
/// /v1/chat/completions`. Records each request line with whether it
/// carried this test's key.
async fn model() -> (u16, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = seen.clone();
    tokio::spawn(async move {
        loop {
            let Ok((mut socket, _)) = listener.accept().await else { return };
            let log = log.clone();
            tokio::spawn(async move {
                let mut buffer = Vec::new();
                let mut chunk = [0u8; 8192];
                let head_end = loop {
                    let n = socket.read(&mut chunk).await.unwrap_or(0);
                    if n == 0 {
                        return;
                    }
                    buffer.extend_from_slice(&chunk[..n]);
                    if let Some(i) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
                        break i + 4;
                    }
                };
                let head = String::from_utf8_lossy(&buffer[..head_end]).to_string();
                let length = head
                    .lines()
                    .find_map(|l| {
                        l.to_ascii_lowercase()
                            .strip_prefix("content-length:")
                            .map(|v| v.trim().to_string())
                    })
                    .and_then(|v| v.parse::<usize>().ok())
                    .unwrap_or(0);
                while buffer.len() < head_end + length {
                    let n = socket.read(&mut chunk).await.unwrap_or(0);
                    if n == 0 {
                        break;
                    }
                    buffer.extend_from_slice(&chunk[..n]);
                }
                let line = head.lines().next().unwrap_or_default().to_string();
                let keyed = head.to_ascii_lowercase().contains(&format!("bearer {KEY}"));
                log.lock()
                    .expect("log")
                    .push(format!("{line} keyed={keyed}"));
                let response = if line.starts_with("GET") && line.contains("/models") {
                    let body = json!({"object":"list","data":[
                        {"id":"fake-1","object":"model"},{"id":"fake-2","object":"model"}]})
                    .to_string();
                    format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: \
                         {}\r\nconnection: close\r\n\r\n{body}",
                        body.len()
                    )
                } else if line.contains("/chat/completions") {
                    let chunk = |delta: Value, finish: Value| {
                        format!(
                            "data: {}\n\n",
                            json!({"id":"c1","object":"chat.completion.chunk","created":1,
                                "model":"fake-1","choices":[{"index":0,"delta":delta,
                                "finish_reason":finish}]})
                        )
                    };
                    let usage = format!(
                        "data: {}\n\n",
                        json!({"id":"c1","object":"chat.completion.chunk","created":1,
                            "model":"fake-1","choices":[],"usage":{"prompt_tokens":1,
                            "completion_tokens":1,"total_tokens":2}})
                    );
                    let body = [
                        chunk(json!({"role":"assistant","content":""}), Value::Null),
                        chunk(json!({"content": REPLY}), Value::Null),
                        chunk(json!({}), json!("stop")),
                        usage,
                        "data: [DONE]\n\n".to_string(),
                    ]
                    .concat();
                    format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: \
                         {}\r\nconnection: close\r\n\r\n{body}",
                        body.len()
                    )
                } else {
                    "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
                        .into()
                };
                let _ = socket.write_all(response.as_bytes()).await;
                let _ = socket.shutdown().await;
            });
        }
    });
    (port, seen)
}

fn identity(host: &AgentHost) -> Identity {
    Identity {
        host_id: Some(host.host_id().to_string()),
        generation: host.snapshot()["generation"].as_u64(),
    }
}

fn texts(history: &Value) -> Vec<String> {
    history["window"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|turn| turn["items"].as_array().cloned().unwrap_or_default())
        .map(|item| item["text"].as_str().unwrap_or_default().to_string())
        .collect()
}

async fn until(what: &str, mut check: impl AsyncFnMut() -> bool) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while !check().await {
        assert!(tokio::time::Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs an installed Grok Build: set PCX_TEST_GROK"]
async fn grok_preset_hosts_reads_and_manages_real_sessions() {
    let program = PathBuf::from(std::env::var_os("PCX_TEST_GROK").expect("PCX_TEST_GROK"));
    let home = tempfile::TempDir::new().expect("home");
    let project = tempfile::TempDir::new().expect("project");
    let (port, seen) = model().await;
    let endpoint = ProviderEndpoint {
        protocol: ApiProtocol::ChatCompletions,
        base_url: format!("http://127.0.0.1:{port}/v1"),
        key: Some(Secret::new(KEY)),
        model: Some("fake-1".into()),
    };
    let grok_home = home.path().join("grok-home");
    let launch =
        grok::provider_launch(&grok_home, &endpoint, &[("fake-2".into(), "Fake Two".into())])
            .expect("provider home");
    let config = std::fs::read_to_string(grok_home.join("config.toml")).expect("config");
    assert!(!config.contains(KEY), "the key stays out of the file");

    let spec = spec::preset(grok::PROFILE_ID).expect("preset").spec();
    let reader = GrokHistory::new(grok_home.clone())
        .expect("reader")
        .with_owner_probe();
    let host = AgentHost::create_with_native_history(
        HostOptions {
            store: SessionStore::memory(SourceId::with_key(&"g".repeat(32), &program, &spec.args)),
            spec,
            program: program.clone(),
            path: None,
            env: launch.env.clone(),
            env_remove: launch.env_remove.clone(),
        },
        None,
        None,
        Some(NativeHistory::Grok(Arc::new(reader))),
    );
    host.launch().await.expect("grok launched");
    let info = host.info();
    println!("negotiated: {}", info["capabilities"]);
    let caps = &info["capabilities"];
    for feature in ["loadSession", "closeSession", "listSessions", "resumeSession"] {
        assert_eq!(caps[feature], true, "Grok negotiates {feature}");
    }

    // A real turn through the custom provider.
    let cwd = project.path().canonicalize().expect("cwd");
    let session = host
        .new_session(&cwd.to_string_lossy(), None)
        .await
        .expect("session")["sessionId"]
        .as_str()
        .expect("id")
        .to_string();
    let access = host
        .session_access(&session, &identity(&host))
        .await
        .expect("access");
    assert_eq!((access.mode.as_str(), access.reason.as_str()), ("write", "owned"), "{access:?}");
    let turn = host
        .prompt(&session, "ping", &[], None)
        .await
        .expect("prompt");
    until("the reply", async || {
        texts(&host.history(&session, None, None, None).expect("history"))
            .iter()
            .any(|t| t == REPLY)
    })
    .await;
    println!("turn {turn} answered");
    let calls = seen.lock().expect("log").clone();
    assert!(
        calls
            .iter()
            .any(|c| c.contains("/chat/completions") && c.ends_with("keyed=true")),
        "the provider got the key from the child environment: {calls:?}"
    );

    // What Grok stored reads back through the native reader.
    let fresh = GrokHistory::new(grok_home.clone()).expect("reader");
    until("the stored turn", async || {
        fresh.read_page(&session, None, 10).await.is_ok_and(|page| {
            page.turns
                .iter()
                .flat_map(|t| &t.items)
                .any(|i| i.text == REPLY)
        })
    })
    .await;
    let listed = fresh.list_sessions(None, 10).await.expect("list");
    assert_eq!(listed["sessions"][0]["sessionId"], session.as_str());
    let page = fresh.read_page(&session, None, 10).await.expect("page");
    let items: Vec<&str> = page
        .turns
        .iter()
        .flat_map(|t| &t.items)
        .map(|i| i.text.as_str())
        .collect();
    assert_eq!(items, ["ping", REPLY]);
    assert_eq!(page.total_turns, Some(1));

    // Handed back, then reopened: Grok's agent is the session's only writer.
    let released = host.session_release(&access).await.expect("release");
    assert_eq!(released.reason, "released_here");
    let reopened = host
        .session_open(&session, &identity(&host))
        .await
        .expect("reopen");
    assert_eq!((reopened.mode.as_str(), reopened.writer.as_str()), ("write", "this_host"));
    host.stop().await;

    // Renamed and deleted through Grok itself, in the same home.
    let control = GrokControl::start(&program, None, &launch.env, &launch.env_remove)
        .await
        .expect("control");
    let account = control.account().await.expect("account");
    println!("account: {account:?}");
    let renamed = control
        .call(
            "_x.ai/session/rename",
            json!({"sessionId": session, "title": "Renamed by POCOX"}),
            Some(Duration::from_secs(15)),
        )
        .await
        .expect("rename");
    assert_eq!(renamed["success"], true);
    let listed = fresh.list_sessions(None, 10).await.expect("list");
    assert_eq!(listed["sessions"][0]["title"], "Renamed by POCOX");
    let deleted = control
        .call("_x.ai/session/delete", json!({"sessionId": session}), Some(Duration::from_secs(15)))
        .await
        .expect("delete");
    assert_eq!(deleted["success"], true);
    control.stop().await;
    let listed = fresh.list_sessions(None, 10).await.expect("list");
    assert!(listed["sessions"].as_array().is_some_and(Vec::is_empty), "{listed}");
}
