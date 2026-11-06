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
    /// The answer was a bare status with no refusal body: an old backend, or a
    /// proxy in front of one that might have taken the request. Shown by its
    /// code, but never a definite refusal, so waits keep asking.
    pub bare_status: bool,
}

impl PairingError {
    /// Whether the backend clearly refused, so what was asked did not happen. A
    /// server failure or a code this client does not know says nothing either
    /// way: only reading the result can.
    pub fn is_definite(&self) -> bool {
        !self.bare_status
            && (400..500).contains(&self.status)
            && self.code != PairingErrorCode::Unknown
    }

    /// A backend from before pairing, which has no pairing routes: it cannot
    /// pair here, which is not the same as being unreachable.
    pub(super) fn without_pairing(status: u16) -> Self {
        Self {
            code: PairingErrorCode::PairingDisabled,
            status,
            retry_after: None,
            operation_id: None,
            grace_deadline: None,
            bare_status: true,
        }
    }

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
            bare_status: false,
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

/// The refusal in `error`'s chain, if the backend answered with one.
pub(super) fn refusal_of(error: &anyhow::Error) -> Option<&PairingError> {
    error
        .chain()
        .find_map(|cause| cause.downcast_ref::<PairingError>())
}

/// Whether `error` says the backend clearly refused, rather than that no usable
/// answer arrived.
pub(super) fn is_definite_refusal(error: &anyhow::Error) -> bool {
    refusal_of(error).is_some_and(PairingError::is_definite)
}

/// This backend has no identity for this device here. Only preparing,
/// activating, previewing a code or asking to recover may start one: pausing or
/// removing anything on a device that does not exist would report a success
/// that did nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NoDevice;

impl std::fmt::Display for NoDevice {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("this device has no pairing identity on this backend")
    }
}

impl std::error::Error for NoDevice {}

/// [`NoDevice`] as the error callers carry.
pub(super) fn no_device_error() -> anyhow::Error {
    NoDevice.into()
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
