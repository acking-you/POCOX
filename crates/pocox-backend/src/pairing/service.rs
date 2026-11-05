//! The pairing service: shared state for routes, relay work and the worker.

use std::collections::HashMap;
use std::future::Future;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use axum::http::HeaderMap;
use pocox_account_proto::pairing::{encode_tuple, HardwareHint, PairingErrorCode};
use pocox_auth::{Auth, PairingKeys};
use pocox_pb::{RelaySession, RelayStatus, ServiceRecord};
use pocox_store::pairing::{BudgetVerdict, HardwareBinding, Prepared};
use pocox_store::Store;
use sha2::{Digest as _, Sha256};
use tokio::sync::{OwnedMutexGuard, Semaphore, SemaphorePermit};

use super::address::{address_bucket, TrustedProxies};
use super::error::{PairingError, PairingResult};
use super::limits::{AddressLimiter, Rate};
use super::settings::PairingSettings;

/// Longest informational hint-source label kept.
const MAX_HINT_SOURCE_BYTES: usize = 32;

/// The current time. Read it right before it matters: a value carried across a
/// lock or a relay call is stale by exactly that wait.
pub(super) fn unix_now() -> i64 {
    time::OffsetDateTime::now_utc().unix_timestamp()
}

/// A cached relay status.
pub(super) struct CachedStatus {
    pub(super) status: RelayStatus,
    pub(super) fetched: Instant,
}

/// Whether someone is asking the relay for its status, and when that last
/// failed.
#[derive(Default)]
pub(super) struct StatusProbe {
    pub(super) in_flight: bool,
    pub(super) failed_at: Option<Instant>,
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
    /// Recovered for a retiring session, so its expiry is already the deadline.
    pub(super) retiring: bool,
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

/// The in-memory limiters. Keys are keyed hashes of an address or a device id.
pub(super) struct Limiters {
    pub(super) code_checks: AddressLimiter,
    pub(super) valid_codes: AddressLimiter,
    pub(super) new_devices: AddressLimiter,
    pub(super) first_keys: AddressLimiter,
    pub(super) moves_by_device: AddressLimiter,
    pub(super) moves_by_address: AddressLimiter,
    pub(super) key_grants_by_device: AddressLimiter,
    pub(super) deregistrations_by_device: AddressLimiter,
    pub(super) deregistrations_by_address: AddressLimiter,
}

impl Limiters {
    /// Drop every counter past its time.
    pub(super) fn expire_all(&self, now: i64) {
        for limiter in [
            &self.code_checks,
            &self.valid_codes,
            &self.new_devices,
            &self.first_keys,
            &self.moves_by_device,
            &self.moves_by_address,
            &self.key_grants_by_device,
            &self.deregistrations_by_device,
            &self.deregistrations_by_address,
        ] {
            limiter.expire(now);
        }
    }
}

/// Where a request came from, as a keyed bucket.
#[derive(Debug, Clone, Copy)]
pub struct ClientBucket(pub(super) [u8; 16]);

/// Maps a device id and code generation to that code's lookup.
pub(super) type DeriveLookup = dyn Fn(&str, i64) -> Vec<u8> + Send + Sync;

/// The relay's service listing, kept briefly and shared by every device caller.
pub(super) type ServiceSnapshot = Option<(Instant, Arc<Vec<ServiceRecord>>)>;

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
    pub(super) probe: Mutex<StatusProbe>,
    pub(super) services: tokio::sync::Mutex<ServiceSnapshot>,
    pub(super) credentials: Mutex<HashMap<CredentialKey, CachedCredential>>,
    pub(super) device_locks: NamedLocks,
    pub(super) user_locks: NamedLocks,
    pub(super) operation_locks: NamedLocks,
    pub(super) grant_slots: Semaphore,
    pub(super) request_slots: Semaphore,
    pub(super) derive_lookup: Box<DeriveLookup>,
}

