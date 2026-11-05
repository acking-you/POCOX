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
    /// Checks that proved a valid code, per address. These refund the limit
    /// above, so they need their own or one address could spend the
    /// backend's budget for free.
    pub valid_codes_per_address: Rate,
    /// New devices per address.
    pub new_devices_per_address: Rate,
    /// New devices across the backend.
    pub new_devices_backend: Rate,
    /// First relay keys per address.
    pub first_keys_per_address: Rate,
    /// First relay keys across the backend.
    pub first_keys_backend: Rate,
    /// Keys for a device that moved, per address.
    pub key_regrants_per_address: Rate,
    /// Keys for a device that moved, across the backend. Renewing an existing
    /// key, or replacing one that merely ended, is outside this budget.
    pub key_regrants_backend: Rate,
    /// Attempts at a key per device, whatever kept the last one from sticking.
    pub key_grants_per_device: Rate,
    /// Namespaces allocated across the backend.
    pub namespace_allocations_backend: Rate,
    /// Links, leaves, removals and restores per device.
    pub moves_per_device: Rate,
    /// Links and restores per address. A removal or leave is not limited by
    /// address, so whoever shares yours cannot stop you removing an
    /// intruder.
    pub moves_per_address: Rate,
    /// Links owing relay work, across the backend. Nothing else draws from
    /// this, so spending it cannot stop a removal, a leave or a recovery.
    pub moves_backend: Rate,
    /// Service deregistrations per device.
    pub deregistrations_per_device: Rate,
    /// Service deregistrations per address.
    pub deregistrations_per_address: Rate,
    /// Service retirements reaching the relay, across the backend.
    pub deregistrations_backend: Rate,
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
            valid_codes_per_address: Rate::new(60, 600),
            new_devices_per_address: Rate::new(20, 3600),
            new_devices_backend: Rate::new(1000, 3600),
            first_keys_per_address: Rate::new(10, 3600),
            first_keys_backend: Rate::new(1000, 3600),
            key_regrants_per_address: Rate::new(120, 3600),
            key_regrants_backend: Rate::new(3600, 3600),
            key_grants_per_device: Rate::new(30, 3600),
            namespace_allocations_backend: Rate::new(1000, 3600),
            moves_per_device: Rate::new(20, 3600),
            moves_per_address: Rate::new(60, 3600),
            moves_backend: Rate::new(1000, 3600),
            deregistrations_per_device: Rate::new(30, 600),
            deregistrations_per_address: Rate::new(60, 600),
            deregistrations_backend: Rate::new(600, 600),
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

    /// Give back one charge. A counter with nothing left on it goes, or free
    /// refused attempts from new addresses would fill the table and lock
    /// everyone else out.
    pub fn refund(&self, key: [u8; 16]) {
        let mut slots = self.slots.lock().expect("limiter lock");
        if let Some(slot) = slots.get_mut(&key) {
            slot.used = (slot.used - 1).max(0);
            if slot.used == 0 && slot.penalty == 0 {
                slots.remove(&key);
            }
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
    fn a_refund_leaves_nothing_behind_that_could_fill_the_table() {
        let limiter = AddressLimiter::new(Rate::new(2, 100), 1);
        assert_eq!(limiter.charge(KEY, 0), Ok(()));
        limiter.refund(KEY);
        assert_eq!(limiter.charge([2; 16], 1), Ok(()), "the refunded address left no entry");

        // One that has been backed off keeps its entry, or a refund would forgive it.
        let limiter = AddressLimiter::with_backoff(Rate::new(1, 100), 10);
        assert_eq!(limiter.charge(KEY, 0), Ok(()));
        assert_eq!(limiter.charge(KEY, 100), Ok(()));
        assert_eq!(limiter.charge(KEY, 101), Err(199));
        assert_eq!(limiter.charge(KEY, 300), Ok(()));
        limiter.refund(KEY);
        assert_eq!(limiter.charge(KEY, 301), Ok(()));
        assert_eq!(limiter.charge(KEY, 302), Err(398), "the longer window still stands");
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
