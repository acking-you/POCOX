//! An account's relay key, as a long-running command holds one.
//!
//! A computer that sleeps past its key's end wakes to a relay that refuses that
//! key for good, and nothing else would start the command's tunnels again, so
//! it fetches the key that replaced it. Only the backend saying no about this
//! device, or handing over another user's namespace, ends that.

use std::time::Duration;

use pocox_account_proto::pairing::PairingErrorCode;
use pocox_bridge::pairing::{NoDevice, PairingError, SignedOut};
use pocox_core::config::{Config, Mode};
use pocox_pb::RelaySession;
use tokio::sync::watch;

use crate::commands::{account, worker};

/// How many times a command asks for a new key before giving up: about two
/// minutes, enough for a network that is still coming back after a sleep.
const REPLACEMENT_TRIES: usize = 8;
const MAX_REPLACEMENT_WAIT: Duration = Duration::from_secs(60);

/// Whether `session` is an account's own credential, rather than a relay the
/// caller named with its key. Only then does anything about the account concern
/// what runs on it.
pub(crate) fn on_account_credential(session: &RelaySession, config: &Config) -> bool {
    session.credential.starts_with("pbmt1_") && config.account_mode() == Mode::Account
}

/// Whether what the relay said means this credential is over, rather than
/// anything passing.
pub(crate) fn credential_refused(said: &str) -> bool {
    said.contains("temporary_key_expired") || said.contains("temporary_key_revoked")
}

/// Whether the backend's refusal is about this device itself, which no amount
/// of asking again changes.
fn about_this_device(error: &anyhow::Error) -> bool {
    let refused = error
        .chain()
        .find_map(|cause| cause.downcast_ref::<PairingError>())
        .is_some_and(|refusal| {
            matches!(
                refusal.code,
                PairingErrorCode::DeviceNotActivated
                    | PairingErrorCode::DeviceSuperseded
                    | PairingErrorCode::DeviceUnknown
                    | PairingErrorCode::DeviceSessionRequired
                    | PairingErrorCode::PairingClientUpgradeRequired
            )
        });
    refused
        || error
            .chain()
            .any(|cause| cause.is::<SignedOut>() || cause.is::<NoDevice>())
}

/// A new credential for `key`, if the backend gives this same user one.
/// Anything but a refusal about this device is asked again, within a bound, at
/// the wait the backend names when it names one.
pub(crate) async fn replacement_credential(
    session: &RelaySession,
    key: &str,
    config: &Config,
) -> Option<RelaySession> {
    let backend = account::backend_base(None, config);
    let mut delay = Duration::from_secs(2);
    for _ in 0..REPLACEMENT_TRIES {
        let mut latest = Config::load().unwrap_or_else(|_| config.clone());
        match account::fetch_relay_credential(&mut latest, &backend).await {
            Ok(relay) => {
                let same_user = key.starts_with(&format!("pcxu:{}:", relay.namespace));
                let new = relay.credential != session.credential;
                return (same_user && new).then(|| {
                    RelaySession::new(relay.relay_addr, relay.credential)
                        .with_preferences(&latest.pb_mapper)
                });
            },
            Err(error) if about_this_device(&error) => {
                tracing::warn!("this key was not replaced: {error:#}");
                return None;
            },
            Err(error) => {
                let asked = error
                    .chain()
                    .find_map(|cause| cause.downcast_ref::<PairingError>())
                    .and_then(|refusal| refusal.retry_after)
                    .map(Duration::from_secs);
                let wait = asked.unwrap_or(delay).min(MAX_REPLACEMENT_WAIT);
                tracing::warn!(
                    retry_secs = wait.as_secs(),
                    "fetching a replacement key: {error:#}"
                );
                tokio::time::sleep(wait).await;
                delay = (delay * 2).min(Duration::from_secs(30));
            },
        }
    }
    None
}

/// A request to stop, created once per process and seen by every phase of its
/// work: a signal arriving while none of them listens would otherwise be lost.
#[derive(Clone)]
pub(crate) struct Shutdown(watch::Receiver<bool>);

impl Shutdown {
    /// The process's polite stops, from now on.
    pub(crate) fn listen() -> Self {
        let (stop, shutdown) = Self::manual();
        tokio::spawn(async move {
            match worker::shutdown_signal().await {
                Ok(()) => {
                    let _ = stop.send(true);
                },
                Err(error) => {
                    tracing::warn!("cannot listen for a stop request: {error:#}");
                    // Kept open: a closed channel would read as a request.
                    std::future::pending::<()>().await;
                    drop(stop);
                },
            }
        });
        shutdown
    }

    /// One that its caller stops.
    pub(crate) fn manual() -> (watch::Sender<bool>, Self) {
        let (stop, shutdown) = watch::channel(false);
        (stop, Self(shutdown))
    }

    /// Wait for a stop request.
    pub(crate) async fn requested(&mut self) {
        let _ = self.0.wait_for(|stop| *stop).await;
    }
}
