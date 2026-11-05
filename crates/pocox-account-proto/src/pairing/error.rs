//! Stable error codes on pairing routes.

use serde::{Deserialize, Serialize};

/// Why a pairing request was refused. The serialized name is the contract;
/// clients match on it and never on prose.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PairingErrorCode {
    /// `POCOX_PAIRING_SECRET` is unset on this backend.
    PairingDisabled,
    /// The client's pairing protocol is missing or unsupported.
    PairingClientUpgradeRequired,
    /// The relay cannot keep per-device keys in one namespace.
    RelayTooOld,
    /// Pairing keys reached their share of relay capacity.
    RelayCapacity,
    /// The relay could not be reached or did not answer.
    RelayUnavailable,
    /// The relay no longer knows this user's namespace. Nothing moves until an
    /// operator restores its state.
    RelayStateLost,
    /// The request is malformed.
    InvalidRequest,
    /// The route needs a device session, and a GitHub session is never
    /// converted.
    DeviceSessionRequired,
    /// This device secret was replaced. Offer recovery or starting as new.
    DeviceSuperseded,
    /// Nothing is known about this device secret.
    DeviceUnknown,
    /// The session's generation is no longer usable. Refresh with the secret.
    SessionStale,
    /// A retiring session may not use this route during its overlap.
    GraceRestricted,
    /// The device has not been activated, so it gets no relay key.
    DeviceNotActivated,
    /// A retiring session's relay key no longer exists, and none is minted for
    /// it.
    RetiringKeyGone,
    /// A membership change is in progress. Retry after it completes.
    TransitionPending,
    /// This operation id was already used with different input.
    OperationConflict,
    /// No such operation for this secret.
    OperationUnknown,
    /// No device holds this code.
    CodeUnknown,
    /// This code was replaced by a rotation.
    CodeRetired,
    /// This code is paused by its device.
    LinkingPaused,
    /// This is the caller's own code.
    OwnCode,
    /// What the user confirmed has changed. Preview again.
    PreviewStale,
    /// The caller no longer qualifies, or the request no longer applies.
    Stale,
    /// The caller has peers and did not confirm leaving them.
    AlreadyLinked,
    /// The target group is at its size limit.
    GroupFull,
    /// Nothing was found.
    NotFound,
    /// The target's approval slots are full. Entering a code still works.
    RestoreSlotsFull,
    /// Too many attempts. Honor `retry_after`.
    RateLimited,
    /// A code this client does not know, from a newer backend.
    #[serde(other)]
    Unknown,
}

impl PairingErrorCode {
    /// The name this code serializes to.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::PairingDisabled => "pairing_disabled",
            Self::PairingClientUpgradeRequired => "pairing_client_upgrade_required",
            Self::RelayTooOld => "relay_too_old",
            Self::RelayCapacity => "relay_capacity",
            Self::RelayUnavailable => "relay_unavailable",
            Self::RelayStateLost => "relay_state_lost",
            Self::InvalidRequest => "invalid_request",
            Self::DeviceSessionRequired => "device_session_required",
            Self::DeviceSuperseded => "device_superseded",
            Self::DeviceUnknown => "device_unknown",
            Self::SessionStale => "session_stale",
            Self::GraceRestricted => "grace_restricted",
            Self::DeviceNotActivated => "device_not_activated",
            Self::RetiringKeyGone => "retiring_key_gone",
            Self::TransitionPending => "transition_pending",
            Self::OperationConflict => "operation_conflict",
            Self::OperationUnknown => "operation_unknown",
            Self::CodeUnknown => "code_unknown",
            Self::CodeRetired => "code_retired",
            Self::LinkingPaused => "linking_paused",
            Self::OwnCode => "own_code",
            Self::PreviewStale => "preview_stale",
            Self::Stale => "stale",
            Self::AlreadyLinked => "already_linked",
            Self::GroupFull => "group_full",
            Self::NotFound => "not_found",
            Self::RestoreSlotsFull => "restore_slots_full",
            Self::RateLimited => "rate_limited",
            Self::Unknown => "unknown",
        }
    }

    /// The code for a stored [`Self::as_str`] value.
    pub fn from_stored(value: &str) -> Option<Self> {
        serde_json::from_value(serde_json::Value::String(value.to_string())).ok()
    }
}

/// The JSON body of a refused pairing request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairingErrorBody {
    /// Why it was refused.
    pub error: PairingErrorCode,
    /// Seconds to wait, also sent as `Retry-After`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub retry_after: Option<u64>,
    /// The pending operation this refusal is waiting on, when the caller's own.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operation_id: Option<String>,
    /// For a superseded secret, when its overlap ends (unix seconds).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grace_deadline: Option<i64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_code_from_a_newer_backend_still_parses() {
        let body: PairingErrorBody =
            serde_json::from_str(r#"{"error":"invented_later"}"#).expect("parse");
        assert_eq!(body.error, PairingErrorCode::Unknown);
        assert_eq!(
            PairingErrorCode::from_stored("preview_stale"),
            Some(PairingErrorCode::PreviewStale)
        );
    }
}
