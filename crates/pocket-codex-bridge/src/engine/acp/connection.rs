//! Establishing and dropping connections: the gateway origin (loopback for
//! a host of this process, else a relay subscription), the opening
//! snapshot and stream, registration under the transport epoch, and
//! probes.

use super::*;

/// Where a connection reaches its gateway.
struct Origin {
    pub(super) url: String,
    /// The relay subscription made for it (registry key), if any.
    pub(super) subscription: Option<String>,
    /// The loopback gateway, when hosted here.
    pub(super) local: Option<String>,
    /// A transient tunnel to abort when done (probes).
    pub(super) transient: Option<runtime::TransientSubscription>,
}

impl Origin {
    fn release(&self) {
        if let Some(subscription) = &self.subscription {
            runtime::unsubscribe_service(subscription);
        }
    }
}

/// Resolve the gateway origin. A host this process owns under the same
/// context is reached on loopback — decided before any relay work; anything
/// else through a relay subscription scoped to the context.
fn origin(
    key: &Key,
    context: &Context,
    local_port: u16,
    owned: &Owned,
    transient: bool,
) -> Result<Origin> {
    let transport = &owned.transport;
    if let Some(gateway) = crate::engine::serve_acp::local_gateway(&key.1, context) {
        return Ok(Origin {
            url: format!("http://{gateway}/"),
            subscription: None,
            local: Some(gateway),
            transient: None,
        });
    }
    if transient {
        let (addr, handle) = runtime::subscribe_transient(key.1.clone(), local_port, transport)?;
        return Ok(Origin {
            url: format!("http://{addr}/"),
            subscription: None,
            local: None,
            transient: Some(handle),
        });
    }
    let registry = subscription_key(key);
    let epoch = owned.epoch;
    let sub =
        runtime::subscribe_service_as(registry.clone(), &key.1, local_port, transport, || {
            transport::is_current(epoch)
        })?;
    Ok(Origin {
        url: format!("http://{}/", sub.local_addr),
        subscription: Some(registry),
        local: None,
        transient: None,
    })
}

pub(super) fn check_api(snapshot: &Value) -> Result<()> {
    match snapshot["info"]["api"].as_u64() {
        Some(1) => Ok(()),
        Some(other) => bail!("this agent host speaks gateway API {other}; update POCOX"),
        None => bail!("the service did not answer like a POCOX ACP gateway"),
    }
}

/// A fresh snapshot and an event stream opened at its watermark: a view
/// that is healthy from its first moment.
async fn open(client: &GatewayClient) -> Result<(Value, EventStream)> {
    let snapshot = client
        .snapshot()
        .await
        .map_err(|error| anyhow!("{error}"))?;
    check_api(&snapshot)?;
    let host_id = snapshot["info"]["hostId"].as_str().map(str::to_string);
    let generation = snapshot["generation"].as_u64().unwrap_or(0);
    let seq = snapshot["seq"].as_u64().unwrap_or(0);
    let stream = client
        .events(host_id.as_deref(), generation, seq)
        .await
        .map_err(|error| match error {
            ClientError::Host {
                ..
            } => anyhow!(
                "the agent host refused another live connection (too many are open); close one \
                 and try again"
            ),
            other => anyhow!("{other}"),
        })?;
    Ok((snapshot, stream))
}

/// Connect (idempotent while the connection is healthy and current). The
/// connection belongs to the context `owned` was resolved in and is
/// registered only while that context is current.
pub fn connect(service_key: &str, local_port: u16, owned: &Owned) -> Result<()> {
    let context = Context::of(&owned.transport);
    let epoch = owned.epoch;
    let key = key_in(&context, service_key)?;
    let lifecycle = lifecycle(&key);
    let _guard = lifecycle
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    if is_current(&key, &context) {
        return Ok(());
    }
    disconnect_inner(&key);
    let origin = origin(&key, &context, local_port, owned, false)?;
    let client = match GatewayClient::new(&origin.url) {
        Ok(client) => client,
        Err(error) => {
            origin.release();
            return Err(anyhow!("{error}"));
        },
    };
    let opened = runtime::runtime()
        .block_on(async { tokio::time::timeout(CONNECT_TIMEOUT, open(&client)).await })
        .context("the agent host did not answer in time")
        .and_then(|opened| opened);
    let (snapshot, stream) = match opened {
        Ok(opened) => opened,
        Err(error) => {
            origin.release();
            return Err(error);
        },
    };
    let (tx, _) = broadcast::channel(EVENT_BUFFER);
    let shared = Arc::new(Mutex::new(Shared::default()));
    // Seed the view now, so capabilities and state are there when this
    // returns; nobody listens yet, so its events go nowhere. Its stream is
    // already open, so it is healthy.
    {
        let mut view = lock(&shared);
        let _ = translate::reconcile(&mut view, &snapshot);
        view.healthy = true;
    }
    let watch = Watch {
        logical: key.1.clone(),
        context: context.clone(),
        local: origin.local.clone(),
    };
    // The event task recovers running folds from this snapshot before it
    // streams, so a controller joining mid-turn starts aligned.
    let task = runtime::runtime().spawn(event_loop(
        client.clone(),
        tx.clone(),
        shared.clone(),
        snapshot,
        Some(stream),
        watch,
    ));
    register(
        key,
        Conn {
            client,
            tx,
            task,
            shared,
            subscription: origin.subscription,
            local: origin.local,
        },
        epoch,
    )
}

