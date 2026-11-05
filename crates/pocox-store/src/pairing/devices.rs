//! Device creation, lookup, activation and group views.

use sqlx::SqliteConnection;
use uuid::Uuid;

use super::codes::next_free_code;
use super::models::{Device, DeviceSessionRow, DeviceUser};
use super::refusal::Refusal;
use crate::{Result, Store};

pub(super) const DEVICE_COLUMNS: &str =
    "id, user_id, label, platform, hardware_lookup, hardware_source, session_generation, \
     code_generation, code_lookup, code_issued_at, code_paused, created_at, joined_at, \
     activated_at, first_key_at, last_active_day, last_transition_kind, last_transition_at, \
     pending_transition_id, retake_window_start, retake_count";

pub(super) const SESSION_COLUMNS: &str = "device_id, generation, secret_hash, original_user_id, \
                                          state, grace_deadline, retired_at, created_at";

const SECS_PER_DAY: i64 = 86_400;

/// The day number of a timestamp.
pub(super) fn day_of(now: i64) -> i64 {
    now.div_euclid(SECS_PER_DAY)
}

/// A fresh device-user id: "du" + 32 hex characters. Disjoint from `users.id`,
/// which is 32 hex characters and can never contain `u`.
pub(super) fn new_user_id() -> String {
    format!("du{}", Uuid::new_v4().simple())
}

/// A device with the session generation a caller holds, and its current user.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceAccess {
    /// The device row.
    pub device: Device,
    /// The session generation.
    pub session: DeviceSessionRow,
    /// The device's current user.
    pub user: DeviceUser,
}

/// A hint to bind to a device. The latest device to bind it holds it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HardwareBinding<'a> {
    /// Keyed hash of the hardware key.
    pub lookup: &'a [u8],
    /// Informational source label.
    pub source: Option<&'a str>,
}

/// What `create_device` needs.
#[derive(Debug, Clone, Copy)]
pub struct NewDevice<'a> {
    /// SHA-256 of the client-generated secret.
    pub secret_hash: &'a [u8],
    /// Display name.
    pub label: &'a str,
    /// Display-only platform label.
    pub platform: Option<&'a str>,
    /// The current time.
    pub now: i64,
}

/// The result of asking for a device by secret, creating it if new.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NewDeviceOutcome {
    /// This request created it.
    Created(Box<DeviceAccess>),
    /// The secret already has a current device.
    Existing(Box<DeviceAccess>),
    /// The secret was replaced. Never recreated, and no deadline restarts.
    Superseded {
        /// The latest overlap deadline of its old generations.
        grace_deadline: Option<i64>,
    },
}

pub(super) async fn device_in(conn: &mut SqliteConnection, id: &str) -> Result<Option<Device>> {
    let device = sqlx::query_as::<_, Device>(sqlx::AssertSqlSafe(format!(
        "SELECT {DEVICE_COLUMNS} FROM devices WHERE id = ?1"
    )))
    .bind(id)
    .fetch_optional(&mut *conn)
    .await?;
    Ok(device)
}

pub(super) async fn user_in(conn: &mut SqliteConnection, id: &str) -> Result<Option<DeviceUser>> {
    let user = sqlx::query_as::<_, DeviceUser>(
        "SELECT id, namespace, membership_revision, created_at FROM device_users WHERE id = ?1",
    )
    .bind(id)
    .fetch_optional(&mut *conn)
    .await?;
    Ok(user)
}

