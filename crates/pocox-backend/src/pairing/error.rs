//! A refused pairing request, as HTTP.

use axum::http::header::RETRY_AFTER;
use axum::http::{HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use pocox_account_proto::pairing::{PairingErrorBody, PairingErrorCode};
use pocox_auth::AuthError;
use pocox_store::{Refusal, StoreError};

/// A pairing request's failure: a stable code, or an internal error whose
/// detail stays in the log.
#[derive(Debug)]
pub enum PairingError {
    /// Refused with a stable code.
    Refused(PairingErrorBody),
    /// Something unexpected. Logged, never echoed.
    Internal(String),
}

impl PairingError {
    /// A bare refusal.
    pub fn code(error: PairingErrorCode) -> Self {
        Self::Refused(PairingErrorBody {
            error,
            retry_after: None,
            operation_id: None,
            grace_deadline: None,
        })
    }

    /// A refusal that tells the client when to come back.
    pub fn retry_later(error: PairingErrorCode, retry_after: u64) -> Self {
        Self::Refused(PairingErrorBody {
            error,
            retry_after: Some(retry_after),
            operation_id: None,
            grace_deadline: None,
        })
    }

    /// Something unexpected.
    pub fn internal(detail: impl std::fmt::Display) -> Self {
        Self::Internal(detail.to_string())
    }

    /// The stable code, if this is a refusal.
    pub fn refusal_code(&self) -> Option<PairingErrorCode> {
        match self {
            Self::Refused(body) => Some(body.error),
            Self::Internal(_) => None,
        }
    }
}

fn status_of(code: PairingErrorCode) -> StatusCode {
    use PairingErrorCode as Code;
    match code {
        Code::PairingClientUpgradeRequired => StatusCode::UPGRADE_REQUIRED,
        Code::PairingDisabled
        | Code::RelayTooOld
        | Code::RelayCapacity
        | Code::RelayUnavailable
        | Code::RelayStateLost => StatusCode::SERVICE_UNAVAILABLE,
        Code::InvalidRequest => StatusCode::BAD_REQUEST,
        Code::DeviceSuperseded | Code::DeviceUnknown | Code::SessionStale => {
            StatusCode::UNAUTHORIZED
        },
        Code::DeviceSessionRequired
        | Code::GraceRestricted
        | Code::DeviceNotActivated
        | Code::LinkingPaused => StatusCode::FORBIDDEN,
        Code::RetiringKeyGone | Code::CodeRetired => StatusCode::GONE,
        Code::OperationUnknown | Code::CodeUnknown | Code::NotFound => StatusCode::NOT_FOUND,
        Code::TransitionPending
        | Code::OperationConflict
        | Code::OwnCode
        | Code::PreviewStale
        | Code::Stale
        | Code::AlreadyLinked
        | Code::GroupFull => StatusCode::CONFLICT,
        Code::RestoreSlotsFull | Code::RateLimited => StatusCode::TOO_MANY_REQUESTS,
        Code::Unknown => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

impl IntoResponse for PairingError {
    fn into_response(self) -> Response {
        match self {
            Self::Refused(body) => {
                let status = status_of(body.error);
                let retry_after = body.retry_after;
                let mut response = (status, Json(body)).into_response();
                if let Some(seconds) = retry_after {
                    if let Ok(value) = HeaderValue::from_str(&seconds.to_string()) {
                        response.headers_mut().insert(RETRY_AFTER, value);
                    }
                }
                response
            },
            Self::Internal(detail) => {
                tracing::error!(error = %detail, "pairing request failed");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(serde_json::json!({ "error": "internal error" })),
                )
                    .into_response()
            },
        }
    }
}

impl From<Refusal> for PairingError {
    fn from(refusal: Refusal) -> Self {
        use PairingErrorCode as Code;
        match refusal {
            Refusal::TransitionPending {
                operation_id,
            } => Self::Refused(PairingErrorBody {
                error: Code::TransitionPending,
                retry_after: Some(5),
                operation_id,
                grace_deadline: None,
            }),
            Refusal::PreviewStale => Self::code(Code::PreviewStale),
            Refusal::Stale => Self::code(Code::Stale),
            Refusal::AlreadyLinked => Self::code(Code::AlreadyLinked),
            Refusal::GroupFull => Self::code(Code::GroupFull),
            Refusal::OperationConflict => Self::code(Code::OperationConflict),
            Refusal::SessionStale => Self::code(Code::SessionStale),
            Refusal::NotFound => Self::code(Code::NotFound),
            Refusal::SlotsFull => Self::code(Code::RestoreSlotsFull),
            Refusal::NotActivated => Self::code(Code::DeviceNotActivated),
            Refusal::CapacityFull => Self::retry_later(Code::RelayCapacity, 300),
            Refusal::TooSoon {
                retry_after,
            } => Self::retry_later(Code::RateLimited, retry_after),
        }
    }
}

impl From<StoreError> for PairingError {
    fn from(error: StoreError) -> Self {
        match error {
            StoreError::Refused(refusal) => refusal.into(),
            other => Self::internal(other),
        }
    }
}

impl From<AuthError> for PairingError {
    fn from(error: AuthError) -> Self {
        use PairingErrorCode as Code;
        match error {
            AuthError::PairingDisabled => Self::code(Code::PairingDisabled),
            AuthError::DeviceUnknown => Self::code(Code::DeviceUnknown),
            AuthError::DeviceSuperseded {
                grace_deadline,
            } => Self::Refused(PairingErrorBody {
                error: Code::DeviceSuperseded,
                retry_after: None,
                operation_id: None,
                grace_deadline,
            }),
            AuthError::SessionStale | AuthError::Jwt(_) => Self::code(Code::SessionStale),
            AuthError::BadPrincipal => Self::code(Code::DeviceSessionRequired),
            AuthError::TransitionPending {
                operation_id,
            } => Refusal::TransitionPending {
                operation_id,
            }
            .into(),
            AuthError::Store(store) => store.into(),
            other => Self::internal(other),
        }
    }
}

/// A pairing route's result.
pub type PairingResult<T> = Result<T, PairingError>;
