//! The services of this device that run a harness, and restarting them on
//! the version now installed.
//!
//! A restart keeps everything else as it ran: Codex respawns its app-server
//! on the same port with the same arguments and environment (as its
//! watchdog does), an ACP agent restarts in place from its captured launch,
//! and an owned OpenCode server starts again from its prepared launch. No
//! pending saved configuration is applied. Each one holds its instance's
//! lifecycle lease and names the incarnation it saw, so a service restarted
//! or replaced meanwhile is left alone. An adopted Codex app-server and a
//! host attached to OpenCode's own background server are not this app's to
//! restart.
//!
//! On Windows a running executable cannot be replaced, so Codex
//! app-servers are stopped in place before the update and started again
//! after it, whatever its outcome; elsewhere they restart only once a new
//! version is installed.

use std::collections::BTreeMap;
use std::time::Duration;

use super::view::Skipped;
use super::Kind;
use crate::engine::host_lease::{self, Lease, Op};
use crate::engine::{serve, serve_acp, serve_opencode};

/// Whether running services must stop before their harness is updated.
pub(super) const STOP_FIRST: bool = cfg!(windows);

/// How long a restart waits for an operation already holding a service.
const WAIT: Duration = Duration::from_secs(30);

/// How a service runs its harness.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Engine {
    Codex,
    OpenCode,
    Acp,
}

/// One running service of a harness.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Target {
    /// Its instance name.
    pub(super) name: String,
    incarnation: Option<String>,
    engine: Engine,
    /// Why it cannot be restarted at all.
    skip: Option<&'static str>,
}

/// The running services of this device, by the harness each uses.
pub(super) fn targets() -> BTreeMap<Kind, Vec<Target>> {
    let mut targets: BTreeMap<Kind, Vec<Target>> = BTreeMap::new();
    for status in serve::serve_status() {
        let (kind, engine) = match (status.provider.as_str(), status.profile_id.as_deref()) {
            ("codex", _) => (Kind::Codex, Engine::Codex),
            ("opencode", _) => (Kind::OpenCode, Engine::OpenCode),
            ("acp", Some("claude")) => (Kind::Claude, Engine::Acp),
            ("acp", Some("grok")) => (Kind::Grok, Engine::Acp),
            _ => continue,
        };
        let skip = match engine {
            Engine::Codex if serve::codex_relaunch(&status.name).is_some_and(|run| run.adopted) => {
                Some("adopted")
            },
            Engine::OpenCode
                if status
                    .opencode
                    .as_ref()
                    .is_some_and(|o| o.background_server) =>
            {
                Some("shared_server")
            },
            _ => None,
        };
        targets.entry(kind).or_default().push(Target {
            name: status.name,
            incarnation: status.incarnation,
            engine,
            skip,
        });
    }
    for services in targets.values_mut() {
        services.sort_by(|a, b| a.name.cmp(&b.name));
    }
    targets
}

/// What restarting came to.
#[derive(Debug, Default)]
pub(super) struct Outcome {
    /// Restarted on the installed version.
    pub(super) restarted: Vec<String>,
    /// Not restarted, and why.
    pub(super) skipped: Vec<Skipped>,
}

impl Outcome {
    fn skip(&mut self, name: &str, reason: &str) {
        self.skipped.push(Skipped {
            name: name.into(),
            reason: reason.into(),
        });
    }

    /// Record every target as not restarted for `reason`.
    pub(super) fn skip_all(&mut self, targets: &[Target], reason: &str) {
        for target in targets {
            self.skip(&target.name, target.skip.unwrap_or(reason));
        }
    }
}

/// A Codex service stopped before an update, holding its lease until it is
/// started again.
pub(super) struct Paused {
    name: String,
    lease: Lease,
    stopped: serve::Stopped,
}

fn lease(target: &Target, outcome: &mut Outcome) -> Option<(Lease, String)> {
    if let Some(reason) = target.skip {
        outcome.skip(&target.name, reason);
        return None;
    }
    let Some(incarnation) = target.incarnation.clone() else {
        outcome.skip(&target.name, "changed");
        return None;
    };
    match host_lease::acquire_within(&target.name, Op::Restart, WAIT) {
        Ok(lease) => Some((lease, incarnation)),
        Err(error) => {
            tracing::info!(service = %target.name, "not restarted after its update: {error:#}");
            outcome.skip(&target.name, "busy");
            None
        },
    }
}

fn failed(name: &str, error: &anyhow::Error, outcome: &mut Outcome) {
    tracing::warn!(service = %name, "restart after a harness update failed: {error:#}");
    outcome.skip(name, "failed");
}

/// Stop the Codex services among `targets` before an update ([`STOP_FIRST`]).
pub(super) fn pause(targets: &[Target], outcome: &mut Outcome) -> Vec<Paused> {
    let mut paused = Vec::new();
    for target in targets
        .iter()
        .filter(|target| target.engine == Engine::Codex)
    {
        let Some((lease, incarnation)) = lease(target, outcome) else { continue };
        match serve::stop_in_place(&lease, &incarnation) {
            Ok(Some(stopped)) => paused.push(Paused {
                name: target.name.clone(),
                lease,
                stopped,
            }),
            Ok(None) => outcome.skip(&target.name, "changed"),
            Err(error) => failed(&target.name, &error, outcome),
        }
    }
    paused
}

/// Start the services [`pause`] stopped, on whatever is installed now.
pub(super) fn resume(paused: Vec<Paused>, outcome: &mut Outcome) {
    for Paused {
        name,
        lease,
        stopped,
    } in paused
    {
        match serve::start_in_place(&lease, stopped) {
            Ok(()) => outcome.restarted.push(name),
            Err(error) => failed(&name, &error, outcome),
        }
    }
}

/// Restart `targets` on the installed version, one at a time.
pub(super) fn restart(targets: &[Target], outcome: &mut Outcome) {
    for target in targets {
        let Some((lease, incarnation)) = lease(target, outcome) else { continue };
        let result = match target.engine {
            Engine::Codex => serve::stop_in_place(&lease, &incarnation).and_then(|stopped| {
                stopped
                    .map(|stopped| serve::start_in_place(&lease, stopped).map(|()| true))
                    .unwrap_or(Ok(false))
            }),
            Engine::Acp => serve_acp::restart_locked(&lease, Some(&incarnation)),
            Engine::OpenCode => serve_opencode::restart_locked(&lease, &incarnation),
        };
        match result {
            Ok(true) => outcome.restarted.push(target.name.clone()),
            Ok(false) => outcome.skip(&target.name, "changed"),
            Err(error) => failed(&target.name, &error, outcome),
        }
    }
}
