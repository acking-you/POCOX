//! What a change of user does to what this process runs.
//!
//! ```text
//!   refresh says another user ─▶ before_user_change   caches, tunnels, hosts stop
//!                                     │
//!                               config.toml written
//!                                     │
//!                               after_persist
//!                                ├ activated (linked, left, restored, Continue)
//!                                │    └▶ the hosts it stopped start again
//!                                └ not activated (removed)
//!                                     └▶ hold: nothing hosts until Continue
//!
//!   another process wrote it first ─▶ follow   the same stop, then the same answer
//! ```
//!
//! Only a process running the engine on this support directory reacts; a plain
//! CLI command owns nothing long-lived and just exits, and a process given an
//! explicit relay does not depend on the account at all. Only the owner of the
//! hosting state ever stops or restarts a host ([`host_owner`]). A hold is
//! memory because the backend is the authority: a removed device has no
//! activation, so after a restart `/v1/relay` refuses it just the same.

use std::path::Path;
#[cfg(not(test))]
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use anyhow::{bail, Result};
use pocox_account_proto::pairing::{DeviceSession, PairingErrorCode};
use pocox_core::config::{AccountProvider, Config, Mode};

use super::error::{code_of, refusal_of, PairingError};
use super::identity::digest;
use super::session::Principal;
use crate::engine::config::load_config;
use crate::engine::host_lease::{self, Op};
use crate::engine::{account, host_lifecycle, host_names, host_owner, runtime, serve, transport};

/// How long a change waits for a host another operation holds before it owes
/// that host a stop instead. Past this it may be the very start that is waiting
/// for the token this change is holding up.
#[cfg(not(test))]
const STOP_WAIT: Duration = Duration::from_secs(10);
#[cfg(test)]
const STOP_WAIT: Duration = Duration::from_millis(1500);

/// A change of user is stopping what the old user owned. A start already
/// holding a host's lease must not sit waiting for a token the change is
/// holding up, or the stop would sit waiting for that lease in turn.
static CHANGING: AtomicBool = AtomicBool::new(false);
/// Nothing hosts until an explicit Continue.
static HOLDING: AtomicBool = AtomicBool::new(false);
/// Hosts a change stopped, which start again once this device may host.
static STOPPED: Mutex<Vec<String>> = Mutex::new(Vec::new());
/// Hosts a change could not stop, still owed a stop and a start.
static OWED: Mutex<Vec<String>> = Mutex::new(Vec::new());
/// The account what this process runs belongs to.
static HOSTED_UNDER: Mutex<Option<Principal>> = Mutex::new(None);
/// The secret the backend called dead, so this process stops asking.
static DEAD: Mutex<Option<DeadSecret>> = Mutex::new(None);

struct DeadSecret {
    digest: String,
    refusal: PairingError,
}

/// Which support directory a test pretends this process's engine runs on.
#[cfg(test)]
pub(super) static TEST_ENGINE: Mutex<Option<std::path::PathBuf>> = Mutex::new(None);
/// Whether a test pretends this process was given an explicit relay.
#[cfg(test)]
pub(super) static TEST_PINNED: AtomicBool = AtomicBool::new(false);
/// Hosts a test saw restarted, in place of starting real agents.
#[cfg(test)]
pub(super) static TEST_RESTARTED: Mutex<Vec<String>> = Mutex::new(Vec::new());
/// Which user `config.toml` named while what the old user owned was stopping.
#[cfg(test)]
pub(super) static TEST_STOPPED_UNDER: Mutex<Option<String>> = Mutex::new(None);
/// What a test pretends the restore ledger holds.
#[cfg(test)]
pub(super) static TEST_LEDGER: Mutex<Vec<String>> = Mutex::new(Vec::new());

