//! Crate-wide error type.

use thiserror::Error;

/// Convenience alias for `Result<T, Error>` used by this crate.
pub type Result<T> = std::result::Result<T, Error>;

/// Whether an error chain reports exhausted local file/socket descriptors.
/// A failed local probe in this state says nothing about the remote service.
pub fn is_file_limit(error: &(dyn std::error::Error + 'static)) -> bool {
    let mut current = Some(error);
    while let Some(error) = current {
        if let Some(io) = error.downcast_ref::<std::io::Error>() {
            #[cfg(unix)]
            if matches!(io.raw_os_error(), Some(code) if code == nix::libc::EMFILE || code == nix::libc::ENFILE)
            {
                return true;
            }
            #[cfg(windows)]
            if matches!(io.raw_os_error(), Some(4 | 10024)) {
                return true;
            }
        }
        current = error.source();
    }
    false
}

/// Credential-free description shared by network and process diagnostics.
pub const FILE_LIMIT_MESSAGE: &str = "This POCOX process has exhausted its file/socket handles; \
                                      close unused connections or restart POCOX, then retry.";

/// All errors surfaced by `pocket-codex-core`.
///
/// New variants should be added here rather than re-using
/// [`anyhow::Error`] so callers can pattern-match on failure modes.
#[derive(Debug, Error)]
pub enum Error {
    /// I/O failure while reading configuration or talking to the
    /// app-server.
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    /// JSON (de)serialisation failure when handling app-server messages.
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),

    /// TOML parsing/serialisation failure.
    #[error("toml deserialise error: {0}")]
    TomlDeserialize(#[from] toml::de::Error),

    /// TOML serialisation failure.
    #[error("toml serialise error: {0}")]
    TomlSerialize(#[from] toml::ser::Error),

    /// User-facing configuration error.
    #[error("config error: {0}")]
    Config(String),

    /// We could not determine a project path (e.g. no `$HOME`).
    #[error("path error: {0}")]
    Path(String),
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn file_limit_survives_context_without_matching_unrelated_errors() {
        let error = anyhow::Error::new(std::io::Error::from_raw_os_error(nix::libc::EMFILE))
            .context("opening a connection");
        assert!(is_file_limit(error.as_ref()));
        let refused = std::io::Error::from(std::io::ErrorKind::ConnectionRefused);
        assert!(!is_file_limit(&refused));
        assert!(!is_file_limit(anyhow::anyhow!("os error 24 in user content").as_ref()));
    }
}
