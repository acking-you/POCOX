//! Small process helpers shared by POCOX supervisors.
//!
//! The CLI tracks long-running `codex app-server` and pb-mapper worker
//! processes by PID in `state.toml`. These helpers keep the platform
//! checks and best-effort termination behaviour consistent across both
//! supervisors.

use std::{net::TcpStream, time::Duration};

use sysinfo::{Pid, ProcessRefreshKind, ProcessStatus, ProcessesToUpdate, System, UpdateKind};
use tracing::warn;

mod identity;
pub use identity::{is_process_descendant, process_arguments, process_identity, ProcessIdentity};

/// Refresh and return the status of a single process, `None` when no such
/// process exists. Shared lookup behind [`pid_alive`] / [`pid_running`] so
/// the sysinfo refresh incantation lives in one place.
fn process_status(pid: u32) -> Option<ProcessStatus> {
    let mut sys = System::new();
    sys.refresh_processes_specifics(
        ProcessesToUpdate::Some(&[Pid::from_u32(pid)]),
        true,
        ProcessRefreshKind::new(),
    );
    sys.process(Pid::from_u32(pid))
        .map(sysinfo::Process::status)
}

/// Check whether a process id currently exists on this host.
pub fn pid_alive(pid: u32) -> bool {
    process_status(pid).is_some()
}

/// Like [`pid_alive`], but an exited-yet-unreaped child (a unix zombie)
/// counts as gone. The supervisors deliberately never `wait()` on the
/// children they spawn, so on unix a codex that died right after launch
/// lingers as a zombie for the CLI's lifetime — [`pid_alive`] keeps
/// reporting it, while this tells the truth: it will never serve.
pub fn pid_running(pid: u32) -> bool {
    !matches!(process_status(pid), None | Some(ProcessStatus::Zombie | ProcessStatus::Dead))
}

/// The start time of `pid` while it runs (not a zombie), for telling a
/// process apart from a later one that reuses its id; `None` when it does
/// not run. Only suitable for equality.
pub fn process_start_time(pid: u32) -> Option<u64> {
    let mut sys = System::new();
    sys.refresh_processes_specifics(
        ProcessesToUpdate::Some(&[Pid::from_u32(pid)]),
        true,
        ProcessRefreshKind::new(),
    );
    let process = sys.process(Pid::from_u32(pid))?;
    if matches!(process.status(), ProcessStatus::Zombie | ProcessStatus::Dead) {
        return None;
    }
    Some(process.start_time())
}

/// Return the start time only if this PID is the exact standalone pb worker.
/// Host supervisors and Codex processes never match, even if state is stale.
pub fn pb_worker_start_time(session: &crate::state::PbSessionInfo) -> Option<u64> {
    let mut sys = System::new();
    sys.refresh_processes_specifics(
        ProcessesToUpdate::Some(&[Pid::from_u32(session.pid)]),
        true,
        ProcessRefreshKind::new()
            .with_cmd(UpdateKind::Always)
            .with_exe(UpdateKind::Always),
    );
    let process = sys.process(Pid::from_u32(session.pid))?;
    if matches!(process.status(), ProcessStatus::Zombie | ProcessStatus::Dead) {
        return None;
    }
    let exe = process
        .exe()?
        .file_name()?
        .to_str()?
        .trim_end_matches(" (deleted)");
    let cmd: Vec<_> = process
        .cmd()
        .iter()
        .map(|s| s.to_string_lossy().into_owned())
        .collect();
    matches_pb_worker(exe, &cmd, session).then(|| process.start_time())
}

/// Identify an exact standalone worker across PID reuse and wall-clock changes.
/// Linux uses the boot ID and kernel start ticks; other platforms retain their
/// native creation timestamp. This opaque value is only suitable for equality.
pub fn pb_worker_identity(session: &crate::state::PbSessionInfo) -> Option<String> {
    let started = pb_worker_start_time(session)?;
    #[cfg(target_os = "linux")]
    {
        let _ = started;
        let stat = std::fs::read_to_string(format!("/proc/{}/stat", session.pid)).ok()?;
        let boot_id = std::fs::read_to_string("/proc/sys/kernel/random/boot_id").ok()?;
        linux_process_identity(&stat, &boot_id)
    }
    #[cfg(not(target_os = "linux"))]
    Some(format!("created:{started}"))
}

