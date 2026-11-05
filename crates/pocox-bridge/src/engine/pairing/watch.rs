//! How a long-running owner learns what happened without a foreground page.
//!
//! A peer's removal changes nothing in the shared store, and a host's
//! credential can have most of a day left, so a process that may host asks
//! every minute. Nothing runs for GitHub or self-hosted setups: the tick stops
//! at the first check of the configuration.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use anyhow::Result;
use pocox_account_proto::pairing::PairingErrorCode;
use pocox_core::config::{AccountProvider, Mode};

use super::error::code_of;
use super::identity::Identity;
use super::{lifecycle, operations, session};
use crate::engine::config::load_config;
use crate::engine::runtime;

const INTERVAL: Duration = Duration::from_secs(60);

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
            tokio::time::sleep(INTERVAL).await;
        }
    });
}

/// One check: settle what is outstanding and find out whether this session
/// still stands. A change of user reacts through the session it refreshes on
/// the way.
pub async fn tick(support: &Path) -> Result<()> {
    let mut config = load_config(support)?;
    if config.account_mode() != Mode::Account
        || config.account_provider() != AccountProvider::DeviceCode
    {
        return Ok(());
    }
    let identity = Identity::of_config(support, &config)?;
    operations::settle(&identity).await?;
    if lifecycle::holding() {
        // The JWT says nothing about a Continue another installation just made,
        // and a dead identity has no refresh left to try.
        let refreshed = session::refresh_now(support, &mut config, identity.backend()).await;
        lifecycle::enforce_hold().await;
        return match refreshed {
            Err(error)
                if matches!(
                    code_of(&error),
                    Some(PairingErrorCode::DeviceSuperseded | PairingErrorCode::DeviceUnknown)
                ) =>
            {
                Ok(())
            },
            other => other.map(drop),
        };
    }
    session::check_in(&identity).await.map(drop)
}
