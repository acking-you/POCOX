//! Process-global tokio runtime, support-dir, and the in-process
//! subscription registry. Mobile has no child processes / state.toml, so
//! subscriptions own SDK handles tracked here and cancelled on unsubscribe.
//!
//! Account and self-host subscriptions are the same code path: both dial the
//! relay directly and differ only in the [`RelaySession`] handed in. Account
//! mode used to need its own broker-tunnel implementation here; now the caller
//! resolves a session (via `transport::resolve`) and everything below is
//! shared.
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, LazyLock, Mutex};

use anyhow::{anyhow, Context, Result};
use once_cell::sync::OnceCell;
use pocox_core::config::ConnectionPath;
use pocox_pb::{
    subscribe_background, subscribed, Connection, RelaySession, SubscribeOptions, TunnelEvent,
};
use tokio::runtime::{Builder, Runtime};
#[cfg(test)]
use tokio::task::JoinHandle;

mod local_forward;
mod path_status;
pub use path_status::{PathStatus, TunnelHealth, TunnelPath};

use crate::engine::transport::Transport;

static RUNTIME: OnceCell<Runtime> = OnceCell::new();
static SUPPORT_DIR: OnceCell<PathBuf> = OnceCell::new();
static REGISTRY: OnceCell<Mutex<HashMap<String, SubEntry>>> = OnceCell::new();

/// A headless supervisor's overrides of the desktop app's hosting defaults.
/// Its caller has already initialized the installation identity.
pub(super) struct HostContext {
    pub device: String,
    pub profiles: PathBuf,
    pub transport: Option<Transport>,
}

static HOST_CONTEXT: OnceCell<HostContext> = OnceCell::new();

pub(super) fn configure_host(context: HostContext) -> Result<()> {
    HOST_CONTEXT
        .set(context)
        .map_err(|_| anyhow!("the managed host is already initialized"))
}

/// The device segment of every service this process publishes: the headless
/// override, else the persisted installation identity. An unreadable identity
/// fails hosting instead of publishing under a different key.
pub fn device_id() -> Result<String> {
    if let Some(context) = HOST_CONTEXT.get() {
        return Ok(context.device.clone());
    }
    if MOBILE {
        return Ok(pocox_core::service::default_device_id());
    }
    let identity = pocox_core::device::initialize(&support_dir()?.join("identity"))?;
    Ok(identity.device().to_string())
}

/// Phones never host, so they keep no installation identity.
const MOBILE: bool = cfg!(any(target_os = "ios", target_os = "android"));

pub(super) fn host_profiles_dir() -> Option<PathBuf> {
    HOST_CONTEXT.get().map(|context| context.profiles.clone())
}

pub(super) fn host_transport() -> Option<Transport> {
    HOST_CONTEXT
        .get()
        .and_then(|context| context.transport.clone())
}

/// A registered tunnel. The entry owns its worker: dropping the entry —
/// replaced, removed, or a creation that lost — stops the worker, so no
/// tunnel ever outlives its registry slot detached.
struct SubEntry {
    local_addr: String,
    owner: SubscriptionOwner,
}

enum SubscriptionOwner {
    Local {
        endpoint: super::local_services::Endpoint,
        epoch: u64,
    },
    /// A chosen port for this process's own service, for clients outside it.
    Forward(local_forward::Forward),
    Tunnel {
        connection: Arc<Connection>,
        path: ConnectionPath,
    },
    #[cfg(test)]
    Task(JoinHandle<()>),
}

#[cfg(test)]
impl Drop for SubscriptionOwner {
    fn drop(&mut self) {
        if let Self::Task(handle) = self {
            handle.abort();
        }
    }
}