fn rate_limited(wait: u64) -> PairingError {
    PairingError::retry_later(PairingErrorCode::RateLimited, wait)
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
        let entries = limits.limiter_entries;
        Ok(Arc::new(Self {
            limiters: Limiters {
                code_checks: AddressLimiter::with_backoff(limits.code_checks_per_address, entries),
                valid_codes: AddressLimiter::new(limits.valid_codes_per_address, entries),
                new_devices: AddressLimiter::new(limits.new_devices_per_address, entries),
                first_keys: AddressLimiter::new(limits.first_keys_per_address, entries),
                moves_by_device: AddressLimiter::new(limits.moves_per_device, entries),
                moves_by_address: AddressLimiter::new(limits.moves_per_address, entries),
                key_grants_by_device: AddressLimiter::new(limits.key_grants_per_device, entries),
                deregistrations_by_device: AddressLimiter::new(
                    limits.deregistrations_per_device,
                    entries,
                ),
                deregistrations_by_address: AddressLimiter::new(
                    limits.deregistrations_per_address,
                    entries,
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
            probe: Mutex::new(StatusProbe::default()),
            services: tokio::sync::Mutex::new(None),
            credentials: Mutex::new(HashMap::new()),
            device_locks: NamedLocks::default(),
            user_locks: NamedLocks::default(),
            operation_locks: NamedLocks::default(),
        }))
    }

    /// Take one of the concurrent request slots, or refuse with 429. Device
    /// calls to the routes they share with GitHub take one too.
    pub(crate) fn enter(&self) -> PairingResult<SemaphorePermit<'_>> {
        self.request_slots
            .try_acquire()
            .map_err(|_| rate_limited(1))
    }

    /// The bucket a request's limits are charged to.
    pub(crate) fn client_bucket(&self, peer: SocketAddr, headers: &HeaderMap) -> ClientBucket {
        let ip = self.proxies.client_ip(peer.ip(), headers);
        ClientBucket(self.keys.address_key(&address_bucket(ip)))
    }

    /// A device's limiter key. Domain-separated from address buckets by its
    /// length.
    pub(super) fn device_key(&self, device_id: &str) -> [u8; 16] {
        self.keys.address_key(device_id.as_bytes())
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
            } => Err(rate_limited(retry_after)),
        }
    }

    /// Charge one code check: per address first, so that a refused attempt
    /// cannot drain the backend-wide budget. When it is the backend's
    /// budget that refuses, the address gets its charge back: someone
    /// else's flood is not this address's guess.
    pub(super) async fn charge_code_check(
        &self,
        bucket: ClientBucket,
        now: i64,
    ) -> PairingResult<()> {
        self.limiters
            .code_checks
            .charge(bucket.0, now)
            .map_err(rate_limited)?;
        let backend = self
            .charge_backend("code_checks", self.settings.limits.code_checks_backend, now)
            .await;
        if backend.is_err() {
            self.limiters.code_checks.refund(bucket.0);
        }
        backend
    }

    /// A code or ticket turned out valid, so it is no guess: refund the
    /// address's charge. Valid checks have their own unrefunded limit, or
    /// one address could spend the backend's budget for free by repeating a
    /// code it knows.
    pub(super) fn credit_valid_code(&self, bucket: ClientBucket, now: i64) -> PairingResult<()> {
        self.limiters
            .valid_codes
            .charge(bucket.0, now)
            .map_err(rate_limited)?;
        self.limiters.code_checks.refund(bucket.0);
        Ok(())
    }

    /// Charge one membership move: each is several relay writes plus rows that
    /// stay for days, so it is metered per device, per address and across
    /// the backend.
    async fn charge_move(
        &self,
        device_id: &str,
        bucket: ClientBucket,
        now: i64,
    ) -> PairingResult<()> {
        let device_key = self.device_key(device_id);
        self.limiters
            .moves_by_device
            .charge(device_key, now)
            .map_err(rate_limited)?;
        if let Err(wait) = self.limiters.moves_by_address.charge(bucket.0, now) {
            self.limiters.moves_by_device.refund(device_key);
            return Err(rate_limited(wait));
        }
        let backend = self
            .charge_backend("membership_moves", self.settings.limits.moves_backend, now)
            .await;
        if backend.is_err() {
            self.limiters.moves_by_device.refund(device_key);
            self.limiters.moves_by_address.refund(bucket.0);
        }
        backend
    }

    async fn refund_move(&self, device_id: &str, bucket: ClientBucket, now: i64) {
        self.limiters
            .moves_by_device
            .refund(self.device_key(device_id));
        self.limiters.moves_by_address.refund(bucket.0);
        let window = self.settings.limits.moves_backend.window_secs;
        if let Err(error) = self
            .store
            .refund_budget("membership_moves", window, now)
            .await
        {
            tracing::warn!(%error, "refunding a membership move");
        }
    }

    /// Prepare an operation under a move's charge. A refusal or a replay did no
    /// work, so it costs nothing and a client may retry it.
    pub(super) async fn metered_prepare<F, Fut>(
        &self,
        device_id: &str,
        bucket: ClientBucket,
        now: i64,
        prepare: F,
    ) -> PairingResult<Prepared>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = pocox_store::Result<Prepared>>,
    {
        self.charge_move(device_id, bucket, now).await?;
        match prepare().await {
            Ok(prepared) => {
                if !prepared.is_new {
                    self.refund_move(device_id, bucket, now).await;
                }
                Ok(prepared)
            },
            Err(error) => {
                self.refund_move(device_id, bucket, now).await;
                Err(error.into())
            },
        }
    }

    /// Bound relay issues per device, whatever kept the last one from sticking.
    pub(super) fn limit_grant_attempts(&self, device_id: &str, now: i64) -> PairingResult<()> {
        self.limiters
            .key_grants_by_device
            .charge(self.device_key(device_id), now)
            .map_err(rate_limited)
    }

    /// Charge a key that takes a new relay slot: a device's first per address
    /// and across the backend, any later one across the backend. Renewing
    /// an existing key is free.
    pub(super) async fn charge_new_key(
        &self,
        first: bool,
        bucket: ClientBucket,
        now: i64,
    ) -> PairingResult<()> {
        let limits = self.settings.limits;
        if !first {
            return self
                .charge_backend("key_regrants", limits.key_regrants_backend, now)
                .await;
        }
        self.limiters
            .first_keys
            .charge(bucket.0, now)
            .map_err(rate_limited)?;
        let backend = self
            .charge_backend("first_keys", limits.first_keys_backend, now)
            .await;
        if backend.is_err() {
            self.limiters.first_keys.refund(bucket.0);
        }
        backend
    }

    /// Give a key's charge back when its grant was refused before anything
    /// happened.
    pub(super) async fn refund_new_key(&self, first: bool, bucket: ClientBucket, now: i64) {
        let limits = self.settings.limits;
        let (name, window) = if first {
            self.limiters.first_keys.refund(bucket.0);
            ("first_keys", limits.first_keys_backend.window_secs)
        } else {
            ("key_regrants", limits.key_regrants_backend.window_secs)
        };
        if let Err(error) = self.store.refund_budget(name, window, now).await {
            tracing::warn!(%error, "refunding a key grant");
        }
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
