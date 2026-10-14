//! Apply a saved configuration to a running local host: an explicit
//! restart of that one host, separate from saving (see
//! [`super::host_profiles`]).
//!
//! The whole apply holds the instance's lifecycle lease (see
//! [`super::host_lease`]), so no start, stop or other apply of it can
//! interleave. It names what it applies: the running incarnation the caller
//! saw and the saved revision it chose; either having moved refuses the
//! apply, so it never restarts a replacement host or applies a save it did
//! not review. Everything the new launch needs (executable, port, proxy,
//! provider, catalog layer) is checked before the host is stopped. Then only
//! that host stops and starts again under the same name; its relay keys are
//! withdrawn and published again, so controllers reconnect, and other hosts
//! are untouched. When the new start fails, the host is started again
//! exactly as it ran (same executable, port, proxy, spec and provider), and
//! the report says whether that worked: Codex from the recorded executable,
//! port and proxy; an ACP agent from the exact launch its stop captured (the
//! resolved executable or adapter, arguments, environment, provider launch,
//! session source and catalog files), never resolved again. A Codex
//! app-server this host adopted rather than started is never restarted.

use anyhow::{anyhow, bail, Result};
use pocket_codex_core::process::tcp_port_open;

use super::{
    config::load_config,
    host_lease::{self, Lease, Op},
    host_profiles::{self, Runtime},
    runtime,
    serve::{self, Binary, CodexStart},
    serve_acp, serve_opencode,
};

/// The outcome of an apply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApplyReport {
    /// Instance name.
    pub name: String,
    /// The host runs the new configuration.
    pub applied: bool,
    /// The new start failed and the previous configuration runs again.
    pub restored_previous: bool,
    /// Why the new start failed (safe to show), when it did.
    pub error: Option<String>,
    /// Why restoring the previous configuration failed too, when it did:
    /// the host is stopped.
    pub restore_error: Option<String>,
    /// The saved revision the host now runs (the previous one after a
    /// restore); `None` when it is stopped.
    pub revision: Option<u64>,
}

/// Whether an apply of `name` is in progress.
#[cfg(test)]
pub fn is_applying(name: &str) -> bool {
    host_lease::holder(name) == Some(Op::Apply)
}

/// What a running host runs with now (never its key).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Active {
    /// Its run identity, to pass back as [`Expected::incarnation`].
    pub incarnation: String,
    /// Its runtime as launched (Codex: the exact executable used).
    pub runtime: Runtime,
    /// Its model-service source as launched.
    pub source: host_profiles::Source,
    /// The saved revision it was launched with (`0`: never saved).
    pub revision: u64,
}

/// What the running host `name` runs with, or `None` when it does not run.
pub fn active(name: &str) -> Option<Active> {
    if let Some(codex) = serve::codex_relaunch(name) {
        return Some(Active {
            incarnation: codex.incarnation,
            runtime: Runtime::Codex {
                binary: codex.binary.map(|b| b.to_string_lossy().into_owned()),
                port: codex.port,
                proxy: codex.proxy,
            },
            source: codex.provider.source,
            revision: codex.provider.revision,
        });
    }
    if let Some(native) = serve_opencode::relaunch(name) {
        return Some(Active {
            incarnation: native.incarnation,
            runtime: Runtime::OpenCode {
                binary: Some(native.prepared.binary()),
            },
            source: native.prepared.provider.source,
            revision: native.prepared.provider.revision,
        });
    }
    serve_acp::relaunch(name).map(|acp| Active {
        incarnation: acp.incarnation,
        runtime: Runtime::Acp(acp.spec),
        source: acp.provider.source,
        revision: acp.provider.revision,
    })
}

/// What the caller saw and chose when it asked for the apply.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Expected {
    /// The running host's incarnation (see `ServeStatus::incarnation`).
    pub incarnation: Option<String>,
    /// The saved revision to apply.
    pub revision: Option<u64>,
}

/// Restart the running host `name` with its saved configuration and saved
/// runtime (the running one when none was saved).
pub fn apply(name: &str, expected: &Expected) -> Result<ApplyReport> {
    let profiles = host_profiles::root()?;
    let lease = host_lease::acquire(name, Op::Apply)?;
    if let Some(running) = serve::codex_relaunch(name) {
        return apply_codex(&lease, &profiles, running, expected);
    }
    if let Some(running) = serve_acp::relaunch(lease.name()) {
        return apply_acp(&lease, &profiles, running, expected);
    }
    if let Some(running) = serve_opencode::relaunch(lease.name()) {
        return apply_opencode(&lease, &profiles, running, expected);
    }
    bail!("`{name}` is not hosting; start it")
}

