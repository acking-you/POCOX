//! Relay key bookkeeping: namespaces and one grant per device generation.
//!
//! A grant is persisted before the relay is called, under a label that names
//! it, so a lost response is found again rather than minted twice. Every key id
//! is persisted before any client sees the credential.

use super::devices::device_in;
use super::models::{KeyState, RelayKeyRow};
use super::refusal::Refusal;
use crate::{Result, Store, StoreError};

const KEY_COLUMNS: &str = "grant_id, device_id, generation, user_id, namespace, relay_instance, \
                           label, key_id, expires_at, local_end, hard_cutoff, cutoff_pending, \
                           state, created_at, updated_at, ended_at";

/// How long a dead key still occupies a relay slot, plus a margin: the relay
/// reclaims a tombstone after 60 seconds.
const TOMBSTONE_MARGIN_SECS: i64 = 120;

/// Counts the relay slots pairing keys occupy: live ones, plus dead ones the
/// relay has not reclaimed yet.
const COUNT_KEY_SLOTS: &str = "SELECT COUNT(*) FROM device_relay_keys
     WHERE state IN ('granting', 'active') OR ended_at > ?1";

/// The result of recording a relay namespace for a user.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NamespaceClaim {
    /// The user's namespace, which is fixed once set.
    Fixed(String),
    /// Another user already holds this number: the relay repeated it.
    Repeated,
}

/// What opening a grant needs.
#[derive(Debug, Clone, Copy)]
pub struct NewGrant<'a> {
    /// The grant operation's id, named in the label.
    pub grant_id: &'a str,
    /// The device.
    pub device_id: &'a str,
    /// The session generation it is for.
    pub generation: i64,
    /// The device's current user.
    pub user_id: &'a str,
    /// That user's namespace.
    pub namespace: &'a str,
    /// The relay instance about to be asked.
    pub relay_instance: &'a str,
    /// The exact label to issue with.
    pub label: &'a str,
    /// Relay slots pairing keys may occupy.
    pub slot_limit: i64,
    /// The current time.
    pub now: i64,
}

/// The relay's answer about one key.
#[derive(Debug, Clone, Copy)]
pub struct KeyAnswer<'a> {
    /// The relay's key id, in canonical decimal.
    pub key_id: &'a str,
    /// Expiry in the relay's clock.
    pub expires_at: i64,
    /// The same moment in the backend's clock.
    pub local_end: i64,
    /// The current time.
    pub now: i64,
}

/// Whether a credential the relay just answered with may reach the client.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GrantFate {
    /// The generation is still current and nothing is moving the device.
    Expose,
    /// A transition began meanwhile: the key is on record for it to deal with,
    /// and the client gets nothing.
    Withhold,
}

fn is_unique_violation(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .is_some_and(|database| database.is_unique_violation())
}

impl Store {
    /// Fix a user's namespace if none is set yet.
    ///
    /// Safe under concurrent first-key requests: the first writer wins and the
    /// others read its number back, wasting theirs.
    pub async fn claim_namespace(&self, user_id: &str, namespace: &str) -> Result<NamespaceClaim> {
        let updated = sqlx::query(
            "UPDATE device_users SET namespace = ?2 WHERE id = ?1 AND namespace IS NULL",
        )
        .bind(user_id)
        .bind(namespace)
        .execute(&self.pool)
        .await;
        match updated {
            Ok(result) if result.rows_affected() == 1 => {
                Ok(NamespaceClaim::Fixed(namespace.to_string()))
            },
            Ok(_) => {
                let current = self.user_namespace(user_id).await?;
                Ok(NamespaceClaim::Fixed(current.ok_or(sqlx::Error::RowNotFound)?))
            },
            Err(error) if is_unique_violation(&error) => Ok(NamespaceClaim::Repeated),
            Err(error) => Err(StoreError::Db(error)),
        }
    }

