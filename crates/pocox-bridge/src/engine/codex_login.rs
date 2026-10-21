//! Official Codex sign-in from the hosting editor, without a running host.
//!
//! Codex owns its login: `account/login/start` on an app-server writes
//! `auth.json` itself. Here the app starts a private, loopback-only
//! `codex app-server` for one sign-in attempt — never published on the
//! relay — with the executable the editor chose and the official provider
//! selected (`model_provider = "openai"`, `openai_base_url` reset), so a
//! custom provider in the user's `config.toml` does not route the sign-in.
//! Before any login request, the child's effective configuration is read
//! back (`config/read`, managed layers and requirements included) and the
//! sign-in is refused, and that child stopped, unless it still routes to
//! the official account. It connects to it directly and stops exactly that
//! child when the attempt is closed (or the app quits).
//!
//! Every attempt is its own session with its own id; closing one never
//! touches another. An attempt is reserved before its child is spawned, so
//! the session limit counts attempts still opening, and quitting closes
//! admission: an attempt that finishes opening afterwards stops its own
//! child instead of registering it. A child is identified when it is
//! spawned, by process id **and** start time ([`OwnedChild`]), so a stale
//! id that the system reused, or a server someone else started on its
//! address, is never signalled; stopping one waits for that process to exit
//! (escalating to a forced stop), not merely for its port to close. Every
//! child being stopped, or whose exit was not seen, stays in the table's
//! [`Retained`] ledger — moved there under the table lock, so a quit never
//! misses it — until it exited, and takes a place in the session limit
//! meanwhile. Closing that attempt again tries exactly its child again; a
//! quit tries each again and fails while one remains or an attempt is still
//! opening at its bound. Before any login request the attempt's endpoint
//! must again be observed held by the server readiness attributed to its
//! child (a point-in-time check, not proof of who answered). Success is
//! the server's own `account/login/completed` notification for this
//! attempt's `loginId`: an `auth.json` that already existed, or an API key,
//! never proves that this sign-in succeeded.

use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Condvar, Mutex, MutexGuard},
    time::{Duration, Instant},
};

use anyhow::{anyhow, bail, Context, Result};
use pocox_codex::{
    locate_binary,
    provider_launch::{check_effective_blocking, codex_launch, CodexProviderMode, ExpectedRoute},
    spawn_ready, still_owned, ListenSpec, SpawnOptions, SpawnReport, READY_TIMEOUT,
};
use serde_json::Value;
use tokio::{sync::broadcast::error::RecvError, task::JoinHandle};

use super::{
    app_session,
    config::load_config,
    owned_child::{OwnedChild, Retained, EXIT_WAIT},
    runtime,
};

/// Prefix of the private session keys; never a relay key (`pcx:` / `pcxu:`).
const KEY_PREFIX: &str = "pcx-local-login:";

/// Most sign-in sessions open at once (each is a codex process).
const MAX_SESSIONS: usize = 4;

/// Most login completions remembered per session.
const MAX_COMPLETIONS: usize = 16;

/// How a login attempt ended, as the server announced it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Completion {
    /// The server reported success.
    pub success: bool,
    /// Its error message, when it failed.
    pub error: Option<String>,
}

type Completions = Arc<Mutex<HashMap<String, Completion>>>;

struct Private {
    key: String,
    child: Option<OwnedChild>,
    addr: String,
    completions: Completions,
    watcher: Option<JoinHandle<()>>,
}

/// How long quitting waits for attempts still opening; a quit that still
/// sees one then fails (the app stays open, and a later quit waits again).
const QUIT_WAIT: Duration = Duration::from_secs(10);

#[derive(Default)]
struct State {
    /// The app is quitting: no attempt opens any more.
    closing: bool,
    /// Attempts reserved and not yet open (their child may be starting).
    opening: HashSet<String>,
    /// Open attempts.
    open: HashMap<String, Private>,
}

/// The sign-in sessions: open ones and those still opening, and every
/// child still to be seen exiting.
struct Table {
    state: Mutex<State>,
    settled: Condvar,
    /// Children being stopped or not seen to exit, by session key. Taken
    /// inside the state lock, never around it.
    stopping: Retained,
}

