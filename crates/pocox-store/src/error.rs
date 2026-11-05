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
    /// The database's owner lock could not be taken or created.
    #[error("locking {path}: {source}")]
    DatabaseLock {
        /// The lock file.
        path: String,
        /// Why.
        source: std::io::Error,
    },
    /// Another process is already serving this database.
    #[error("another process holds {path}; one process serves a pairing database")]
    DatabaseInUse {
        /// The lock file.
        path: String,
    },
    /// A pairing compare-and-set refused the change.
    #[error("refused: {0}")]
    Refused(#[from] crate::pairing::Refusal),
}

/// Convenience result alias for the store.
pub type Result<T> = std::result::Result<T, StoreError>;
