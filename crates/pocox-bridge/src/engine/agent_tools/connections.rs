//! Services of the user's other devices made reachable on this device, at
//! the same port number when it is free.

use std::time::Duration;

use pocox_account_proto::key::NamespacedServiceId;
use pocox_core::service::{sanitize_component, ServiceId, ServiceKind};

use super::consent;
use super::error::{Pending, ToolError};
use super::model::{bounded, ConnectionView, Lifetime, LinkView};
use super::shares::Caller;
use super::state::{self, now_ms, Connection, OwnerKey, Restore};
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
    /// How long an agent's connection lasts; the user's own lasts until
    /// they end it.
    pub lifetime: Lifetime,
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

/// Make `request.service` reachable on this device for `caller`. An agent
/// connects another device's Responses API, which spends that device's
/// model account, only with the user's consent: a pending result while the
/// user has not answered. Shared ports were shared with the user's devices
/// and need none.
pub async fn connect(
    caller: &Caller,
    request: ConnectRequest,
) -> Result<Result<ConnectionView, Pending>, ToolError> {
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
    if !caller.is_user() && id.kind == ServiceKind::Api {
        if let Err(waiting) = consent::admit_connect(caller, &caller.key(), &key, &id.name).await? {
            return Ok(Err(waiting));
        }
    }
    let until = request.lifetime.until(now_ms());
    let kept_port = match reuse(caller, &key, owned.epoch, until)? {
        Reused::Live(existing) => return Ok(Ok(*existing)),
        Reused::Ended(port) => Some(port),
        Reused::None => None,
    };
    let own_port = (id.kind == ServiceKind::Port)
        .then(|| id.name.parse::<u16>().ok())
        .flatten();
    // A kept connection whose tunnel ended reopens where it was.
    let preferred = request.local_port.or(kept_port).or(own_port).unwrap_or(0);
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
    let link = link_of(Some(&status), &Restore::default());
    let connection = Connection {
        service: key,
        registry_key,
        local: status.local_addr,
        same_port,
        owner: caller.owner(),
        holders: if user { Vec::new() } else { vec![(caller.key(), until)] },
        user,
        restore: Restore::default(),
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
    let mut view = match state
        .connections
        .iter_mut()
        .find(|c| c.service == connection.service)
    {
        // A concurrent connect made the same tunnel first, or this one
        // reopened a kept connection's: join it, where it now is.
        Some(existing) => {
            existing.local = connection.local;
            existing.same_port = connection.same_port;
            existing.restore = Restore::default();
            hold(existing, caller, until);
            existing.view()
        },
        None => {
            let view = connection.view();
            state.connections.push(connection);
            view
        },
    };
    state::changed(&mut state);
    view.link = link;
    tracing::info!(service = %view.service, local = %view.local, "connected");
    Ok(Ok(view))
}

/// What [`reuse`] found.
enum Reused {
    /// A live connection, now held by the caller too.
    Live(Box<ConnectionView>),
    /// A kept connection whose tunnel ended, at this port.
    Ended(u16),
    /// None.
    None,
}

/// A live connection to `key`, shared with `caller`: an agent joins those
/// keeping it alive (with its own lease, renewed or changed to `until`), and
/// the user's own connect takes it over.
fn reuse(caller: &Caller, key: &str, epoch: u64, until: Option<i64>) -> Result<Reused, ToolError> {
    let mut state = state::lock();
    state.admits(caller)?;
    // A tunnel of an account or relay that changed is gone.
    if !transport::is_current(epoch) {
        return Err(ToolError::ContextChanged);
    }
    let Some(connection) = state.connections.iter_mut().find(|c| c.service == key) else {
        return Ok(Reused::None);
    };
    let statuses = runtime::list_subscriptions();
    let status = statuses.iter().find(|s| s.key == connection.registry_key);
    if !status.is_some_and(|s| s.alive) {
        return Ok(Reused::Ended(port_of(&connection.local)));
    }
    hold(connection, caller, until);
    let mut view = connection.view();
    view.link = link_of(status, &connection.restore);
    state::changed(&mut state);
    Ok(Reused::Live(Box::new(view)))
}

/// Let `caller` hold `connection` until `until`: the user's own connect
/// takes it over; an agent renews its hold, or joins those keeping it.
fn hold(connection: &mut Connection, caller: &Caller, until: Option<i64>) {
    if caller.is_user() {
        connection.user = true;
        connection.holders.clear();
        connection.owner = caller.owner();
    } else if !connection.user {
        let owner = caller.key();
        match connection.holders.iter_mut().find(|(key, _)| *key == owner) {
            Some(holder) => holder.1 = until,
            None => connection.holders.push((owner, until)),
        }
    }
}

/// The port of a `host:port` address, or 0 for any.
fn port_of(local: &str) -> u16 {
    local
        .rsplit(':')
        .next()
        .and_then(|port| port.parse().ok())
        .unwrap_or(0)
}

/// How a connection travels, from its tunnel's live `status`. Without a
/// live tunnel a kept connection is being reopened.
fn link_of(status: Option<&runtime::SubStatus>, restore: &Restore) -> Option<LinkView> {
    use runtime::TunnelPath;
    let Some(status) = status.filter(|status| status.alive) else {
        return Some(LinkView {
            policy: String::new(),
            path: "idle".into(),
            state: "restoring".into(),
            direct_sessions: 0,
            relay_sessions: 0,
            fallbacks: 0,
            last_fallback_stage: None,
            attempting: None,
            restore_failures: restore.failures,
        });
    };
    let path = &status.path;
    let state = if !status.ready {
        "connecting"
    } else if status.health.retrying || status.health.consecutive_failures > 0 {
        "reconnecting"
    } else {
        "ready"
    };
    Some(LinkView {
        policy: if path.path == TunnelPath::RelayOnly { "relay_only" } else { "p2p_first" }.into(),
        path: match path.path {
            TunnelPath::RelayOnly | TunnelPath::Relay => "relay",
            TunnelPath::Idle => "idle",
            TunnelPath::Direct => "direct",
            TunnelPath::Mixed => "mixed",
        }
        .into(),
        state: state.into(),
        direct_sessions: path.direct_sessions,
        relay_sessions: path.relay_sessions,
        fallbacks: path.fallbacks,
        last_fallback_stage: status
            .events
            .iter()
            .rev()
            .find_map(|event| match event.kind {
                pocox_pb::TunnelEventKind::DirectFallback {
                    stage,
                } => Some(stage.as_str().to_string()),
                _ => None,
            }),
        attempting: path
            .attempt
            .map(|attempt| attempt.stage.as_str().to_string()),
        restore_failures: 0,
    })
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
/// holds any more.
fn release_where(release: impl Fn(&OwnerKey, Option<i64>) -> bool) {
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
        .partition(Connection::abandoned);
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
    release_where(|key, _| ended(key));
}

/// Drop expired holds, and reopen the tunnels of the connections kept that
/// ended: a connection lasts until it expires or is ended, whatever happens
/// to its tunnel meanwhile.
pub fn prune() {
    let now = now_ms();
    release_where(|_, until| until.is_some_and(|until| until <= now));
    restore(now);
}

/// Wait before reopening a tunnel again after `failures` failed attempts:
/// two seconds, doubling up to a minute.
fn backoff_ms(failures: u32) -> i64 {
    (1_000_i64 << failures.min(6)).min(60_000)
}

/// Start reopening each kept connection whose tunnel ended and whose
/// backoff has passed, at the address it was given.
fn restore(now: i64) {
    for (service, registry_key, port) in due(now, &runtime::list_subscriptions()) {
        tracing::info!(%service, "reopening a kept connection whose tunnel ended");
        runtime::runtime().spawn(async move {
            let reopened = reopen(&service, &registry_key, port).await;
            settle(&registry_key, reopened);
        });
    }
}

/// The connections to reopen now, as (service, registry key, port), each
/// marked as being reopened: no live tunnel in `statuses`, no attempt
/// running, and its backoff passed.
fn due(now: i64, statuses: &[runtime::SubStatus]) -> Vec<(String, String, u16)> {
    let mut state = state::lock();
    state
        .connections
        .iter_mut()
        .filter(|c| {
            !c.restore.running
                && c.restore.next_ms <= now
                && !statuses.iter().any(|s| s.key == c.registry_key && s.alive)
        })
        .map(|c| {
            c.restore.running = true;
            (c.service.clone(), c.registry_key.clone(), port_of(&c.local))
        })
        .collect()
}

/// Reopen the tunnel `registry_key` to `service` on `port` (0 when the
/// port went to something else meanwhile).
async fn reopen(service: &str, registry_key: &str, port: u16) -> anyhow::Result<(String, bool)> {
    let owned = transport::resolve_owned().await?;
    let (service, registry, epoch) = (service.to_string(), registry_key.to_string(), owned.epoch);
    tokio::task::spawn_blocking(move || {
        let current = || transport::is_current(epoch);
        let transport = &owned.transport;
        runtime::subscribe_service_as(registry.clone(), &service, port, transport, current)
            .map(|status| (status.local_addr, true))
            .or_else(|error| {
                if port == 0 {
                    return Err(error);
                }
                runtime::subscribe_service_as(registry, &service, 0, transport, current)
                    .map(|status| (status.local_addr, false))
            })
    })
    .await?
}

/// Record how reopening `registry_key` went.
fn settle(registry_key: &str, reopened: anyhow::Result<(String, bool)>) {
    let mut state = state::lock();
    let Some(connection) = state
        .connections
        .iter_mut()
        .find(|c| c.registry_key == registry_key)
    else {
        // Ended meanwhile, and with it the tunnel this reopened.
        drop(state);
        if reopened.is_ok() {
            runtime::unsubscribe_service(registry_key);
        }
        return;
    };
    match reopened {
        Ok((local, same)) => {
            if !same {
                tracing::warn!(service = %connection.service, %local, "reopened at another port");
                connection.same_port = false;
            }
            connection.local = local;
            connection.restore = Restore::default();
        },
        Err(error) => {
            let failures = connection.restore.failures.saturating_add(1);
            tracing::warn!(service = %connection.service, failures, error = %format!("{error:#}"), "reopening failed");
            connection.restore = Restore {
                failures,
                next_ms: now_ms() + backoff_ms(failures),
                running: false,
            };
        },
    }
    state::changed(&mut state);
}

/// The account or relay changed: these tunnels belong to the old one.
pub fn context_changed() {
    let gone = std::mem::take(&mut state::lock().connections);
    if !gone.is_empty() {
        state::changed(&mut state::lock());
    }
    runtime::unsubscribe_prefix(FAMILY);
}

/// This device's connections, each with how it travels now.
pub fn list() -> Vec<ConnectionView> {
    let statuses = runtime::list_subscriptions();
    state::lock()
        .connections
        .iter()
        .map(|connection| ConnectionView {
            link: link_of(
                statuses.iter().find(|s| s.key == connection.registry_key),
                &connection.restore,
            ),
            ..connection.view()
        })
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
            holders: vec![(a.clone(), Some(i64::MAX)), (b.clone(), None)],
            user: false,
            restore: Restore::default(),
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

    #[test]
    fn a_kept_connection_outlives_its_tunnel_until_it_expires() {
        runtime::init(std::env::temp_dir()).expect("test runtime");
        let service = "pcx:keep-test:port:7002";
        let expired = OwnerKey {
            token: "keep-expired".into(),
            conversation: None,
        };
        let permanent = OwnerKey {
            token: "keep-permanent".into(),
            conversation: None,
        };
        state::lock().connections.push(Connection {
            service: service.into(),
            registry_key: format!("{FAMILY}test\u{1f}{service}"),
            local: "127.0.0.1:7002".into(),
            same_port: true,
            owner: Caller::user("agent").owner(),
            holders: vec![(expired.clone(), Some(1)), (permanent.clone(), None)],
            user: false,
            restore: Restore::default(),
        });
        let now = now_ms();
        release_where(|_, until| until.is_some_and(|until| until <= now));
        // Its tunnel never existed: rather than drop the connection, it is
        // reopened where it was, once, until that attempt settles.
        let reopening = due(now, &[]);
        assert!(reopening.contains(&(
            service.to_string(),
            format!("{FAMILY}test\u{1f}{service}"),
            7002
        )));
        assert!(due(now, &[]).iter().all(|(s, ..)| s != service), "one attempt at a time");
        let mut state = state::lock();
        let kept = state
            .connections
            .iter()
            .find(|c| c.service == service)
            .expect("a permanent hold keeps it");
        assert!(kept.held_by(&permanent) && !kept.held_by(&expired));
        assert_eq!(kept.view().expires_ms, None, "a permanent hold has no expiry");
        let link = link_of(None, &kept.restore).expect("link");
        assert_eq!(link.state, "restoring");
        state.connections.retain(|c| c.service != service);
    }

    #[test]
    fn reopening_backs_off_to_a_minute() {
        assert_eq!(backoff_ms(1), 2_000);
        assert_eq!(backoff_ms(3), 8_000);
        assert_eq!(backoff_ms(40), 60_000);
    }
}
