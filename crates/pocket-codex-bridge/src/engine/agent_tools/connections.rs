//! Services of the user's other devices made reachable on this device, at
//! the same port number when it is free.

use std::time::Duration;

use pocket_codex_account_proto::key::NamespacedServiceId;
use pocket_codex_core::service::{sanitize_component, ServiceId, ServiceKind};

use super::{
    error::ToolError,
    model::{bounded, ConnectionView, AGENT_LEASE_MS},
    shares::Caller,
    state::{self, now_ms, Connection, OwnerKey},
};
use crate::engine::{discovery, runtime, transport};

/// Registry-key family of these tunnels; each is scoped to its transport
/// context.
const FAMILY: &str = "tools\u{1f}";

/// What to connect to.
#[derive(Debug, Clone, Default)]
pub struct ConnectRequest {
    /// A key (`pcx:devbox:port:8000`, or the account form `pcxu:<user>:…`),
    /// `devbox:port:8000` or `devbox/8000`.
    pub service: String,
    /// A local port to prefer over the service's own number.
    pub local_port: Option<u16>,
}

/// The kinds an agent may connect to: shared ports and Responses APIs.
/// Agent hosts are for the user's controllers, not for other agents.
fn connectable(kind: ServiceKind) -> bool {
    matches!(kind, ServiceKind::Port | ServiceKind::Api)
}

/// Resolve `wanted` among `services`.
pub fn resolve(wanted: &str, services: &[ServiceId]) -> Result<ServiceId, ToolError> {
    let wanted = wanted.trim();
    let parsed = ServiceId::parse_key(wanted)
        .or_else(|| NamespacedServiceId::parse_key(wanted).map(|id| id.service))
        .or_else(|| ServiceId::parse_key(&format!("pcx:{wanted}")))
        .map(|id| vec![id]);
    let candidates: Vec<ServiceId> = match parsed {
        Some(ids) => ids,
        None => {
            let (device, name) = wanted.split_once('/').ok_or_else(|| {
                ToolError::Invalid(
                    "Name the service by its key, `device:kind:name` or `device/name`.".into(),
                )
            })?;
            let (device, name) = (sanitize_component(device), sanitize_component(name));
            services
                .iter()
                .filter(|s| s.device == device && s.name == name && connectable(s.kind))
                .cloned()
                .collect()
        },
    };
    match candidates.as_slice() {
        [one] if services.contains(one) => {
            if connectable(one.kind) {
                Ok(one.clone())
            } else {
                Err(ToolError::Invalid(
                    "Only shared ports and Responses APIs can be connected to.".into(),
                ))
            }
        },
        [_] | [] => Err(ToolError::NotFound(format!("The service `{}`", bounded(wanted)))),
        _ => Err(ToolError::Invalid(format!(
            "`{}` matches more than one service; use its full key.",
            bounded(wanted)
        ))),
    }
}

fn alive(registry_key: &str) -> bool {
    runtime::list_subscriptions()
        .iter()
        .any(|s| s.key == registry_key && s.alive)
}

