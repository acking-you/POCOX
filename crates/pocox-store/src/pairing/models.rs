//! Row types for the pairing tables. All timestamps are unix seconds.

use sqlx::FromRow;

/// The state of one session generation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, sqlx::Type)]
#[sqlx(rename_all = "snake_case")]
pub enum SessionState {
    /// The device's one live generation.
    Current,
    /// Replaced, within its fixed overlap.
    Grace,
    /// No longer authorizes anything.
    Revoked,
}

/// A device's last membership transition.
#[derive(Debug, Clone, Copy, PartialEq, Eq, sqlx::Type)]
#[sqlx(rename_all = "snake_case")]
pub enum TransitionKind {
    /// Moved into another group by its own confirmation.
    Linked,
    /// Moved out of its group by its own confirmation.
    Left,
    /// Moved out of its group by a peer.
    Removed,
    /// Its secret was replaced by a restore.
    Restored,
    /// Its secret was replaced by a compromised-device retake.
    Retaken,
}

/// What a durable operation does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, sqlx::Type)]
#[sqlx(rename_all = "snake_case")]
pub enum OperationKind {
    /// Move a device into another group.
    Link,
    /// Move a device out of its group.
    Leave,
    /// Move a peer out of the actor's group.
    Remove,
    /// Replace a device's secret, with an overlap.
    Restore,
    /// Replace a device's secret, with none.
    Retake,
    /// Rotate a code. Has no relay work.
    Rotate,
    /// Answer a recovery request. Has no relay work.
    Decide,
}

impl OperationKind {
    /// Whether old authorization ends with no overlap.
    pub fn revokes_all(self) -> bool {
        !matches!(self, Self::Restore)
    }

    /// The stable name used in fingerprints.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Link => "link",
            Self::Leave => "leave",
            Self::Remove => "remove",
            Self::Restore => "restore",
            Self::Retake => "retake",
            Self::Rotate => "rotate",
            Self::Decide => "decide",
        }
    }
}

/// How far a durable operation has got.
#[derive(Debug, Clone, Copy, PartialEq, Eq, sqlx::Type)]
#[sqlx(rename_all = "snake_case")]
pub enum OperationState {
    /// Persisted; the subject is transitioning. Relay work may be under way.
    Prepared,
    /// The relay confirmed its part. Commit is all that remains.
    RelayApplied,
    /// Membership changed. Terminal.
    Committed,
    /// It ended without changing membership. Terminal.
    Failed,
}

impl OperationState {
    /// Whether nothing further will happen to this operation.
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Committed | Self::Failed)
    }
}

/// Where a recovery request stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, sqlx::Type)]
#[sqlx(rename_all = "snake_case")]
pub enum RestoreRequestState {
    /// Waiting for a member.
    Pending,
    /// A member allowed it; waiting for the requester to confirm.
    Approved,
    /// A member denied it.
    Denied,
    /// It ran out of time.
    Expired,
    /// The target changed or the requester moved on.
    Stale,
}

/// The lifecycle of one relay key, as far as the backend knows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, sqlx::Type)]
#[sqlx(rename_all = "snake_case")]
pub enum KeyState {
    /// Persisted before the relay was called; no key id known yet.
    Granting,
    /// May authenticate.
    Active,
    /// The relay confirmed it cannot authenticate.
    Revoked,
    /// It reached its expiry at the relay.
    Expired,
    /// Unusable: the relay's instance changed or its identity did not match.
    Dead,
}

/// A linked set of devices: `device_users`.
#[derive(Debug, Clone, PartialEq, Eq, FromRow)]
pub struct DeviceUser {
    /// Opaque id, disjoint from GitHub `users.id`.
    pub id: String,
    /// The relay namespace in canonical decimal, once allocated.
    pub namespace: Option<String>,
    /// Bumped on every membership change.
    pub membership_revision: i64,
    /// Creation time.
    pub created_at: i64,
}

/// One device: `devices`.
#[derive(Debug, Clone, PartialEq, Eq, FromRow)]
pub struct Device {
    /// Device id.
    pub id: String,
    /// The current user.
    pub user_id: String,
    /// Display name.
    pub label: String,
    /// Display-only platform label.
    pub platform: Option<String>,
    /// Keyed hash of the hardware hint, set at activation.
    pub hardware_lookup: Option<Vec<u8>>,
    /// Informational source of the hint.
    pub hardware_source: Option<String>,
    /// The current session generation.
    pub session_generation: i64,
    /// The current code generation.
    pub code_generation: i64,
    /// Keyed hash of the current code.
    pub code_lookup: Vec<u8>,
    /// When the current code was issued, in server time.
    pub code_issued_at: i64,
    /// Whether linking through the code is paused.
    pub code_paused: bool,
    /// Bumped on every pause. Bound into tickets, so resuming revives none.
    pub code_pause_epoch: i64,
    /// Creation time.
    pub created_at: i64,
    /// When it entered its current user.
    pub joined_at: i64,
    /// When it was explicitly activated. A removal clears this.
    pub activated_at: Option<i64>,
    /// When it was first activated. Never cleared.
    pub first_activated_at: Option<i64>,
    /// When it first received a relay key.
    pub first_key_at: Option<i64>,
    /// The session generation of the last key issued.
    pub key_generation: Option<i64>,
    /// The day it was last active, in days since the unix epoch.
    pub last_active_day: i64,
    /// Its last membership transition.
    pub last_transition_kind: Option<TransitionKind>,
    /// When that transition committed.
    pub last_transition_at: Option<i64>,
    /// The durable operation moving this device, if any.
    pub pending_transition_id: Option<String>,
    /// Start of the current retake window.
    pub retake_window_start: Option<i64>,
    /// Retakes in the current window.
    pub retake_count: i64,
}

