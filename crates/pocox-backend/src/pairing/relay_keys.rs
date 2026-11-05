//! Per-device-generation relay keys.
//!
//! GitHub shares one key per account (`crate::credentials`). A pairing user has
//! one stable namespace and a key per device generation, so a removal costs its
//! peers nothing.
//!
//! The rules this file keeps:
//!
//! - A grant is persisted before the relay is called, and a lost answer is
//!   found again by label rather than minted twice.
//! - The relay's instance is compared before any call naming a stored key id:
//!   after a reset that id may name another tenant's key.
//! - A credential reaches a client only after its namespace and label match
//!   what was expected and its key id is on record.
//! - A stored namespace is never replaced, whatever the relay answers.
//! - A retiring session only ever gets its own generation's existing key, with
//!   no more than the time it has left.

use std::time::Duration;

use pocox_account_proto::http::RelayCredentialResponse;
use pocox_account_proto::key::NamespacedServiceId;
use pocox_account_proto::pairing::PairingErrorCode;
use pocox_auth::{DeviceCaller, SessionMode};
use pocox_pb::IssuedCredential;
use pocox_store::pairing::{GrantFate, KeyState, NamespaceClaim, NewGrant, RelayKeyRow};
use uuid::Uuid;

use super::error::{PairingError, PairingResult};
use super::relay::RelayFailure;
use super::service::{CachedCredential, ClientBucket, CredentialKey, Pairing};

/// The relay refuses a shorter lifetime.
pub(super) const MIN_KEY_TTL_SECS: i64 = 10;

/// Attempts at finding an unrepeated namespace in one request. A relay that
/// lost its state repeats numbers for a while; the next request carries on from
/// there.
const NAMESPACE_ATTEMPTS: usize = 64;

/// The label a key is issued with. It names the grant, which is how a lost
/// issue response is found again. Never collides with GitHub's `pcx-account:`
/// labels.
pub(super) fn grant_label(device_id: &str, generation: i64, grant_id: &str) -> String {
    format!("pcxd:{device_id}:{generation}:{grant_id}")
}

/// The grant a pairing label names.
pub(super) fn grant_of_label(label: &str) -> Option<&str> {
    let rest = label.strip_prefix("pcxd:")?;
    rest.rsplit(':').next()
}

pub(super) fn parse_relay_number(value: &str) -> PairingResult<u64> {
    value
        .parse()
        .map_err(|_| PairingError::internal(format!("stored relay number `{value}` is not a u64")))
}

/// What the relay said about a key compared with what the database expected.
enum Identity {
    Expected,
    /// Another tenant's key answered to this id. Never exposed and never
    /// touched.
    Foreign,
    /// Ours by label, in the wrong namespace: revoke and reissue.
    Drifted,
}

fn identity_of(issued: &IssuedCredential, row: &RelayKeyRow) -> Identity {
    if issued.label.as_deref() != Some(row.label.as_str()) {
        Identity::Foreign
    } else if issued.namespace.to_string() != row.namespace {
        Identity::Drifted
    } else {
        Identity::Expected
    }
}

impl Pairing {
    /// `GET /v1/relay` for a device session.
    pub(crate) async fn relay_credential(
        &self,
        caller: &DeviceCaller,
        bucket: ClientBucket,
        now: i64,
    ) -> PairingResult<RelayCredentialResponse> {
        let (credential, expires_at) = match caller.mode {
            SessionMode::Current => self.current_credential(caller, bucket, now).await?,
            SessionMode::Retiring {
                deadline,
            } => self.retiring_credential(caller, deadline, now).await?,
        };
        Ok(RelayCredentialResponse {
            relay_addr: self.relay.relay_addr.clone(),
            credential,
            expires_at,
            namespace: NamespacedServiceId::namespace_of(&caller.access.user.id),
        })
    }

    fn key_ttl(&self, group_size: i64) -> Duration {
        if group_size > 1 {
            self.settings.linked_key_ttl
        } else {
            self.settings.single_key_ttl
        }
    }

