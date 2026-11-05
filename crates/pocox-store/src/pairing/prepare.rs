//! Step one of a durable membership change: persist the operation and mark its
//! subject transitioning, atomically, after checking what the user confirmed.
//!
//! Nothing here talks to the relay. A change is serialized per group: while an
//! operation is open on a user, no other may start on it, so an operation that
//! would only lose at commit is refused before it revokes anything.

use sqlx::SqliteConnection;

use super::budgets::{charge_budget_in, BudgetVerdict};
use super::devices::{
    activate_in, device_in, group_size_in, new_user_id, user_in, HardwareBinding,
};
use super::models::{Device, OperationKind, OperationState, PairOperation};
use super::operations::OPERATION_COLUMNS;
use super::refusal::Refusal;
use crate::{Result, Store};

/// Who is asking for an idempotent operation.
#[derive(Debug, Clone, Copy)]
pub struct OperationMeta<'a> {
    /// The client-chosen idempotency id.
    pub id: &'a str,
    /// Hash of the exact request. A retry must match it.
    pub fingerprint: &'a [u8],
    /// The device asking.
    pub actor_device_id: &'a str,
    /// The asking device's secret hash, which authorizes reading the result.
    pub actor_secret_hash: &'a [u8],
    /// The current time.
    pub now: i64,
}

/// What preparing an operation came to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Prepared {
    /// The operation as it stands.
    pub operation: PairOperation,
    /// False when the id had already been used: this request is a replay.
    pub is_new: bool,
}

impl Prepared {
    fn new(operation: PairOperation) -> Self {
        Self {
            operation,
            is_new: true,
        }
    }

    fn replay(operation: PairOperation) -> Self {
        Self {
            operation,
            is_new: false,
        }
    }
}

/// What a confirmed link names.
#[derive(Debug, Clone, Copy)]
pub struct LinkInput<'a> {
    /// The idempotent operation.
    pub meta: OperationMeta<'a>,
    /// The caller's generation in the confirmed ticket.
    pub generation: i64,
    /// The caller's group revision in the confirmed ticket.
    pub source_revision: i64,
    /// The device whose code was confirmed.
    pub target_device_id: &'a str,
    /// That code's generation in the ticket.
    pub code_generation: i64,
    /// That code's pause epoch in the ticket.
    pub code_pause_epoch: i64,
    /// The group the user confirmed.
    pub destination_user_id: &'a str,
    /// That group's revision in the ticket.
    pub destination_revision: i64,
    /// Explicit confirmation of leaving current peers.
    pub leave_current: bool,
    /// Bound at commit.
    pub hardware: Option<HardwareBinding<'a>>,
    /// The largest a group may grow.
    pub max_group_size: i64,
    /// The backend-wide budget a link owing relay work draws from.
    pub relay_budget: RelayBudget<'a>,
}

/// A backend-wide budget, charged inside the transaction that decides it is
/// owed.
#[derive(Debug, Clone, Copy)]
pub struct RelayBudget<'a> {
    /// The budget's name.
    pub name: &'a str,
    /// Its window.
    pub window_secs: i64,
    /// Units per window.
    pub limit: i64,
}

/// What removing a peer names.
#[derive(Debug, Clone, Copy)]
pub struct RemoveInput<'a> {
    /// The idempotent operation.
    pub meta: OperationMeta<'a>,
    /// The actor's session generation.
    pub generation: i64,
    /// The device being removed.
    pub subject_device_id: &'a str,
}

/// What authorizes a restore.
#[derive(Debug, Clone, Copy)]
pub enum RestoreProof<'a> {
    /// A preview ticket for a current code of the target's group.
    Ticket {
        /// The caller's group revision in the ticket.
        source_revision: i64,
        /// The device whose code was confirmed.
        code_device_id: &'a str,
        /// That code's generation in the ticket.
        code_generation: i64,
        /// That code's pause epoch in the ticket.
        code_pause_epoch: i64,
        /// The group the ticket confirmed.
        destination_user_id: &'a str,
        /// That group's revision in the ticket.
        destination_revision: i64,
    },
    /// A member's approval of this exact request.
    Request {
        /// The approved request's id.
        request_id: &'a str,
    },
}

