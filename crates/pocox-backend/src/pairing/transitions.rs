//! Driving a durable membership operation: the relay's part, then the commit.
//!
//! ```text
//!   1. prepare (store)   persist the operation; the subject is transitioning, so
//!                        competing changes and key issue or renewal are blocked
//!   2. relay action      shorten retiring keys for a normal restore; revoke every
//!                        key for a link, leave, removal or retake
//!   3. commit (store)    revalidate, move membership, open the new generation
//! ```
//!
//! No destination credential exists until step 3, and step 3 only happens once
//! the relay has confirmed step 2. A relay outage therefore leaves an operation
//! pending, and whichever process runs next resumes it from the persisted
//! state.

use std::sync::Arc;
use std::time::Duration;

use pocox_pb::CredentialRecord;
use pocox_store::pairing::{
    CommitContext, KeyState, OperationKind, OperationState, PairOperation, RelayKeyRow,
};

use super::error::{PairingError, PairingResult};
use super::relay::RelayFailure;
use super::relay_keys::{expires_as_i64, parse_relay_number, MIN_KEY_TTL_SECS};
use super::service::Pairing;

/// Longest wait between attempts at a stuck operation.
const MAX_RETRY_DELAY_SECS: i64 = 300;

fn now() -> i64 {
    time::OffsetDateTime::now_utc().unix_timestamp()
}

