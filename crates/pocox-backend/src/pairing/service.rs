//! The pairing service: shared state for routes, relay work and the worker.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use axum::http::HeaderMap;
use pocox_account_proto::pairing::{encode_tuple, HardwareHint, PairingErrorCode};
use pocox_auth::{Auth, PairingKeys};
use pocox_pb::{RelaySession, RelayStatus};
use pocox_store::pairing::{BudgetVerdict, HardwareBinding};
use pocox_store::Store;
use sha2::{Digest as _, Sha256};
use tokio::sync::{OwnedMutexGuard, Semaphore};

use super::address::{address_bucket, TrustedProxies};
use super::error::{PairingError, PairingResult};
use super::limits::{AddressLimiter, Rate};
use super::settings::PairingSettings;

/// Longest informational hint-source label kept.
const MAX_HINT_SOURCE_BYTES: usize = 32;

/// A cached relay status.
pub(super) struct CachedStatus {
    pub(super) status: RelayStatus,
    pub(super) fetched: Instant,
}

/// Which credential a cache entry holds. Device and generation are part of the
/// key: an account-only cache would hand a retiring session its replacement's
/// credential.
#[derive(Clone, PartialEq, Eq, Hash)]
pub(super) struct CredentialKey {
    pub(super) user_id: String,
    pub(super) device_id: String,
    pub(super) generation: i64,
}

/// A credential text recovered from the relay, which repeats it only on
/// renewal.
#[derive(Clone)]
pub(super) struct CachedCredential {
    pub(super) credential: String,
    pub(super) expires_at: u64,
    pub(super) relay_instance: String,
}

/// Async locks by name, created on demand and dropped when nothing holds them.
#[derive(Default)]
pub(super) struct NamedLocks {
    locks: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
}

impl NamedLocks {
    pub(super) async fn acquire(&self, name: &str) -> OwnedMutexGuard<()> {
        let lock = {
            let mut locks = self.locks.lock().expect("named locks");
            locks.retain(|_, lock| Arc::strong_count(lock) > 1 || lock.try_lock().is_err());
            locks.entry(name.to_string()).or_default().clone()
        };
        lock.lock_owned().await
    }
}

/// The per-address limiters.
pub(super) struct Limiters {
    pub(super) code_checks: AddressLimiter,
    pub(super) new_devices: AddressLimiter,
    pub(super) first_keys: AddressLimiter,
}

/// Where a request came from, as a keyed bucket.
#[derive(Debug, Clone, Copy)]
pub struct ClientBucket(pub(super) [u8; 16]);

/// Maps a device id and code generation to that code's lookup.
pub(super) type DeriveLookup = dyn Fn(&str, i64) -> Vec<u8> + Send + Sync;

/// The pairing service.
pub struct Pairing {
    pub(super) auth: Arc<Auth>,
    pub(super) store: Store,
    pub(super) keys: PairingKeys,
    pub(super) relay: RelaySession,
    pub(super) settings: PairingSettings,
    pub(super) proxies: TrustedProxies,
    pub(super) limiters: Limiters,
    pub(super) status: Mutex<Option<CachedStatus>>,
    pub(super) credentials: Mutex<HashMap<CredentialKey, CachedCredential>>,
    pub(super) device_locks: NamedLocks,
    pub(super) user_locks: NamedLocks,
    pub(super) operation_locks: NamedLocks,
    pub(super) grant_slots: Semaphore,
    pub(super) request_slots: Semaphore,
    pub(super) derive_lookup: Box<DeriveLookup>,
}

