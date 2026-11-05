//! Recovery requests: the path that needs no code, only a member's approval.
//!
//! A hint locates a row and nothing more. Creating a request reveals nothing
//! and changes nothing, a member's approval changes nothing either, and only
//! the requester's confirmation starts an operation.

use sqlx::SqliteConnection;
use uuid::Uuid;

use super::devices::{device_in, group_size_in, user_in};
use super::models::{Device, DeviceUser, OperationKind, RestoreRequest, RestoreRequestState};
use super::prepare::{
    existing_operation, insert_terminal_operation, refuse_if_transitioning, OperationMeta,
};
use super::refusal::Refusal;
use crate::{Result, Store};

const REQUEST_COLUMNS: &str = "id, requester_device_id, target_device_id, target_user_id, \
                               target_generation, target_revision, state, created_at, expires_at, \
                               approval_expires_at, updated_at";

/// How long an unanswered request lives.
const REQUEST_TTL_SECS: i64 = 7 * 24 * 3600;

/// How long an approval waits for its requester.
const APPROVAL_TTL_SECS: i64 = 24 * 3600;

/// What answering a request names.
#[derive(Debug, Clone, Copy)]
pub struct DecideInput<'a> {
    /// The idempotent operation.
    pub meta: OperationMeta<'a>,
    /// The member's session generation.
    pub generation: i64,
    /// The device named in the route.
    pub target_device_id: &'a str,
    /// The exact request being answered.
    pub request_id: &'a str,
    /// Allow or deny.
    pub allow: bool,
}

async fn request_in(conn: &mut SqliteConnection, id: &str) -> Result<Option<RestoreRequest>> {
    let request = sqlx::query_as::<_, RestoreRequest>(sqlx::AssertSqlSafe(format!(
        "SELECT {REQUEST_COLUMNS} FROM pair_restore_requests WHERE id = ?1"
    )))
    .bind(id)
    .fetch_optional(&mut *conn)
    .await?;
    Ok(request)
}

async fn set_request_state(
    conn: &mut SqliteConnection,
    id: &str,
    state: RestoreRequestState,
    now: i64,
) -> Result<()> {
    sqlx::query("UPDATE pair_restore_requests SET state = ?2, updated_at = ?3 WHERE id = ?1")
        .bind(id)
        .bind(state)
        .bind(now)
        .execute(&mut *conn)
        .await?;
    Ok(())
}

/// Bring an open request up to date: end it if it ran out of time or if what it
/// bound (the target's generation, group or revision) has changed.
async fn settle_request(
    conn: &mut SqliteConnection,
    request: RestoreRequest,
    now: i64,
) -> Result<RestoreRequest> {
    let next = match request.state {
        RestoreRequestState::Pending | RestoreRequestState::Approved => {
            let expired = match request.state {
                RestoreRequestState::Approved => request
                    .approval_expires_at
                    .is_none_or(|expires| expires <= now),
                _ => request.expires_at <= now,
            };
            if expired {
                Some(RestoreRequestState::Expired)
            } else if binding_holds(conn, &request).await? {
                None
            } else {
                Some(RestoreRequestState::Stale)
            }
        },
        _ => None,
    };
    let Some(state) = next else {
        return Ok(request);
    };
    set_request_state(conn, &request.id, state, now).await?;
    Ok(RestoreRequest {
        state,
        updated_at: now,
        ..request
    })
}

async fn binding_holds(conn: &mut SqliteConnection, request: &RestoreRequest) -> Result<bool> {
    let Some(target) = device_in(conn, &request.target_device_id).await? else {
        return Ok(false);
    };
    let Some(user) = user_in(conn, &target.user_id).await? else {
        return Ok(false);
    };
    Ok(target.session_generation == request.target_generation
        && target.user_id == request.target_user_id
        && user.membership_revision == request.target_revision)
}