#[cfg(target_os = "linux")]
fn linux_process_identity(stat: &str, boot_id: &str) -> Option<String> {
    // comm (field 2) may contain spaces and ')'. The remainder starts at field 3;
    // field 22 is measured since boot and is unaffected by NTP clock corrections.
    let (_, fields) = stat.rsplit_once(") ")?;
    let ticks = fields.split_whitespace().nth(19)?.parse::<u64>().ok()?;
    let boot_id = boot_id.trim();
    (!boot_id.is_empty()).then(|| format!("linux:{boot_id}:{ticks}"))
}

fn matches_pb_worker(exe: &str, cmd: &[String], session: &crate::state::PbSessionInfo) -> bool {
    let role = match session.role {
        crate::state::PbRole::Register => "pb-register",
        crate::state::PbRole::Subscribe => "pb-subscribe",
    };
    let flag = |name: &str, value: &str| {
        let mut values = cmd
            .windows(2)
            .filter(|pair| pair[0] == name)
            .map(|pair| &pair[1]);
        values.next().is_some_and(|actual| actual == value) && values.next().is_none()
    };
    is_cli_executable(exe)
        && cmd.get(1).is_some_and(|arg| arg == "__worker")
        && cmd.get(2).is_some_and(|arg| arg == role)
        && flag("--key", &session.key)
        && flag("--relay", &session.relay_addr)
        && flag("--local-addr", &session.local_addr)
}

/// Match only this CLI before inspecting or stopping a worker.
fn is_cli_executable(exe: &str) -> bool {
    let name = exe
        .strip_suffix(".exe")
        .or_else(|| exe.strip_suffix(".EXE"))
        .unwrap_or(exe);
    if cfg!(windows) {
        name.eq_ignore_ascii_case("pocox")
    } else {
        name == "pocox"
    }
}

/// Host to dial when probing a listener that was bound to `host`: unspecified
/// binds (`0.0.0.0` / `::`) are reachable over loopback, and a bracketed IPv6
/// authority (`[::1]`) is unwrapped so `ToSocketAddrs` accepts it. Shared by
/// [`tcp_port_open`] and the readiness probe so the two can never disagree
/// about whether the same server is reachable.
pub fn probe_host(host: &str) -> &str {
    let host = host
        .strip_prefix('[')
        .and_then(|h| h.strip_suffix(']'))
        .unwrap_or(host);
    match host {
        "0.0.0.0" | "::" | "" => "127.0.0.1",
        other => other,
    }
}

/// Whether something is currently accepting TCP connections on `host:port`.
///
/// This is the source of truth for "is the codex app-server actually up",
/// which is more reliable than a recorded PID: when `codex` is launched
/// through an npm/node shim (`codex.ps1 → node → codex.exe`) the PID we
/// spawned is the shim — it exits while the native binary keeps the socket.
/// Unspecified hosts (`0.0.0.0` / `::`) are probed over loopback.
pub fn tcp_port_open(host: &str, port: u16) -> bool {
    use std::net::ToSocketAddrs;
    let host = probe_host(host);
    let Ok(addrs) = (host, port).to_socket_addrs() else {
        return false;
    };
    let timeout = Duration::from_millis(400);
    addrs
        .into_iter()
        .any(|addr| TcpStream::connect_timeout(&addr, timeout).is_ok())
}

