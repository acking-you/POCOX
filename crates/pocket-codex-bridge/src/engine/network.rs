//! HTTP owned by POCOX, separate from relay transports and hosted runtimes.
use std::{path::Path, time::Duration};

use anyhow::{bail, Context, Result};
use reqwest::{ClientBuilder, Proxy, Url};

use super::config::{load_config, update_config};

#[cfg(test)]
mod tests;

/// Read the saved URL only for the explicit proxy editor.
pub fn proxy(support: &Path) -> Result<Option<String>> {
    Ok(load_config(support)?.network.proxy)
}

/// Validate before saving; failed edits leave the previous configuration
/// intact.
pub fn set_proxy(support: &Path, value: &str) -> Result<()> {
    let value = normalize_proxy(value)?;
    update_config(support, |config| {
        config.network.proxy = value;
        Ok(())
    })
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

/// A fresh builder reads the current setting, so the next operation uses edits.
/// Existing transfers keep their client. No process environment is changed.
pub fn client(support: &Path) -> Result<ClientBuilder> {
    let saved = proxy(support)?;
    builder(saved.as_deref())
}

fn builder(value: Option<&str>) -> Result<ClientBuilder> {
    let mut builder = reqwest::Client::builder().use_rustls_tls();
    if let Some(value) = normalize_proxy(value.unwrap_or_default())? {
        // Resolve target names at the SOCKS server, including for socks5://.
        let value = value
            .strip_prefix("socks5://")
            .map(|rest| format!("socks5h://{rest}"))
            .unwrap_or(value);
        let proxy = Proxy::all(value)
            .map_err(|_| anyhow::anyhow!("invalid application proxy URL"))?
            .no_proxy(reqwest::NoProxy::from_string("localhost,127.0.0.0/8,::1"));
        builder = builder.no_proxy().proxy(proxy);
    }
    Ok(builder)
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
