//! Opt-in acceptance of forking against installed agents, in throwaway homes,
//! with a deterministic loopback model (no account, no network):
//!
//! ```sh
//! POCOX_TEST_GROK="$HOME/.grok/bin/grok" cargo test -p pocox-host-svc \
//!   --test fork_live grok -- --ignored --nocapture
//! POCOX_TEST_NODE=<node 22+> POCOX_TEST_CLAUDE_ADAPTER=<adapter dist/index.js> \
//!   POCOX_TEST_CLAUDE_CLI="$(command -v claude)" cargo test -p pocox-host-svc \
//!   --test fork_live claude -- --ignored --nocapture
//! ```
//!
//! Two hosts share one store: `holder` writes a session, standing in for
//! another process, and `forker` never loads it. Model requests prove what each
//! conversation really carries. OpenCode's is `opencode_native.rs`
//! (`native_fork_*`), beside its fixture.
#![cfg(unix)]

use std::convert::Infallible;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::extract::State;
use axum::http::Uri;
use axum::response::sse::Event;
use axum::response::{IntoResponse, Response, Sse};
use axum::routing::{get, post};
use axum::{Json, Router};
use pocox_core::history_sync::digest_bytes;
use pocox_core::provider::{ApiProtocol, ProviderEndpoint, Secret};
use pocox_host_svc::acp::provider::AcpProviderLaunch;
use pocox_host_svc::acp::spec::AgentSpec;
use pocox_host_svc::acp::{
    api, grok, spec, AgentHost, GatewayClient, HostError, HostOptions, Identity, SessionStore,
    SourceId,
};
use pocox_host_svc::native_history::{ClaudeHistory, GrokHistory, NativeHistory};
use serde_json::{json, Value};
use tokio::sync::{mpsc, watch};
use tokio_stream::wrappers::ReceiverStream;

const WAIT: Duration = Duration::from_secs(90);
/// A prompt the model starts answering and finishes only when released.
const HOLD: &str = "HOLD-THE-REPLY";

#[derive(Clone)]
struct Model {
    /// The body of every model request.
    requests: Arc<Mutex<Vec<Value>>>,
    /// Anything else that reached this address, as `METHOD path`.
    other: Arc<Mutex<Vec<String>>>,
    release: watch::Sender<bool>,
    port: u16,
}

impl Model {
    async fn start() -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind");
        let model = Self {
            requests: Arc::default(),
            other: Arc::default(),
            release: watch::channel(false).0,
            port: listener.local_addr().expect("address").port(),
        };
        let router = Router::new()
            .route("/v1/models", get(models))
            .route("/v1/chat/completions", post(chat))
            .route("/v1/messages", post(messages))
            .fallback(other)
            .with_state(model.clone());
        tokio::spawn(async move {
            let _ = axum::serve(listener, router).await;
        });
        model
    }

    /// The agent's own turn request carrying `marker`: it offers tools, unlike
    /// the title and summary requests beside it.
    fn turn_request(&self, marker: &str) -> Option<String> {
        let requests = self.requests.lock().expect("requests");
        requests
            .iter()
            .rev()
            .find(|body| {
                body["tools"]
                    .as_array()
                    .is_some_and(|tools| !tools.is_empty())
                    && body["messages"].to_string().contains(marker)
            })
            .map(|body| body["messages"].to_string())
    }

    async fn context_of(&self, marker: &str) -> String {
        until(&format!("a model request with {marker}"), async || {
            self.turn_request(marker).is_some()
        })
        .await;
        self.turn_request(marker).expect("request")
    }
}

async fn models() -> Json<Value> {
    Json(json!({"object": "list", "data": [{"id": "fake-1", "object": "model"}]}))
}

async fn other(State(model): State<Model>, method: axum::http::Method, uri: Uri) -> Response {
    model
        .other
        .lock()
        .expect("other")
        .push(format!("{method} {uri}"));
    Json(json!({})).into_response()
}

type Frames = ReceiverStream<Result<Event, Infallible>>;