/// Require that `request_id` is a live approval by this requester for this
/// target.
pub(super) async fn require_approved_in(
    conn: &mut SqliteConnection,
    request_id: &str,
    requester: &Device,
    target: &Device,
    group: &DeviceUser,
    now: i64,
) -> Result<()> {
    let request = request_in(conn, request_id)
        .await?
        .filter(|request| {
            request.requester_device_id == requester.id && request.target_device_id == target.id
        })
        .ok_or(Refusal::NotFound)?;
    let request = settle_request(conn, request, now).await?;
    let live = request.state == RestoreRequestState::Approved
        && request.target_user_id == group.id
        && request.target_revision == group.membership_revision;
    if live {
        return Ok(());
    }
    // Stale means the target or its group changed, so what the user saw is out of
    // date: a stale preview like any other. Anything else simply no longer
    // applies.
    if request.state == RestoreRequestState::Stale {
        return Err(Refusal::PreviewStale.into());
    }
    Err(Refusal::Stale.into())
}

impl Store {
    /// Open a recovery request from an inactive device with no peers to
    /// whichever device holds this hint.
    ///
    /// Asking again while a request is open returns that request, so a lost
    /// response is recoverable. A new request can neither overwrite a pending
    /// one nor touch current access, and a full set of slots blocks only
    /// this path.
    pub async fn create_restore_request(
        &self,
        requester_id: &str,
        generation: i64,
        hardware_lookup: &[u8],
        slots: i64,
        now: i64,
    ) -> Result<RestoreRequest> {
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let requester = device_in(&mut tx, requester_id)
            .await?
            .ok_or(Refusal::SessionStale)?;
        if requester.session_generation != generation {
            return Err(Refusal::SessionStale.into());
        }
        if requester.pending_transition_id.is_some() {
            return Err(Refusal::TransitionPending {
                operation_id: None,
            }
            .into());
        }
        if requester.activated_at.is_some() || group_size_in(&mut tx, &requester.user_id).await? > 1
        {
            return Err(Refusal::Stale.into());
        }
        let open = sqlx::query_as::<_, RestoreRequest>(sqlx::AssertSqlSafe(format!(
            "SELECT {REQUEST_COLUMNS} FROM pair_restore_requests
             WHERE requester_device_id = ?1 AND state IN ('pending', 'approved')"
        )))
        .bind(requester_id)
        .fetch_optional(&mut *tx)
        .await?;
        if let Some(open) = open {
            let settled = settle_request(&mut tx, open, now).await?;
            if matches!(settled.state, RestoreRequestState::Pending | RestoreRequestState::Approved)
            {
                tx.commit().await?;
                return Ok(settled);
            }
        }
        let holder: Option<(String,)> =
            sqlx::query_as("SELECT id FROM devices WHERE hardware_lookup = ?1 AND id != ?2")
                .bind(hardware_lookup)
                .bind(requester_id)
                .fetch_optional(&mut *tx)
                .await?;
        let Some((target_id,)) = holder else {
            tx.commit().await?;
            return Err(Refusal::NotFound.into());
        };
        let target = device_in(&mut tx, &target_id)
            .await?
            .ok_or(Refusal::NotFound)?;
        let group = user_in(&mut tx, &target.user_id)
            .await?
            .ok_or(Refusal::NotFound)?;
        let others = sqlx::query_as::<_, RestoreRequest>(sqlx::AssertSqlSafe(format!(
            "SELECT {REQUEST_COLUMNS} FROM pair_restore_requests
             WHERE target_device_id = ?1 AND state IN ('pending', 'approved')"
        )))
        .bind(&target_id)
        .fetch_all(&mut *tx)
        .await?;
        let mut occupied = 0;
        for other in others {
            let settled = settle_request(&mut tx, other, now).await?;
            if matches!(settled.state, RestoreRequestState::Pending | RestoreRequestState::Approved)
            {
                occupied += 1;
            }
        }
        if occupied >= slots {
            tx.commit().await?;
            return Err(Refusal::SlotsFull.into());
        }
        let id = Uuid::new_v4().simple().to_string();
        sqlx::query(
            "INSERT INTO pair_restore_requests (id, requester_device_id, target_device_id, \
             target_user_id, target_generation, target_revision, state, created_at, expires_at, \
             updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'pending', ?7, ?8, ?7)",
        )
        .bind(&id)
        .bind(requester_id)
        .bind(&target_id)
        .bind(&target.user_id)
        .bind(target.session_generation)
        .bind(group.membership_revision)
        .bind(now)
        .bind(now + REQUEST_TTL_SECS)
        .execute(&mut *tx)
        .await?;
        let created = request_in(&mut tx, &id)
            .await?
            .ok_or(sqlx::Error::RowNotFound)?;
        tx.commit().await?;
        Ok(created)
    }

