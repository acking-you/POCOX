//! Opt-in acceptance: two native Codex hosts and two ACP hosts owned by ONE
//! process, through the production `serve` / `serve_acp` / session-engine
//! paths. Ignored; run it only with `POCOX_HOSTING_LIVE_ROOT` naming a fresh
//! private fixture directory, with HOME and CODEX_HOME (and any XDG_* set)
//! inside it. The directory supplies:
//!
//! - `host-support/config.toml`: the relay configuration;
//! - `codex-path` (or `POCOX_HOSTING_LIVE_CODEX`): the installed Codex binary;
//! - `agent.json`: the ACP agent specification;
//! - `expected-models.json`: every model value the agent must advertise;
//! - `project-a/` and `project-b/`: empty disposable projects.
//!
//! No prompt is sent. Product errors (which may name the relay) go to
//! `errors.log` in the fixture, never to the test output; the sanitized
//! result is `acceptance.json`. Only the uniquely named hosts started here are
//! stopped, by name.

use std::{
    collections::HashSet,
    io::Write as _,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use pocox_core::process::pid_running;
use pocox_host_svc::acp::{AgentSpec, GatewayClient};
use serde_json::{json, Value};

use crate::engine::{
    app_session, runtime, serve, serve_acp,
    session_engine::{self, StartOptions},
    transport,
};

const WAIT: Duration = Duration::from_secs(120);

/// Fixture paths and inputs, checked before any product code runs.
struct Fixture {
    root: PathBuf,
    codex: String,
    spec: AgentSpec,
    models: Vec<String>,
}

impl Fixture {
    /// Record `error` in the fixture's log and fail without echoing it.
    fn fail(&self, step: &str, error: impl std::fmt::Display) -> ! {
        if let Ok(mut log) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.root.join("errors.log"))
        {
            let _ = writeln!(log, "{step}: {error:#}");
        }
        panic!("{step} failed; the detail is in errors.log in the fixture");
    }

    fn ok<T>(&self, step: &str, result: anyhow::Result<T>) -> T {
        result.unwrap_or_else(|error| self.fail(step, format!("{error:#}")))
    }
}

/// `var` names a directory inside `root` (required, or checked when set).
fn confined(root: &Path, var: &str, required: bool) {
    let Some(value) = std::env::var_os(var) else {
        assert!(!required, "{var} must point inside POCOX_HOSTING_LIVE_ROOT");
        return;
    };
    let path = std::fs::canonicalize(&value)
        .unwrap_or_else(|_| panic!("{var} must name an existing directory"));
    assert!(path.starts_with(root), "{var} must lie inside POCOX_HOSTING_LIVE_ROOT");
}

fn fixture() -> Fixture {
    let root = std::env::var_os("POCOX_HOSTING_LIVE_ROOT")
        .map(PathBuf::from)
        .expect("POCOX_HOSTING_LIVE_ROOT: an explicit fresh fixture directory");
    let root = std::fs::canonicalize(root).expect("the fixture root must exist");
    // macOS resolves several product paths from HOME regardless of XDG, so
    // HOME itself must be confined, before anything initializes or spawns.
    confined(&root, "HOME", true);
    confined(&root, "CODEX_HOME", true);
    for var in ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"] {
        confined(&root, var, false);
    }
    assert!(
        root.join("host-support/config.toml").is_file(),
        "host-support/config.toml is required"
    );
    assert!(!root.join("acceptance.json").exists(), "use a fresh fixture");
    for project in ["project-a", "project-b"] {
        let entries = std::fs::read_dir(root.join(project))
            .unwrap_or_else(|_| panic!("{project}/ is required"));
        assert_eq!(entries.count(), 0, "{project}/ must be empty and disposable");
    }
    let codex = std::env::var("POCOX_HOSTING_LIVE_CODEX")
        .ok()
        .unwrap_or_else(|| {
            std::fs::read_to_string(root.join("codex-path"))
                .expect("codex-path or POCOX_HOSTING_LIVE_CODEX is required")
                .trim()
                .to_string()
        });
    assert!(
        Path::new(&codex).is_absolute() && Path::new(&codex).is_file(),
        "the Codex executable must be an existing absolute path"
    );
    let spec: AgentSpec =
        serde_json::from_slice(&std::fs::read(root.join("agent.json")).expect("agent.json"))
            .expect("agent.json is an agent specification");
    let models: Vec<String> = serde_json::from_slice(
        &std::fs::read(root.join("expected-models.json")).expect("expected-models.json"),
    )
    .expect("expected-models.json is an array of model values");
    let distinct: HashSet<&String> = models.iter().collect();
    assert!(models.len() >= 2 && distinct.len() == models.len(), "two or more distinct models");
    Fixture {
        root,
        codex,
        spec,
        models,
    }
}

