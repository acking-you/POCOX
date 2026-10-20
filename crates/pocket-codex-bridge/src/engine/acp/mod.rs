//! Controller-side engine for `acp` services: any ACP agent hosted behind
//! the POCOX gateway (`/acp/v1`), on this device or another.
//!
//! # Ownership
//!
//! A connection belongs to one transport [`Context`] (account and relay, or
//! self-host relay and key) *and* one logical service key: the same `pcx:`
//! key under another account or relay is another service, with its own
//! client, relay subscription, capabilities and permissions. A namespaced
//! key of another account is refused. When the context changes (sign-in,
//! sign-out, another relay or key), every connection of the old one is
//! dropped, and a connection still being established then is discarded
//! instead of registered (see [`transport::epoch`]). A host this process
//! runs is reached on loopback only when it was published under the same
//! context.
//!
//! Every operation acts through one captured [`Link`] — the connection's
//! client and view — and carries the host incarnation and generation that
//! view shows, so the host refuses it if either changed. Its result is
//! applied only to that same connection, and only while it still shows that
//! host and generation: a late answer never lands in a newer connection.
//!
//! # Consistency
//!
//! One event task per connection streams events strictly after the
//! snapshot watermark. On a `reset` (generation change, replaced host
//! incarnation, replay overflow, lag) it reads a fresh snapshot, completes
//! turns that ended meanwhile with their final text and recorded outcome,
//! announces turns it had not seen begin, and rebuilds the live folds of
//! running turns from history — whose answers carry their own watermark. A
//! turn whose fold cannot be read yet stays explicitly *unsynchronized*: its
//! updates are not folded (that would start it without its prefix), and the
//! read is retried with backoff — on the next event of that turn or on a
//! timer — until it succeeds or the turn ends, which then says its items
//! could not be read. So item ids and text match the host's, without
//! duplicates, missing prefixes or invented history.
//!
//! # Health
//!
//! A connection is healthy only while its event stream is open; a snapshot
//! alone proves nothing. A refused stream (the host's stream limit) or a
//! failed one makes capabilities fall back to the conservative unnegotiated
//! set, withdraws pending permissions from view (they come back on
//! recovery) and tells the UI the host is unreachable. A local host replaced
//! under the same key (a new loopback port) ends the connection, so the next
//! connect reaches the new one. Disconnecting drops only this controller's
//! view: turns and permissions belong to the host and keep running.

mod access;
mod connection;
mod events;
#[cfg(test)]
mod live_tests;
mod native_history;
mod ops;
mod translate;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, MutexGuard, Weak},
    time::Duration,
};

pub use access::{session_access, session_open, session_release};
use anyhow::{anyhow, bail, Context as _, Result};
use futures::StreamExt;
pub use native_history::{follow_native_session, native_liveness};
use once_cell::sync::OnceCell;
pub use ops::*;
use pocket_codex_host_svc::acp::{
    client::EventStream, ClientError, GatewayClient, Identity, Replica,
};
use serde_json::Value;
use tokio::{sync::broadcast, task::JoinHandle, time::Instant};
pub use translate::app_item as native_item;

pub use self::connection::{
    connect, context_changed, disconnect, host_info, is_connected, probe_reason,
};
#[cfg(test)]
use self::connection::{disconnect_inner, is_current, register};
#[cfg(test)]
use self::events::recover;
use self::{
    connection::check_api,
    events::{event_loop, Watch},
};
use super::{
    app_session::AppEvent,
    runtime,
    session_engine::{logical_key, Capabilities},
    transport::{self, Context, Owned},
};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const EVENT_BUFFER: usize = 1024;
/// First wait before retrying an unreadable running fold.
const FOLD_RETRY: Duration = Duration::from_millis(250);
/// Longest wait between retries of an unreadable running fold.
const MAX_FOLD_RETRY: Duration = Duration::from_secs(5);

/// When an unsynchronized turn's fold is read again.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Retry {
    due: Instant,
    delay: Duration,
}

/// The controller's view of one host, kept consistent with its snapshots.
#[derive(Default)]
pub(crate) struct Shared {
    /// Host incarnation the view belongs to.
    host_id: String,
    /// Host generation the view belongs to.
    generation: u64,
    /// Host info (phase, profile, negotiated capabilities).
    info: Value,
    /// Session → running host turn.
    running: HashMap<String, String>,
    /// Session → latest session-state body.
    sessions: HashMap<String, Value>,
    /// Handle → pending permission body.
    permissions: HashMap<String, Value>,
    /// Live folds, aligned with the host's.
    live: Replica,
    /// Running turns whose fold could not be read yet: `(session, turn)`.
    unsynced: HashMap<(String, String), Retry>,
    /// Who sent the message of a running turn begun only from the host's
    /// fold (a prompt with images), until that fold is installed: `(session,
    /// turn)` → the host's `clientId`.
    senders: HashMap<(String, String), Value>,
    /// Session → oldest loaded turn (paging cursor).
    oldest: HashMap<String, String>,
    /// Native source generation of each loaded window.
    history_epochs: HashMap<String, String>,
    /// The event stream is open.
    healthy: bool,
}