impl SubEntry {
    fn status(&self, key: &str) -> SubStatus {
        match &self.owner {
            SubscriptionOwner::Local {
                endpoint,
                epoch,
            } => self
                .local_status(key, endpoint.is_current() && super::transport::is_current(*epoch)),
            SubscriptionOwner::Forward(forward) => self.local_status(key, forward.is_current()),
            SubscriptionOwner::Tunnel {
                connection,
                path,
            } => observe(key, &self.local_addr, connection, *path, true),
            #[cfg(test)]
            SubscriptionOwner::Task(task) => SubStatus {
                key: key.into(),
                local_addr: self.local_addr.clone(),
                alive: !task.is_finished(),
                ready: true,
                path: PathStatus::default(),
                health: TunnelHealth::default(),
                events: Vec::new(),
            },
        }
    }

    /// This process's own service, reached without SDK counters or phases.
    fn local_status(&self, key: &str, current: bool) -> SubStatus {
        SubStatus {
            key: key.into(),
            local_addr: self.local_addr.clone(),
            alive: current,
            ready: current,
            path: PathStatus {
                path: TunnelPath::Local,
                ..PathStatus::default()
            },
            health: TunnelHealth::default(),
            events: Vec::new(),
        }
    }
}

/// The status of `connection`, a tunnel to `key` on `local_addr`.
fn observe(
    key: &str,
    local_addr: &str,
    connection: &Connection,
    path: ConnectionPath,
    ready: bool,
) -> SubStatus {
    // One snapshot for every view: the tunnel's health is read before its
    // path counters and history are moved out of it.
    let diagnostics = connection.diagnostics();
    let health = TunnelHealth::observe(&diagnostics);
    SubStatus {
        key: key.into(),
        local_addr: local_addr.into(),
        alive: !matches!(
            connection.status(),
            pocox_pb::TunnelStatus::Stopped | pocox_pb::TunnelStatus::Failed(_)
        ),
        ready,
        path: PathStatus::observe(path, diagnostics.direct),
        health,
        events: diagnostics.events,
    }
}

/// A tunnel still coming up. It is listed with the registered ones, so its
/// first connection can be followed as it happens rather than only once it
/// is ready.
struct Coming {
    local_addr: String,
    connection: Arc<Connection>,
    path: ConnectionPath,
}

static COMING: LazyLock<Mutex<HashMap<String, Coming>>> = LazyLock::new(Mutex::default);

fn coming() -> std::sync::MutexGuard<'static, HashMap<String, Coming>> {
    COMING.lock().unwrap_or_else(|poison| poison.into_inner())
}

/// Lists a tunnel while it comes up, until this guard is dropped: once it is
/// ready (and registered) or given up.
struct ShowComing {
    key: String,
    connection: Arc<Connection>,
}

impl ShowComing {
    fn new(
        key: &str,
        local_addr: &str,
        connection: &Arc<Connection>,
        path: ConnectionPath,
    ) -> Self {
        coming().insert(key.into(), Coming {
            local_addr: local_addr.into(),
            connection: connection.clone(),
            path,
        });
        Self {
            key: key.into(),
            connection: connection.clone(),
        }
    }
}

impl Drop for ShowComing {
    fn drop(&mut self) {
        let mut coming = coming();
        // A concurrent creation for the same key may have replaced it.
        if coming
            .get(&self.key)
            .is_some_and(|shown| Arc::ptr_eq(&shown.connection, &self.connection))
        {
            coming.remove(&self.key);
        }
    }
}

/// Initialise the runtime + support dir. Idempotent; safe to call once at boot.
pub fn init(support_dir: PathBuf) -> Result<()> {
    RUNTIME
        .set(
            Builder::new_multi_thread()
                .enable_all()
                .build()
                .map_err(|e| anyhow!("building tokio runtime: {e}"))?,
        )
        .ok();
    SUPPORT_DIR.set(support_dir).ok();
    // Loaded early so local metadata names the installation before its first
    // host starts. A damaged identity only blocks hosting, never the app.
    if let Err(error) = device_id() {
        tracing::warn!(%error, "host identity unavailable; hosting is blocked until it is restored");
    }
    REGISTRY.set(Mutex::new(HashMap::new())).ok();
    Ok(())
}

