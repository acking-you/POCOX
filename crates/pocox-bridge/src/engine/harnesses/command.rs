//! Running a harness's own tools: version probes, its update check and its
//! installer. Every run is bounded in time and output
//! ([`pocox_core::process::bounded`]), starts in a temporary directory with
//! no console window, and follows the app's network route (see
//! [`network::route`]) in its environment only: never in argv, logs or
//! answers.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use pocox_core::process::bounded::{self, Failure as RunFailure};

use crate::engine::{network, runtime};

/// A version probe or update check finishes within this.
const PROBE_TIMEOUT: Duration = Duration::from_secs(30);
/// Most bytes kept of a probe's output streams.
const PROBE_CAP: usize = 256 * 1024;
/// An installer finishes within this.
const UPDATE_TIMEOUT: Duration = Duration::from_secs(15 * 60);
/// Most bytes kept of an installer's output streams; more stops it.
const UPDATE_CAP: usize = 16 << 20;
/// Lines of an installer's output kept in the host's diagnostics.
const LOGGED_LINES: usize = 40;

/// One run of a vendor tool.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Invocation {
    /// The executable, already resolved.
    pub(super) program: PathBuf,
    /// Its arguments, fixed by this app (never taken from a request).
    pub(super) args: Vec<String>,
}

/// Why an installer did not succeed (see `view::Job::failure`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Failure {
    /// Its package manager or shell was not found.
    ToolMissing,
    /// A file it had to replace was in use (Windows).
    InUse,
    /// It lacked the rights to write the installation.
    Permission,
    /// It did not finish in time and was stopped.
    TimedOut,
    /// It exited unsuccessfully.
    Failed,
}

impl Failure {
    /// Stable wire code.
    pub(super) fn code(self) -> &'static str {
        match self {
            Self::ToolMissing => "tool_missing",
            Self::InUse => "in_use",
            Self::Permission => "permission",
            Self::TimedOut => "timed_out",
            Self::Failed => "failed",
        }
    }
}

/// The `PATH` a GUI host's children get (its login shell's on macOS), else
/// this process's own.
fn child_path() -> Option<OsString> {
    pocox_codex::external_tool_path().or_else(|| std::env::var_os("PATH"))
}

/// The proxy variables a child understands.
const PROXY_VARS: [&str; 6] =
    ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"];

/// The app's network route, as the child must see it.
fn route() -> network::Route {
    runtime::support_dir()
        .ok()
        .and_then(|support| network::route(&support).ok())
        .unwrap_or(network::Route {
            proxy: None,
            bypass: Vec::new(),
            source: network::Source::Direct,
        })
}

/// Give `command` the app's route: a custom or system proxy as its proxy
/// variables (a `socks5` one resolving names through itself, as the app's
/// own requests do), none at all for a direct route; proxy variables the app
/// inherited already reach it unchanged.
fn apply_route(command: &mut Command, route: &network::Route) {
    match (route.source, &route.proxy) {
        (network::Source::Environment, _) => {},
        (_, Some(proxy)) => {
            let proxy = network::socks5h(proxy.clone());
            for name in PROXY_VARS {
                command.env(name, &proxy);
            }
            let mut direct = vec!["localhost".to_string(), "127.0.0.1".into(), "::1".into()];
            direct.extend(route.bypass.iter().cloned());
            for name in ["NO_PROXY", "no_proxy"] {
                command.env(name, direct.join(","));
            }
        },
        (_, None) => {
            for name in PROXY_VARS {
                command.env_remove(name);
            }
        },
    }
}

fn command(invocation: &Invocation) -> Command {
    let mut command = Command::new(&invocation.program);
    command
        .args(&invocation.args)
        .current_dir(std::env::temp_dir());
    if let Some(path) = pocox_codex::external_tool_path() {
        command.env("PATH", path);
    }
    apply_route(&mut command, &route());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // A windowless app's console child would otherwise open a window.
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
}