impl Shared {
    /// The identity this view acts on: its host incarnation and generation.
    fn identity(&self) -> Identity {
        Identity {
            host_id: Some(self.host_id.clone()).filter(|id| !id.is_empty()),
            generation: Some(self.generation),
        }
    }

    /// Whether this view still shows `identity`.
    fn shows(&self, identity: &Identity) -> bool {
        *identity == self.identity()
    }

    /// Record that `turn`'s fold could not be read: retry later, with
    /// backoff.
    fn unreadable(&mut self, session: &str, turn: &str) {
        let key = (session.to_string(), turn.to_string());
        let delay = self
            .unsynced
            .get(&key)
            .map_or(FOLD_RETRY, |retry| (retry.delay * 2).min(MAX_FOLD_RETRY));
        self.unsynced.insert(key, Retry {
            due: Instant::now() + delay,
            delay,
        });
    }

    /// Whether `turn`'s fold may be read now: never tried, or its retry is
    /// due.
    fn may_read(&self, session: &str, turn: &str) -> bool {
        self.unsynced
            .get(&(session.to_string(), turn.to_string()))
            .is_none_or(|retry| retry.due <= Instant::now())
    }

    /// The earliest due retry.
    fn next_retry(&self) -> Option<Instant> {
        self.unsynced.values().map(|retry| retry.due).min()
    }
}

/// Registry key: transport context id and logical service key.
type Key = (String, String);

struct Conn {
    client: GatewayClient,
    tx: broadcast::Sender<AppEvent>,
    task: JoinHandle<()>,
    shared: Arc<Mutex<Shared>>,
    /// Registry key of the relay subscription this connection owns.
    subscription: Option<String>,
    /// The loopback gateway address, when this process hosts the service.
    local: Option<String>,
}

fn conns() -> MutexGuard<'static, HashMap<Key, Conn>> {
    static CONNS: OnceCell<Mutex<HashMap<Key, Conn>>> = OnceCell::new();
    CONNS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
}

pub(crate) fn lock(shared: &Mutex<Shared>) -> MutexGuard<'_, Shared> {
    shared.lock().unwrap_or_else(|poison| poison.into_inner())
}

/// Serializes connect/disconnect of one key without holding the registry
/// across network I/O.
fn lifecycle(key: &Key) -> Arc<Mutex<()>> {
    type Locks = Mutex<HashMap<Key, Weak<Mutex<()>>>>;
    static LOCKS: OnceCell<Locks> = OnceCell::new();
    let mut locks = LOCKS
        .get_or_init(Mutex::default)
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    if let Some(lock) = locks.get(key).and_then(Weak::upgrade) {
        return lock;
    }
    locks.retain(|_, lock| lock.strong_count() > 0);
    let lock = Arc::new(Mutex::new(()));
    locks.insert(key.clone(), Arc::downgrade(&lock));
    lock
}

/// The registry key of `service_key` in `context`. A namespaced key must
/// belong to the context's own account.
fn key_in(context: &Context, service_key: &str) -> Result<Key> {
    if !context.admits(service_key) {
        bail!("this service belongs to another account or relay");
    }
    let logical = logical_key(service_key)
        .ok_or_else(|| anyhow!("not a POCOX service key: {service_key}"))?;
    Ok((context.id().to_string(), logical))
}

/// The registry key of `service_key` in the current context.
fn current_key(service_key: &str) -> Result<Key> {
    let context =
        transport::current_context().ok_or_else(|| anyhow!("not connected to {service_key}"))?;
    key_in(&context, service_key)
}

fn subscription_key(key: &Key) -> String {
    format!("acp\u{1f}{}\u{1f}{}", key.0, key.1)
}

/// One connection as an operation captured it (see the module docs).
pub(crate) struct Link {
    pub(crate) client: GatewayClient,
    pub(crate) shared: Arc<Mutex<Shared>>,
    pub(crate) tx: broadcast::Sender<AppEvent>,
    key: Key,
}

impl Link {
    /// The host incarnation and generation this connection shows now.
    pub(crate) fn identity(&self) -> Identity {
        lock(&self.shared).identity()
    }

