//! Process-owned loopback routes. Only hosting lifecycle code registers them;
//! neither device labels nor files on a shared filesystem establish locality.
//! A retired route remains known until process exit, so reconnect never turns
//! a stopped local service into a subscription to a similarly named remote one.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};

use anyhow::{bail, ensure, Result};
use pocox_core::service::ServiceId;

use super::transport::Context;
use super::{host_owner, session_engine};

type Key = (Context, String);
static ROUTES: LazyLock<Mutex<HashMap<Key, Endpoint>>> = LazyLock::new(Mutex::default);

/// Where the host behind an [`Endpoint`] stands.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Standing {
    /// It serves the snapshot's listener.
    Serving,
    /// It is restarting in place, or has restarted since the snapshot was
    /// taken: the snapshot's clients were retired and reconnect to the same
    /// host on their own.
    Restarting,
    /// It stopped. A new host on the same port is another lifetime.
    Stopped,
}

/// One host lifetime: its generation, bumped by each in-place restart, and
/// where it stands, packed into one word so the two are always read together.
#[derive(Debug)]
struct Lifetime(AtomicU64);

impl Lifetime {
    const STATE_BITS: u32 = 2;

    fn serving() -> Self {
        Self(AtomicU64::new(Self::pack(0, Standing::Serving)))
    }

    fn pack(generation: u64, standing: Standing) -> u64 {
        let state = match standing {
            Standing::Serving => 0,
            Standing::Restarting => 1,
            Standing::Stopped => 2,
        };
        (generation << Self::STATE_BITS) | state
    }

    fn load(&self) -> (u64, Standing) {
        let word = self.0.load(Ordering::Acquire);
        let standing = match word & ((1 << Self::STATE_BITS) - 1) {
            0 => Standing::Serving,
            1 => Standing::Restarting,
            _ => Standing::Stopped,
        };
        (word >> Self::STATE_BITS, standing)
    }

    /// Keep the generation and stand as `standing`.
    fn stand(&self, standing: Standing) {
        let (generation, _) = self.load();
        self.0
            .store(Self::pack(generation, standing), Ordering::Release);
    }

    /// Serve again under a new generation, which retires every older snapshot.
    fn restarted(&self) -> u64 {
        let (generation, _) = self.load();
        let next = generation + 1;
        self.0
            .store(Self::pack(next, Standing::Serving), Ordering::Release);
        next
    }
}

/// A snapshot of a loopback listener and the lifetime that owns it. Cloning
/// the snapshot never keeps a host alive or makes a retired address usable.
#[derive(Clone, Debug)]
pub(crate) struct Endpoint {
    address: SocketAddr,
    lifetime: Arc<Lifetime>,
    generation: u64,
}

impl Endpoint {
    pub(crate) fn address(&self) -> String {
        self.address.to_string()
    }

    pub(crate) fn is_current(&self) -> bool {
        self.standing() == Standing::Serving
    }

    pub(crate) fn standing(&self) -> Standing {
        match self.lifetime.load() {
            (generation, Standing::Serving) if generation != self.generation => {
                Standing::Restarting
            },
            (_, standing) => standing,
        }
    }

    pub(crate) fn same_listener(&self, other: &Self) -> bool {
        self.address == other.address
            && Arc::ptr_eq(&self.lifetime, &other.lifetime)
            && self.generation == other.generation
    }
}

/// Held by one host, independently of its publications. Drop before stopping
/// its listeners; old snapshots stay invalid even if a port is reused.
pub(crate) struct Registration {
    lifetime: Arc<Lifetime>,
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
            // A host restarting in place still owns its keys.
            ensure!(
                routes
                    .get(&(context.clone(), key.clone()))
                    .is_none_or(|endpoint| endpoint.standing() == Standing::Stopped),
                "this local service is already hosted"
            );
        }
        let registration = Self {
            lifetime: Arc::new(Lifetime::serving()),
            context: context.clone(),
            services: services.to_vec(),
        };
        registration.publish(&mut routes, 0);
        Ok(registration)
    }

    fn publish(&self, routes: &mut HashMap<Key, Endpoint>, generation: u64) {
        for (key, address) in &self.services {
            routes.insert((self.context.clone(), key.clone()), Endpoint {
                address: *address,
                lifetime: self.lifetime.clone(),
                generation,
            });
        }
    }

    /// Whether its host serves its listeners now, rather than restarting.
    pub(crate) fn is_serving(&self) -> bool {
        self.lifetime.load().1 == Standing::Serving
    }

    /// An in-place child restart keeps its ports, but retires every old
    /// client. Until [`Self::resume`] its services read as restarting, not
    /// stopped, and nothing else can host them.
    pub(crate) fn suspend(&self) {
        self.lifetime.stand(Standing::Restarting);
        retire_clients();
    }

    /// Called only after the replacement has passed the host's readiness
    /// checks. Clients from before the restart stay retired.
    pub(crate) fn resume(&mut self) {
        let mut routes = ROUTES.lock().unwrap_or_else(|error| error.into_inner());
        let generation = self.lifetime.restarted();
        self.publish(&mut routes, generation);
    }
}

impl Drop for Registration {
    fn drop(&mut self) {
        self.lifetime.stand(Standing::Stopped);
        retire_clients();
    }
}

/// Every protocol drops its connections to a listener that is no longer
/// current.
fn retire_clients() {
    super::app_session::local_stopped();
    super::acp::local_stopped();
    super::opencode::local_stopped();
}

fn route(context: &Context, service: &str) -> Result<Option<Endpoint>> {
    ensure!(context.admits(service), "this service belongs to another account or relay");
    let Some(logical) = session_engine::logical_key(service) else { return Ok(None) };
    let routes = ROUTES.lock().unwrap_or_else(|error| error.into_inner());
    Ok(routes.get(&(context.clone(), logical)).cloned())
}

/// `None` means no local ownership evidence. A known service that is not
/// serving is an error, never permission to fall back to the relay.
pub(crate) fn lookup(context: &Context, service: &str) -> Result<Option<Endpoint>> {
    let Some(endpoint) = route(context, service)? else { return Ok(None) };
    match endpoint.standing() {
        Standing::Serving => Ok(Some(endpoint)),
        Standing::Restarting => bail!("this local host is restarting; reconnect in a moment"),
        Standing::Stopped => {
            bail!("this local service has stopped; start its host before reconnecting")
        },
    }
}

/// Whether this process hosts `service`, serving or restarting in place.
/// `false` means no local ownership evidence; a stopped one is an error.
pub(crate) fn hosts(context: &Context, service: &str) -> Result<bool> {
    let Some(endpoint) = route(context, service)? else { return Ok(false) };
    match endpoint.standing() {
        Standing::Serving | Standing::Restarting => Ok(true),
        Standing::Stopped => {
            bail!("this local service has stopped; start its host before reconnecting")
        },
    }
}

/// Where `service`'s local host stands; stopped when there is none.
pub(crate) fn standing(context: &Context, service: &str) -> Standing {
    match route(context, service) {
        Ok(Some(endpoint)) => endpoint.standing(),
        Ok(None) | Err(_) => Standing::Stopped,
    }
}

/// Local discovery is a memory read, independent of relay credentials,
/// publication state, probes and network availability. A host restarting in
/// place stays listed.
pub(crate) fn discover(context: &Context) -> Vec<ServiceId> {
    ROUTES
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .iter()
        .filter(|((owner, _), endpoint)| {
            owner == context && endpoint.standing() != Standing::Stopped
        })
        .filter_map(|((_, key), _)| ServiceId::parse_key(key))
        .collect()
}
