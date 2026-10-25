//! Process-owned loopback routes. Only hosting lifecycle code registers them;
//! neither device labels nor files on a shared filesystem establish locality.
//! A retired route remains known until process exit, so reconnect never turns
//! a stopped local service into a subscription to a similarly named remote one.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

use anyhow::{bail, ensure, Result};
use pocox_core::service::ServiceId;

use super::transport::Context;
use super::{host_owner, session_engine};

type Key = (Context, String);
static ROUTES: LazyLock<Mutex<HashMap<Key, Endpoint>>> = LazyLock::new(Mutex::default);

/// A snapshot of a loopback listener and the lifetime that owns it. Cloning
/// the snapshot never keeps a host alive or makes a retired address usable.
#[derive(Clone, Debug)]
pub(crate) struct Endpoint {
    address: SocketAddr,
    active: Arc<AtomicBool>,
}

impl Endpoint {
    pub(crate) fn address(&self) -> String {
        self.address.to_string()
    }

    pub(crate) fn is_current(&self) -> bool {
        self.active.load(Ordering::Acquire)
    }

    pub(crate) fn same_listener(&self, other: &Self) -> bool {
        self.address == other.address && Arc::ptr_eq(&self.active, &other.active)
    }
}

/// Held by one host, independently of its publications. Drop before stopping
/// its listeners; old snapshots stay invalid even if a port is reused.
pub(crate) struct Registration {
    active: Arc<AtomicBool>,
    context: Context,
    services: Vec<(String, SocketAddr)>,
}

impl Registration {
    pub(crate) fn new(context: &Context, services: &[(String, SocketAddr)]) -> Result<Self> {
        host_owner::require()?;
        ensure!(
            services
                .iter()
                .all(|(_, address)| address.ip().is_loopback()),
            "local services must bind loopback"
        );
        let mut routes = ROUTES.lock().unwrap_or_else(|error| error.into_inner());
        for (key, _) in services {
            ensure!(ServiceId::parse_key(key).is_some(), "invalid local service key");
            ensure!(
                !routes
                    .get(&(context.clone(), key.clone()))
                    .is_some_and(Endpoint::is_current),
                "this local service is already hosted"
            );
        }
        let active = Arc::new(AtomicBool::new(true));
        for (key, address) in services {
            routes.insert((context.clone(), key.clone()), Endpoint {
                address: *address,
                active: active.clone(),
            });
        }
        Ok(Self {
            active,
            context: context.clone(),
            services: services.to_vec(),
        })
    }

    /// In-place child restarts keep their ports, but retire every old client.
    pub(crate) fn suspend(&self) {
        self.active.store(false, Ordering::Release);
        super::app_session::local_stopped();
        super::acp::local_stopped();
        super::opencode::local_stopped();
    }

    /// Called only after the replacement has passed the host's readiness
    /// checks.
    pub(crate) fn resume(&mut self) -> Result<()> {
        *self = Self::new(&self.context, &self.services)?;
        Ok(())
    }
}

impl Drop for Registration {
    fn drop(&mut self) {
        self.suspend();
    }
}

/// `None` means no local ownership evidence. A known but stopped service is
/// an error, never permission to fall back to the relay.
pub(crate) fn lookup(context: &Context, service: &str) -> Result<Option<Endpoint>> {
    ensure!(context.admits(service), "this service belongs to another account or relay");
    let Some(logical) = session_engine::logical_key(service) else { return Ok(None) };
    let routes = ROUTES.lock().unwrap_or_else(|error| error.into_inner());
    let Some(endpoint) = routes.get(&(context.clone(), logical)) else { return Ok(None) };
    if !endpoint.is_current() {
        bail!("this local service has stopped; start its host before reconnecting");
    }
    Ok(Some(endpoint.clone()))
}

/// Local discovery is a memory read, independent of relay credentials,
/// publication state, probes and network availability.
pub(crate) fn discover(context: &Context) -> Vec<ServiceId> {
    ROUTES
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .iter()
        .filter(|((owner, _), endpoint)| owner == context && endpoint.is_current())
        .filter_map(|((_, key), _)| ServiceId::parse_key(key))
        .collect()
}