/// What a confirmed restore names.
#[derive(Debug, Clone, Copy)]
pub struct RestoreInput<'a> {
    /// The idempotent operation.
    pub meta: OperationMeta<'a>,
    /// The requester's generation.
    pub generation: i64,
    /// The device this claims to be.
    pub target_device_id: &'a str,
    /// What authorizes it.
    pub proof: RestoreProof<'a>,
    /// A compromised-device retake rather than a continuity restore.
    pub retake: bool,
    /// Bound at commit.
    pub hardware: Option<HardwareBinding<'a>>,
    /// The fixed overlap of a continuity restore.
    pub overlap_secs: i64,
    /// Retakes allowed per device per window.
    pub retake_limit: i64,
    /// The retake window.
    pub retake_window_secs: i64,
}

/// The fields of a new `pair_operations` row.
pub(super) struct NewOperation<'a> {
    pub meta: OperationMeta<'a>,
    pub kind: OperationKind,
    pub subject_device_id: &'a str,
    pub subject_generation: i64,
    pub source_user_id: &'a str,
    pub source_revision: i64,
    pub destination_user_id: Option<&'a str>,
    pub destination_revision: Option<i64>,
    pub code_device_id: Option<&'a str>,
    pub code_generation: Option<i64>,
    pub code_pause_epoch: Option<i64>,
    pub request_id: Option<&'a str>,
    pub new_user_id: Option<&'a str>,
    pub hardware: Option<HardwareBinding<'a>>,
    pub grace_deadline: Option<i64>,
    pub state: OperationState,
    pub no_op: bool,
}

/// The operation a retry names, or `None` for a new id. Reusing an id with
/// other input fails rather than applying the new input.
pub(super) async fn existing_operation(
    conn: &mut SqliteConnection,
    id: &str,
    fingerprint: &[u8],
) -> Result<Option<PairOperation>> {
    let found = operation_in(conn, id).await?;
    match found {
        Some(operation) if operation.fingerprint == fingerprint => Ok(Some(operation)),
        Some(_) => Err(Refusal::OperationConflict.into()),
        None => Ok(None),
    }
}

pub(super) async fn operation_in(
    conn: &mut SqliteConnection,
    id: &str,
) -> Result<Option<PairOperation>> {
    let operation = sqlx::query_as::<_, PairOperation>(sqlx::AssertSqlSafe(format!(
        "SELECT {OPERATION_COLUMNS} FROM pair_operations WHERE id = ?1"
    )))
    .bind(id)
    .fetch_optional(&mut *conn)
    .await?;
    Ok(operation)
}

pub(super) async fn insert_operation(
    conn: &mut SqliteConnection,
    new: &NewOperation<'_>,
) -> Result<PairOperation> {
    let terminal = new.state.is_terminal();
    sqlx::query(
        "INSERT INTO pair_operations (id, kind, fingerprint, actor_device_id, actor_secret_hash, \
         subject_device_id, subject_generation, source_user_id, source_revision, \
         destination_user_id, destination_revision, code_device_id, code_generation, request_id, \
         new_user_id, hardware_lookup, hardware_source, grace_deadline, state, result_device_id, \
         created_at, updated_at, completed_at, code_pause_epoch, no_op) VALUES (?1, ?2, ?3, ?4, \
         ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?21, \
         ?22, ?23, ?24)",
    )
    .bind(new.meta.id)
    .bind(new.kind)
    .bind(new.meta.fingerprint)
    .bind(new.meta.actor_device_id)
    .bind(new.meta.actor_secret_hash)
    .bind(new.subject_device_id)
    .bind(new.subject_generation)
    .bind(new.source_user_id)
    .bind(new.source_revision)
    .bind(new.destination_user_id)
    .bind(new.destination_revision)
    .bind(new.code_device_id)
    .bind(new.code_generation)
    .bind(new.request_id)
    .bind(new.new_user_id)
    .bind(new.hardware.map(|binding| binding.lookup))
    .bind(new.hardware.and_then(|binding| binding.source))
    .bind(new.grace_deadline)
    .bind(new.state)
    .bind(terminal.then_some(new.meta.actor_device_id))
    .bind(new.meta.now)
    .bind(terminal.then_some(new.meta.now))
    .bind(new.code_pause_epoch)
    .bind(new.no_op)
    .execute(&mut *conn)
    .await?;
    let inserted = operation_in(conn, new.meta.id)
        .await?
        .ok_or(sqlx::Error::RowNotFound)?;
    Ok(inserted)
}

