//! The one spelling of a backend's address that keys its device store.

use anyhow::{bail, Context, Result};
use url::{Host, Url};

/// A backend's origin and base path in one canonical spelling.
///
/// Different spellings of one backend share a device store, and different base
/// paths never do. Only `https://` qualifies, plus `http://` to a loopback
/// address, so a device secret cannot leave this computer in cleartext.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CanonicalBackend(String);

impl CanonicalBackend {
    /// Canonicalize `url`, refusing anything that could send a secret somewhere
    /// its spelling does not plainly say.
    pub fn parse(url: &str) -> Result<Self> {
        let parsed = Url::parse(url.trim()).context("the backend address is not a URL")?;
        match parsed.scheme() {
            "https" => {},
            "http" if is_loopback(&parsed) => {},
            "http" => bail!("the backend address must use https://"),
            other => bail!("the backend address must use https://, not {other}://"),
        }
        if parsed.host().is_none() {
            bail!("the backend address has no host");
        }
        if !parsed.username().is_empty() || parsed.password().is_some() {
            bail!("the backend address must not carry credentials");
        }
        if parsed.query().is_some() || parsed.fragment().is_some() {
            bail!("the backend address must not carry a query or fragment");
        }
        // `Url` already lowercased the host, dropped a default port and resolved
        // dot segments. Case in the path stays significant, and only the
        // trailing slash of a base path is spelling.
        Ok(Self(parsed.as_str().trim_end_matches('/').to_string()))
    }

    /// The canonical address, with no trailing slash.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

fn is_loopback(url: &Url) -> bool {
    match url.host() {
        Some(Host::Domain(domain)) => domain.eq_ignore_ascii_case("localhost"),
        Some(Host::Ipv4(address)) => address.is_loopback(),
        Some(Host::Ipv6(address)) => address.is_loopback(),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spellings_of_one_backend_agree_and_paths_stay_apart() {
        let canonical = |url: &str| CanonicalBackend::parse(url).expect(url).0;
        let plain = canonical("https://Lb7666.TOP:8443");
        assert_eq!(plain, "https://lb7666.top:8443");
        assert_eq!(canonical("https://lb7666.top:8443/"), plain);
        assert_eq!(canonical("https://example.com:443"), "https://example.com");
        assert_ne!(canonical("https://example.com/a"), canonical("https://example.com/b"));
        assert_ne!(canonical("https://example.com/a"), canonical("https://example.com/A"));
        assert_ne!(canonical("https://example.com/a"), canonical("https://example.com"));
    }

    #[test]
    fn nothing_that_could_misdirect_a_secret_is_accepted() {
        for url in [
            "http://example.com",
            "ftp://example.com",
            "https://user:pass@example.com",
            "https://example.com?next=https://evil.example",
            "https://example.com#fragment",
            "not a url",
        ] {
            assert!(CanonicalBackend::parse(url).is_err(), "{url}");
        }
        for url in ["http://127.0.0.1:8080", "http://[::1]:8080", "http://localhost:8080"] {
            assert!(CanonicalBackend::parse(url).is_ok(), "{url}");
        }
    }
}
