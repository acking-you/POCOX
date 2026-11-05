//! Bounded per-address counters and the charges against them.
//!
//! An attempt is charged atomically before any expensive work, so concurrent
//! guesses cannot outrun the limit, and per-address first, so an attempt that
//! limit refuses cannot drain a backend-wide budget. Keys are keyed hashes of
//! an address bucket: no raw address or code ever reaches this state.

use std::collections::HashMap;
use std::sync::Mutex;

/// Longest any counter is kept.
const MAX_WINDOW_SECS: i64 = 24 * 3600;

/// One limit: `count` per `window_secs`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rate {
    /// Attempts allowed.
    pub count: i64,
    /// The window.
    pub window_secs: i64,
}

impl Rate {
    const fn new(count: i64, window_secs: i64) -> Self {
        Self {
            count,
            window_secs,
        }
    }
}

/// Admission limits. Initial values, not measured.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PairingLimits {
    /// Code checks per address (`preview`, `link`, `restore`), with growing
    /// backoff.
    pub code_checks_per_address: Rate,
    /// Code checks across the backend.
    pub code_checks_backend: Rate,
    /// New devices per address.
    pub new_devices_per_address: Rate,
    /// New devices across the backend.
    pub new_devices_backend: Rate,
    /// First relay keys per address.
    pub first_keys_per_address: Rate,
    /// First relay keys across the backend.
    pub first_keys_backend: Rate,
    /// Recovery requests across the backend.
    pub restore_requests_backend: Rate,
    /// Pairing requests handled at once.
    pub concurrent_requests: usize,
    /// Relay grants in flight at once.
    pub concurrent_grants: usize,
    /// Counters held per limit before refusing new addresses.
    pub limiter_entries: usize,
}

impl Default for PairingLimits {
    fn default() -> Self {
        Self {
            code_checks_per_address: Rate::new(5, 600),
            code_checks_backend: Rate::new(100, 1),
            new_devices_per_address: Rate::new(20, 3600),
            new_devices_backend: Rate::new(1000, 3600),
            first_keys_per_address: Rate::new(10, 3600),
            first_keys_backend: Rate::new(1000, 3600),
            restore_requests_backend: Rate::new(1000, 3600),
            concurrent_requests: 256,
            concurrent_grants: 16,
            limiter_entries: 100_000,
        }
    }
}

/// One address's position in its current window.
#[derive(Debug, Clone, Copy)]
struct Slot {
    window_start: i64,
    used: i64,
    /// Doublings applied to the window, for limits that back off.
    penalty: u32,
}

/// A fixed-window counter per keyed address hash, bounded in memory.
#[derive(Debug)]
pub struct AddressLimiter {
    rate: Rate,
    backs_off: bool,
    max_entries: usize,
    slots: Mutex<HashMap<[u8; 16], Slot>>,
}

impl AddressLimiter {
    /// A limiter at a fixed `rate`.
    pub fn new(rate: Rate, max_entries: usize) -> Self {
        Self {
            rate,
            backs_off: false,
            max_entries,
            slots: Mutex::new(HashMap::new()),
        }
    }

    /// A limiter whose window doubles each time it is exhausted, up to a day.
    pub fn with_backoff(rate: Rate, max_entries: usize) -> Self {
        Self {
            backs_off: true,
            ..Self::new(rate, max_entries)
        }
    }

    fn window_of(&self, slot: &Slot) -> i64 {
        let doubled = self
            .rate
            .window_secs
            .saturating_mul(1i64 << slot.penalty.min(16));
        doubled.min(MAX_WINDOW_SECS)
    }

    /// When a counter may be forgotten. One that backs off outlives its window
    /// by another window, so a returning guesser still meets the longer
    /// wait. Never past a day.
    fn forget_at(&self, slot: &Slot) -> i64 {
        let window = self.window_of(slot);
        let kept = if self.backs_off { window.saturating_mul(2) } else { window };
        slot.window_start + kept.min(MAX_WINDOW_SECS)
    }

