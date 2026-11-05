//! Backend-wide admission budgets, shared by every process using this database.

use sqlx::SqliteConnection;

use crate::{Result, Store};

/// The answer to charging a budget.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BudgetVerdict {
    /// Charged.
    Admitted,
    /// Exhausted until the window ends.
    Refused {
        /// Seconds until the next window.
        retry_after: u64,
    },
}

/// Atomically charge one unit against a fixed-window budget, as one step of
/// whatever the connection is doing.
///
/// One statement, so concurrent callers cannot outrun the limit, and a refused
/// charge leaves the counter capped. Only a newer window resets it: a charge
/// carrying an older time, from a request that waited or a clock that stepped
/// back, counts against the window in progress.
pub(super) async fn charge_budget_in(
    conn: &mut SqliteConnection,
    name: &str,
    window_secs: i64,
    limit: i64,
    now: i64,
) -> Result<BudgetVerdict> {
    let window_start = now - now.rem_euclid(window_secs);
    let (used,): (i64,) = sqlx::query_as(
        "INSERT INTO pairing_budgets (name, window_start, used) VALUES (?1, ?2, 1)
         ON CONFLICT(name) DO UPDATE SET
             used = CASE WHEN ?2 > window_start THEN 1 ELSE MIN(used + 1, ?3 + 1) END,
             window_start = MAX(window_start, ?2)
         RETURNING used",
    )
    .bind(name)
    .bind(window_start)
    .bind(limit)
    .fetch_one(&mut *conn)
    .await?;
    if used > limit {
        let retry_after = (window_start + window_secs - now).max(1);
        return Ok(BudgetVerdict::Refused {
            retry_after: u64::try_from(retry_after).unwrap_or(1),
        });
    }
    Ok(BudgetVerdict::Admitted)
}

impl Store {
    /// Atomically charge one unit against a fixed-window budget.
    pub async fn charge_budget(
        &self,
        name: &str,
        window_secs: i64,
        limit: i64,
        now: i64,
    ) -> Result<BudgetVerdict> {
        let mut conn = self.pool.acquire().await?;
        charge_budget_in(&mut conn, name, window_secs, limit, now).await
    }

    /// Give one unit back to the current window, for a charge whose work was
    /// refused before it cost anything.
    pub async fn refund_budget(&self, name: &str, window_secs: i64, now: i64) -> Result<()> {
        let window_start = now - now.rem_euclid(window_secs);
        sqlx::query(
            "UPDATE pairing_budgets SET used = MAX(used - 1, 0) WHERE name = ?1 AND window_start \
             = ?2",
        )
        .bind(name)
        .bind(window_start)
        .execute(&self.pool)
        .await?;
        Ok(())
    }
}