/// Block until nothing accepts on `addr`, or `timeout` elapses. `true` if the
/// port closed.
///
/// Used after asking a supervised process to stop: the PID exiting does not
/// mean the socket is free (a shimmed `codex` leaves the native child holding
/// it, and the OS may hold the port briefly regardless), so a caller that
/// restarts immediately would hit "address in use". Waiting on the port rather
/// than the PID is what makes a stop-then-start reliable.
///
/// An `addr` that is not a literal `host:port` returns `true`: nothing can be
/// listening on an address we cannot parse, and blocking for `timeout` would
/// only delay the caller's real error.
pub fn wait_for_port_closed(addr: &str, timeout: Duration) -> bool {
    let Ok(sock) = addr.parse::<std::net::SocketAddr>() else {
        return true;
    };
    let deadline = std::time::Instant::now() + timeout;
    while std::time::Instant::now() < deadline {
        if TcpStream::connect_timeout(&sock, Duration::from_millis(200)).is_err() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    false
}

/// Does this process look like a native `codex app-server` launched with
/// `listen_url`? Matched by executable name (`codex`) so the `node` /
/// `powershell` wrappers of an npm install are skipped: they carry the same
/// `app-server --listen …` arguments but are not the process holding the
/// socket. Split out from [`find_codex_app_server`] so the matching rule is
/// unit-testable without real processes.
fn matches_codex_app_server(exe_name: &str, cmd: &[String], listen_url: &str) -> bool {
    // Linux keeps replaced executables running and appends this suffix to
    // /proc/PID/exe. Their process identity does not change during an upgrade.
    let exe_name = exe_name.trim_end_matches(" (deleted)");
    (exe_name.eq_ignore_ascii_case("codex") || exe_name.eq_ignore_ascii_case("codex.exe"))
        && cmd.iter().any(|a| a == "app-server")
        && (cmd
            .windows(2)
            .any(|pair| pair[0] == "--listen" && pair[1] == listen_url)
            || cmd
                .iter()
                .any(|arg| arg.strip_prefix("--listen=") == Some(listen_url)))
}

/// PID of the native `codex app-server` process serving `listen_url`, if one
/// is running. This is what keeps status/stop/`serve` correct when `codex`
/// resolves to an npm/node shim: [`std::process::Command`] only sees the
/// shim's PID (which exits), while the native binary several layers down keeps
/// the listener. Linux worker threads and exited processes are excluded.
pub fn find_codex_app_server(listen_url: &str) -> Option<u32> {
    let sys = codex_snapshot();
    sys.processes()
        .values()
        .find(|p| serves(p, listen_url))
        .map(|p| p.pid().as_u32())
}

/// Every process with its command line and executable, for matching.
fn codex_snapshot() -> System {
    let mut sys = System::new();
    sys.refresh_processes_specifics(
        ProcessesToUpdate::All,
        true,
        ProcessRefreshKind::new()
            .with_cmd(UpdateKind::Always)
            .with_exe(UpdateKind::Always),
    );
    sys
}

/// Whether `p` is a running native `codex app-server` for `listen_url`.
fn serves(p: &sysinfo::Process, listen_url: &str) -> bool {
    if p.thread_kind().is_some()
        || matches!(p.status(), ProcessStatus::Zombie | ProcessStatus::Dead)
    {
        return false;
    }
    let exe = p.exe().map(std::path::Path::to_path_buf);
    let name = exe
        .as_deref()
        .unwrap_or_else(|| std::path::Path::new(p.name()))
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or_default();
    let cmd: Vec<String> = p
        .cmd()
        .iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    matches_codex_app_server(name, &cmd, listen_url)
}

/// Most parent links followed from a candidate towards its root.
const MAX_ANCESTRY: usize = 32;

/// The native `codex app-server` serving `listen_url` that is the process
/// `root` (started at `root_started`, see [`process_start_time`]) or one of
/// its descendants — an npm/node shim's native binary — with its start time.
/// A server anyone else started on the same address never matches: from
/// one process snapshot, the candidate's parent chain must reach `root`,
/// still running with that start time, through processes started no
/// earlier than it (a stale parent id reused by a later process does not
/// count). `None` when no such server runs, e.g. once a shim that exited
/// left its child to another parent.
///
/// This matches arguments and ancestry only: it does not show that the
/// candidate holds the listening socket. [`endpoint_owner_under`] does.
pub fn find_codex_app_server_under(
    listen_url: &str,
    root: u32,
    root_started: u64,
) -> Option<(u32, u64)> {
    let sys = codex_snapshot();
    let root_pid = Pid::from_u32(root);
    if sys.process(root_pid)?.start_time() != root_started {
        return None;
    }
    sys.processes()
        .values()
        .filter(|p| serves(p, listen_url))
        .find(|p| descends(&sys, p, root_pid, root_started))
        .map(|p| (p.pid().as_u32(), p.start_time()))
}

/// Whether `p` is `root` (started at `root_started`) or descends from it
/// through processes started no earlier than it.
fn descends(sys: &System, p: &sysinfo::Process, root: Pid, root_started: u64) -> bool {
    let mut current = p;
    for _ in 0..MAX_ANCESTRY {
        if current.pid() == root {
            return true;
        }
        if current.start_time() < root_started {
            return false;
        }
        let Some(parent) = current.parent().and_then(|id| sys.process(id)) else {
            return false;
        };
        current = parent;
    }
    false
}

/// Who holds the listening socket of a launch's port.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EndpointOwner {
    /// Only processes the launch started hold it; this one serves (the
    /// native codex when several of them hold it).
    Owned {
        /// Its process id.
        pid: u32,
        /// Its start time ([`process_start_time`]).
        started: u64,
    },
    /// Another process holds it (or one this launch did not start).
    Foreign,
    /// Nothing listens there.
    Unbound,
    /// It cannot be told: the launch's root no longer runs as started (an
    /// exited shim leaves its child to another parent), the listen host is
    /// neither an IP address nor `localhost`, or the platform's listener
    /// source could not be read completely ([`crate::listener`]).
    Unknown,
}

