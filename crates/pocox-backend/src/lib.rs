//! Hosted POCOX backend.
//!
//! An identity and credential-vending service, and nothing more. It:
//! - serves the GitHub-device-flow HTTP API ([`router`]) plus the per-account
//!   `/v1/me` + `/v1/services` views;
//! - vends each account a short-lived pb-mapper credential over `/v1/relay`
//!   ([`credentials`]), minted under the administrator key this process alone
//!   holds;
//! - serves pairing-code login when configured with a pairing secret
//!   ([`pairing`]): linked devices as users, with a relay key per device
//!   generation;
//! - terminates TLS in-process (plain / cert files / ACME).
//!
//! # It is not on the data path
//!
//! Clients take that credential and `register`/`connect` against the relay
//! **directly**. The backend used to tunnel every byte through a broker on its
//! own port, which cost an extra hop and made backend availability a
//! prerequisite for two of a user's own devices to talk. Now a device needs the
//! backend once per credential lifetime and never again.
//!
//! HTTP serving is exposed as library items so integration tests can drive it
//! over plain TCP.

#![forbid(unsafe_code)]

pub mod config;

mod api;
pub mod credentials;
pub mod pairing;
mod serve;
mod tls;

use std::sync::Arc;

pub use api::{router, AppState};
pub use config::{ServerConfig, TlsMode};
pub use credentials::Credentials;
use pocox_auth::Auth;
use pocox_store::Store;
pub use serve::ConnectionLimits;
use tokio::net::TcpListener;

/// Serve `router` over plain TCP through the real accept loop, forever. For
/// local testing; a deployment goes through [`run`].
///
/// `limits` is `None` with pairing off, when connections are served as they
/// always were.
pub async fn serve_plain(
    listener: TcpListener,
    router: axum::Router,
    limits: Option<ConnectionLimits>,
    trusted_proxies: pairing::TrustedProxies,
) {
    serve::serve_http(listener, router, tls::TlsKind::Plain, limits, trusted_proxies).await;
}

/// Hold the database for this process when pairing is on, or refuse to start.
/// Nothing is locked with pairing off, as before.
fn claim_database(store: &Store, pairing_enabled: bool) -> anyhow::Result<Option<std::fs::File>> {
    if pairing_enabled {
        Ok(store.lock_database()?)
    } else {
        Ok(None)
    }
}

/// Run the backend (the HTTP API over the configured TLS layer) until a fatal
/// error.
pub async fn run(cfg: ServerConfig) -> anyhow::Result<()> {
    let _ = rustls::crypto::ring::default_provider().install_default();

    let store = Store::connect(&cfg.database_url).await?;

    // Relay work is serialized by locks in this process, so a second process on
    // this database could undo a removal. Held until this function returns,
    // which is never.
    let _database_owner = claim_database(&store, cfg.pairing_secret.is_some())?;

    // Periodically purge expired device flows + refresh tokens so the tables
    // don't grow unbounded under device-flow churn / abandoned logins.
    let auth_store = store.clone();
    let purge_store = store.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(std::time::Duration::from_secs(3600));
        loop {
            tick.tick().await;
            let now = time::OffsetDateTime::now_utc().unix_timestamp();
            if let Err(e) = purge_store.purge_expired(now).await {
                tracing::warn!(error = %e, "periodic purge_expired failed");
            }
        }
    });

    // The web (authorization-code) flow's OAuth callback the backend hands to
    // GitHub — derived from the configured public URL, and enabled only when a
    // client secret is also present (Auth gates on both).
    let web_callback_url = cfg
        .public_url
        .as_deref()
        .map(|u| format!("{}/auth/web/callback", u.trim_end_matches('/')));
    let auth = Arc::new(Auth::new(auth_store, pocox_auth::Config {
        github_client_id: cfg.github_client_id.clone(),
        github_client_secret: cfg.github_client_secret.clone(),
        github_scope: cfg.github_scope.clone(),
        jwt_secret: cfg.jwt_secret.clone(),
        jwt_ttl_secs: cfg.jwt_ttl_secs,
        refresh_ttl_secs: cfg.refresh_ttl_secs,
        web_callback_url,
        pairing_secret: cfg.pairing_secret.clone(),
    })?);
    // Before anything is served: a changed key would make every derived code
    // disagree with what is stored, and hardware indexes use it too.
    auth.verify_pairing_key().await?;
    tracing::info!(
        web_login = auth.web_enabled(),
        pairing = auth.pairing_keys().is_some(),
        "auth flows configured"
    );
    // Validated at boot even though the SDK takes the address as a string: a
    // typo'd relay_addr should fail the process here, not surface later as a
    // per-tunnel connect error on a backend that looked healthy.
    pocox_pb::parse_relay_addr(&cfg.relay_addr)?;

    // The ADMINISTRATOR credential, which this process alone holds and never
    // hands out. Two uses, both administrative: minting the per-account
    // credentials clients do get, and acting on an account's whole relay view
    // (listing services across namespaces, retiring an abandoned registration).
    let relay = pocox_pb::RelaySession::new(
        cfg.relay_addr.clone(),
        cfg.relay_credential()
            .ok_or_else(|| anyhow::anyhow!("relay_credential is required"))?,
    );

    let tls = tls::build_tls(&cfg)?;
    let http_listener = TcpListener::bind(&cfg.http_listen)
        .await
        .map_err(|e| anyhow::anyhow!("binding http {}: {e}", cfg.http_listen))?;

    let pairing = match auth.pairing_keys() {
        Some(_) => {
            let service = pairing::Pairing::new(
                Arc::clone(&auth),
                store,
                relay.clone(),
                pairing::PairingSettings {
                    trusted_proxies: cfg.trusted_proxies.clone(),
                    ..pairing::PairingSettings::default()
                },
            )?;
            Arc::clone(&service).spawn_worker();
            Some(service)
        },
        None => None,
    };
    let app = api::router(AppState {
        auth,
        credentials: credentials::Credentials::new(relay.clone()),
        relay,
        pairing,
    });
    tracing::info!(
        http = %cfg.http_listen,
        relay = %cfg.relay_addr,
        tls = ?cfg.tls_mode,
        "pocox backend up"
    );

    let trusted_proxies = pairing::TrustedProxies::parse(&cfg.trusted_proxies)?;
    // Only pairing opens an anonymous surface. With it off, a GitHub-only backend
    // behind a proxy keeps serving connections as it always has.
    let limits = cfg.pairing_secret.is_some().then(ConnectionLimits::default);
    serve::serve_http(http_listener, app, tls, limits, trusted_proxies).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn pairing_claims_the_database_and_a_github_only_backend_does_not() {
        let dir = std::env::temp_dir().join(format!("pocox-owner-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("directory");
        let store = Store::connect(&format!("sqlite://{}", dir.join("backend.db").display()))
            .await
            .expect("store");

        assert!(claim_database(&store, false)
            .expect("nothing to claim")
            .is_none());
        let held = claim_database(&store, true)
            .expect("first")
            .expect("a file database");
        assert!(claim_database(&store, true).is_err(), "a second process refuses to start");
        assert!(claim_database(&store, false)
            .expect("github only")
            .is_none());
        drop(held);
        assert!(claim_database(&store, true).expect("free again").is_some());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
