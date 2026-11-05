//! Why a pairing transaction refused to change anything.

/// A compare-and-set that lost: the state is not what the request assumed.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Refusal {
    /// A membership change is in progress on this device or group.
    #[error("a membership change is in progress")]
    TransitionPending {
        /// The operation the caller can poll, when it is the caller's own.
        operation_id: Option<String>,
    },
    /// What the user confirmed has changed.
    #[error("the confirmed state has changed")]
    PreviewStale,
    /// The caller no longer qualifies, or the request no longer applies.
    #[error("the request no longer applies")]
    Stale,
    /// The caller has peers and did not confirm leaving them.
    #[error("the device is already linked")]
    AlreadyLinked,
    /// The target group is at its size limit.
    #[error("the group is full")]
    GroupFull,
    /// This operation id was already used with different input.
    #[error("the operation id was used with different input")]
    OperationConflict,
    /// The caller's session generation is no longer the device's current one.
    #[error("the session generation is stale")]
    SessionStale,
    /// Nothing was found in the caller's scope.
    #[error("not found")]
    NotFound,
    /// The target's approval slots are full.
    #[error("the recovery slots are full")]
    SlotsFull,
    /// The device is not activated.
    #[error("the device is not activated")]
    NotActivated,
    /// A code rotation or retake came before its wait ended.
    #[error("too soon; retry after {retry_after} seconds")]
    TooSoon {
        /// Seconds until it may be tried again.
        retry_after: u64,
    },
}
