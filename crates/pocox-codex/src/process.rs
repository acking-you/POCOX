//! Spawn / inspect / stop a `codex app-server` child process.
//!
//! POCOX aims to behave like a small process supervisor: it
//! resolves the user's `codex` binary, starts it with the requested
//! `--listen` URL (websocket or unix socket), captures its stdout and
//! stderr to a log file, and persists enough metadata in
//! [`pocox_core::state::RuntimeState`] for a follow-up CLI
//! invocation to attach instead of re-spawning.
//!
//! Daemonisation is intentionally minimal: we use [`std::process`] to
//! spawn and rely on the kernel to keep the child alive after the CLI
//! exits (the parent process drops the [`Child`] handle without
//! waiting). This keeps things portable and avoids depending on
//! platform-specific `daemon(3)` calls.

use std::{
    path::PathBuf,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

use chrono::Utc;
use pocox_core::{
    paths,
    process::{
        endpoint_owner_under, find_codex_app_server, pid_alive, pid_running, process_start_time,
        send_sigterm, tcp_port_open, EndpointOwner,
    },
    state::{CodexProcessInfo, RuntimeState},
};
use tracing::{debug, info, warn};

use crate::protocol::Message as _ProtocolMessage;

/// How long [`spawn`] waits for a freshly-launched app-server to start
/// listening before giving up and recording the directly-spawned PID. codex
/// usually binds in well under a second; the generous ceiling covers a cold
/// start without hanging an interactive `serve` indefinitely.
const SPAWN_RESOLVE_TIMEOUT: Duration = Duration::from_secs(15);

/// Appended to an inherited `RUST_LOG` to silence codex's per-request span
/// traffic. See [`child_log_filter`] for why this is a targeted directive
/// rather than a blanket level.
pub const SPAN_NOISE_DIRECTIVE: &str = "codex_app_server::app_server_tracing=warn";

/// Size at which a host's log file is discarded at spawn time. Matches the
/// tailer's live cap, so the bound doesn't depend on which layer noticed first
/// — see [`discard_log_if_oversized`].
pub const MAX_LOG_BYTES: u64 = 8 * 1024 * 1024;

/// The `RUST_LOG` to set on a spawned app-server, given the ambient one
/// (`None` when unset). Returns `None` to leave the child's environment alone.
///
/// Only acts when a level is already in play. codex installs its stderr layer
/// with `FmtSpan::FULL`, so at `info` or above EVERY JSON-RPC request emits a
/// full `enter` and `exit` line, each repeating the whole span field set. That
/// is not a rounding error: measured against this codex, 20 `thread/list` calls
/// wrote 45.8 MB at `RUST_LOG=info`, 66,488 of those lines being span events.
/// Silencing just that module took the same load to 113 KB — a 405× reduction —
/// with every other `info` line intact.
///
/// Hence a targeted directive rather than a blanket level: someone who exported
/// `RUST_LOG=info` wants codex's info logs, not its span bookkeeping, and a
/// blanket `warn` would throw away what they asked for. An unset `RUST_LOG`
/// needs nothing — codex's own default is already quiet (222 bytes for the same
/// load), so there is nothing to fix and no reason to start filtering.
///
/// A later directive wins in `EnvFilter`, so appending overrides a broad `info`
/// while a caller who names this module explicitly
/// (`...app_server_tracing=trace`) still loses to our append — deliberate: the
/// file this feeds only ever appends, and one run at that verbosity can cost
/// gigabytes.
///
/// Split out as a pure function so the decision is testable: mutating the
/// process-wide `RUST_LOG` from a test needs `unsafe` on this edition, and this
/// crate forbids it.
fn child_log_filter(ambient: Option<&std::ffi::OsStr>) -> Option<String> {
    // Blank is what an `unset`-by-shell-script leaves behind, and EnvFilter
    // reads it as "no directives" — same as absent. Either way codex falls back
    // to its own quiet default, so leave it be.
    let inherited = ambient.and_then(|v| v.to_str()).unwrap_or("").trim();
    if inherited.is_empty() {
        return None;
    }
    // Already asking for this module to be quiet — don't stack a duplicate.
    if inherited.contains(SPAN_NOISE_DIRECTIVE) {
        return None;
    }
    Some(format!("{inherited},{SPAN_NOISE_DIRECTIVE}"))
}

/// Delete [`log_file`] when it has grown past [`MAX_LOG_BYTES`], so the fresh
/// run appends to an empty file.
///
/// Deleted, not rotated. Nothing ever reads a byte written before the current
/// run: the tailer starts at this run's `log_offset` and only forwards appended
/// bytes, and failure diagnosis reads at most the last 16 KB / 20 lines from
/// that same offset. Keeping a `.1` generation would therefore preserve bytes
/// with no reader — on the machine that prompted this, a 4.6 GB copy on a disk
/// with 10 GB free, which is the same disk-space problem wearing a hat.
///
/// This is the second of two layers, and it covers what the other can't. A live
/// host's log is bounded by its tailer, which truncates in place every poll —
/// but the tailer only runs while the app has that host registered, and a host
/// is deliberately detached (PPID 1) and keeps writing after the app quits.
/// That unattended growth is precisely the case that produced a 4.9 GB file,
/// and this is where it gets caught: on the next launch, before the tailer
/// exists.
///
/// Removing rather than truncating is safe here specifically because no writer
/// holds the file yet — this runs before the spawn. The tailer must truncate
/// instead, since unlinking under a live child would leave it appending to a
/// deleted inode and never free the space.
///
/// Best-effort by design: a failure to remove must not stop a host from
/// starting. The worst case is the old behaviour, an oversized file.
fn discard_log_if_oversized(log_file: &std::path::Path) {
    let Ok(meta) = std::fs::metadata(log_file) else {
        return; // no file yet — nothing to discard
    };
    if meta.len() <= MAX_LOG_BYTES {
        return;
    }
    // The child that wrote it is gone (this runs before the new spawn), so
    // unlinking frees the space immediately rather than leaving a live writer
    // holding a deleted inode.
    if let Err(cause) = std::fs::remove_file(log_file) {
        tracing::debug!(?log_file, %cause, "could not discard oversized codex log");
    } else {
        tracing::info!(
            ?log_file,
            bytes = meta.len(),
            "discarded oversized codex log; it predates this run and has no reader"
        );
    }
}

/// Parse the `host`/`port` out of a `ws://host:port` listen URL. Returns
/// `None` for non-websocket transports (e.g. `unix://`), which have no TCP
/// port to probe and therefore fall back to PID-based tracking.
pub(crate) fn ws_host_port(listen_url: &str) -> Option<(String, u16)> {
    let authority = listen_url.strip_prefix("ws://")?.split('/').next()?;
    let (host, port) = authority.rsplit_once(':')?;
    Some((host.to_string(), port.parse().ok()?))
}

/// Resolve a concrete port for the `--port 0` (auto-select) case by asking the
/// OS for a free one on `host`.
///
/// codex's `--listen ws://host:0` lets the OS pick the port but never reports
/// the chosen number back to us in any readable form: the PID we spawn may be
/// an npm/node shim, and the listen URL we record would keep the literal `:0`.
/// Downstream consumers — the register tunnel's `local_addr`, status/stop, the
/// health watchdog — would then forward to / probe port 0 and fail with
/// `WSAEADDRNOTAVAIL` / "address not available". So we reserve a free port
/// ourselves: bind an ephemeral listener on `host`, read the assigned port, and
/// drop the listener so codex can bind it. There is a tiny window between
/// releasing the port and codex re-binding it, but for a freshly-assigned
/// loopback port a collision is extremely unlikely — and the in-app API-proxy /
/// meta-service listeners already reserve their ports exactly this way.
fn resolve_auto_port(host: &str) -> std::io::Result<u16> {
    use std::net::TcpListener;
    // Bind the host the caller asked for so the port is free on that interface
    // (an empty/unspecified host resolves to all interfaces, mirroring codex).
    let bind_host = match host {
        "" => "0.0.0.0",
        other => other,
    };
    let listener = TcpListener::bind((bind_host, 0))?;
    Ok(listener.local_addr()?.port())
}

/// After a spawn, poll until the listen port's socket is held by a process
/// this spawn started (the native app-server, even when it sits behind an
/// npm/node shim, see [`owner`]) and return it. A port held by anything
/// else is not this spawn's: the wait goes on (the child then usually dies
/// on its bind error). Falls back to `spawn_pid` (and no owned server) if no
/// such listener comes up within
/// [`SPAWN_RESOLVE_TIMEOUT`], so status honestly reports a server that
/// failed to start rather than silently mislabelling one.
///
/// The second value is whether that listener was observed — it feeds
/// [`SpawnReport::listener_confirmed`], so a follow-up
/// [`crate::verify_ready`] knows this wait already ran dry and shrinks its
/// own budget instead of re-waiting in full.
///
/// The full wait is cut short only when the launch has *provably* failed:
/// the direct child is gone AND this run's log already shows the
/// address-in-use bind error. A dead child alone is deliberately not enough
/// — an npm shim exits right after handing off to the native binary, which
/// may still need seconds to bind (cold start, AV scan).
fn resolve_listener_pid(
    host: &str,
    port: u16,
    listen_url: &str,
    spawn_pid: u32,
    spawned: Option<ProcessIdentity>,
    log: (&std::path::Path, u64),
) -> (u32, bool, Option<ProcessIdentity>) {
    let (log_file, log_offset) = log;
    let deadline = Instant::now() + SPAWN_RESOLVE_TIMEOUT;
    let mut next_death_check = Instant::now() + crate::readiness::DEATH_CHECK_INTERVAL;
    loop {
        if tcp_port_open(host, port) {
            if let Some(EndpointOwner::Owned {
                pid,
                started,
            }) = spawned.map(|root| owner(listen_url, root))
            {
                return (
                    pid,
                    true,
                    Some(ProcessIdentity {
                        pid,
                        started,
                    }),
                );
            }
        }
        if Instant::now() >= next_death_check {
            next_death_check = Instant::now() + crate::readiness::DEATH_CHECK_INTERVAL;
            if !pid_running(spawn_pid)
                && crate::readiness::bind_failure_logged(log_file, log_offset)
            {
                return (spawn_pid, false, None);
            }
        }
        if Instant::now() >= deadline {
            return (spawn_pid, false, None);
        }
        thread::sleep(Duration::from_millis(150));
    }
}

/// Resolve the `codex` binary: the `explicit` path if it exists, otherwise
/// `codex` on `$PATH`. Returns `None` when neither resolves, so a caller (e.g.
/// the UI) can prompt the user to point at a binary before spawning. This is
/// the same resolution [`spawn`] performs internally, exposed so the path can
/// be shown / validated without starting a process.
pub fn locate_binary(explicit: Option<&str>) -> Option<PathBuf> {
    match explicit.map(str::trim).filter(|s| !s.is_empty()) {
        Some(path) => {
            let p = PathBuf::from(path);
            p.exists().then_some(p)
        },
        None => locate_on_path(codex_child_path().as_deref()),
    }
}

fn codex_child_path() -> Option<std::ffi::OsString> {
    #[cfg(target_os = "macos")]
    {
        crate::shell_environment::child_path()
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

pub(super) fn locate_on_path(path: Option<&std::ffi::OsStr>) -> Option<PathBuf> {
    match path {
        Some(path) => which::which_in("codex", Some(path), std::env::current_dir().ok()?).ok(),
        None => which::which("codex").ok(),
    }
}

/// `codex app-server`'s `--listen` URL choices we explicitly support.
#[derive(Debug, Clone)]
pub enum ListenSpec {
    /// `unix://<path>` — UDS socket.
    UnixSocket(PathBuf),
    /// `ws://<host>:<port>` — WebSocket listener.
    WebSocket {
        /// Host the app-server should bind to.
        host: String,
        /// Port the app-server should bind to.
        port: u16,
    },
}

impl ListenSpec {
    /// Format this listen spec as the URL string accepted by
    /// `codex app-server --listen`.
    pub fn to_listen_url(&self) -> String {
        match self {
            Self::UnixSocket(path) => format!("unix://{}", path.display()),
            Self::WebSocket {
                host,
                port,
            } => format!("ws://{host}:{port}"),
        }
    }

    /// Local TCP `host:port` an external relay should connect to in
    /// order to reach this app-server. Returns `None` for unix socket
    /// transports (which can't be relayed by pb-mapper directly).
    pub fn as_socket_addr(&self) -> Option<String> {
        match self {
            Self::WebSocket {
                host,
                port,
            } => Some(format!("{host}:{port}")),
            Self::UnixSocket(_) => None,
        }
    }
}

/// Options describing how to spawn the codex app-server.
#[derive(Debug, Clone)]
pub struct SpawnOptions {
    /// Optional explicit binary path. When `None`, `codex` is looked
    /// up on `$PATH`.
    pub binary: Option<PathBuf>,

    /// `--listen` URL.
    pub listen: ListenSpec,

    /// Extra arguments passed verbatim after `app-server`.
    pub extra_args: Vec<String>,

    /// Log file path. When `None` the default location from
    /// [`paths::codex_log_file`] is used.
    pub log_file: Option<PathBuf>,

    /// Upstream proxy injected into the child's environment so codex's
    /// outbound HTTP (codex_apps MCP, model calls, plugin sync) and the
    /// model WebSocket can reach chatgpt.com. When `Some`, the proxy is
    /// written to `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` (and their
    /// lowercase variants) for the child only. When `None`, the child
    /// inherits the parent's environment untouched. The value is taken
    /// verbatim; validation is the caller's responsibility.
    pub proxy: Option<String>,
}

/// Child-only environment holding secrets (a custom provider's key read
/// through its `env_key`), for [`spawn_with_env`]. Never logged: [`Secret`]
/// redacts itself, and nothing here reaches the argument vector.
///
/// [`Secret`]: pocox_core::provider::Secret
pub type SecretEnv = [(String, pocox_core::provider::Secret)];

impl Default for SpawnOptions {
    fn default() -> Self {
        Self {
            binary: None,
            listen: ListenSpec::WebSocket {
                host: "127.0.0.1".into(),
                port: 18080,
            },
            extra_args: Vec::new(),
            log_file: None,
            proxy: None,
        }
    }
}

/// Result of [`spawn`].
#[derive(Debug, Clone)]
pub struct SpawnReport {
    /// Process info recorded in [`RuntimeState::codex`].
    pub info: CodexProcessInfo,

    /// Whether [`spawn`] reused an already-running process instead of
    /// starting a new one. When `true`, any spawn-time options (such as
    /// [`SpawnOptions::proxy`]) had no effect on the live process.
    pub reused: bool,

    /// Byte offset in [`CodexProcessInfo::log_file`] just before this spawn —
    /// the point from which this run's log lines begin (the file is opened
    /// in append mode and shared across runs). A log tailer starts here to
    /// show this process's output without replaying earlier runs.
    pub log_offset: u64,

    /// Whether [`spawn`] observed the listen endpoint actually accepting
    /// connections — an adopted live listener, or the fresh child's own
    /// server ([`Self::owned`]) coming up within the spawn-time port wait (a
    /// port served by anything else does not count). `false` means that wait
    /// already ran its full course without ever seeing a listener (the child
    /// most likely died silently during startup), so [`crate::verify_ready`]
    /// caps its own budget instead of re-waiting in full on top. Unix-socket
    /// transports have no TCP port to probe and always report `false`.
    pub listener_confirmed: bool,

    /// The process [`spawn`] started, identified right after the spawn;
    /// `None` when a running server was adopted (`reused`) or the child was
    /// already gone before its start time could be read.
    pub spawned: Option<ProcessIdentity>,

    /// The process holding the listen address's socket, when only processes
    /// this spawn started hold the sockets that address reaches:
    /// [`Self::spawned`] itself or a descendant of it (an npm/node shim's
    /// native binary), see
    /// [`pocox_core::process::endpoint_owner_under`]. A server
    /// someone else started on the same address is never named here; `None`
    /// when adopted or not attributed (and always for unix sockets).
    pub owned: Option<ProcessIdentity>,
}

/// A process by id and start time
/// ([`pocox_core::process::process_start_time`]), so a later process
/// reusing the id never matches.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProcessIdentity {
    /// Its process id.
    pub pid: u32,
    /// Its start time, only suitable for equality.
    pub started: u64,
}

impl ProcessIdentity {
    /// The process `pid` as it runs now; `None` when it does not run.
    pub fn of(pid: u32) -> Option<Self> {
        process_start_time(pid).map(|started| Self {
            pid,
            started,
        })
    }
}

/// Who holds the listening sockets connections to the websocket
/// `listen_url` reach (its address and family, applicable wildcards),
/// relative to the process `spawned` (see [`endpoint_owner_under`]);
/// `Unknown` for any other transport.
pub(crate) fn owner(listen_url: &str, spawned: ProcessIdentity) -> EndpointOwner {
    match ws_host_port(listen_url) {
        Some((_, port)) => endpoint_owner_under(port, listen_url, spawned.pid, spawned.started),
        None => EndpointOwner::Unknown,
    }
}

/// Whether the endpoint of a fresh websocket launch is, at this moment,
/// held only by the exact server it owned ([`SpawnReport::owned`]).
/// Checked again after the first requests over it. Two such checks are
/// point-in-time observations of the same holder, not proof that every
/// request between them reached it. `true` for an adopted server or a unix
/// socket, which this launch never claims; `false` without an owned server
/// or when the holder cannot be told.
pub fn still_owned(report: &SpawnReport) -> bool {
    if report.reused || ws_host_port(&report.info.listen).is_none() {
        return true;
    }
    let (Some(spawned), Some(owned)) = (report.spawned, report.owned) else {
        return false;
    };
    owner(&report.info.listen, spawned)
        == EndpointOwner::Owned {
            pid: owned.pid,
            started: owned.started,
        }
}

/// Spawn `codex app-server`, persist the resulting state and return a
/// report describing what was started.
///
/// If the previous run is still alive (PID matches and process exists)
/// the existing process is returned untouched.
pub fn spawn(opts: SpawnOptions) -> pocox_core::Result<SpawnReport> {
    spawn_with_env(opts, &[])
}

/// [`spawn`] with `secret_env` added to the child's environment only (an
/// adopted, already-running server never sees it).
pub fn spawn_with_env(
    opts: SpawnOptions,
    secret_env: &SecretEnv,
) -> pocox_core::Result<SpawnReport> {
    spawn_with_env_redacted(opts, secret_env, None)
}

/// [`spawn_with_env`] for a launch with a supplied key (`redactor` holds
/// one): the fresh child's raw stdout and stderr never reach its log file,
/// which receives only this app's fixed notices instead (see
/// [`crate::output`]). The child's output goes through pipes this process
/// reads, so it needs this process alive (an app-owned host); without a key
/// it is exactly [`spawn_with_env`].
pub fn spawn_with_env_redacted(
    mut opts: SpawnOptions,
    secret_env: &SecretEnv,
    redactor: Option<&pocox_core::redact::Redactor>,
) -> pocox_core::Result<SpawnReport> {
    let withheld = redactor.is_some_and(|r| !r.is_empty());
    let mut state = RuntimeState::load()?;

    // `--port 0` means "let the OS choose a free port". codex never reports the
    // chosen port back to us, so resolve a concrete one up front and rewrite the
    // listen spec to it. Every downstream consumer — the reuse probe below, the
    // register tunnel's `local_addr`, status/stop, the health watchdog — then
    // works against a real port instead of the literal `:0` (which otherwise
    // makes every data tunnel fail to bind).
    let auto_host = match &opts.listen {
        ListenSpec::WebSocket {
            host,
            port: 0,
        } => Some(host.clone()),
        _ => None,
    };
    if let Some(host) = auto_host {
        let port = resolve_auto_port(&host).map_err(|e| {
            pocox_core::Error::Config(format!(
                "could not reserve an auto-select (--port 0) port on `{host}`: {e}"
            ))
        })?;
        opts.listen = ListenSpec::WebSocket {
            host,
            port,
        };
    }

    let listen_url = opts.listen.to_listen_url();
    let endpoint = ws_host_port(&listen_url);

    let log_file = opts
        .log_file
        .clone()
        .map(Ok)
        .unwrap_or_else(paths::codex_log_file)?;
    // Roll BEFORE measuring: `log_offset` below is where this run's lines start,
    // and rolling afterwards would leave it pointing past the end of the new
    // (empty) file — the tailer would then wait forever for the file to reach an
    // offset it never will, showing no logs at all for this host.
    if let Some(parent) = log_file.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    discard_log_if_oversized(&log_file);
    // The byte offset where this run's log lines will begin (the file is opened
    // in append mode and shared across runs). A tailer starts here to show only
    // this process's output, not earlier runs'.
    let log_offset = std::fs::metadata(&log_file).map(|m| m.len()).unwrap_or(0);

    // Reuse an app-server that is already serving the listen port. For a
    // websocket transport "is it up" is decided by the *port*, not a recorded
    // PID: when `codex` is an npm/node shim the PID we spawned is the shim
    // (which exits) while the native binary keeps the socket. Adopting the
    // live listener — ours from a prior run, or any other codex already bound
    // there — also makes `serve` idempotent instead of launching a second
    // codex that can't bind the port and dies, leaving the "stale codex /
    // working endpoint" split that this whole function exists to avoid.
    match &endpoint {
        Some((host, port)) if tcp_port_open(host, *port) => {
            // Adopt ONLY when the listener is genuinely a `codex … app-server`
            // bound to this URL. If something else holds the port,
            // find_codex_app_server returns None: refuse rather than register a
            // foreign service as our app-server (which `serve` would publish on
            // the relay and `status` would report alive).
            let Some(pid) = find_codex_app_server(&listen_url) else {
                return Err(pocox_core::Error::Config(format!(
                    "{host}:{port} is already in use by a non-codex process; free the port or \
                     serve on a different --port"
                )));
            };
            // Keep the original start time if it's the same process we already
            // tracked; otherwise stamp now (best-effort for an adopted one).
            let started_at = state
                .codex
                .as_ref()
                .filter(|c| c.pid == pid)
                .map(|c| c.started_at.clone())
                .unwrap_or_else(|| Utc::now().to_rfc3339());
            let info = CodexProcessInfo {
                pid,
                listen: listen_url,
                log_file,
                started_at,
            };
            state.codex = Some(info.clone());
            state.save()?;
            info!(pid, %host, port, "adopting codex app-server already on the listen port");
            return Ok(SpawnReport {
                info,
                reused: true,
                log_offset,
                listener_confirmed: true,
                spawned: None,
                owned: None,
            });
        },
        // Unix-socket transport has no TCP port to probe — keep PID-based
        // reuse (the shim problem is websocket-specific).
        None => {
            if let Some(existing) = state.codex.clone() {
                if pid_alive(existing.pid) {
                    info!(pid = existing.pid, listen = %existing.listen, "codex already running");
                    return Ok(SpawnReport {
                        info: existing,
                        reused: true,
                        log_offset,
                        listener_confirmed: false,
                        spawned: None,
                        owned: None,
                    });
                }
                warn!(stale_pid = existing.pid, "previous codex process is gone, restarting");
            }
        },
        // Websocket port is free → fall through and spawn a fresh app-server.
        Some(_) => {
            if let Some(existing) = state.codex.as_ref() {
                warn!(stale_pid = existing.pid, "recorded codex is no longer serving, restarting");
            }
        },
    }

    let child_path = codex_child_path();
    let binary = match opts.binary.as_ref() {
        Some(path) => path.clone(),
        None => locate_on_path(child_path.as_deref()).ok_or_else(|| {
            pocox_core::Error::Config(
                "could not locate `codex` on $PATH; install codex or pass --codex-binary"
                    .to_string(),
            )
        })?,
    };

    if let Some(parent) = log_file.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let log_handle = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_file)?;
    let log_handle_dup = log_handle.try_clone()?;

    debug!(?binary, %listen_url, ?log_file, "spawning codex app-server");

    let mut command = build_command(
        &binary,
        &listen_url,
        &opts.extra_args,
        opts.proxy.as_deref(),
        child_path.as_deref(),
    );
    for (key, value) in secret_env {
        command.env(key, value.expose());
    }
    command.stdin(Stdio::null());
    match withheld {
        true => command.stdout(Stdio::piped()).stderr(Stdio::piped()),
        false => command
            .stdout(Stdio::from(log_handle.try_clone()?))
            .stderr(Stdio::from(log_handle_dup.try_clone()?)),
    };
    let mut child = command.spawn().map_err(|e| {
        pocox_core::Error::Config(format!("failed to spawn `{}`: {e}", binary.display()))
    })?;
    if withheld {
        // Only this app's own notices reach the log (see `crate::output`).
        let piped = [
            child
                .stdout
                .take()
                .map(|out| crate::output::pump(out, log_handle, true)),
            child
                .stderr
                .take()
                .map(|err| crate::output::pump(err, log_handle_dup, false)),
        ];
        if piped.contains(&Some(false)) {
            warn!("could not read codex output; a stream of it is discarded");
        }
    }

    let spawn_pid = child.id();
    // The identity of exactly this child, read while its handle is held: the
    // only process (with its descendants) this spawn may later call its own.
    let spawned = ProcessIdentity::of(spawn_pid);
    // Drop the Child handle so the kernel keeps the process alive after this
    // CLI exits; we track it by pid from now on.
    drop(child);

    // The PID we just spawned may be a throwaway shim. Wait for the listener to
    // come up and record the PID that actually owns it, so status/stop target
    // the real app-server rather than a wrapper that has already exited.
    let (pid, listener_confirmed, owned) = match &endpoint {
        Some((host, port)) => resolve_listener_pid(
            host,
            *port,
            &listen_url,
            spawn_pid,
            spawned,
            (&log_file, log_offset),
        ),
        None => (spawn_pid, false, None),
    };

    let info = CodexProcessInfo {
        pid,
        listen: listen_url,
        log_file,
        started_at: Utc::now().to_rfc3339(),
    };
    state.codex = Some(info.clone());
    state.save()?;

    info!(pid, listen = %info.listen, "codex app-server spawned");
    Ok(SpawnReport {
        info,
        reused: false,
        log_offset,
        listener_confirmed,
        spawned,
        owned,
    })
}

/// Build the `codex app-server` [`Command`] without spawning it or
/// touching stdio / on-disk state.
///
/// When `proxy` is `Some`, the proxy URL is injected into the child's
/// environment under `HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` (and
/// their lowercase variants) so codex's reqwest client and WebSocket
/// tunnel both pick it up — neither reads codex's own `config.toml` for
/// proxy settings, they only honour the process environment. As a
/// defensive default we also seed `NO_PROXY` with the loopback hosts so
/// the proxy never swallows codex's local app-server traffic, but only
/// when the parent did not already provide one (we never override an
/// inherited value). `child_path` supplies a resolved macOS login-shell PATH
/// for this child only; no process-global environment is changed.
pub(super) fn build_command(
    binary: &std::path::Path,
    listen_url: &str,
    extra_args: &[String],
    proxy: Option<&str>,
    child_path: Option<&std::ffi::OsStr>,
) -> Command {
    let mut command = Command::new(binary);
    if let Some(path) = child_path {
        command.env("PATH", path);
    }
    // The bundled binary IS the app-server (`codex-app-server --listen …`),
    // whereas an external `codex` exposes it as a subcommand (`codex app-server
    // --listen …`). Distinguish by file name so either can be spawned uniformly.
    let is_standalone = binary
        .file_stem()
        .and_then(|s| s.to_str())
        .is_some_and(|s| s.starts_with("codex-app-server"));
    if !is_standalone {
        command.arg("app-server");
    }
    command.arg("--listen").arg(listen_url).args(extra_args);

    if let Some(raw) = proxy {
        // Set both cases so platforms/libraries that read either form agree.
        // On Windows env keys are case-insensitive, so the two writes simply
        // collapse to one entry with the same value — harmless.
        for key in
            ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]
        {
            command.env(key, raw);
        }
        let inherits_no_proxy =
            std::env::var_os("NO_PROXY").is_some() || std::env::var_os("no_proxy").is_some();
        if !inherits_no_proxy {
            command.env("NO_PROXY", "localhost,127.0.0.1,::1");
            command.env("no_proxy", "localhost,127.0.0.1,::1");
        }
    }

    // Keep an inherited RUST_LOG from turning the host's log file into gigabytes
    // of span bookkeeping. We redirect this child's stdout/stderr into a file
    // that only ever appends, so a verbosity that is merely noisy in a terminal
    // is a disk-space problem here. See `child_log_filter` for the measurements.
    if let Some(filter) = child_log_filter(std::env::var_os("RUST_LOG").as_deref()) {
        command.env("RUST_LOG", filter);
    }

    // Windows: `codex` is typically an npm shim (codex.cmd → node), and a
    // windowless GUI parent (the Flutter desktop app) launching a console child
    // makes Windows allocate a visible black console window that stays open for
    // the child's lifetime — and closing it would kill codex. CREATE_NO_WINDOW
    // suppresses that console while leaving the child fully functional; its
    // stdout/stderr are already redirected to the log file by the caller, so no
    // output is lost. `creation_flags` is a safe call (no `unsafe` needed), so
    // the crate's `#![forbid(unsafe_code)]` still holds. This is the single
    // command-construction site, so every spawn path (in-app host, watchdog
    // respawn, CLI serve) inherits the fix.
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }

    command
}