impl Table {
    fn new() -> Self {
        Self {
            state: Mutex::new(State::default()),
            settled: Condvar::new(),
            stopping: Retained::new(),
        }
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Reserve attempt `id` before anything starts; counted in the limit,
    /// with every attempt still open or opening and every closed attempt
    /// whose child has not been seen to exit (each counted once).
    fn reserve(&'static self, id: &str) -> Result<Reservation> {
        // Children seen to have exited since leave first (nothing signalled).
        self.stopping.prune();
        let mut state = self.state();
        if state.closing {
            bail!("the app is quitting");
        }
        let kept = self
            .stopping
            .owners(|key| {
                let id = key.strip_prefix(KEY_PREFIX).unwrap_or(key);
                !state.open.contains_key(id) && !state.opening.contains(id)
            })
            .len();
        if state.open.len() + state.opening.len() + kept >= MAX_SESSIONS {
            bail!("too many sign-ins are open or still stopping; close one first");
        }
        state.opening.insert(id.to_string());
        Ok(Reservation {
            table: self,
            id: id.to_string(),
        })
    }

    /// Take open attempt `id` for closing, its child kept in the ledger
    /// before the entry leaves the table.
    fn take(&self, id: &str) -> Option<Private> {
        let mut state = self.state();
        let private = state.open.remove(id)?;
        if let Some(child) = private.child {
            self.stopping.hold(&private.key, child);
        }
        Some(private)
    }

    /// Close admission, take every open attempt (each child kept in the
    /// ledger first), and wait (bounded) for those still opening: each of
    /// them stops its own child through the ledger. The second value is
    /// whether none was still opening at the bound.
    fn close(&self, wait: Duration) -> (Vec<Private>, bool) {
        let mut state = self.state();
        state.closing = true;
        let open: Vec<Private> = state.open.drain().map(|(_, p)| p).collect();
        for private in &open {
            if let Some(child) = private.child {
                self.stopping.hold(&private.key, child);
            }
        }
        let deadline = Instant::now() + wait;
        while !state.opening.is_empty() {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return (open, false);
            }
            state = self
                .settled
                .wait_timeout(state, left)
                .unwrap_or_else(|p| p.into_inner())
                .0;
        }
        (open, true)
    }
}

/// One attempt being opened; released (and counted no more) when dropped,
/// which its opener does only after it stopped any child it had to (one
/// that did not exit stays in the ledger).
struct Reservation {
    table: &'static Table,
    id: String,
}

impl Reservation {
    /// Register `private` as open, unless the app quits meanwhile: then it
    /// is handed back for its opener to stop while this reservation still
    /// holds the attempt as opening.
    fn commit(&self, private: Private) -> std::result::Result<(), Private> {
        let mut state = self.table.state();
        if state.closing {
            return Err(private);
        }
        state.open.insert(self.id.clone(), private);
        Ok(())
    }
}

impl Drop for Reservation {
    fn drop(&mut self) {
        self.table.state().opening.remove(&self.id);
        self.table.settled.notify_all();
    }
}

fn table() -> &'static Table {
    static TABLE: once_cell::sync::Lazy<Table> = once_cell::sync::Lazy::new(Table::new);
    &TABLE
}

/// The open sign-in sessions.
fn sessions() -> SessionsGuard {
    SessionsGuard(table().state())
}

struct SessionsGuard(MutexGuard<'static, State>);

impl std::ops::Deref for SessionsGuard {
    type Target = HashMap<String, Private>;

    fn deref(&self) -> &Self::Target {
        &self.0.open
    }
}

impl std::ops::DerefMut for SessionsGuard {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0.open
    }
}

