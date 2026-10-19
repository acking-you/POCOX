//! Native OpenCode hosting, independent of ACP and Codex. Every start, stop
//! and apply holds the shared instance lease. Records and name claims survive
//! a failed stop; only confirmed exit permits a replacement. A 2.x host on the
//! shared history with OpenCode's own configuration attaches to OpenCode's
//! background server instead of owning a server: stopping it only detaches.

use std::{
    collections::HashMap,
    net::SocketAddr,
    sync::{Arc, Mutex, MutexGuard},
    time::{Duration, Instant},
};

use anyhow::{anyhow, bail, ensure, Context, Result};
use once_cell::sync::Lazy;
use pocket_codex_core::service::{ServiceId, ServiceKind};
use pocket_codex_host_svc::{
    file_links::SessionDirResolver,
    opencode::{
        self,
        catalog::Catalog,
        host::Host,
        runtime::{Launch, Server},
        service::{Attachment, State},
    },
    process,
};
use pocket_codex_pb::Published;
use tokio::task::JoinHandle;

use super::{
    agent_tools,
    host_lease::{self, Op},
    host_profiles, host_services, hosting, runtime,
    serve::ServeStatus,
    transport,
};

#[path = "serve_opencode_registration.rs"]
mod registration;
pub(super) use registration::{deregister, reregister};

#[derive(Default)]
struct Registry {
    closing: bool,
    hosts: HashMap<String, Serving>,
}
static HOSTS: Lazy<Mutex<Registry>> = Lazy::new(Mutex::default);
fn hosts() -> MutexGuard<'static, Registry> {
    HOSTS.lock().unwrap_or_else(|error| error.into_inner())
}

#[derive(Default)]
struct Slot {
    published: Option<Published>,
    revision: u64,
}
struct Serving {
    prepared: Prepared,
    host: Host,
    pid: u32,
    device: String,
    key: String,
    meta_key: String,
    local: SocketAddr,
    meta: SocketAddr,
    tasks: [JoinHandle<()>; 2],
    /// Follows the attached background server (none when owned).
    watch: Option<JoinHandle<()>>,
    background_server: bool,
    register: Slot,
    meta_register: Slot,
    context: transport::Context,
    status: OpenCodeStatus,
    stopped: bool,
}

/// Public startup/catalog status without native credentials or private URL.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenCodeStatus {
    /// Installed executable version.
    pub version: String,
    /// Number of connected native providers.
    pub providers_connected: u32,
    /// Number of usable native models.
    pub models: u32,
    /// Captured custom default, or an authoritative native global selection.
    pub default_model: Option<String>,
    /// Visible primary agents.
    pub agents: Vec<String>,
    /// Safe catalog or lifecycle failure, if any.
    pub problem: Option<String>,
    /// The host keeps its sessions in a database of its own, not in
    /// OpenCode's default one.
    #[serde(default)]
    pub separate_history: bool,
    /// The host is attached to OpenCode's background server, which its other
    /// clients share and which keeps running when the host stops.
    #[serde(default)]
    pub background_server: bool,
}
impl OpenCodeStatus {
    fn new(
        version: String,
        catalog: Result<Catalog, opencode::host::Error>,
        default_model: Option<String>,
    ) -> Self {
        let mut out = Self {
            version,
            providers_connected: 0,
            models: 0,
            default_model,
            agents: Vec::new(),
            problem: None,
            separate_history: false,
            background_server: false,
        };
        match catalog {
            Ok(catalog) => {
                out.providers_connected =
                    u32::try_from(catalog.providers_connected).unwrap_or(u32::MAX);
                out.models = u32::try_from(catalog.models.len()).unwrap_or(u32::MAX);
                out.agents = catalog.agents.into_iter().map(|agent| agent.name).collect();
            },
            Err(error) => out.problem = Some(format!("{error:#}")),
        }
        out
    }
}

/// Native host's gateway and meta service, never its private server endpoint.
#[derive(Debug, Clone)]
pub struct Report {
    /// Canonical instance name.
    pub name: String,
    /// Logical `opencode` service key.
    pub service_key: String,
}
fn report(host: &Serving) -> Report {
    Report {
        name: host.prepared.name.clone(),
        service_key: host.key.clone(),
    }
}

