//! The data path a subscription is observed to use, and how its tunnel to the
//! relay is doing, from the SDK's counters.

use pocox_core::config::ConnectionPath;
use pocox_pb::{
    DirectAttempt, PathDiagnostics, PortMappingStage, PortMappingStatus, RecoveryFailure,
    RecoveryPhase, RelayTransport, TunnelDiagnostics,
};

/// What a subscription's data connections currently go through.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum TunnelPath {
    /// Opened with the relay-only preference; the SDK keeps no path counters.
    #[default]
    RelayOnly,
    /// Ready, with no data connection open right now.
    Idle,
    /// Every open data connection is direct.
    Direct,
    /// Every open data connection uses the relay.
    Relay,
    /// Some open data connections are direct, others use the relay.
    Mixed,
    /// A process-owned loopback service, with no relay or forwarding listener.
    Local,
}

/// A local SDK observation, never inferred from the configured preference.
#[derive(Debug, Clone, Default)]
pub struct PathStatus {
    /// What the open data connections go through.
    pub path: TunnelPath,
    /// Number of currently active direct data connections.
    pub active_direct: u64,
    /// Number of currently active relay data connections tracked by auto mode.
    pub active_relay: u64,
    /// Data connections that went direct during this tunnel's lifetime.
    pub direct_sessions: u64,
    /// Data connections that used the relay during this tunnel's lifetime.
    pub relay_sessions: u64,
    /// Pre-commit fallbacks observed during this tunnel's lifetime.
    pub fallbacks: u64,
    /// SDK diagnostic reason for the most recent fallback, if any.
    pub last_fallback: Option<String>,
    /// The direct attempt in flight, if any: how far its hole punching got.
    pub attempt: Option<DirectAttempt>,
}

/// What a tunnel's router port mapping amounts to right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MappingState {
    /// Nothing asked yet: it waits for a failed punch or a first direct
    /// session.
    Standby,
    /// Looking for the router, or asking it for a mapping.
    Asking,
    /// A lease is usable now.
    Active,
    /// The router gave none; it is asked again later.
    Failed,
    /// Released, or ended with its tunnel.
    Stopped,
}

impl MappingState {
    /// Classify the SDK's stage. A lease outlives some stages, such as a
    /// renewal that failed, so `active` decides first.
    pub fn of(status: &PortMappingStatus) -> Self {
        if status.active {
            return Self::Active;
        }
        match status.stage {
            PortMappingStage::Standby | PortMappingStage::WaitingForDirect => Self::Standby,
            PortMappingStage::Discovering
            | PortMappingStage::GatewayFound
            | PortMappingStage::Discovered
            | PortMappingStage::Requesting
            | PortMappingStage::Active
            | PortMappingStage::Renewing
            | PortMappingStage::NetworkChanged => Self::Asking,
            PortMappingStage::Expired | PortMappingStage::Retrying | PortMappingStage::Failed => {
                Self::Failed
            },
            PortMappingStage::Releasing
            | PortMappingStage::Released
            | PortMappingStage::ReleaseSent
            | PortMappingStage::ReleaseFailed
            | PortMappingStage::Cancelled
            | PortMappingStage::Stopped => Self::Stopped,
        }
    }

    /// Stable label for programs.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Standby => "standby",
            Self::Asking => "asking",
            Self::Active => "active",
            Self::Failed => "failed",
            Self::Stopped => "stopped",
        }
    }
}

/// How a tunnel's own link to the relay is doing, as the SDK reports it.
#[derive(Debug, Clone, Copy)]
pub struct TunnelHealth {
    /// The carrier it started on; none without an SDK tunnel.
    pub relay_transport: Option<RelayTransport>,
    /// The phase its worker entered last.
    pub phase: RecoveryPhase,
    /// Time left before the next attempt, while waiting for one.
    pub next_retry_ms: Option<u64>,
    /// Waiting to try again after a failure.
    pub retrying: bool,
    /// Failures since the last success.
    pub consecutive_failures: u64,
    /// Why the most recent attempt failed, if one did.
    pub last_failure: Option<RecoveryFailure>,
    /// How long the last answered setup took, in milliseconds.
    pub setup_latency_ms: Option<u64>,
}