/// The uniquely named hosts this test owns. Dropping it (success, error or
/// panic) stops exactly those still running, by name; nothing global.
#[derive(Default)]
struct Owned {
    names: Vec<String>,
    connected: Vec<String>,
}

impl Owned {
    fn stop(&mut self, name: &str) {
        self.names.retain(|n| n != name);
        // reason: serve_stop is documented as best-effort and never fails.
        serve::serve_stop(name).expect("stop by name");
    }
}

impl Drop for Owned {
    fn drop(&mut self) {
        for key in self.connected.drain(..) {
            session_engine::engine(&key).disconnect(&key);
        }
        for name in std::mem::take(&mut self.names) {
            let _ = serve::serve_stop(&name);
        }
    }
}

fn until(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + WAIT;
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting: {what}");
        std::thread::sleep(Duration::from_millis(200));
    }
}

fn row(name: &str) -> Option<serve::ServeStatus> {
    serve::serve_status().into_iter().find(|s| s.name == name)
}

/// Wait until `name` runs with every one of its services published.
fn registered(name: &str) -> serve::ServeStatus {
    let mut found = None;
    until("every service registered", || {
        found = row(name).filter(|s| {
            s.alive
                && s.app_registered
                && s.meta_registered
                && (s.provider == "acp" || s.api_registered)
        });
        found.is_some()
    });
    found.expect("checked above")
}

/// The wire keys of `status` (what the relay lists), by service kind.
fn wire_keys(transport: &transport::Transport, status: &serve::ServeStatus) -> Vec<String> {
    [&status.app_service_key, &status.api_service_key, &status.meta_service_key]
        .into_iter()
        .filter(|key| !key.is_empty())
        .map(|key| {
            let id = session_engine::service_id_of(key).expect("a POCOX key");
            transport.key(&id)
        })
        .collect()
}

fn relay_keys(fx: &Fixture, transport: &transport::Transport) -> HashSet<String> {
    let keys = runtime::runtime().block_on(pocox_pb::keys(&transport.session));
    fx.ok("listing relay keys", keys).into_iter().collect()
}

/// The host's own description of the ACP gateway at `addr`.
fn gateway(fx: &Fixture, addr: &str) -> (GatewayClient, Value) {
    let client = GatewayClient::new(&format!("http://{addr}/"))
        .unwrap_or_else(|error| fx.fail("gateway client", error));
    let info = runtime::runtime()
        .block_on(client.info())
        .unwrap_or_else(|error| fx.fail("gateway info", error));
    (client, info)
}

/// Every value of select option `option`, groups flattened.
fn values(option: &Value) -> Vec<String> {
    let mut out = Vec::new();
    for entry in option["options"].as_array().into_iter().flatten() {
        match entry["value"].as_str() {
            Some(value) => out.push(value.to_string()),
            None => out.extend(values(entry)),
        }
    }
    out
}

fn option<'a>(settings: &'a Value, category: &str) -> Option<&'a Value> {
    settings["configOptions"]
        .as_array()?
        .iter()
        .find(|o| o["category"] == category || (category == "model" && o["id"] == "model"))
}

/// What the host itself holds for `session`: its configuration options.
fn host_settings(fx: &Fixture, client: &GatewayClient, session: &str) -> Value {
    let snapshot = runtime::runtime()
        .block_on(client.snapshot())
        .unwrap_or_else(|error| fx.fail("gateway snapshot", error));
    snapshot["sessions"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|s| s["sessionId"] == session)
        .cloned()
        .unwrap_or_else(|| fx.fail("host session state", "the session is not held"))
}

