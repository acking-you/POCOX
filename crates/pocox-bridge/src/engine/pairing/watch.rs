//! How a long-running owner learns what happened without a foreground page.
//!
//! A peer's removal changes nothing in the shared store, and a host's
//! credential can have most of a day left, so a process that may host asks
//! every minute. A command in another terminal changes `config.toml` under it,
//! which is compared on every tick. A GitHub or self-hosted setup that never
//! touched pairing reads its configuration and stops there.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::LazyLock;
use std::time::Duration;

use anyhow::Result;
use pocox_account_proto::pairing::PairingErrorCode;
use pocox_core::config::{AccountProvider, Config, Mode};
use tokio::sync::Notify;

use super::error::code_of;
use super::identity::{store_exists, Identity};
use super::{lifecycle, operations, session};
use crate::engine::config::load_config;
use crate::engine::runtime;

const INTERVAL: Duration = Duration::from_secs(60);

static WAKE: LazyLock<Notify> = LazyLock::new(Notify::new);
/// Whether this process has heard once whether this device may host. After a
/// restart nothing else would say: a removal left no trace but its absence.
static LOOKED: AtomicBool = AtomicBool::new(false);

/// Start watching this process's installation, once.
pub fn start() {
    static STARTED: AtomicBool = AtomicBool::new(false);
    if STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    let Ok(support) = runtime::support_dir() else {
        return;
    };
    runtime::runtime().spawn(async move {
        loop {
            if let Err(error) = tick(&support).await {
                tracing::debug!("pairing check: {error:#}");
            }
            tokio::select! {
                () = tokio::time::sleep(INTERVAL) => {},
                () = WAKE.notified() => {},
            }
        }
    });
}

/// Check now rather than at the next minute: this process just changed its own
/// account by a path that does not stop anything itself.
pub(in crate::engine) fn wake() {
    WAKE.notify_one();
}

/// One check: follow what `config.toml` now says, settle what is outstanding,
/// and find out whether this session still stands. A change of user reacts
/// through the session it refreshes on the way.
pub async fn tick(support: &Path) -> Result<()> {
    if lifecycle::pinned_to_a_relay() {
        return Ok(());
    }
    lifecycle::follow(support).await?;
    lifecycle::settle_owed(support).await;
    let config = load_config(support)?;
    if config.account_mode() != Mode::Account
        || config.account_provider() != AccountProvider::DeviceCode
    {
        settle_saved(support, &config).await;
        return Ok(());
    }
    let identity = Identity::of_config(support, &config)?;
    operations::settle(&identity).await?;
    if lifecycle::holding() || !LOOKED.load(Ordering::SeqCst) {
        // The JWT says nothing about a Continue another installation just made,
        // and a dead identity has no refresh left to try.
        let mut config = load_config(support)?;
        let refreshed = session::refresh_now(support, &mut config, identity.backend()).await;
        lifecycle::enforce_hold().await;
        return match refreshed {
            Err(error)
                if matches!(
                    code_of(&error),
                    Some(PairingErrorCode::DeviceSuperseded | PairingErrorCode::DeviceUnknown)
                ) =>
            {
                LOOKED.store(true, Ordering::SeqCst);
                Ok(())
            },
            Ok(_) => {
                LOOKED.store(true, Ordering::SeqCst);
                Ok(())
            },
            Err(error) => Err(error),
        };
    }
    session::check_in(&identity).await.map(drop)
}

/// A change a screen or command started and could not finish, on an
/// installation not using pairing right now. Costs nothing but a read when none
/// is saved.
async fn settle_saved(support: &Path, config: &Config) {
    if !store_exists(support) {
        return;
    }
    let Ok(identity) = Identity::of_config(support, config) else {
        return;
    };
    let saved = identity
        .read()
        .ok()
        .flatten()
        .is_some_and(|record| !record.operations.is_empty());
    if saved {
        if let Err(error) = operations::settle(&identity).await {
            tracing::debug!("settling a saved pairing change: {error:#}");
        }
    }
}

/// Forget that this process has looked, as a restarted one has not.
#[cfg(test)]
pub(super) fn forget_having_looked() {
    LOOKED.store(false, Ordering::SeqCst);
}
