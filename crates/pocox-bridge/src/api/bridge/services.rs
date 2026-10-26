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

impl From<pocox_core::service::ServiceId> for ServiceIdDto {
    fn from(id: pocox_core::service::ServiceId) -> Self {
        Self {
            device: id.device.clone(),
            kind: id.kind.as_key_segment().into(),
            name: id.name.clone(),
            key: id.key(),
        }
    }
}

/// Discover this process's owned loopback services without contacting a relay.
#[frb(sync)]
pub fn local_services() -> Vec<ServiceIdDto> {
    discovery::local()
        .into_iter()
        .map(ServiceIdDto::from)
        .collect()
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
    /// This process's own loopback service; no relay setup or data forwarding.
    Local,
}

impl From<runtime::TunnelPath> for TunnelPathDto {
    fn from(path: runtime::TunnelPath) -> Self {
        match path {
            runtime::TunnelPath::Local => Self::Local,
            runtime::TunnelPath::RelayOnly => Self::RelayOnly,
            runtime::TunnelPath::Idle => Self::Idle,
            runtime::TunnelPath::Direct => Self::Direct,
            runtime::TunnelPath::Relay => Self::Relay,
            runtime::TunnelPath::Mixed => Self::Mixed,
        }
    }
}

/// Why a tunnel's attempt to reach the relay failed, mirrored for Dart.
pub enum TunnelFailureDto {
    /// The relay's name did not resolve.
    Dns,
    /// The connection to the relay broke.
    Transport,
    /// The relay did not answer in time.
    Timeout,
    /// The service is not published, or its host is unavailable.
    ServiceUnavailable,
    /// The relay refused the credential or the request.
    Rejected,
    /// The device's network changed underneath it.
    NetworkChanged,
}

impl From<pocox_pb::RecoveryFailure> for TunnelFailureDto {
    fn from(failure: pocox_pb::RecoveryFailure) -> Self {
        match failure {
            pocox_pb::RecoveryFailure::Dns => Self::Dns,
            pocox_pb::RecoveryFailure::Transport => Self::Transport,
            pocox_pb::RecoveryFailure::Timeout => Self::Timeout,
            pocox_pb::RecoveryFailure::ServiceUnavailable => Self::ServiceUnavailable,
            pocox_pb::RecoveryFailure::Rejected => Self::Rejected,
            pocox_pb::RecoveryFailure::NetworkChanged => Self::NetworkChanged,
        }
    }
}

/// The phase a tunnel's link to the relay entered last, mirrored for Dart.
pub enum RelayPhaseDto {
    /// Starting up.
    Starting,
    /// Waiting for a free setup slot.
    Queued,
    /// Looking up the relay's address.
    Resolving,
    /// Connecting to the relay.
    Connecting,
    /// Authenticating and confirming the service.
    Handshake,
    /// Confirmed by the relay.
    Ready,
    /// Waiting to try again after a failure.
    Backoff,
    /// Stopped.
    Stopped,
}

impl From<pocox_pb::RecoveryPhase> for RelayPhaseDto {
    fn from(phase: pocox_pb::RecoveryPhase) -> Self {
        match phase {
            pocox_pb::RecoveryPhase::Starting => Self::Starting,
            pocox_pb::RecoveryPhase::Capacity => Self::Queued,
            pocox_pb::RecoveryPhase::Resolving => Self::Resolving,
            pocox_pb::RecoveryPhase::Connecting => Self::Connecting,
            pocox_pb::RecoveryPhase::Handshake => Self::Handshake,
            pocox_pb::RecoveryPhase::Ready => Self::Ready,
            pocox_pb::RecoveryPhase::Backoff => Self::Backoff,
            pocox_pb::RecoveryPhase::Stopped => Self::Stopped,
        }
    }
}

/// How far a direct (hole-punched) attempt got, mirrored for Dart.
pub enum DirectStageDto {
    /// Asking whether the other side offers direct.
    Negotiating,
    /// Learning this device's public address and asking for a grant.
    Discovering,
    /// Dialing the other side through both NATs.
    Punching,
    /// The path is up; the other side is opening its service.
    Committing,
}

impl From<pocox_pb::DirectStage> for DirectStageDto {
    fn from(stage: pocox_pb::DirectStage) -> Self {
        match stage {
            pocox_pb::DirectStage::Negotiating => Self::Negotiating,
            pocox_pb::DirectStage::Discovering => Self::Discovering,
            pocox_pb::DirectStage::Punching => Self::Punching,
            pocox_pb::DirectStage::Committing => Self::Committing,
        }
    }
}

/// What a [`LinkEventDto`] records.
pub enum LinkEventKindDto {
    /// The relay answered, for the first time or after failures.
    RelayReady,
    /// An attempt to reach the relay failed.
    RelayFailed,
    /// The device's network changed.
    NetworkChanged,
    /// A connection went direct.
    DirectEstablished,
    /// A connection gave up on direct and used the relay.
    DirectFallback,
}

/// One entry of a tunnel's recent history, mirrored flat for Dart.
pub struct LinkEventDto {
    /// Increases with every event, so new ones can be told from seen ones.
    pub seq: u32,
    /// Milliseconds since it (last) happened.
    pub age_ms: u32,
    /// Times it happened in a row.
    pub repeats: u32,
    /// What happened.
    pub kind: LinkEventKindDto,
    /// `RelayFailed`: why.
    pub failure: Option<TunnelFailureDto>,
    /// `DirectFallback`: the stage it gave up at.
    pub stage: Option<DirectStageDto>,
    /// `RelayReady`: setup latency; `RelayFailed`: time to the next try;
    /// `DirectEstablished`: setup time.
    pub ms: Option<u32>,
}

