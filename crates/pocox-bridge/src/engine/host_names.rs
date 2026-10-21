//! The one canonical identity of a local host instance.
//!
//! Relay keys (`ServiceId`) sanitize the instance name, so two spellings
//! that sanitize alike (`My Host`, `my-host`) are the same service on the
//! relay. Saved configuration, lifecycle leases and conflict checks all key
//! on that canonical form. The native host table keeps the trimmed name it
//! always used, so existing restore records and status rows are unchanged.

use anyhow::{bail, Result};
use pocox_core::service::sanitize_component;

/// The trimmed requested name, or `fallback` when none was given.
pub(super) fn requested(name: Option<&str>, fallback: &str) -> String {
    name.map(str::trim)
        .filter(|n| !n.is_empty())
        .unwrap_or(fallback)
        .to_string()
}

/// The canonical identity of `name`. A blank name would sanitize to the
/// default service name: it is refused rather than silently naming another
/// host.
pub(super) fn canonical(name: &str) -> Result<String> {
    if name.trim().is_empty() {
        bail!("an instance name is required");
    }
    Ok(sanitize_component(name))
}

/// Whether `a` and `b` name the same instance.
pub(super) fn same(a: &str, b: &str) -> bool {
    !a.trim().is_empty() && !b.trim().is_empty() && sanitize_component(a) == sanitize_component(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spellings_that_share_a_relay_key_are_one_instance() {
        assert_eq!(canonical(" My Host ").expect("name"), "my-host");
        assert!(same("My Host", "my-host"));
        assert!(!same("host-a", "host-b"));
        assert!(!same("", "default"), "a blank name is no instance");
        assert!(canonical("  ").is_err());
    }

    #[test]
    fn a_missing_name_takes_the_fallback() {
        assert_eq!(requested(None, "default"), "default");
        assert_eq!(requested(Some("  "), "opencode"), "opencode");
        assert_eq!(requested(Some(" mine "), "x"), "mine");
    }
}