/// Send each frame, waiting for the release before the last two when held.
fn stream(model: &Model, held: bool, frames: Vec<Event>) -> Sse<Frames> {
    let (sender, stream) = mpsc::channel(16);
    let mut release = model.release.subscribe();
    tokio::spawn(async move {
        let hold_at = frames.len().saturating_sub(2);
        for (index, frame) in frames.into_iter().enumerate() {
            if held && index == hold_at {
                let _ = release.wait_for(|released| *released).await;
            }
            if sender.send(Ok(frame)).await.is_err() {
                return;
            }
        }
    });
    Sse::new(ReceiverStream::new(stream))
}

async fn chat(State(model): State<Model>, Json(body): Json<Value>) -> Sse<Frames> {
    let held = last_user_text(&body).contains(HOLD);
    model.requests.lock().expect("requests").push(body);
    let chunk = |delta: Value, reason: Value| {
        Event::default().data(
            json!({"id": "c", "object": "chat.completion.chunk", "created": 1, "model": "fake-1",
                "choices": [{"index": 0, "delta": delta, "finish_reason": reason}]})
            .to_string(),
        )
    };
    stream(&model, held, vec![
        chunk(json!({"role": "assistant", "content": "partial "}), Value::Null),
        chunk(json!({"content": "REPLY"}), Value::Null),
        chunk(json!({}), json!("stop")),
        Event::default().data("[DONE]"),
    ])
}

async fn messages(State(model): State<Model>, Json(body): Json<Value>) -> Response {
    let held = last_user_text(&body).contains(HOLD);
    let streamed = body["stream"] == true;
    let name = body["model"].clone();
    model.requests.lock().expect("requests").push(body);
    if !streamed {
        return Json(json!({"id": "m", "type": "message", "role": "assistant", "model": name,
            "content": [{"type": "text", "text": "title"}], "stop_reason": "end_turn",
            "stop_sequence": null, "usage": {"input_tokens": 1, "output_tokens": 1}}))
        .into_response();
    }
    let event = |kind: &str, body: Value| Event::default().event(kind).data(body.to_string());
    let text = |text: &str| {
        event(
            "content_block_delta",
            json!({"type": "content_block_delta", "index": 0,
                "delta": {"type": "text_delta", "text": text}}),
        )
    };
    stream(&model, held, vec![
        event(
            "message_start",
            json!({"type": "message_start", "message": {"id": "m", "type": "message",
                "role": "assistant", "model": name, "content": [], "stop_reason": null,
                "stop_sequence": null, "usage": {"input_tokens": 1, "output_tokens": 1}}}),
        ),
        event(
            "content_block_start",
            json!({"type": "content_block_start", "index": 0,
                "content_block": {"type": "text", "text": ""}}),
        ),
        text("partial "),
        text("REPLY"),
        event("content_block_stop", json!({"type": "content_block_stop", "index": 0})),
        event(
            "message_delta",
            json!({"type": "message_delta", "delta": {"stop_reason": "end_turn",
                "stop_sequence": null}, "usage": {"output_tokens": 1}}),
        ),
        event("message_stop", json!({"type": "message_stop"})),
    ])
    .into_response()
}

fn last_user_text(body: &Value) -> String {
    body["messages"]
        .as_array()
        .and_then(|messages| messages.iter().rev().find(|m| m["role"] == "user"))
        .map(|message| message["content"].to_string())
        .unwrap_or_default()
}

fn identity(host: &AgentHost) -> Identity {
    Identity {
        host_id: Some(host.host_id().to_string()),
        generation: host.snapshot()["generation"].as_u64(),
    }
}

