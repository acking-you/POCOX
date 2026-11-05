//! Retention: what pairing data is kept, and for how long.
//!
//! Purging follows the revocation and transition boundary. A device, user or
//! operation with an unresolved transition or a key that may still authenticate
//! stays, whatever its age.

use crate::{Result, Store};

const DAY: i64 = 24 * 3600;
/// An activated device lives this long without authenticated use or renewal.
const ACTIVATED_RETENTION_SECS: i64 = 180 * DAY;
/// A never-activated device lives this long after creation.
const UNACTIVATED_RETENTION_SECS: i64 = 30 * DAY;
/// Superseded sessions, finished operations, retired codes and terminal
/// requests.
const DIAGNOSTIC_RETENTION_SECS: i64 = 7 * DAY;
/// A dead key's row, past the relay reclaiming its slot.
const DEAD_KEY_RETENTION_SECS: i64 = 3600;

/// How many rows one purge removed.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PurgeCounts {
    /// Devices deleted.
    pub devices: u64,
    /// Users deleted.
    pub users: u64,
    /// Finished operations deleted.
    pub operations: u64,
}

impl Store {
    /// Remove what retention no longer requires.
    pub async fn purge_pairing(&self, now: i64) -> Result<PurgeCounts> {
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        sqlx::query(
            "UPDATE pair_restore_requests SET state = 'expired', updated_at = ?1
             WHERE (state = 'pending' AND expires_at <= ?1)
                OR (state = 'approved' AND approval_expires_at <= ?1)",
        )
        .bind(now)
        .execute(&mut *tx)
        .await?;
        sqlx::query(
            "DELETE FROM pair_restore_requests
             WHERE state NOT IN ('pending', 'approved') AND updated_at <= ?1",
        )
        .bind(now - DIAGNOSTIC_RETENTION_SECS)
        .execute(&mut *tx)
        .await?;
        // A device's age for retention: last use once activated, otherwise the
        // moment it entered its current user, which a peer linking in never moves.
        let doomed: Vec<(String, String)> = sqlx::query_as(
            "SELECT id, user_id FROM devices d
             WHERE pending_transition_id IS NULL
             AND ((activated_at IS NOT NULL AND last_active_day * 86400 <= ?1)
               OR (activated_at IS NULL AND joined_at <= ?2))
             AND NOT EXISTS (SELECT 1 FROM device_relay_keys k
                 WHERE k.device_id = d.id AND k.state IN ('granting', 'active'))
             AND NOT EXISTS (SELECT 1 FROM pair_operations o
                 WHERE o.state IN ('prepared', 'relay_applied')
                 AND (o.subject_device_id = d.id OR o.actor_device_id = d.id
                      OR o.code_device_id = d.id))",
        )
        .bind(now - ACTIVATED_RETENTION_SECS)
        .bind(now - UNACTIVATED_RETENTION_SECS)
        .fetch_all(&mut *tx)
        .await?;
        let mut counts = PurgeCounts::default();
        for (device_id, user_id) in doomed {
            sqlx::query("DELETE FROM devices WHERE id = ?1")
                .bind(&device_id)
                .execute(&mut *tx)
                .await?;
            sqlx::query(
                "UPDATE device_users SET membership_revision = membership_revision + 1 WHERE id = \
                 ?1",
            )
            .bind(&user_id)
            .execute(&mut *tx)
            .await?;
            counts.devices += 1;
        }
        sqlx::query(
            "DELETE FROM device_sessions WHERE state != 'current' AND retired_at <= ?1
             AND (grace_deadline IS NULL OR grace_deadline <= ?1)",
        )
        .bind(now - DIAGNOSTIC_RETENTION_SECS)
        .execute(&mut *tx)
        .await?;
        counts.operations = sqlx::query(
            "DELETE FROM pair_operations
             WHERE state IN ('committed', 'failed') AND completed_at <= ?1",
        )
        .bind(now - DIAGNOSTIC_RETENTION_SECS)
        .execute(&mut *tx)
        .await?
        .rows_affected();
        sqlx::query("DELETE FROM retired_codes WHERE retired_at <= ?1")
            .bind(now - DIAGNOSTIC_RETENTION_SECS)
            .execute(&mut *tx)
            .await?;
        sqlx::query(
            "DELETE FROM device_relay_keys WHERE state NOT IN ('granting', 'active')
             AND ended_at <= ?1
             AND NOT EXISTS (SELECT 1 FROM pair_operations o
                 WHERE o.state IN ('prepared', 'relay_applied')
                 AND o.subject_device_id = device_relay_keys.device_id)",
        )
        .bind(now - DEAD_KEY_RETENTION_SECS)
        .execute(&mut *tx)
        .await?;
        // A user goes last, once no device, open operation or live key refers to it.
        // The relay does not hand its number out again, and the unique index catches
        // a relay that lost its state and does.
        counts.users = sqlx::query(
            "DELETE FROM device_users WHERE id NOT IN (SELECT user_id FROM devices)
             AND id NOT IN (SELECT user_id FROM device_relay_keys
                 WHERE state IN ('granting', 'active'))
             AND id NOT IN (SELECT source_user_id FROM pair_operations
                 WHERE state IN ('prepared', 'relay_applied'))
             AND id NOT IN (SELECT destination_user_id FROM pair_operations
                 WHERE state IN ('prepared', 'relay_applied')
                 AND destination_user_id IS NOT NULL)",
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();
        tx.commit().await?;
        Ok(counts)
    }
}