/// Who holds the listening sockets on `port` that connections to the host of
/// `listen_url` (`ws://<host>:<port>`) reach — that address, a wildcard that
/// applies to it, never another address or family sharing the port number
/// ([`crate::listener`]) — relative to the process `root` (started at
/// `root_started`) that a launch spawned: [`EndpointOwner::Owned`] only when
/// every such holder is `root` or one of its descendants (see
/// [`find_codex_app_server_under`] for the ancestry rule), preferring the one
/// matching `codex app-server --listen <listen_url>`. One snapshot is taken
/// before the listing, so a process started in between counts as foreign.
/// This is one point-in-time observation.
pub fn endpoint_owner_under(
    port: u16,
    listen_url: &str,
    root: u32,
    root_started: u64,
) -> EndpointOwner {
    let Some(requested) = listen_host(listen_url).and_then(crate::listener::requested) else {
        return EndpointOwner::Unknown;
    };
    let sys = codex_snapshot();
    let root_pid = Pid::from_u32(root);
    if sys.process(root_pid).map(sysinfo::Process::start_time) != Some(root_started) {
        return EndpointOwner::Unknown;
    }
    let tree: Vec<&sysinfo::Process> = sys
        .processes()
        .values()
        .filter(|p| p.thread_kind().is_none() && descends(&sys, p, root_pid, root_started))
        .collect();
    let pids: Vec<u32> = tree.iter().map(|p| p.pid().as_u32()).collect();
    let Some(listening) = crate::listener::holders(&requested, port, &pids) else {
        return EndpointOwner::Unknown;
    };
    if listening.is_empty() {
        return EndpointOwner::Unbound;
    }
    if listening.unattributed || listening.pids.iter().any(|pid| !pids.contains(pid)) {
        return EndpointOwner::Foreign;
    }
    let holders = || {
        tree.iter()
            .filter(|p| listening.pids.contains(&p.pid().as_u32()))
    };
    holders()
        .find(|p| serves(p, listen_url))
        .or_else(|| holders().next())
        .map_or(EndpointOwner::Unknown, |p| EndpointOwner::Owned {
            pid: p.pid().as_u32(),
            started: p.start_time(),
        })
}

/// The host of a `ws://<host>:<port>[/...]` listen URL.
fn listen_host(listen_url: &str) -> Option<&str> {
    let authority = listen_url.strip_prefix("ws://")?.split('/').next()?;
    Some(authority.rsplit_once(':')?.0)
}

/// Send `SIGTERM` to a process id, logging but not surfacing errors.
#[cfg(unix)]
pub fn send_sigterm(pid: u32) {
    use nix::{
        sys::signal::{kill, Signal},
        unistd::Pid as NixPid,
    };

    let nix_pid = NixPid::from_raw(pid as i32);
    if let Err(e) = kill(nix_pid, Signal::SIGTERM) {
        warn!(pid, error = %e, "failed to SIGTERM process");
    }
}

/// Send `SIGTERM` to a process id, logging but not surfacing errors.
///
/// Windows has no SIGTERM; best-effort termination goes through
/// sysinfo's `Process::kill` (TerminateProcess) instead.
#[cfg(not(unix))]
pub fn send_sigterm(pid: u32) {
    let mut sys = System::new();
    sys.refresh_processes_specifics(
        ProcessesToUpdate::Some(&[Pid::from_u32(pid)]),
        true,
        ProcessRefreshKind::new(),
    );
    match sys.process(Pid::from_u32(pid)) {
        Some(process) => {
            if !process.kill() {
                warn!(pid, "failed to terminate process");
            }
        },
        None => warn!(pid, "process not found; nothing to terminate"),
    }
}

