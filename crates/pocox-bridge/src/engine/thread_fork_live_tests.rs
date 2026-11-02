//! Opt-in acceptance of `thread/fork` with real external Codex processes: one
//! client holds a session in its own process while a host serving the same
//! history forks it through the production engine path. Both then keep working.
//!
//! Set `POCOX_TEST_CODEX_BINARY` to the native Codex binary and run with
//! `--ignored`. Homes, listeners and the model endpoint are temporary and
//! local; no account is used and no existing host is contacted. The relay path
//! is the same engine call over a tunnel port, so the two hosts below stand for
//! two devices: each service key reaches only its own host's history.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use pocox_codex::client::{AppClient, Inbound};
use pocox_codex::{liveness, rollout};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, Notify};

use super::app_session::{self, ForkOutcome};
use super::runtime;
use super::session_engine::{engine, TurnOptions};

/// The first request carrying this waits until the test releases it. A fork of
/// that turn inherits the text, and its own requests must not wait too.
const HOLD: &str = "hold-this-turn";
const WAIT: Duration = Duration::from_secs(60);

/// The Responses endpoint both processes call: records every request and
/// answers each with a canned reply, holding back those that ask for it.
#[derive(Default)]
struct ModelEndpoint {
    requests: Mutex<Vec<String>>,
    hold_used: AtomicBool,
    held: Notify,
    release: Notify,
}

impl ModelEndpoint {
    /// The one request that carried `marker` as its newest prompt.
    fn request_with(&self, marker: &str) -> String {
        self.requests
            .lock()
            .expect("requests")
            .iter()
            .rev()
            .find(|body| body.contains(marker))
            .unwrap_or_else(|| panic!("no model request carried {marker}"))
            .clone()
    }

    async fn serve(self: Arc<Self>, listener: TcpListener) {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(Arc::clone(&self).answer(stream));
        }
    }

    async fn answer(self: Arc<Self>, mut stream: TcpStream) {
        let mut request = Vec::new();
        let mut chunk = [0_u8; 16 * 1024];
        let body = loop {
            let read = stream.read(&mut chunk).await.unwrap_or(0);
            if read == 0 {
                return;
            }
            request.extend_from_slice(&chunk[..read]);
            let Some(split) = request.windows(4).position(|window| window == b"\r\n\r\n") else {
                continue;
            };
            let head = String::from_utf8_lossy(&request[..split]).to_lowercase();
            let length: usize = head
                .lines()
                .find_map(|line| line.strip_prefix("content-length:"))
                .and_then(|value| value.trim().parse().ok())
                .unwrap_or(0);
            if request.len() >= split + 4 + length {
                if !head.starts_with("post") || !head.contains("/responses") {
                    let _ = stream
                        .write_all(b"HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n")
                        .await;
                    return;
                }
                break String::from_utf8_lossy(&request[split + 4..]).into_owned();
            }
        };
        let holding = body.contains(HOLD) && !self.hold_used.swap(true, Ordering::SeqCst);
        let index = {
            let mut requests = self.requests.lock().expect("requests");
            requests.push(body);
            requests.len()
        };
        let event = |kind: &str, data: Value| format!("event: {kind}\ndata: {data}\n\n");
        let id = format!("resp-{index}");
        let opening = format!(
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n{}",
            event("response.created", json!({"type": "response.created", "response": {"id": id}}))
        );
        if stream.write_all(opening.as_bytes()).await.is_err() {
            return;
        }
        let _ = stream.flush().await;
        if holding {
            self.held.notify_one();
            self.release.notified().await;
        }
        let closing = [
            event(
                "response.output_item.done",
                json!({"type": "response.output_item.done", "item": {
                    "type": "message",
                    "role": "assistant",
                    "id": format!("msg-{index}"),
                    "content": [{"type": "output_text", "text": format!("reply-{index}")}],
                }}),
            ),
            event(
                "response.completed",
                json!({"type": "response.completed", "response": {"id": id}}),
            ),
        ]
        .concat();
        let _ = stream.write_all(closing.as_bytes()).await;
        let _ = stream.shutdown().await;
    }
}