fn current(settings: &Value, category: &str) -> Option<String> {
    option(settings, category).and_then(|o| o["currentValue"].as_str().map(str::to_string))
}

/// One ACP session for `project`, prepared without a prompt, advertising
/// exactly the expected catalog.
fn prepare(fx: &Fixture, owned: &mut Owned, key: &str, project: &str) -> String {
    let engine = session_engine::engine(key);
    fx.ok("connect to the ACP host", engine.connect(key.into(), 0));
    if !owned.connected.iter().any(|k| k == key) {
        owned.connected.push(key.into());
    }
    let caps = engine.capabilities(key);
    assert!(caps.negotiated && caps.session_config, "ACP negotiated with session options");
    assert_eq!(caps.profile_id, fx.spec.profile_id);
    let cwd = fx.root.join(project).to_string_lossy().into_owned();
    let tid = fx.ok(
        "prepare an ACP session",
        engine.thread_start(key, StartOptions {
            cwd: Some(cwd),
            ..Default::default()
        }),
    );
    let settings = engine
        .session_settings(key, &tid)
        .unwrap_or_else(|| fx.fail("session settings", "none were reported"));
    full_catalog(fx, &settings);
    tid
}

/// `settings` advertise exactly the expected model values.
fn full_catalog(fx: &Fixture, settings: &Value) {
    let mut advertised = option(settings, "model")
        .map(values)
        .unwrap_or_else(|| fx.fail("model option", "the agent advertised none"));
    advertised.sort();
    let mut expected = fx.models.clone();
    expected.sort();
    if advertised != expected {
        fx.fail(
            "model catalog",
            format!("advertised {} values, expected {}", advertised.len(), expected.len()),
        );
    }
}

/// Whether the host's session listing (every page) names `session`.
fn listed_session(fx: &Fixture, client: &GatewayClient, session: &str) -> bool {
    let mut cursor: Option<String> = None;
    for _ in 0..100 {
        let page = runtime::runtime()
            .block_on(client.sessions(cursor.as_deref()))
            .unwrap_or_else(|error| fx.fail("gateway session listing", error));
        let mut sessions = page["sessions"].as_array().into_iter().flatten();
        if sessions.any(|s| s["sessionId"] == session) {
            return true;
        }
        match page["nextCursor"].as_str() {
            Some(next) if cursor.as_deref() != Some(next) => cursor = Some(next.to_string()),
            _ => return false,
        }
    }
    false
}

/// What one host showed at a baseline, which every transition of ANOTHER
/// host must leave exactly as it was.
struct Peer {
    name: String,
    listen: String,
    keys: Vec<String>,
    kind: PeerKind,
}

enum PeerKind {
    Native { pid: u32 },
    Acp { host_id: Value, generation: u64, session: String, model: String, effort: Option<String> },
}

impl Peer {
    /// Baseline of native host `name`, after a verified handshake.
    fn native(fx: &Fixture, transport: &transport::Transport, name: &str) -> Self {
        let status = registered(name);
        native_ready(fx, &status);
        Self {
            name: name.to_string(),
            listen: status.app_listen_addr.clone(),
            keys: wire_keys(transport, &status),
            kind: PeerKind::Native {
                pid: status.pid.expect("a native host has a pid"),
            },
        }
    }

    /// Baseline of ACP host `name` holding `session` with the full catalog.
    fn acp(fx: &Fixture, transport: &transport::Transport, name: &str, session: &str) -> Self {
        let status = registered(name);
        let (client, info) = gateway(fx, &status.app_listen_addr);
        assert_eq!(info["phase"]["state"], "ready", "{name}: agent ready");
        let held = host_settings(fx, &client, session);
        full_catalog(fx, &held);
        assert!(listed_session(fx, &client, session), "{name}: session listed");
        Self {
            name: name.to_string(),
            listen: status.app_listen_addr.clone(),
            keys: wire_keys(transport, &status),
            kind: PeerKind::Acp {
                host_id: info["hostId"].clone(),
                generation: info["generation"].as_u64().expect("generation"),
                session: session.to_string(),
                model: current(&held, "model").expect("a selected model"),
                effort: current(&held, "thought_level"),
            },
        }
    }