/// Record an operation that is complete the moment it is decided: it has no
/// relay work, or it changes nothing.
pub(super) async fn insert_terminal_operation(
    conn: &mut SqliteConnection,
    meta: OperationMeta<'_>,
    kind: OperationKind,
    subject: &Device,
    no_op: bool,
) -> Result<PairOperation> {
    if no_op {
        // A no-op changes nothing worth keeping two records of, and each one is free
        // to repeat. One row per device and kind bounds what that costs the database.
        sqlx::query(
            "DELETE FROM pair_operations WHERE actor_device_id = ?1 AND kind = ?2 AND no_op",
        )
        .bind(meta.actor_device_id)
        .bind(kind)
        .execute(&mut *conn)
        .await?;
    }
    let user = user_in(conn, &subject.user_id)
        .await?
        .ok_or(sqlx::Error::RowNotFound)?;
    insert_operation(conn, &NewOperation {
        meta,
        kind,
        subject_device_id: &subject.id,
        subject_generation: subject.session_generation,
        source_user_id: &subject.user_id,
        source_revision: user.membership_revision,
        destination_user_id: None,
        destination_revision: None,
        code_device_id: None,
        code_generation: None,
        code_pause_epoch: None,
        request_id: None,
        new_user_id: None,
        hardware: None,
        grace_deadline: None,
        state: OperationState::Committed,
        no_op,
    })
    .await
}

pub(super) async fn refuse_if_transitioning(
    conn: &mut SqliteConnection,
    device: &Device,
    secret_hash: &[u8],
) -> Result<()> {
    let Some(pending) = &device.pending_transition_id else {
        return Ok(());
    };
    // Its id is only for whoever asked for it: a device being removed by a peer
    // learns the outcome from its refresh.
    let own = operation_in(conn, pending)
        .await?
        .is_some_and(|operation| operation.actor_secret_hash == secret_hash);
    Err(Refusal::TransitionPending {
        operation_id: own.then(|| pending.clone()),
    }
    .into())
}

/// Refuse while another device is transitioning. Its operation is not the
/// caller's to read, so its id is not revealed.
fn refuse_if_other_transitioning(device: &Device) -> Result<()> {
    if device.pending_transition_id.is_some() {
        return Err(Refusal::TransitionPending {
            operation_id: None,
        }
        .into());
    }
    Ok(())
}

/// Refuse while any operation is open on `user_id`. That operation may be
/// another device's, so its id is not revealed.
async fn refuse_if_group_busy(conn: &mut SqliteConnection, user_id: &str) -> Result<()> {
    let (open,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM pair_operations WHERE state IN ('prepared', 'relay_applied')
         AND (source_user_id = ?1 OR destination_user_id = ?1)",
    )
    .bind(user_id)
    .fetch_one(&mut *conn)
    .await?;
    if open > 0 {
        return Err(Refusal::TransitionPending {
            operation_id: None,
        }
        .into());
    }
    Ok(())
}