    /// A request as it stands now, for the device that made it.
    pub async fn restore_request_for(
        &self,
        id: &str,
        requester_id: &str,
        now: i64,
    ) -> Result<Option<RestoreRequest>> {
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let Some(request) = request_in(&mut tx, id)
            .await?
            .filter(|request| request.requester_device_id == requester_id)
        else {
            return Ok(None);
        };
        let settled = settle_request(&mut tx, request, now).await?;
        tx.commit().await?;
        Ok(Some(settled))
    }

    /// Allow or deny this exact request, from a current member of the target's
    /// group. Allowing changes nothing until the requester confirms.
    pub async fn decide_restore_request(&self, input: DecideInput<'_>) -> Result<()> {
        let meta = input.meta;
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        if existing_operation(&mut tx, meta.id, meta.fingerprint)
            .await?
            .is_some()
        {
            return Ok(());
        }
        let actor = device_in(&mut tx, meta.actor_device_id)
            .await?
            .ok_or(Refusal::SessionStale)?;
        if actor.session_generation != input.generation {
            return Err(Refusal::SessionStale.into());
        }
        refuse_if_transitioning(&mut tx, &actor, meta.actor_secret_hash).await?;
        let target = device_in(&mut tx, input.target_device_id)
            .await?
            .filter(|target| target.user_id == actor.user_id)
            .ok_or(Refusal::NotFound)?;
        let request = request_in(&mut tx, input.request_id)
            .await?
            .filter(|request| request.target_device_id == target.id)
            .ok_or(Refusal::NotFound)?;
        let settled = settle_request(&mut tx, request, meta.now).await?;
        if settled.state != RestoreRequestState::Pending {
            tx.commit().await?;
            return Err(Refusal::Stale.into());
        }
        let (state, approval) = if input.allow {
            (RestoreRequestState::Approved, Some(meta.now + APPROVAL_TTL_SECS))
        } else {
            (RestoreRequestState::Denied, None)
        };
        sqlx::query(
            "UPDATE pair_restore_requests SET state = ?2, approval_expires_at = ?3, updated_at = \
             ?4 WHERE id = ?1",
        )
        .bind(input.request_id)
        .bind(state)
        .bind(approval)
        .bind(meta.now)
        .execute(&mut *tx)
        .await?;
        insert_terminal_operation(&mut tx, meta, OperationKind::Decide, &target, false).await?;
        tx.commit().await?;
        Ok(())
    }

    /// Open requests about a group's devices that a member can still answer,
    /// with each requester's name, newest first and bounded. A request
    /// whose target or group has changed since it was made is undecidable,
    /// so it is not offered.
    pub async fn pending_restore_requests(
        &self,
        user_id: &str,
        limit: i64,
        now: i64,
    ) -> Result<Vec<(RestoreRequest, String)>> {
        let rows = sqlx::query_as::<_, RestoreRequest>(
            "SELECT r.id, r.requester_device_id, r.target_device_id, r.target_user_id, \
             r.target_generation, r.target_revision, r.state, r.created_at, r.expires_at, \
             r.approval_expires_at, r.updated_at
             FROM pair_restore_requests r
             JOIN devices d ON d.id = r.target_device_id
             JOIN device_users u ON u.id = d.user_id
             WHERE r.target_user_id = ?1 AND r.state = 'pending' AND r.expires_at > ?2
             AND d.user_id = r.target_user_id AND d.session_generation = r.target_generation
             AND u.membership_revision = r.target_revision
             ORDER BY r.created_at DESC LIMIT ?3",
        )
        .bind(user_id)
        .bind(now)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        let mut out = Vec::with_capacity(rows.len());
        let mut conn = self.pool.acquire().await?;
        for request in rows {
            if let Some(requester) = device_in(&mut conn, &request.requester_device_id).await? {
                out.push((request, requester.label));
            }
        }
        Ok(out)
    }
}
