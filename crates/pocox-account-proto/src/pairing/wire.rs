//! JSON bodies of the pairing routes. Unknown fields are ignored on read, so
//! later additions stay compatible.

use serde::{Deserialize, Serialize};

use super::PairingErrorCode;

/// A session on a device principal. Holds no refresh token: the device secret,
/// which stays in the client's device store, is what refreshes it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceSession {
    /// Bearer token (JWT) for pairing and `/v1/*` routes.
    pub token: String,
    /// Bearer-token lifetime in seconds.
    pub expires_in_secs: u64,
    /// The device's label (display only).
    pub login: String,
    /// The device's current user: compare it with the installation's own before
    /// persisting this session.
    pub account_id: String,
    /// This device's id.
    pub device_id: String,
    /// The session generation this token belongs to.
    pub generation: i64,
    /// Whether the device has been explicitly activated.
    pub activated: bool,
    /// The device's last membership transition, if it had one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub membership_change: Option<MembershipChange>,
}

/// A device's last membership transition.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct MembershipChange {
    /// What happened.
    pub kind: MembershipChangeKind,
    /// When it committed (unix seconds).
    pub at: i64,
}

/// What a membership transition was.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MembershipChangeKind {
    /// The user confirmed moving this device into another group.
    Linked,
    /// The user confirmed moving this device out of its group.
    Left,
    /// Another device removed this one. Host nothing until an explicit
    /// Continue.
    Removed,
    /// A kind this client does not know, from a newer backend.
    #[serde(other)]
    Unknown,
}

/// Request body for `POST /v1/pair/device`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairDeviceRequest {
    /// The client-generated secret, durably saved before this request.
    pub device_secret: String,
    /// The device's display name.
    pub label: String,
    /// Display-only platform label. Grants nothing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
}

/// Request body for `POST /auth/refresh` on a device principal. GitHub clients
/// keep sending [`crate::http::RefreshRequest`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceRefreshRequest {
    /// The device's current secret.
    pub device_secret: String,
}

/// An optional hardware hint. Locates a device and never authorizes anything.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HardwareHint {
    /// The application-derived hardware key: 32 bytes in unpadded base64url.
    pub key: String,
    /// Informational source label.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

/// Request body for `POST /v1/pair/activate`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActivateRequest {
    /// Bound to this device, replacing any earlier binding of the same hint.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hint: Option<HardwareHint>,
}

/// Response to `POST /v1/pair/activate`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActivationStatus {
    /// When the device was first activated (unix seconds).
    pub activated_at: i64,
}

/// Response to the code routes: this device's own code. Never logged or stored.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CodeStatus {
    /// The code as displayed: `K7M2-F9QX-3RTB`.
    pub code: String,
    /// When it was issued (unix seconds, server time).
    pub issued_at: i64,
    /// Earliest rotation time (unix seconds, server time).
    pub next_rotation_at: i64,
    /// Whether linking through this code is paused.
    pub paused: bool,
}

/// Request body for `POST /v1/pair/code/rotate`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RotateCodeRequest {
    /// Idempotency id; a retry returns the current code without rotating again.
    pub operation_id: String,
}

/// Request body for `PATCH /v1/pair/code`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SetCodePausedRequest {
    /// The state to set: explicit, so a retry cannot toggle it back.
    pub paused: bool,
}

/// Request body for `POST /v1/pair/preview`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreviewRequest {
    /// The code as typed.
    pub code: String,
}

/// A device as shown before confirming a group. Carries nothing that
/// authorizes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreviewDevice {
    /// The device's id, which a restore names as its target.
    pub id: String,
    /// The device's display name.
    pub name: String,
    /// The day it was last active, in days since the unix epoch.
    pub last_active_day: i64,
}

/// Response to `POST /v1/pair/preview`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PreviewResponse {
    /// The signed ticket a link or restore confirms.
    pub ticket: String,
    /// When the ticket stops working (unix seconds).
    pub expires_at: i64,
    /// The device whose code this is.
    pub target_device_id: String,
    /// Whether the caller is already in this group, which makes a link a no-op.
    pub already_member: bool,
    /// The group's devices.
    pub devices: Vec<PreviewDevice>,
}

/// Request body for `POST /v1/pair/link`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LinkRequest {
    /// The ticket from the preview the user confirmed.
    pub ticket: String,
    /// Idempotency id bound to this exact request.
    pub operation_id: String,
    /// Explicit confirmation of leaving current peers.
    #[serde(default)]
    pub leave_current: bool,
    /// Bound when this link activates the device.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hint: Option<HardwareHint>,
}

/// Request body for `POST /v1/pair/leave`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LeaveRequest {
    /// Idempotency id.
    pub operation_id: String,
}

/// Request body for `POST /v1/pair/restore/requests`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateRestoreRequest {
    /// Locates the device to ask about. Grants nothing.
    pub hint: HardwareHint,
}

