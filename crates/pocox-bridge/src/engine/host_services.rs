//! Hosting operations shared by native Codex and ACP hosts: the host-global
//! meta stores, loopback listeners and supervision of in-process services,
//! and relay publication of a local service.
//!
//! ```text
//! serve (native Codex) ─┐
//!                       ├─► host_services ─► relay (pb-mapper) / meta stores
//! serve_acp (ACP)  ─────┘
//! ```
//!
//! Each provider keeps its own host table and lifecycle; only these
//! provider-neutral steps are shared.

use std::{
    net::SocketAddr,
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{bail, Context, Result};
use once_cell::sync::OnceCell;
use pocox_core::service::{ServiceId, ServiceKind};
use pocox_pb::{publish_pending, PublishError, Published, RegisterOptions};

use crate::engine::{runtime, transport::Transport};

/// Upper bound on the backoff between repeated failed restarts.
pub(super) const MAX_RESTART_BACKOFF: Duration = Duration::from_secs(300);

/// The process-global per-thread config store, shared by every local meta
/// service: all hosts on this machine share one `CODEX_HOME` and therefore one
/// config map, so they must write through one serialized store. Opened once,
/// lazily, and the success cached; a store-open failure (an unresolvable /
/// unwritable `CODEX_HOME`) is returned as an `Err` for the caller to surface
/// as a hosting error rather than panicking the process (the bridge builds with
/// `panic = "abort"`, so an `expect` here would take the whole app down).
pub(super) fn config_store() -> Result<Arc<pocox_host_svc::store::ConfigStore>> {
    static STORE: OnceCell<Arc<pocox_host_svc::store::ConfigStore>> = OnceCell::new();
    STORE
        .get_or_try_init(|| -> Result<Arc<pocox_host_svc::store::ConfigStore>> {
            // Co-locate the config store with the sessions it annotates (under
            // CODEX_HOME) so every host on this machine shares one map.
            let path = pocox_host_svc::store::default_db_path()?;
            let store = runtime::runtime()
                .block_on(pocox_host_svc::store::ConfigStore::open(path))
                .context("opening the host meta config store")?;
            Ok(Arc::new(store))
        })
        .map(Arc::clone)
}

/// The process-wide host-config store (project roots + default project), opened
/// once and shared by every host — like [`config_store`], co-located under
/// CODEX_HOME so all hosts on this machine share one host config.
pub(super) fn host_store() -> Result<Arc<pocox_host_svc::store::HostStore>> {
    static STORE: OnceCell<Arc<pocox_host_svc::store::HostStore>> = OnceCell::new();
    STORE
        .get_or_try_init(|| -> Result<Arc<pocox_host_svc::store::HostStore>> {
            let path = pocox_host_svc::store::default_host_config_path()?;
            let store = runtime::runtime()
                .block_on(pocox_host_svc::store::HostStore::open(path))
                .context("opening the host config store")?;
            Ok(Arc::new(store))
        })
        .map(Arc::clone)
}

/// Publish `local` on the relay for `kind`, holding the registration.
///
/// Not fallible for the caller's purposes unless the NAME is taken: a relay
/// that is merely unreachable still yields a handle whose worker keeps
/// retrying, so the service comes up on its own. That asymmetry is deliberate —
/// a name conflict cannot resolve itself and must stop hosting, while
/// everything else can.
///
/// Deliberately NOT wrapped in `tokio::time::timeout`: cancelling `publish`
/// drops the handle, and with it the SDK worker doing the retrying, so a slow
/// relay would leave the service permanently unpublished rather than merely
/// late. The bound comes from the SDK's own readiness budget instead, and
/// [`pocox_pb::publish_pending`] hands the handle back either way.
pub(super) fn register_service(
    transport: &Transport,
    device: &str,
    kind: ServiceKind,
    name: &str,
    local: SocketAddr,
) -> Result<Option<Published>> {
    let key = transport.key(&ServiceId::new(device, kind, name));
    let outcome =
        runtime::runtime().block_on(publish_pending(&transport.session, RegisterOptions {
            key: key.clone(),
            local_addr: local.to_string(),
            // Plain HTTP/WebSocket traffic can trigger resets on the relay path.
            // Subscribers negotiate the publisher's codec through pb-mapper.
            codec: true,
        }));
    match outcome {
        Ok((published, ready)) => {
            if !ready {
                tracing::info!(
                    key = %key,
                    "hosting started before the relay confirmed this service; it keeps retrying"
                );
            }
            Ok(Some(published))
        },
        // The one condition hosting must not proceed through: another live
        // instance owns the name, and publishing anyway makes the two evict each
        // other on the relay in an endless leapfrog.
        Err(PublishError::Conflict {
            detail, ..
        }) => bail!("`{name}` is already in use by another device: {detail}"),
        Err(PublishError::Other(err)) => {
            tracing::warn!(
                key = %key,
                error = %format!("{err:#}"),
                "publishing failed; hosting continues and will retry"
            );
            Ok(None)
        },
    }
}

/// `true` if there is no registration to hold — none was created, or the relay
/// permanently refused the one we have.
///
/// Deliberately NOT the same question as "is it serving right now": a handle in
/// `Retrying` is down but must not be replaced, because its worker is already
/// reconnecting and a second registration for one key is the eviction leapfrog.
/// [`is_published`] is what the UI shows; this is what decides whether to
/// publish again.
pub(super) fn needs_publishing(published: &Option<Published>) -> bool {
    published.as_ref().is_none_or(|p| p.failure().is_some())
}

/// `true` if a service is reachable through the relay right now.
///
/// What the UI reports, so `Starting` and `Retrying` read as NOT published: the
/// key may still be indexed while nothing is forwarding, and showing that as
/// online is what would withhold the offline / re-register controls from a user
/// whose service is unreachable.
pub(super) fn is_published(published: &Option<Published>) -> bool {
    published.as_ref().is_some_and(|p| p.is_live())
}

/// Reserve an ephemeral loopback listener for an in-process service, already
/// non-blocking for [`supervise`], and learn its address. `label` names the
/// service in errors.
pub(super) fn bind_loopback(label: &str) -> Result<(std::net::TcpListener, SocketAddr)> {
    let listener = std::net::TcpListener::bind("127.0.0.1:0")
        .with_context(|| format!("binding the {label} listener"))?;
    listener
        .set_nonblocking(true)
        .with_context(|| format!("setting the {label} listener non-blocking"))?;
    let addr = listener
        .local_addr()
        .with_context(|| format!("reading the {label} listener address"))?;
    Ok((listener, addr))
}

/// Keep an in-process service alive on `addr`. Runs `serve` and, if it ever
/// exits (a transient auth/IO error, or an `axum::serve` accept error),
/// re-binds the SAME loopback port and restarts it with backoff — so the
/// registered tunnel keeps forwarding to a live server instead of a dead
/// socket. `first` is the listener the host's start already bound (so the
/// port is reserved, see [`bind_loopback`]); later restarts re-bind it.
/// `label` names the service in logs. Aborting this task (when the host stops)
/// drops the listener.
pub(super) async fn supervise<F, Fut>(
    label: &str,
    addr: SocketAddr,
    first: std::net::TcpListener,
    serve: F,
) where
    F: Fn(tokio::net::TcpListener) -> Fut,
    Fut: std::future::Future<Output = Result<()>>,
{
    let mut reserved = Some(first);
    let mut failures: u32 = 0;
    loop {
        let std_listener = match reserved.take() {
            Some(listener) => listener,
            None => match std::net::TcpListener::bind(addr) {
                Ok(listener) => {
                    let _ = listener.set_nonblocking(true);
                    listener
                },
                Err(e) => {
                    tracing::warn!(error = %e, %addr, "re-binding {label} failed");
                    failures = failures.saturating_add(1);
                    tokio::time::sleep(proxy_restart_backoff(failures)).await;
                    continue;
                },
            },
        };
        let listener = match tokio::net::TcpListener::from_std(std_listener) {
            Ok(listener) => listener,
            Err(e) => {
                tracing::warn!(error = %e, "adopting {label} listener failed");
                failures = failures.saturating_add(1);
                tokio::time::sleep(proxy_restart_backoff(failures)).await;
                continue;
            },
        };
        let started = Instant::now();
        match serve(listener).await {
            Ok(()) => tracing::warn!("{label} returned; restarting"),
            Err(e) => tracing::warn!(error = %format!("{e:#}"), "{label} exited; restarting"),
        }
        // A server that ran a while then died hit a transient fault — reset the
        // backoff; one that fails fast (e.g. a persistently missing login) backs
        // off progressively.
        failures = if started.elapsed() > Duration::from_secs(60) {
            1
        } else {
            failures.saturating_add(1)
        };
        tokio::time::sleep(proxy_restart_backoff(failures)).await;
    }
}

/// Backoff before restarting a supervised service: 2s, doubling, capped at
/// [`MAX_RESTART_BACKOFF`].
fn proxy_restart_backoff(failures: u32) -> Duration {
    Duration::from_secs(2)
        .saturating_mul(1u32 << failures.saturating_sub(1).min(7))
        .min(MAX_RESTART_BACKOFF)
}