/// The global runtime; panics if [`init`] was not called (a boot-order bug).
pub fn runtime() -> &'static Runtime {
    RUNTIME
        .get()
        .expect("engine::runtime::init must run before runtime()")
}

/// The configured app-support directory.
pub fn support_dir() -> Result<PathBuf> {
    SUPPORT_DIR
        .get()
        .cloned()
        .ok_or_else(|| anyhow!("bridge not initialised"))
}

fn registry() -> &'static Mutex<HashMap<String, SubEntry>> {
    REGISTRY
        .get()
        .expect("engine::runtime::init must run first")
}

/// Status of one active subscription, surfaced to the UI.
#[derive(Debug, Clone)]
pub struct SubStatus {
    /// Service key being subscribed to.
    pub key: String,
    /// Local `host:port` the subscriber listener is bound on.
    pub local_addr: String,
    /// Whether the SDK worker is still running.
    pub alive: bool,
    /// Whether it has been ready; false while it is still coming up.
    pub ready: bool,
    /// Locally observed data paths for this subscription.
    pub path: PathStatus,
    /// How its tunnel's own link to the relay is doing.
    pub health: TunnelHealth,
    /// What happened to it lately, oldest first.
    pub events: Vec<TunnelEvent>,
}

/// Track direct use of an owned service without binding or forwarding a port.
pub(crate) fn subscribe_local(
    key: String,
    endpoint: super::local_services::Endpoint,
    epoch: u64,
) -> Result<SubStatus> {
    let mut registry = registry().lock().expect("registry poisoned");
    anyhow::ensure!(
        endpoint.is_current() && super::transport::is_current(epoch),
        "the local host or connection changed; reconnect"
    );
    if let Some(entry) = registry.get(&key) {
        if let SubscriptionOwner::Local {
            endpoint: current,
            epoch: current_epoch,
        } = &entry.owner
        {
            if *current_epoch == epoch && current.same_listener(&endpoint) {
                return Ok(entry.status(&key));
            }
        }
    }
    let entry = SubEntry {
        local_addr: endpoint.address(),
        owner: SubscriptionOwner::Local {
            endpoint,
            epoch,
        },
    };
    let status = entry.status(&key);
    let old = registry.insert(key, entry);
    drop(registry);
    drop(old);
    Ok(status)
}

/// Expose this process's own `key` on `127.0.0.1:<local_port>` (`0`: any free
/// port) for clients outside the app, such as a Responses API client. The
/// port is held until [`unsubscribe_service`]; each connection reaches the
/// listener the service's host owns at the time. A live forward keeps its
/// port, like a live tunnel.
pub(crate) fn forward_local(
    key: String,
    context: super::transport::Context,
    epoch: u64,
    local_port: u16,
) -> Result<SubStatus> {
    let stale = || anyhow!("the account or relay changed; try again");
    let replaced = {
        let mut registry = registry().lock().expect("registry poisoned");
        if !super::transport::is_current(epoch) {
            return Err(stale());
        }
        if let Some(entry) = registry.get(&key) {
            if matches!(entry.owner, SubscriptionOwner::Forward(_)) {
                return Ok(entry.status(&key));
            }
        }
        // Another kind of entry (a relay tunnel, say) gives its port back first.
        registry.remove(&key)
    };
    drop(replaced);
    let (address, forward) = local_forward::Forward::bind(context, key.clone(), epoch, local_port)?;
    let entry = SubEntry {
        local_addr: address.to_string(),
        owner: SubscriptionOwner::Forward(forward),
    };
    let status = entry.status(&key);
    let mut registry = registry().lock().expect("registry poisoned");
    if !super::transport::is_current(epoch) {
        return Err(stale());
    }
    let old = registry.insert(key, entry);
    drop(registry);
    drop(old);
    Ok(status)
}

/// Retire every outgoing connection after its account/relay epoch moves.
pub(super) fn context_changed() {
    let Some(registry) = REGISTRY.get() else { return };
    let old = std::mem::take(&mut *registry.lock().expect("registry poisoned"));
    drop(old);
}