async fn until(what: &str, mut check: impl AsyncFnMut() -> bool) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while !check().await {
        assert!(tokio::time::Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

async fn idle(host: &AgentHost, session: &str) {
    until("the turn's end", async || {
        host.session_access(session, &identity(host))
            .await
            .is_ok_and(|access| access.mode == "write" && access.turn == "idle")
    })
    .await;
}

async fn send(host: &AgentHost, session: &str, text: &str) -> String {
    host.prompt(session, text, &[], None).await.expect("prompt")
}

async fn turn(host: &AgentHost, session: &str, text: &str) -> String {
    let turn = send(host, session, text).await;
    idle(host, session).await;
    turn
}

/// Open a session on `host` through its ordinary admission.
async fn open(host: &AgentHost, session: &str) {
    let access = host
        .session_open(session, &identity(host))
        .await
        .expect("open");
    assert_eq!((access.mode.as_str(), access.reason.as_str()), ("write", "owned"), "{access:?}");
}

/// Every file of `dir`, by digest, without the agent's lock files.
fn digest(dir: &Path) -> Vec<(String, String)> {
    let mut files: Vec<_> = std::fs::read_dir(dir)
        .expect("session dir")
        .flatten()
        .filter(|entry| {
            entry.path().is_file() && entry.path().extension().is_none_or(|e| e != "lock")
        })
        .map(|entry| {
            let bytes = std::fs::read(entry.path()).expect("file");
            (entry.file_name().to_string_lossy().into_owned(), digest_bytes(&bytes))
        })
        .collect();
    files.sort();
    files
}

/// `read`, once it stopped changing: the writer's own summaries and titles
/// land a moment after its turn ends.
async fn settled<T: PartialEq>(mut read: impl FnMut() -> T) -> T {
    let mut last = read();
    let mut quiet = 0;
    while quiet < 6 {
        tokio::time::sleep(Duration::from_millis(500)).await;
        let next = read();
        quiet = if next == last { quiet + 1 } else { 0 };
        last = next;
    }
    last
}

/// Where a session named `id` is stored under `root`, whatever its bucket.
fn stored(root: &Path, id: &str) -> Option<PathBuf> {
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let path = entry.path();
            let stem = path.file_stem().and_then(|stem| stem.to_str());
            if stem == Some(id) {
                return Some(path);
            }
            if path.is_dir() {
                pending.push(path);
            }
        }
    }
    None
}

fn file_digest(path: &Path) -> String {
    digest_bytes(&std::fs::read(path).expect("transcript"))
}