/// Start a private sign-in server with `binary` (`None`: the app's saved
/// codex, then `PATH`) and the upstream `proxy` for its OAuth traffic;
/// returns its session id. Inputs are checked before anything starts, and
/// no other sign-in session is touched.
pub fn open(binary: Option<String>, proxy: Option<String>) -> Result<String> {
    let proxy = trimmed(proxy);
    if let Some(p) = proxy.as_deref() {
        pocox_api_proxy::validate_proxy(p)?;
    }
    let support = runtime::support_dir()?;
    let candidate = trimmed(binary).or_else(|| load_config(&support).ok()?.codex.binary);
    let binary = locate_binary(candidate.as_deref())
        .ok_or_else(|| anyhow!("could not find the codex binary; install codex or set its path"))?;
    let official =
        codex_launch(&CodexProviderMode::Official, "sign-in", "").map_err(|e| anyhow!("{e}"))?;
    let expected = official
        .expected
        .clone()
        .context("the official route names no provider")?;
    let id = uuid::Uuid::new_v4().to_string();
    // Before the child exists, so the limit and a quit both see it. Dropped
    // only when this returns: after any child it started was stopped.
    let reservation = table().reserve(&id)?;
    let port = super::serve::free_loopback_port()?;
    let opts = SpawnOptions {
        binary: Some(binary),
        listen: ListenSpec::WebSocket {
            host: "127.0.0.1".to_string(),
            port,
        },
        extra_args: official.args,
        // Its own file: a host's tailer never shows this server's output.
        // The dot keeps it apart from every per-host log name.
        log_file: Some(support.join("codex-logs").join("codex-sign-in.private.log")),
        proxy,
    };
    let addr = format!("127.0.0.1:{port}");
    let key = format!("{KEY_PREFIX}{id}");
    let table = table();
    let report = match spawn_ready(opts, READY_TIMEOUT) {
        Ok(report) => report,
        Err(pocox_codex::SpawnReadyError::Spawn(e)) => {
            return Err(anyhow::Error::new(e).context("starting codex for sign-in"))
        },
        Err(pocox_codex::SpawnReadyError::NotReady {
            report, ..
        }) => {
            // Only what this attempt spawned; one that does not exit stays
            // in the ledger for the quit.
            if let Some(child) = OwnedChild::of_report(&report) {
                table.stopping.stop(&key, child, EXIT_WAIT);
            }
            bail!("codex did not start for sign-in; check its path and the log");
        },
    };
    if report.reused {
        // Someone else's server took the port first: never use or stop it.
        bail!("the sign-in port was taken by another codex; try again");
    }
    let child = OwnedChild::of_report(&report);
    // Before any login request: the child must still route to the official
    // account after managed configuration and requirements.
    admit(&report, &expected, child, &table.stopping, &key)?;
    let mut private = Private {
        key,
        child,
        addr,
        completions: Arc::default(),
        watcher: None,
    };
    let watched = app_session::connect_local(private.key.clone(), &private.addr)
        .and_then(|()| app_session::subscribe_events(&private.key));
    match watched {
        Ok(events) => {
            private.watcher =
                Some(runtime::runtime().spawn(watch(events, private.completions.clone())));
        },
        Err(e) => {
            stop(&table.stopping, private);
            return Err(e.context("connecting to codex for sign-in"));
        },
    }
    if let Err(private) = reservation.commit(private) {
        // The app began quitting while this attempt opened.
        stop(&table.stopping, private);
        bail!("the app is quitting");
    }
    Ok(id)
}