/// Start (or no-op if already live) an in-process subscription exposing
/// `key` on `127.0.0.1:<local_port>`. The registry retains the SDK handle
/// until [`unsubscribe_service`] cancels the listener and its data paths.
///
/// `local_port` may be `0` to let the OS assign a free port — needed so each
/// subscribed service gets its own port and they can coexist (a fixed shared
/// port lets only the first service bind; the rest hit the probe-bind failure
/// below). The concrete assigned port is read back from the probe and reported
/// in [`SubStatus::local_addr`]. A live subscription for `key` keeps its port.
///
/// Returns only once the tunnel is READY, so the address it reports can be
/// dialled immediately. Callers do exactly that — `app_session::connect` opens
/// a websocket to it on the next line — and a listener that is merely *about*
/// to be bound would refuse that connection nondeterministically.
/// Subscribes to `service_key`, tracked under `registry_key`,
/// for an owner that may stop being current meanwhile.
///
/// Lets a caller scope its subscription to more than the service key — the
/// ACP engine and meta include the transport context, so the same logical
/// key under another account or relay never reuses (or tears down) this
/// tunnel. [`unsubscribe_service`] takes the same `registry_key`.
///
/// `owner_current` is checked under the registry lock when the tunnel is
/// registered (and before a live one is reused): a tunnel created for an
/// owner that is gone by then is stopped instead of registered. Pair it
/// with an invalidation that makes it false *before* it unsubscribes, and
/// no tunnel of the old owner survives.
pub fn subscribe_service_as(
    registry_key: String,
    service_key: &str,
    local_port: u16,
    transport: &Transport,
    owner_current: impl Fn() -> bool,
) -> Result<SubStatus> {
    // Dialled with the transport's key shape, but tracked under the key the
    // CALLER used: the app identifies a service by its bare `pcx:` key (that is
    // what `unsubscribe_service` will be given), while the relay in account mode
    // wants the namespaced form.
    let session = transport.session.clone();
    let relay_key = transport.relay_key(service_key);
    let shown_as = registry_key.clone();
    subscribe_with(registry_key, owner_current, move || {
        spawn_subscribe(&shown_as, session, relay_key, local_port)
    })
}

/// The status of a live registered tunnel.
fn live_status(key: &str, entry: &SubEntry) -> Option<SubStatus> {
    let status = entry.status(key);
    status.alive.then_some(status)
}

/// Reuse the live tunnel of `registry_key`, or `create` one and register
/// it. Creation runs without the registry lock (it waits for the relay), so
/// two callers may both create; exactly one tunnel is registered and every
/// other one — the loser of that race, or one whose owner stopped being
/// current — is stopped before this returns.
fn subscribe_with(
    registry_key: String,
    owner_current: impl Fn() -> bool,
    create: impl FnOnce() -> Result<SubEntry>,
) -> Result<SubStatus> {
    let stale = || anyhow!("the account or relay changed while subscribing; try again");
    {
        let reg = registry().lock().expect("registry poisoned");
        if let Some(live) = reg
            .get(&registry_key)
            .and_then(|entry| live_status(&registry_key, entry))
        {
            return if owner_current() { Ok(live) } else { Err(stale()) };
        }
    }
    let created = create()?;
    let mut reg = registry().lock().expect("registry poisoned");
    if !owner_current() {
        drop(reg);
        drop(created);
        return Err(stale());
    }
    if let Some(winner) = reg
        .get(&registry_key)
        .and_then(|entry| live_status(&registry_key, entry))
    {
        drop(reg);
        drop(created);
        return Ok(winner);
    }
    let status = created.status(&registry_key);
    // A finished entry it replaces is dropped (and so stopped) here.
    let replaced = reg.insert(registry_key, created);
    drop(reg);
    drop(replaced);
    Ok(status)
}

