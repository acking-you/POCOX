//! Persistence for pairing-code login: linked devices, generation-aware
//! sessions, recovery requests, durable membership operations and
//! per-generation relay keys.
//!
//! Every multi-statement change runs in a `BEGIN IMMEDIATE` transaction, so its
//! reads and writes are one atomic compare-and-set against all other writers. A
//! relay call never happens inside one: see [`operations`] for how a membership
//! change spans them.

mod budgets;
mod codes;
mod devices;
mod keys;
mod models;
pub mod operations;
mod prepare;
mod refusal;
mod requests;
mod retention;

pub use budgets::BudgetVerdict;
pub use codes::{CodeResolution, RotateInput, CODE_ROTATION_WAIT_SECS};
pub use devices::{DeviceAccess, HardwareBinding, NewDevice, NewDeviceOutcome};
pub use keys::{GrantFate, NamespaceClaim, NewGrant};
pub use models::{
    Device, DeviceSessionRow, DeviceUser, KeyState, OperationKind, OperationState, PairOperation,
    RelayKeyRow, RestoreRequest, RestoreRequestState, SessionState, TransitionKind,
};
pub use operations::CommitContext;
pub use prepare::{LinkInput, OperationMeta, RemoveInput, RestoreInput, RestoreProof};
pub use refusal::Refusal;
pub use requests::DecideInput;
pub use retention::PurgeCounts;