/// Exact resolved launch, retained for apply rollback.
#[derive(Clone)]
pub(super) struct Prepared {
    name: String,
    launch: Launch,
    discovery_problem: Option<String>,
    pub(super) provider: host_profiles::Resolved,
    /// Launched with its own database ([`history_database`]).
    pub(super) separate_history: bool,
}
/// Running host identity and exact launch.
pub(super) struct Relaunch {
    pub(super) prepared: Prepared,
    pub(super) incarnation: String,
}
impl Prepared {
    fn default_model(&self) -> Option<String> {
        self.provider
            .endpoint
            .as_ref()
            .and_then(|endpoint| endpoint.model.clone())
    }

    pub(super) fn binary(&self) -> String {
        self.launch.program.display().to_string()
    }
}

fn launch_for(binary: Option<&str>) -> Result<Launch> {
    ensure!(
        process::hosting_supported(),
        "native OpenCode hosting is unavailable on this platform"
    );
    let path = pocket_codex_codex::external_tool_path();
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    let program = pocket_codex_host_svc::acp::spec::resolve_program(
        binary
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("opencode"),
        path.as_ref(),
        home.as_deref(),
        &[".opencode/bin"],
    )
    .map_err(|_| anyhow!("OpenCode was not found; install it or select its executable"))?;
    Ok(Launch {
        program,
        path,
        env: Vec::new(),
    })
}

/// The database file of a host that keeps its own history: in OpenCode's
/// data directory, beside its default database, named after the canonical
/// instance (so one instance keeps its history across stops and restarts).
/// `OPENCODE_DB` resolves a bare file name against that directory.
fn history_database(name: &str) -> Result<String> {
    let name = super::host_names::canonical(name)?;
    // A file name, whatever the instance name's length.
    Ok(if name.len() <= 96 {
        format!("pocket-codex-{name}.db")
    } else {
        let digest = pocket_codex_core::history_sync::digest_bytes(name.as_bytes());
        format!("pocket-codex-{}.db", &digest[..32])
    })
}

/// The running host that serves OpenCode's default database, if any: a
/// second host on it would be refused, so it keeps a history of its own.
pub(super) fn shared_history_host() -> Option<String> {
    hosts()
        .hosts
        .values()
        .find(|host| !host.prepared.separate_history)
        .map(|host| host.prepared.name.clone())
}

/// Resolve and inspect the installed external executable without starting a
/// host.
pub fn detect(binary: Option<&str>) -> Result<(String, String)> {
    let launch = launch_for(binary)?;
    let detection = runtime::runtime().block_on(launch.detect())?;
    Ok((launch.program.display().to_string(), detection.version))
}

pub(super) fn prepare(
    name: &str,
    binary: Option<&str>,
    separate_history: bool,
    provider: host_profiles::Resolved,
) -> Result<Prepared> {
    host_profiles::Engine::OpenCode
        .allows(provider.source, provider.endpoint.as_ref().map(|e| e.protocol))?;
    ensure!(
        provider.claude_env.is_empty(),
        "OpenCode uses its own native environment configuration"
    );
    let mut launch = launch_for(binary)?;
    let (environment, discovery_problem) =
        runtime::runtime().block_on(host_profiles::opencode::discover_environment(
            &provider,
            name,
            std::env::var_os("OPENCODE_CONFIG_CONTENT").as_deref(),
        ))?;
    launch.env = environment;
    if separate_history {
        // Detection, the source claim and the server all use this database.
        launch
            .env
            .push(("OPENCODE_DB".into(), history_database(name)?.into()));
    }
    let notice = runtime::runtime().block_on(launch.detect())?.notice;
    let discovery_problem = match (discovery_problem, notice) {
        (Some(problem), Some(notice)) => Some(format!("{notice} {problem}")),
        (problem, notice) => notice.or(problem),
    };
    Ok(Prepared {
        name: name.into(),
        launch,
        discovery_problem,
        provider,
        separate_history,
    })
}

pub(super) fn start_locked(
    lease: &host_lease::Lease,
    binary: Option<&str>,
    separate_history: bool,
    provider: host_profiles::Resolved,
) -> Result<Report> {
    launch_prepared(prepare(lease.name(), binary, separate_history, provider)?)
}