/// Bind a local port, subscribe on it, and return once the tunnel is up.
///
/// Two things have to be true when this returns, and neither is free:
///
/// * **The port is known.** `local_port` may be `0` so each service gets its
///   own (a fixed shared port lets only the first bind), so the concrete port
///   is learned from a throwaway probe bind — which also reports "already in
///   use" here rather than letting the detached task swallow it while the UI
///   shows a live endpoint.
/// * **The listener is actually accepting.** The SDK binds inside its worker,
///   so the address is not dialable until it reports ready. Awaiting that is
///   what closes the gap; it also means a subscribe to a service nobody is
///   publishing fails HERE, with the relay's reason, instead of looking like a
///   dead endpoint.
///
/// The registry entry owns the SDK handle directly. Removing it cancels the
/// listener and every data path, including established direct sessions.
/// Until it is ready, the tunnel is listed under `shown_as`.
fn spawn_subscribe(
    shown_as: &str,
    session: RelaySession,
    key: String,
    local_port: u16,
) -> Result<SubEntry> {
    let path = session.path;
    let (local_addr, connection) = open_subscription(Some(shown_as), session, key, local_port)?;
    Ok(SubEntry {
        local_addr,
        owner: SubscriptionOwner::Tunnel {
            connection,
            path,
        },
    })
}

fn open_subscription(
    shown_as: Option<&str>,
    session: RelaySession,
    key: String,
    local_port: u16,
) -> Result<(String, Arc<Connection>)> {
    let requested = format!("127.0.0.1:{local_port}");
    let reservation = std::net::TcpListener::bind(&requested)
        .with_context(|| format!("cannot bind {requested}"))?;
    let local_addr = reservation.local_addr()?.to_string();
    drop(reservation);
    let opening = async {
        let connection = Arc::new(
            subscribe_background(&session, SubscribeOptions {
                key: key.clone(),
                local_addr: local_addr.clone(),
            })
            .await?,
        );
        let _shown = shown_as
            .map(|shown_as| ShowComing::new(shown_as, &local_addr, &connection, session.path));
        subscribed(&connection, &session, &key).await?;
        anyhow::Ok(connection)
    };
    // Giving up drops the opening future, and with it the tunnel.
    let connection = runtime()
        .block_on(async { tokio::time::timeout(subscribe_ready_timeout(), opening).await })
        .map_err(|_| {
            anyhow!(
                "the relay did not accept a subscription on `{requested}` within {}s",
                subscribe_ready_timeout().as_secs()
            )
        })??;
    Ok((local_addr, connection))
}

/// How long a subscribe waits for the tunnel to come up before giving up.
///
/// A margin over [`pocox_pb::TUNNEL_READY_TIMEOUT`], which is what the
/// SDK itself waits: this bound exists only so a wedged worker cannot hang the
/// blocking caller forever, not to pre-empt the SDK's own verdict.
const SUBSCRIBE_READY_TIMEOUT: std::time::Duration =
    pocox_pb::TUNNEL_READY_TIMEOUT.saturating_add(std::time::Duration::from_secs(5));

/// Test-only override for [`SUBSCRIBE_READY_TIMEOUT`], so a case that
/// deliberately points at nothing does not spend the full production budget
/// waiting.
#[cfg(test)]
static TEST_READY_TIMEOUT: Mutex<Option<std::time::Duration>> = Mutex::new(None);

fn subscribe_ready_timeout() -> std::time::Duration {
    #[cfg(test)]
    if let Some(over) = *TEST_READY_TIMEOUT.lock().unwrap_or_else(|p| p.into_inner()) {
        return over;
    }
    SUBSCRIBE_READY_TIMEOUT
}

/// Stop and forget the subscription for `key`. No-op if absent. The SDK
/// handle is dropped after the registry lock is released.
pub fn unsubscribe_service(key: &str) {
    let removed = registry().lock().expect("registry poisoned").remove(key);
    drop(removed);
}

