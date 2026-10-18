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
    let id = resolve(&request.service, &services)?;
    let key = id.key();
    let this_device = runtime::device_id().ok();
    if this_device.as_deref() == Some(id.device.as_str()) {
        return Err(ToolError::Invalid(format!(
            "`{key}` runs on this device; use it at its own local address."
        )));
    }
    if let Some(existing) = reuse(caller, &key) {
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
        key: (!user).then(|| caller.key()),
        expires_ms: (!user).then(|| now_ms() + AGENT_LEASE_MS),
    };
    let view = connection.view();
    let mut state = state::lock();
    // The call may have waited for the relay: the switch or the token may
    // have ended meanwhile.
    if let Err(error) = state.admits(caller) {
        drop(state);
        runtime::unsubscribe_service(&connection.registry_key);
        return Err(error);
    }
    state
        .connections
        .retain(|c| c.service != connection.service);
    state.connections.push(connection);
    state::changed(&mut state);
    tracing::info!(service = %view.service, local = %view.local, "connected");
    Ok(view)
}

/// A live connection to `key`; the user's own connect takes it over.
fn reuse(caller: &Caller, key: &str) -> Option<ConnectionView> {
    let mut state = state::lock();
    let index = state.connections.iter().position(|c| c.service == key)?;
    if !alive(&state.connections[index].registry_key) {
        state.connections.remove(index);
        state::changed(&mut state);
        return None;
    }
    if caller.is_user() {
        let connection = &mut state.connections[index];
        connection.key = None;
        connection.expires_ms = None;
        connection.owner = caller.owner();
    }
    let view = state.connections[index].view();
    state::changed(&mut state);
    Some(view)
}

/// End the connection to `service` (a key or its local address). An agent
/// ends only what its own conversation connected; `None` is the user.
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
        if state.connections[index].key.as_ref() != Some(&caller.key()) {
            return Err(ToolError::NotOwner);
        }
    }
    let connection = state.connections.remove(index);
    state::changed(&mut state);
    drop(state);
    runtime::unsubscribe_service(&connection.registry_key);
    tracing::info!(service = %connection.service, "disconnected");
    Ok(connection.view())
}

/// End every connection whose owner `ended` selects.
pub fn end_owned(ended: impl Fn(&OwnerKey) -> bool) {
    let mut state = state::lock();
    let (gone, kept): (Vec<Connection>, Vec<Connection>) = std::mem::take(&mut state.connections)
        .into_iter()
        .partition(|c| c.key.as_ref().is_some_and(&ended));
    state.connections = kept;
    if gone.is_empty() {
        return;
    }
    state::changed(&mut state);
    drop(state);
    for connection in gone {
        runtime::unsubscribe_service(&connection.registry_key);
    }
}

/// Drop expired and dead connections.
pub fn prune() {
    let now = now_ms();
    let mut state = state::lock();
    let (gone, kept): (Vec<Connection>, Vec<Connection>) = std::mem::take(&mut state.connections)
        .into_iter()
        .partition(|c| c.expires_ms.is_some_and(|at| at <= now) || !alive(&c.registry_key));
    state.connections = kept;
    if gone.is_empty() {
        return;
    }
    state::changed(&mut state);
    drop(state);
    for connection in gone {
        runtime::unsubscribe_service(&connection.registry_key);
    }
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
}