pub(super) fn launch_prepared(prepared: Prepared) -> Result<Report> {
    let reservation = hosting::reserve_for(&prepared.name, hosting::Provider::OpenCode)?;
    ensure!(!hosts().closing, "the app is quitting");
    // Fallible local/transport setup precedes the owned process.
    let owned = transport::resolve_owned_blocking()?;
    let device = runtime::device_id()?;
    let config = host_services::config_store()?;
    let store = host_services::host_store()?;
    let uploads = pocket_codex_core::paths::state_dir()?.join("opencode-uploads");
    let (gateway, local) = host_services::bind_loopback("OpenCode gateway")?;
    let (meta_listener, meta) = host_services::bind_loopback("OpenCode meta")?;
    let rt = runtime::runtime();
    // OpenCode's own configuration on the history its background server
    // serves: join that server rather than run a second engine on it.
    let shared =
        !prepared.separate_history && prepared.provider.source == host_profiles::Source::Inherited;
    let attached = if shared { rt.block_on(Server::attach(&prepared.launch))? } else { None };
    let service = attached
        .as_ref()
        .and_then(|server| server.service().cloned());
    // The tools are added at launch, not when the launch is prepared: an
    // apply prepares before it stops the previous host, which ends that
    // host's tokens. A shared background server gets none: OpenCode adds MCP
    // servers server-wide, so every client of it would hold this host's token.
    let mut launch = prepared.launch.clone();
    let name = &prepared.name;
    // Revoked when dropped uncommitted: any failure below.
    let tools = attached
        .is_none()
        .then(|| agent_tools::inject::hosted(name, "opencode", &format!("OpenCode · {name}")))
        .flatten()
        .and_then(|grant| {
            let inherited = std::env::var_os("OPENCODE_CONFIG_CONTENT");
            match agent_tools::inject::opencode(&grant, &mut launch.env, inherited.as_deref()) {
                Ok(()) => Some(grant),
                Err(error) => {
                    tracing::warn!("agent tools not given to OpenCode `{name}`: {error:#}");
                    None
                },
            }
        });
    let (host, pid) = rt.block_on(async {
        let server = match attached {
            Some(server) => server,
            None => Server::start(&launch).await?,
        };
        let pid = server.pid;
        Ok::<_, anyhow::Error>((Host::new(server).await?, pid))
    })?;
    let mut status = OpenCodeStatus::new(
        host.info().version,
        rt.block_on(host.catalog(None)),
        prepared.default_model(),
    );
    status.problem = status
        .problem
        .or_else(|| prepared.discovery_problem.clone());
    let gateway_host = host.clone();
    let gateway_task =
        rt.spawn(host_services::supervise("OpenCode gateway", local, gateway, move |listener| {
            let host = gateway_host.clone();
            async move { opencode::api::serve(listener, host).await }
        }));
    let meta_host = host.clone();
    let meta_task =
        rt.spawn(host_services::supervise("OpenCode meta", meta, meta_listener, move |listener| {
            let (config, store, uploads) = (config.clone(), store.clone(), uploads.clone());
            let dirs: Arc<dyn SessionDirResolver> = Arc::new(meta_host.clone());
            async move {
                pocket_codex_host_svc::serve_generic(listener, config, store, uploads, dirs).await
            }
        }));
    let name = prepared.name.clone();
    let watch =
        service.map(|service| rt.spawn(watch(name.clone(), host.info().identity.host_id, service)));
    let serving = Serving {
        key: ServiceId::new(&device, ServiceKind::OpenCode, &name).key(),
        meta_key: ServiceId::new(&device, ServiceKind::Meta, &name).key(),
        prepared,
        host,
        pid,
        device,
        local,
        meta,
        tasks: [gateway_task, meta_task],
        background_server: watch.is_some(),
        watch,
        register: Slot::default(),
        meta_register: Slot::default(),
        context: transport::Context::of(&owned.transport),
        status,
        stopped: false,
    };
    let out = report(&serving);
    let closing = {
        let mut registry = hosts();
        let closing = registry.closing;
        registry.hosts.insert(name.clone(), serving);
        closing
    };
    // From here a failed stop retains both the record and this name.
    reservation.commit();
    let publish = if closing || !transport::is_current(owned.epoch) {
        Err(anyhow!("the app is quitting or its account/relay changed during OpenCode startup"))
    } else {
        reregister(&name, "opencode").and_then(|()| reregister(&name, "meta"))
    }
    .and_then(|()| {
        ensure!(
            transport::is_current(owned.epoch) && !hosts().closing,
            "the app is quitting or its account/relay changed during OpenCode startup"
        );
        Ok(())
    });
    if let Err(error) = publish {
        stop(&name)
            .context("OpenCode startup cleanup did not confirm exit; stop this host again")?;
        return Err(error);
    }
    if let Some(grant) = tools {
        agent_tools::inject::hosted_started(&name, grant, false);
    }
    Ok(out)
}