/// Stop and forget every subscription whose registry key starts with
/// `prefix` (a whole family, such as the meta tunnels of every context).
/// No-op before [`init`].
pub fn unsubscribe_prefix(prefix: &str) {
    let Some(registry) = REGISTRY.get() else { return };
    let removed: Vec<SubEntry> = {
        let mut registry = registry.lock().unwrap_or_else(|poison| poison.into_inner());
        let keys: Vec<String> = registry
            .keys()
            .filter(|key| key.starts_with(prefix))
            .cloned()
            .collect();
        keys.iter().filter_map(|key| registry.remove(key)).collect()
    };
    drop(removed);
}

/// An isolated probe's tunnel. Dropping it cancels the SDK connection even
/// when a probe returns early; explicit closure also waits for its streams.
pub struct TransientSubscription {
    connection: Arc<Connection>,
}

impl TransientSubscription {
    /// Stop the probe's listener and streams before reporting completion.
    pub fn close(self) {
        if let Err(error) = runtime().block_on(self.connection.stop()) {
            tracing::warn!(%error, "closing transient relay subscription failed");
        }
    }
}

/// Open a one-off subscriber owned by the returned guard, independently of
/// every persistent connection. Call `close` after the probe to await teardown.
pub fn subscribe_transient(
    key: String,
    local_port: u16,
    transport: &Transport,
) -> Result<(String, TransientSubscription)> {
    let (address, connection) =
        open_subscription(None, transport.session.clone(), transport.relay_key(&key), local_port)?;
    Ok((address, TransientSubscription {
        connection,
    }))
}

/// Snapshot of all tracked subscriptions, those still coming up included
/// (not yet [`SubStatus::ready`]). A tunnel coming up in place of a
/// finished one is listed instead of it. None before [`init`].
pub fn list_subscriptions() -> Vec<SubStatus> {
    let Some(registry) = REGISTRY.get() else { return Vec::new() };
    let coming: Vec<SubStatus> = coming()
        .iter()
        .map(|(key, tunnel)| {
            observe(key, &tunnel.local_addr, &tunnel.connection, tunnel.path, false)
        })
        .collect();
    let mut all: Vec<SubStatus> = registry
        .lock()
        .expect("registry poisoned")
        .iter()
        .filter(|(key, _)| !coming.iter().any(|tunnel| tunnel.key == **key))
        .map(|(key, e)| e.status(key))
        .collect();
    all.extend(coming);
    all
}

