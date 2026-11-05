//! Steps two and three of a durable membership change.
//!
//! ```text
//!   prepared ──relay confirmed──▶ relay_applied ──destination valid──▶ committed
//!      │                                │
//!      └──────destination changed───────┴──▶ failed (membership untouched)
//! ```
//!
//! An operation is not a database transaction pretending to include a network
//! call: the relay work happens between these steps, and a restart resumes from
//! whatever state was last persisted. Once the relay may have been touched a
//! failure cannot undo it, so a failed subject gets a fresh generation in its
//! source group rather than its old authorization back.

use sqlx::SqliteConnection;

use super::codes::rotate_code_in;
use super::devices::{bind_hardware_in, device_in, group_size_in, user_in, HardwareBinding};
use super::models::{
    Device, OperationKind, OperationState, PairOperation, RestoreRequestState, TransitionKind,
};
use super::prepare::operation_in;
use crate::{Result, Store};

pub(super) const OPERATION_COLUMNS: &str =
    "id, kind, fingerprint, actor_device_id, actor_secret_hash, subject_device_id, \
     subject_generation, source_user_id, source_revision, destination_user_id, \
     destination_revision, code_device_id, code_generation, code_pause_epoch, request_id, \
     new_user_id, hardware_lookup, hardware_source, grace_deadline, state, relay_started, no_op, \
     result_code, result_device_id, attempts, next_attempt_at, created_at, updated_at, \
     completed_at";

const PREVIEW_STALE: &str = "preview_stale";
const STALE: &str = "stale";
const GROUP_FULL: &str = "group_full";

/// What retiring a session generation leaves behind.
enum Retire {
    /// Usable on grace-eligible routes until this deadline.
    Grace(i64),
    /// Authorizes nothing.
    Revoke,
}

/// Retire the device's current generation and open a new one on `secret_hash`.
async fn advance_generation(
    conn: &mut SqliteConnection,
    device: &Device,
    secret_hash: &[u8],
    user_id: &str,
    retire: Retire,
    now: i64,
) -> Result<i64> {
    let (state, deadline) = match retire {
        Retire::Grace(deadline) => ("grace", Some(deadline)),
        Retire::Revoke => ("revoked", None),
    };
    sqlx::query(
        "UPDATE device_sessions SET state = ?2, grace_deadline = COALESCE(?3, grace_deadline), \
         retired_at = ?4 WHERE device_id = ?1 AND state = 'current'",
    )
    .bind(&device.id)
    .bind(state)
    .bind(deadline)
    .bind(now)
    .execute(&mut *conn)
    .await?;
    let generation = device.session_generation + 1;
    sqlx::query(
        "INSERT INTO device_sessions (device_id, generation, secret_hash, original_user_id, \
         state, created_at) VALUES (?1, ?2, ?3, ?4, 'current', ?5)",
    )
    .bind(&device.id)
    .bind(generation)
    .bind(secret_hash)
    .bind(user_id)
    .bind(now)
    .execute(&mut *conn)
    .await?;
    sqlx::query("UPDATE devices SET session_generation = ?2 WHERE id = ?1")
        .bind(&device.id)
        .bind(generation)
        .execute(&mut *conn)
        .await?;
    Ok(generation)
}

async fn bump_revision(conn: &mut SqliteConnection, user_id: &str) -> Result<()> {
    sqlx::query(
        "UPDATE device_users SET membership_revision = membership_revision + 1 WHERE id = ?1",
    )
    .bind(user_id)
    .execute(&mut *conn)
    .await?;
    Ok(())
}

/// Cancel every open recovery request by or about this device.
async fn cancel_requests(conn: &mut SqliteConnection, device_id: &str, now: i64) -> Result<()> {
    sqlx::query(
        "UPDATE pair_restore_requests SET state = 'stale', updated_at = ?2
         WHERE state IN ('pending', 'approved')
         AND (requester_device_id = ?1 OR target_device_id = ?1)",
    )
    .bind(device_id)
    .bind(now)
    .execute(&mut *conn)
    .await?;
    Ok(())
}