pub(super) fn is_hosting(name: &str) -> bool {
    hosts().hosts.contains_key(name)
}
pub(super) fn relaunch(name: &str) -> Option<Relaunch> {
    hosts().hosts.get(name).map(|host| Relaunch {
        prepared: host.prepared.clone(),
        incarnation: host.host.info().identity.host_id,
    })
}

/// Under the instance lease; retain ownership and listeners if exit is
/// uncertain.
pub(super) fn retire(name: &str) -> Result<Option<Prepared>> {
    let Some(host) = ({
        let mut registry = hosts();
        registry.hosts.get_mut(name).map(|host| {
            host.stopped = true;
            host.host.clone()
        })
    }) else {
        return Ok(None);
    };
    if let Err(error) = runtime::runtime().block_on(host.stop()) {
        if let Some(host) = hosts().hosts.get_mut(name) {
            host.status.problem = Some(error.to_string());
        }
        return Err(error);
    }
    let removed = hosts().hosts.remove(name);
    let Some(host) = removed else { return Ok(None) };
    agent_tools::inject::hosted_stopped(name);
    runtime::runtime().block_on(async {
        for task in host.tasks.into_iter().chain(host.watch) {
            task.abort();
            let _ = task.await;
        }
        let withdrawals = [host.register.published, host.meta_register.published]
            .into_iter()
            .flatten()
            .map(Published::stop);
        let _ =
            tokio::time::timeout(Duration::from_secs(2), futures::future::join_all(withdrawals))
                .await;
    });
    hosting::release_for(name, hosting::Provider::OpenCode);
    Ok(Some(host.prepared))
}
pub(super) fn stop(name: &str) -> Result<()> {
    retire(name).map(drop)
}
pub(super) fn close_admission() {
    hosts().closing = true;
}
pub(super) fn stop_all(drained: bool) -> Vec<String> {
    close_admission();
    let names: Vec<_> = hosts().hosts.keys().cloned().collect();
    let mut left = Vec::new();
    for name in names {
        let wait = if drained { host_lease::LEASE_WAIT } else { Duration::ZERO };
        let result = host_lease::acquire_for_quit(&name, wait).and_then(|_lease| stop(&name));
        if let Err(error) = result {
            left.push(format!("OpenCode `{name}`: {error}"));
        }
    }
    if opencode::runtime::pending_cleanup() != 0 {
        left.push("an OpenCode startup is still stopping".into());
    }
    left
}

/// Refresh the native catalog for one exact running host. Requests and native
/// configuration reads happen outside the registry lock; a late result never
/// changes a replacement host or erases its stop failure.
pub fn refresh_catalog(name: &str) -> Result<()> {
    let name = super::host_names::canonical(name)?;
    let (host, default_model) = hosts()
        .hosts
        .get(&name)
        .filter(|host| !host.stopped)
        .map(|host| (host.host.clone(), host.prepared.default_model()))
        .ok_or_else(|| anyhow!("OpenCode host is not running"))?;
    let identity = host.info().identity;
    let status = OpenCodeStatus::new(
        host.info().version,
        runtime::runtime().block_on(host.catalog(None)),
        default_model,
    );
    let mut registry = hosts();
    let current = registry
        .hosts
        .get_mut(&name)
        .filter(|host| !host.stopped && host.host.info().identity == identity)
        .ok_or_else(|| anyhow!("OpenCode host changed during refresh"))?;
    current.status = status;
    current.status.problem = current
        .status
        .problem
        .take()
        .or_else(|| current.prepared.discovery_problem.clone());
    Ok(())
}

/// Loopback ports this process's OpenCode hosts listen on (gateway and meta).
pub(crate) fn listen_ports() -> Vec<u16> {
    hosts()
        .hosts
        .values()
        .flat_map(|host| [host.local.port(), host.meta.port()])
        .collect()
}

