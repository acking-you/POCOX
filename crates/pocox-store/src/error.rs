//! Store error type.

/// Errors from the persistence layer.
#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    /// A database query or connection failed.
    #[error("database: {0}")]
    Db(#[from] sqlx::Error),
    /// Applying the embedded migrations failed.
    #[error("migration: {0}")]
    Migrate(#[from] sqlx::migrate::MigrateError),
    /// A pairing compare-and-set refused the change.
    #[error("refused: {0}")]
    Refused(#[from] crate::pairing::Refusal),
}

/// Convenience result alias for the store.
pub type Result<T> = std::result::Result<T, StoreError>;