/// Mark `device` transitioning and limit its current session to `deadline`,
/// which is fixed here and never moves again.
async fn begin_transition(
    conn: &mut SqliteConnection,
    device_id: &str,
    operation_id: &str,
    deadline: i64,
) -> Result<()> {
    sqlx::query("UPDATE devices SET pending_transition_id = ?2 WHERE id = ?1")
        .bind(device_id)
        .bind(operation_id)
        .execute(&mut *conn)
        .await?;
    sqlx::query(
        "UPDATE device_sessions SET grace_deadline = ?2 WHERE device_id = ?1 AND state = 'current'",
    )
    .bind(device_id)
    .bind(deadline)
    .execute(&mut *conn)
    .await?;
    Ok(())
}

/// End every earlier overlap at once: no-grace changes revoke them all.
async fn revoke_grace_sessions(
    conn: &mut SqliteConnection,
    device_id: &str,
    now: i64,
) -> Result<()> {
    sqlx::query(
        "UPDATE device_sessions SET state = 'revoked', retired_at = COALESCE(retired_at, ?2)
         WHERE device_id = ?1 AND state = 'grace'",
    )
    .bind(device_id)
    .bind(now)
    .execute(&mut *conn)
    .await?;
    Ok(())
}

/// Owe the relay a cutoff on a device's open keys, in `generation` or in all of
/// them.
///
/// The debt outlives the operation. If the operation fails after touching the
/// relay, the worker still enforces it, so an old key cannot run on to its full
/// life. A key already ending by then owes nothing.
async fn owe_key_cutoffs(
    conn: &mut SqliteConnection,
    device_id: &str,
    generation: Option<i64>,
    cutoff: i64,
    now: i64,
) -> Result<()> {
    sqlx::query(
        "UPDATE device_relay_keys SET
             cutoff_pending = CASE WHEN local_end IS NOT NULL AND local_end <= ?3 THEN 0 ELSE 1 \
         END,
             hard_cutoff = MIN(COALESCE(hard_cutoff, ?3), ?3),
             updated_at = ?4
         WHERE device_id = ?1 AND (?2 IS NULL OR generation = ?2)
         AND state IN ('granting', 'active')",
    )
    .bind(device_id)
    .bind(generation)
    .bind(cutoff)
    .bind(now)
    .execute(&mut *conn)
    .await?;
    Ok(())
}

