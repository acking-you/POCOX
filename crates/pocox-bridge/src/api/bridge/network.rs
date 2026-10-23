//! App-owned outbound network configuration and image reads.
use std::path::Path;

use anyhow::Result;
use pocox_core::config::ConnectionPath;

use crate::engine::execution::{self, Lane};
use crate::engine::{config, network, runtime};

/// Outgoing path preference for new subscriptions, mirrored for Dart.
pub enum ConnectionPathDto {
    /// Every new subscription uses the relay (the default).
    RelayOnly,
    /// Direct first, with the SDK's pre-commit relay fallback.
    Auto,
}

impl From<ConnectionPath> for ConnectionPathDto {
    fn from(path: ConnectionPath) -> Self {
        match path {
            ConnectionPath::RelayOnly => Self::RelayOnly,
            ConnectionPath::Auto => Self::Auto,
        }
    }
}

impl From<ConnectionPathDto> for ConnectionPath {
    fn from(path: ConnectionPathDto) -> Self {
        match path {
            ConnectionPathDto::RelayOnly => Self::RelayOnly,
            ConnectionPathDto::Auto => Self::Auto,
        }
    }
}

/// Preferences captured when a new network tunnel is created.
pub struct RelayPreferencesDto {
    /// Path preference for new subscriptions.
    pub path: ConnectionPathDto,
    /// Allow direct setup for new local service registrations.
    pub allow_direct: bool,
}

/// Read this installation's relay preferences, shared by both account modes.
pub async fn relay_preferences() -> Result<RelayPreferencesDto> {
    execution::run(Lane::Read, move || {
        let saved = config::load_config(&runtime::support_dir()?)?.pb_mapper;
        Ok(RelayPreferencesDto {
            path: saved.path.into(),
            allow_direct: saved.allow_direct,
        })
    })
    .await
}

/// Save preferences for new tunnels. Existing connections and hosts keep
/// theirs.
pub async fn relay_set_preferences(preferences: RelayPreferencesDto) -> Result<()> {
    execution::run(Lane::Read, move || {
        save_relay_preferences(&runtime::support_dir()?, preferences)
    })
    .await
}

fn save_relay_preferences(support: &Path, preferences: RelayPreferencesDto) -> Result<()> {
    config::update_config(support, |config| {
        config.pb_mapper.path = preferences.path.into();
        config.pb_mapper.allow_direct = preferences.allow_direct;
        Ok(())
    })
}

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relay_preferences_preserve_credentials() {
        let support = tempfile::tempdir().expect("support dir");
        config::update_config(support.path(), |saved| {
            saved.account.token = Some("account-token".into());
            saved.pb_mapper.key = Some("relay-key".into());
            Ok(())
        })
        .expect("initial config");
        save_relay_preferences(support.path(), RelayPreferencesDto {
            path: ConnectionPathDto::Auto,
            allow_direct: true,
        })
        .expect("save preferences");
        let saved = config::load_config(support.path()).expect("read config");
        assert_eq!(saved.pb_mapper.path, ConnectionPath::Auto);
        assert!(saved.pb_mapper.allow_direct);
        assert_eq!(saved.pb_mapper.key.as_deref(), Some("relay-key"));
        assert_eq!(saved.account.token.as_deref(), Some("account-token"));
    }
}