fn apply_codex(
    lease: &Lease,
    profiles: &std::path::Path,
    running: serve::CodexRelaunch,
    expected: &Expected,
) -> Result<ApplyReport> {
    let desired = host_profiles::resolve_in(profiles, lease.name())?;
    let support = runtime::support_dir()?;
    let name = running.name.clone();
    orchestrate(
        lease,
        &Current {
            incarnation: &running.incarnation,
            desired: &desired,
            previous: &running.provider,
        },
        expected,
        || {
            if running.adopted {
                bail!(
                    "this host uses a codex app-server it did not start, so it cannot restart it; \
                     stop it and start the host again"
                );
            }
            let (binary, port, proxy) =
                codex_runtime(&support, &running, desired.runtime.as_ref())?;
            host_profiles::codex(&desired, &name)?;
            Ok(CodexStart {
                port,
                binary: Binary::Exact(binary),
                name: name.clone(),
                proxy,
                provider: Some(desired.clone()),
            })
        },
        || serve::serve_stop_locked(lease, &name),
        |next| serve::serve_start_locked(lease, &support, profiles, next).map(drop),
        |()| {
            let previous = CodexStart {
                port: running.port,
                binary: running
                    .binary
                    .clone()
                    .map_or(Binary::Requested(None), Binary::Exact),
                name: name.clone(),
                proxy: running.proxy.clone(),
                provider: Some(running.provider.clone()),
            };
            serve::serve_start_locked(lease, &support, profiles, previous)
                .map(|_| running.provider.revision)
        },
    )
}

/// The executable, port and proxy the next Codex start uses: the saved
/// runtime, or the running one when none was saved. Checked here, before
/// the running host is stopped.
fn codex_runtime(
    support: &std::path::Path,
    running: &serve::CodexRelaunch,
    saved: Option<&Runtime>,
) -> Result<(std::path::PathBuf, u16, Option<String>)> {
    let (binary, port, proxy) = match saved {
        Some(Runtime::Codex {
            binary,
            port,
            proxy,
        }) => (binary.clone(), *port, proxy.clone()),
        Some(_) => bail!("the saved runtime is not a Codex runtime"),
        None => {
            let binary = running.binary.clone().ok_or_else(|| {
                anyhow!("the running codex executable is unknown; save one and apply again")
            })?;
            return Ok((binary, running.port, running.proxy.clone()));
        },
    };
    let candidate = binary.or_else(|| load_config(support).ok().and_then(|c| c.codex.binary));
    let binary = pocket_codex_codex::locate_binary(candidate.as_deref()).ok_or_else(|| {
        anyhow!("could not find the codex binary to apply; install codex or set its path")
    })?;
    // Automatic keeps the port the host already has, so controllers find it.
    let port = if port == 0 { running.port } else { port };
    if port != running.port && tcp_port_open("127.0.0.1", port) {
        bail!("port {port} is already in use; choose another port");
    }
    if let Some(p) = proxy.as_deref() {
        pocket_codex_api_proxy::validate_proxy(p)?;
    }
    Ok((binary, port, proxy))
}

fn apply_acp(
    lease: &Lease,
    profiles: &std::path::Path,
    running: serve_acp::AcpRelaunch,
    expected: &Expected,
) -> Result<ApplyReport> {
    let desired = host_profiles::resolve_in(profiles, lease.name())?;
    let name = lease.name().to_string();
    orchestrate(
        lease,
        &Current {
            incarnation: &running.incarnation,
            desired: &desired,
            previous: &running.provider,
        },
        expected,
        || {
            let spec = match desired.runtime.clone() {
                Some(Runtime::Acp(spec)) => spec,
                Some(_) => bail!("the saved runtime is not an agent runtime"),
                None => running.spec.clone(),
            };
            serve_acp::prepare(&name, spec, Some(desired.clone()), profiles)
        },
        // The stop keeps the exact launch the host ran with ...
        || Ok(serve_acp::retire(&name)),
        |next| serve_acp::launch_prepared(next).map(drop),
        // ... and the restore starts exactly that: nothing is located,
        // discovered or built again after the failure.
        |previous| {
            let previous = previous
                .ok_or_else(|| anyhow!("the previous launch was not kept; start the host again"))?;
            serve_acp::launch_prepared(previous).map(|_| running.provider.revision)
        },
    )
}

