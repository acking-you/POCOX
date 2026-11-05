//! The worker that makes background correctness independent of any client's
//! polling.
//!
//! On restart and on a timer it resumes open operations, then compares the
//! relay's key table with the database: orphaned grants from a crash, keys
//! drifted to another namespace, deadlines a delayed earlier renewal moved, and
//! keys that no longer exist.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Instant;

use pocox_pb::CredentialRecord;
use pocox_store::pairing::{KeyState, RelayKeyRow};
use tokio::task::JoinHandle;

use super::error::PairingResult;
use super::relay::RelayFailure;
use super::relay_keys::{expires_as_i64, grant_of_label};
use super::service::Pairing;
use super::transitions::store_failure;

/// How often retention runs.
const PURGE_INTERVAL_SECS: u64 = 3600;

fn now() -> i64 {
    time::OffsetDateTime::now_utc().unix_timestamp()
}

impl Pairing {
    /// Start the worker. Its first pass runs at once, so a restart resumes
    /// whatever was in flight.
    pub fn spawn_worker(self: Arc<Self>) -> JoinHandle<()> {
        tokio::spawn(async move {
            let mut ticks = tokio::time::interval(self.settings.reconcile_interval);
            let mut last_sweep: Option<Instant> = None;
            let mut last_purge: Option<Instant> = None;
            // The first pass ignores any retry schedule: this may be a restart.
            let mut due_at = None;
            loop {
                ticks.tick().await;
                if let Err(error) = self.resume_operations(due_at).await {
                    tracing::warn!(?error, "resuming pairing operations failed");
                }
                due_at = Some(now());
                if last_sweep.is_none_or(|at| at.elapsed() >= self.settings.sweep_interval) {
                    last_sweep = Some(Instant::now());
                    if let Err(failure) = self.sweep_keys().await {
                        tracing::warn!(?failure, "comparing relay keys failed");
                    }
                }
                if last_purge.is_none_or(|at| at.elapsed().as_secs() >= PURGE_INTERVAL_SECS) {
                    last_purge = Some(Instant::now());
                    if let Err(error) = self.store.purge_pairing(now()).await {
                        tracing::warn!(%error, "pairing retention failed");
                    }
                    self.limiters.code_checks.expire(now());
                    self.limiters.new_devices.expire(now());
                    self.limiters.first_keys.expire(now());
                }
            }
        })
    }

    /// One full pass: what a restart does.
    pub async fn reconcile_once(&self) -> PairingResult<()> {
        self.resume_operations(None).await?;
        if let Err(failure) = self.sweep_keys().await {
            tracing::warn!(?failure, "comparing relay keys failed");
        }
        Ok(())
    }

    async fn resume_operations(&self, due_at: Option<i64>) -> PairingResult<()> {
        for operation in self.store.open_operations(due_at).await? {
            if !Self::has_relay_work(operation.kind) {
                continue;
            }
            if let Err(error) = self.drive(&operation.id).await {
                tracing::warn!(operation = %operation.id, ?error, "operation did not advance");
            }
        }
        Ok(())
    }

    /// Compare the relay's table with the database.
    ///
    /// A key absent from one walk is not proof of anything, because listings
    /// page by position, so absence takes two walks to believe.
    pub(super) async fn sweep_keys(&self) -> Result<(), RelayFailure> {
        let instance = self.fresh_status().await?.instance_id;
        let first = pocox_pb::live_credentials(&self.relay)
            .await
            .map_err(|error| RelayFailure::classify(&error))?;
        for record in &first {
            self.reconcile_listed(record, &instance).await?;
        }
        let rows = self.store.open_keys().await.map_err(store_failure)?;
        let listed = |records: &[CredentialRecord], row: &RelayKeyRow| {
            records
                .iter()
                .any(|record| record.label.as_deref() == Some(row.label.as_str()))
        };
        let missing: Vec<&RelayKeyRow> = rows.iter().filter(|row| !listed(&first, row)).collect();
        if missing.is_empty() {
            return Ok(());
        }
        let second = pocox_pb::live_credentials(&self.relay)
            .await
            .map_err(|error| RelayFailure::classify(&error))?;
        let stale_labels: HashSet<&str> = missing
            .iter()
            .filter(|row| !listed(&second, row))
            .map(|row| row.label.as_str())
            .collect();
        for row in missing {
            if !stale_labels.contains(row.label.as_str()) {
                continue;
            }
            let state =
                if row.relay_instance != instance { KeyState::Dead } else { KeyState::Expired };
            // A grant this process has in flight holds its device's lock. Waiting for
            // it means an answer on its way is recorded, not called absent.
            let _device_guard = self.device_locks.acquire(&row.device_id).await;
            let latest = self
                .store
                .grant(&row.grant_id)
                .await
                .map_err(store_failure)?;
            if latest.is_some_and(|latest| latest.updated_at == row.updated_at) {
                self.store
                    .end_key(&row.grant_id, state, now())
                    .await
                    .map_err(store_failure)?;
                self.forget_credentials(&row.device_id);
            }
        }
        Ok(())
    }