async fn finish_operation(
    conn: &mut SqliteConnection,
    id: &str,
    state: OperationState,
    result_code: Option<&str>,
    result_device_id: &str,
    now: i64,
) -> Result<PairOperation> {
    sqlx::query(
        "UPDATE pair_operations SET state = ?2, result_code = ?3, result_device_id = ?4, \
         completed_at = ?5, updated_at = ?5, next_attempt_at = NULL WHERE id = ?1",
    )
    .bind(id)
    .bind(state)
    .bind(result_code)
    .bind(result_device_id)
    .bind(now)
    .execute(&mut *conn)
    .await?;
    let finished = operation_in(conn, id)
        .await?
        .ok_or(sqlx::Error::RowNotFound)?;
    Ok(finished)
}

/// Why this operation may no longer commit, re-derived from current state.
///
/// Covers everything the user confirmed: the subject's generation, the source
/// and destination groups, and the code or approval that authorized it.
async fn commit_blocker(
    conn: &mut SqliteConnection,
    operation: &PairOperation,
    now: i64,
    max_group_size: i64,
) -> Result<Option<&'static str>> {
    let Some(subject) = device_in(conn, &operation.subject_device_id).await? else {
        return Ok(Some(PREVIEW_STALE));
    };
    if subject.session_generation != operation.subject_generation
        || subject.user_id != operation.source_user_id
        || subject.pending_transition_id.as_deref() != Some(operation.id.as_str())
    {
        return Ok(Some(PREVIEW_STALE));
    }
    let Some(destination_id) = operation.destination_user_id.as_deref() else {
        return Ok(None);
    };
    let Some(destination) = user_in(conn, destination_id).await? else {
        return Ok(Some(PREVIEW_STALE));
    };
    if Some(destination.membership_revision) != operation.destination_revision {
        return Ok(Some(PREVIEW_STALE));
    }
    if let (Some(code_device), Some(code_generation)) =
        (operation.code_device_id.as_deref(), operation.code_generation)
    {
        let holds_code = device_in(conn, code_device).await?.is_some_and(|holder| {
            holder.user_id == destination_id
                && holder.code_generation == code_generation
                && Some(holder.code_pause_epoch) == operation.code_pause_epoch
                && !holder.code_paused
        });
        if !holds_code {
            return Ok(Some(PREVIEW_STALE));
        }
    }
    match operation.kind {
        OperationKind::Link => {
            let source = user_in(conn, &operation.source_user_id).await?;
            if source.map(|user| user.membership_revision) != Some(operation.source_revision) {
                return Ok(Some(PREVIEW_STALE));
            }
            if group_size_in(conn, destination_id).await? >= max_group_size {
                return Ok(Some(GROUP_FULL));
            }
        },
        OperationKind::Restore | OperationKind::Retake => {
            let requester = device_in(conn, &operation.actor_device_id).await?;
            let qualifies = match &requester {
                Some(requester) => {
                    requester.activated_at.is_none()
                        && requester.pending_transition_id.as_deref() == Some(operation.id.as_str())
                        && group_size_in(conn, &requester.user_id).await? == 1
                },
                None => false,
            };
            if !qualifies {
                return Ok(Some(STALE));
            }
            if let Some(request_id) = operation.request_id.as_deref() {
                let (state, approval): (RestoreRequestState, Option<i64>) = sqlx::query_as(
                    "SELECT state, approval_expires_at FROM pair_restore_requests WHERE id = ?1",
                )
                .bind(request_id)
                .fetch_optional(&mut *conn)
                .await?
                .unwrap_or((RestoreRequestState::Stale, None));
                let live = state == RestoreRequestState::Approved
                    && approval.is_some_and(|expires| expires > now);
                if !live {
                    return Ok(Some(STALE));
                }
            }
        },
        OperationKind::Leave
        | OperationKind::Remove
        | OperationKind::Rotate
        | OperationKind::Decide => {},
    }
    Ok(None)
}

