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
//! pending, and the worker resumes it from the persisted state.
//!
//! This relies on one process per database: per-operation and per-device locks
//! live in the process, and `crate::run` enforces that with a file lock beside
//! the database.

use std::sync::Arc;
use std::time::Duration;

use pocox_store::pairing::{
    CommitContext, KeyAnswer, KeyState, OperationState, PairOperation, RelayKeyRow,
};

use super::error::{PairingError, PairingResult};
use super::relay::{KeyCheck, RelayFailure};
use super::relay_keys::{expires_as_i64, parse_relay_number, MIN_KEY_TTL_SECS};
use super::service::{unix_now, Pairing};

/// Longest wait between attempts at a stuck operation.
const MAX_RETRY_DELAY_SECS: i64 = 300;

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
    /// any number of places in this process: the operation's lock and
    /// compare-and-set steps mean its effects happen once.
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
                .revalidate_operation(id, self.commit_context(unix_now()))
                .await?;
            if operation.state.is_terminal() {
                self.after_terminal(&operation).await;
                return Ok(operation);
            }
            if self.store.mark_relay_started(id, unix_now()).await? {
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
                        ?failure,
                        "relay work incomplete; the operation stays pending"
                    );
                    self.store
                        .defer_operation(id, unix_now() + delay, unix_now())
                        .await?;
                    return self
                        .store
                        .operation(id)
                        .await?
                        .ok_or_else(|| PairingError::internal("operation vanished"));
                }
                self.store.mark_relay_applied(id, unix_now()).await?;
            }
        }
        let finished = self
            .store
            .commit_operation(id, self.commit_context(unix_now()))
            .await?;
        self.after_terminal(&finished).await;
        Ok(finished)
    }

    /// Clear what a finished operation made stale. A failure after relay work
    /// also owes the relay whatever the operation had started: old keys do
    /// not get to run on.
    async fn after_terminal(&self, operation: &PairOperation) {
        self.forget_credentials(&operation.subject_device_id);
        self.forget_credentials(&operation.actor_device_id);
        if operation.state == OperationState::Failed && operation.relay_started {
            if let Err(failure) = self.enforce_owed_cutoffs().await {
                tracing::warn!(
                    ?failure,
                    "enforcing a failed operation's cutoffs; the worker retries"
                );
            }
        }
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
    /// still authenticate, of the generations this operation covers. A key
    /// newer than that is not its business, whichever order things ran in.
    async fn apply_relay_action(&self, operation: &PairOperation) -> Result<(), RelayFailure> {
        let rows = self
            .store
            .device_open_keys(&operation.subject_device_id, operation.subject_generation)
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
                    .end_key(&row.grant_id, KeyState::Dead, unix_now())
                    .await
                    .map_err(store_failure)?;
                continue;
            }
            let cutoff = match (operation.kind.revokes_all(), operation.grace_deadline) {
                (true, _) | (false, None) => unix_now(),
                (false, Some(deadline)) if row.generation == operation.subject_generation => {
                    deadline
                },
                // An older retiring generation keeps its own earlier deadline.
                (false, Some(_)) => continue,
            };
            self.enforce_cutoff(&row, cutoff).await?;
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
        let found = self.find_key_by_label(&row.label).await?;
        Ok(found.map(|record| record.key_id))
    }

    /// Make a key end by `cutoff`, after reading that it is the key the row
    /// says it is: the relay acts on whichever key holds an id now, so
    /// another tenant's answer ends the row with no change at the relay.
    ///
    /// Revokes when too little time is left for a renewal, which is every
    /// no-overlap change. Otherwise renews to the time left, which the
    /// relay enforces by itself and which needs no clock agreement. Never
    /// lengthens: a key already ending sooner keeps its own end.
    pub(super) async fn enforce_cutoff(
        &self,
        row: &RelayKeyRow,
        cutoff: i64,
    ) -> Result<(), RelayFailure> {
        let Some(key_id) = self.resolve_key_id(row).await? else {
            return self.end_row(row, KeyState::Dead).await;
        };
        let record = match self.inspect_key(row, key_id).await? {
            KeyCheck::Ours(record) => record,
            KeyCheck::Gone => return self.end_row(row, KeyState::Expired).await,
            KeyCheck::Foreign => return self.end_row(row, KeyState::Dead).await,
            KeyCheck::Drifted => {
                self.revoke_key(key_id).await?;
                return self.end_row(row, KeyState::Revoked).await;
            },
        };
        let end = row.local_end.map_or(cutoff, |end| end.min(cutoff));
        let started = unix_now();
        let remaining = end - started;
        if remaining < MIN_KEY_TTL_SECS {
            self.revoke_key(key_id).await?;
            return self.end_row(row, KeyState::Revoked).await;
        }
        let unmoved = row
            .expires_at
            .is_some_and(|known| expires_as_i64(record.expires_at) <= known);
        if unmoved && row.local_end.is_some_and(|local_end| local_end <= cutoff) {
            // It already ends by then, so nothing is owed and nothing needs writing.
            return self
                .store
                .record_cutoff_applied(&row.grant_id, KeyAnswer {
                    key_id: &record.key_id.to_string(),
                    expires_at: expires_as_i64(record.expires_at),
                    local_end: end,
                    now: started,
                })
                .await
                .map_err(store_failure);
        }
        let ttl = Duration::from_secs(remaining as u64);
        match pocox_pb::renew_credential(&self.relay, key_id, ttl).await {
            Ok(renewed) => {
                if renewed.label.as_deref() != Some(row.label.as_str()) {
                    tracing::error!(grant = %row.grant_id, "a retiring key id answered with another label");
                    return self.end_row(row, KeyState::Dead).await;
                }
                if renewed.namespace.to_string() != row.namespace {
                    tracing::error!(grant = %row.grant_id, "a retiring key is in another namespace; revoking");
                    self.revoke_key(key_id).await?;
                    return self.end_row(row, KeyState::Revoked).await;
                }
                self.store
                    .record_cutoff_applied(&row.grant_id, KeyAnswer {
                        key_id: &renewed.key_id.to_string(),
                        expires_at: expires_as_i64(renewed.expires_at),
                        local_end: end,
                        now: unix_now(),
                    })
                    .await
                    .map_err(store_failure)
            },
            Err(error) => match RelayFailure::classify(&error) {
                RelayFailure::KeyDead => self.end_row(row, KeyState::Expired).await,
                other => Err(other),
            },
        }
    }

    async fn end_row(&self, row: &RelayKeyRow, state: KeyState) -> Result<(), RelayFailure> {
        self.store
            .end_key(&row.grant_id, state, unix_now())
            .await
            .map_err(store_failure)
    }
}

pub(super) fn store_failure(error: pocox_store::StoreError) -> RelayFailure {
    RelayFailure::Unavailable(format!("store: {error}"))
}