    /// Hold one live relay key against what the database says about it.
    async fn reconcile_listed(
        &self,
        record: &CredentialRecord,
        instance: &str,
    ) -> Result<(), RelayFailure> {
        let Some(grant_id) = record.label.as_deref().and_then(grant_of_label) else {
            return Ok(());
        };
        let Some(row) = self.store.grant(grant_id).await.map_err(store_failure)? else {
            // A grant is persisted before the relay is called, so this key has no
            // owner: a purged grant's leftover or a forged label. No client may ever
            // be handed it.
            tracing::warn!(key = record.key_id, "revoking a relay key with no grant on record");
            return self.revoke_key(record.key_id).await;
        };
        let _device_guard = self.device_locks.acquire(&row.device_id).await;
        let row = self
            .store
            .grant(&row.grant_id)
            .await
            .map_err(store_failure)?
            .unwrap_or(row);
        let ours_here = row.relay_instance == instance;
        let on_record = row.key_id.as_deref() == Some(record.key_id.to_string().as_str());
        match row.state {
            KeyState::Granting if ours_here => {
                self.settle_orphan(&row, record).await?;
            },
            KeyState::Active if ours_here && on_record => {
                self.check_live_key(&row, record).await?;
            },
            // Ended on our side yet alive at the relay, a second key on one grant, or
            // a key this instance should not hold: nothing legitimate claims it.
            _ => {
                tracing::warn!(key = record.key_id, grant = %row.grant_id, "revoking a stray relay key");
                self.revoke_key(record.key_id).await?;
            },
        }
        Ok(())
    }

    /// A grant the relay applied before a crash lost its answer. Adopt it if
    /// its generation still stands; otherwise revoke it. Either way no
    /// client saw it.
    async fn settle_orphan(
        &self,
        row: &RelayKeyRow,
        record: &CredentialRecord,
    ) -> Result<(), RelayFailure> {
        let device = self
            .store
            .pairing_device(&row.device_id)
            .await
            .map_err(store_failure)?;
        let stands = device.is_some_and(|device| {
            device.session_generation == row.generation
                && device.user_id == row.user_id
                && device.pending_transition_id.is_none()
        });
        if stands && record.namespace.to_string() == row.namespace {
            self.store
                .record_key(
                    &row.grant_id,
                    &record.key_id.to_string(),
                    expires_as_i64(record.expires_at),
                    now(),
                )
                .await
                .map_err(store_failure)?;
            return Ok(());
        }
        self.revoke_key(record.key_id).await?;
        self.store
            .end_key(&row.grant_id, KeyState::Revoked, now())
            .await
            .map_err(store_failure)
    }

    /// A live key on record: its namespace must match, and a retiring one must
    /// not outlive the deadline it was last set to. Both expiries are the
    /// relay's own answers, so comparing them needs no clock agreement.
    async fn check_live_key(
        &self,
        row: &RelayKeyRow,
        record: &CredentialRecord,
    ) -> Result<(), RelayFailure> {
        if record.namespace.to_string() != row.namespace {
            tracing::error!(grant = %row.grant_id, "relay reports another namespace for a key; revoking it");
            self.revoke_key(record.key_id).await?;
            self.forget_credentials(&row.device_id);
            return self
                .store
                .end_key(&row.grant_id, KeyState::Revoked, now())
                .await
                .map_err(store_failure);
        }
        if let (Some(cutoff), Some(known)) = (row.hard_cutoff, row.expires_at) {
            if expires_as_i64(record.expires_at) > known {
                tracing::warn!(grant = %row.grant_id, "a delayed renewal moved a retiring key; reapplying its deadline");
                self.shorten_key(row, record.key_id, cutoff).await?;
            }
        }
        Ok(())
    }
}