/// Where a recovery request stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RestoreRequestStatus {
    /// Waiting for a member.
    Pending,
    /// A member allowed it. Nothing changes until the requester confirms.
    Approved,
    /// A member denied it.
    Denied,
    /// It ran out of time.
    Expired,
    /// The target's group or generation changed, or the requester moved on.
    Stale,
    /// A status this client does not know, from a newer backend.
    #[serde(other)]
    Unknown,
}

/// Response to `POST /v1/pair/restore/requests` and
/// `GET /v1/pair/restore/{request_id}`.
///
/// Reveals no code, device name or count until
/// [`RestoreRequestStatus::Approved`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RestoreRequestView {
    /// The request's id.
    pub request_id: String,
    /// Where it stands.
    pub status: RestoreRequestStatus,
    /// Shown on both devices to tell this request from an impostor.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub matching_id: Option<String>,
    /// When it stops being answerable (unix seconds).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<i64>,
    /// Approved only: the device this would restore.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_device_id: Option<String>,
    /// Approved only: the group's devices, to confirm before anything changes.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub devices: Vec<PreviewDevice>,
}

/// How a restore treats the secret it replaces.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RestoreIntent {
    /// Continuity: the old secret keeps a fixed 10-minute overlap and the code
    /// stays the same.
    #[default]
    Restore,
    /// A compromised device: old authorization ends at once and the code
    /// rotates.
    Retake,
}

/// Request body for `POST /v1/pair/restore`. Names a ticket and a target, or an
/// approved request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConfirmRestoreRequest {
    /// The ticket from a code's preview.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ticket: Option<String>,
    /// With a ticket: the group's device the user says this is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target_device_id: Option<String>,
    /// An approved request, instead of a ticket.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    /// Idempotency id bound to this exact request.
    pub operation_id: String,
    /// Bound to the restored device.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hint: Option<HardwareHint>,
    /// Whether old authorization keeps its overlap.
    #[serde(default)]
    pub intent: RestoreIntent,
}

/// One device in `GET /v1/devices`. Never another device's code or secret.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceEntry {
    /// The device's id.
    pub id: String,
    /// The device's display name.
    pub name: String,
    /// Display-only platform label.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
    /// When it joined this group (unix seconds).
    pub joined_at: i64,
    /// The day it was last active, in days since the unix epoch.
    pub last_active_day: i64,
    /// Whether it has been set up. An inactive peer hosts nothing.
    pub activated: bool,
    /// Whether this is the caller.
    pub is_self: bool,
}

/// A recovery request a member can answer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingRestoreSummary {
    /// The request's id, which an answer must name.
    pub request_id: String,
    /// The device it asks to restore.
    pub target_device_id: String,
    /// The requester's self-reported name. Does not identify anyone.
    pub requester_name: String,
    /// Compare with the requester's screen.
    pub matching_id: String,
    /// When it expires (unix seconds).
    pub expires_at: i64,
}

/// Response to `GET /v1/devices`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceListResponse {
    /// One page of the caller's group.
    pub devices: Vec<DeviceEntry>,
    /// Pass as `cursor` for the next page.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
    /// Requests waiting on a member, bounded.
    pub pending_requests: Vec<PendingRestoreSummary>,
}

/// Request body for `PATCH /v1/devices/{id}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RenameDeviceRequest {
    /// The new display name.
    pub name: String,
}

/// Request body for `POST /v1/devices/{id}/restore`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DecideRestoreRequest {
    /// The exact request being answered.
    pub request_id: String,
    /// Idempotency id.
    pub operation_id: String,
    /// Allow or deny. Allowing changes nothing until the requester confirms.
    pub allow: bool,
}

/// What kind of change an operation is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OperationKind {
    /// Move a device into another group.
    Link,
    /// Move a device out of its group.
    Leave,
    /// Move another device out of the caller's group.
    Remove,
    /// Restore a device with an overlap.
    Restore,
    /// Restore a compromised device with no overlap.
    Retake,
    /// Rotate a code.
    Rotate,
    /// Answer a recovery request.
    Decide,
    /// A kind this client does not know, from a newer backend.
    #[serde(other)]
    Unknown,
}

/// Where an operation stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OperationStatus {
    /// Relay work is incomplete. Poll; never repeat the action.
    Pending,
    /// It committed.
    Completed,
    /// It ended without changing membership. See [`OperationView::error`].
    Failed,
    /// A status this client does not know, from a newer backend.
    #[serde(other)]
    Unknown,
}

/// The result of a durable operation, returned with 202 while pending and from
/// `GET /v1/pair/operations/{id}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OperationView {
    /// The operation's id.
    pub operation_id: String,
    /// What it does.
    pub kind: OperationKind,
    /// Where it stands.
    pub status: OperationStatus,
    /// Why it failed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<PairingErrorCode>,
    /// A session freshly issued for this response, never stored. Present only
    /// on `GET /v1/pair/operations/{id}`, whose bearer is the device
    /// secret, when that secret is current and idle. A response to a
    /// mutation never carries one: refresh with the secret after any
    /// completed mutation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<DeviceSession>,
}
