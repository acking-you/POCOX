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
//! ```
//!
//! Only a process running the engine on this support directory reacts; a plain
//! CLI command owns nothing long-lived and just exits. Only the owner of the
//! hosting state ever stops or restarts a host ([`host_owner`]). A hold is
//! memory because the backend is the authority: a removed device has no
//! activation, so after a restart `/v1/relay` refuses it just the same.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

use anyhow::{bail, Result};
use pocox_account_proto::pairing::{DeviceSession, PairingErrorCode};
use pocox_core::config::{AccountProvider, Mode};

use super::error::code_of;
use crate::engine::config::load_config;
use crate::engine::host_lease::{self, Op};
#[cfg(not(test))]
use crate::engine::host_lifecycle;
use crate::engine::{account, host_owner, runtime, serve, transport};

/// A change of user is stopping what the old user owned. A start already
/// holding a host's lease must not sit waiting for a token the change is
/// holding up, or the stop would sit waiting for that lease in turn.
static CHANGING: AtomicBool = AtomicBool::new(false);
/// Nothing hosts until an explicit Continue.
static HOLDING: AtomicBool = AtomicBool::new(false);
/// Hosts a change stopped, which start again once this device may host.
static STOPPED: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// Which support directory a test pretends this process's engine runs on.
#[cfg(test)]
pub(super) static TEST_ENGINE: Mutex<Option<PathBuf>> = Mutex::new(None);
/// Hosts a test saw restarted, in place of starting real agents.
#[cfg(test)]
pub(super) static TEST_RESTARTED: Mutex<Vec<String>> = Mutex::new(Vec::new());
/// Which user `config.toml` named while what the old user owned was stopping.
#[cfg(test)]
pub(super) static TEST_STOPPED_UNDER: Mutex<Option<String>> = Mutex::new(None);

fn owns(support: &Path) -> bool {
    #[cfg(test)]
    {
        TEST_ENGINE
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .as_deref()
            == Some(support)
    }
    #[cfg(not(test))]
    {
        runtime::support_dir().is_ok_and(|dir: PathBuf| dir == support)
    }
}

/// Refuse token work while a change of user is stopping things.
pub(super) fn refuse_while_changing() -> Result<()> {
    if CHANGING.load(Ordering::SeqCst) {
        bail!("this device's account is changing; try again");
    }
    Ok(())
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
    CHANGING.store(true, Ordering::SeqCst);
    // The epoch moves first: work in flight sees the change and backs out.
    account::forget_relay_credential().await;
    transport::context_changed();
    stop_hosts().await;
    #[cfg(test)]
    {
        *TEST_STOPPED_UNDER
            .lock()
            .unwrap_or_else(|poison| poison.into_inner()) = load_config(support)
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
    if !session.activated {
        HOLDING.store(true, Ordering::SeqCst);
        return;
    }
    HOLDING.store(false, Ordering::SeqCst);
    let names = std::mem::take(&mut *stopped());
    if !names.is_empty() {
        tokio::task::spawn_blocking(move || restart(&names));
    }
}

/// This device's secret is dead: superseded or unknown. Stop renewing it and
/// hosting on it until the user chooses what to do.
pub(super) async fn identity_dead(support: &Path) {
    if !owns(support) {
        return;
    }
    HOLDING.store(true, Ordering::SeqCst);
    CHANGING.store(true, Ordering::SeqCst);
    account::forget_relay_credential().await;
    transport::context_changed();
    stop_hosts().await;
    CHANGING.store(false, Ordering::SeqCst);
}

/// The user stopped being a pairing device here, so no Continue will come.
pub(in crate::engine) fn release_hold() {
    HOLDING.store(false, Ordering::SeqCst);
    stopped().clear();
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
/// setups.
pub(in crate::engine) fn require_may_host(name: &str) -> Result<()> {
    #[cfg(test)]
    let support = {
        // Other tests' hosts share this process's lease table.
        if !name.starts_with("pairing-test-") {
            return Ok(());
        }
        let engine = TEST_ENGINE
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .clone();
        let Some(support) = engine else {
            return Ok(());
        };
        support
    };
    #[cfg(not(test))]
    let _ = name;
    #[cfg(not(test))]
    let Ok(support) = runtime::support_dir() else {
        return Ok(());
    };
    let Ok(config) = load_config(&support) else {
        return Ok(());
    };
    if config.account_mode() != Mode::Account
        || config.account_provider() != AccountProvider::DeviceCode
        || runtime::host_transport().is_some()
    {
        return Ok(());
    }
    if holding() {
        bail!("this device cannot host until you continue or restore it");
    }
    match runtime::runtime().block_on(account::relay_credential(&support)) {
        Err(error) if code_of(&error) == Some(PairingErrorCode::DeviceNotActivated) => {
            bail!("this device is not set up; continue on this device before hosting")
        },
        _ => Ok(()),
    }
}

fn stopped() -> std::sync::MutexGuard<'static, Vec<String>> {
    STOPPED.lock().unwrap_or_else(|poison| poison.into_inner())
}

async fn stop_hosts() {
    if host_owner::require().is_err() {
        return;
    }
    let stopped_now = tokio::task::spawn_blocking(stop_every_host)
        .await
        .unwrap_or_default();
    let mut remembered = stopped();
    for name in stopped_now {
        if !remembered.contains(&name) {
            remembered.push(name);
        }
    }
}

/// Stop each host without touching its restore choice: the user did not ask for
/// this stop, and these same hosts start again under the new user.
fn stop_every_host() -> Vec<String> {
    let mut done = Vec::new();
    for name in serve::owned_host_names() {
        // Other tests' hosts share this process's table.
        #[cfg(test)]
        if !name.starts_with("pairing-test-") {
            continue;
        }
        let stopped = host_lease::acquire(&name, Op::Stop)
            .and_then(|lease| serve::serve_stop_locked(&lease, &name));
        match stopped {
            Ok(()) => done.push(name),
            Err(error) => {
                tracing::error!(service = %name, "not stopped for an account change: {error:#}");
            },
        }
    }
    done
}

fn restart(names: &[String]) {
    #[cfg(test)]
    {
        TEST_RESTARTED
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .extend(names.iter().cloned());
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
            let Some(entry) = entries.get(name).filter(|entry| entry.runtime.is_some()) else {
                continue;
            };
            if let Err(error) = host_lifecycle::restore(name, Some(entry.revision), None) {
                tracing::warn!(service = %name, "not restarted: {error:#}");
                host_lifecycle::record_restore_failure(name);
            }
        }
    }
}
