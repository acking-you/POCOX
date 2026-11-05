//! Pairing's fixed values, gathered so tests can shorten them. Only the trusted
//! proxy list is an operator setting; these are initial values, not measured.

use std::time::Duration;

use super::limits::PairingLimits;

/// How long a normal secret replacement's overlap lasts. Fixed by design.
const SECRET_OVERLAP_SECS: i64 = 600;

/// Everything a [`super::Pairing`] is built with.
#[derive(Debug, Clone)]
pub struct PairingSettings {
    /// Addresses whose forwarding headers are believed, as IPs or CIDR ranges.
    /// Each must have restricted ingress and overwrite those headers.
    pub trusted_proxies: Vec<String>,
    /// A normal secret replacement's fixed overlap.
    pub overlap_secs: i64,
    /// Key lifetime in a linked group.
    pub linked_key_ttl: Duration,
    /// Key lifetime for a single-device group, so an abandoned device returns
    /// its slot quickly.
    pub single_key_ttl: Duration,
    /// Pairing keys' share of relay capacity, in percent.
    pub capacity_share_percent: u64,
    /// The largest group.
    pub max_group_size: i64,
    /// Pending recovery requests per target.
    pub restore_slots: i64,
    /// Retakes allowed per device per window.
    pub retake_limit: i64,
    /// The retake window.
    pub retake_window_secs: i64,
    /// Admission limits.
    pub limits: PairingLimits,
    /// How long a request waits for relay work before answering pending.
    pub foreground_wait: Duration,
    /// How often the worker retries open operations.
    pub reconcile_interval: Duration,
    /// How often the worker compares the relay's key table with the database.
    pub sweep_interval: Duration,
    /// How long a cached relay status is believed where a stale one cannot
    /// harm.
    pub relay_status_ttl: Duration,
}

impl Default for PairingSettings {
    fn default() -> Self {
        Self {
            trusted_proxies: Vec::new(),
            overlap_secs: SECRET_OVERLAP_SECS,
            linked_key_ttl: Duration::from_secs(24 * 3600),
            single_key_ttl: Duration::from_secs(3600),
            capacity_share_percent: 50,
            max_group_size: 64,
            restore_slots: 3,
            retake_limit: 3,
            retake_window_secs: 24 * 3600,
            limits: PairingLimits::default(),
            foreground_wait: Duration::from_secs(5),
            reconcile_interval: Duration::from_secs(15),
            sweep_interval: Duration::from_secs(300),
            relay_status_ttl: Duration::from_secs(30),
        }
    }
}