/// Forcefully terminate a process id, returning whether the kill signal
/// was delivered.
///
/// Unlike [`send_sigterm`], this is an immediate, non-graceful kill
/// (`SIGKILL` on unix, `TerminateProcess` on Windows, both via sysinfo's
/// [`sysinfo::Process::kill`]). It is the primitive behind a *force
/// takeover*, where POCOX evicts another codex process that is
/// holding a session's rollout file open so it can resume that session
/// itself. Returns `false` when the process is already gone or the kill
/// could not be delivered; callers treat that as best-effort (the
/// takeover proceeds regardless).
pub fn force_kill(pid: u32) -> bool {
    let mut sys = System::new();
    sys.refresh_processes_specifics(
        ProcessesToUpdate::Some(&[Pid::from_u32(pid)]),
        true,
        ProcessRefreshKind::new(),
    );
    match sys.process(Pid::from_u32(pid)) {
        Some(process) => process.kill(),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use std::net::TcpListener;

    use super::*;

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_identity_uses_boot_and_ticks_without_comm_or_wall_time() {
        let stat =
            "123 (name with ) spaces) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 987654 0";
        assert_eq!(
            linux_process_identity(stat, "boot-a\n").as_deref(),
            Some("linux:boot-a:987654")
        );
        assert_ne!(linux_process_identity(stat, "boot-a"), linux_process_identity(stat, "boot-b"));
        assert_ne!(
            linux_process_identity(stat, "boot-a"),
            linux_process_identity(&stat.replace("987654", "987655"), "boot-a")
        );
        assert_eq!(linux_process_identity("123 (broken)", "boot-a"), None);
        assert_eq!(linux_process_identity(stat, ""), None);
    }

    #[test]
    fn network_maintenance_matches_exact_worker_and_rejects_host_or_reused_pid() {
        let record = crate::state::PbSessionInfo {
            role: crate::state::PbRole::Register,
            key: "pcx:test:api:default".into(),
            relay_addr: "relay.test:7666".into(),
            local_addr: "127.0.0.1:12345".into(),
            pid: 0,
            log_file: Default::default(),
            codec: true,
            started_at: String::new(),
        };
        let args = [
            "pocox",
            "__worker",
            "pb-register",
            "--key",
            &record.key,
            "--local-addr",
            &record.local_addr,
            "--relay",
            &record.relay_addr,
            "--codec",
        ];
        let cmd: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        for exe in ["pocox", "pocox.exe"] {
            assert!(matches_pb_worker(exe, &cmd, &record), "{exe}");
        }
        assert!(!matches_pb_worker("codex", &cmd, &record));
        let mut host = cmd.clone();
        host[1] = "serve".into();
        assert!(!matches_pb_worker("pocox", &host, &record));
        let mut wrong = cmd.clone();
        wrong[4] = "another-key".into();
        assert!(!matches_pb_worker("pocox", &wrong, &record));
        let mut wrong = cmd.clone();
        wrong[8] = "different-relay:7666".into();
        assert!(!matches_pb_worker("pocox", &wrong, &record));
        let mut wrong = cmd;
        wrong.extend(["--key".into(), record.key.clone()]);
        assert!(!matches_pb_worker("pocox", &wrong, &record));
    }

    #[test]
    fn tcp_port_open_sees_a_live_listener() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port");
        let port = listener.local_addr().expect("local addr").port();
        assert!(tcp_port_open("127.0.0.1", port), "bound port should read open");
        // Unspecified host is probed over loopback, so it sees the same listener.
        assert!(tcp_port_open("0.0.0.0", port));
    }

    #[test]
    fn tcp_port_open_false_when_nothing_listens() {
        // Bind then drop to learn a port nobody is listening on.
        let port = {
            let l = TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port");
            l.local_addr().expect("local addr").port()
        };
        assert!(!tcp_port_open("127.0.0.1", port));
    }

    #[test]
    fn pid_running_tracks_real_processes() {
        // Our own process is by definition running (and not a zombie).
        assert!(pid_running(std::process::id()));
        // A PID that cannot exist reads as gone. u32::MAX is above every
        // platform's PID ceiling.
        assert!(!pid_running(u32::MAX));
    }

    #[test]
    fn probe_host_normalizes_unspecified_and_bracketed_hosts() {
        assert_eq!(probe_host("0.0.0.0"), "127.0.0.1");
        assert_eq!(probe_host("::"), "127.0.0.1");
        assert_eq!(probe_host("[::]"), "127.0.0.1");
        assert_eq!(probe_host(""), "127.0.0.1");
        assert_eq!(probe_host("[::1]"), "::1");
        assert_eq!(probe_host("127.0.0.1"), "127.0.0.1");
        assert_eq!(probe_host("example.test"), "example.test");
        // A half-bracketed host is left alone rather than mangled.
        assert_eq!(probe_host("[oops"), "[oops");
    }

    #[test]
    fn matches_native_codex_app_server_only() {
        let url = "ws://127.0.0.1:18080";
        let cmd = |argv: &[&str]| argv.iter().map(|s| s.to_string()).collect::<Vec<_>>();

        // Native binary: stem `codex`, carries `app-server` + our listen url.
        assert!(matches_codex_app_server(
            "codex",
            &cmd(&["codex", "app-server", "--listen", url]),
            url,
        ));
        assert!(matches_codex_app_server(
            "codex (deleted)",
            &cmd(&["codex", "app-server", "--listen", url]),
            url,
        ));
        assert!(matches_codex_app_server(
            "codex.exe",
            &cmd(&["codex.exe", "app-server", &format!("--listen={url}")]),
            url,
        ));
        assert!(!matches_codex_app_server(
            "codex",
            &cmd(&["codex", "app-server", "--listen", "ws://127.0.0.1:180800"]),
            url,
        ));
        assert!(!matches_codex_app_server(
            "codex",
            &cmd(&["codex", "app-server", "--config", url]),
            url,
        ));
        // The npm/node shim carries identical args but is named `node` — skip it.
        assert!(!matches_codex_app_server(
            "node",
            &cmd(&["node", "codex.js", "app-server", "--listen", url]),
            url,
        ));
        // Right binary, different port → not ours.
        assert!(!matches_codex_app_server(
            "codex",
            &cmd(&["codex", "app-server", "--listen", "ws://127.0.0.1:9999"]),
            url,
        ));
        // Right binary + url but not an app-server invocation.
        assert!(
            !matches_codex_app_server("codex", &cmd(&["codex", "exec", "--listen", url]), url,)
        );
    }

    #[cfg(unix)]
    fn copy_fake_codex(path: &std::path::Path) {
        // A copied system shell can be killed by macOS launch constraints.
        std::fs::copy(std::env::current_exe().expect("test binary"), path)
            .expect("a process named codex");
    }

    #[test]
    #[ignore = "an idle fixture process the attribution tests start"]
    fn idle_fixture() {
        if std::env::var_os("POCOX_TEST_IDLE").is_some() {
            std::thread::sleep(Duration::from_secs(60));
        }
    }

    /// An idle test process named `codex`, directly or behind a live shim.
    #[cfg(unix)]
    fn fake_codex(codex: &std::path::Path, url: &str, shim: bool) -> std::process::Child {
        // After `--`, libtest treats the server arguments as extra filters.
        // The exact fixture filter still selects only this one idle test.
        let args = [
            "--exact",
            "process::tests::idle_fixture",
            "--ignored",
            "--test-threads=1",
            "--",
            "app-server",
            "--listen",
            url,
        ];
        let mut command = if shim {
            let mut sh = std::process::Command::new("/bin/sh");
            // The trailing `:` keeps the shell in front instead of exec'ing.
            sh.args(["-c", "\"$0\" \"$@\"; :"]).arg(codex).args(args);
            sh
        } else {
            let mut direct = std::process::Command::new(codex);
            direct.args(args);
            direct
        };
        command
            .env("POCOX_TEST_IDLE", "1")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn fixture")
    }

    /// Only a server descending from the process a launch spawned is
    /// attributed to it: the same URL served by a process someone else
    /// started never is, nor is a root whose id now names another process.
    #[cfg(unix)]
    #[test]
    fn only_a_descendant_of_the_spawned_process_is_attributed() {
        let dir = std::env::temp_dir().join(format!("pcx-attribution-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let codex = dir.join("codex");
        copy_fake_codex(&codex);
        let url = "ws://127.0.0.1:9";
        let mut foreign = fake_codex(&codex, url, false);
        let mut shim = fake_codex(&codex, url, true);
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        let root_started = loop {
            if let Some(started) = process_start_time(shim.id()) {
                break started;
            }
            assert!(std::time::Instant::now() < deadline, "the shim started");
            std::thread::sleep(Duration::from_millis(20));
        };
        let ours = loop {
            if let Some(found) = find_codex_app_server_under(url, shim.id(), root_started) {
                break found;
            }
            assert!(std::time::Instant::now() < deadline, "the shim's server started");
            std::thread::sleep(Duration::from_millis(20));
        };
        assert_ne!(ours.0, foreign.id(), "the foreign server is never ours");
        assert_ne!(ours.0, shim.id(), "the shim itself is not the server");
        // The foreign server is its own root.
        let foreign_started = process_start_time(foreign.id()).expect("foreign runs");
        assert_eq!(
            find_codex_app_server_under(url, foreign.id(), foreign_started).map(|f| f.0),
            Some(foreign.id())
        );
        // Another start time is another process under the same id.
        assert_eq!(find_codex_app_server_under(url, shim.id(), root_started + 1), None);
        // A root that started nothing serving the URL is attributed nothing.
        let me = std::process::id();
        let mine = process_start_time(me).expect("this process runs");
        assert_eq!(find_codex_app_server_under("ws://127.0.0.1:1", me, mine), None);
        for child in [&mut foreign, &mut shim] {
            let _ = child.kill();
            let _ = child.wait();
        }
        force_kill(ours.0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Started by [`listening_child`] only: listen on the port it names,
    /// then wait to be stopped.
    #[test]
    #[ignore = "a fixture process the endpoint tests start"]
    fn listen_fixture() {
        let Some(port) = std::env::var("POCOX_TEST_LISTEN")
            .ok()
            .and_then(|p| p.parse::<u16>().ok())
        else {
            return;
        };
        let _listener =
            std::net::TcpListener::bind(("127.0.0.1", port)).expect("bind the fixture port");
        std::thread::sleep(Duration::from_secs(60));
    }

    #[cfg(unix)]
    fn free_port() -> u16 {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        listener.local_addr().expect("addr").port()
    }

    /// This test binary listening on `port` (in [`listen_fixture`]), run
    /// directly or behind `/bin/sh` that stays in front of it.
    #[cfg(unix)]
    fn listening_child(port: u16, shim: bool) -> std::process::Child {
        let exe = std::env::current_exe().expect("the test binary");
        let args = ["--exact", "process::tests::listen_fixture", "--ignored", "--test-threads=1"];
        let mut command = if shim {
            let mut sh = std::process::Command::new("/bin/sh");
            // The trailing `:` keeps the shell in front instead of exec'ing.
            sh.args(["-c", "\"$0\" \"$@\"; :"]).arg(&exe).args(args);
            sh
        } else {
            let mut direct = std::process::Command::new(&exe);
            direct.args(args);
            direct
        };
        command
            .env("POCOX_TEST_LISTEN", port.to_string())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn the fixture")
    }

    #[cfg(unix)]
    fn started(pid: u32) -> u64 {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(started) = process_start_time(pid) {
                return started;
            }
            assert!(std::time::Instant::now() < deadline, "{pid} started");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    #[cfg(unix)]
    fn until_listening(port: u16) {
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        while !tcp_port_open("127.0.0.1", port) {
            assert!(std::time::Instant::now() < deadline, "the fixture listens on {port}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// The gap ancestry alone leaves: a live, matching codex this launch
    /// started that does not hold the socket, while someone else does. The
    /// argument match attributes it; the endpoint check does not.
    #[cfg(unix)]
    #[test]
    fn a_matching_child_that_does_not_hold_the_socket_does_not_own_the_endpoint() {
        let dir = std::env::temp_dir().join(format!("pcx-endpoint-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let codex = dir.join("codex");
        copy_fake_codex(&codex);
        // Someone else's server: this test process, not in the child's tree.
        // Retain the port reservation: a dropped ephemeral listener can be
        // reused by another parallel fixture before a second bind.
        let foreign = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = foreign.local_addr().expect("addr").port();
        let url = format!("ws://127.0.0.1:{port}");
        let mut ours = fake_codex(&codex, &url, false);
        let ours_started = started(ours.id());
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while find_codex_app_server_under(&url, ours.id(), ours_started).is_none() {
            assert!(std::time::Instant::now() < deadline, "the matching child runs");
            std::thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(
            endpoint_owner_under(port, &url, ours.id(), ours_started),
            EndpointOwner::Foreign
        );
        drop(foreign);
        assert_eq!(
            endpoint_owner_under(port, &url, ours.id(), ours_started),
            EndpointOwner::Unbound
        );
        let _ = ours.kill();
        let _ = ours.wait();
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The spawned process holding the socket owns the endpoint, whatever
    /// listens at another address or family on the same port; so does the
    /// child of a shim that stays in front of it. Once that shim is gone,
    /// nothing can be attributed any more.
    #[cfg(unix)]
    #[test]
    fn the_process_a_launch_started_that_holds_the_socket_owns_the_endpoint() {
        let port = free_port();
        let url = format!("ws://127.0.0.1:{port}");
        let mut direct = listening_child(port, false);
        let direct_started = started(direct.id());
        until_listening(port);
        assert_eq!(
            endpoint_owner_under(port, &url, direct.id(), direct_started),
            EndpointOwner::Owned {
                pid: direct.id(),
                started: direct_started,
            }
        );
        assert_eq!(
            endpoint_owner_under(port, &url, direct.id(), direct_started + 1),
            EndpointOwner::Unknown,
            "another start time is another process"
        );
        // Someone else's listener on the same port number at another
        // address and family leaves the endpoint ours; it is what a request
        // for its own address finds, and `localhost` reaches both. The IPv4
        // wildcard request does not reach a specific IPv6 listener.
        let other = std::net::TcpListener::bind(("::1", port)).expect("the IPv6 loopback");
        let owned = EndpointOwner::Owned {
            pid: direct.id(),
            started: direct_started,
        };
        let at = |url: &str| endpoint_owner_under(port, url, direct.id(), direct_started);
        assert_eq!(at(&url), owned, "a listener elsewhere is not this endpoint's");
        assert_eq!(at(&format!("ws://0.0.0.0:{port}")), owned);
        for foreign in ["[::1]", "localhost", "[::]"] {
            let foreign = format!("ws://{foreign}:{port}");
            assert_eq!(at(&foreign), EndpointOwner::Foreign, "{foreign}");
        }
        drop(other);
        assert_eq!(at(&format!("ws://[::1]:{port}")), EndpointOwner::Unbound);
        assert_eq!(
            at(&format!("ws://codex.example:{port}")),
            EndpointOwner::Unknown,
            "a name's address is not known"
        );
        let _ = direct.kill();
        let _ = direct.wait();

        let port = free_port();
        let url = format!("ws://127.0.0.1:{port}");
        let mut shim = listening_child(port, true);
        let shim_started = started(shim.id());
        until_listening(port);
        let EndpointOwner::Owned {
            pid: server, ..
        } = endpoint_owner_under(port, &url, shim.id(), shim_started)
        else {
            panic!("the shim's child holds the socket");
        };
        assert_ne!(server, shim.id(), "the shim itself does not listen");
        let _ = shim.kill();
        let _ = shim.wait();
        assert_eq!(
            endpoint_owner_under(port, &url, shim.id(), shim_started),
            EndpointOwner::Unknown,
            "an exited shim's child is not attributed"
        );
        force_kill(server);
    }

    #[test]
    fn waiting_on_a_free_port_returns_at_once() {
        // Bind then drop, so the address is real but nothing is accepting.
        let addr = {
            let listener =
                std::net::TcpListener::bind("127.0.0.1:0").expect("bind a loopback port");
            listener.local_addr().expect("local addr").to_string()
        };
        let started = std::time::Instant::now();
        assert!(wait_for_port_closed(&addr, Duration::from_secs(5)));
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "a closed port must not burn the whole timeout"
        );
    }

    #[test]
    fn waiting_on_a_live_listener_times_out() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind a loopback port");
        let addr = listener.local_addr().expect("local addr").to_string();
        // Held open for the duration, so the port never closes.
        assert!(!wait_for_port_closed(&addr, Duration::from_millis(600)));
        drop(listener);
    }

    #[test]
    fn an_unparsable_address_does_not_block() {
        // Nothing can listen on an address we cannot parse, so reporting "closed"
        // lets the caller reach its real error instead of stalling first.
        let started = std::time::Instant::now();
        assert!(wait_for_port_closed("not-an-address", Duration::from_secs(30)));
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}
