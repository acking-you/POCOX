//! Pairing-code login: this installation's half of the device identity.
//!
//! ```text
//!   device store (pocox-core)          shared by every installation of a device
//!        │ secret
//!        ▼
//!   identity ── mint ──▶ DeviceSession  POST /auth/refresh or /v1/pair/device
//!        │                    │
//!        │ a JWT for          ▼
//!        │ staged work   session        compare the user, stop what the old user
//!        │                    │         owned, persist `[account]`, restart
//!        ▼                    ▼
//!   flows, operations     lifecycle     hosting owner only
//!                             ▲
//!                         watch         long-running owners learn of a peer's act
//! ```
//!
//! `[account]` holds only the short-lived JWT and display fields; the store
//! holds the secret. Preparing a code changes nothing but the store. See
//! `docs/pairing-code-login.md`.

mod client;
mod error;
pub mod flows;
pub mod identity;
pub mod lifecycle;
pub mod native_store;
pub mod operations;
mod parked;
pub mod session;
pub mod status;
pub mod watch;

#[cfg(test)]
mod identity_tests;
#[cfg(test)]
mod late_answer_tests;
#[cfg(test)]
mod lost_response_tests;
#[cfg(test)]
mod removal_tests;
#[cfg(test)]
mod revival_tests;
#[cfg(test)]
mod switching_tests;
#[cfg(test)]
mod test_lab;

pub use error::{code_of, signed_out_error, NoDevice, PairingError, SignedOut};
pub use flows::{NativeHint, Prepared};
pub use operations::OperationOutcome;
pub use parked::{forget_github as forget_parked_github, parked_github, resume_github};
pub use status::{PairingState, PairingStatus};
