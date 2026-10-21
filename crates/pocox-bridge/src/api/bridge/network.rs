//! App-owned outbound network configuration and image reads.
use anyhow::Result;

use crate::engine::{
    execution::{self, Lane},
    network, runtime,
};

/// Saved proxy URL for the explicit editor; may contain credentials.
pub async fn network_proxy() -> Result<Option<String>> {
    execution::run(Lane::Read, move || network::proxy(&runtime::support_dir()?)).await
}

/// Set an HTTP(S)/SOCKS5 proxy, or clear it with an empty string.
pub async fn network_set_proxy(value: String) -> Result<()> {
    execution::run(Lane::Read, move || network::set_proxy(&runtime::support_dir()?, &value)).await
}

/// Bounded avatar/favicon download using POCOX's network configuration.
pub async fn network_image(url: String) -> Result<Vec<u8>> {
    let support = runtime::support_dir()?;
    runtime::runtime()
        .spawn(async move { network::image(&support, &url).await })
        .await?
}
