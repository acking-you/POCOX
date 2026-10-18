//! Context-scoped native gateway subscriptions and stream health.

use std::time::Duration;

use super::{super::transport::Owned, *};

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
pub fn connect(service: &str, port: u16, owned: &Owned) -> Result<()> {
    let context = Context::of(&owned.transport);
    let key = key_in(&context, service)?;
    let lifecycle = lifecycle(&key);
    let _guard = lock(&lifecycle);
    if lock(&CONNS)
        .get(&key)
        .is_some_and(|c| !c.task.is_finished() && lock(&c.shared).healthy)
    {
        return Ok(());
    }
    remove(&key);
    let subscription = format!("opencode\u{1f}{}\u{1f}{}", key.0, key.1);
    let address = match super::super::serve_opencode::local_gateway(&key.1, &context) {
        Some(local) => local,
        None => {
            runtime::subscribe_service_as(
                subscription.clone(),
                &key.1,
                port,
                &owned.transport,
                || transport::is_current(owned.epoch),
            )?
            .local_addr
        },
    };
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
    };
    let mut registry = lock(&CONNS);
    if transport::epoch() != owned.epoch {
        drop(registry);
        dispose(connection);
        bail!("the account or relay changed while connecting; try again");
    }
    registry.insert(key, connection);
    let _ = start.send(());
    Ok(())
}

/// Live health of this controller, independently of host-owned turns.
pub fn is_connected(service: &str) -> bool {
    let Ok(key) = current_key(service) else { return false };
    lock(&CONNS)
        .get(&key)
        .is_some_and(|c| !c.task.is_finished() && lock(&c.shared).healthy)
}

/// Release only this controller's subscription and task.
pub fn disconnect(service: &str) {
    if let Ok(key) = current_key(service) {
        let lifecycle = lifecycle(&key);
        let _guard = lock(&lifecycle);
        remove(&key);
    }
}

/// Invalidate every connection of the previous account or relay.
pub fn context_changed() {
    let all: Vec<_> = lock(&CONNS).drain().map(|(_, conn)| conn).collect();
    for conn in all {
        dispose(conn);
    }
}

/// Test a transient subscription without retaining a controller connection.
pub fn probe_reason(service: &str, owned: &Owned) -> Option<String> {
    let attempt = || -> Result<()> {
        let context = Context::of(&owned.transport);
        let key = key_in(&context, service)?;
        let (address, task) = match super::super::serve_opencode::local_gateway(&key.1, &context) {
            Some(local) => (local, None),
            None => {
                let (address, task) = runtime::subscribe_transient(key.1, 0, &owned.transport)?;
                (address, Some(task))
            },
        };
        let result = runtime::runtime().block_on(async {
            tokio::time::timeout(Duration::from_secs(10), async {
                Gateway::new(&format!("http://{address}/"))?.info().await
            })
            .await
        });
        if let Some(task) = task {
            task.close();
        }
        result??;
        Ok(())
    };
    attempt().err().map(|error| format!("{error:#}"))
}