    /// The host still shows its baseline: same process or incarnation and
    /// generation, listener, readiness, published keys, and (ACP) the same
    /// session, selections and full catalog.
    fn unchanged(&self, fx: &Fixture, transport: &transport::Transport) {
        let name = &self.name;
        let status = row(name).unwrap_or_else(|| panic!("{name}: still hosted"));
        assert!(
            status.alive && status.app_registered && status.meta_registered,
            "{name}: alive and registered"
        );
        assert_eq!(status.app_listen_addr, self.listen, "{name}: same listener");
        assert_eq!(wire_keys(transport, &status), self.keys, "{name}: same keys");
        let listed = relay_keys(fx, transport);
        assert!(self.keys.iter().all(|k| listed.contains(k)), "{name}: still on the relay");
        match &self.kind {
            PeerKind::Native {
                pid,
            } => {
                assert!(status.api_registered, "{name}: API still registered");
                assert_eq!(status.pid, Some(*pid), "{name}: same process");
                native_ready(fx, &status);
            },
            PeerKind::Acp {
                host_id,
                generation,
                session,
                model,
                effort,
            } => {
                let (client, info) = gateway(fx, &self.listen);
                assert_eq!(&info["hostId"], host_id, "{name}: same host incarnation");
                assert_eq!(info["generation"].as_u64(), Some(*generation), "{name}: no restart");
                assert_eq!(info["phase"]["state"], "ready", "{name}: agent ready");
                let held = host_settings(fx, &client, session);
                full_catalog(fx, &held);
                assert!(
                    current(&held, "model").as_ref() == Some(model),
                    "{name}: model selection unchanged"
                );
                assert!(current(&held, "thought_level") == *effort, "{name}: effort unchanged");
                assert!(listed_session(fx, &client, session), "{name}: session still listed");
            },
        }
    }
}

/// Every host in `peers` is exactly as its baseline recorded it.
fn unchanged(fx: &Fixture, transport: &transport::Transport, peers: &[&Peer]) {
    for peer in peers {
        peer.unchanged(fx, transport);
    }
}

/// Wait until every key of `stopped` has left the relay.
fn withdrawn(fx: &Fixture, transport: &transport::Transport, stopped: &Peer) {
    until("stopped keys leave the relay", || {
        let listed = relay_keys(fx, transport);
        stopped.keys.iter().all(|k| !listed.contains(k))
    });
}

fn select_model(fx: &Fixture, key: &str, tid: &str, value: &str) {
    let engine = session_engine::engine(key);
    let settings = engine.session_settings(key, tid).expect("prepared session");
    let id = option(&settings, "model").expect("model option")["id"]
        .as_str()
        .expect("option id")
        .to_string();
    fx.ok("select a model", engine.set_session_config(key, tid, &id, value));
}

/// Native readiness: the real `initialize` handshake on loopback, no prompt.
fn native_ready(fx: &Fixture, status: &serve::ServeStatus) {
    if let Some(error) = app_session::probe_endpoint_error(&status.app_listen_addr) {
        fx.fail("native app-server handshake", error);
    }
    let pid = status.pid.expect("a native host has a pid");
    assert!(pid_running(pid), "the native app-server process runs");
}