/// A real `codex app-server` with its own process and listener.
struct AppServer {
    process: tokio::process::Child,
    address: String,
    log: PathBuf,
}

impl AppServer {
    fn start(binary: &Path, home: &Path, scratch: &Path, name: &str) -> Self {
        runtime::runtime().block_on(async {
            let reserved = std::net::TcpListener::bind("127.0.0.1:0").expect("reserve port");
            let address = reserved.local_addr().expect("port").to_string();
            drop(reserved);
            let log_path = scratch.join(format!("{name}.log"));
            let log = std::fs::File::create(&log_path).expect("log");
            let process = tokio::process::Command::new(binary)
                .args(["app-server", "--listen", &format!("ws://{address}")])
                .env("CODEX_HOME", home)
                .env("HOME", scratch)
                .current_dir(scratch)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(log)
                .kill_on_drop(true)
                .spawn()
                .expect("start codex");
            Self {
                process,
                address,
                log: log_path,
            }
        })
    }

    fn pid(&self) -> u32 {
        self.process.id().expect("running process")
    }

    fn is_running(&mut self) -> bool {
        matches!(self.process.try_wait(), Ok(None))
    }

    /// A raw controller of this process, as another client would be.
    fn client(&self) -> (AppClient, mpsc::UnboundedReceiver<Inbound>) {
        runtime::runtime().block_on(async {
            let url = format!("ws://{}", self.address);
            let deadline = Instant::now() + WAIT;
            let (client, events) = loop {
                if let Ok(connected) = AppClient::connect(&url).await {
                    break connected;
                }
                assert!(
                    Instant::now() < deadline,
                    "app-server did not start: {}",
                    std::fs::read_to_string(&self.log).unwrap_or_default()
                );
                tokio::time::sleep(Duration::from_millis(50)).await;
            };
            client
                .initialize("pocox-fork-test", true)
                .await
                .expect("initialize");
            (client, events)
        })
    }
}

/// Run one turn in another client and wait until it reaches the given state.
fn start_turn(client: &AppClient, thread: &str, text: &str) -> String {
    let response = runtime::runtime()
        .block_on(client.request(
            "turn/start",
            json!({"threadId": thread, "input": [{"type": "text", "text": text}]}),
        ))
        .expect("turn/start");
    response["turn"]["id"].as_str().expect("turn id").to_owned()
}

fn wait_for_completion(events: &mut mpsc::UnboundedReceiver<Inbound>, thread: &str) {
    runtime::runtime().block_on(async {
        tokio::time::timeout(WAIT, async {
            while let Some(event) = events.recv().await {
                let params = event.params.unwrap_or(Value::Null);
                if event.method == "turn/completed" && params["threadId"] == thread {
                    assert_eq!(params["turn"]["status"], "completed", "{params}");
                    return;
                }
            }
            panic!("connection ended before the turn completed");
        })
        .await
        .expect("turn completed in time");
    });
}

/// A thread's turns, oldest first, as id and status.
fn turns(client: &AppClient, thread: &str) -> Vec<(String, String)> {
    let page = runtime::runtime()
        .block_on(client.request(
            "thread/turns/list",
            json!({"threadId": thread, "limit": 50, "sortDirection": "asc", "itemsView": "notLoaded"}),
        ))
        .expect("turns");
    page["data"]
        .as_array()
        .expect("turn page")
        .iter()
        .map(|turn| {
            (
                turn["id"].as_str().expect("id").to_owned(),
                turn["status"].as_str().expect("status").to_owned(),
            )
        })
        .collect()
}