impl Store {
    /// Persist a confirmed link, or read a retry's result.
    ///
    /// A link to a device already in the caller's user is a no-op success,
    /// which is how opposite-direction links converge. The user still confirmed
    /// this group, so it activates the device like any other link. Anything
    /// else that changed since the preview is `PreviewStale`.
    pub async fn prepare_link(&self, input: LinkInput<'_>) -> Result<Prepared> {
        let meta = input.meta;
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        if let Some(operation) = existing_operation(&mut tx, meta.id, meta.fingerprint).await? {
            return Ok(Prepared::replay(operation));
        }
        let subject = device_in(&mut tx, meta.actor_device_id)
            .await?
            .ok_or(Refusal::SessionStale)?;
        refuse_if_transitioning(&mut tx, &subject, meta.actor_secret_hash).await?;
        let target = device_in(&mut tx, input.target_device_id)
            .await?
            .ok_or(Refusal::PreviewStale)?;
        if target.user_id == subject.user_id {
            activate_in(&mut tx, &subject, input.hardware, meta.now).await?;
            let done =
                insert_terminal_operation(&mut tx, meta, OperationKind::Link, &subject, true)
                    .await?;
            tx.commit().await?;
            return Ok(Prepared::new(done));
        }
        refuse_if_other_transitioning(&target)?;
        let source = user_in(&mut tx, &subject.user_id)
            .await?
            .ok_or(sqlx::Error::RowNotFound)?;
        if subject.session_generation != input.generation
            || source.membership_revision != input.source_revision
        {
            return Err(Refusal::PreviewStale.into());
        }
        let destination = user_in(&mut tx, &target.user_id)
            .await?
            .ok_or(sqlx::Error::RowNotFound)?;
        if target.user_id != input.destination_user_id
            || destination.membership_revision != input.destination_revision
            || target.code_generation != input.code_generation
            || target.code_pause_epoch != input.code_pause_epoch
            || target.code_paused
        {
            return Err(Refusal::PreviewStale.into());
        }
        refuse_if_group_busy(&mut tx, &subject.user_id).await?;
        refuse_if_group_busy(&mut tx, &target.user_id).await?;
        if group_size_in(&mut tx, &subject.user_id).await? > 1 && !input.leave_current {
            return Err(Refusal::AlreadyLinked.into());
        }
        if group_size_in(&mut tx, &target.user_id).await? >= input.max_group_size {
            return Err(Refusal::GroupFull.into());
        }
        // Links are the one move with a backend-wide budget, and only one owing the
        // relay work spends it: a no-op or a device with no keys costs the
        // relay nothing here. Leave and removal never touch it, each needing a
        // peer some link paid to bring in, so spending this budget can never
        // stop anyone removing an intruder.
        let (owed,): (i64,) = sqlx::query_as(
            "SELECT COUNT(*) FROM device_relay_keys
             WHERE device_id = ?1 AND state IN ('granting', 'active')",
        )
        .bind(&subject.id)
        .fetch_one(&mut *tx)
        .await?;
        if owed > 0 {
            let budget = input.relay_budget;
            let verdict =
                charge_budget_in(&mut tx, budget.name, budget.window_secs, budget.limit, meta.now)
                    .await?;
            if let BudgetVerdict::Refused {
                retry_after,
            } = verdict
            {
                return Err(Refusal::TooSoon {
                    retry_after,
                }
                .into());
            }
        }
        let operation = insert_operation(&mut tx, &NewOperation {
            meta,
            kind: OperationKind::Link,
            subject_device_id: &subject.id,
            subject_generation: subject.session_generation,
            source_user_id: &subject.user_id,
            source_revision: source.membership_revision,
            destination_user_id: Some(&target.user_id),
            destination_revision: Some(destination.membership_revision),
            code_device_id: Some(&target.id),
            code_generation: Some(target.code_generation),
            code_pause_epoch: Some(target.code_pause_epoch),
            request_id: None,
            new_user_id: None,
            hardware: input.hardware,
            grace_deadline: None,
            state: OperationState::Prepared,
            no_op: false,
        })
        .await?;
        begin_transition(&mut tx, &subject.id, meta.id, meta.now).await?;
        revoke_grace_sessions(&mut tx, &subject.id, meta.now).await?;
        owe_key_cutoffs(&mut tx, &subject.id, None, meta.now, meta.now).await?;
        tx.commit().await?;
        Ok(Prepared::new(operation))
    }

    /// Persist moving the caller out of its group, or read a retry's result. A
    /// device already alone has nothing to leave: that is a no-op, never
    /// another new group.
    pub async fn prepare_leave(
        &self,
        meta: OperationMeta<'_>,
        generation: i64,
    ) -> Result<Prepared> {
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        if let Some(operation) = existing_operation(&mut tx, meta.id, meta.fingerprint).await? {
            return Ok(Prepared::replay(operation));
        }
        let subject = device_in(&mut tx, meta.actor_device_id)
            .await?
            .ok_or(Refusal::SessionStale)?;
        if subject.session_generation != generation {
            return Err(Refusal::SessionStale.into());
        }
        refuse_if_transitioning(&mut tx, &subject, meta.actor_secret_hash).await?;
        if group_size_in(&mut tx, &subject.user_id).await? <= 1 {
            let done =
                insert_terminal_operation(&mut tx, meta, OperationKind::Leave, &subject, true)
                    .await?;
            tx.commit().await?;
            return Ok(Prepared::new(done));
        }
        let operation = prepare_departure(&mut tx, meta, OperationKind::Leave, &subject).await?;
        tx.commit().await?;
        Ok(Prepared::new(operation))
    }

