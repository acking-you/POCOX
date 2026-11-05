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
//!   after a reset that id may name another tenant's key. The key's label and
//!   namespace are then read before anything is changed.
//! - A credential reaches a client only after its namespace and label match
//!   what was expected and its key id is on record.
//! - A stored namespace is never replaced, whatever the relay answers.
//! - A retiring session only ever gets its own generation's existing key, with
//!   no more than the time it has left. A current key is never shortened.

use std::sync::Arc;
use std::time::Duration;

use pocox_account_proto::http::RelayCredentialResponse;
use pocox_account_proto::key::NamespacedServiceId;
use pocox_account_proto::pairing::PairingErrorCode;
use pocox_auth::{DeviceCaller, SessionMode};
use pocox_pb::{IssuedCredential, RelayStatus};
use pocox_store::pairing::{GrantFate, KeyAnswer, KeyState, NamespaceClaim, NewGrant, RelayKeyRow};
use tokio::sync::OwnedMutexGuard;
use uuid::Uuid;

use super::error::{PairingError, PairingResult};
use super::relay::{KeyCheck, RelayFailure};
use super::service::{unix_now, CachedCredential, ClientBucket, CredentialKey, NewKey, Pairing};

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

/// What the relay's answer to a renew or issue says about a key, compared with
/// what the database expected. The check before the call can be raced, so this
/// one still counts.
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

/// The relay's expiry as stored. Unix seconds fit an `i64` for ages yet.
pub(super) fn expires_as_i64(expires_at: u64) -> i64 {
    i64::try_from(expires_at).unwrap_or(i64::MAX)
}

impl Pairing {
    /// `GET /v1/relay` for a device session.
    ///
    /// The work is its own task, which the request waits on for a bounded time.
    /// A renewal is a relay write, and the relay repeats a credential only
    /// then, so a client closing between the relay's answer and this
    /// backend remembering it must not throw that write away for the next
    /// request to repeat. A relay that says nothing gets a 503 rather than
    /// holding this request's slot.
    pub(crate) async fn relay_credential(
        self: &Arc<Self>,
        caller: Box<DeviceCaller>,
        bucket: ClientBucket,
    ) -> PairingResult<RelayCredentialResponse> {
        let namespace = NamespacedServiceId::namespace_of(&caller.access.user.id);
        let pairing = Arc::clone(self);
        let task = tokio::spawn(async move {
            match caller.mode {
                SessionMode::Current => pairing.current_credential(&caller, bucket).await,
                SessionMode::Retiring {
                    deadline,
                } => pairing.retiring_credential(&caller, deadline).await,
            }
        });
        let (credential, expires_at) =
            match tokio::time::timeout(self.settings.foreground_wait, task).await {
                Ok(Ok(result)) => result?,
                Ok(Err(panicked)) => return Err(PairingError::internal(panicked)),
                Err(_) => {
                    return Err(PairingError::retry_later(PairingErrorCode::RelayUnavailable, 5));
                },
            };
        Ok(RelayCredentialResponse {
            relay_addr: self.relay.relay_addr.clone(),
            credential,
            expires_at,
            namespace,
        })
    }

    /// The device's lock, or a retry-later. Whoever holds it is already doing
    /// what this request would, and waiting would only hold a global slot.
    fn device_lock_or_retry(&self, device_id: &str) -> PairingResult<OwnedMutexGuard<()>> {
        self.device_locks
            .try_acquire(device_id)
            .ok_or_else(|| PairingError::retry_later(PairingErrorCode::RateLimited, 1))
    }

    fn key_ttl(&self, group_size: i64) -> Duration {
        if group_size > 1 {
            self.settings.linked_key_ttl
        } else {
            self.settings.single_key_ttl
        }
    }

    /// A cached current credential that has `margin` seconds left. With no
    /// instance known it is still served: a dead one costs a retry, and
    /// refusing costs an outage.
    fn cached_current(
        &self,
        key: &CredentialKey,
        instance: Option<&str>,
        margin: u64,
    ) -> Option<(String, u64)> {
        let credentials = self.credentials.lock().expect("credential cache");
        let entry = credentials.get(key)?;
        let usable = !entry.retiring
            && instance.is_none_or(|instance| entry.relay_instance == instance)
            && entry.expires_at > (unix_now().max(0) as u64) + margin;
        usable.then(|| (entry.credential.clone(), entry.expires_at))
    }

    fn remember_credential(
        &self,
        key: &CredentialKey,
        issued: &IssuedCredential,
        instance: &str,
        retiring: bool,
    ) {
        self.credentials
            .lock()
            .expect("credential cache")
            .insert(key.clone(), CachedCredential {
                credential: issued.credential.clone(),
                expires_at: issued.expires_at,
                relay_instance: instance.to_string(),
                retiring,
            });
    }

