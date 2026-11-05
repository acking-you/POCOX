//! Who a request came from, for per-address limits.
//!
//! An address is one IPv4 address or one IPv6 /64, since a single host commonly
//! controls the whole prefix. Forwarding headers count only from an explicitly
//! configured proxy; a "trust any X-Forwarded-For" switch would let any client
//! choose its own limiter bucket.

use std::convert::Infallible;
use std::net::{IpAddr, SocketAddr};

use axum::extract::{ConnectInfo, FromRequestParts};
use axum::http::request::Parts;
use axum::http::HeaderMap;
use ipnet::IpNet;

/// The configured proxies.
#[derive(Debug, Clone, Default)]
pub struct TrustedProxies {
    nets: Vec<IpNet>,
}

impl TrustedProxies {
    /// Parse a list of IPs and CIDR ranges.
    pub fn parse(entries: &[String]) -> anyhow::Result<Self> {
        let mut nets = Vec::with_capacity(entries.len());
        for entry in entries {
            let entry = entry.trim();
            let net = match entry.parse::<IpNet>() {
                Ok(net) => net,
                Err(_) => IpNet::from(entry.parse::<IpAddr>().map_err(|_| {
                    anyhow::anyhow!("trusted_proxies entry `{entry}` is not an IP or CIDR range")
                })?),
            };
            nets.push(net);
        }
        Ok(Self {
            nets,
        })
    }

    fn contains(&self, ip: IpAddr) -> bool {
        self.nets.iter().any(|net| net.contains(&ip))
    }

    /// The client address of a request whose socket peer is `peer`.
    ///
    /// A trusted proxy overwrites `X-Forwarded-For`, so the last entry is the
    /// one it wrote. Anything else keeps the socket peer: an untrusted
    /// peer's header means nothing, and an unparsable one from a proxy is
    /// no reason to believe it.
    pub fn client_ip(&self, peer: IpAddr, headers: &HeaderMap) -> IpAddr {
        let peer = canonical(peer);
        if !self.contains(peer) {
            return peer;
        }
        headers
            .get("x-forwarded-for")
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.rsplit(',').next())
            .and_then(|last| last.trim().parse::<IpAddr>().ok())
            .map(canonical)
            .unwrap_or(peer)
    }
}

/// Fail startup on a proxy list with a typo in it.
pub(crate) fn validate_trusted_proxies(entries: &[String]) -> anyhow::Result<()> {
    TrustedProxies::parse(entries).map(|_| ())
}

/// An IPv4-mapped IPv6 address is that IPv4 address.
fn canonical(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map_or(ip, IpAddr::V4),
        v4 => v4,
    }
}

/// The bytes that identify an address for limiting: an IPv6 address collapses
/// to its /64.
pub fn address_bucket(ip: IpAddr) -> Vec<u8> {
    match canonical(ip) {
        IpAddr::V4(v4) => v4.octets().to_vec(),
        IpAddr::V6(v6) => v6.octets()[..8].to_vec(),
    }
}

/// A request's socket peer, as the accept loop annotated it. A request it did
/// not annotate shares one bucket with all others like it, which fails toward
/// limiting.
#[derive(Debug, Clone, Copy)]
pub(crate) struct PeerAddr(pub(crate) SocketAddr);

impl<S: Sync> FromRequestParts<S> for PeerAddr {
    type Rejection = Infallible;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Infallible> {
        let peer = parts
            .extensions
            .get::<ConnectInfo<SocketAddr>>()
            .map_or_else(|| SocketAddr::from(([0, 0, 0, 0], 0)), |ConnectInfo(addr)| *addr);
        Ok(Self(peer))
    }
}

#[cfg(test)]
mod tests {
    use axum::http::HeaderValue;

    use super::*;

    fn with_forwarded(value: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert("x-forwarded-for", HeaderValue::from_str(value).expect("header"));
        headers
    }

    #[test]
    fn only_a_configured_proxy_can_name_a_client() {
        let proxies =
            TrustedProxies::parse(&["10.0.0.0/8".into(), "192.0.2.1".into()]).expect("parse");
        let forged = with_forwarded("203.0.113.9");
        let outside: IpAddr = "198.51.100.7".parse().expect("ip");
        assert_eq!(proxies.client_ip(outside, &forged), outside, "an outsider's header is noise");
        let proxy: IpAddr = "10.1.2.3".parse().expect("ip");
        assert_eq!(
            proxies.client_ip(proxy, &with_forwarded("198.51.100.1, 203.0.113.9")),
            "203.0.113.9".parse::<IpAddr>().expect("ip"),
            "the proxy's own entry is the last one"
        );
        assert_eq!(proxies.client_ip(proxy, &with_forwarded("not-an-ip")), proxy);
        assert_eq!(proxies.client_ip(proxy, &HeaderMap::new()), proxy);
        assert!(TrustedProxies::parse(&["nonsense".into()]).is_err());
    }

    #[test]
    fn an_ipv6_host_is_one_bucket_across_its_slash_64() {
        let one: IpAddr = "2001:db8:1:2:aaaa::1".parse().expect("ip");
        let same_prefix: IpAddr = "2001:db8:1:2:bbbb::9".parse().expect("ip");
        let other_prefix: IpAddr = "2001:db8:1:3::1".parse().expect("ip");
        assert_eq!(address_bucket(one), address_bucket(same_prefix));
        assert_ne!(address_bucket(one), address_bucket(other_prefix));
        let mapped: IpAddr = "::ffff:192.0.2.1".parse().expect("ip");
        let plain: IpAddr = "192.0.2.1".parse().expect("ip");
        assert_eq!(address_bucket(mapped), address_bucket(plain));
    }
}