/// End `operation` without moving membership.
///
/// Before any relay call it simply undoes the transition mark. After one, the
/// old keys may be shortened or gone and that cannot be taken back: the subject
/// keeps its secret and membership under a fresh generation, and the old
/// generation keeps only what it had.
async fn fail_in(
    conn: &mut SqliteConnection,
    operation: &PairOperation,
    code: &str,
    now: i64,
) -> Result<PairOperation> {
    if let Some(subject) = device_in(conn, &operation.subject_device_id).await? {
        if subject.pending_transition_id.as_deref() == Some(operation.id.as_str()) {
            let hash: Option<(Vec<u8>,)> = sqlx::query_as(
                "SELECT secret_hash FROM device_sessions WHERE device_id = ?1 AND state = \
                 'current'",
            )
            .bind(&subject.id)
            .fetch_optional(&mut *conn)
            .await?;
            match (operation.relay_started, hash) {
                (true, Some((hash,))) => {
                    let retire = match (operation.kind.revokes_all(), operation.grace_deadline) {
                        (false, Some(deadline)) => Retire::Grace(deadline),
                        _ => Retire::Revoke,
                    };
                    advance_generation(conn, &subject, &hash, &subject.user_id, retire, now)
                        .await?;
                },
                _ => {
                    sqlx::query(
                        "UPDATE device_sessions SET grace_deadline = NULL
                         WHERE device_id = ?1 AND state = 'current'",
                    )
                    .bind(&subject.id)
                    .execute(&mut *conn)
                    .await?;
                    sqlx::query(
                        "UPDATE device_relay_keys SET hard_cutoff = NULL, cutoff_pending = 0, \
                         updated_at = ?3
                         WHERE device_id = ?1 AND generation = ?2 AND hard_cutoff IS NOT NULL",
                    )
                    .bind(&subject.id)
                    .bind(subject.session_generation)
                    .bind(now)
                    .execute(&mut *conn)
                    .await?;
                },
            }
        }
    }
    sqlx::query("UPDATE devices SET pending_transition_id = NULL WHERE pending_transition_id = ?1")
        .bind(&operation.id)
        .execute(&mut *conn)
        .await?;
    finish_operation(
        conn,
        &operation.id,
        OperationState::Failed,
        Some(code),
        &operation.actor_device_id,
        now,
    )
    .await
}

fn hardware_of(operation: &PairOperation) -> Option<HardwareBinding<'_>> {
    operation
        .hardware_lookup
        .as_deref()
        .map(|lookup| HardwareBinding {
            lookup,
            source: operation.hardware_source.as_deref(),
        })
}

async fn apply_link(
    conn: &mut SqliteConnection,
    operation: &PairOperation,
    now: i64,
) -> Result<PairOperation> {
    let subject = device_in(conn, &operation.subject_device_id)
        .await?
        .ok_or(sqlx::Error::RowNotFound)?;
    let destination = operation
        .destination_user_id
        .as_deref()
        .ok_or(sqlx::Error::RowNotFound)?;
    // A move preserves the secret. Old generations stay as historical rows so that
    // returning to a user later cannot make an old token valid again.
    advance_generation(
        conn,
        &subject,
        &operation.actor_secret_hash,
        destination,
        Retire::Revoke,
        now,
    )
    .await?;
    sqlx::query(
        "UPDATE devices SET user_id = ?2, joined_at = ?3, activated_at = COALESCE(activated_at, \
         ?3), first_activated_at = COALESCE(first_activated_at, ?3), last_transition_kind = ?4, \
         last_transition_at = ?3, pending_transition_id = NULL
         WHERE id = ?1",
    )
    .bind(&subject.id)
    .bind(destination)
    .bind(now)
    .bind(TransitionKind::Linked)
    .execute(&mut *conn)
    .await?;
    if let Some(binding) = hardware_of(operation) {
        bind_hardware_in(conn, &subject.id, binding).await?;
    }
    cancel_requests(conn, &subject.id, now).await?;
    bump_revision(conn, &operation.source_user_id).await?;
    bump_revision(conn, destination).await?;
    finish_operation(conn, &operation.id, OperationState::Committed, None, &subject.id, now).await
}

