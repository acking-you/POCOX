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

/// What a subscription's data connections currently go through, mirrored
/// for Dart.
pub enum TunnelPathDto {
    /// Opened with the relay-only preference.
    RelayOnly,
    /// Ready, with no data connection open right now.
    Idle,
    /// Every open data connection is direct.
    Direct,
    /// Every open data connection uses the relay.
    Relay,
    /// Direct and relay data connections are both open.
    Mixed,
}

impl From<runtime::TunnelPath> for TunnelPathDto {
    fn from(path: runtime::TunnelPath) -> Self {
        match path {
            runtime::TunnelPath::RelayOnly => Self::RelayOnly,
            runtime::TunnelPath::Idle => Self::Idle,
            runtime::TunnelPath::Direct => Self::Direct,
            runtime::TunnelPath::Relay => Self::Relay,
            runtime::TunnelPath::Mixed => Self::Mixed,
        }
    }
}

/// Status of one active subscription, mirrored for Dart.
pub struct SubStatusDto {
    /// Service key.
    pub key: String,
    /// Local `host:port`.
    pub local_addr: String,
    /// Task still running.
    pub alive: bool,
    /// Locally observed path, never the saved preference.
    pub path: TunnelPathDto,
    /// Active direct data connections.
    pub active_direct: u32,
    /// Active relay data connections counted by auto mode.
    pub active_relay: u32,
    /// Pre-commit fallbacks in this tunnel's lifetime.
    pub fallbacks: u32,
    /// SDK reason for its most recent fallback.
    pub last_fallback: Option<String>,
}

impl From<runtime::SubStatus> for SubStatusDto {
    fn from(s: runtime::SubStatus) -> Self {
        // Dart reads `u32` as a plain `int`; `u64` would cost a `BigInt` per field.
        let count = |value: u64| u32::try_from(value).unwrap_or(u32::MAX);
        Self {
            key: s.key,
            local_addr: s.local_addr,
            alive: s.alive,
            path: s.path.path.into(),
            active_direct: count(s.path.active_direct),
            active_relay: count(s.path.active_relay),
            fallbacks: count(s.path.fallbacks),
            last_fallback: s.path.last_fallback,
        }
    }
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
        Ok(s.into())
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
        .map(SubStatusDto::from)
        .collect()
}
