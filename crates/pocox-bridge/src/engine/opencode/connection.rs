//! Context-scoped native gateway subscriptions and stream health.

use std::time::Duration;

use super::super::connect_stage::{self, ConnectStage};
use super::super::service_connection::Target;
use super::*;

fn remove(key: &Key) {
    let removed = lock(&CONNS).remove(key);
    if let Some(conn) = removed {
        dispose(conn);
    }
}

fn dispose(conn: Conn) {
    conn.task.abort();
    runtime::unsubscribe_service(&conn.subscription);
    let _ = conn.tx.send(projection::health(false));
}

/// Connect to this context's native gateway, with a stream before publication.
pub(crate) fn connect(service: &str, port: u16, owned: &Target) -> Result<()> {
    let context = owned.context();
    let key = key_in(&context, service)?;
    let lifecycle = lifecycle(&key);
    let _guard = lock(&lifecycle);
    if lock(&CONNS)
        .get(&key)
        .is_some_and(|c| running(c) && lock(&c.shared).healthy)
    {
        return Ok(());
    }
    // A stale connection goes, but its live tunnel stays for the new one: the
    // SDK recovers it on its own. A failed attempt below releases it too.
    let stale = lock(&CONNS).remove(&key);
    if let Some(stale) = stale {
        stale.task.abort();
        let _ = stale.tx.send(projection::health(false));
    }
    let subscription = format!("opencode\u{1f}{}\u{1f}{}", key.0, key.1);
    let origin = owned
        .open(&key.1, subscription.clone(), port, false)
        .inspect_err(|_| runtime::unsubscribe_service(&subscription))?;
    let address = &origin.address;
    connect_stage::enter(service, ConnectStage::Session);
    let opened = runtime::runtime().block_on(async {
        let client = Gateway::new(&format!("http://{}/", address))?;
        let info = client.info().await?;
        let stream = client.events(&info.identity, 0).await?;
        let catalog = client.catalog(None, &info.identity).await?;
        Ok::<_, ClientError>((client, info, stream, catalog))
    });
    let (client, info, stream, catalog) = match opened {
        Ok(opened) => opened,
        Err(error) => {
            runtime::unsubscribe_service(&subscription);
            return Err(error.into());
        },
    };
    let shared = Arc::new(Mutex::new(Shared {
        info,
        image_input: catalog.models.iter().any(|model| model.images),
        healthy: true,
        sessions: HashMap::new(),
        bytes: HashMap::new(),
        cursors: HashMap::new(),
        turn_pages: HashMap::new(),
        admitted: HashMap::new(),
    }));
    let (tx, _) = broadcast::channel(64);
    let link = Link {
        key: key.clone(),
        client: client.clone(),
        shared: shared.clone(),
        tx: tx.clone(),
    };
    // The event task cannot commit before the connection enters the registry.
    let (start, ready) = tokio::sync::oneshot::channel();
    let task = runtime::runtime().spawn(async move {
        if ready.await.is_ok() {
            events::run(link, stream).await;
        }
    });
    let connection = Conn {
        client,
        shared,
        tx,
        task,
        subscription,
        local: origin.local,
    };
    let mut registry = lock(&CONNS);
    if transport::epoch() != owned.epoch()
        || connection
            .local
            .as_ref()
            .is_some_and(|local| !local.is_current())
    {
        drop(registry);
        dispose(connection);
        bail!("the account or relay changed while connecting; try again");
    }
    registry.insert(key, connection);
    let _ = start.send(());
    Ok(())
}

/// Whether `conn`'s event task still runs (perhaps retrying an outage) and,
/// for a local host, still points at the host currently published here.
fn running(conn: &Conn) -> bool {
    !conn.task.is_finished()
        && conn
            .local
            .as_ref()
            .is_none_or(super::super::local_services::Endpoint::is_current)
}

/// Live health of this controller, independently of host-owned turns.
pub fn is_connected(service: &str) -> bool {
    let Ok(key) = current_key(service) else { return false };
    lock(&CONNS)
        .get(&key)
        .is_some_and(|c| running(c) && lock(&c.shared).healthy)
}

/// Whether this controller's connection may still come back on its own: its
/// event task retries a dropped stream, so an outage alone never ends it.
pub fn is_retained(service: &str) -> bool {
    let Ok(key) = current_key(service) else { return false };
    lock(&CONNS).get(&key).is_some_and(running)
}

/// Release only this controller's subscription and task.
pub fn disconnect(service: &str) {
    if let Ok(key) = current_key(service) {
        let lifecycle = lifecycle(&key);
        let _guard = lock(&lifecycle);
        remove(&key);
    }
}

/// The registry and event loop own two references; any other reference pins
/// outstanding operations. Running turns and unanswered requests also pin it.
fn busy(conn: &Conn) -> bool {
    let view = lock(&conn.shared);
    Arc::strong_count(&conn.shared) > 2
        || !view.admitted.is_empty()
        || view.sessions.values().any(|snapshot| {
            snapshot.turn_id.is_some()
                || !snapshot.permissions.is_empty()
                || !snapshot.questions.is_empty()
        })
}

/// Whether [`evict_idle`] would release `service` now, without releasing it.
pub(crate) fn is_idle(service: &str) -> bool {
    let Ok(key) = current_key(service) else { return true };
    !lock(&CONNS).get(&key).is_some_and(busy)
}

/// Release `service` unless it is [`busy`].
pub(crate) fn evict_idle(service: &str) -> bool {
    let Ok(key) = current_key(service) else { return true };
    let lifecycle = lifecycle(&key);
    let _guard = lock(&lifecycle);
    let mut registry = lock(&CONNS);
    if registry.get(&key).is_some_and(busy) {
        return false;
    }
    let removed = registry.remove(&key);
    drop(registry);
    if let Some(conn) = removed {
        dispose(conn);
    }
    true
}

/// Invalidate every connection of the previous account or relay.
pub fn context_changed() {
    let all: Vec<_> = lock(&CONNS).drain().map(|(_, conn)| conn).collect();
    for conn in all {
        dispose(conn);
    }
}

/// Retiring a local host closes its controller streams immediately.
pub(crate) fn local_stopped() {
    let mut registry = lock(&CONNS);
    let keys: Vec<_> = registry
        .iter()
        .filter(|(_, conn)| conn.local.as_ref().is_some_and(|local| !local.is_current()))
        .map(|(key, _)| key.clone())
        .collect();
    let retired: Vec<_> = keys.iter().filter_map(|key| registry.remove(key)).collect();
    drop(registry);
    for conn in retired {
        dispose(conn);
    }
}

/// Test a transient subscription without retaining a controller connection.
pub(crate) fn probe_reason(service: &str, owned: &Target) -> Option<String> {
    let attempt = || -> Result<()> {
        let context = owned.context();
        let key = key_in(&context, service)?;
        let origin = owned.open(&key.1, String::new(), 0, true)?;
        let address = &origin.address;
        let result = runtime::runtime().block_on(async {
            tokio::time::timeout(Duration::from_secs(10), async {
                Gateway::new(&format!("http://{address}/"))?.info().await
            })
            .await
        });
        let current = origin.is_current() && transport::is_current(owned.epoch());
        origin.close_probe();
        anyhow::ensure!(current, "the host or connection changed; reconnect");
        result??;
        Ok(())
    };
    attempt().err().map(|error| format!("{error:#}"))
}
