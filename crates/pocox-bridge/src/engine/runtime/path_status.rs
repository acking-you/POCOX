use pocox_core::config::ConnectionPath;
use pocox_pb::{PathDiagnostics, TunnelDiagnostics};

/// A local SDK observation, never inferred from the configured preference.
#[derive(Debug, Clone)]
pub struct PathStatus {
    /// `relay_only`, `idle`, `direct`, `relay`, `mixed`, or `unknown`.
    pub path: String,
    /// Number of currently active direct data connections.
    pub active_direct: u64,
    /// Number of currently active relay data connections tracked by auto mode.
    pub active_relay: u64,
    /// Pre-commit fallbacks observed during this tunnel's lifetime.
    pub fallbacks: u64,
    /// SDK diagnostic reason for the most recent fallback, if any.
    pub last_fallback: Option<String>,
}

impl Default for PathStatus {
    fn default() -> Self {
        Self {
            path: "unknown".into(),
            active_direct: 0,
            active_relay: 0,
            fallbacks: 0,
            last_fallback: None,
        }
    }
}

impl PathStatus {
    pub(super) fn observe(policy: ConnectionPath, diagnostics: TunnelDiagnostics) -> Self {
        Self::from_counters(policy, diagnostics.direct)
    }

    fn from_counters(policy: ConnectionPath, direct: Option<PathDiagnostics>) -> Self {
        if policy == ConnectionPath::RelayOnly {
            return Self {
                path: "relay_only".into(),
                ..Self::default()
            };
        }
        let Some(direct) = direct else {
            return Self {
                path: "idle".into(),
                ..Self::default()
            };
        };
        let path = match (direct.active_direct > 0, direct.active_relay > 0) {
            (true, true) => "mixed",
            (true, false) => "direct",
            (false, true) => "relay",
            (false, false) => "idle",
        };
        Self {
            path: path.into(),
            active_direct: direct.active_direct,
            active_relay: direct.active_relay,
            fallbacks: direct.fallbacks,
            last_fallback: direct.last_fallback,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_paths_do_not_confuse_preferences_or_historical_success_with_liveness() {
        assert_eq!(PathStatus::from_counters(ConnectionPath::Auto, None).path, "idle");
        let mut counters = PathDiagnostics {
            direct_sessions: 3,
            fallbacks: 1,
            last_fallback: Some("udp_unavailable".into()),
            ..Default::default()
        };
        let idle = PathStatus::from_counters(ConnectionPath::Auto, Some(counters.clone()));
        assert_eq!(idle.path, "idle", "completed direct traffic is not an active path");
        assert_eq!(idle.fallbacks, 1);
        counters.active_relay = 1;
        assert_eq!(
            PathStatus::from_counters(ConnectionPath::Auto, Some(counters.clone())).path,
            "relay"
        );
        counters.active_direct = 2;
        let mixed = PathStatus::from_counters(ConnectionPath::Auto, Some(counters.clone()));
        assert_eq!((mixed.path.as_str(), mixed.active_direct, mixed.active_relay), ("mixed", 2, 1));
        counters.active_relay = 0;
        assert_eq!(PathStatus::from_counters(ConnectionPath::Auto, Some(counters)).path, "direct");
        assert_eq!(PathStatus::from_counters(ConnectionPath::RelayOnly, None).path, "relay_only");
    }
}
