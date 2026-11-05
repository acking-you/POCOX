//! What a pairing call can fail with, in a form callers can match on.

use pocox_account_proto::pairing::{PairingErrorBody, PairingErrorCode};

/// The backend refused a pairing request. Match on [`Self::code`], never on
/// prose. Carried inside `anyhow::Error`; see [`code_of`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingError {
    /// The stable reason.
    pub code: PairingErrorCode,
    /// The HTTP status it came with.
    pub status: u16,
    /// Seconds to wait, from the body or `Retry-After`.
    pub retry_after: Option<u64>,
    /// The pending operation this waits on, when it is the caller's own.
    pub operation_id: Option<String>,
    /// For a superseded secret, when its overlap ends (unix seconds).
    pub grace_deadline: Option<i64>,
}

impl PairingError {
    /// The error a refusal's body describes.
    pub(super) fn from_body(
        status: u16,
        body: PairingErrorBody,
        retry_header: Option<u64>,
    ) -> Self {
        Self {
            code: body.error,
            status,
            retry_after: body.retry_after.or(retry_header),
            operation_id: body.operation_id,
            grace_deadline: body.grace_deadline,
        }
    }
}

impl std::fmt::Display for PairingError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "the backend refused this: {}", self.code.as_str())?;
        if let Some(seconds) = self.retry_after {
            write!(f, " (retry in {seconds} s)")?;
        }
        Ok(())
    }
}

impl std::error::Error for PairingError {}

/// `error`'s pairing code, wherever in its chain it is.
pub fn code_of(error: &anyhow::Error) -> Option<PairingErrorCode> {
    error
        .chain()
        .find_map(|cause| cause.downcast_ref::<PairingError>())
        .map(|refusal| refusal.code)
}

/// This installation holds a pairing session with no device store behind it, as
/// after restoring `config.toml` from a backup. That means signed out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SignedOut;

impl std::fmt::Display for SignedOut {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("not signed in: this device has no saved pairing identity")
    }
}

impl std::error::Error for SignedOut {}

/// [`SignedOut`] as the error callers carry.
pub fn signed_out_error() -> anyhow::Error {
    SignedOut.into()
}