/// Make `request.service` reachable on this device for `caller`.
pub async fn connect(
    caller: &Caller,
    request: ConnectRequest,
) -> Result<ConnectionView, ToolError> {
    if !caller.is_user() && !state::lock().settings.enabled {
        return Err(ToolError::Off);
    }
    let owned = transport::resolve_owned()
        .await
        .map_err(|e| ToolError::Relay(format!("{e:#}")))?;
    let services =
        tokio::time::timeout(Duration::from_secs(10), discovery::discover(&owned.transport))
            .await
            .map_err(|_| ToolError::Relay("listing services timed out".into()))?
            .map_err(|e| ToolError::Relay(format!("{e:#}")))?;
    // A full account key names its account: one of another account or relay
    // (a stale or foreign link) is not this one's same-named service.
    let wanted = request.service.trim();
    if let Some(named) = NamespacedServiceId::parse_key(wanted) {
        if owned.transport.key(&named.service) != wanted {
            return Err(ToolError::Invalid(format!(
                "`{}` belongs to another account or relay; call `services` for this one's.",
                bounded(wanted)
            )));
        }
    }
    let id = resolve(&request.service, &services)?;
    let key = id.key();
    let this_device = runtime::device_id().ok();
    if this_device.as_deref() == Some(id.device.as_str()) {
        return Err(ToolError::Invalid(format!(
            "`{key}` runs on this device; use it at its own local address."
        )));
    }
    if let Some(existing) = reuse(caller, &key, owned.epoch)? {
        return Ok(existing);
    }
    let own_port = (id.kind == ServiceKind::Port)
        .then(|| id.name.parse::<u16>().ok())
        .flatten();
    let preferred = request.local_port.or(own_port).unwrap_or(0);
    let context = transport::Context::of(&owned.transport);
    let registry_key = format!("{FAMILY}{}\u{1f}{key}", context.id());
    let epoch = owned.epoch;
    let transport = owned.transport.clone();
    let (service_key, registry) = (key.clone(), registry_key.clone());
    let status = tokio::task::spawn_blocking(move || {
        let current = || transport::is_current(epoch);
        runtime::subscribe_service_as(
            registry.clone(),
            &service_key,
            preferred,
            &transport,
            current,
        )
        .or_else(|error| {
            if preferred == 0 {
                return Err(error);
            }
            runtime::subscribe_service_as(registry, &service_key, 0, &transport, current)
        })
    })
    .await
    .map_err(|e| ToolError::Relay(format!("{e}")))?
    .map_err(|e| ToolError::Relay(format!("{e:#}")))?;
    // Only the service's own number keeps absolute localhost URLs working.
    let same_port = status
        .local_addr
        .rsplit(':')
        .next()
        .and_then(|p| p.parse::<u16>().ok())
        .is_some_and(|port| Some(port) == own_port);
    let user = caller.is_user();
    let connection = Connection {
        service: key,
        registry_key,
        local: status.local_addr,
        same_port,
        owner: caller.owner(),
        holders: if user { Vec::new() } else { vec![(caller.key(), now_ms() + AGENT_LEASE_MS)] },
        user,
    };
    let mut state = state::lock();
    // The call may have waited for the relay: the switch, the token, or the
    // account or relay the tunnel belongs to may have ended meanwhile.
    let admitted = state.admits(caller).and_then(|()| {
        transport::is_current(epoch)
            .then_some(())
            .ok_or(ToolError::ContextChanged)
    });
    if let Err(error) = admitted {
        // The tunnel may be another admitted owner's too (a concurrent
        // connect to the same service): only an unowned one is ended.
        let owned = state
            .connections
            .iter()
            .any(|c| c.registry_key == connection.registry_key);
        drop(state);
        if !owned {
            runtime::unsubscribe_service(&connection.registry_key);
        }
        return Err(error);
    }
    let view = match state
        .connections
        .iter_mut()
        .find(|c| c.service == connection.service)
    {
        // A concurrent connect made the same tunnel first: join it.
        Some(existing) => {
            if connection.user {
                // The user's own connect takes it over, as in `reuse`.
                existing.user = true;
                existing.holders.clear();
                existing.owner = connection.owner;
            } else if !existing.user {
                existing.holders.extend(connection.holders);
            }
            existing.view()
        },
        None => {
            let view = connection.view();
            state.connections.push(connection);
            view
        },
    };
    state::changed(&mut state);
    tracing::info!(service = %view.service, local = %view.local, "connected");
    Ok(view)
}

/// A live connection to `key`, shared with `caller`: an agent joins those
/// keeping it alive (with its own lease), and the user's own connect takes
/// it over.
fn reuse(caller: &Caller, key: &str, epoch: u64) -> Result<Option<ConnectionView>, ToolError> {
    let mut state = state::lock();
    state.admits(caller)?;
    // A tunnel of an account or relay that changed is gone.
    if !transport::is_current(epoch) {
        return Err(ToolError::ContextChanged);
    }
    let Some(index) = state.connections.iter().position(|c| c.service == key) else {
        return Ok(None);
    };
    if !alive(&state.connections[index].registry_key) {
        state.connections.remove(index);
        state::changed(&mut state);
        return Ok(None);
    }
    let connection = &mut state.connections[index];
    if caller.is_user() {
        connection.user = true;
        connection.holders.clear();
        connection.owner = caller.owner();
    } else if !connection.user {
        let (owner, until) = (caller.key(), now_ms() + AGENT_LEASE_MS);
        match connection.holders.iter_mut().find(|(key, _)| *key == owner) {
            Some(holder) => holder.1 = until,
            None => connection.holders.push((owner, until)),
        }
    }
    let view = connection.view();
    state::changed(&mut state);
    Ok(Some(view))
}

