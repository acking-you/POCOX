//! Pairing-code login on the backend: device routes, per-generation relay keys,
//! durable membership operations and their reconciliation.
//!
//! The rules live in `docs/pairing-code-login.md`. In short: a device's secret
//! is its authority; a hardware hint only locates; a membership change is a
//! durable operation spanning the relay, not a database transaction pretending
//! to include a network call; and no destination credential exists while old
//! authorization is uncertain.

mod address;
mod error;
mod limits;
mod reconcile;
mod relay;
mod relay_keys;
mod routes;
mod routes_code;
mod routes_group;
mod routes_link;
mod routes_restore;
mod service;
mod services;
mod settings;
mod transitions;

#[cfg(test)]
mod tests;

pub use address::TrustedProxies;
pub(crate) use address::{address_bucket, validate_trusted_proxies, PeerAddr};
pub use error::PairingError;
pub use limits::{PairingLimits, Rate};
pub(crate) use routes::{check_protocol, is_device_token, router};
pub use service::{ClientBucket, Pairing};
pub use settings::PairingSettings;