    /// Persist a grant before calling the relay.
    ///
    /// Refuses unless the generation is current, the device is activated and no
    /// transition is under way, which serializes issuance against transitions.
    /// The slot is counted and taken in this one transaction, so a burst
    /// cannot pass the share.
    pub async fn open_grant(&self, grant: NewGrant<'_>) -> Result<RelayKeyRow> {
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let device = device_in(&mut tx, grant.device_id)
            .await?
            .ok_or(Refusal::SessionStale)?;
        if device.session_generation != grant.generation || device.user_id != grant.user_id {
            return Err(Refusal::SessionStale.into());
        }
        if device.pending_transition_id.is_some() {
            return Err(Refusal::TransitionPending {
                operation_id: None,
            }
            .into());
        }
        if device.activated_at.is_none() {
            return Err(Refusal::NotActivated.into());
        }
        let (slots,): (i64,) = sqlx::query_as(COUNT_KEY_SLOTS)
            .bind(grant.now - TOMBSTONE_MARGIN_SECS)
            .fetch_one(&mut *tx)
            .await?;
        if slots >= grant.slot_limit {
            return Err(Refusal::CapacityFull.into());
        }
        let inserted = sqlx::query(
            "INSERT INTO device_relay_keys (grant_id, device_id, generation, user_id, namespace, \
             relay_instance, label, state, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, \
             ?6, ?7, 'granting', ?8, ?8)",
        )
        .bind(grant.grant_id)
        .bind(grant.device_id)
        .bind(grant.generation)
        .bind(grant.user_id)
        .bind(grant.namespace)
        .bind(grant.relay_instance)
        .bind(grant.label)
        .bind(grant.now)
        .execute(&mut *tx)
        .await;
        match inserted {
            Ok(_) => {},
            // Another request already holds this generation's one open grant.
            Err(error) if is_unique_violation(&error) => {
                return Err(Refusal::TransitionPending {
                    operation_id: None,
                }
                .into());
            },
            Err(error) => return Err(StoreError::Db(error)),
        }
        let row = sqlx::query_as::<_, RelayKeyRow>(sqlx::AssertSqlSafe(format!(
            "SELECT {KEY_COLUMNS} FROM device_relay_keys WHERE grant_id = ?1"
        )))
        .bind(grant.grant_id)
        .fetch_one(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(row)
    }

    /// Record the relay's answer to a grant or renewal, then decide whether the
    /// credential may be exposed. The key id is on record either way.
    pub async fn record_key(&self, grant_id: &str, answer: KeyAnswer<'_>) -> Result<GrantFate> {
        let mut tx = self.pool.begin_with("BEGIN IMMEDIATE").await?;
        let row = sqlx::query_as::<_, RelayKeyRow>(sqlx::AssertSqlSafe(format!(
            "SELECT {KEY_COLUMNS} FROM device_relay_keys WHERE grant_id = ?1"
        )))
        .bind(grant_id)
        .fetch_optional(&mut *tx)
        .await?
        .ok_or(sqlx::Error::RowNotFound)?;
        sqlx::query(
            "UPDATE device_relay_keys SET key_id = ?2, expires_at = ?3, local_end = ?4, state = \
             'active', updated_at = ?5 WHERE grant_id = ?1",
        )
        .bind(grant_id)
        .bind(answer.key_id)
        .bind(answer.expires_at)
        .bind(answer.local_end)
        .bind(answer.now)
        .execute(&mut *tx)
        .await?;
        let fate = match device_in(&mut tx, &row.device_id).await? {
            Some(device)
                if device.session_generation == row.generation
                    && device.user_id == row.user_id
                    && device.pending_transition_id.is_none() =>
            {
                sqlx::query(
                    "UPDATE devices SET first_key_at = COALESCE(first_key_at, ?2) WHERE id = ?1",
                )
                .bind(&row.device_id)
                .bind(answer.now)
                .execute(&mut *tx)
                .await?;
                GrantFate::Expose
            },
            _ => GrantFate::Withhold,
        };
        tx.commit().await?;
        Ok(fate)
    }

    /// Record the relay's confirmation that a retiring key ends by its cutoff.
    /// Nothing is owed on it any more.
    pub async fn record_cutoff_applied(&self, grant_id: &str, answer: KeyAnswer<'_>) -> Result<()> {
        sqlx::query(
            "UPDATE device_relay_keys SET key_id = ?2, expires_at = ?3, local_end = ?4, state = \
             'active', cutoff_pending = 0, updated_at = ?5 WHERE grant_id = ?1",
        )
        .bind(grant_id)
        .bind(answer.key_id)
        .bind(answer.expires_at)
        .bind(answer.local_end)
        .bind(answer.now)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Record that a key can no longer authenticate.
    pub async fn end_key(&self, grant_id: &str, state: KeyState, now: i64) -> Result<()> {
        sqlx::query(
            "UPDATE device_relay_keys SET state = ?2, cutoff_pending = 0, updated_at = ?3, \
             ended_at = ?3 WHERE grant_id = ?1 AND state IN ('granting', 'active')",
        )
        .bind(grant_id)
        .bind(state)
        .bind(now)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// Drop a grant the relay definitely never applied.
    pub async fn forget_grant(&self, grant_id: &str) -> Result<()> {
        sqlx::query("DELETE FROM device_relay_keys WHERE grant_id = ?1 AND state = 'granting'")
            .bind(grant_id)
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    /// The open key of one device generation, if any.
    pub async fn generation_key(
        &self,
        device_id: &str,
        generation: i64,
    ) -> Result<Option<RelayKeyRow>> {
        let row = sqlx::query_as::<_, RelayKeyRow>(sqlx::AssertSqlSafe(format!(
            "SELECT {KEY_COLUMNS} FROM device_relay_keys
             WHERE device_id = ?1 AND generation = ?2 AND state IN ('granting', 'active')"
        )))
        .bind(device_id)
        .bind(generation)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    /// Every key of a device that may still authenticate, up to and including
    /// `generation`. An operation covers no key newer than the generation it
    /// prepared.
    pub async fn device_open_keys(
        &self,
        device_id: &str,
        generation: i64,
    ) -> Result<Vec<RelayKeyRow>> {
        let rows = sqlx::query_as::<_, RelayKeyRow>(sqlx::AssertSqlSafe(format!(
            "SELECT {KEY_COLUMNS} FROM device_relay_keys
             WHERE device_id = ?1 AND generation <= ?2 AND state IN ('granting', 'active')"
        )))
        .bind(device_id)
        .bind(generation)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// Every key that may still authenticate, for reconciliation.
    pub async fn open_keys(&self) -> Result<Vec<RelayKeyRow>> {
        let rows = sqlx::query_as::<_, RelayKeyRow>(sqlx::AssertSqlSafe(format!(
            "SELECT {KEY_COLUMNS} FROM device_relay_keys WHERE state IN ('granting', 'active')"
        )))
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// Keys whose cutoff the relay has not confirmed and that no open operation
    /// is about to deal with: what a failed operation left behind.
    pub async fn keys_owing_cutoff(&self) -> Result<Vec<RelayKeyRow>> {
        let rows = sqlx::query_as::<_, RelayKeyRow>(sqlx::AssertSqlSafe(format!(
            "SELECT {KEY_COLUMNS} FROM device_relay_keys k
             WHERE cutoff_pending AND state IN ('granting', 'active')
             AND NOT EXISTS (SELECT 1 FROM pair_operations o
                 WHERE o.subject_device_id = k.device_id
                 AND o.state IN ('prepared', 'relay_applied'))"
        )))
        .fetch_all(&self.pool)
        .await?;
        Ok(rows)
    }

    /// A grant by id, in any state.
    pub async fn grant(&self, grant_id: &str) -> Result<Option<RelayKeyRow>> {
        let row = sqlx::query_as::<_, RelayKeyRow>(sqlx::AssertSqlSafe(format!(
            "SELECT {KEY_COLUMNS} FROM device_relay_keys WHERE grant_id = ?1"
        )))
        .bind(grant_id)
        .fetch_optional(&self.pool)
        .await?;
        Ok(row)
    }

    /// Relay slots pairing keys occupy: live ones, plus dead ones the relay has
    /// not reclaimed yet.
    pub async fn pairing_key_slots(&self, now: i64) -> Result<i64> {
        let (count,): (i64,) = sqlx::query_as(COUNT_KEY_SLOTS)
            .bind(now - TOMBSTONE_MARGIN_SECS)
            .fetch_one(&self.pool)
            .await?;
        Ok(count)
    }

    /// Whether this device has ever held a relay key.
    pub async fn device_had_key(&self, device_id: &str) -> Result<bool> {
        let (first, any): (Option<i64>, i64) = sqlx::query_as(
            "SELECT (SELECT first_key_at FROM devices WHERE id = ?1),
                    (SELECT COUNT(*) FROM device_relay_keys WHERE device_id = ?1)",
        )
        .bind(device_id)
        .fetch_one(&self.pool)
        .await?;
        Ok(first.is_some() || any > 0)
    }
}
