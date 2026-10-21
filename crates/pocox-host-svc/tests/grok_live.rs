//! Opt-in acceptance of the Grok preset against an installed Grok Build:
//!
//! ```sh
//! POCOX_TEST_GROK=~/.grok/bin/grok cargo test -p pocox-host-svc \
//!   --test grok_live -- --ignored --nocapture
//! ```
//!
//! The host runs the real `grok agent --no-leader stdio` with a custom
//! provider in a throwaway Grok home, aimed at a deterministic loopback
//! Chat Completions endpoint in this test (no account, no network). It
//! covers a real turn, the model chip on a Grok that sends ACP
//! `configOptions`, Grok's own extensions (a supplement merged into a
//! running turn, rename, context usage, `/compact` listed), the native
//! reader over what Grok stored, handing the session back and reopening it
//! (Grok's agent is its own, unregistered writer), and renaming and deleting
//! it through Grok itself. A second test follows, read-only and live, a
//! session that Grok's own stdio client runs through a leader it started.
#![cfg(unix)]

use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};

use pocox_core::provider::{ApiProtocol, ProviderEndpoint, Secret};
use pocox_host_svc::{
    acp::{
        grok, grok_control::GrokControl, schema::SteerOutcome, spec, AgentHost, HostOptions,
        Identity, SessionStore, SourceId,
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
/// A prompt the loopback model answers slowly (about three seconds), so a
/// supplement can arrive while it runs.
const SLOW: &str = "please wait";
/// The supplement's text; the log notes every request that carries it.
const STEER: &str = "STEER-42";
/// A 32×32 PNG (Grok drops images under 8×8 or 512 pixels).
const IMAGE: &str = "data:image/png;base64,\
                     iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAAKUlEQVR42u3NsQkAAAgDsB7W//\
                     Esr3AQAtmTaU9FIBAIBAKBQCAQfAkWAwwATPGfc7wAAAAASUVORK5CYII=";
const WAIT: Duration = Duration::from_secs(60);

/// A loopback model: `GET /v1/models` and streamed `POST
/// /v1/chat/completions`. Records each request line with whether it
/// carried this test's key and the model its body named.
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
                let body: Value = serde_json::from_slice(&buffer[head_end..]).unwrap_or_default();
                let model = body["model"].as_str().unwrap_or("-");
                let text = body["messages"].to_string();
                let steered = text.contains(STEER);
                let image = text.contains("data:image/png;base64,");
                // Only the turn's first request is slow: the one after an
                // interjection answers at once.
                let slow = text.contains(SLOW) && !steered;
                log.lock().expect("log").push(format!(
                    "{line} keyed={keyed} steer={steered} image={image} model={model}"
                ));
                if slow && line.contains("/chat/completions") {
                    let head = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: \
                                close\r\n\r\n";
                    let _ = socket.write_all(head.as_bytes()).await;
                    for word in ["slow ", "but ", "steady"] {
                        let chunk = json!({"id":"c2","object":"chat.completion.chunk","created":1,
                            "model":"fake-1","choices":[{"index":0,
                            "delta":{"role":"assistant","content":word},"finish_reason":null}]});
                        let _ = socket
                            .write_all(format!("data: {chunk}\n\n").as_bytes())
                            .await;
                        tokio::time::sleep(Duration::from_secs(1)).await;
                    }
                    let end = json!({"id":"c2","object":"chat.completion.chunk","created":1,
                        "model":"fake-1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]});
                    let _ = socket
                        .write_all(format!("data: {end}\n\ndata: [DONE]\n\n").as_bytes())
                        .await;
                    let _ = socket.shutdown().await;
                    return;
                }
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

/// This Grok's version, and whether it sends ACP `configOptions` (the
/// model and effort chips). The reference source (`deps/grok-build`, 1.0.45)
/// does (`xai-grok-shell/src/agent/session_config.rs`); 1.0.4 sends only the
/// unstable `models` state, which POCOX does not use. Grok's `initialize`
/// carries no `agentInfo`, so the version is `grok --version`'s
/// (`grok 1.0.62 (<commit>)`).
fn config_options_expected(program: &Path, home: &Path) -> (String, bool) {
    let output = std::process::Command::new(program)
        .arg("--version")
        .env("GROK_HOME", home)
        .env("GROK_DISABLE_AUTOUPDATER", "1")
        .output()
        .expect("grok --version");
    let text = String::from_utf8_lossy(&output.stdout);
    let version = text
        .split_whitespace()
        .nth(1)
        .unwrap_or_default()
        .to_string();
    let parts: Vec<u64> = version
        .split(['.', '-', '+'])
        .take(3)
        .map_while(|part| part.parse().ok())
        .collect();
    let expected = parts.len() == 3 && (parts[0], parts[1], parts[2]) >= (1, 0, 45);
    (version, expected)
}

async fn until(what: &str, mut check: impl AsyncFnMut() -> bool) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while !check().await {
        assert!(tokio::time::Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs an installed Grok Build: set POCOX_TEST_GROK"]
async fn grok_preset_hosts_reads_and_manages_real_sessions() {
    let program = PathBuf::from(std::env::var_os("POCOX_TEST_GROK").expect("POCOX_TEST_GROK"));
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
    let opened = host
        .new_session(&cwd.to_string_lossy(), None)
        .await
        .expect("session");
    let session = opened["sessionId"].as_str().expect("id").to_string();
    let (version, native) = config_options_expected(&program, &grok_home);
    let chips = native;
    println!("grok {version} configOptions: {}", opened["configOptions"]);
    if chips {
        let options = opened["configOptions"].as_array().expect("configOptions");
        let model = options
            .iter()
            .find(|option| option["id"] == "model")
            .expect("a model option");
        assert_eq!(model["category"], "model");
        assert_eq!(model["currentValue"], "fake-1", "the provider's default model");
        let values: Vec<&str> = model["options"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|value| value["value"].as_str())
            .collect();
        assert_eq!(values, ["fake-1", "fake-2"], "only the provider's models");
        if let Some(effort) = options
            .iter()
            .find(|option| option["id"] == "reasoning_effort")
        {
            assert_eq!(effort["category"], "thought_level");
        }
    }
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
        calls.iter().any(|c| c.contains("/chat/completions")
            && c.contains("keyed=true")
            && c.ends_with("model=fake-1")),
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

    // Grok's own extensions: a supplement reaches the running turn (Grok
    // asks the model again with it), rename goes through Grok, and the
    // context in use is reported.
    if native {
        assert_eq!(caps["grok"], true, "Grok's extensions negotiated");
        until("the first turn's end", async || {
            host.session_access(&session, &identity(&host))
                .await
                .is_ok_and(|access| access.can_release)
        })
        .await;
        let slow = host
            .prompt(&session, SLOW, &[], None)
            .await
            .expect("slow prompt");
        // `promptRequired` until Grok reports this turn running; nothing is
        // sent meanwhile.
        until("the supplement taken", async || {
            matches!(
                host.steer(&session, Some(&slow), STEER, &[], None).await,
                Ok((SteerOutcome::Injected, Some(ref turn))) if *turn == slow
            )
        })
        .await;
        until("a model request carrying the supplement", async || {
            seen.lock()
                .expect("log")
                .iter()
                .any(|c| c.contains("/chat/completions") && c.contains("steer=true"))
        })
        .await;
        until("the slow turn's end", async || {
            host.session_access(&session, &identity(&host))
                .await
                .is_ok_and(|access| access.can_release)
        })
        .await;
        let state = host
            .rename(&session, "Renamed live", Some(&identity(&host)))
            .await
            .expect("rename");
        assert_eq!(state["title"], "Renamed live");
        let usage = &state["usage"];
        println!("usage after the turns: {usage}");
        assert!(usage["used"].as_u64().is_some_and(|used| used > 0), "{state}");
        assert!(usage["size"].as_u64().is_some_and(|size| size > 0), "{state}");
        assert!(
            host.info()["commands"]
                .as_array()
                .is_some_and(|commands| commands.iter().any(|c| c["name"] == "compact")),
            "Grok lists /compact"
        );
        // Grok takes image prompts though it advertises none, and passes the
        // image on to the model.
        assert_eq!(caps["image"], true);
        host.prompt(&session, "what is this", &[IMAGE.into()], None)
            .await
            .expect("image prompt");
        until("a model request carrying the image", async || {
            seen.lock()
                .expect("log")
                .iter()
                .any(|c| c.contains("/chat/completions") && c.contains("image=true"))
        })
        .await;
        until("the image turn's end", async || {
            host.session_access(&session, &identity(&host))
                .await
                .is_ok_and(|access| access.can_release)
        })
        .await;
    }

    // Handed back, then reopened: Grok's agent is the session's only writer.
    // The reply can show before the turn's `session/prompt` answer, and a
    // running turn is not handed back.
    until("the turn's end", async || {
        host.session_access(&session, &identity(&host))
            .await
            .is_ok_and(|access| access.can_release)
    })
    .await;
    let released = host.session_release(&access).await.expect("release");
    assert_eq!(released.reason, "released_here");
    let reopened = host
        .session_open(&session, &identity(&host))
        .await
        .expect("reopen");
    assert_eq!((reopened.mode.as_str(), reopened.writer.as_str()), ("write", "this_host"));

    // The model chip of the reopened session reaches the provider.
    if chips {
        let state = host
            .set_config_option(&session, "model", "fake-2", Some(&identity(&host)))
            .await
            .expect("model switched");
        let model = state["configOptions"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|option| option["id"] == "model")
            .expect("model option");
        assert_eq!(model["currentValue"], "fake-2");
        host.prompt(&session, "ping again", &[], Some(&identity(&host)))
            .await
            .expect("second prompt");
        until("a request for the chosen model", async || {
            seen.lock()
                .expect("log")
                .iter()
                .any(|c| c.contains("/chat/completions") && c.ends_with("model=fake-2"))
        })
        .await;
        until("the second reply", async || {
            texts(&host.history(&session, None, None, None).expect("history"))
                .iter()
                .skip_while(|t| *t != "ping again")
                .any(|t| t == REPLY)
        })
        .await;
    }
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

/// Grok's own stdio client in leader mode (`grok agent --leader stdio`),
/// standing in for a terminal client: it starts the home's leader and
/// drives the session through it. It refuses every agent request.
struct LeaderClient {
    child: tokio::process::Child,
    stdin: Arc<tokio::sync::Mutex<tokio::process::ChildStdin>>,
    waiting: Arc<Mutex<std::collections::HashMap<u64, tokio::sync::oneshot::Sender<Value>>>>,
    next: std::sync::atomic::AtomicU64,
}

impl LeaderClient {
    fn spawn(
        program: &Path,
        launch: &pocox_host_svc::acp::provider::AcpProviderLaunch,
        cwd: &Path,
    ) -> Self {
        let mut command = tokio::process::Command::new(program);
        command
            .args(["agent", "--leader", "stdio"])
            .envs(launch.env.iter().cloned())
            .env("GROK_DISABLE_AUTOUPDATER", "1")
            .current_dir(cwd)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true);
        for name in &launch.env_remove {
            command.env_remove(name);
        }
        let mut child = command.spawn().expect("grok agent --leader stdio");
        let stdin = Arc::new(tokio::sync::Mutex::new(child.stdin.take().expect("stdin")));
        let waiting: Arc<
            Mutex<std::collections::HashMap<u64, tokio::sync::oneshot::Sender<Value>>>,
        > = Arc::default();
        let (reader, answers, refusals) =
            (child.stdout.take().expect("stdout"), waiting.clone(), stdin.clone());
        tokio::spawn(async move {
            use tokio::io::AsyncBufReadExt;
            let mut lines = tokio::io::BufReader::new(reader).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
                match (message["id"].as_u64(), message.get("method")) {
                    (Some(id), None) => {
                        if let Some(answer) = answers.lock().expect("waiting").remove(&id) {
                            let _ = answer.send(message);
                        }
                    },
                    (_, Some(_)) if message.get("id").is_some() => {
                        let refusal = json!({"jsonrpc": "2.0", "id": message["id"],
                            "error": {"code": -32601, "message": "not available"}});
                        let mut stdin = refusals.lock().await;
                        let _ = stdin.write_all(format!("{refusal}\n").as_bytes()).await;
                        let _ = stdin.flush().await;
                    },
                    _ => {},
                }
            }
        });
        Self {
            child,
            stdin,
            waiting,
            next: 1.into(),
        }
    }

    fn pid(&self) -> u32 {
        self.child.id().expect("running")
    }

    /// Send a request; the answer arrives on the returned receiver.
    async fn send(&self, method: &str, params: Value) -> tokio::sync::oneshot::Receiver<Value> {
        let id = self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (answer, receiver) = tokio::sync::oneshot::channel();
        self.waiting.lock().expect("waiting").insert(id, answer);
        let request = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        let mut stdin = self.stdin.lock().await;
        stdin
            .write_all(format!("{request}\n").as_bytes())
            .await
            .expect("write");
        stdin.flush().await.expect("flush");
        receiver
    }

    async fn call(&self, method: &str, params: Value) -> Value {
        let answer = tokio::time::timeout(WAIT, self.send(method, params).await)
            .await
            .unwrap_or_else(|_| panic!("{method} timed out"))
            .expect("answer");
        assert!(answer.get("error").is_none(), "{method}: {answer}");
        answer["result"].clone()
    }
}

/// The test's leader, stopped when the test ends however it ends.
struct Leader(i32);

impl Drop for Leader {
    fn drop(&mut self) {
        let _ = std::process::Command::new("kill")
            .arg(self.0.to_string())
            .status();
    }
}

fn updates_log(home: &Path, session: &str) -> String {
    let Ok(buckets) = std::fs::read_dir(home.join("sessions")) else { return String::new() };
    buckets
        .flatten()
        .map(|bucket| bucket.path().join(session).join("updates.jsonl"))
        .find_map(|path| std::fs::read_to_string(path).ok())
        .unwrap_or_default()
}

fn page_text(page: &pocox_host_svc::native_history::NativePage) -> String {
    page.turns
        .iter()
        .flat_map(|turn| turn.items.iter().map(|item| item.text.clone()))
        .collect::<Vec<_>>()
        .join("|")
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs an installed Grok Build: set POCOX_TEST_GROK"]
async fn a_terminal_clients_leader_session_is_followed_live_read_only() {
    let program = PathBuf::from(std::env::var_os("POCOX_TEST_GROK").expect("POCOX_TEST_GROK"));
    let home = tempfile::TempDir::new().expect("home");
    let project = tempfile::TempDir::new().expect("project");
    let (port, _) = model().await;
    let endpoint = ProviderEndpoint {
        protocol: ApiProtocol::ChatCompletions,
        base_url: format!("http://127.0.0.1:{port}/v1"),
        key: Some(Secret::new(KEY)),
        model: Some("fake-1".into()),
    };
    let grok_home = home.path().join("grok-home");
    let launch = grok::provider_launch(&grok_home, &endpoint, &[]).expect("provider home");
    let cwd = project.path().canonicalize().expect("cwd");

    let client = LeaderClient::spawn(&program, &launch, &cwd);
    client
        .call("initialize", json!({"protocolVersion": 1, "clientCapabilities": {}}))
        .await;
    let opened = client
        .call("session/new", json!({"cwd": cwd, "mcpServers": []}))
        .await;
    let session = opened["sessionId"]
        .as_str()
        .expect("session id")
        .to_string();
    assert!(grok_home.join("leader.sock").exists(), "the client started a leader");
    // Grok starts its leader with `--no-exit-on-disconnect`: stop it here.
    let leader = Leader(
        std::fs::read_to_string(grok_home.join("leader.lock"))
            .expect("leader lock")
            .trim()
            .parse()
            .expect("leader pid"),
    );
    // It registers the session as Grok's terminal client does.
    let registry = grok_home.join("active_sessions.json");
    std::fs::write(
        &registry,
        json!([{"session_id": session, "pid": client.pid(), "cwd": cwd,
            "opened_at": chrono::Utc::now().to_rfc3339()}])
        .to_string(),
    )
    .expect("registry");

    let reader = GrokHistory::new(grok_home.clone())
        .expect("reader")
        .with_owner_probe()
        .with_leader_follow();
    let follow = reader.follow(&session).expect("follow");
    until("the live follow", async || reader.liveness(&session).await.turn_state == "idle").await;

    // A slow reply streams: the view shows it, and that the turn runs,
    // before Grok's log holds the text (Grok writes a text run when it ends).
    let answer = client
        .send(
            "session/prompt",
            json!({"sessionId": session,
            "prompt": [{"type": "text", "text": SLOW}]}),
        )
        .await;
    let mut ran = false;
    until("streamed text the log does not hold yet", async || {
        ran |= reader.liveness(&session).await.turn_state == "running";
        let page = reader.read_page(&session, None, 20).await.expect("page");
        page_text(&page).contains("slow") && !updates_log(&grok_home, &session).contains("slow")
    })
    .await;
    assert!(ran, "the turn showed as running");
    let answered = tokio::time::timeout(WAIT, answer)
        .await
        .expect("prompt")
        .expect("answer");
    assert_eq!(answered["result"]["stopReason"], "end_turn", "{answered}");
    until("the finished turn", async || {
        reader.liveness(&session).await.turn_state == "idle"
            && page_text(&reader.read_page(&session, None, 20).await.expect("page"))
                .contains("slow but steady")
    })
    .await;

    // The client's session works on after being followed (the loopback
    // model answers slowly again: the history holds the slow prompt).
    client
        .call(
            "session/prompt",
            json!({"sessionId": session,
            "prompt": [{"type": "text", "text": "ping"}]}),
        )
        .await;
    until("the next reply", async || {
        page_text(&reader.read_page(&session, None, 20).await.expect("page"))
            .ends_with("ping|slow but steady")
    })
    .await;

    // The registration ends: the follower leaves, the client's session stays.
    std::fs::write(&registry, "[]").expect("registry");
    until("the follower left", async || {
        tokio::time::sleep(Duration::from_secs(6)).await; // past the probe's display cache
        reader.liveness(&session).await.turn_state == "unknown"
    })
    .await;
    client
        .call(
            "session/prompt",
            json!({"sessionId": session,
            "prompt": [{"type": "text", "text": "ping"}]}),
        )
        .await;
    drop(follow);

    drop(client);
    drop(leader);
}