fn fork(key: &str, source: &str, through: Option<&str>) -> app_session::ThreadFork {
    match engine(key).thread_fork(key, source, through).expect("fork") {
        ForkOutcome::Created(fork) => fork,
        ForkOutcome::Unknown(reason) => panic!("outcome unknown: {reason}"),
    }
}

/// Reopen a fork through the bridge and send it one prompt.
fn continue_fork(key: &str, thread: &str, text: &str) {
    engine(key)
        .thread_resume(key, thread)
        .expect("resume the fork");
    run_turn(key, thread, text);
}

/// Send one prompt through the bridge and wait for its reply.
fn run_turn(key: &str, thread: &str, text: &str) {
    let engine = engine(key);
    engine
        .turn_start(key, thread, TurnOptions {
            text: text.into(),
            ..Default::default()
        })
        .expect("turn in the fork");
    let deadline = Instant::now() + WAIT;
    loop {
        // A thread with its first turn just started may not be readable yet.
        let Ok(history) = engine.thread_read(key, thread, true) else {
            assert!(Instant::now() < deadline, "the thread stayed unreadable");
            std::thread::sleep(Duration::from_millis(100));
            continue;
        };
        if !history.running
            && history
                .items
                .iter()
                .any(|item| item.text.contains("reply-"))
        {
            let turn_finished = history
                .turns
                .last()
                .is_some_and(|turn| !turn.assistant_text.is_empty());
            if turn_finished {
                return;
            }
        }
        assert!(Instant::now() < deadline, "the fork's turn did not finish");
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn rollout_of(home: &Path, thread: &str) -> PathBuf {
    rollout::rollout_path_in(&home.join("sessions"), thread)
        .expect("scan")
        .expect("rollout exists")
}

fn write_config(home: &Path, model: &str) {
    std::fs::create_dir_all(home).expect("home");
    std::fs::write(
        home.join("config.toml"),
        format!(
            r#"
model = "fixture-model"
model_provider = "fixture"
approval_policy = "never"
sandbox_mode = "read-only"
[analytics]
enabled = false
[model_providers.fixture]
name = "Fork fixture"
base_url = "{model}/v1"
wire_api = "responses"
requires_openai_auth = false
"#
        ),
    )
    .expect("config");
}

#[test]
#[ignore = "requires POCOX_TEST_CODEX_BINARY; starts isolated external app-servers"]
fn a_held_source_and_its_fork_continue_independently() {
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
    let unrelated_home = scratch.path().join("other-device");
    write_config(&home, &model);
    write_config(&unrelated_home, &model);

    // One at a time: two processes creating a fresh home's database race.
    let mut holder = AppServer::start(&binary, &home, scratch.path(), "holder");
    let (holding, mut holder_events) = holder.client();
    let host = AppServer::start(&binary, &home, scratch.path(), "host");
    let (reading, _reading_events) = host.client();
    let other_device = AppServer::start(&binary, &unrelated_home, scratch.path(), "other-device");
    let (_probe, _probe_events) = other_device.client();

    let key = "pcx:forktest:app:host";
    let other_key = "pcx:forktest:app:other";
    app_session::connect_local(key.into(), &host.address).expect("connect the host");
    app_session::connect_local(other_key.into(), &other_device.address)
        .expect("connect the other device");

    // The holder creates a session and keeps it loaded in its own process.
    let started = runtime::runtime()
        .block_on(holding.request("thread/start", json!({"cwd": scratch.path()})))
        .expect("thread/start");
    let source = started["thread"]["id"]
        .as_str()
        .expect("thread id")
        .to_owned();
    let first_turn = start_turn(&holding, &source, "source-turn-one");
    wait_for_completion(&mut holder_events, &source);
    let source_rollout = rollout_of(&home, &source);
    let before = std::fs::read(&source_rollout).expect("source bytes");

    // Another device serves other history: its key can never reach this one.
    assert!(
        engine(other_key)
            .thread_fork(other_key, &source, None)
            .is_err(),
        "a host must answer from its own history, never another device's"
    );
    assert!(rollout::rollout_path_in(&unrelated_home.join("sessions"), &source)
        .expect("scan")
        .is_none());

    // Forking the held session only reads it.
    let branch = fork(key, &source, None);
    assert_ne!(branch.thread.id, source);
    assert_eq!(branch.thread.forked_from_id.as_deref(), Some(source.as_str()));
    assert_eq!(branch.thread.parent_thread_id, None);
    assert!(branch.boundary_confirmed);
    assert!(!branch.last_turn_interrupted);
    assert_eq!(std::fs::read(&source_rollout).expect("source bytes"), before);
    assert!(holder.is_running(), "a fork never stops the source's owner");
    assert!(
        !liveness::file_holders(&source_rollout)
            .iter()
            .any(|process| process.pid == host.pid()),
        "the host must not keep the source open and look like a second owner"
    );

    // The rollout readers see what it inherited, before any turn of its own.
    let branch_rollout = rollout_of(&home, &branch.thread.id);
    let info = rollout::read_session_info(&branch_rollout).expect("fork info");
    assert!(info.preview.contains("source-turn-one"), "{}", info.preview);

    // Codex lists it only after a turn of its own and names no source there, but
    // a fresh fork already reads as the conversation it inherited.
    assert!(branch.thread.preview.contains("source-turn-one"));
    let metadata = app_session::thread_metadata(key, &branch.thread.id).expect("metadata");
    assert!(metadata.preview.contains("source-turn-one"));
    assert_eq!(metadata.forked_from_id.as_deref(), Some(source.as_str()));

    // Each side continues on its own, with its own context.
    continue_fork(key, &branch.thread.id, "branch-turn-two");
    assert!(
        engine(key)
            .thread_list(key)
            .expect("session list")
            .iter()
            .any(|thread| thread.id == branch.thread.id),
        "a fork with a turn reopens from the session list"
    );
    let in_branch = endpoint.request_with("branch-turn-two");
    assert!(in_branch.contains("source-turn-one"), "the fork keeps its context");

    let later = start_turn(&holding, &source, "source-turn-two");
    wait_for_completion(&mut holder_events, &source);
    let in_source = endpoint.request_with("source-turn-two");
    assert!(!in_source.contains("branch-turn-two"), "the source never sees the fork");
    let branch_turns = turns(&reading, &branch.thread.id);
    assert_eq!(branch_turns.len(), 2, "{branch_turns:?}");
    assert_eq!(branch_turns[0].0, first_turn);
    assert!(
        !branch_turns.iter().any(|(id, _)| id == &later),
        "later source turns stay out of the fork"
    );
    let transcript = rollout::read_transcript(&branch_rollout).expect("fork transcript");
    for marker in ["source-turn-one", "branch-turn-two"] {
        assert!(transcript.iter().any(|item| item.text.contains(marker)), "{marker}");
    }
    assert!(!transcript
        .iter()
        .any(|item| item.text.contains("source-turn-two")));

    // A completed turn is an exact boundary.
    let through = fork(key, &source, Some(&first_turn));
    assert!(through.boundary_confirmed);
    assert_eq!(turns(&reading, &through.thread.id), [(first_turn.clone(), "completed".to_owned())]);
    continue_fork(key, &through.thread.id, "through-turn-two");
    assert!(!endpoint
        .request_with("through-turn-two")
        .contains("source-turn-two"));

    // A turn running in the other process is a consistent snapshot: whatever it
    // has saved is frozen, never finished in the branch, and it runs on untouched.
    let running = start_turn(&holding, &source, &format!("source-turn-three {HOLD}"));
    runtime::runtime().block_on(async {
        tokio::time::timeout(WAIT, endpoint.held.notified())
            .await
            .expect("the model was asked");
    });
    assert!(
        engine(key)
            .thread_fork(key, &source, Some(&running))
            .is_err(),
        "a running turn is never a boundary"
    );
    let snapshot = fork(key, &source, None);
    let frozen = turns(&reading, &snapshot.thread.id);
    eprintln!("active-source snapshot turns: {frozen:?}");
    match frozen.iter().find(|(id, _)| id == &running) {
        Some((_, status)) => {
            assert_eq!(status, "interrupted");
            assert!(snapshot.last_turn_interrupted);
        },
        None => assert!(!snapshot.last_turn_interrupted),
    }
    assert_eq!(
        frozen
            .iter()
            .filter(|(_, status)| status == "inProgress")
            .count(),
        0,
        "nothing in a branch is left pretending to run"
    );
    endpoint.release.notify_one();
    wait_for_completion(&mut holder_events, &source);
    assert_eq!(turns(&reading, &snapshot.thread.id), frozen, "later output stays out");
    continue_fork(key, &snapshot.thread.id, "snapshot-turn");
    assert!(holder.is_running());

    app_session::disconnect(key);
    app_session::disconnect(other_key);
}

/// A controller reaches a remote host through the relay, and everything happens
/// in that host's Codex home: this process's own stays empty. Needs a running
/// relay (`POCOX_FORK_RELAY`, `POCOX_FORK_RELAY_KEY`) and a host serving
/// `POCOX_FORK_SERVICE` from the Codex home `POCOX_FORK_HOST_HOME`.
#[cfg(feature = "flutter")]
#[test]
#[ignore = "requires a running relay and a separately started pocox host"]
fn a_fork_over_the_relay_runs_on_the_serving_host() {
    use crate::api::bridge as api;
    use crate::engine::session_engine::StartOptions;

    let required = |name: &str| std::env::var(name).unwrap_or_else(|_| panic!("{name} required"));
    let service = required("POCOX_FORK_SERVICE");
    let host_home = PathBuf::from(required("POCOX_FORK_HOST_HOME"));
    let port: u16 = required("POCOX_FORK_MODEL_PORT")
        .parse()
        .expect("model port");

    let controller = tempfile::tempdir().expect("controller");
    let controller_home = controller.path().join("codex-home");
    std::env::set_var("CODEX_HOME", &controller_home);
    api::init_bridge(controller.path().display().to_string()).expect("bridge");
    api::set_relay(required("POCOX_FORK_RELAY")).expect("relay");
    api::set_key(required("POCOX_FORK_RELAY_KEY")).expect("key");
    let endpoint = Arc::new(ModelEndpoint::default());
    runtime::runtime().block_on(async {
        let listener = TcpListener::bind(("127.0.0.1", port))
            .await
            .expect("model port");
        tokio::spawn(Arc::clone(&endpoint).serve(listener));
    });

    let deadline = Instant::now() + WAIT;
    while let Err(error) = futures::executor::block_on(api::app_connect(service.clone(), 0)) {
        assert!(Instant::now() < deadline, "no route to the host: {error:#}");
        std::thread::sleep(Duration::from_secs(1));
    }
    let engine = engine(&service);
    let source = engine
        .thread_start(&service, StartOptions {
            cwd: Some(host_home.display().to_string()),
            ..Default::default()
        })
        .expect("start on the host");
    run_turn(&service, &source, "relay-source-turn");

    let branch = fork(&service, &source, None);
    assert_eq!(branch.thread.forked_from_id.as_deref(), Some(source.as_str()));
    continue_fork(&service, &branch.thread.id, "relay-branch-turn");
    assert!(endpoint
        .request_with("relay-branch-turn")
        .contains("relay-source-turn"));

    let sessions = controller_home.join("sessions");
    assert!(rollout_of(&host_home, &branch.thread.id).exists());
    for thread in [&source, &branch.thread.id] {
        assert!(
            rollout::rollout_path_in(&sessions, thread)
                .expect("scan")
                .is_none(),
            "nothing may be written on the controller"
        );
    }
    app_session::disconnect(&service);
}
