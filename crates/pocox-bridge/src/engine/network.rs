//! HTTP owned by POCOX, separate from relay transports and hosted runtimes.
//!
//! Its proxy is the system's by default (the proxy environment variables,
//! else this computer's own setting; see [`system`]), none, or a custom URL.
use std::path::Path;
use std::time::Duration;

use anyhow::{bail, Context, Result};
pub use pocox_core::config::ProxyMode;
use reqwest::{ClientBuilder, Proxy, Url};

use super::config::{load_config, update_config};

mod system;
#[cfg(test)]
mod tests;

/// The saved proxy setting, for its editor only: the custom URL may carry
/// credentials.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProxySetting {
    /// The mode in effect.
    pub mode: ProxyMode,
    /// The custom proxy URL, kept while another mode is chosen.
    pub custom: Option<String>,
}

/// Where a route's proxy came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// The custom URL.
    Custom,
    /// `HTTPS_PROXY`, `ALL_PROXY` or `HTTP_PROXY`.
    Environment,
    /// This computer's proxy setting.
    System,
    /// No proxy: requests connect directly.
    Direct,
}

/// Where POCOX's own requests go now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Route {
    /// The proxy URL (it may carry credentials); none connects directly.
    pub proxy: Option<String>,
    /// Hosts that connect directly despite the proxy, besides loopback.
    pub bypass: Vec<String>,
    /// Where the proxy came from.
    pub source: Source,
}

impl Route {
    fn direct() -> Self {
        Self {
            proxy: None,
            bypass: Vec::new(),
            source: Source::Direct,
        }
    }
}

/// Read the saved setting.
pub fn setting(support: &Path) -> Result<ProxySetting> {
    let network = load_config(support)?.network;
    Ok(ProxySetting {
        mode: network.effective_mode(),
        custom: network.proxy,
    })
}

/// Validate before saving; failed edits leave the previous configuration
/// intact. `custom` (blank removes it) is kept whatever the mode, and is
/// required by [`ProxyMode::Custom`].
pub fn set_setting(support: &Path, mode: ProxyMode, custom: &str) -> Result<()> {
    let custom = normalize_proxy(custom)?;
    if mode == ProxyMode::Custom && custom.is_none() {
        bail!("a custom application proxy needs its URL");
    }
    update_config(support, |config| {
        config.network.mode = Some(mode);
        config.network.proxy = custom;
        Ok(())
    })
}

/// The route the saved setting gives requests now; the system's is read
/// again every time.
pub fn route(support: &Path) -> Result<Route> {
    let network = load_config(support)?.network;
    Ok(match (network.effective_mode(), network.proxy) {
        (ProxyMode::Custom, Some(proxy)) => Route {
            proxy: Some(proxy),
            bypass: Vec::new(),
            source: Source::Custom,
        },
        (ProxyMode::System, _) => system::detect().unwrap_or_else(Route::direct),
        (ProxyMode::Direct | ProxyMode::Custom, _) => Route::direct(),
    })
}

/// The system's proxy now (what [`ProxyMode::System`] uses), if any.
pub fn system_route() -> Option<Route> {
    system::detect()
}

/// `url` without its credentials, for display.
pub fn without_credentials(url: &str) -> String {
    match Url::parse(url) {
        Ok(mut parsed) => {
            let _ = parsed.set_username("");
            let _ = parsed.set_password(None);
            parsed.to_string().trim_end_matches('/').to_string()
        },
        Err(_) => String::new(),
    }
}

fn normalize_proxy(value: &str) -> Result<Option<String>> {
    let value = value.trim();
    if value.is_empty() {
        return Ok(None);
    }
    // Never attach a parser error or the input: either can contain credentials.
    let invalid = || anyhow::anyhow!("invalid application proxy URL");
    let url = Url::parse(value).map_err(|_| invalid())?;
    if value.chars().any(char::is_control)
        || !matches!(url.scheme(), "http" | "https" | "socks5" | "socks5h")
        || url.host_str().is_none()
        || url.port_or_known_default().is_none_or(|port| port == 0)
        || !matches!(url.path(), "" | "/")
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(invalid());
    }
    Proxy::all(value).map_err(|_| invalid())?;
    Ok(Some(url.to_string()))
}

/// A fresh builder reads the current setting (and the system's proxy), so
/// the next operation uses edits. Existing transfers keep their client. No
/// process environment is changed.
pub fn client(support: &Path) -> Result<ClientBuilder> {
    let route = route(support)?;
    builder(route.proxy.as_deref(), &route.bypass)
}

/// A builder going through `proxy` (directly without one), except for
/// loopback and `bypass`. Only the route decides: nothing else in the
/// environment is consulted.
fn builder(proxy: Option<&str>, bypass: &[String]) -> Result<ClientBuilder> {
    let builder = reqwest::Client::builder().use_rustls_tls().no_proxy();
    let Some(value) = normalize_proxy(proxy.unwrap_or_default())? else {
        return Ok(builder);
    };
    let mut direct = vec!["localhost".to_string(), "127.0.0.0/8".into(), "::1".into()];
    direct.extend(bypass.iter().cloned());
    let proxy = Proxy::all(socks5h(value))
        .map_err(|_| anyhow::anyhow!("invalid application proxy URL"))?
        .no_proxy(reqwest::NoProxy::from_string(&direct.join(",")));
    Ok(builder.proxy(proxy))
}

/// A SOCKS5 proxy resolves target names itself, `socks5://` included.
pub fn socks5h(url: String) -> String {
    url.strip_prefix("socks5://")
        .map(|rest| format!("socks5h://{rest}"))
        .unwrap_or(url)
}

/// Fetch an app-owned avatar or favicon through the same network policy.
/// Bound both transfer time and bytes before crossing the Flutter bridge.
pub async fn image(support: &Path, url: &str) -> Result<Vec<u8>> {
    let url = Url::parse(url).context("invalid image URL")?;
    if url.scheme() != "https" || !url.username().is_empty() || url.password().is_some() {
        bail!("images require an HTTPS URL without credentials");
    }
    let mut response = client(support)?
        .timeout(Duration::from_secs(20))
        .connect_timeout(Duration::from_secs(10))
        .build()?
        .get(url)
        .send()
        .await?
        .error_for_status()?;
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        if bytes.len() + chunk.len() > 2 * 1024 * 1024 {
            bail!("image exceeds 2 MiB");
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}
