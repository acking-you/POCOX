//! End-to-end tests of the host-owned ACP client against the scripted mock
//! agent (`examples/mock_acp_agent.rs`), run as a real subprocess with
//! different capability profiles, plus the `/acp/v1` gateway and the
//! controller-side replica over loopback.
#![cfg(unix)]

use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use futures::StreamExt;
use pocox_host_svc::acp::{
    api,
    fold::Turn,
    spec::{self, AgentSpec},
    state::LogEntry,
    AgentHost, ClientError, GatewayClient, HostError, HostOptions, Identity, Replica, SessionStore,
    SourceId,
};
use serde_json::{json, Value};
use tokio::sync::broadcast::{self, error::RecvError};

mod gateway;
mod sessions;
mod turns;

const WAIT: Duration = Duration::from_secs(15);

/// The example binary Cargo builds next to this test.
fn mock_binary() -> PathBuf {
    let exe = std::env::current_exe().expect("test executable");
    let dir = exe
        .parent()
        .and_then(|deps| deps.parent())
        .expect("target dir");
    let mock = dir.join("examples").join("mock_acp_agent");
    assert!(
        mock.is_file(),
        "{} is missing: run the whole package test (`cargo test -p pocox-host-svc`), which builds \
         examples",
        mock.display()
    );
    mock
}

/// The mock behind a path with spaces, to prove paths are not split.
fn spaced_mock(root: &Path) -> PathBuf {
    let dir = root.join("agent dir with spaces");
    std::fs::create_dir_all(&dir).expect("dir");
    let link = dir.join("mock agent");
    if !link.exists() {
        std::os::unix::fs::symlink(mock_binary(), &link).expect("symlink");
    }
    link
}

fn spec_of(root: &Path, profile: &str, extra: &[&str]) -> (AgentSpec, PathBuf) {
    let program = spaced_mock(root);
    let mut args = vec!["--profile".to_string(), profile.to_string()];
    args.extend(extra.iter().map(|arg| arg.to_string()));
    let spec = AgentSpec {
        profile_id: format!("custom-{profile}"),
        display_name: format!("Mock {profile}"),
        program: program.to_string_lossy().into_owned(),
        args,
    };
    let resolved = spec::resolve_program(&spec.program, None, None, &[]).expect("explicit path");
    (spec, resolved)
}

/// The store a host with this invocation uses.
fn store_of(root: &Path, name: &str, spec: &AgentSpec, program: &Path) -> SessionStore {
    let state = root.join("state");
    let source = SourceId::derive(&state, program, &spec.args).expect("source");
    SessionStore::open(&state, name, source)
}

async fn host_named(
    root: &Path,
    name: &str,
    profile: &str,
    extra: &[&str],
) -> (AgentHost, Result<(), HostError>) {
    let (spec, program) = spec_of(root, profile, extra);
    AgentHost::start(HostOptions {
        store: store_of(root, name, &spec, &program),
        spec,
        program,
        path: None,
        env: Vec::new(),
        env_remove: Vec::new(),
    })
    .await
}

async fn host(root: &Path, profile: &str, extra: &[&str]) -> (AgentHost, Result<(), HostError>) {
    host_named(root, "mock", profile, extra).await
}

struct Events {
    backlog: std::collections::VecDeque<Arc<LogEntry>>,
    live: broadcast::Receiver<Arc<LogEntry>>,
}

impl Events {
    fn from(host: &AgentHost) -> Self {
        let snapshot = host.snapshot();
        let generation = snapshot["generation"].as_u64().expect("generation");
        let seq = snapshot["seq"].as_u64().expect("seq");
        let (backlog, live) = host.subscribe(generation, seq).expect("subscribe");
        Self {
            backlog: backlog.into(),
            live,
        }
    }

    async fn until(&mut self, mut pred: impl FnMut(&Value) -> bool) -> Value {
        tokio::time::timeout(WAIT, async {
            loop {
                let entry = match self.backlog.pop_front() {
                    Some(entry) => entry,
                    None => match self.live.recv().await {
                        Ok(entry) => entry,
                        // Floods outrun this observer; it only waits for
                        // events that come later.
                        Err(RecvError::Lagged(_)) => continue,
                        Err(RecvError::Closed) => panic!("event log closed"),
                    },
                };
                let body: Value = serde_json::from_str(&entry.body).expect("json");
                if pred(&body) {
                    return body;
                }
            }
        })
        .await
        .expect("expected event in time")
    }
}

fn is(kind: &'static str) -> impl FnMut(&Value) -> bool {
    move |body| body["type"] == kind
}

fn message_texts(history: &Value) -> Vec<String> {
    history["window"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|turn| turn["items"].as_array().cloned().unwrap_or_default())
        .filter(|item| item["kind"] == "agent_message")
        .map(|item| item["text"].as_str().unwrap_or("").to_string())
        .collect()
}

fn canonical(path: &Path) -> String {
    std::fs::canonicalize(path)
        .expect("canonical")
        .to_string_lossy()
        .into_owned()
}

async fn new_session(host: &AgentHost, cwd: &Path) -> String {
    host.new_session(&cwd.to_string_lossy(), None)
        .await
        .expect("session")["sessionId"]
        .as_str()
        .expect("id")
        .to_string()
}

fn outcomes_of(host: &AgentHost, turn: &str) -> Vec<Value> {
    host.snapshot()["recentTurns"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|recent| recent["turnId"] == turn)
        .map(|recent| recent["outcome"].clone())
        .collect()
}

async fn eventually(mut check: impl FnMut() -> bool, what: &str) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while !check() {
        assert!(tokio::time::Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

fn alive(pid: i32) -> bool {
    nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None).is_ok()
}

async fn serve(host: &AgentHost) -> (GatewayClient, tokio::task::JoinHandle<anyhow::Result<()>>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let addr = listener.local_addr().expect("addr");
    let server = tokio::spawn(api::serve(listener, host.clone()));
    (GatewayClient::new(&format!("http://{addr}/")).expect("client"), server)
}