    async fn current_credential(
        &self,
        caller: &DeviceCaller,
        bucket: ClientBucket,
        now: i64,
    ) -> PairingResult<(String, u64)> {
        let device = &caller.access.device;
        let generation = caller.access.session.generation;
        let refuse_unless_ready = |activated: bool, pending: Option<&String>| {
            if let Some(operation) = pending {
                return Err(PairingError::from(pocox_store::Refusal::TransitionPending {
                    operation_id: Some(operation.clone()),
                }));
            }
            if !activated {
                return Err(PairingError::code(PairingErrorCode::DeviceNotActivated));
            }
            Ok(())
        };
        refuse_unless_ready(device.activated_at.is_some(), device.pending_transition_id.as_ref())?;
        let status = self.cached_status().await?;
        if !status.supports_key_namespaces {
            return Err(PairingError::code(PairingErrorCode::RelayTooOld));
        }
        let group_size = self.store.group_size(&caller.access.user.id).await?;
        let ttl = self.key_ttl(group_size);
        let margin = (ttl.as_secs() / 2).min(3600);
        let cache_key = CredentialKey {
            user_id: caller.access.user.id.clone(),
            device_id: device.id.clone(),
            generation,
        };
        let cached = |pairing: &Self, instance: &str| {
            pairing
                .credentials
                .lock()
                .expect("credential cache")
                .get(&cache_key)
                .filter(|entry| {
                    entry.relay_instance == instance
                        && entry.expires_at > (now.max(0) as u64) + margin
                })
                .map(|entry| (entry.credential.clone(), entry.expires_at))
        };
        if let Some(hit) = cached(self, &status.instance_id) {
            return Ok(hit);
        }
        let _device_guard = self.device_locks.acquire(&device.id).await;
        // Under the lock nothing else is granting for this device, but a transition
        // may have begun while this request waited for it.
        let latest = self
            .store
            .device_access(&device.id, generation)
            .await?
            .ok_or(PairingError::code(PairingErrorCode::SessionStale))?;
        if latest.device.session_generation != generation {
            return Err(PairingError::code(PairingErrorCode::SessionStale));
        }
        refuse_unless_ready(
            latest.device.activated_at.is_some(),
            latest.device.pending_transition_id.as_ref(),
        )?;
        let instance = self.fresh_status().await?.instance_id;
        if let Some(hit) = cached(self, &instance) {
            return Ok(hit);
        }
        if let Some(row) = self.store.generation_key(&device.id, generation).await? {
            if row.relay_instance != instance {
                // Key ids started over, so this id means nothing here. Calling the
                // relay with it would act on whichever key holds it now.
                tracing::warn!(device = %device.id, "relay instance changed; its key is dead");
                self.store
                    .end_key(&row.grant_id, KeyState::Dead, now)
                    .await?;
            } else if let Some(found) = self.recover_key(row, ttl, now).await? {
                return Ok(self.expose(found, &cache_key, &instance));
            }
        }
        let issued = self
            .grant_new_key(&latest, ttl, &instance, bucket, now)
            .await?;
        Ok(self.expose(issued, &cache_key, &instance))
    }

    /// Remember a key that has been verified, recorded and released for
    /// exposure.
    fn expose(
        &self,
        issued: IssuedCredential,
        cache_key: &CredentialKey,
        instance: &str,
    ) -> (String, u64) {
        self.credentials.lock().expect("credential cache").insert(
            cache_key.clone(),
            CachedCredential {
                credential: issued.credential.clone(),
                expires_at: issued.expires_at,
                relay_instance: instance.to_string(),
            },
        );
        (issued.credential, issued.expires_at)
    }

    /// Bring a device generation's existing grant back: renew a known key, or
    /// find a lost one by label. `None` means nothing usable is left and a
    /// new grant may follow, which it may only after a repeated listing
    /// proves absence.
    async fn recover_key(
        &self,
        row: RelayKeyRow,
        ttl: Duration,
        now: i64,
    ) -> PairingResult<Option<IssuedCredential>> {
        let key_id = match row.key_id.as_deref() {
            Some(id) => parse_relay_number(id)?,
            None => match self.find_key_by_label(&row.label).await? {
                Some(found) if found.namespace.to_string() != row.namespace => {
                    tracing::error!(
                        grant = %row.grant_id,
                        "relay reports another namespace for a grant; revoking it"
                    );
                    self.revoke_key(found.key_id).await?;
                    self.store
                        .end_key(&row.grant_id, KeyState::Revoked, now)
                        .await?;
                    return Ok(None);
                },
                Some(found) => found.key_id,
                None => {
                    // Absent after a repeated walk: the relay never applied it. Keep
                    // the grant and label, so a crash during this issue is still
                    // recoverable the same way.
                    return self.issue_for_grant(&row, ttl, now).await.map(Some);
                },
            },
        };
        match pocox_pb::renew_credential(&self.relay, key_id, ttl).await {
            Ok(renewed) => match identity_of(&renewed, &row) {
                Identity::Expected => {
                    let fate = self
                        .store
                        .record_key(
                            &row.grant_id,
                            &renewed.key_id.to_string(),
                            expires_as_i64(renewed.expires_at),
                            now,
                        )
                        .await?;
                    self.released(fate, renewed).map(Some)
                },
                Identity::Foreign => {
                    tracing::error!(
                        grant = %row.grant_id,
                        "a stored key id answered with another label; not exposing or touching it"
                    );
                    self.store
                        .end_key(&row.grant_id, KeyState::Dead, now)
                        .await?;
                    Ok(None)
                },
                Identity::Drifted => {
                    tracing::error!(
                        grant = %row.grant_id,
                        "relay reports another namespace for a key; revoking and reissuing"
                    );
                    self.revoke_key(key_id).await?;
                    self.store
                        .end_key(&row.grant_id, KeyState::Revoked, now)
                        .await?;
                    Ok(None)
                },
            },
            Err(error) => match RelayFailure::classify(&error) {
                RelayFailure::KeyDead => {
                    self.store
                        .end_key(&row.grant_id, KeyState::Expired, now)
                        .await?;
                    Ok(None)
                },
                other => Err(other.into()),
            },
        }
    }