    async fn current_credential(
        &self,
        caller: &DeviceCaller,
        bucket: ClientBucket,
    ) -> PairingResult<(String, u64)> {
        let device = &caller.access.device;
        let generation = caller.access.session.generation;
        let refuse_unless_ready = |activated: bool, pending: bool| {
            if pending {
                return Err(PairingError::from(pocox_store::Refusal::TransitionPending {
                    operation_id: None,
                }));
            }
            if !activated {
                return Err(PairingError::code(PairingErrorCode::DeviceNotActivated));
            }
            Ok(())
        };
        refuse_unless_ready(device.activated_at.is_some(), device.pending_transition_id.is_some())?;
        let known = self.known_status().await;
        if known
            .as_ref()
            .is_some_and(|status| !status.supports_key_namespaces)
        {
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
        let known_instance = known.as_ref().map(|status| status.instance_id.as_str());
        if let Some(hit) = self.cached_current(&cache_key, known_instance, margin) {
            return Ok(hit);
        }
        let _device_guard = self.device_lock_or_retry(&device.id)?;
        // Under the lock nothing else is granting for this device, but a transition
        // may have begun since this request was authenticated.
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
            latest.device.pending_transition_id.is_some(),
        )?;
        let row = self.store.generation_key(&device.id, generation).await?;
        // Renewing a key on record is free: once done it is cached, so a client cannot
        // force it. Anything else pays per device before the relay is asked
        // anything, status reads and label walks included, so a refused device
        // costs the relay nothing per request.
        let metered = row.as_ref().is_none_or(|row| row.key_id.is_none());
        if metered {
            self.limit_grant_attempts(&device.id, unix_now())?;
        }
        let status = match self.fresh_status().await {
            Ok(status) => status,
            Err(failure) => {
                if metered {
                    self.refund_grant_attempt(&device.id);
                }
                return Err(failure.into());
            },
        };
        if !status.supports_key_namespaces {
            return Err(PairingError::code(PairingErrorCode::RelayTooOld));
        }
        let instance = status.instance_id.clone();
        if let Some(hit) = self.cached_current(&cache_key, Some(&instance), margin) {
            return Ok(hit);
        }
        if let Some(row) = row {
            if row.relay_instance != instance {
                // Key ids started over, so this id means nothing here. Calling the
                // relay with it would act on whichever key holds it now.
                tracing::warn!(device = %device.id, "relay instance changed; its key is dead");
                self.store
                    .end_key(&row.grant_id, KeyState::Dead, unix_now())
                    .await?;
            } else if let Some(found) = self.recover_key(row, ttl).await? {
                self.remember_credential(&cache_key, &found, &instance, false);
                return Ok((found.credential, found.expires_at));
            }
        }
        if !metered {
            self.limit_grant_attempts(&device.id, unix_now())?;
        }
        let issued = self.grant_new_key(&latest, ttl, &status, bucket).await?;
        self.remember_credential(&cache_key, &issued, &instance, false);
        Ok((issued.credential, issued.expires_at))
    }