async fn apply_departure(
    conn: &mut SqliteConnection,
    operation: &PairOperation,
    now: i64,
) -> Result<PairOperation> {
    let subject = device_in(conn, &operation.subject_device_id)
        .await?
        .ok_or(sqlx::Error::RowNotFound)?;
    let new_user = operation
        .new_user_id
        .as_deref()
        .ok_or(sqlx::Error::RowNotFound)?;
    let (hash,): (Vec<u8>,) = sqlx::query_as(
        "SELECT secret_hash FROM device_sessions WHERE device_id = ?1 AND state = 'current'",
    )
    .bind(&subject.id)
    .fetch_one(&mut *conn)
    .await?;
    sqlx::query("INSERT INTO device_users (id, created_at) VALUES (?1, ?2)")
        .bind(new_user)
        .bind(now)
        .execute(&mut *conn)
        .await?;
    advance_generation(conn, &subject, &hash, new_user, Retire::Revoke, now).await?;
    let (kind, keep_activation) = match operation.kind {
        OperationKind::Remove => (TransitionKind::Removed, false),
        _ => (TransitionKind::Left, true),
    };
    // A removed device keeps its row and hint but hosts nothing until an explicit
    // Continue: clearing activation enforces that here, not only in clients.
    sqlx::query(
        "UPDATE devices SET user_id = ?2, joined_at = ?3, activated_at = CASE WHEN ?4 THEN \
         activated_at ELSE NULL END, last_transition_kind = ?5, last_transition_at = ?3, \
         pending_transition_id = NULL
         WHERE id = ?1",
    )
    .bind(&subject.id)
    .bind(new_user)
    .bind(now)
    .bind(keep_activation)
    .bind(kind)
    .execute(&mut *conn)
    .await?;
    cancel_requests(conn, &subject.id, now).await?;
    bump_revision(conn, &operation.source_user_id).await?;
    finish_operation(
        conn,
        &operation.id,
        OperationState::Committed,
        None,
        &operation.actor_device_id,
        now,
    )
    .await
}

async fn apply_restore(
    conn: &mut SqliteConnection,
    operation: &PairOperation,
    now: i64,
    derive_lookup: &(dyn Fn(&str, i64) -> Vec<u8> + Send + Sync),
    retake_window_secs: i64,
) -> Result<PairOperation> {
    let target = device_in(conn, &operation.subject_device_id)
        .await?
        .ok_or(sqlx::Error::RowNotFound)?;
    // The secret moves in this commit, so the store never holds two owners for it.
    sqlx::query("DELETE FROM devices WHERE id = ?1")
        .bind(&operation.actor_device_id)
        .execute(&mut *conn)
        .await?;
    let retake = operation.kind == OperationKind::Retake;
    let retire = match (retake, operation.grace_deadline) {
        (false, Some(deadline)) => Retire::Grace(deadline),
        _ => Retire::Revoke,
    };
    advance_generation(conn, &target, &operation.actor_secret_hash, &target.user_id, retire, now)
        .await?;
    let kind = if retake { TransitionKind::Retaken } else { TransitionKind::Restored };
    sqlx::query(
        "UPDATE devices SET activated_at = COALESCE(activated_at, ?2), first_activated_at = \
         COALESCE(first_activated_at, ?2), last_transition_kind = ?3, last_transition_at = ?2, \
         pending_transition_id = NULL WHERE id = ?1",
    )
    .bind(&target.id)
    .bind(now)
    .bind(kind)
    .execute(&mut *conn)
    .await?;
    if retake {
        rotate_code_in(conn, &target, now, derive_lookup).await?;
        let window_open = target
            .retake_window_start
            .is_some_and(|start| now < start + retake_window_secs);
        let (start, count) = if window_open {
            (target.retake_window_start.unwrap_or(now), target.retake_count + 1)
        } else {
            (now, 1)
        };
        sqlx::query("UPDATE devices SET retake_window_start = ?2, retake_count = ?3 WHERE id = ?1")
            .bind(&target.id)
            .bind(start)
            .bind(count)
            .execute(&mut *conn)
            .await?;
    }
    if let Some(binding) = hardware_of(operation) {
        bind_hardware_in(conn, &target.id, binding).await?;
    }
    cancel_requests(conn, &target.id, now).await?;
    bump_revision(conn, &target.user_id).await?;
    finish_operation(conn, &operation.id, OperationState::Committed, None, &target.id, now).await
}

/// What committing an operation needs besides its id.
#[derive(Clone, Copy)]
pub struct CommitContext<'a> {
    /// The current time.
    pub now: i64,
    /// The largest a group may grow.
    pub max_group_size: i64,
    /// The retake window.
    pub retake_window_secs: i64,
    /// Maps a device id and code generation to that code's lookup.
    pub derive_lookup: &'a (dyn Fn(&str, i64) -> Vec<u8> + Send + Sync),
}

impl Store {
    /// An operation by id.
    pub async fn operation(&self, id: &str) -> Result<Option<PairOperation>> {
        let mut conn = self.pool.acquire().await?;
        operation_in(&mut conn, id).await
    }

