//! Pairing codes: lookups, rotation and pause. Plaintext codes are never
//! stored; the caller derives them from the device id and generation.

use sqlx::SqliteConnection;

use super::devices::device_in;
use super::models::{Device, OperationKind};
use super::prepare::{existing_operation, insert_terminal_operation, OperationMeta};
use super::refusal::Refusal;
use crate::{Result, Store};

/// Seconds a code must live before it may be rotated.
pub const CODE_ROTATION_WAIT_SECS: i64 = 24 * 3600;

/// What a code lookup found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodeResolution {
    /// The device currently holding this code.
    Active(Box<Device>),
    /// This code was rotated away.
    Retired,
    /// No device holds it.
    Unknown,
}

/// What rotating a code needs.
#[derive(Debug, Clone, Copy)]
pub struct RotateInput<'a> {
    /// The idempotent operation.
    pub meta: OperationMeta<'a>,
    /// The caller's session generation.
    pub generation: i64,
}

/// The first code generation at or after `from` whose lookup collides with no
/// active or retained retired code, and that lookup.
pub(super) async fn next_free_code(
    conn: &mut SqliteConnection,
    device_id: &str,
    from: i64,
    derive_lookup: &(dyn Fn(&str, i64) -> Vec<u8> + Send + Sync),
) -> Result<(i64, Vec<u8>)> {
    let mut generation = from;
    loop {
        let lookup = derive_lookup(device_id, generation);
        let (taken,): (i64,) = sqlx::query_as(
            "SELECT (SELECT COUNT(*) FROM devices WHERE code_lookup = ?1)
                  + (SELECT COUNT(*) FROM retired_codes WHERE code_lookup = ?1)",
        )
        .bind(&lookup)
        .fetch_one(&mut *conn)
        .await?;
        if taken == 0 {
            return Ok((generation, lookup));
        }
        generation += 1;
    }
}

/// Retire `device`'s code and move it to the next free generation, recording
/// server time. The whole change is one step of the caller's transaction.
pub(super) async fn rotate_code_in(
    conn: &mut SqliteConnection,
    device: &Device,
    now: i64,
    derive_lookup: &(dyn Fn(&str, i64) -> Vec<u8> + Send + Sync),
) -> Result<()> {
    sqlx::query("INSERT OR REPLACE INTO retired_codes (code_lookup, retired_at) VALUES (?1, ?2)")
        .bind(&device.code_lookup)
        .bind(now)
        .execute(&mut *conn)
        .await?;
    let (generation, lookup) =
        next_free_code(conn, &device.id, device.code_generation + 1, derive_lookup).await?;
    sqlx::query(
        "UPDATE devices SET code_generation = ?2, code_lookup = ?3, code_issued_at = ?4
         WHERE id = ?1",
    )
    .bind(&device.id)
    .bind(generation)
    .bind(&lookup)
    .bind(now)
    .execute(&mut *conn)
    .await?;
    Ok(())
}

impl Store {
    /// Find what a code's lookup refers to.
    pub async fn resolve_code(&self, lookup: &[u8]) -> Result<CodeResolution> {
        let mut conn = self.pool.acquire().await?;
        let holder: Option<(String,)> =
            sqlx::query_as("SELECT id FROM devices WHERE code_lookup = ?1")
                .bind(lookup)
                .fetch_optional(&mut *conn)
                .await?;
        if let Some((id,)) = holder {
            if let Some(device) = device_in(&mut conn, &id).await? {
                return Ok(CodeResolution::Active(Box::new(device)));
            }
        }
        let (retired,): (i64,) =
            sqlx::query_as("SELECT COUNT(*) FROM retired_codes WHERE code_lookup = ?1")
                .bind(lookup)
                .fetch_one(&mut *conn)
                .await?;
        Ok(if retired > 0 { CodeResolution::Retired } else { CodeResolution::Unknown })
    }

    /// Rotate the caller's code once its wait is over.
    ///
    /// A retry of the same operation returns without rotating again. Rotation
    /// retires the old lookup, advances the generation and records server time
    /// atomically, which also invalidates every preview ticket for the old
    /// code.
    pub async fn rotate_code(
        &self,
        input: RotateInput<'_>,
        derive_lookup: &(dyn Fn(&str, i64) -> Vec<u8> + Send + Sync),
    ) -> Result<()> {
        let meta = input.meta;
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        if existing_operation(&mut tx, meta.id, meta.fingerprint)
            .await?
            .is_some()
        {
            return Ok(());
        }
        let device = device_in(&mut tx, meta.actor_device_id)
            .await?
            .ok_or(Refusal::SessionStale)?;
        if device.session_generation != input.generation {
            return Err(Refusal::SessionStale.into());
        }
        if let Some(operation) = &device.pending_transition_id {
            return Err(Refusal::TransitionPending {
                operation_id: Some(operation.clone()),
            }
            .into());
        }
        let ready_at = device.code_issued_at + CODE_ROTATION_WAIT_SECS;
        if meta.now < ready_at {
            return Err(Refusal::TooSoon {
                retry_after: u64::try_from(ready_at - meta.now).unwrap_or(1),
            }
            .into());
        }
        rotate_code_in(&mut tx, &device, meta.now, derive_lookup).await?;
        insert_terminal_operation(&mut tx, meta, OperationKind::Rotate, &device).await?;
        tx.commit().await?;
        Ok(())
    }

    /// Set a code's pause state explicitly.
    pub async fn set_code_paused(&self, device_id: &str, paused: bool) -> Result<()> {
        sqlx::query("UPDATE devices SET code_paused = ?2 WHERE id = ?1")
            .bind(device_id)
            .bind(paused)
            .execute(&self.pool)
            .await?;
        Ok(())
    }
}