impl From<pocox_pb::TunnelEvent> for LinkEventDto {
    fn from(event: pocox_pb::TunnelEvent) -> Self {
        use pocox_pb::TunnelEventKind as Kind;
        let (kind, failure, stage, ms) = match event.kind {
            Kind::RelayReady {
                latency_ms,
            } => (LinkEventKindDto::RelayReady, None, None, Some(latency_ms)),
            Kind::RelayFailed {
                failure,
                retry_in_ms,
            } => (LinkEventKindDto::RelayFailed, Some(failure.into()), None, Some(retry_in_ms)),
            Kind::NetworkChanged => (LinkEventKindDto::NetworkChanged, None, None, None),
            Kind::DirectEstablished {
                setup_ms,
            } => (LinkEventKindDto::DirectEstablished, None, None, Some(setup_ms)),
            Kind::DirectFallback {
                stage,
            } => (LinkEventKindDto::DirectFallback, None, Some(stage.into()), None),
        };
        Self {
            // Sequence numbers only grow; one tunnel never records 2^32 events.
            seq: event.seq as u32,
            age_ms: count(event.age_ms),
            repeats: event.repeats,
            kind,
            failure,
            stage,
            ms: ms.map(count),
        }
    }
}

/// Dart reads `u32` as a plain `int`; `u64` would cost a `BigInt` per field.
fn count(value: u64) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

/// Status of one active subscription, mirrored for Dart.
pub struct SubStatusDto {
    /// Service key.
    pub key: String,
    /// Local `host:port`.
    pub local_addr: String,
    /// Task still running.
    pub alive: bool,
    /// Has been ready; false while it is still coming up.
    pub ready: bool,
    /// Locally observed path, never the saved preference.
    pub path: TunnelPathDto,
    /// Active direct data connections.
    pub active_direct: u32,
    /// Active relay data connections counted by auto mode.
    pub active_relay: u32,
    /// Data connections that went direct in this tunnel's lifetime.
    pub direct_sessions: u32,
    /// Data connections that used the relay in this tunnel's lifetime.
    pub relay_sessions: u32,
    /// Pre-commit fallbacks in this tunnel's lifetime.
    pub fallbacks: u32,
    /// SDK reason for its most recent fallback.
    pub last_fallback: Option<String>,
    /// Waiting to try the relay again after a failure.
    pub retrying: bool,
    /// Failures since the tunnel last reached the relay.
    pub consecutive_failures: u32,
    /// Why the most recent attempt failed, if one did.
    pub last_failure: Option<TunnelFailureDto>,
    /// How long the last answered setup took, in milliseconds.
    pub setup_latency_ms: Option<u32>,
    /// The phase its link to the relay entered last.
    pub relay_phase: RelayPhaseDto,
    /// Milliseconds before the next attempt, while waiting for one.
    pub next_retry_ms: Option<u32>,
    /// How far the direct attempt in flight got, if one is.
    pub attempt_stage: Option<DirectStageDto>,
    /// Milliseconds since that attempt began.
    pub attempt_ms: Option<u32>,
    /// Direct attempts in flight.
    pub attempts_in_flight: u32,
    /// What happened to it lately, oldest first.
    pub events: Vec<LinkEventDto>,
}

impl From<runtime::SubStatus> for SubStatusDto {
    fn from(s: runtime::SubStatus) -> Self {
        let attempt = s.path.attempt;
        Self {
            key: s.key,
            local_addr: s.local_addr,
            alive: s.alive,
            ready: s.ready,
            path: s.path.path.into(),
            active_direct: count(s.path.active_direct),
            active_relay: count(s.path.active_relay),
            direct_sessions: count(s.path.direct_sessions),
            relay_sessions: count(s.path.relay_sessions),
            fallbacks: count(s.path.fallbacks),
            last_fallback: s.path.last_fallback,
            retrying: s.health.retrying,
            consecutive_failures: count(s.health.consecutive_failures),
            last_failure: s.health.last_failure.map(TunnelFailureDto::from),
            setup_latency_ms: s.health.setup_latency_ms.map(count),
            relay_phase: s.health.phase.into(),
            next_retry_ms: s.health.next_retry_ms.map(count),
            attempt_stage: attempt.map(|a| a.stage.into()),
            attempt_ms: attempt.map(|a| count(a.elapsed_ms)),
            attempts_in_flight: attempt.map_or(0, |a| a.in_flight),
            events: s.events.into_iter().map(LinkEventDto::from).collect(),
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
        Ok(found.into_iter().map(ServiceIdDto::from).collect())
    })
    .await
}

/// Expose an API service on `127.0.0.1:<local_port>` (`0`: any free port).
/// An API this app hosts is forwarded there directly, following its host's
/// listener across restarts; another device's is subscribed through the relay.
pub async fn api_subscribe(service_key: String, local_port: u16) -> Result<SubStatusDto> {
    execution::run(Lane::Control, move || {
        let target = crate::engine::service_connection::Target::resolve(&service_key)?;
        Ok(target.expose(&service_key, local_port)?.into())
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
