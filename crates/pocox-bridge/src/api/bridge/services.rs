//! Service discovery on the relay and local API-service subscriptions.

use super::*;
use crate::engine::execution::{self, Lane};

/// A discovered service, mirrored for Dart.
pub struct ServiceIdDto {
    /// Device id segment.
    pub device: String,
    /// `app` (Codex app-server), `acp` (ACP agent gateway), `api`
    /// (Responses proxy) or `meta` (host meta service).
    pub kind: String,
    /// Instance name segment.
    pub name: String,
    /// Full relay key.
    pub key: String,
}

/// Status of one active subscription, mirrored for Dart.
pub struct SubStatusDto {
    /// Service key.
    pub key: String,
    /// Local `host:port`.
    pub local_addr: String,
    /// Task still running.
    pub alive: bool,
}

/// Discover the services this device can reach on the relay.
///
/// One query in both modes: an account credential sees only its own namespace,
/// so the relay's listing IS the account's inventory. Reported with BARE `pcx:`
/// keys whatever the mode, because that is the identity the app and its Dart
/// layer use — [`Transport::relay_key`] maps back when the relay is next
/// addressed.
pub async fn discover_services() -> Result<Vec<ServiceIdDto>> {
    execution::run(Lane::Background, move || {
        let transport = transport::resolve_blocking()?;
        let found = runtime::runtime().block_on(discovery::discover(&transport))?;
        Ok(found
            .into_iter()
            .map(|id| ServiceIdDto {
                device: id.device.clone(),
                kind: id.kind.as_key_segment().to_string(),
                name: id.name.clone(),
                key: id.key(),
            })
            .collect())
    })
    .await
}

/// Subscribe to an API service, exposing it on `127.0.0.1:<local_port>`.
pub async fn api_subscribe(service_key: String, local_port: u16) -> Result<SubStatusDto> {
    execution::run(Lane::Control, move || {
        let transport = transport::resolve_blocking()?;
        let s = runtime::subscribe_service(service_key, local_port, &transport)?;
        Ok(SubStatusDto {
            key: s.key,
            local_addr: s.local_addr,
            alive: s.alive,
        })
    })
    .await
}

/// Stop an API-service subscription.
pub fn api_unsubscribe(service_key: String) {
    runtime::unsubscribe_service(&service_key);
}

/// List all active subscriptions.
pub fn subscriptions() -> Vec<SubStatusDto> {
    runtime::list_subscriptions()
        .into_iter()
        .map(|s| SubStatusDto {
            key: s.key,
            local_addr: s.local_addr,
            alive: s.alive,
        })
        .collect()
}