    /// Apply `commit` to this connection's view if it is still the
    /// registered connection and still shows `identity`; `None` otherwise
    /// (the answer belongs to a connection or host that is gone).
    pub(crate) fn commit<T>(
        &self,
        identity: &Identity,
        commit: impl FnOnce(&mut Shared) -> T,
    ) -> Option<T> {
        let conns = conns();
        let registered = conns
            .get(&self.key)
            .is_some_and(|conn| Arc::ptr_eq(&conn.shared, &self.shared));
        if !registered {
            return None;
        }
        let mut shared = lock(&self.shared);
        shared.shows(identity).then(|| commit(&mut shared))
    }
}

/// The current connection of `service_key`.
pub(crate) fn conn(service_key: &str) -> Result<Link> {
    let key = current_key(service_key)?;
    let conns = conns();
    let conn = conns
        .get(&key)
        .ok_or_else(|| anyhow!("not connected to {}", key.1))?;
    Ok(Link {
        client: conn.client.clone(),
        shared: conn.shared.clone(),
        tx: conn.tx.clone(),
        key,
    })
}

pub(crate) fn block<T>(
    future: impl std::future::Future<Output = Result<T, ClientError>>,
) -> Result<T> {
    runtime::runtime()
        .block_on(future)
        .map_err(|error| anyhow!("{error}"))
}

/// Subscribe to translated live events.
pub fn subscribe_events(service_key: &str) -> Result<broadcast::Receiver<AppEvent>> {
    Ok(conn(service_key)?.tx.subscribe())
}

/// Capabilities negotiated by the host's current agent generation;
/// conservative (nothing optional) until connected, healthy and ready.
pub fn capabilities(service_key: &str) -> Capabilities {
    let Ok(link) = conn(service_key) else {
        return Capabilities::acp_unnegotiated();
    };
    let shared = lock(&link.shared);
    if !shared.healthy {
        return Capabilities::acp_unnegotiated();
    }
    capabilities_of(&shared.info, shared.generation)
}

/// One slash command the agent offers: name, description and input hint.
pub struct AgentCommand {
    /// Exact name without the slash.
    pub name: String,
    /// What it does.
    pub description: String,
    /// What it takes after the name, when anything.
    pub hint: Option<String>,
}

/// The agent's slash commands, as its host last reported them (empty until
/// it is connected and ready).
pub fn commands(service_key: &str) -> Result<Vec<AgentCommand>> {
    let link = conn(service_key)?;
    let shared = lock(&link.shared);
    Ok(commands_of(&shared.info))
}

fn commands_of(info: &Value) -> Vec<AgentCommand> {
    if info["phase"]["state"] != "ready" {
        return Vec::new();
    }
    info["commands"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|command| {
            Some(AgentCommand {
                name: command["name"].as_str()?.to_string(),
                description: command["description"]
                    .as_str()
                    .unwrap_or_default()
                    .to_string(),
                hint: command["input"]["hint"].as_str().map(str::to_string),
            })
        })
        .collect()
}

/// Capabilities from a host info body.
pub fn capabilities_of(info: &Value, generation: u64) -> Capabilities {
    let mut caps = Capabilities::acp_unnegotiated();
    caps.generation = generation;
    if let Some(name) = info["profile"]["displayName"].as_str() {
        caps.provider_name = name.to_string();
    }
    if let Some(id) = info["profile"]["id"].as_str() {
        caps.profile_id = id.to_string();
    }
    caps.auth_required = info["authRequired"] == true;
    caps.external_writer_monitor = info["nativeHistory"] == true;
    let negotiated = &info["capabilities"];
    if info["phase"]["state"] == "ready" && negotiated.is_object() {
        caps.negotiated = true;
        caps.image_input = negotiated["image"] == true;
        // Only an agent that advertised the steering extension can add to a
        // running turn; others queue the input for the next turn.
        caps.steer = negotiated["steering"] == true;
        // Grok renames its own sessions (`_x.ai/session/rename`).
        caps.rename = negotiated["grok"] == true;
        // Grok's questions may each take several answers, and its account
        // reports a usage window.
        caps.question_multiple = negotiated["grok"] == true;
        caps.rate_limits = negotiated["grok"] == true;
        caps.session_config = true;
        caps.session_reopen = if negotiated["loadSession"] == true {
            "load"
        } else if negotiated["resumeSession"] == true {
            "resume"
        } else {
            "none"
        }
        .to_string();
        caps.session_list =
            if negotiated["listSessions"] == true { "agent" } else { "host" }.to_string();
        let commands = commands_of(info);
        caps.commands = !commands.is_empty();
        // Compaction is the agent's own `/compact`, sent as a turn.
        caps.compact = commands.iter().any(|command| command.name == "compact");
    }
    caps
}

#[cfg(test)]
mod tests;
