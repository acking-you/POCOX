//! Stopping native hosts and the app-quit fence.
//!
//! Every stop holds the instance's lease and resolves the host table's own
//! key (native keys keep the spelling they were started with) before it
//! mutates anything. Quitting fences new hosts first: a start that has not
//! recorded its host yet tears it down itself ([`commit_host`]), new
//! operations are refused, the quit waits (bounded) for those in progress
//! and then stops every recorded host under its lease. Only the exact
//! processes this app started are ever signalled (identified when they were
//! spawned, never by whoever listens on their port): an adopted app-server,
//! or one that replaced an exited child on its port, is left running.
//!
//! An owned codex whose exit was not seen stays in [`NATIVE`] under its
//! host's name — put there before its host record is dropped — so a stop,
//! start, restart or quit of that name tries it again and fails while it
//! may still run, instead of forgetting it. Meanwhile the name stays a
//! Codex host for every other provider (`is_hosting_codex`, so an ACP
//! start is refused) and status lists it with [`NOT_EXITED`], so its Stop
//! stays reachable.

use std::sync::atomic::{AtomicBool, Ordering};

use super::*;
use crate::engine::owned_child::Retained;

/// Set once the app quits; never cleared.
static QUITTING: AtomicBool = AtomicBool::new(false);

/// Owned codex processes of native hosts whose exit was not seen yet.
pub(super) static NATIVE: Retained = Retained::new();

/// How long the quit waits for operations in progress. Every lifecycle
/// operation waits for a lease at most this long itself.
const QUIT_WAIT: Duration = host_lease::LEASE_WAIT;

/// Whether the app is quitting.
pub(super) fn quitting() -> bool {
    QUITTING.load(Ordering::SeqCst)
}

/// Record `host` as running, unless `quitting`: then tear it down (the quit
/// may already have stopped every recorded host) and fail.
pub(super) fn commit_host_unless(quitting: &AtomicBool, host: LocalServe) -> Result<()> {
    let mut guard = hosts_locked();
    if quitting.load(Ordering::SeqCst) {
        drop(guard);
        let exited = stop_host_tasks(host);
        bail!("the app is quitting; the host was stopped{}", not_exited(exited));
    }
    guard.insert(host.name.clone(), host);
    Ok(())
}

/// [`commit_host_unless`] for this app.
pub(super) fn commit_host(host: LocalServe) -> Result<()> {
    commit_host_unless(&QUITTING, host)
}

/// What status says of a host whose owned codex did not exit.
pub(super) const NOT_EXITED: &str = "its codex did not exit; stop the host again";

/// The suffix of a teardown message whose codex `exited` (or not).
pub(super) fn not_exited(exited: bool) -> &'static str {
    if exited {
        ""
    } else {
        ", but its codex did not exit; stop the host again"
    }
}

/// The host table's key for the instance `name` (any spelling).
pub(super) fn table_name(name: &str) -> Option<String> {
    hosts_locked()
        .keys()
        .find(|key| host_names::same(key, name))
        .cloned()
}

/// Try again to stop every codex kept for the instance `name` (any
/// spelling); fails while one may still run, so nothing launches beside it.
pub(super) fn settle_retained(name: &str) -> Result<()> {
    if NATIVE
        .settle(|owner| host_names::same(owner, name), EXIT_WAIT)
        .is_empty()
    {
        return Ok(());
    }
    bail!("an earlier codex of `{name}` did not exit; stop the host again")
}

/// Fully stop one host by name: release its three relay keys, abort the
/// watchdog, API proxy, and meta service tasks, and stop its codex (when
/// this app started it). Idempotent — only an earlier codex of the name
/// that did not exit is tried again when that name isn't hosting. Fails
/// while its codex may still run (it is kept, and the next stop or quit
/// tries again).
#[cfg(test)]
pub fn serve_stop(name: &str) -> Result<()> {
    let lease = host_lease::acquire(name, Op::Stop)?;
    serve_stop_locked(&lease, name)
}

/// User-requested stop, durably suppressing automatic restore before any
/// process is touched. A remote controller must provide its observed
/// incarnation.
pub fn serve_stop_remembered(name: &str, expected: Option<&str>) -> Result<()> {
    serve_stop_remembered_checked(name, expected, &|| Ok(()))
}

/// Remote stop, rechecking authorization after any lifecycle wait.
pub(in crate::engine) fn serve_stop_remembered_checked(
    name: &str,
    expected: Option<&str>,
    check: &dyn Fn() -> Result<()>,
) -> Result<()> {
    let lease = host_lease::acquire_checked(name, Op::Stop, check)?;
    if let Some(expected) = expected {
        if super::super::host_apply::active(lease.name())
            .is_none_or(|active| active.incarnation != expected)
        {
            bail!("the host has changed; refresh before stopping it");
        }
    }
    super::super::host_lifecycle::record_stop_in(&host_profiles::root()?, lease.name())?;
    serve_stop_locked(&lease, name)
}