/// The executable `name` resolves to: in `first` (an installation's own
/// directory, where its package manager usually sits), then on the child
/// `PATH`. On Windows this finds `npm.cmd` and the like.
pub(super) fn resolve(name: &str, first: Option<&Path>) -> Option<PathBuf> {
    let mut dirs: Vec<PathBuf> = first.map(Path::to_path_buf).into_iter().collect();
    if let Some(path) = child_path() {
        dirs.extend(std::env::split_paths(&path).filter(|dir| dir.is_absolute()));
    }
    let search = std::env::join_paths(dirs).ok()?;
    which::which_in(name, Some(search), std::env::temp_dir()).ok()
}

/// The standard output of a successful short run, as text.
pub(super) fn probe(program: &Path, args: &[&str]) -> Option<String> {
    let invocation = Invocation {
        program: program.to_path_buf(),
        args: args.iter().map(|arg| (*arg).to_string()).collect(),
    };
    let output = bounded::run(&mut command(&invocation), Instant::now() + PROBE_TIMEOUT, PROBE_CAP)
        .ok()
        .filter(|output| output.code == Some(0))?;
    String::from_utf8(output.stdout).ok()
}

/// Run an installer to its end. Its output stays in this host's
/// diagnostics (its last lines, with the proxy withheld).
pub(super) fn install(invocation: &Invocation) -> Result<(), Failure> {
    let started = Instant::now();
    let result = bounded::run(&mut command(invocation), started + UPDATE_TIMEOUT, UPDATE_CAP);
    let program = invocation
        .program
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let output = match result {
        Ok(output) => output,
        Err(RunFailure::Start(kind)) => {
            tracing::warn!(%program, ?kind, "the harness installer could not be started");
            return Err(Failure::ToolMissing);
        },
        Err(RunFailure::Deadline) => {
            tracing::warn!(%program, "the harness installer did not finish in time");
            return Err(Failure::TimedOut);
        },
        Err(RunFailure::Unreadable) => {
            tracing::warn!(%program, "the harness installer's output could not be read");
            return Err(Failure::Failed);
        },
    };
    let text = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    tracing::info!(
        target: "pocox::harness",
        %program,
        code = ?output.code,
        seconds = started.elapsed().as_secs(),
        output = %tail(&withhold_proxy(&text), LOGGED_LINES),
        "harness installer finished"
    );
    match output.code {
        Some(0) => Ok(()),
        _ => Err(classify(&text, cfg!(windows))),
    }
}

/// Why an installer that exited unsuccessfully failed, from what it printed.
/// On Windows npm reports a file another process holds as `EPERM` too.
pub(super) fn classify(output: &str, windows: bool) -> Failure {
    let text = output.to_ascii_lowercase();
    if ["ebusy", "being used by another process", "resource busy"]
        .iter()
        .any(|mark| text.contains(mark))
        || windows && text.contains("eperm")
    {
        Failure::InUse
    } else if [
        "eacces",
        "eperm",
        "permission denied",
        "access is denied",
        "operation not permitted",
    ]
    .iter()
    .any(|mark| text.contains(mark))
    {
        Failure::Permission
    } else {
        Failure::Failed
    }
}

/// `text` without the route's proxy URL, as given or as passed to a child.
fn withhold_proxy(text: &str) -> String {
    let mut text = text.to_string();
    if let Some(proxy) = route().proxy.filter(|proxy| !proxy.is_empty()) {
        text = text.replace(&network::socks5h(proxy.clone()), "[proxy]");
        text = text.replace(&proxy, "[proxy]");
    }
    text
}

/// The last `lines` non-empty lines of `text`.
fn tail(text: &str, lines: usize) -> String {
    let kept: Vec<&str> = text
        .lines()
        .filter(|line| !line.trim().is_empty())
        .collect();
    kept[kept.len().saturating_sub(lines)..].join("\n")
}