/// Snapshot of the current supervised process.
#[derive(Debug, Clone)]
pub struct StatusReport {
    /// Recorded info, with the observed native PID when it can be identified.
    pub recorded: Option<CodexProcessInfo>,
    /// Whether the supervised native process is still alive.
    pub alive: bool,
}

/// Inspect the persisted state and report whether the supervised
/// process is still running.
pub fn status() -> pocox_core::Result<StatusReport> {
    let mut state = RuntimeState::load()?;
    // "Alive" is whether a real codex app-server is serving the listen URL —
    // not merely whether the recorded PID exists (it may be a shim that exited
    // while the native binary keeps the socket) nor whether *anything* holds
    // the port (a foreign process must not read as our app-server). For
    // websocket transports require a `codex … app-server` bound to the URL;
    // fall back to the PID for unix sockets.
    let alive = state.codex.as_mut().is_some_and(|c| {
        if ws_host_port(&c.listen).is_some() {
            if let Some(pid) = find_codex_app_server(&c.listen) {
                c.pid = pid;
                true
            } else {
                false
            }
        } else {
            pid_alive(c.pid)
        }
    });
    Ok(StatusReport {
        recorded: state.codex,
        alive,
    })
}

/// Outcome of [`stop`].
#[derive(Debug, Clone)]
pub enum StopOutcome {
    /// Nothing to do — there was no recorded process.
    NoRecord,
    /// Previous process was already gone; state was cleaned up.
    StaleRecord {
        /// Pid we cleaned up.
        pid: u32,
    },
    /// Successfully sent the signal and removed the recorded state.
    Stopped {
        /// Pid we signalled.
        pid: u32,
    },
}