    fn released(
        &self,
        fate: GrantFate,
        issued: IssuedCredential,
    ) -> PairingResult<IssuedCredential> {
        match fate {
            GrantFate::Expose => Ok(issued),
            GrantFate::Withhold => Err(pocox_store::Refusal::TransitionPending {
                operation_id: None,
            }
            .into()),
        }
    }

    /// Open a new grant, after the checks that must come before side effects.
    async fn grant_new_key(
        &self,
        access: &pocox_store::pairing::DeviceAccess,
        ttl: Duration,
        instance: &str,
        bucket: ClientBucket,
        now: i64,
    ) -> PairingResult<IssuedCredential> {
        let device = &access.device;
        self.check_capacity_share(now).await?;
        if !self.store.device_had_key(&device.id).await? {
            let limits = self.settings.limits;
            self.limiters
                .first_keys
                .charge(bucket.0, now)
                .map_err(|wait| PairingError::retry_later(PairingErrorCode::RateLimited, wait))?;
            self.charge_backend("first_keys", limits.first_keys_backend, now)
                .await?;
        }
        let namespace = self.ensure_namespace(&access.user.id).await?;
        let grant_id = Uuid::new_v4().simple().to_string()[..16].to_string();
        let label = grant_label(&device.id, access.session.generation, &grant_id);
        let row = self
            .store
            .open_grant(NewGrant {
                grant_id: &grant_id,
                device_id: &device.id,
                generation: access.session.generation,
                user_id: &access.user.id,
                namespace: &namespace,
                relay_instance: instance,
                label: &label,
                now,
            })
            .await?;
        self.issue_for_grant(&row, ttl, now).await
    }

    /// Pairing keys stop at their share of relay capacity. Renewal needs no new
    /// slot and never comes through here, so issued keys and GitHub
    /// accounts keep working.
    async fn check_capacity_share(&self, now: i64) -> PairingResult<()> {
        let capacity = self.cached_status().await?.key_capacity;
        let share = capacity as u64 * self.settings.capacity_share_percent / 100;
        let used = self.store.pairing_key_slots(now).await?;
        if used >= i64::try_from(share).unwrap_or(i64::MAX) {
            return Err(PairingError::retry_later(PairingErrorCode::RelayCapacity, 300));
        }
        Ok(())
    }

    /// Ask the relay for this grant's key.
    ///
    /// An unknown outcome leaves the grant open: the next request or the worker
    /// finds it by label. A stored namespace the relay no longer knows
    /// leaves it open too, with 503, and is never replaced: moving a user's
    /// namespace would split its group.
    async fn issue_for_grant(
        &self,
        row: &RelayKeyRow,
        ttl: Duration,
        now: i64,
    ) -> PairingResult<IssuedCredential> {
        let namespace = parse_relay_number(&row.namespace)?;
        let _slot = self
            .grant_slots
            .acquire()
            .await
            .map_err(PairingError::internal)?;
        let issued = pocox_pb::issue_credential_in_namespace(
            &self.relay,
            namespace,
            ttl,
            Some(row.label.clone()),
        )
        .await;
        let issued = match issued {
            Ok(issued) => issued,
            Err(error) => {
                let failure = RelayFailure::classify(&error);
                match failure {
                    RelayFailure::NamespaceLost => tracing::error!(
                        user = %row.user_id,
                        namespace = %row.namespace,
                        "the relay does not know a stored namespace: it lost its state. Holding \
                         this grant; no replacement is allocated"
                    ),
                    RelayFailure::TableFull => self.store.forget_grant(&row.grant_id).await?,
                    _ => {},
                }
                return Err(failure.into());
            },
        };
        match identity_of(&issued, row) {
            Identity::Expected => {
                let fate = self
                    .store
                    .record_key(
                        &row.grant_id,
                        &issued.key_id.to_string(),
                        expires_as_i64(issued.expires_at),
                        now,
                    )
                    .await?;
                self.released(fate, issued)
            },
            Identity::Foreign | Identity::Drifted => {
                tracing::error!(
                    grant = %row.grant_id,
                    "relay issued a key with another namespace or label; revoking it"
                );
                self.revoke_key(issued.key_id).await?;
                self.store
                    .end_key(&row.grant_id, KeyState::Revoked, now)
                    .await?;
                Err(PairingError::retry_later(PairingErrorCode::RelayUnavailable, 30))
            },
        }
    }