pub(super) async fn group_size_in(conn: &mut SqliteConnection, user_id: &str) -> Result<i64> {
    let (count,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM devices WHERE user_id = ?1")
        .bind(user_id)
        .fetch_one(&mut *conn)
        .await?;
    Ok(count)
}

pub(super) async fn bind_hardware_in(
    conn: &mut SqliteConnection,
    device_id: &str,
    binding: HardwareBinding<'_>,
) -> Result<()> {
    sqlx::query(
        "UPDATE devices SET hardware_lookup = NULL, hardware_source = NULL
         WHERE hardware_lookup = ?1 AND id != ?2",
    )
    .bind(binding.lookup)
    .bind(device_id)
    .execute(&mut *conn)
    .await?;
    sqlx::query("UPDATE devices SET hardware_lookup = ?1, hardware_source = ?2 WHERE id = ?3")
        .bind(binding.lookup)
        .bind(binding.source)
        .bind(device_id)
        .execute(&mut *conn)
        .await?;
    Ok(())
}

async fn access_by_secret_in(
    conn: &mut SqliteConnection,
    secret_hash: &[u8],
) -> Result<Option<DeviceAccess>> {
    let session = sqlx::query_as::<_, DeviceSessionRow>(sqlx::AssertSqlSafe(format!(
        "SELECT {SESSION_COLUMNS} FROM device_sessions WHERE secret_hash = ?1 AND state = \
         'current'"
    )))
    .bind(secret_hash)
    .fetch_optional(&mut *conn)
    .await?;
    let Some(session) = session else {
        return Ok(None);
    };
    let Some(device) = device_in(conn, &session.device_id).await? else {
        return Ok(None);
    };
    let Some(user) = user_in(conn, &device.user_id).await? else {
        return Ok(None);
    };
    Ok(Some(DeviceAccess {
        device,
        session,
        user,
    }))
}

impl Store {
    /// The device holding `secret_hash` as its current secret.
    ///
    /// Checks the current session first: a matching historical hash can never
    /// override the current row after a membership move.
    pub async fn device_by_secret(&self, secret_hash: &[u8]) -> Result<Option<DeviceAccess>> {
        let mut conn = self.pool.acquire().await?;
        access_by_secret_in(&mut conn, secret_hash).await
    }

    /// Whether a secret was replaced, and the latest overlap deadline of its
    /// old generations. `None` when nothing is known about it.
    pub async fn superseded_secret(&self, secret_hash: &[u8]) -> Result<Option<Option<i64>>> {
        let row: Option<(Option<i64>,)> = sqlx::query_as(
            "SELECT MAX(grace_deadline) FROM device_sessions WHERE secret_hash = ?1
             HAVING COUNT(*) > 0",
        )
        .bind(secret_hash)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|(deadline,)| deadline))
    }

    /// A device, one session generation of it, and its current user.
    pub async fn device_access(
        &self,
        device_id: &str,
        generation: i64,
    ) -> Result<Option<DeviceAccess>> {
        let mut conn = self.pool.acquire().await?;
        let session = sqlx::query_as::<_, DeviceSessionRow>(sqlx::AssertSqlSafe(format!(
            "SELECT {SESSION_COLUMNS} FROM device_sessions WHERE device_id = ?1 AND generation = \
             ?2"
        )))
        .bind(device_id)
        .bind(generation)
        .fetch_optional(&mut *conn)
        .await?;
        let Some(session) = session else {
            return Ok(None);
        };
        let Some(device) = device_in(&mut conn, device_id).await? else {
            return Ok(None);
        };
        let Some(user) = user_in(&mut conn, &device.user_id).await? else {
            return Ok(None);
        };
        Ok(Some(DeviceAccess {
            device,
            session,
            user,
        }))
    }

    /// Idempotently create an inactive single-device user and device for a new
    /// secret, or report what is already known about it.
    ///
    /// `derive_lookup` maps a device id and code generation to that code's
    /// lookup. A collision with an active or retained retired code advances
    /// the generation in this same transaction.
    pub async fn create_device(
        &self,
        new: NewDevice<'_>,
        derive_lookup: &(dyn Fn(&str, i64) -> Vec<u8> + Send + Sync),
    ) -> Result<NewDeviceOutcome> {
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        if let Some(existing) = access_by_secret_in(&mut tx, new.secret_hash).await? {
            return Ok(NewDeviceOutcome::Existing(Box::new(existing)));
        }
        let historical: Option<(Option<i64>,)> = sqlx::query_as(
            "SELECT MAX(grace_deadline) FROM device_sessions WHERE secret_hash = ?1
             HAVING COUNT(*) > 0",
        )
        .bind(new.secret_hash)
        .fetch_optional(&mut *tx)
        .await?;
        if let Some((grace_deadline,)) = historical {
            return Ok(NewDeviceOutcome::Superseded {
                grace_deadline,
            });
        }
        let user_id = new_user_id();
        let device_id = Uuid::new_v4().simple().to_string();
        sqlx::query("INSERT INTO device_users (id, created_at) VALUES (?1, ?2)")
            .bind(&user_id)
            .bind(new.now)
            .execute(&mut *tx)
            .await?;
        let (code_generation, code_lookup) =
            next_free_code(&mut tx, &device_id, 1, derive_lookup).await?;
        sqlx::query(
            "INSERT INTO devices (id, user_id, label, platform, session_generation, \
             code_generation, code_lookup, code_issued_at, created_at, joined_at, \
             last_active_day) VALUES (?1, ?2, ?3, ?4, 1, ?5, ?6, ?7, ?7, ?7, ?8)",
        )
        .bind(&device_id)
        .bind(&user_id)
        .bind(new.label)
        .bind(new.platform)
        .bind(code_generation)
        .bind(&code_lookup)
        .bind(new.now)
        .bind(day_of(new.now))
        .execute(&mut *tx)
        .await?;
        sqlx::query(
            "INSERT INTO device_sessions (device_id, generation, secret_hash, original_user_id, \
             state, created_at) VALUES (?1, 1, ?2, ?3, 'current', ?4)",
        )
        .bind(&device_id)
        .bind(new.secret_hash)
        .bind(&user_id)
        .bind(new.now)
        .execute(&mut *tx)
        .await?;
        let created = access_by_secret_in(&mut tx, new.secret_hash)
            .await?
            .ok_or(sqlx::Error::RowNotFound)?;
        tx.commit().await?;
        Ok(NewDeviceOutcome::Created(Box::new(created)))
    }

    /// Record authenticated use, at most one write per day.
    pub async fn touch_device(&self, device_id: &str, now: i64) -> Result<()> {
        sqlx::query(
            "UPDATE devices SET last_active_day = ?2 WHERE id = ?1 AND last_active_day < ?2",
        )
        .bind(device_id)
        .bind(day_of(now))
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Mark a device activated, idempotently, binding an optional hint and
    /// cancelling its own recovery requests. Returns when it was first
    /// activated.
    pub async fn activate_device(
        &self,
        device_id: &str,
        generation: i64,
        hardware: Option<HardwareBinding<'_>>,
        now: i64,
    ) -> Result<i64> {
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let device = device_in(&mut tx, device_id)
            .await?
            .ok_or(Refusal::SessionStale)?;
        if device.session_generation != generation {
            return Err(Refusal::SessionStale.into());
        }
        if let Some(operation) = &device.pending_transition_id {
            return Err(Refusal::TransitionPending {
                operation_id: Some(operation.clone()),
            }
            .into());
        }
        let activated_at = device.activated_at.unwrap_or(now);
        sqlx::query("UPDATE devices SET activated_at = ?2 WHERE id = ?1")
            .bind(device_id)
            .bind(activated_at)
            .execute(&mut *tx)
            .await?;
        if let Some(binding) = hardware {
            bind_hardware_in(&mut tx, device_id, binding).await?;
        }
        sqlx::query(
            "UPDATE pair_restore_requests SET state = 'stale', updated_at = ?2
             WHERE requester_device_id = ?1 AND state IN ('pending', 'approved')",
        )
        .bind(device_id)
        .bind(now)
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(activated_at)
    }

    /// Rename a device in the caller's current user.
    pub async fn rename_device(
        &self,
        caller_user: &str,
        device_id: &str,
        label: &str,
    ) -> Result<()> {
        let result = sqlx::query("UPDATE devices SET label = ?3 WHERE id = ?2 AND user_id = ?1")
            .bind(caller_user)
            .bind(device_id)
            .bind(label)
            .execute(&self.pool)
            .await?;
        if result.rows_affected() == 0 {
            return Err(Refusal::NotFound.into());
        }
        Ok(())
    }

    /// One page of a user's devices, in joined order. The cursor is the last
    /// device id of the previous page.
    pub async fn group_devices(
        &self,
        user_id: &str,
        after: Option<&str>,
        limit: i64,
    ) -> Result<Vec<Device>> {
        let devices = sqlx::query_as::<_, Device>(sqlx::AssertSqlSafe(format!(
            "SELECT {DEVICE_COLUMNS} FROM devices WHERE user_id = ?1 AND id > COALESCE(?2, '')
             ORDER BY id LIMIT ?3"
        )))
        .bind(user_id)
        .bind(after)
        .bind(limit)
        .fetch_all(&self.pool)
        .await?;
        Ok(devices)
    }

    /// A device, if it exists.
    pub async fn pairing_device(&self, device_id: &str) -> Result<Option<Device>> {
        let mut conn = self.pool.acquire().await?;
        device_in(&mut conn, device_id).await
    }

    /// How many devices a user has.
    pub async fn group_size(&self, user_id: &str) -> Result<i64> {
        let mut conn = self.pool.acquire().await?;
        group_size_in(&mut conn, user_id).await
    }

    /// A user's relay namespace in canonical decimal, if allocated.
    pub async fn user_namespace(&self, user_id: &str) -> Result<Option<String>> {
        let mut conn = self.pool.acquire().await?;
        Ok(user_in(&mut conn, user_id)
            .await?
            .and_then(|user| user.namespace))
    }

    /// Whether any pairing state exists, which makes a pairing key change
    /// unsafe.
    pub async fn has_pairing_state(&self) -> Result<bool> {
        let (count,): (i64,) = sqlx::query_as(
            "SELECT (SELECT COUNT(*) FROM devices) + (SELECT COUNT(*) FROM retired_codes)",
        )
        .fetch_one(&self.pool)
        .await?;
        Ok(count > 0)
    }

    /// Read a value from `pairing_metadata`.
    pub async fn pairing_metadata(&self, key: &str) -> Result<Option<Vec<u8>>> {
        let row: Option<(Vec<u8>,)> =
            sqlx::query_as("SELECT value FROM pairing_metadata WHERE key = ?1")
                .bind(key)
                .fetch_optional(&self.pool)
                .await?;
        Ok(row.map(|(value,)| value))
    }

    /// Record a value in `pairing_metadata`.
    pub async fn set_pairing_metadata(&self, key: &str, value: &[u8]) -> Result<()> {
        sqlx::query(
            "INSERT INTO pairing_metadata (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        )
        .bind(key)
        .bind(value)
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}