/// One session generation: `device_sessions`.
#[derive(Debug, Clone, PartialEq, Eq, FromRow)]
pub struct DeviceSessionRow {
    /// The device.
    pub device_id: String,
    /// The generation, monotonic per device.
    pub generation: i64,
    /// SHA-256 of the device secret.
    pub secret_hash: Vec<u8>,
    /// The user this generation was issued under.
    pub original_user_id: String,
    /// The generation's state.
    pub state: SessionState,
    /// The fixed end of its overlap, once a replacement is prepared.
    pub grace_deadline: Option<i64>,
    /// When it stopped being current.
    pub retired_at: Option<i64>,
    /// Creation time.
    pub created_at: i64,
}

/// A recovery request: `pair_restore_requests`.
#[derive(Debug, Clone, PartialEq, Eq, FromRow)]
pub struct RestoreRequest {
    /// Independent random id.
    pub id: String,
    /// The inactive device asking.
    pub requester_device_id: String,
    /// The device it asks to restore.
    pub target_device_id: String,
    /// The target's user when asked.
    pub target_user_id: String,
    /// The target's session generation when asked.
    pub target_generation: i64,
    /// The group's membership revision when asked.
    pub target_revision: i64,
    /// Where it stands.
    pub state: RestoreRequestState,
    /// Creation time.
    pub created_at: i64,
    /// When an unanswered request expires.
    pub expires_at: i64,
    /// When an approval stops waiting for its requester.
    pub approval_expires_at: Option<i64>,
    /// Last change.
    pub updated_at: i64,
}

/// A durable operation: `pair_operations`.
#[derive(Debug, Clone, PartialEq, Eq, FromRow)]
pub struct PairOperation {
    /// Client-chosen idempotency id.
    pub id: String,
    /// What it does.
    pub kind: OperationKind,
    /// Hash of the exact request.
    pub fingerprint: Vec<u8>,
    /// The device that asked.
    pub actor_device_id: String,
    /// The actor's secret hash, which authorizes reading the result.
    pub actor_secret_hash: Vec<u8>,
    /// The device whose authorization changes.
    pub subject_device_id: String,
    /// The subject's generation when prepared.
    pub subject_generation: i64,
    /// The subject's user when prepared.
    pub source_user_id: String,
    /// That user's revision when prepared.
    pub source_revision: i64,
    /// The confirmed destination user.
    pub destination_user_id: Option<String>,
    /// The confirmed destination's revision.
    pub destination_revision: Option<i64>,
    /// The device whose code authorized this.
    pub code_device_id: Option<String>,
    /// That code's generation.
    pub code_generation: Option<i64>,
    /// That code's pause epoch.
    pub code_pause_epoch: Option<i64>,
    /// The approved recovery request that authorized this.
    pub request_id: Option<String>,
    /// The single-device user a leave or removal creates.
    pub new_user_id: Option<String>,
    /// Keyed hash of the hint to bind at commit.
    pub hardware_lookup: Option<Vec<u8>>,
    /// Informational source of that hint.
    pub hardware_source: Option<String>,
    /// The retiring generation's fixed deadline.
    pub grace_deadline: Option<i64>,
    /// How far it has got.
    pub state: OperationState,
    /// Whether any relay call may have been made.
    pub relay_started: bool,
    /// It committed without moving anyone.
    pub no_op: bool,
    /// Stable error code of a failed operation.
    pub result_code: Option<String>,
    /// The device the actor's secret belongs to afterwards.
    pub result_device_id: Option<String>,
    /// Relay attempts so far.
    pub attempts: i64,
    /// Earliest next attempt, after a failed one.
    pub next_attempt_at: Option<i64>,
    /// Creation time.
    pub created_at: i64,
    /// Last change.
    pub updated_at: i64,
    /// When it reached a terminal state.
    pub completed_at: Option<i64>,
}

/// One relay key: `device_relay_keys`.
#[derive(Debug, Clone, PartialEq, Eq, FromRow)]
pub struct RelayKeyRow {
    /// The grant operation's id, named in the label.
    pub grant_id: String,
    /// The device.
    pub device_id: String,
    /// The session generation it belongs to.
    pub generation: i64,
    /// The user it was granted under.
    pub user_id: String,
    /// The namespace it must be in, in canonical decimal.
    pub namespace: String,
    /// The relay instance that issued it.
    pub relay_instance: String,
    /// The exact label it was issued with.
    pub label: String,
    /// The relay's key id in canonical decimal, once known.
    pub key_id: Option<String>,
    /// Expiry in the relay's clock, as its last answer stated.
    pub expires_at: Option<i64>,
    /// The same moment in the backend's clock.
    pub local_end: Option<i64>,
    /// The backend-clock moment it must never outlive.
    pub hard_cutoff: Option<i64>,
    /// The relay has not yet confirmed that cutoff.
    pub cutoff_pending: bool,
    /// Its lifecycle.
    pub state: KeyState,
    /// Creation time.
    pub created_at: i64,
    /// Last change.
    pub updated_at: i64,
    /// When it stopped being able to authenticate.
    pub ended_at: Option<i64>,
}