impl Default for TunnelHealth {
    fn default() -> Self {
        Self {
            relay_transport: None,
            phase: RecoveryPhase::Starting,
            next_retry_ms: None,
            retrying: false,
            consecutive_failures: 0,
            last_failure: None,
            setup_latency_ms: None,
        }
    }
}

impl TunnelHealth {
    /// Read from the SDK's snapshot of a tunnel.
    pub(super) fn observe(diagnostics: &TunnelDiagnostics) -> Self {
        Self {
            relay_transport: Some(diagnostics.relay_transport),
            phase: diagnostics.last_attempt_phase,
            next_retry_ms: diagnostics.next_retry_in_ms,
            retrying: diagnostics.last_attempt_phase == RecoveryPhase::Backoff,
            consecutive_failures: diagnostics.consecutive_failures,
            last_failure: diagnostics.last_failure,
            setup_latency_ms: diagnostics.last_setup_latency_ms,
        }
    }
}

impl PathStatus {
    /// Classify the SDK's `direct` counters of a tunnel opened with `policy`.
    /// Completed connections and past successes never count as a live path.
    pub(super) fn observe(policy: ConnectionPath, direct: Option<PathDiagnostics>) -> Self {
        let direct = match (policy, direct) {
            (ConnectionPath::RelayOnly, _) => return Self::default(),
            (ConnectionPath::Auto, None) => {
                return Self {
                    path: TunnelPath::Idle,
                    ..Self::default()
                }
            },
            (ConnectionPath::Auto, Some(direct)) => direct,
        };
        let path = match (direct.active_direct > 0, direct.active_relay > 0) {
            (true, true) => TunnelPath::Mixed,
            (true, false) => TunnelPath::Direct,
            (false, true) => TunnelPath::Relay,
            (false, false) => TunnelPath::Idle,
        };
        Self {
            path,
            active_direct: direct.active_direct,
            active_relay: direct.active_relay,
            direct_sessions: direct.direct_sessions,
            relay_sessions: direct.relay_sessions,
            fallbacks: direct.fallbacks,
            last_fallback: direct.last_fallback,
            attempt: direct.attempt,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_usable_lease_counts_as_active_whatever_its_stage() {
        let status = |stage, active| PortMappingStatus {
            stage,
            network_generation: 0,
            local_port: None,
            gateway: None,
            protocol: None,
            available_protocols: Vec::new(),
            external_addr: None,
            active,
            lease_lifetime_ms: None,
            error: None,
        };
        assert_eq!(MappingState::of(&status(PortMappingStage::Failed, true)), MappingState::Active);
        assert_eq!(
            MappingState::of(&status(PortMappingStage::Renewing, false)),
            MappingState::Asking
        );
        assert_eq!(
            MappingState::of(&status(PortMappingStage::Expired, false)),
            MappingState::Failed
        );
    }

    #[test]
    fn current_paths_do_not_confuse_preferences_or_historical_success_with_liveness() {
        let auto = |counters: &PathDiagnostics| {
            PathStatus::observe(ConnectionPath::Auto, Some(counters.clone()))
        };
        assert_eq!(PathStatus::observe(ConnectionPath::Auto, None).path, TunnelPath::Idle);
        let mut counters = PathDiagnostics {
            direct_sessions: 3,
            fallbacks: 1,
            last_fallback: Some("udp_unavailable".into()),
            ..Default::default()
        };
        let idle = auto(&counters);
        assert_eq!(idle.path, TunnelPath::Idle, "completed direct traffic is not an active path");
        assert_eq!(idle.fallbacks, 1);
        counters.active_relay = 1;
        assert_eq!(auto(&counters).path, TunnelPath::Relay);
        counters.active_direct = 2;
        let mixed = auto(&counters);
        assert_eq!(
            (mixed.path, mixed.active_direct, mixed.active_relay),
            (TunnelPath::Mixed, 2, 1)
        );
        counters.active_relay = 0;
        assert_eq!(auto(&counters).path, TunnelPath::Direct);
        let relay_only = PathStatus::observe(ConnectionPath::RelayOnly, Some(counters));
        assert_eq!(relay_only.path, TunnelPath::RelayOnly);
        assert_eq!(relay_only.active_direct, 0, "a relay-only tunnel invents no counts");
    }
}