pub(super) fn status() -> Vec<ServeStatus> {
    registration::recover();
    hosts()
        .hosts
        .values()
        .map(|host| ServeStatus {
            name: host.prepared.name.clone(),
            device: host.device.clone(),
            pid: Some(host.pid),
            alive: !host.stopped
                && !host.tasks[0].is_finished()
                && pocket_codex_core::process::pid_running(host.pid),
            app_listen_addr: host.local.to_string(),
            app_service_key: host.key.clone(),
            app_registered: host_services::is_published(&host.register.published),
            meta_listen_addr: host.meta.to_string(),
            meta_service_key: host.meta_key.clone(),
            meta_registered: host_services::is_published(&host.meta_register.published),
            codex_binary: Some(host.prepared.binary()),
            provider: "opencode".into(),
            provider_version: Some(host.status.version.clone()),
            protocol: "opencode-http".into(),
            provider_name: "OpenCode".into(),
            config_source: Some("inherited".into()),
            config_revision: Some(host.prepared.provider.revision),
            incarnation: Some(host.host.info().identity.host_id),
            busy: host_lease::holder(&host.prepared.name).map(|op| op.label().into()),
            agent_error: host.status.problem.clone(),
            opencode: Some(OpenCodeStatus {
                separate_history: host.prepared.separate_history,
                background_server: host.background_server,
                ..host.status.clone()
            }),
            ..ServeStatus::default()
        })
        .collect()
}

const SERVICE_STOPPED: &str = "OpenCode's background server stopped. Start OpenCode, or restart \
                               this host, to start it again.";

/// Follow the background server this host attached to. When a client
/// replaced it (another version, `opencode service restart`, a changed
/// setting), the host attaches to the new one under its lease; retiring this
/// incarnation aborts this task. A stopped server is reported and left
/// stopped: only an explicit start, apply or restore starts it again.
async fn watch(name: String, incarnation: String, service: Attachment) {
    let mut gone = false;
    loop {
        tokio::time::sleep(Duration::from_secs(2)).await;
        match service.state().await {
            State::Replaced => {
                let (host, run) = (name.clone(), incarnation.clone());
                if let Ok(Err(error)) =
                    tokio::task::spawn_blocking(move || reattach(&host, &run)).await
                {
                    tracing::warn!("OpenCode `{name}` did not attach again: {error:#}");
                }
                // Still here: this incarnation was not retired (its lease
                // was busy, or it changed meanwhile).
                if relaunch(&name).is_none_or(|running| running.incarnation != incarnation) {
                    return;
                }
            },
            state if (state == State::Gone) != gone => {
                gone = !gone;
                let mut registry = hosts();
                let Some(host) = registry
                    .hosts
                    .get_mut(&name)
                    .filter(|host| host.host.info().identity.host_id == incarnation)
                else {
                    return;
                };
                if gone {
                    host.status.problem = Some(SERVICE_STOPPED.into());
                } else if host.status.problem.as_deref() == Some(SERVICE_STOPPED) {
                    host.status.problem = None;
                }
            },
            _ => {},
        }
    }
}

/// Detach from a replaced background server and attach to its successor, as
/// long as this incarnation still runs.
fn reattach(name: &str, incarnation: &str) -> Result<()> {
    let _lease = host_lease::acquire_within(name, Op::Restart, Duration::from_secs(5))?;
    ensure!(
        relaunch(name).is_some_and(|running| running.incarnation == incarnation),
        "the host changed meanwhile"
    );
    match retire(name)? {
        Some(prepared) => launch_prepared(prepared).map(drop),
        None => Ok(()),
    }
}

pub(super) fn local_gateway(logical: &str, context: &transport::Context) -> Option<String> {
    hosts()
        .hosts
        .values()
        .find(|host| host.key == logical && &host.context == context && !host.stopped)
        .map(|host| host.local.to_string())
}
pub(super) fn local_endpoints(service: &str) -> Option<(String, String)> {
    let context = transport::current_context()?;
    if !context.admits(service) {
        return None;
    }
    let logical = super::session_engine::logical_key(service)?;
    hosts()
        .hosts
        .values()
        .find(|host| host.key == logical && host.context == context && !host.stopped)
        .map(|host| (host.local.to_string(), host.meta.to_string()))
}

#[cfg(test)]
#[path = "serve_opencode_tests.rs"]
mod tests;