impl Pairing {
    fn commit_context(&self, now: i64) -> CommitContext<'_> {
        CommitContext {
            now,
            max_group_size: self.settings.max_group_size,
            retake_window_secs: self.settings.retake_window_secs,
            derive_lookup: self.derive_lookup.as_ref(),
        }
    }

    /// Take an open operation as far as it can go right now. Safe to call from
    /// any number of places: per-operation locking and compare-and-set
    /// steps mean its effects happen once.
    pub(super) async fn drive(&self, id: &str) -> PairingResult<PairOperation> {
        let _operation_guard = self.operation_locks.acquire(id).await;
        let mut operation = self
            .store
            .operation(id)
            .await?
            .ok_or_else(|| PairingError::internal("operation vanished"))?;
        if operation.state.is_terminal() {
            return Ok(operation);
        }
        if operation.state == OperationState::Prepared {
            operation = self
                .store
                .revalidate_operation(id, self.commit_context(now()))
                .await?;
            if operation.state.is_terminal() {
                self.forget_after(&operation);
                return Ok(operation);
            }
            self.store.mark_relay_started(id, now()).await?;
            let applied = {
                let _device_guard = self
                    .device_locks
                    .acquire(&operation.subject_device_id)
                    .await;
                self.forget_credentials(&operation.subject_device_id);
                self.apply_relay_action(&operation).await
            };
            if let Err(failure) = applied {
                let delay = (5i64 << operation.attempts.clamp(0, 6)).min(MAX_RETRY_DELAY_SECS);
                tracing::warn!(
                    operation = %id,
                    failure = ?failure,
                    "relay work incomplete; the operation stays pending"
                );
                self.store.defer_operation(id, now() + delay, now()).await?;
                return self
                    .store
                    .operation(id)
                    .await?
                    .ok_or_else(|| PairingError::internal("operation vanished"));
            }
            self.store.mark_relay_applied(id, now()).await?;
        }
        let finished = self
            .store
            .commit_operation(id, self.commit_context(now()))
            .await?;
        self.forget_after(&finished);
        Ok(finished)
    }

    fn forget_after(&self, operation: &PairOperation) {
        self.forget_credentials(&operation.subject_device_id);
        self.forget_credentials(&operation.actor_device_id);
    }

    /// Drive an operation with the request waiting a bounded time. The work is
    /// its own task, so a request timing out cannot abandon it halfway.
    pub(super) async fn drive_in_foreground(
        self: &Arc<Self>,
        operation: PairOperation,
    ) -> PairingResult<PairOperation> {
        if operation.state.is_terminal() {
            return Ok(operation);
        }
        let pairing = Arc::clone(self);
        let id = operation.id.clone();
        let task = tokio::spawn(async move { pairing.drive(&id).await });
        match tokio::time::timeout(self.settings.foreground_wait, task).await {
            Ok(Ok(driven)) => driven,
            Ok(Err(panicked)) => Err(PairingError::internal(panicked)),
            Err(_) => Ok(operation),
        }
    }

    /// Step 2. Returns only once the relay confirmed it for every key that may
    /// still authenticate.
    async fn apply_relay_action(&self, operation: &PairOperation) -> Result<(), RelayFailure> {
        let rows = self
            .store
            .device_open_keys(&operation.subject_device_id)
            .await
            .map_err(store_failure)?;
        if rows.is_empty() {
            return Ok(());
        }
        let instance = self.fresh_status().await?.instance_id;
        for row in rows {
            if row.relay_instance != instance {
                // The old instance's keys died with it, and its ids may now name
                // another tenant's keys. Dead is authoritative; touching it is not safe.
                self.store
                    .end_key(&row.grant_id, KeyState::Dead, now())
                    .await
                    .map_err(store_failure)?;
                continue;
            }
            let Some(key_id) = self.resolve_key_id(&row).await? else {
                self.store
                    .end_key(&row.grant_id, KeyState::Dead, now())
                    .await
                    .map_err(store_failure)?;
                continue;
            };
            match (operation.kind.revokes_all(), operation.grace_deadline) {
                (false, Some(deadline)) if row.generation == operation.subject_generation => {
                    self.shorten_key(&row, key_id, deadline).await?;
                },
                // An older retiring generation keeps its own earlier deadline.
                (false, _) => {},
                (true, _) => {
                    self.revoke_key(key_id).await?;
                    self.store
                        .end_key(&row.grant_id, KeyState::Revoked, now())
                        .await
                        .map_err(store_failure)?;
                },
            }
        }
        Ok(())
    }

    /// A grant's key id: on record, or found by label. `None` after a repeated
    /// walk misses it: the relay never applied that grant, or the key has
    /// already gone.
    async fn resolve_key_id(&self, row: &RelayKeyRow) -> Result<Option<u64>, RelayFailure> {
        if let Some(id) = row.key_id.as_deref() {
            return parse_relay_number(id)
                .map(Some)
                .map_err(|error| RelayFailure::Unavailable(format!("{error:?}")));
        }
        let found: Option<CredentialRecord> = self.find_key_by_label(&row.label).await?;
        Ok(found.map(|record| record.key_id))
    }

    /// Set a retiring key to end at its generation's deadline. The relay takes
    /// a relative lifetime, so no clock agreement is needed. Below its
    /// minimum, revoke.
    pub(super) async fn shorten_key(
        &self,
        row: &RelayKeyRow,
        key_id: u64,
        deadline: i64,
    ) -> Result<(), RelayFailure> {
        let remaining = deadline - now();
        if remaining < MIN_KEY_TTL_SECS {
            self.revoke_key(key_id).await?;
            return self
                .store
                .end_key(&row.grant_id, KeyState::Revoked, now())
                .await
                .map_err(store_failure);
        }
        let ttl = Duration::from_secs(remaining as u64);
        match pocox_pb::renew_credential(&self.relay, key_id, ttl).await {
            Ok(renewed) => {
                let foreign = renewed.label.as_deref() != Some(row.label.as_str());
                if foreign {
                    tracing::error!(grant = %row.grant_id, "a retiring key id answered with another label");
                    return self
                        .store
                        .end_key(&row.grant_id, KeyState::Dead, now())
                        .await
                        .map_err(store_failure);
                }
                if renewed.namespace.to_string() != row.namespace {
                    tracing::error!(grant = %row.grant_id, "a retiring key is in another namespace; revoking");
                    self.revoke_key(key_id).await?;
                    return self
                        .store
                        .end_key(&row.grant_id, KeyState::Revoked, now())
                        .await
                        .map_err(store_failure);
                }
                self.store
                    .record_key_expiry(&row.grant_id, expires_as_i64(renewed.expires_at), now())
                    .await
                    .map_err(store_failure)
            },
            Err(error) => match RelayFailure::classify(&error) {
                RelayFailure::KeyDead => self
                    .store
                    .end_key(&row.grant_id, KeyState::Expired, now())
                    .await
                    .map_err(store_failure),
                other => Err(other),
            },
        }
    }

    /// Whether a kind of operation needs the relay at all.
    pub(super) fn has_relay_work(kind: OperationKind) -> bool {
        !matches!(kind, OperationKind::Rotate | OperationKind::Decide)
    }
}

pub(super) fn store_failure(error: pocox_store::StoreError) -> RelayFailure {
    RelayFailure::Unavailable(format!("store: {error}"))
}