    /// Operations with relay work outstanding, oldest first: those due another
    /// attempt at `due_at`, or all of them with `None`, which is what a
    /// restart resumes.
    pub async fn open_operations(&self, due_at: Option<i64>) -> Result<Vec<PairOperation>> {
        let operations = sqlx::query_as::<_, PairOperation>(sqlx::AssertSqlSafe(format!(
            "SELECT {OPERATION_COLUMNS} FROM pair_operations
             WHERE state IN ('prepared', 'relay_applied')
             AND (?1 IS NULL OR next_attempt_at IS NULL OR next_attempt_at <= ?1)
             ORDER BY created_at"
        )))
        .bind(due_at)
        .fetch_all(&self.pool)
        .await?;
        Ok(operations)
    }

    /// Note that relay calls may now have been made, before making them. False
    /// when the operation is no longer prepared, so its relay work is not
    /// this caller's to do.
    pub async fn mark_relay_started(&self, id: &str, now: i64) -> Result<bool> {
        let marked = sqlx::query(
            "UPDATE pair_operations SET relay_started = 1, attempts = attempts + 1, updated_at = \
             ?2 WHERE id = ?1 AND state = 'prepared'",
        )
        .bind(id)
        .bind(now)
        .execute(&self.pool)
        .await?;
        Ok(marked.rows_affected() == 1)
    }

    /// Record that the relay confirmed its part.
    pub async fn mark_relay_applied(&self, id: &str, now: i64) -> Result<()> {
        sqlx::query(
            "UPDATE pair_operations SET state = 'relay_applied', next_attempt_at = NULL, \
             updated_at = ?2 WHERE id = ?1 AND state = 'prepared'",
        )
        .bind(id)
        .bind(now)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Schedule the next attempt after a relay failure.
    pub async fn defer_operation(&self, id: &str, next_attempt_at: i64, now: i64) -> Result<()> {
        sqlx::query(
            "UPDATE pair_operations SET next_attempt_at = ?2, updated_at = ?3 WHERE id = ?1",
        )
        .bind(id)
        .bind(next_attempt_at)
        .bind(now)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Before relay work: fail the operation if what it confirmed has changed.
    /// Returns the operation as it now stands.
    pub async fn revalidate_operation(
        &self,
        id: &str,
        context: CommitContext<'_>,
    ) -> Result<PairOperation> {
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let operation = operation_in(&mut tx, id)
            .await?
            .ok_or(sqlx::Error::RowNotFound)?;
        if operation.state.is_terminal() {
            return Ok(operation);
        }
        let verdict =
            commit_blocker(&mut tx, &operation, context.now, context.max_group_size).await?;
        let Some(code) = verdict else {
            return Ok(operation);
        };
        let failed = fail_in(&mut tx, &operation, code, context.now).await?;
        tx.commit().await?;
        Ok(failed)
    }

    /// Commit an operation whose relay work is done: revalidate everything it
    /// confirmed, then move membership and open the new generation atomically.
    /// If the destination changed it fails instead, and membership stays put.
    pub async fn commit_operation(
        &self,
        id: &str,
        context: CommitContext<'_>,
    ) -> Result<PairOperation> {
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let operation = operation_in(&mut tx, id)
            .await?
            .ok_or(sqlx::Error::RowNotFound)?;
        if operation.state != OperationState::RelayApplied {
            return Ok(operation);
        }
        let verdict =
            commit_blocker(&mut tx, &operation, context.now, context.max_group_size).await?;
        let finished = match verdict {
            Some(code) => fail_in(&mut tx, &operation, code, context.now).await?,
            None => match operation.kind {
                OperationKind::Link => apply_link(&mut tx, &operation, context.now).await?,
                OperationKind::Leave | OperationKind::Remove => {
                    apply_departure(&mut tx, &operation, context.now).await?
                },
                OperationKind::Restore | OperationKind::Retake => {
                    apply_restore(
                        &mut tx,
                        &operation,
                        context.now,
                        context.derive_lookup,
                        context.retake_window_secs,
                    )
                    .await?
                },
                OperationKind::Rotate | OperationKind::Decide => operation,
            },
        };
        tx.commit().await?;
        Ok(finished)
    }
}