/// Send `SIGTERM` to the supervised process and clear the recorded
/// state.
pub fn stop() -> pocox_core::Result<StopOutcome> {
    let mut state = RuntimeState::load()?;
    let Some(info) = state.codex.take() else {
        return Ok(StopOutcome::NoRecord);
    };

    // Target the process that actually owns the listen port — that's the real
    // app-server, which differs from the recorded PID when codex was launched
    // through a shim (killing the recorded shim PID would never free the port).
    // Fall back to the recorded PID for unix sockets or when the port is idle.
    let target = ws_host_port(&info.listen)
        .filter(|(host, port)| tcp_port_open(host, *port))
        .and_then(|_| find_codex_app_server(&info.listen))
        .unwrap_or(info.pid);

    let outcome = if pid_alive(target) {
        send_sigterm(target);
        StopOutcome::Stopped {
            pid: target,
        }
    } else {
        StopOutcome::StaleRecord {
            pid: target,
        }
    };

    state.save()?;
    Ok(outcome)
}

// Compile-time assurance the protocol module is reachable from this
// crate (used by integration tests downstream).
#[allow(
    dead_code,
    reason = "anchors the protocol module so future refactors don't quietly drop it"
)]
fn _proto_anchor(_msg: _ProtocolMessage) {}

#[cfg(test)]
#[path = "process_tests.rs"]
mod tests;
