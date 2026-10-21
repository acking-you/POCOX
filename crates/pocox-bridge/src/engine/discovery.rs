//! Relay service discovery: which POCOX services this device can see.

use anyhow::{Context, Result};
use pocox_core::service::ServiceId;

use crate::engine::transport::Transport;

/// List the POCOX services this transport can reach, dropping keys that
/// are not ours.
///
/// One relay query in both modes: an account credential is confined to its own
/// namespace, so the relay's listing IS the account's inventory and nothing has
/// to be filtered by prefix. Only the key SHAPE differs, which the transport
/// parses.
///
/// Returns [`ServiceId`]s rather than a discovery-specific struct: the caller
/// wants a service's identity, and the relay-key form it happened to arrive in
/// is [`Transport`]'s business, not theirs.
pub async fn discover(transport: &Transport) -> Result<Vec<ServiceId>> {
    let keys = pocox_pb::keys(&transport.session)
        .await
        .context("querying relay keys")?;
    Ok(keys
        .into_iter()
        .filter_map(|key| transport.parse_key(&key))
        .collect())
}