/// End the connection to `service` (a key or its local address). An agent
/// only lets go of what its own conversation connected, and the tunnel ends
/// once nobody holds it; `None` is the user, who ends it.
pub fn disconnect(caller: Option<&Caller>, service: &str) -> Result<ConnectionView, ToolError> {
    let service = service.trim();
    let mut state = state::lock();
    let index = state
        .connections
        .iter()
        .position(|c| {
            c.service == service
                || c.local == service
                || ServiceId::parse_key(&c.service).is_some_and(|id| {
                    format!("{}/{}", id.device, id.name) == service
                        || format!("pcx:{service}") == c.service
                })
        })
        .ok_or_else(|| ToolError::NotFound(format!("A connection to `{}`", bounded(service))))?;
    if let Some(caller) = caller.filter(|c| !c.is_user()) {
        let owner = caller.key();
        let connection = &mut state.connections[index];
        if connection.user || !connection.held_by(&owner) {
            return Err(ToolError::NotOwner);
        }
        connection.holders.retain(|(key, _)| *key != owner);
        if !connection.abandoned() {
            // Others still use it.
            let view = connection.view();
            state::changed(&mut state);
            return Ok(view);
        }
    }
    let connection = state.connections.remove(index);
    state::changed(&mut state);
    drop(state);
    runtime::unsubscribe_service(&connection.registry_key);
    tracing::info!(service = %connection.service, "disconnected");
    Ok(connection.view())
}

/// Let go of every hold `release` selects, ending the connections nobody
/// holds any more and those `dead` selects.
fn release_where(release: impl Fn(&OwnerKey, i64) -> bool, dead: impl Fn(&Connection) -> bool) {
    let mut state = state::lock();
    let mut changed = false;
    for connection in &mut state.connections {
        let before = connection.holders.len();
        connection
            .holders
            .retain(|(key, until)| !release(key, *until));
        changed |= connection.holders.len() != before;
    }
    let (gone, kept): (Vec<Connection>, Vec<Connection>) = std::mem::take(&mut state.connections)
        .into_iter()
        .partition(|c| c.abandoned() || dead(c));
    state.connections = kept;
    if !changed && gone.is_empty() {
        return;
    }
    state::changed(&mut state);
    drop(state);
    for connection in gone {
        runtime::unsubscribe_service(&connection.registry_key);
    }
}

/// End the holds of the owners `ended` selects.
pub fn end_owned(ended: impl Fn(&OwnerKey) -> bool) {
    release_where(|key, _| ended(key), |_| false);
}

/// Drop expired holds and dead connections.
pub fn prune() {
    let now = now_ms();
    release_where(|_, until| until <= now, |c| !alive(&c.registry_key));
}

/// The account or relay changed: these tunnels belong to the old one.
pub fn context_changed() {
    let gone = std::mem::take(&mut state::lock().connections);
    if !gone.is_empty() {
        state::changed(&mut state::lock());
    }
    runtime::unsubscribe_prefix(FAMILY);
}

/// This device's connections.
pub fn list() -> Vec<ConnectionView> {
    state::lock()
        .connections
        .iter()
        .map(Connection::view)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_resolve_to_one_connectable_service() {
        let services = [
            ServiceId::new("devbox", ServiceKind::Port, "8000"),
            ServiceId::new("devbox", ServiceKind::Api, "default"),
            ServiceId::new("devbox", ServiceKind::App, "default"),
        ];
        assert_eq!(resolve("devbox/8000", &services), Ok(services[0].clone()));
        assert_eq!(resolve("pcx:devbox:api:default", &services), Ok(services[1].clone()));
        assert_eq!(resolve("pcxu:u1:devbox:api:default", &services), Ok(services[1].clone()));
        assert_eq!(resolve("devbox:port:8000", &services), Ok(services[0].clone()));
        assert!(matches!(resolve("devbox/9999", &services), Err(ToolError::NotFound(_))));
        assert!(matches!(resolve("devbox:app:default", &services), Err(ToolError::Invalid(_))));
        assert!(matches!(resolve("nonsense", &services), Err(ToolError::Invalid(_))));
    }

    #[test]
    fn a_shared_tunnel_lasts_until_its_last_holder_lets_go() {
        // Ending a tunnel unsubscribes it in the runtime's registry.
        runtime::init(std::env::temp_dir()).expect("test runtime");
        let service = "pcx:holders-test:port:7001";
        let a = OwnerKey {
            token: "holders-a".into(),
            conversation: Some("c1".into()),
        };
        let b = OwnerKey {
            token: "holders-b".into(),
            conversation: None,
        };
        state::lock().connections.push(Connection {
            service: service.into(),
            registry_key: format!("{FAMILY}test\u{1f}{service}"),
            local: "127.0.0.1:7001".into(),
            same_port: true,
            owner: Caller::user("agent").owner(),
            holders: vec![(a.clone(), i64::MAX), (b.clone(), i64::MAX)],
            user: false,
        });
        let held = |key: &OwnerKey| {
            state::lock()
                .connections
                .iter()
                .any(|c| c.service == service && c.held_by(key))
        };
        end_owned(|key| *key == a);
        assert!(!held(&a) && held(&b), "the other holder keeps it");
        end_owned(|key| *key == b);
        assert!(state::lock()
            .connections
            .iter()
            .all(|c| c.service != service));
    }
}