/// Register a fake tunnel (tests of the code that owns tunnels).
#[cfg(test)]
pub(crate) fn insert_for_test(key: &str, handle: JoinHandle<()>) {
    registry()
        .lock()
        .expect("registry poisoned")
        .insert(key.to_string(), SubEntry {
            local_addr: "127.0.0.1:9".into(),
            owner: SubscriptionOwner::Task(handle),
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_family_of_tunnels_is_dropped_together() {
        let _serial = super::super::transport::test_serial();
        init(std::env::temp_dir()).expect("init");
        let family = "family-test\u{1f}";
        let doomed = runtime().spawn(std::future::pending::<()>());
        let kept = runtime().spawn(std::future::pending::<()>());
        insert_for_test(&format!("{family}ctx\u{1f}pcx:d:meta:n"), doomed);
        insert_for_test("family-other:pcx:d:app:n", kept);
        unsubscribe_prefix(family);
        let keys: Vec<String> = list_subscriptions().into_iter().map(|s| s.key).collect();
        assert!(keys.iter().all(|key| !key.starts_with(family)));
        assert!(keys.iter().any(|key| key == "family-other:pcx:d:app:n"));
        unsubscribe_service("family-other:pcx:d:app:n");
    }

    /// A tunnel worker that owns a real listener and says when it stopped.
    fn owned_tunnel(stopped: std::sync::Arc<std::sync::atomic::AtomicBool>) -> Result<SubEntry> {
        struct Stopped(std::sync::Arc<std::sync::atomic::AtomicBool>);
        impl Drop for Stopped {
            fn drop(&mut self) {
                self.0.store(true, std::sync::atomic::Ordering::SeqCst);
            }
        }
        let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
        let addr = listener.local_addr()?.to_string();
        let guard = Stopped(stopped);
        let handle = runtime().spawn(async move {
            let _owned = (listener, guard);
            std::future::pending::<()>().await;
        });
        Ok(SubEntry {
            local_addr: addr,
            owner: SubscriptionOwner::Task(handle),
        })
    }

    fn eventually(what: &str, done: impl Fn() -> bool) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while !done() {
            assert!(std::time::Instant::now() < deadline, "{what}");
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    fn accepts(addr: &str) -> bool {
        std::net::TcpStream::connect(addr).is_ok()
    }

    /// Two callers create the same tunnel at once (both past the "is it
    /// registered?" check). Exactly one is registered, the other's worker
    /// and listener are stopped, and invalidating the owner then closes the
    /// winner too: no created tunnel survives detached.
    #[test]
    fn concurrent_creations_register_one_tunnel_and_stop_every_other() {
        let _serial = super::super::transport::test_serial();
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::{Arc, Barrier};
        init(std::env::temp_dir()).expect("init");
        let family = "race-test\u{1f}";
        let key = format!("{family}ctx\u{1f}pcx:d:meta:n");
        let both_created = Arc::new(Barrier::new(2));
        let flags = [Arc::new(AtomicBool::new(false)), Arc::new(AtomicBool::new(false))];
        let addrs: Vec<(String, String)> = std::thread::scope(|scope| {
            let workers: Vec<_> = flags
                .iter()
                .map(|stopped| {
                    let (key, both_created, stopped) =
                        (key.clone(), both_created.clone(), stopped.clone());
                    scope.spawn(move || {
                        let mut mine = String::new();
                        let status = subscribe_with(
                            key,
                            || true,
                            || {
                                let created = owned_tunnel(stopped)?;
                                mine = created.local_addr.clone();
                                // Neither registers before both have created.
                                both_created.wait();
                                Ok(created)
                            },
                        )
                        .expect("subscribe");
                        (mine, status.local_addr)
                    })
                })
                .collect();
            workers
                .into_iter()
                .map(|w| w.join().expect("join"))
                .collect()
        });
        let winner = addrs[0].1.clone();
        assert_eq!(addrs[1].1, winner, "both callers are handed the one registered tunnel");
        let loser = if addrs[0].0 == winner { 1 } else { 0 };
        assert_ne!(addrs[loser].0, winner);
        eventually("the losing worker stops", || flags[loser].load(Ordering::SeqCst));
        assert!(!accepts(&addrs[loser].0), "the losing listener is closed");
        assert!(!flags[1 - loser].load(Ordering::SeqCst) && accepts(&winner));
        unsubscribe_prefix(family);
        eventually("the registered worker stops", || flags[1 - loser].load(Ordering::SeqCst));
        assert!(!accepts(&winner), "invalidation closes the registered listener");
    }

    /// A tunnel created for an owner that stopped being current meanwhile
    /// is stopped, not registered.
    #[test]
    fn a_tunnel_created_for_a_stale_owner_is_stopped() {
        let _serial = super::super::transport::test_serial();
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;
        init(std::env::temp_dir()).expect("init");
        let key = "stale-test\u{1f}ctx\u{1f}pcx:d:meta:n".to_string();
        let current = AtomicBool::new(true);
        let stopped = Arc::new(AtomicBool::new(false));
        let mut addr = String::new();
        let result = subscribe_with(
            key.clone(),
            || current.load(Ordering::SeqCst),
            || {
                let created = owned_tunnel(stopped.clone())?;
                addr = created.local_addr.clone();
                // The context changes while the relay is being dialled.
                current.store(false, Ordering::SeqCst);
                Ok(created)
            },
        );
        assert!(result.is_err());
        assert!(!list_subscriptions().iter().any(|s| s.key == key));
        eventually("the stale worker stops", || stopped.load(Ordering::SeqCst));
        assert!(!accepts(&addr));
    }

    /// A transport pointing at a relay that does not exist.
    ///
    /// Enough for these cases: both are about the LOCAL bind, which happens
    /// before anything dials the relay. The spawned task then fails to
    /// connect and logs, which is exactly what a real unreachable relay
    /// would do.
    fn test_transport() -> Transport {
        Transport {
            session: RelaySession::for_test("127.0.0.1:1"),
            namespace: None,
        }
    }

    #[test]
    fn subscribe_fails_fast_when_port_in_use() {
        let _serial = super::super::transport::test_serial();
        init(std::env::temp_dir()).expect("init");
        // Hold a port so the probe-bind inside subscribe_service must fail.
        let occupied = std::net::TcpListener::bind("127.0.0.1:0").expect("bind probe holder");
        let port = occupied.local_addr().expect("addr").port();

        let err = subscribe_service_as(
            "pcx:t:api:t".into(),
            "pcx:t:api:t",
            port,
            &test_transport(),
            || true,
        )
        .expect_err("port is occupied; subscribe must error, not report alive");
        assert!(err.to_string().contains("cannot bind"), "got: {err}");
        // Nothing should have been registered for the failed attempt.
        assert!(!list_subscriptions().iter().any(|s| s.key == "pcx:t:api:t"));
    }

    #[test]
    fn an_unreachable_relay_fails_instead_of_reporting_a_dead_endpoint() {
        let _serial = super::super::transport::test_serial();
        init(std::env::temp_dir()).expect("init");
        // Nothing is listening, so waiting out the production budget would just
        // make this case slow.
        *TEST_READY_TIMEOUT.lock().unwrap_or_else(|p| p.into_inner()) =
            Some(std::time::Duration::from_millis(200));
        // The contract callers rely on: a returned address is DIALABLE. Callers
        // open a websocket to it on the next line, so reporting "alive" for a
        // tunnel that never came up is worse than failing — it turns a clear relay
        // error into a nondeterministic connection refused.
        let err = subscribe_service_as(
            "pcx:t:app:down".into(),
            "pcx:t:app:down",
            0,
            &test_transport(),
            || true,
        )
        .expect_err("nothing is listening on the relay, so this cannot be ready");
        let err = err.to_string();
        assert!(
            err.contains("subscribing to the relay failed") || err.contains("did not accept"),
            "the error should name the relay, not the local bind: {err}"
        );
        // And a failed attempt must leave nothing behind for `subscriptions` to
        // show as live, or the UI would offer an endpoint that refuses.
        assert!(!list_subscriptions()
            .iter()
            .any(|s| s.key == "pcx:t:app:down"));
    }

    #[test]
    fn a_tunnel_is_listed_while_it_comes_up_and_not_once_it_gives_up() {
        let _serial = super::super::transport::test_serial();
        init(std::env::temp_dir()).expect("init");
        *TEST_READY_TIMEOUT.lock().unwrap_or_else(|p| p.into_inner()) =
            Some(std::time::Duration::from_millis(600));
        let key = "pcx:t:app:coming";
        let opening = std::thread::spawn(|| {
            subscribe_service_as(key.into(), key, 0, &test_transport(), || true)
        });
        // How the first connection goes is what a reconnect shows, so the
        // tunnel is visible before it is ready, not only after.
        let seen = (0..500).find_map(|_| {
            let seen = list_subscriptions().into_iter().find(|s| s.key == key);
            if seen.is_none() {
                std::thread::sleep(std::time::Duration::from_millis(2));
            }
            seen
        });
        let seen = seen.expect("a tunnel coming up is listed");
        assert!(seen.alive && !seen.ready, "listed as coming up: {seen:?}");
        assert!(opening.join().expect("subscribe thread").is_err());
        assert!(
            !list_subscriptions().iter().any(|s| s.key == key),
            "a tunnel given up is no longer listed"
        );
    }
}
