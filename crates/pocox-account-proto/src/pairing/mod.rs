//! The pairing-code login contract between the backend and its clients.
//!
//! A pairing user is a set of linked devices with no profile, email or
//! password; see `docs/pairing-code-login.md`. [`format`] holds the pure rules
//! both sides must agree on, [`wire`] the JSON bodies and [`error`] the stable
//! error codes. GitHub sign-in uses none of this.

pub mod error;
pub mod format;
pub mod wire;

pub use error::{PairingErrorBody, PairingErrorCode};
pub use format::{
    display_code, encode_tuple, encode_tuple_with_tag, is_operation_id, normalize_code,
    parse_hardware_key, parse_label, relay_namespace_segment, secret_is_well_formed, CODE_LENGTH,
    DEVICE_SECRET_PREFIX, MAX_LABEL_BYTES, PAIRING_PROTOCOL_HEADER, PAIRING_PROTOCOL_VERSION,
    PAIR_URI_PREFIX,
};
pub use wire::*;