fn trimmed(value: Option<String>) -> Option<String> {
    value
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

/// Record every `account/login/completed` of one session.
async fn watch(
    mut events: tokio::sync::broadcast::Receiver<app_session::AppEvent>,
    completions: Completions,
) {
    loop {
        match events.recv().await {
            Ok(event) if event.kind == "account/login/completed" => {
                if let Some((login, completion)) = completion_of(&event.raw) {
                    let mut held = completions.lock().unwrap_or_else(|p| p.into_inner());
                    if held.len() >= MAX_COMPLETIONS {
                        held.clear();
                    }
                    held.insert(login, completion);
                }
            },
            Ok(_) | Err(RecvError::Lagged(_)) => {},
            Err(RecvError::Closed) => return,
        }
    }
}

/// The login id and outcome of an `account/login/completed` notification's
/// params; `None` without a login id (it then names no attempt).
fn completion_of(raw: &str) -> Option<(String, Completion)> {
    let params: Value = serde_json::from_str(raw).ok()?;
    let login = params.get("loginId")?.as_str()?.to_string();
    Some((login, Completion {
        success: params.get("success").and_then(Value::as_bool) == Some(true),
        error: params
            .get("error")
            .and_then(Value::as_str)
            .map(str::to_string),
    }))
}

/// Stop the private sign-in server `id`; nothing for any other id. A child
/// that does not exit stays in the ledger (counted against the limit) and
/// the close fails; closing `id` again tries exactly that child again, as
/// does a quit.
pub fn close(id: &str) -> Result<()> {
    close_in(table(), id)
}

fn close_in(table: &Table, id: &str) -> Result<()> {
    let exited = match table.take(id) {
        Some(private) => stop(&table.stopping, private),
        // Closed before: only the child kept for this attempt.
        None => {
            let key = format!("{KEY_PREFIX}{id}");
            table
                .stopping
                .settle(|owner| owner == key, EXIT_WAIT)
                .is_empty()
        },
    };
    if !exited {
        bail!("this sign-in's codex did not exit; close it again, or quit to try again");
    }
    Ok(())
}

/// Stop every sign-in server (app quit): no attempt opens afterwards, and
/// those still opening stop their own child. Fails, naming why, when an
/// attempt was still opening at the bound or a child did not exit: the app
/// must then not exit as if every sign-in server had stopped. Calling it
/// again tries every remaining child again.
pub fn close_all() -> Result<()> {
    close_table(table(), QUIT_WAIT)
}

fn close_table(table: &Table, wait: Duration) -> Result<()> {
    let (open, settled) = table.close(wait);
    for private in open {
        stop(&table.stopping, private);
    }
    // Every child kept so far, by this quit, an earlier one or a close
    // still running, is tried again here.
    let running = table.stopping.settle(|_| true, EXIT_WAIT).len();
    if !settled {
        bail!("a sign-in was still starting its codex; quit again in a moment");
    }
    if running > 0 {
        bail!("{running} sign-in codex process(es) did not exit");
    }
    Ok(())
}

/// Close one attempt through `stopping`; `true` once its child no longer
/// runs (otherwise it stays there).
fn stop(stopping: &Retained, private: Private) -> bool {
    if let Some(watcher) = private.watcher {
        watcher.abort();
    }
    app_session::disconnect(&private.key);
    match private.child {
        Some(child) => stopping.stop(&private.key, child, EXIT_WAIT),
        None => true,
    }
}

/// Use the sign-in server `report` launched only if its effective
/// configuration still selects the official route and its endpoint is then
/// again observed held by the server readiness attributed;
/// otherwise stop exactly `child` through `stopping` (as `key`) and fail
/// (the reason never holds a configuration value).
fn admit(
    report: &SpawnReport,
    expected: &ExpectedRoute,
    child: Option<OwnedChild>,
    stopping: &Retained,
    key: &str,
) -> Result<()> {
    let refusal = match check_effective_blocking(&report.info.listen, expected, READY_TIMEOUT) {
        Err(refusal) => refusal.to_string(),
        Ok(()) if !still_owned(report) => {
            "the sign-in port is no longer served by the codex this attempt started".to_string()
        },
        Ok(()) => return Ok(()),
    };
    let exited = child.is_none_or(|child| stopping.stop(key, child, EXIT_WAIT));
    if !exited {
        bail!("{refusal}; its codex did not exit");
    }
    bail!(refusal);
}

/// The session key of `id`, while it is open.
fn key_of(id: &str) -> Result<String> {
    sessions()
        .get(id)
        .map(|private| private.key.clone())
        .context("this sign-in was closed; open it again")
}

/// Begin the official ChatGPT login on session `id`.
pub fn login_start(id: &str) -> Result<app_session::ChatgptLoginStart> {
    app_session::login_chatgpt_start(&key_of(id)?)
}

/// What session `id`'s codex reports, and how login `login_id` ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthStatus {
    /// A credential is configured (it may predate this attempt).
    pub authenticated: bool,
    /// `chatgpt` or `apikey` when configured.
    pub method: Option<String>,
    /// How `login_id` ended, once the server announced it.
    pub completed: Option<Completion>,
}

/// The account state of session `id` and the outcome of `login_id` there.
pub fn auth_status(id: &str, login_id: Option<&str>) -> Result<AuthStatus> {
    let (key, completions) = {
        let held = sessions();
        let private = held
            .get(id)
            .context("this sign-in was closed; open it again")?;
        (private.key.clone(), private.completions.clone())
    };
    let completed = login_id.and_then(|login| {
        completions
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .get(login)
            .cloned()
    });
    let (authenticated, method) = app_session::auth_status(&key)?;
    Ok(AuthStatus {
        authenticated,
        method,
        completed,
    })
}

/// Cancel login `login_id` on session `id`.
pub fn login_cancel(id: &str, login_id: &str) -> Result<()> {
    app_session::login_cancel(&key_of(id)?, login_id)
}

/// Sign codex out through session `id`.
pub fn logout(id: &str) -> Result<()> {
    app_session::codex_logout(&key_of(id)?)
}

#[cfg(test)]
#[path = "codex_login_tests.rs"]
mod tests;
