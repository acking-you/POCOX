//! The system's proxy, as this computer's other programs see it: the proxy
//! environment variables first (as curl reads them for HTTPS), else the
//! operating system's own setting: Windows' Internet Settings (Settings ›
//! Network › Proxy, which proxy tools such as Clash set) or macOS' network
//! proxies. Linux and phones have no setting beyond the environment, and
//! automatic configuration scripts (PAC) are not evaluated. Read again for
//! every client, so a change applies to the next request.

use super::{Route, Source};

/// The system's proxy now, if any.
pub(super) fn detect() -> Option<Route> {
    from_environment(|name| std::env::var(name).ok()).or_else(|| {
        let (proxy, bypass) = platform()?;
        Some(Route {
            proxy: Some(proxy),
            bypass,
            source: Source::System,
        })
    })
}

/// The proxy the environment names, with `NO_PROXY` as its bypass list.
pub(super) fn from_environment(var: impl Fn(&str) -> Option<String>) -> Option<Route> {
    let first = |names: &[&str]| {
        names
            .iter()
            .filter_map(|name| var(name))
            .map(|value| value.trim().to_string())
            .find(|value| !value.is_empty())
    };
    let proxy = first(&[
        "HTTPS_PROXY",
        "https_proxy",
        "ALL_PROXY",
        "all_proxy",
        "HTTP_PROXY",
        "http_proxy",
    ])?;
    let bypass = first(&["NO_PROXY", "no_proxy"])
        .map(|list| hosts(list.split(',')))
        .unwrap_or_default();
    Some(Route {
        proxy: Some(with_scheme(&proxy, "http")),
        bypass,
        source: Source::Environment,
    })
}

/// `value` with `scheme://` unless it names one.
fn with_scheme(value: &str, scheme: &str) -> String {
    if value.contains("://") {
        value.to_string()
    } else {
        format!("{scheme}://{value}")
    }
}

/// Bypass entries as the HTTP client takes them: `*.example.com` becomes
/// `example.com` (itself and its subdomains); Windows' `<local>` (names
/// without a dot) is left out, since requests here name public hosts.
fn hosts<'a>(entries: impl Iterator<Item = &'a str>) -> Vec<String> {
    entries
        .map(str::trim)
        .filter(|entry| !entry.is_empty() && !entry.eq_ignore_ascii_case("<local>"))
        .map(|entry| entry.trim_start_matches("*.").to_string())
        .collect()
}

/// Windows' `ProxyServer`: one `host:port` for every protocol, or
/// per-protocol `https=…;http=…;socks=…` entries, of which HTTPS is taken
/// first, then HTTP, then SOCKS.
#[cfg(any(windows, test))]
pub(super) fn windows_server(value: &str) -> Option<String> {
    let value = value.trim();
    if value.is_empty() {
        return None;
    }
    if !value.contains('=') {
        return Some(with_scheme(value, "http"));
    }
    let entry = |protocol: &str| {
        value.split(';').find_map(|entry| {
            let (name, address) = entry.split_once('=')?;
            (name.trim().eq_ignore_ascii_case(protocol) && !address.trim().is_empty())
                .then(|| address.trim().to_string())
        })
    };
    entry("https")
        .or_else(|| entry("http"))
        .map(|address| with_scheme(&address, "http"))
        .or_else(|| entry("socks").map(|address| with_scheme(&address, "socks5h")))
}

/// Windows' proxy setting: its proxy URL and the hosts that bypass it.
#[cfg(windows)]
fn platform() -> Option<(String, Vec<String>)> {
    let settings = windows_registry::CURRENT_USER
        .open("Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings")
        .ok()?;
    if settings.get_u32("ProxyEnable").unwrap_or(0) == 0 {
        return None;
    }
    let proxy = windows_server(&settings.get_string("ProxyServer").ok()?)?;
    let bypass = settings
        .get_string("ProxyOverride")
        .map(|list| hosts(list.split(';')))
        .unwrap_or_default();
    Some((proxy, bypass))
}

/// macOS' network proxies (System Settings › Network › Proxies), HTTPS
/// first, then HTTP, then SOCKS, with no bypass hosts: its exceptions list
/// is not read; loopback always connects directly.
#[cfg(target_os = "macos")]
fn platform() -> Option<(String, Vec<String>)> {
    use system_configuration::core_foundation::number::CFNumber;
    use system_configuration::core_foundation::string::CFString;
    use system_configuration::dynamic_store::SCDynamicStoreBuilder;

    let proxies = SCDynamicStoreBuilder::new("pocox").build()?.get_proxies()?;
    let number = |key: &'static str| {
        proxies
            .find(CFString::from_static_string(key))?
            .downcast::<CFNumber>()?
            .to_i32()
    };
    let text = |key: &'static str| {
        Some(
            proxies
                .find(CFString::from_static_string(key))?
                .downcast::<CFString>()?
                .to_string(),
        )
    };
    // The dynamic store's enable, host and port keys, and each one's scheme.
    let servers = [
        ("HTTPSEnable", "HTTPSProxy", "HTTPSPort", "http"),
        ("HTTPEnable", "HTTPProxy", "HTTPPort", "http"),
        ("SOCKSEnable", "SOCKSProxy", "SOCKSPort", "socks5h"),
    ];
    let proxy = servers
        .into_iter()
        .find_map(|(enable, host, port, scheme)| {
            if number(enable) != Some(1) {
                return None;
            }
            let host = text(host).filter(|host| !host.is_empty())?;
            Some(match number(port) {
                Some(port) => format!("{scheme}://{host}:{port}"),
                None => format!("{scheme}://{host}"),
            })
        })?;
    Some((proxy, Vec::new()))
}

/// Linux and phones have no proxy setting beyond the environment.
#[cfg(not(any(windows, target_os = "macos")))]
fn platform() -> Option<(String, Vec<String>)> {
    None
}
