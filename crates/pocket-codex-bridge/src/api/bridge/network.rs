//! App-owned outbound network configuration and image reads.
use anyhow::Result;

use crate::engine::{network, runtime};

/// Saved proxy URL for the explicit editor; may contain credentials.
pub fn network_proxy() -> Result<Option<String>> {
    network::proxy(&runtime::support_dir()?)
}

/// Set an HTTP(S)/SOCKS5 proxy, or clear it with an empty string.
pub fn network_set_proxy(value: String) -> Result<()> {
    network::set_proxy(&runtime::support_dir()?, &value)
}

/// Bounded avatar/favicon download using POCOX's network configuration.
pub async fn network_image(url: String) -> Result<Vec<u8>> {
    let support = runtime::support_dir()?;
    runtime::runtime()
        .spawn(async move { network::image(&support, &url).await })
        .await?
}