    /// Drop every counter past its time. The worker calls this, so counters
    /// expire within a day even on an idle backend.
    pub fn expire(&self, now: i64) {
        let mut slots = self.slots.lock().expect("limiter lock");
        slots.retain(|_, slot| self.forget_at(slot) > now);
    }

    /// Charge one attempt. `Err` carries the seconds to wait.
    ///
    /// When the table is full of live counters a new address is refused rather
    /// than evicting one: eviction would reset a limit for whoever floods
    /// the table.
    pub fn charge(&self, key: [u8; 16], now: i64) -> Result<(), u64> {
        let mut slots = self.slots.lock().expect("limiter lock");
        if !slots.contains_key(&key) && slots.len() >= self.max_entries {
            slots.retain(|_, slot| self.forget_at(slot) > now);
            if slots.len() >= self.max_entries {
                return Err(60);
            }
        }
        let slot = slots.entry(key).or_insert(Slot {
            window_start: now,
            used: 0,
            penalty: 0,
        });
        if now >= slot.window_start + self.window_of(slot) {
            slot.penalty =
                if self.backs_off && slot.used >= self.rate.count { slot.penalty + 1 } else { 0 };
            slot.window_start = now;
            slot.used = 0;
        }
        if slot.used >= self.rate.count {
            let remaining = slot.window_start + self.window_of(slot) - now;
            return Err(u64::try_from(remaining).unwrap_or(1).max(1));
        }
        slot.used += 1;
        Ok(())
    }

    /// Give back one charge: the attempt turned out to prove a valid code.
    pub fn refund(&self, key: [u8; 16]) {
        let mut slots = self.slots.lock().expect("limiter lock");
        if let Some(slot) = slots.get_mut(&key) {
            slot.used = (slot.used - 1).max(0);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: [u8; 16] = [1; 16];

    #[test]
    fn an_address_is_limited_and_a_refund_restores_one_attempt() {
        let limiter = AddressLimiter::new(Rate::new(2, 600), 10);
        assert_eq!(limiter.charge(KEY, 0), Ok(()));
        assert_eq!(limiter.charge(KEY, 1), Ok(()));
        assert_eq!(limiter.charge(KEY, 2), Err(598));
        limiter.refund(KEY);
        assert_eq!(limiter.charge(KEY, 3), Ok(()));
        assert_eq!(limiter.charge([2; 16], 3), Ok(()), "another address has its own count");
        assert_eq!(limiter.charge(KEY, 600), Ok(()), "a new window");
    }

    #[test]
    fn exhausting_a_limit_grows_its_window() {
        let limiter = AddressLimiter::with_backoff(Rate::new(1, 100), 10);
        assert_eq!(limiter.charge(KEY, 0), Ok(()));
        assert_eq!(limiter.charge(KEY, 1), Err(99));
        assert_eq!(limiter.charge(KEY, 100), Ok(()), "the first window ended");
        assert_eq!(limiter.charge(KEY, 101), Err(199), "the next one is twice as long");
    }

    #[test]
    fn a_full_table_refuses_new_addresses_without_resetting_live_ones() {
        let limiter = AddressLimiter::new(Rate::new(1, 100), 1);
        assert_eq!(limiter.charge(KEY, 0), Ok(()));
        assert_eq!(limiter.charge([2; 16], 1), Err(60), "no room while the entry is live");
        assert_eq!(limiter.charge(KEY, 2), Err(98), "and the live count survives");
        assert_eq!(limiter.charge([2; 16], 100), Ok(()), "an expired entry makes room");
    }

    #[test]
    fn counters_are_forgotten_within_a_day_but_backoff_survives_its_window() {
        let limiter = AddressLimiter::with_backoff(Rate::new(1, 100), 10);
        assert_eq!(limiter.charge(KEY, 0), Ok(()));
        assert_eq!(limiter.charge(KEY, 1), Err(99));
        limiter.expire(150);
        assert_eq!(limiter.charge(KEY, 150), Ok(()));
        assert_eq!(limiter.charge(KEY, 151), Err(199), "the longer wait is still remembered");
        limiter.expire(MAX_WINDOW_SECS + 151);
        assert!(limiter.slots.lock().expect("lock").is_empty());
    }
}