/// Register `conn` unless the context changed since `epoch` was read: then
/// it belongs to the old context, is released instead and must not outlive
/// the change (see [`context_changed`]).
pub(super) fn register(key: Key, conn: Conn, epoch: u64) -> Result<()> {
    let mut registry = conns();
    if transport::epoch() != epoch {
        drop(registry);
        release(conn);
        bail!("the account or relay changed while connecting; try again");
    }
    registry.insert(key, conn);
    Ok(())
}

/// Whether `key`'s connection is alive, its stream healthy, and — for a
/// local host — still pointing at the host currently published here.
pub(super) fn is_current(key: &Key, context: &Context) -> bool {
    let conns = conns();
    let Some(conn) = conns.get(key) else { return false };
    if conn.task.is_finished() || !lock(&conn.shared).healthy {
        return false;
    }
    match &conn.local {
        Some(local) => {
            crate::engine::serve_acp::local_gateway(&key.1, context).as_ref() == Some(local)
        },
        None => true,
    }
}

/// Whether a live, healthy connection exists in the current context.
pub fn is_connected(service_key: &str) -> bool {
    let Some(context) = transport::current_context() else { return false };
    let Ok(key) = key_in(&context, service_key) else { return false };
    is_current(&key, &context)
}

pub(super) fn disconnect_inner(key: &Key) {
    let removed = conns().remove(key);
    if let Some(conn) = removed {
        release(conn);
    }
}

fn release(conn: Conn) {
    conn.task.abort();
    if let Some(subscription) = &conn.subscription {
        runtime::unsubscribe_service(subscription);
    }
    let _ = conn.tx.send(translate::host_unreachable());
}

/// Drop this controller's connection. Host-owned turns keep running.
pub fn disconnect(service_key: &str) {
    if let Ok(key) = current_key(service_key) {
        let lifecycle = lifecycle(&key);
        let _guard = lifecycle
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        disconnect_inner(&key);
    }
}

/// The transport context changed: every connection belongs to the old one.
/// Runs after [`transport::epoch`] moved, under the registry lock, so a
/// connection still being established either is drained here or sees the
/// new epoch and discards itself.
pub fn context_changed() {
    let all: Vec<Conn> = conns().drain().map(|(_, conn)| conn).collect();
    for conn in all {
        release(conn);
    }
}

/// Why the service is unreachable or unusable, or `None` when it is ready.
pub fn probe_reason(service_key: &str, owned: &Owned) -> Option<String> {
    let context = Context::of(&owned.transport);
    let key = match key_in(&context, service_key) {
        Ok(key) => key,
        Err(error) => return Some(format!("{error:#}")),
    };
    if is_current(&key, &context) {
        return None;
    }
    let origin = match origin(&key, &context, 0, owned, true) {
        Ok(found) => found,
        Err(error) => return Some(format!("{error:#}")),
    };
    let reason = GatewayClient::new(&origin.url)
        .map_err(|error| anyhow!("{error}"))
        .and_then(|client| {
            runtime::runtime()
                .block_on(async { tokio::time::timeout(CONNECT_TIMEOUT, client.info()).await })
                .context("the agent host did not answer in time")?
                .map_err(|error| anyhow!("{error}"))
        })
        .map(|info| match info["phase"]["state"].as_str() {
            Some("ready") => None,
            Some("failed") => Some(
                info["phase"]["reason"]
                    .as_str()
                    .unwrap_or("the agent failed to start")
                    .to_string(),
            ),
            Some("stopped") => Some("the agent is stopped on its host".to_string()),
            _ => Some("the agent is starting".to_string()),
        })
        .unwrap_or_else(|error| Some(format!("{error:#}")));
    if let Some(handle) = origin.transient {
        handle.close();
    }
    reason
}