fn grok_host(program: &Path, home: &Path, env: &AcpProviderLaunch, backend: u16) -> AgentHost {
    let spec = spec::preset(grok::PROFILE_ID).expect("preset").spec();
    let reader = GrokHistory::new(home.to_path_buf())
        .expect("reader")
        .with_owner_probe();
    let mut launch = env.env.clone();
    // What Grok's fork tells its backend, if anything, arrives here.
    launch.push((
        "GROK_CODE_BACKEND_URL".into(),
        format!("http://127.0.0.1:{backend}/backend").into(),
    ));
    AgentHost::create_with_native_history(
        HostOptions {
            store: SessionStore::memory(SourceId::with_key(&"g".repeat(32), program, &spec.args)),
            spec,
            program: program.to_path_buf(),
            path: None,
            env: launch,
            env_remove: env.env_remove.clone(),
        },
        None,
        None,
        Some(NativeHistory::Grok(Arc::new(reader))),
    )
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs an installed Grok Build: set POCOX_TEST_GROK"]
async fn grok_forks_a_held_session_without_touching_its_writer() {
    let program = PathBuf::from(std::env::var_os("POCOX_TEST_GROK").expect("POCOX_TEST_GROK"));
    let root = tempfile::TempDir::new().expect("root");
    let project = tempfile::TempDir::new().expect("project");
    let cwd = project.path().canonicalize().expect("cwd");
    let cwd = cwd.to_str().expect("path");
    let model = Model::start().await;
    let endpoint = ProviderEndpoint {
        protocol: ApiProtocol::ChatCompletions,
        base_url: format!("http://127.0.0.1:{}/v1", model.port),
        key: Some(Secret::new("sk-pocox-live-test")),
        model: Some("fake-1".into()),
    };
    let home = root.path().join("grok-home");
    let launch = grok::provider_launch(&home, &endpoint, &[]).expect("provider home");
    let holder = grok_host(&program, &home, &launch, model.port);
    let forker = grok_host(&program, &home, &launch, model.port);
    holder.launch().await.expect("holder");
    forker.launch().await.expect("forker");
    println!("negotiated fork: {}", forker.info()["fork"]);
    assert_eq!(forker.info()["fork"], json!({"supported": true, "throughTurn": true}));

    // The holder writes; the forker reaches this over its real gateway.
    let opened = holder.new_session(cwd, None).await.expect("session");
    let source = opened["sessionId"].as_str().expect("id").to_string();
    let first = turn(&holder, &source, "first MARKER-A").await;
    turn(&holder, &source, "second MARKER-B").await;
    let source_dir = stored(&home.join("sessions"), &source).expect("stored");
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let origin = format!("http://{}/", listener.local_addr().expect("address"));
    tokio::spawn(api::serve(listener, forker.clone()));
    let gateway = GatewayClient::new(&origin).expect("client");

    let before = settled(|| digest(&source_dir)).await;
    let answer = gateway
        .fork_session(&source, None, &identity(&forker))
        .await
        .expect("fork");
    println!("fork: {answer}");
    assert_eq!(answer["outcome"], "created");
    assert_eq!(answer["forkedFrom"], source.as_str());
    assert_eq!(answer["cwd"], cwd);
    assert_eq!(answer["lastTurnInterrupted"], false);
    let fork = answer["sessionId"].as_str().expect("id").to_string();
    assert_ne!(fork, source);
    assert_eq!(digest(&source_dir), before, "a fork writes nothing to its source");
    let holding = holder
        .session_access(&source, &identity(&holder))
        .await
        .expect("access");
    assert_eq!((holding.mode.as_str(), holding.reason.as_str()), ("write", "owned"));
    tokio::time::sleep(Duration::from_secs(2)).await;
    let other = model.other.lock().expect("other").clone();
    assert!(
        !other.iter().any(|request| request.contains("/backend/")),
        "a provider's key signs nothing in to Grok's backend: {other:?}"
    );

    // Its own admission, then each side's turns stay on their side.
    open(&forker, &fork).await;
    turn(&forker, &fork, "fork MARKER-C").await;
    let context = model.context_of("MARKER-C").await;
    assert!(context.contains("MARKER-A") && context.contains("MARKER-B"), "{context}");
    turn(&holder, &source, "source MARKER-D").await;
    let context = model.context_of("MARKER-D").await;
    assert!(context.contains("MARKER-B") && !context.contains("MARKER-C"), "{context}");
    turn(&forker, &fork, "fork again MARKER-E").await;
    let context = model.context_of("MARKER-E").await;
    assert!(context.contains("MARKER-C") && !context.contains("MARKER-D"), "{context}");

    // Through a turn, named by the holder's own turn id or the reader's.
    let answer = holder
        .fork_session(&source, Some(&first), &identity(&holder))
        .await
        .expect("fork through the host's turn");
    assert_eq!(answer["boundaryConfirmed"], true, "{answer}");
    let bounded = answer["sessionId"].as_str().expect("id").to_string();
    open(&forker, &bounded).await;
    turn(&forker, &bounded, "bounded MARKER-F").await;
    let context = model.context_of("MARKER-F").await;
    assert!(context.contains("MARKER-A") && !context.contains("MARKER-B"), "{context}");
    let shown = forker
        .read_history(&source, None, None, Some(50))
        .await
        .expect("native history");
    let native = shown["turns"][1]["turnId"].as_str().expect("turn");
    let answer = forker
        .fork_session(&source, Some(native), &identity(&forker))
        .await
        .expect("fork through the reader's turn");
    assert_eq!(answer["boundaryConfirmed"], true, "{answer}");

    // And a turn this host replayed when it opened the session.
    let replayed = forker
        .read_history(&fork, None, None, Some(50))
        .await
        .expect("replayed history");
    let replayed = replayed["window"][0]["id"].as_str().expect("turn");
    assert!(replayed.starts_with("replay:"), "{replayed}");
    let answer = forker
        .fork_session(&fork, Some(replayed), &identity(&forker))
        .await
        .expect("fork through a replayed turn");
    assert_eq!(answer["boundaryConfirmed"], true, "{answer}");

    // A session this host never saw is refused, and leaves nothing behind.
    let buckets = || {
        std::fs::read_dir(source_dir.parent().expect("bucket"))
            .expect("list")
            .count()
    };
    let count = buckets();
    let error = forker
        .fork_session("01a15501-b678-7db0-b062-a1f5b1edc8d9", None, &identity(&forker))
        .await
        .expect_err("no such session");
    assert!(matches!(error, HostError::Agent(_)), "{error}");
    assert_eq!(buckets(), count, "Grok was never asked");

    // A running source: the copy freezes the turn at what is stored, and the
    // reply reaching the source later stays with the source.
    let held = send(&holder, &source, &format!("{HOLD} MARKER-G")).await;
    model.context_of("MARKER-G").await;
    let answer = forker
        .fork_session(&source, None, &identity(&forker))
        .await
        .expect("fork a running source");
    assert_eq!(answer["outcome"], "created", "{answer}");
    assert_eq!(answer["lastTurnInterrupted"], true, "{answer}");
    let frozen = answer["sessionId"].as_str().expect("id").to_string();
    let error = forker
        .fork_session(&source, Some(&held), &identity(&forker))
        .await
        .expect_err("not finished");
    assert!(matches!(error, HostError::InvalidInput(_) | HostError::Busy), "{error}");
    open(&forker, &frozen).await;
    turn(&forker, &frozen, "after the freeze MARKER-H").await;
    let context = model.context_of("MARKER-H").await;
    assert!(context.contains("MARKER-G"), "the frozen prompt stays: {context}");
    assert_eq!(
        context.matches("REPLY").count(),
        model.context_of("MARKER-G").await.matches("REPLY").count(),
        "the frozen turn has no reply of its own: {context}"
    );
    model.release.send_replace(true);
    idle(&holder, &source).await;
    assert_eq!(holder.info()["phase"]["state"], "ready", "the writer finished its turn");
    holder.stop().await;
    forker.stop().await;
}

fn claude_host(root: &Path, model: u16) -> AgentHost {
    let path = |key: &str| PathBuf::from(std::env::var_os(key).expect(key));
    let (node, adapter, cli) =
        (path("POCOX_TEST_NODE"), path("POCOX_TEST_CLAUDE_ADAPTER"), path("POCOX_TEST_CLAUDE_CLI"));
    let (config, home) = (root.join("config"), root.join("home"));
    std::fs::create_dir_all(&config).expect("config");
    std::fs::create_dir_all(&home).expect("home");
    let reader = ClaudeHistory::from_adapter(node.clone(), &adapter, config.clone())
        .expect("reader")
        .with_owner_probe(cli.clone(), home.clone());
    let args = vec![adapter.to_string_lossy().into_owned()];
    let store = SessionStore::memory(SourceId::with_key(&"f".repeat(32), &node, &args));
    let env = vec![
        ("HOME".into(), home.into_os_string()),
        ("CLAUDE_CONFIG_DIR".into(), config.into_os_string()),
        ("CLAUDE_CODE_EXECUTABLE".into(), cli.into_os_string()),
        ("ANTHROPIC_BASE_URL".into(), format!("http://127.0.0.1:{model}").into()),
        ("ANTHROPIC_API_KEY".into(), "pcx-disposable-fixture-key".into()),
        ("ANTHROPIC_MODEL".into(), "fake-1".into()),
        ("DISABLE_TELEMETRY".into(), "1".into()),
        ("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC".into(), "1".into()),
        ("CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF".into(), "1".into()),
    ];
    AgentHost::create_with_native_history(
        HostOptions {
            spec: AgentSpec {
                profile_id: "claude".into(),
                display_name: "Isolated Claude".into(),
                program: node.to_string_lossy().into_owned(),
                args,
            },
            program: node,
            path: Some("/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin".into()),
            env,
            env_remove: Vec::new(),
            store,
        },
        None,
        None,
        Some(NativeHistory::Claude(Arc::new(reader))),
    )
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "needs POCOX_TEST_NODE, POCOX_TEST_CLAUDE_ADAPTER and POCOX_TEST_CLAUDE_CLI"]
async fn claude_forks_a_held_session_from_its_latest_state_only() {
    let root = tempfile::TempDir::new().expect("root");
    let project = tempfile::TempDir::new().expect("project");
    let cwd = project.path().canonicalize().expect("cwd");
    let cwd = cwd.to_str().expect("path");
    let model = Model::start().await;
    let holder = claude_host(root.path(), model.port);
    let forker = claude_host(root.path(), model.port);
    holder.launch().await.expect("holder");
    forker.launch().await.expect("forker");
    println!("negotiated fork: {}", forker.info()["fork"]);
    assert_eq!(forker.info()["fork"], json!({"supported": true, "throughTurn": false}));

    let opened = holder.new_session(cwd, None).await.expect("session");
    let source = opened["sessionId"].as_str().expect("id").to_string();
    let first = turn(&holder, &source, "first MARKER-A").await;
    turn(&holder, &source, "second MARKER-B").await;
    let transcript = stored(&root.path().join("config/projects"), &source).expect("transcript");

    let before = settled(|| file_digest(&transcript)).await;
    let answer = forker
        .fork_session(&source, None, &identity(&forker))
        .await
        .expect("fork");
    println!("fork: {answer}");
    assert_eq!(answer["outcome"], "created");
    assert_eq!(answer["forkedFrom"], source.as_str());
    let fork = answer["sessionId"].as_str().expect("id").to_string();
    assert_ne!(fork, source);
    assert_eq!(file_digest(&transcript), before, "a fork writes nothing to its source");
    assert_eq!(holder.info()["phase"]["state"], "ready", "its writer is untouched");

    open(&forker, &fork).await;
    turn(&forker, &fork, "fork MARKER-C").await;
    let context = model.context_of("MARKER-C").await;
    assert!(context.contains("MARKER-A") && context.contains("MARKER-B"), "{context}");
    turn(&holder, &source, "source MARKER-D").await;
    let context = model.context_of("MARKER-D").await;
    assert!(context.contains("MARKER-B") && !context.contains("MARKER-C"), "{context}");
    turn(&forker, &fork, "fork again MARKER-E").await;
    let context = model.context_of("MARKER-E").await;
    assert!(context.contains("MARKER-C") && !context.contains("MARKER-D"), "{context}");

    // The adapter's only boundary belongs to another client.
    let error = forker
        .fork_session(&source, Some(&first), &identity(&forker))
        .await
        .expect_err("no boundary");
    assert!(matches!(error, HostError::Unsupported(_)), "{error}");

    let error = forker
        .fork_session("11111111-1111-4111-8111-111111111111", None, &identity(&forker))
        .await
        .expect_err("no such session");
    assert!(matches!(error, HostError::Agent(_)), "{error}");

    // A running source: the prompt is stored and its reply is not.
    send(&holder, &source, &format!("{HOLD} MARKER-G")).await;
    model.context_of("MARKER-G").await;
    let answer = forker
        .fork_session(&source, None, &identity(&forker))
        .await
        .expect("fork a running source");
    println!("fork of a running source: {answer}");
    assert_eq!(answer["outcome"], "created", "{answer}");
    let frozen = answer["sessionId"].as_str().expect("id").to_string();
    open(&forker, &frozen).await;
    turn(&forker, &frozen, "after the freeze MARKER-H").await;
    let context = model.context_of("MARKER-H").await;
    assert!(context.contains("MARKER-G"), "the frozen prompt stays: {context}");
    model.release.send_replace(true);
    idle(&holder, &source).await;
    assert_eq!(holder.info()["phase"]["state"], "ready", "the writer finished its turn");
    holder.stop().await;
    forker.stop().await;
}