    /// Persist removing a peer from the actor's current user, or read a retry's
    /// result. The actor's own membership is rechecked here, so a concurrent
    /// removal of the actor cannot authorize a later action on its former
    /// peers.
    pub async fn prepare_remove(&self, input: RemoveInput<'_>) -> Result<Prepared> {
        let meta = input.meta;
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        if let Some(operation) = existing_operation(&mut tx, meta.id, meta.fingerprint).await? {
            return Ok(Prepared::replay(operation));
        }
        let actor = device_in(&mut tx, meta.actor_device_id)
            .await?
            .ok_or(Refusal::SessionStale)?;
        if actor.session_generation != input.generation {
            return Err(Refusal::SessionStale.into());
        }
        refuse_if_transitioning(&mut tx, &actor, meta.actor_secret_hash).await?;
        let subject = device_in(&mut tx, input.subject_device_id)
            .await?
            .filter(|subject| subject.user_id == actor.user_id && subject.id != actor.id)
            .ok_or(Refusal::NotFound)?;
        refuse_if_other_transitioning(&subject)?;
        let operation = prepare_departure(&mut tx, meta, OperationKind::Remove, &subject).await?;
        tx.commit().await?;
        Ok(Prepared::new(operation))
    }

    /// Persist a confirmed recovery, or read a retry's result.
    ///
    /// Fixes the retiring generation's deadline at this moment, before its keys
    /// are shortened and before any replacement exists, so nothing later
    /// can extend it.
    pub async fn prepare_restore(&self, input: RestoreInput<'_>) -> Result<Prepared> {
        let meta = input.meta;
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        if let Some(operation) = existing_operation(&mut tx, meta.id, meta.fingerprint).await? {
            return Ok(Prepared::replay(operation));
        }
        let requester = device_in(&mut tx, meta.actor_device_id)
            .await?
            .ok_or(Refusal::SessionStale)?;
        if requester.session_generation != input.generation {
            return Err(Refusal::SessionStale.into());
        }
        refuse_if_transitioning(&mut tx, &requester, meta.actor_secret_hash).await?;
        if requester.activated_at.is_some() || group_size_in(&mut tx, &requester.user_id).await? > 1
        {
            return Err(Refusal::Stale.into());
        }
        let target = device_in(&mut tx, input.target_device_id)
            .await?
            .filter(|target| target.id != requester.id)
            .ok_or(Refusal::PreviewStale)?;
        let group = user_in(&mut tx, &target.user_id)
            .await?
            .ok_or(sqlx::Error::RowNotFound)?;
        let mut code_device = None;
        let mut request_id = None;
        match input.proof {
            RestoreProof::Ticket {
                source_revision,
                code_device_id,
                code_generation,
                code_pause_epoch,
                destination_user_id,
                destination_revision,
            } => {
                let source = user_in(&mut tx, &requester.user_id)
                    .await?
                    .ok_or(sqlx::Error::RowNotFound)?;
                let code_holder = device_in(&mut tx, code_device_id).await?;
                let holds_code = code_holder.as_ref().is_some_and(|holder| {
                    holder.user_id == destination_user_id
                        && holder.code_generation == code_generation
                        && holder.code_pause_epoch == code_pause_epoch
                        && !holder.code_paused
                });
                if !holds_code
                    || source.membership_revision != source_revision
                    || target.user_id != destination_user_id
                    || group.membership_revision != destination_revision
                {
                    return Err(Refusal::PreviewStale.into());
                }
                code_device = Some((code_device_id, code_generation, code_pause_epoch));
            },
            RestoreProof::Request {
                request_id: id,
            } => {
                super::requests::require_approved_in(
                    &mut tx, id, &requester, &target, &group, meta.now,
                )
                .await?;
                request_id = Some(id);
            },
        }
        refuse_if_other_transitioning(&target)?;
        refuse_if_group_busy(&mut tx, &target.user_id).await?;
        refuse_if_group_busy(&mut tx, &requester.user_id).await?;
        if input.retake {
            refuse_if_retake_spent(&target, &input)?;
        }
        let deadline = if input.retake { meta.now } else { meta.now + input.overlap_secs };
        let operation = insert_operation(&mut tx, &NewOperation {
            meta,
            kind: if input.retake { OperationKind::Retake } else { OperationKind::Restore },
            subject_device_id: &target.id,
            subject_generation: target.session_generation,
            source_user_id: &target.user_id,
            source_revision: group.membership_revision,
            destination_user_id: Some(&target.user_id),
            destination_revision: Some(group.membership_revision),
            code_device_id: code_device.map(|(id, _, _)| id),
            code_generation: code_device.map(|(_, generation, _)| generation),
            code_pause_epoch: code_device.map(|(_, _, epoch)| epoch),
            request_id,
            new_user_id: None,
            hardware: input.hardware,
            grace_deadline: Some(deadline),
            state: OperationState::Prepared,
            no_op: false,
        })
        .await?;
        begin_transition(&mut tx, &target.id, meta.id, deadline).await?;
        sqlx::query("UPDATE devices SET pending_transition_id = ?2 WHERE id = ?1")
            .bind(&requester.id)
            .bind(meta.id)
            .execute(&mut *tx)
            .await?;
        // The retiring generation's keys never outlive its deadline from here on,
        // whatever a retry or a delayed earlier request does. A retake ends them all.
        if input.retake {
            revoke_grace_sessions(&mut tx, &target.id, meta.now).await?;
            owe_key_cutoffs(&mut tx, &target.id, None, deadline, meta.now).await?;
        } else {
            owe_key_cutoffs(
                &mut tx,
                &target.id,
                Some(target.session_generation),
                deadline,
                meta.now,
            )
            .await?;
        }
        tx.commit().await?;
        Ok(Prepared::new(operation))
    }
}