    /// A user's namespace, allocating it once.
    ///
    /// Concurrent first keys in a group race on the database's conditional
    /// update, so all of them end up with one number. A number another user
    /// already holds means the relay repeated it after losing its state:
    /// ask again and alert.
    async fn ensure_namespace(&self, user_id: &str) -> PairingResult<String> {
        if let Some(namespace) = self.store.user_namespace(user_id).await? {
            return Ok(namespace);
        }
        let _user_guard = self.user_locks.acquire(user_id).await;
        if let Some(namespace) = self.store.user_namespace(user_id).await? {
            return Ok(namespace);
        }
        for _ in 0..NAMESPACE_ATTEMPTS {
            let allocated = pocox_pb::allocate_namespace(&self.relay)
                .await
                .map_err(|error| PairingError::from(RelayFailure::classify(&error)))?;
            match self
                .store
                .claim_namespace(user_id, &allocated.to_string())
                .await?
            {
                NamespaceClaim::Fixed(namespace) => return Ok(namespace),
                NamespaceClaim::Repeated => {
                    tracing::error!(
                        namespace = allocated,
                        "ALERT: the relay repeated a namespace another user holds; it lost its \
                         state directory. Allocating again"
                    );
                },
            }
        }
        Err(PairingError::retry_later(PairingErrorCode::RelayStateLost, 60))
    }

    /// A retiring session's own generation's key, with what is left of its
    /// deadline.
    ///
    /// Never mints, never returns the current generation's key, and never
    /// extends: the lifetime is computed from the fixed deadline every
    /// time, so asking again lands on the same moment.
    async fn retiring_credential(
        &self,
        caller: &DeviceCaller,
        deadline: i64,
        now: i64,
    ) -> PairingResult<(String, u64)> {
        let gone = || PairingError::code(PairingErrorCode::RetiringKeyGone);
        let device_id = &caller.access.device.id;
        let generation = caller.access.session.generation;
        let _device_guard = self.device_locks.acquire(device_id).await;
        let row = self
            .store
            .generation_key(device_id, generation)
            .await?
            .ok_or_else(gone)?;
        let instance = self.fresh_status().await?.instance_id;
        if row.relay_instance != instance {
            self.store
                .end_key(&row.grant_id, KeyState::Dead, now)
                .await?;
            return Err(gone());
        }
        let key_id = parse_relay_number(row.key_id.as_deref().ok_or_else(gone)?)?;
        let remaining = deadline - now;
        if remaining < MIN_KEY_TTL_SECS {
            return Err(gone());
        }
        let renewed =
            pocox_pb::renew_credential(&self.relay, key_id, Duration::from_secs(remaining as u64))
                .await;
        match renewed {
            Ok(renewed) => match identity_of(&renewed, &row) {
                Identity::Expected => {
                    self.store
                        .record_key_expiry(&row.grant_id, expires_as_i64(renewed.expires_at), now)
                        .await?;
                    Ok((renewed.credential, renewed.expires_at))
                },
                Identity::Foreign => {
                    self.store
                        .end_key(&row.grant_id, KeyState::Dead, now)
                        .await?;
                    Err(gone())
                },
                Identity::Drifted => {
                    self.revoke_key(key_id).await?;
                    self.store
                        .end_key(&row.grant_id, KeyState::Revoked, now)
                        .await?;
                    Err(gone())
                },
            },
            Err(error) => match RelayFailure::classify(&error) {
                RelayFailure::KeyDead => {
                    self.store
                        .end_key(&row.grant_id, KeyState::Expired, now)
                        .await?;
                    Err(gone())
                },
                other => Err(other.into()),
            },
        }
    }
}

/// The relay's expiry as stored. Unix seconds fit an `i64` for ages yet.
pub(super) fn expires_as_i64(expires_at: u64) -> i64 {
    i64::try_from(expires_at).unwrap_or(i64::MAX)
}