fn guarded<T>(lock: &'static Mutex<T>) -> std::sync::MutexGuard<'static, T> {
    lock.lock().unwrap_or_else(|poison| poison.into_inner())
}

fn on_this_support(support: &Path) -> bool {
    #[cfg(test)]
    {
        guarded(&TEST_ENGINE).as_deref() == Some(support)
    }
    #[cfg(not(test))]
    {
        runtime::support_dir().is_ok_and(|dir: PathBuf| dir == support)
    }
}

/// Whether this process was given an explicit relay. Its tunnels do not depend
/// on `[account]`, so nothing about the account stops them.
pub(super) fn pinned_to_a_relay() -> bool {
    #[cfg(test)]
    {
        TEST_PINNED.load(Ordering::SeqCst)
    }
    #[cfg(not(test))]
    {
        runtime::host_transport().is_some()
    }
}

fn owns(support: &Path) -> bool {
    on_this_support(support) && !pinned_to_a_relay()
}

/// Refuse token work on `support` while a change of user is stopping things
/// there.
pub(super) fn refuse_while_changing(support: &Path) -> Result<()> {
    if CHANGING.load(Ordering::SeqCst) && on_this_support(support) {
        bail!("this device's account is changing; try again");
    }
    Ok(())
}

/// Whether a change of user is stopping things right now.
#[cfg(test)]
pub(super) fn changing() -> bool {
    CHANGING.load(Ordering::SeqCst)
}

/// Whether this process is holding its hosts until Continue.
pub fn holding() -> bool {
    HOLDING.load(Ordering::SeqCst)
}

/// Stop everything the current user owns here, before another user is written.
pub(super) async fn before_user_change(support: &Path) {
    if !owns(support) {
        return;
    }
    tracing::info!("this installation's account is changing: stopping what the old one owned");
    CHANGING.store(true, Ordering::SeqCst);
    // The epoch moves first: work in flight sees the change and backs out.
    account::forget_relay_credential().await;
    transport::context_changed();
    stop_hosts().await;
    #[cfg(test)]
    {
        *guarded(&TEST_STOPPED_UNDER) = load_config(support)
            .ok()
            .and_then(|config| config.account_id().map(str::to_string));
    }
    CHANGING.store(false, Ordering::SeqCst);
}

/// The new session is written. Start what the change stopped, or hold.
pub(super) fn after_persist(support: &Path, session: &DeviceSession) {
    if !owns(support) {
        return;
    }
    note_hosted_under(support);
    if !session.activated {
        tracing::warn!("this device is not set up: it hosts nothing until you continue");
        HOLDING.store(true, Ordering::SeqCst);
        return;
    }
    let held = HOLDING.swap(false, Ordering::SeqCst);
    restart_stopped(held);
}

/// The new session never reached `config.toml`: nothing changed, so what was
/// stopped for it starts again.
pub(super) fn after_failed_persist(support: &Path) {
    if owns(support) {
        restart_stopped(false);
    }
}

/// `config.toml` no longer names a pairing session, so no Continue will come.
/// What the change stopped starts again if anything else here can publish it.
pub(super) fn left_pairing(support: &Path, config: &Config) {
    if !owns(support) {
        return;
    }
    *guarded(&HOSTED_UNDER) = Some(Principal::of(config));
    *guarded(&DEAD) = None;
    let held = HOLDING.swap(false, Ordering::SeqCst);
    if config.account_mode() == Mode::Unconfigured {
        guarded(&STOPPED).clear();
        guarded(&OWED).clear();
        return;
    }
    restart_stopped(held);
}

/// Follow a change another process wrote: `pocox pair join` in another terminal
/// is the only way to confirm a move on a headless host, and it reaches
/// `config.toml` first, so this process finds a matching JWT and nothing of its
/// own to react to. A setup that never touches pairing is left to the rules it
/// has always had.
pub(super) async fn follow(support: &Path) -> Result<()> {
    if !owns(support) {
        return Ok(());
    }
    // A change this process is making holds this lock from its stop to its note of
    // the new user, so it is never mistaken here for one made elsewhere.
    let _guard = account::refresh_lock().lock().await;
    let config = load_config(support)?;
    let now = Principal::of(&config);
    let previous = guarded(&HOSTED_UNDER).replace(now.clone());
    let Some(previous) = previous else {
        return Ok(());
    };
    if !previous.moved_to(&now) {
        return Ok(());
    }
    tracing::info!("another process changed this installation's account");
    before_user_change(support).await;
    if now.is_device() {
        // Whether this user may host is the next refresh's to say, and it says so
        // through after_persist on this same tick or a later one.
        HOLDING.store(true, Ordering::SeqCst);
    } else {
        left_pairing(support, &config);
    }
    Ok(())
}

/// Try again to stop what a change could not.
pub(super) async fn settle_owed(support: &Path) {
    if !owns(support) {
        return;
    }
    let names = std::mem::take(&mut *guarded(&OWED));
    if names.is_empty() {
        return;
    }
    stop_named(names).await;
    if !holding() {
        restart_stopped(false);
    }
}

fn note_hosted_under(support: &Path) {
    if let Ok(config) = load_config(support) {
        *guarded(&HOSTED_UNDER) = Some(Principal::of(&config));
    }
}

/// What the backend said about `secret`, if it already called it dead here.
pub(super) fn known_dead(secret: &str) -> Option<PairingError> {
    let digest = digest(secret);
    guarded(&DEAD)
        .as_ref()
        .filter(|dead| dead.digest == digest)
        .map(|dead| dead.refusal.clone())
}

/// This device's secret is dead: superseded or unknown. Stop renewing it and
/// hosting on it until the user chooses what to do. Once per secret: dropping
/// the transport's context again would keep failing whatever a user kept open.
pub(super) async fn identity_dead(support: &Path, secret: &str, error: &anyhow::Error) {
    if !owns(support) || known_dead(secret).is_some() {
        return;
    }
    if let Some(refusal) = refusal_of(error) {
        *guarded(&DEAD) = Some(DeadSecret {
            digest: digest(secret),
            refusal: refusal.clone(),
        });
    }
    tracing::warn!("this device's identity ended: it hosts nothing until you choose what to do");
    HOLDING.store(true, Ordering::SeqCst);
    CHANGING.store(true, Ordering::SeqCst);
    account::forget_relay_credential().await;
    transport::context_changed();
    stop_hosts().await;
    CHANGING.store(false, Ordering::SeqCst);
}

/// A held process checks that nothing started or survived.
pub(super) async fn enforce_hold() {
    if holding() {
        stop_hosts().await;
    }
}

/// Refuse a start while this device may not host: a hold, or a backend that
/// says this device has no activation, as it does after a removal even when
/// this process just started. Anything else (offline, say) stays for the start
/// to discover, as it always has. Touches nothing on GitHub or self-hosted
/// setups. What was refused starts when Continue comes, if it is saved to
/// restore.
pub(in crate::engine) fn require_may_host(name: &str) -> Result<()> {
    #[cfg(test)]
    let support = {
        // Other tests' hosts share this process's lease table.
        if !name.starts_with("pairing-test-") {
            return Ok(());
        }
        let engine = guarded(&TEST_ENGINE).clone();
        let Some(support) = engine else {
            return Ok(());
        };
        support
    };
    #[cfg(not(test))]
    let Ok(support) = runtime::support_dir() else {
        return Ok(());
    };
    let Ok(config) = load_config(&support) else {
        return Ok(());
    };
    if config.account_mode() != Mode::Account
        || config.account_provider() != AccountProvider::DeviceCode
        || pinned_to_a_relay()
    {
        return Ok(());
    }
    if holding() {
        remember(&mut guarded(&STOPPED), [name.to_string()]);
        bail!("this device cannot host until you continue or restore it");
    }
    match runtime::runtime().block_on(account::relay_credential(&support)) {
        Err(error) if code_of(&error) == Some(PairingErrorCode::DeviceNotActivated) => {
            HOLDING.store(true, Ordering::SeqCst);
            remember(&mut guarded(&STOPPED), [name.to_string()]);
            bail!("this device is not set up; continue on this device before hosting")
        },
        _ => Ok(()),
    }
}

fn remember(list: &mut Vec<String>, names: impl IntoIterator<Item = String>) {
    for name in names {
        if !list.contains(&name) {
            list.push(name);
        }
    }
}

async fn stop_hosts() {
    if host_owner::require().is_err() {
        return;
    }
    stop_named(serve::owned_host_names()).await;
}

async fn stop_named(names: Vec<String>) {
    let (stopped, busy) = tokio::task::spawn_blocking(move || stop_each(names))
        .await
        .unwrap_or_default();
    remember(&mut guarded(&STOPPED), stopped);
    remember(&mut guarded(&OWED), busy);
}

/// Stop each host without touching its restore choice: the user did not ask for
/// this stop, and these same hosts start again under the new user. Returns
/// those it stopped and those still owed.
fn stop_each(names: Vec<String>) -> (Vec<String>, Vec<String>) {
    let (mut stopped, mut busy) = (Vec::new(), Vec::new());
    for name in names {
        // Other tests' hosts share this process's table.
        #[cfg(test)]
        if !name.starts_with("pairing-test-") {
            continue;
        }
        let outcome = host_lease::acquire_within(&name, Op::Stop, STOP_WAIT)
            .and_then(|lease| serve::serve_stop_locked(&lease, &name));
        match outcome {
            Ok(()) => stopped.push(name),
            Err(error) => {
                tracing::warn!(service = %name, "not stopped yet for an account change: {error:#}");
                busy.push(name);
            },
        }
    }
    (stopped, busy)
}

/// Start what a change stopped. A hold that ended also brings back whatever the
/// ledger says should run, since a process restarted while removed stopped
/// nothing itself.
fn restart_stopped(hold_ended: bool) {
    let mut names = std::mem::take(&mut *guarded(&STOPPED));
    if hold_ended {
        remember(&mut names, restorable_hosts());
    }
    if !names.is_empty() {
        tokio::task::spawn_blocking(move || restart(&names));
    }
}

/// Saved to restore and not running.
fn restorable_hosts() -> Vec<String> {
    if host_owner::require().is_err() {
        return Vec::new();
    }
    let running = serve::owned_host_names();
    #[cfg(test)]
    let saved = guarded(&TEST_LEDGER).clone();
    #[cfg(not(test))]
    let saved: Vec<String> = match host_lifecycle::entries() {
        Ok(entries) => entries
            .into_iter()
            .filter(|(_, entry)| entry.runtime.is_some())
            .map(|(name, _)| name)
            .collect(),
        Err(error) => {
            tracing::error!("reading what to restore after a hold: {error:#}");
            Vec::new()
        },
    };
    saved
        .into_iter()
        .filter(|name| !running.contains(name))
        .collect()
}

/// What the ledger says about a host a change stopped.
#[derive(Debug, PartialEq, Eq)]
enum RestartPlan {
    /// Start it as saved.
    Restore(u64),
    /// The user has since chosen not to run it.
    Leave,
    /// It ran with nothing saved, so it cannot come back on its own.
    Lost,
}

/// The ledger is keyed by canonical name, which is not always how a host's
/// table spells it.
fn plan_restart(
    entries: &std::collections::BTreeMap<String, host_lifecycle::Entry>,
    name: &str,
) -> RestartPlan {
    let entry = host_names::canonical(name)
        .ok()
        .and_then(|canonical| entries.get(&canonical));
    match entry {
        Some(entry) if entry.runtime.is_some() => RestartPlan::Restore(entry.revision),
        Some(_) => RestartPlan::Leave,
        None => RestartPlan::Lost,
    }
}

fn restart(names: &[String]) {
    #[cfg(test)]
    {
        guarded(&TEST_RESTARTED).extend(names.iter().cloned());
    }
    #[cfg(not(test))]
    {
        let entries = match host_lifecycle::entries() {
            Ok(entries) => entries,
            Err(error) => {
                tracing::error!("hosts not restarted after an account change: {error:#}");
                return;
            },
        };
        for name in names {
            match plan_restart(&entries, name) {
                RestartPlan::Restore(revision) => {
                    if let Err(error) = host_lifecycle::restore(name, Some(revision), None) {
                        tracing::warn!(service = %name, "not restarted: {error:#}");
                        host_lifecycle::record_restore_failure(name);
                    }
                },
                RestartPlan::Leave => {},
                RestartPlan::Lost => {
                    tracing::warn!(service = %name, "stopped for an account change, and nothing is saved to restart it");
                    host_lifecycle::record_restore_failure(name);
                },
            }
        }
    }
}

/// Clear what a process remembers, as a test's next pretend process has none.
#[cfg(test)]
pub(super) fn forget_everything() {
    HOLDING.store(false, Ordering::SeqCst);
    CHANGING.store(false, Ordering::SeqCst);
    guarded(&STOPPED).clear();
    guarded(&OWED).clear();
    guarded(&TEST_LEDGER).clear();
    *guarded(&HOSTED_UNDER) = None;
    *guarded(&DEAD) = None;
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use crate::engine::host_profiles::Runtime;

    #[test]
    fn the_ledger_is_read_by_canonical_name() {
        let canonical = host_names::canonical("My Host").expect("name");
        let entries = BTreeMap::from([(canonical, host_lifecycle::Entry {
            revision: 7,
            runtime: Some(Runtime::Codex {
                binary: None,
                port: 0,
                proxy: None,
            }),
        })]);
        assert_eq!(plan_restart(&entries, "My Host"), RestartPlan::Restore(7));
        assert_eq!(plan_restart(&entries, "Another"), RestartPlan::Lost);
    }
}
