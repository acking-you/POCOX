//! The client's half of pairing-code login: the device identity it keeps.
//!
//! ```text
//!   canonical backend + OS environment + POCOX_DEVICE_SCOPE
//!        │                     (the OS account supplies the private parent)
//!        ▼
//!   StoreKey ── slot ──▶ StoreBackend    a private file, or the platform's store
//!        │
//!        ├──▶ DeviceStore    the only durable copy of the device secret, plus
//!        │                   the operations local configuration has not caught
//!        │                   up with; every read and write holds a file lock
//!        └──▶ derive_hint    locates a device for recovery, never authorizes
//! ```
//!
//! See `docs/pairing-code-login.md`. Nothing here talks to the network; the
//! bridge's pairing engine owns the backend conversation.

mod backend;
mod hint;
mod store;
mod tuple;

pub use backend::CanonicalBackend;
pub use hint::{
    derive_hint, os_account, read_local_hardware_id, DerivedHint, HintSource, RawHardwareId,
};
pub use store::{
    generate_secret, install_platform_store, secret_is_well_formed, ActiveAccount, DeviceRecord,
    DeviceStore, OperationKind, OperationState, SessionMark, StoreBackend, StoreKey,
    StoredOperation, DEVICE_SCOPE_ENV,
};
pub use tuple::{encode_tuple, encode_tuple_with_tag, DEVICE_SECRET_PREFIX};