#[test]
#[ignore = "requires an explicit isolated fixture, an installed Codex, a real ACP agent and relay"]
fn hosting_live_coexistence() {
    let fx = fixture();
    fx.ok("runtime init", runtime::init(fx.root.join("host-support")));
    let mut owned = Owned::default();
    // Unique per run: this pid plus the wall-clock milliseconds.
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis());
    let suffix = format!("{:x}-{stamp:x}", std::process::id());
    let [codex_a, codex_b, acp_a, acp_b] =
        ["hl-codex-a", "hl-codex-b", "hl-acp-a", "hl-acp-b"].map(|n| format!("{n}-{suffix}"));

    // The built-in engine stays disabled and records nothing.
    assert!(serve::serve_start(0, None, Some(codex_a.clone()), None, true).is_err());
    assert!(row(&codex_a).is_none());

    // 1. Four hosts at once, automatic ports, this device's own identity.
    for name in [&codex_a, &codex_b] {
        owned.names.push(name.clone());
        let started =
            serve::serve_start(0, Some(fx.codex.clone()), Some(name.clone()), None, false);
        assert!(!fx.ok("start a native host", started).reused);
    }
    for name in [&acp_a, &acp_b] {
        owned.names.push(name.clone());
        let started = serve_acp::start(Some(name.clone()), fx.spec.clone());
        assert!(!fx.ok("start an ACP host", started).reused);
    }
    let device = runtime::device_id().expect("host identity");
    let rows = [codex_a.as_str(), codex_b.as_str(), acp_a.as_str(), acp_b.as_str()].map(registered);
    for status in &rows {
        assert_eq!(status.device, device);
    }
    for status in &rows[..2] {
        assert_eq!(
            (status.provider.as_str(), status.protocol.as_str(), status.profile_id.as_deref()),
            ("codex", "codex-app-server", None)
        );
        assert!(!status.embedded);
    }
    for status in &rows[2..] {
        assert_eq!((status.provider.as_str(), status.protocol.as_str()), ("acp", "acp"));
        assert_eq!(status.profile_id.as_deref(), Some(fx.spec.profile_id.as_str()));
        assert_eq!(status.agent_phase.as_deref(), Some("ready"));
    }
    let listeners: HashSet<&String> = rows.iter().map(|s| &s.app_listen_addr).collect();
    assert_eq!(listeners.len(), 4, "four distinct session listeners");
    assert_ne!(rows[0].pid, rows[1].pid, "two native processes");
    let transport = fx.ok("resolve the transport", transport::resolve_blocking());
    let listed = relay_keys(&fx, &transport);
    for status in &rows {
        for key in wire_keys(&transport, status) {
            assert!(listed.contains(&key), "every owned service is on the relay");
        }
    }

    // 2. Native handshakes; ACP sessions with isolated model selections.
    native_ready(&fx, &rows[0]);
    native_ready(&fx, &rows[1]);
    for status in &rows[..2] {
        let reason = session_engine::engine(&status.app_service_key)
            .probe_reason(status.app_service_key.clone());
        if let Some(error) = fx.ok("probe the native service", reason) {
            fx.fail("native service probe", error);
        }
    }
    let (key_a, key_b) = (rows[2].app_service_key.clone(), rows[3].app_service_key.clone());
    let (gateway_a, info_a) = gateway(&fx, &rows[2].app_listen_addr);
    let (gateway_b, info_b) = gateway(&fx, &rows[3].app_listen_addr);
    assert_ne!(info_a["hostId"], info_b["hostId"], "two ACP host incarnations");
    let tid_a = prepare(&fx, &mut owned, &key_a, "project-a");
    let tid_b = prepare(&fx, &mut owned, &key_b, "project-b");
    let (model_a, model_b) = (fx.models[0].clone(), fx.models[fx.models.len() - 1].clone());
    select_model(&fx, &key_a, &tid_a, &model_a);
    select_model(&fx, &key_b, &tid_b, &model_b);
    assert!(
        current(&host_settings(&fx, &gateway_a, &tid_a), "model").as_ref() == Some(&model_a)
            && current(&host_settings(&fx, &gateway_b, &tid_b), "model").as_ref() == Some(&model_b),
        "isolated model selections"
    );
    // Effort only where the agent advertises it; a mode is not an effort.
    let effort = option(&host_settings(&fx, &gateway_a, &tid_a), "thought_level").map(values);
    let effort_b = current(&host_settings(&fx, &gateway_b, &tid_b), "thought_level");
    if let Some(levels) = &effort {
        let settings = session_engine::engine(&key_a)
            .session_settings(&key_a, &tid_a)
            .unwrap();
        let id = option(&settings, "thought_level").unwrap()["id"]
            .as_str()
            .unwrap()
            .to_string();
        let level = levels.last().expect("an advertised level").clone();
        fx.ok(
            "select an effort",
            session_engine::engine(&key_a).set_session_config(&key_a, &tid_a, &id, &level),
        );
        assert_eq!(current(&host_settings(&fx, &gateway_a, &tid_a), "thought_level"), Some(level));
        assert_eq!(current(&host_settings(&fx, &gateway_b, &tid_b), "thought_level"), effort_b);
    }

    // Baselines. After every transition below, each host it does not target
    // must still match its baseline; only the targeted host gets a new one,
    // once its intended transition is verified.
    let mut native_a = Peer::native(&fx, &transport, &codex_a);
    let native_b = Peer::native(&fx, &transport, &codex_b);
    let mut peer_a = Peer::acp(&fx, &transport, &acp_a, &tid_a);
    let mut peer_b = Peer::acp(&fx, &transport, &acp_b, &tid_b);

    // 3. Stop native A by name, then start it again under the same name.
    let old_pid_a = rows[0].pid.expect("pid");
    owned.stop(&codex_a);
    assert!(row(&codex_a).is_none());
    until("native A's process exits", || !pid_running(old_pid_a));
    withdrawn(&fx, &transport, &native_a);
    assert!(
        app_session::probe_endpoint_error(&native_a.listen).is_some(),
        "native A no longer answers"
    );
    unchanged(&fx, &transport, &[&native_b, &peer_a, &peer_b]);
    owned.names.push(codex_a.clone());
    let restarted =
        serve::serve_start(0, Some(fx.codex.clone()), Some(codex_a.clone()), None, false);
    assert!(!fx.ok("restart native A", restarted).reused);
    native_a = Peer::native(&fx, &transport, &codex_a);
    assert!(
        matches!(native_a.kind, PeerKind::Native { pid } if pid != old_pid_a),
        "a fresh native process"
    );
    unchanged(&fx, &transport, &[&native_b, &peer_a, &peer_b]);

    // 4. Stop ACP A by name, then recreate it: a new host incarnation (not
    // a controller reconnect), with a fresh session and the full catalog.
    session_engine::engine(&key_a).disconnect(&key_a);
    owned.connected.retain(|k| k != &key_a);
    owned.stop(&acp_a);
    assert!(row(&acp_a).is_none());
    withdrawn(&fx, &transport, &peer_a);
    assert!(runtime::runtime().block_on(gateway_a.info()).is_err(), "ACP A's gateway closed");
    unchanged(&fx, &transport, &[&native_a, &native_b, &peer_b]);

    owned.names.push(acp_a.clone());
    let restarted = serve_acp::start(Some(acp_a.clone()), fx.spec.clone());
    assert!(!fx.ok("start ACP A again", restarted).reused);
    let tid_a2 = prepare(&fx, &mut owned, &key_a, "project-a");
    assert_ne!(tid_a2, tid_a, "a new session on the recreated host");
    select_model(&fx, &key_a, &tid_a2, &model_a);
    let reopen = session_engine::engine(&key_a)
        .capabilities(&key_a)
        .session_reopen;
    let reopened_a = matches!(reopen.as_str(), "load" | "resume");
    if reopened_a {
        let listed =
            fx.ok("list ACP A sessions", session_engine::engine(&key_a).thread_list(&key_a));
        assert!(listed.iter().any(|t| t.id == tid_a), "the recreated host lists A's session");
        fx.ok("reopen A's session", session_engine::engine(&key_a).thread_resume(&key_a, &tid_a));
    }
    let recreated = Peer::acp(&fx, &transport, &acp_a, &tid_a2);
    match (&recreated.kind, &peer_a.kind) {
        (
            PeerKind::Acp {
                host_id,
                model,
                ..
            },
            PeerKind::Acp {
                host_id: old, ..
            },
        ) => {
            assert_ne!(host_id, old, "a new ACP host incarnation");
            assert!(*model == model_a, "the recreated session holds its own selection");
        },
        _ => unreachable!("ACP baselines"),
    }
    peer_a = recreated;
    unchanged(&fx, &transport, &[&native_a, &native_b, &peer_b]);

    // 4b. Restart ACP B's agent in place: the same host incarnation and
    // listener, a new generation; then the controller reconnects.
    let PeerKind::Acp {
        host_id: host_b,
        generation: generation_b,
        ..
    } = &peer_b.kind
    else {
        unreachable!("an ACP baseline")
    };
    let (host_b, generation_b) = (host_b.clone(), *generation_b);
    let caps_b = session_engine::engine(&key_b)
        .capabilities(&key_b)
        .generation;
    fx.ok("restart ACP B", serve_acp::restart(&acp_b));
    until("ACP B's new generation is ready", || {
        let info = gateway(&fx, &peer_b.listen).1;
        info["generation"].as_u64() > Some(generation_b) && info["phase"]["state"] == "ready"
    });
    assert_eq!(gateway(&fx, &peer_b.listen).1["hostId"], host_b, "same ACP B incarnation");
    unchanged(&fx, &transport, &[&native_a, &native_b, &peer_a]);
    let engine_b = session_engine::engine(&key_b);
    engine_b.disconnect(&key_b);
    fx.ok("reconnect to ACP B", engine_b.connect(key_b.clone(), 0));
    assert!(engine_b.capabilities(&key_b).generation > caps_b, "the controller sees it");
    let reopened_b =
        matches!(engine_b.capabilities(&key_b).session_reopen.as_str(), "load" | "resume");
    let session_b = if reopened_b {
        fx.ok("reopen B's session", engine_b.thread_resume(&key_b, &tid_b));
        tid_b.clone()
    } else {
        prepare(&fx, &mut owned, &key_b, "project-b")
    };
    // What the new agent process holds for the session, as the host saw it.
    let held = host_settings(&fx, &gateway_b, &session_b);
    full_catalog(&fx, &held);
    let restart_kept_model = current(&held, "model").as_ref() == Some(&model_b);
    select_model(&fx, &key_b, &session_b, &model_b);
    let restarted_b = Peer::acp(&fx, &transport, &acp_b, &session_b);
    match &restarted_b.kind {
        PeerKind::Acp {
            host_id,
            generation,
            model,
            ..
        } => {
            assert_eq!(*host_id, host_b, "same ACP B incarnation");
            assert!(*generation > generation_b, "a new ACP B generation");
            assert!(*model == model_b, "ACP B's selection reads back");
        },
        PeerKind::Native {
            ..
        } => unreachable!("an ACP baseline"),
    }
    assert_eq!(restarted_b.listen, peer_b.listen, "same ACP B listener");
    assert_eq!(restarted_b.keys, peer_b.keys, "same ACP B keys");
    peer_b = restarted_b;
    unchanged(&fx, &transport, &[&native_a, &native_b, &peer_a]);

    // 5. Stop each owned host by name: its keys go, and every host not yet
    // stopped still matches its baseline until its own stop.
    let mut remaining = vec![native_a, native_b, peer_a, peer_b];
    while let Some(peer) = remaining.pop() {
        let key = row(&peer.name).expect("still hosted").app_service_key;
        if owned.connected.contains(&key) {
            session_engine::engine(&key).disconnect(&key);
            owned.connected.retain(|k| k != &key);
        }
        owned.stop(&peer.name);
        assert!(row(&peer.name).is_none());
        if let PeerKind::Native {
            pid,
        } = peer.kind
        {
            until("the stopped native process exits", || !pid_running(pid));
        }
        withdrawn(&fx, &transport, &peer);
        unchanged(&fx, &transport, &remaining.iter().collect::<Vec<_>>());
    }
    assert!(owned.names.is_empty() && owned.connected.is_empty());

    let artifact = json!({
        "status": "passed",
        "sameProcess": true,
        "nativeHosts": 2,
        "acpHosts": 2,
        "builtInRefused": true,
        "distinctListeners": true,
        "nativeHandshakes": true,
        "advertisedModels": fx.models.len(),
        "isolatedModelSelections": true,
        "effortAdvertised": effort.is_some(),
        "nativeStopRestartByName": true,
        "acpStopRestartByName": true,
        "acpNewIncarnation": true,
        "acpRestartNewGeneration": true,
        "acpSessionReopened": {"recreated": reopened_a, "restarted": reopened_b},
        "reopenedSessionKeptModel": reopened_b && restart_kept_model,
        "newSessionAfterRecreate": true,
        "survivorsUnchangedAfterEveryTransition": true,
        "ownedKeysWithdrawnIndividually": true,
    });
    std::fs::write(
        fx.root.join("acceptance.json"),
        serde_json::to_vec_pretty(&artifact).expect("json"),
    )
    .expect("write the acceptance artifact");
}