/// [`serve_stop`] with the instance's lease already held.
pub(in crate::engine) fn serve_stop_locked(lease: &Lease, name: &str) -> Result<()> {
    debug_assert!(host_names::same(lease.name(), name), "the lease names this host");
    // The ACP table is keyed canonically, the native one by the started
    // spelling: resolve each table's own key, never the caller's spelling.
    if super::super::serve_opencode::is_hosting(lease.name()) {
        super::super::serve_opencode::stop(lease.name())?;
    } else if super::super::serve_acp::is_hosting(lease.name()) {
        super::super::serve_acp::stop(lease.name());
    } else if let Some(key) = table_name(lease.name()) {
        stop_codex(&key);
    }
    // Every codex this name still keeps, whichever provider hosted it last:
    // a stop never reports success while one may run.
    settle_retained(lease.name())
}

/// Stop the Codex host recorded under `key`, keeping its name claimed until
/// its relay keys and listeners are released; `false` when its own codex
/// could not be seen to exit (it stays in [`NATIVE`]).
fn stop_codex(key: &str) -> bool {
    let mut stopped = true;
    super::super::hosting::retiring(key, super::super::hosting::Provider::Codex, || {
        let removed = {
            let mut hosts = hosts_locked();
            // Kept before the record goes, so a quit sees it in one place.
            if let Some(child) = hosts.get(key).and_then(owned_of) {
                NATIVE.hold(key, child);
            }
            hosts.remove(key)
        };
        if let Some(ls) = removed {
            stopped = stop_host_tasks(ls);
        }
    });
    stopped
}

/// The codex `ls` owns: none when adopted.
fn owned_of(ls: &LocalServe) -> Option<OwnedChild> {
    if ls.adopted {
        None
    } else {
        ls.child
    }
}

/// Stop every host (called on app quit so a real quit leaves no orphan
/// codex). Owned ACP agents go first: their cleanup is bounded and closes
/// the ACP start barrier. Sign-in servers next. Native hosts: fence, refuse
/// new operations, wait (bounded) for those in progress, then stop each
/// under its lease — never around an operation still holding it — and try
/// again every codex an earlier stop could not see exit.
///
/// `Err` names what may still run (an operation that outlived the wait, a
/// sign-in still starting, a child that did not exit): the caller must not
/// exit as if everything had stopped. Calling it again repeats every step
/// for what is left, and fails again while anything remains.
pub fn serve_stop_all() -> Result<()> {
    {
        let _hosts = hosts_locked();
        QUITTING.store(true, Ordering::SeqCst);
    }
    host_lease::close_admission();
    super::super::management::stop();
    super::super::serve_opencode::close_admission();
    super::super::serve_acp::stop_all();
    let mut left = Vec::new();
    if let Err(error) = super::super::codex_login::close_all() {
        left.push(format!("{error:#}"));
    }
    // Held past the wait: those operations still own their processes (a
    // start records or tears down its host itself, behind the fence).
    let drained = host_lease::drain(QUIT_WAIT);
    left.extend(super::super::serve_opencode::stop_all(drained));
    let names: Vec<String> = hosts_locked().keys().cloned().collect();
    for name in names {
        let wait = if drained { QUIT_WAIT } else { Duration::ZERO };
        match host_lease::acquire_for_quit(&name, wait) {
            Ok(lease) => {
                stop_codex(&name);
                drop(lease);
            },
            Err(_) => left.push(format!("`{name}` is still busy")),
        }
    }
    left.extend(
        NATIVE
            .settle(|_| true, EXIT_WAIT)
            .into_iter()
            .map(|name| format!("`{name}`'s codex did not exit")),
    );
    if !drained && left.is_empty() {
        left.push("a host operation is still running".to_string());
    }
    if left.is_empty() {
        return Ok(());
    }
    tracing::error!(left = %left.join("; "), "quitting could not stop everything yet");
    bail!("still stopping: {}; try quitting again", left.join("; "))
}

/// Abort a host's background tasks (all register tunnels, watchdog, API proxy,
/// meta service) and stop its codex when this app started it: exactly that
/// process, never whoever listens on its port now. Does not touch the relay
/// (callers that need an immediate relay drop force-deregister separately).
/// `false` when its own codex was seen running after a forced stop (it is
/// then kept in [`NATIVE`]).
pub(super) fn stop_host_tasks(ls: LocalServe) -> bool {
    let owned = owned_of(&ls);
    // Awaited rather than dropped, so the relay releases all three keys NOW: an
    // immediate re-host under the same name would otherwise race registrations
    // this one abandoned but the relay still held.
    runtime::runtime().block_on(async {
        for published in [ls.app_register, ls.api_register, ls.meta_register]
            .into_iter()
            .flatten()
        {
            if let Err(e) = published.stop().await {
                tracing::warn!(
                    error = %format!("{e:#}"),
                    service = %ls.name,
                    "releasing a relay key on stop failed; it lingers until lease expiry"
                );
            }
        }
    });
    // A watchdog restart in progress holds the lease the caller holds now,
    // so none is running; aborting stops the next one.
    ls.watchdog.abort();
    ls.api_proxy.abort();
    ls.meta_svc.abort();
    if let Some(h) = ls.log_tail {
        h.abort();
    }
    owned.is_none_or(|child| NATIVE.stop(&ls.name, child, EXIT_WAIT))
}