    /// Bring a device generation's existing grant back: renew a known key, or
    /// find a lost one by label. `None` means nothing usable is left and a
    /// new grant may follow, which it may only after a repeated listing
    /// proves absence.
    async fn recover_key(
        &self,
        row: RelayKeyRow,
        ttl: Duration,
    ) -> PairingResult<Option<IssuedCredential>> {
        let key_id = match row.key_id.as_deref() {
            Some(id) => parse_relay_number(id)?,
            None => match self.find_key_by_label(&row.label).await? {
                Some(found) => found.key_id,
                None => {
                    // Absent after a repeated walk: the relay never applied it. Keep
                    // the grant and label, so a crash during this issue is still
                    // recoverable the same way.
                    return self.issue_for_grant(&row, ttl).await.map(Some);
                },
            },
        };
        match self.inspect_key(&row, key_id).await? {
            KeyCheck::Ours(_) => {},
            KeyCheck::Gone => {
                self.store
                    .end_key(&row.grant_id, KeyState::Expired, unix_now())
                    .await?;
                return Ok(None);
            },
            KeyCheck::Foreign => {
                self.store
                    .end_key(&row.grant_id, KeyState::Dead, unix_now())
                    .await?;
                return Ok(None);
            },
            KeyCheck::Drifted => {
                self.revoke_key(key_id).await?;
                self.store
                    .end_key(&row.grant_id, KeyState::Revoked, unix_now())
                    .await?;
                return Ok(None);
            },
        }
        // Never shorten a current key. Another installation may be asleep on the expiry
        // it was given, and a group shrinking is no reason to cut its tunnels.
        let started = unix_now();
        let remaining = row.local_end.map_or(0, |end| (end - started).max(0)) as u64;
        let ttl = ttl.max(Duration::from_secs(remaining));
        match pocox_pb::renew_credential(&self.relay, key_id, ttl).await {
            Ok(renewed) => match identity_of(&renewed, &row) {
                Identity::Expected => {
                    let fate = self
                        .store
                        .record_key(&row.grant_id, KeyAnswer {
                            key_id: &renewed.key_id.to_string(),
                            expires_at: expires_as_i64(renewed.expires_at),
                            local_end: started + ttl.as_secs() as i64,
                            now: unix_now(),
                        })
                        .await?;
                    self.released(fate, renewed).map(Some)
                },
                Identity::Foreign => {
                    tracing::error!(
                        grant = %row.grant_id,
                        "a stored key id answered with another label; not exposing or touching it"
                    );
                    self.store
                        .end_key(&row.grant_id, KeyState::Dead, unix_now())
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
                        .end_key(&row.grant_id, KeyState::Revoked, unix_now())
                        .await?;
                    Ok(None)
                },
            },
            Err(error) => match RelayFailure::classify(&error) {
                RelayFailure::KeyDead => {
                    self.store
                        .end_key(&row.grant_id, KeyState::Expired, unix_now())
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

    /// Open a new grant, after the checks and charges that must come before
    /// side effects. Each charge comes as late as it can: a retry after a
    /// failed allocation has spent no key budget.
    async fn grant_new_key(
        &self,
        access: &pocox_store::pairing::DeviceAccess,
        ttl: Duration,
        status: &RelayStatus,
        bucket: ClientBucket,
    ) -> PairingResult<IssuedCredential> {
        let device = &access.device;
        let now = unix_now();
        // Pairing keys stop at their share of relay capacity. Renewal needs no new slot
        // and never comes through here, so issued keys and GitHub accounts keep
        // working.
        let share = status.key_capacity as u64 * self.settings.capacity_share_percent / 100;
        let slot_limit = i64::try_from(share).unwrap_or(i64::MAX);
        if self.store.pairing_key_slots(now).await? >= slot_limit {
            return Err(pocox_store::Refusal::CapacityFull.into());
        }
        // A failed allocation issued nothing, so it spends no attempt and no key
        // budget.
        let namespace = match self.ensure_namespace(&access.user.id, now).await {
            Ok(namespace) => namespace,
            Err(error) => {
                self.refund_grant_attempt(&device.id);
                return Err(error);
            },
        };
        let kind = if device.key_generation == Some(access.session.generation) {
            NewKey::Replacement
        } else if self.store.device_had_key(&device.id).await? {
            NewKey::AfterMove
        } else {
            NewKey::First
        };
        self.charge_new_key(kind, bucket, now).await?;
        let grant_id = Uuid::new_v4().simple().to_string()[..16].to_string();
        let label = grant_label(&device.id, access.session.generation, &grant_id);
        let opened = self
            .store
            .open_grant(NewGrant {
                grant_id: &grant_id,
                device_id: &device.id,
                generation: access.session.generation,
                user_id: &access.user.id,
                namespace: &namespace,
                relay_instance: &status.instance_id,
                label: &label,
                slot_limit,
                now,
            })
            .await;
        let row = match opened {
            Ok(row) => row,
            Err(error) => {
                self.refund_new_key(kind, bucket, now).await;
                return Err(error.into());
            },
        };
        let issued = self.issue_for_grant(&row, ttl).await;
        if let Err(error) = &issued {
            // The relay's table was full: it issued nothing, and this slot was never taken.
            if error.refusal_code() == Some(PairingErrorCode::RelayCapacity) {
                self.refund_new_key(kind, bucket, now).await;
            }
        }
        issued
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
    ) -> PairingResult<IssuedCredential> {
        let namespace = parse_relay_number(&row.namespace)?;
        let _slot = self
            .grant_slots
            .acquire()
            .await
            .map_err(PairingError::internal)?;
        let started = unix_now();
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
                    .record_key(&row.grant_id, KeyAnswer {
                        key_id: &issued.key_id.to_string(),
                        expires_at: expires_as_i64(issued.expires_at),
                        local_end: started + ttl.as_secs() as i64,
                        now: unix_now(),
                    })
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
                    .end_key(&row.grant_id, KeyState::Revoked, unix_now())
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
    /// ask again and alert. Allocations are capped across the backend,
    /// since each is a relay write and leaving a group makes a new user
    /// that needs one.
    async fn ensure_namespace(&self, user_id: &str, now: i64) -> PairingResult<String> {
        if let Some(namespace) = self.store.user_namespace(user_id).await? {
            return Ok(namespace);
        }
        let _user_guard = self.user_locks.acquire(user_id).await;
        if let Some(namespace) = self.store.user_namespace(user_id).await? {
            return Ok(namespace);
        }
        for _ in 0..NAMESPACE_ATTEMPTS {
            self.charge_backend(
                "namespace_allocations",
                self.settings.limits.namespace_allocations_backend,
                now,
            )
            .await?;
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
    /// extends: the lifetime is the time left to the earlier of the
    /// deadline and the key's own end, read from the clock right before the
    /// call, so no wait for a lock or the relay can push it past either.
    /// The relay repeats a credential only on renewal, which is a
    /// relay write, so the text is kept once recovered: asking again costs
    /// nothing.
    async fn retiring_credential(
        &self,
        caller: &DeviceCaller,
        deadline: i64,
    ) -> PairingResult<(String, u64)> {
        let gone = || PairingError::code(PairingErrorCode::RetiringKeyGone);
        let device_id = &caller.access.device.id;
        let generation = caller.access.session.generation;
        let cache_key = CredentialKey {
            user_id: caller.access.user.id.clone(),
            device_id: device_id.clone(),
            generation,
        };
        // A key that has ended or died with its instance is no answer, however recently
        // it was recovered.
        let known = self.known_status().await;
        let cached = || {
            let credentials = self.credentials.lock().expect("credential cache");
            credentials
                .get(&cache_key)
                .filter(|entry| {
                    entry.retiring
                        && entry.expires_at > unix_now().max(0) as u64
                        && known
                            .as_ref()
                            .is_none_or(|status| status.instance_id == entry.relay_instance)
                })
                .map(|entry| (entry.credential.clone(), entry.expires_at))
        };
        if let Some(hit) = cached() {
            return Ok(hit);
        }
        let _device_guard = self.device_lock_or_retry(device_id)?;
        if let Some(hit) = cached() {
            return Ok(hit);
        }
        let row = self
            .store
            .generation_key(device_id, generation)
            .await?
            .ok_or_else(gone)?;
        let end = [Some(deadline), row.hard_cutoff, row.local_end]
            .into_iter()
            .flatten()
            .min()
            .unwrap_or(deadline);
        // Past saving, so there is nothing to ask the relay.
        if end - unix_now() < MIN_KEY_TTL_SECS {
            return Err(gone());
        }
        let instance = self.fresh_status().await?.instance_id;
        if row.relay_instance != instance {
            self.store
                .end_key(&row.grant_id, KeyState::Dead, unix_now())
                .await?;
            return Err(gone());
        }
        let key_id = parse_relay_number(row.key_id.as_deref().ok_or_else(gone)?)?;
        match self.inspect_key(&row, key_id).await? {
            KeyCheck::Ours(_) => {},
            KeyCheck::Gone => {
                self.store
                    .end_key(&row.grant_id, KeyState::Expired, unix_now())
                    .await?;
                return Err(gone());
            },
            KeyCheck::Foreign => {
                self.store
                    .end_key(&row.grant_id, KeyState::Dead, unix_now())
                    .await?;
                return Err(gone());
            },
            KeyCheck::Drifted => {
                self.revoke_key(key_id).await?;
                self.store
                    .end_key(&row.grant_id, KeyState::Revoked, unix_now())
                    .await?;
                return Err(gone());
            },
        }
        let remaining = end - unix_now();
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
                        .record_cutoff_applied(&row.grant_id, KeyAnswer {
                            key_id: &renewed.key_id.to_string(),
                            expires_at: expires_as_i64(renewed.expires_at),
                            local_end: end,
                            now: unix_now(),
                        })
                        .await?;
                    self.remember_credential(&cache_key, &renewed, &instance, true);
                    Ok((renewed.credential, renewed.expires_at))
                },
                Identity::Foreign => {
                    self.store
                        .end_key(&row.grant_id, KeyState::Dead, unix_now())
                        .await?;
                    Err(gone())
                },
                Identity::Drifted => {
                    self.revoke_key(key_id).await?;
                    self.store
                        .end_key(&row.grant_id, KeyState::Revoked, unix_now())
                        .await?;
                    Err(gone())
                },
            },
            Err(error) => match RelayFailure::classify(&error) {
                RelayFailure::KeyDead => {
                    self.store
                        .end_key(&row.grant_id, KeyState::Expired, unix_now())
                        .await?;
                    Err(gone())
                },
                other => Err(other.into()),
            },
        }
    }
}