impl Pairing {
    /// Build the service. `auth` must have been configured with a pairing
    /// secret.
    pub fn new(
        auth: Arc<Auth>,
        store: Store,
        relay: RelaySession,
        settings: PairingSettings,
    ) -> anyhow::Result<Arc<Self>> {
        let keys = auth
            .pairing_keys()
            .ok_or_else(|| anyhow::anyhow!("pairing needs POCOX_PAIRING_SECRET"))?
            .clone();
        let proxies = TrustedProxies::parse(&settings.trusted_proxies)?;
        let limits = settings.limits;
        Ok(Arc::new(Self {
            limiters: Limiters {
                code_checks: AddressLimiter::with_backoff(
                    limits.code_checks_per_address,
                    limits.limiter_entries,
                ),
                new_devices: AddressLimiter::new(
                    limits.new_devices_per_address,
                    limits.limiter_entries,
                ),
                first_keys: AddressLimiter::new(
                    limits.first_keys_per_address,
                    limits.limiter_entries,
                ),
            },
            derive_lookup: {
                let keys = keys.clone();
                Box::new(move |device, generation| keys.device_code_lookup(device, generation))
            },
            grant_slots: Semaphore::new(limits.concurrent_grants),
            request_slots: Semaphore::new(limits.concurrent_requests),
            auth,
            store,
            keys,
            relay,
            settings,
            proxies,
            status: Mutex::new(None),
            credentials: Mutex::new(HashMap::new()),
            device_locks: NamedLocks::default(),
            user_locks: NamedLocks::default(),
            operation_locks: NamedLocks::default(),
        }))
    }

    /// The bucket a request's limits are charged to.
    pub(crate) fn client_bucket(&self, peer: SocketAddr, headers: &HeaderMap) -> ClientBucket {
        let ip = self.proxies.client_ip(peer.ip(), headers);
        ClientBucket(self.keys.address_key(&address_bucket(ip)))
    }

    /// Charge a backend-wide budget.
    pub(super) async fn charge_backend(
        &self,
        name: &str,
        rate: Rate,
        now: i64,
    ) -> PairingResult<()> {
        match self
            .store
            .charge_budget(name, rate.window_secs, rate.count, now)
            .await?
        {
            BudgetVerdict::Admitted => Ok(()),
            BudgetVerdict::Refused {
                retry_after,
            } => Err(PairingError::retry_later(PairingErrorCode::RateLimited, retry_after)),
        }
    }

    /// Charge one code check: per address first, so that a refused attempt
    /// cannot drain the backend-wide budget.
    pub(super) async fn charge_code_check(
        &self,
        bucket: ClientBucket,
        now: i64,
    ) -> PairingResult<()> {
        self.limiters
            .code_checks
            .charge(bucket.0, now)
            .map_err(|wait| PairingError::retry_later(PairingErrorCode::RateLimited, wait))?;
        self.charge_backend("code_checks", self.settings.limits.code_checks_backend, now)
            .await
    }

    /// Validate a hint and derive its stored lookup. A hint is only ever an
    /// index: nothing here or downstream treats it as proof of anything.
    pub(super) fn hint_lookup(&self, hint: &HardwareHint) -> PairingResult<Vec<u8>> {
        let key = pocox_account_proto::pairing::parse_hardware_key(&hint.key)
            .ok_or(PairingError::code(PairingErrorCode::InvalidRequest))?;
        if hint
            .source
            .as_deref()
            .is_some_and(|source| source.len() > MAX_HINT_SOURCE_BYTES)
        {
            return Err(PairingError::code(PairingErrorCode::InvalidRequest));
        }
        Ok(self.keys.hardware_lookup(&key))
    }

    /// Drop every cached credential of a device, in all generations.
    pub(super) fn forget_credentials(&self, device_id: &str) {
        self.credentials
            .lock()
            .expect("credential cache")
            .retain(|key, _| key.device_id != device_id);
    }
}

/// A binding over a validated lookup.
pub(super) fn binding<'a>(
    lookup: Option<&'a [u8]>,
    hint: Option<&'a HardwareHint>,
) -> Option<HardwareBinding<'a>> {
    lookup.map(|lookup| HardwareBinding {
        lookup,
        source: hint.and_then(|hint| hint.source.as_deref()),
    })
}

/// The hash binding an operation id to its exact request.
pub(super) fn fingerprint(kind: &str, secret_hash: &[u8], fields: &[&[u8]]) -> Vec<u8> {
    let mut all: Vec<&[u8]> = vec![kind.as_bytes(), secret_hash];
    all.extend_from_slice(fields);
    Sha256::digest(encode_tuple(&all)).to_vec()
}