fn refuse_if_retake_spent(target: &Device, input: &RestoreInput<'_>) -> Result<()> {
    let now = input.meta.now;
    let window_over = |start: i64| now >= start + input.retake_window_secs;
    match target.retake_window_start {
        Some(start) if !window_over(start) && target.retake_count >= input.retake_limit => {
            Err(Refusal::TooSoon {
                retry_after: u64::try_from(start + input.retake_window_secs - now).unwrap_or(1),
            }
            .into())
        },
        _ => Ok(()),
    }
}

/// Persist a move of `subject` out of its group into a fresh single-device
/// user, with no overlap for its old authorization.
async fn prepare_departure(
    conn: &mut SqliteConnection,
    meta: OperationMeta<'_>,
    kind: OperationKind,
    subject: &Device,
) -> Result<PairOperation> {
    refuse_if_group_busy(conn, &subject.user_id).await?;
    let source = user_in(conn, &subject.user_id)
        .await?
        .ok_or(sqlx::Error::RowNotFound)?;
    let reserved_user = new_user_id();
    let operation = insert_operation(conn, &NewOperation {
        meta,
        kind,
        subject_device_id: &subject.id,
        subject_generation: subject.session_generation,
        source_user_id: &subject.user_id,
        source_revision: source.membership_revision,
        destination_user_id: None,
        destination_revision: None,
        code_device_id: None,
        code_generation: None,
        code_pause_epoch: None,
        request_id: None,
        new_user_id: Some(&reserved_user),
        hardware: None,
        grace_deadline: None,
        state: OperationState::Prepared,
        no_op: false,
    })
    .await?;
    begin_transition(conn, &subject.id, meta.id, meta.now).await?;
    revoke_grace_sessions(conn, &subject.id, meta.now).await?;
    owe_key_cutoffs(conn, &subject.id, None, meta.now, meta.now).await?;
    Ok(operation)
}