fn apply_opencode(
    lease: &Lease,
    profiles: &std::path::Path,
    running: serve_opencode::Relaunch,
    expected: &Expected,
) -> Result<ApplyReport> {
    let desired = host_profiles::resolve_in(profiles, lease.name())?;
    orchestrate(
        lease,
        &Current {
            incarnation: &running.incarnation,
            desired: &desired,
            previous: &running.prepared.provider,
        },
        expected,
        || {
            let binary = match &desired.runtime {
                Some(Runtime::OpenCode {
                    binary,
                }) => binary.clone(),
                None => Some(running.prepared.binary()),
                Some(_) => bail!("the saved runtime is not an OpenCode runtime"),
            };
            serve_opencode::prepare(lease.name(), binary.as_deref(), desired.clone())
        },
        || serve_opencode::retire(lease.name()),
        |prepared| serve_opencode::launch_prepared(prepared).map(drop),
        |previous| {
            let previous =
                previous.ok_or_else(|| anyhow!("the previous OpenCode launch is unavailable"))?;
            serve_opencode::launch_prepared(previous).map(|_| running.prepared.provider.revision)
        },
    )
}

/// What runs and what is saved, as the apply found them under its lease.
struct Current<'a> {
    incarnation: &'a str,
    desired: &'a host_profiles::Resolved,
    /// The model service the host runs with now (for redaction).
    previous: &'a host_profiles::Resolved,
}

/// The apply itself, with its steps supplied: refuse a moved incarnation or
/// revision, prepare the next launch, and only then stop, start and (when
/// the start fails) restore what the stop captured of the previous launch.
/// A stop that fails (an owned process that did not exit, kept for the next
/// stop or quit) starts nothing: no new launch, and no restore beside it.
/// Every step runs under `lease`.
fn orchestrate<P, R>(
    lease: &Lease,
    current: &Current<'_>,
    expected: &Expected,
    prepare: impl FnOnce() -> Result<P>,
    stop: impl FnOnce() -> Result<R>,
    start: impl FnOnce(P) -> Result<()>,
    restore: impl FnOnce(R) -> Result<u64>,
) -> Result<ApplyReport> {
    let name = lease.name().to_string();
    if expected
        .incarnation
        .as_deref()
        .is_some_and(|seen| seen != current.incarnation)
    {
        bail!("`{name}` was restarted or replaced since you opened it; reload it and try again");
    }
    if expected
        .revision
        .is_some_and(|seen| seen != current.desired.revision)
    {
        bail!("`{name}`'s saved configuration changed since you opened it; reload it first");
    }
    // Nothing has been interrupted when this fails.
    let next = prepare().map_err(|e| anyhow!(redacted(&e, current)))?;
    let previous = stop().map_err(|e| {
        anyhow!("`{name}` did not stop, so nothing was started: {}", redacted(&e, current))
    })?;
    let error = match start(next) {
        Ok(()) => {
            return Ok(ApplyReport {
                name,
                applied: true,
                restored_previous: false,
                error: None,
                restore_error: None,
                revision: Some(current.desired.revision),
            })
        },
        Err(e) => redacted(&e, current),
    };
    let restored = restore(previous);
    let restore_error = restored.as_ref().err().map(|e| redacted(e, current));
    if let Some(restore_error) = &restore_error {
        tracing::warn!(
            service = %name,
            error = %restore_error,
            "restarting the host with its previous configuration failed"
        );
    }
    Ok(ApplyReport {
        name,
        applied: false,
        restored_previous: restored.is_ok(),
        error: Some(error),
        restore_error,
        revision: restored.ok(),
    })
}

/// `error` with the keys of both configurations withheld.
fn redacted(error: &anyhow::Error, current: &Current<'_>) -> String {
    let text = host_profiles::redact(&format!("{error:#}"), current.desired);
    host_profiles::redact(&text, current.previous)
}

#[cfg(test)]
#[path = "host_apply_tests.rs"]
mod tests;
