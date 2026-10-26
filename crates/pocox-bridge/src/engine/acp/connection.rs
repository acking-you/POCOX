//! Establishing and dropping connections: the gateway origin (loopback for
//! a host of this process, else a relay subscription), the opening
//! snapshot and stream, registration under the transport epoch, and
//! probes.

use super::*;
use crate::engine::connect_stage::{self, ConnectStage};
use crate::engine::service_connection::{Origin, Target};

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
pub(crate) fn connect(service_key: &str, local_port: u16, owned: &Target) -> Result<()> {
    let context = owned.context();
    let epoch = owned.epoch();
    let key = key_in(&context, service_key)?;
    let lifecycle = lifecycle(&key);
    let _guard = lifecycle
        .lock()
        .unwrap_or_else(|poison| poison.into_inner());
    if is_current(&key, &context) {
        return Ok(());
    }
    // A stale connection goes, but its live tunnel stays for the new one: the
    // SDK recovers it on its own. A failed attempt below releases it too.
    let stale = conns().remove(&key);
    if let Some(stale) = &stale {
        close(stale);
    }
    let origin = owned.open(&key.1, subscription_key(&key), local_port, false);
    // A tunnel the new connection does not reuse (it failed, or the host is
    // now reached on loopback) is the old one's alone.
    let kept = origin
        .as_ref()
        .ok()
        .and_then(|origin| origin.subscription.as_ref());
    if let Some(old) = stale.as_ref().and_then(|stale| stale.subscription.as_ref()) {
        if kept != Some(old) {
            runtime::unsubscribe_service(old);
        }
    }
    let origin = origin?;
    connect_stage::enter(service_key, ConnectStage::Session);
    let client = match GatewayClient::new(&origin.url()) {
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
    if transport::epoch() != epoch || conn.local.as_ref().is_some_and(|local| !local.is_current()) {
        drop(registry);
        release(conn);
        bail!("the account or relay changed while connecting; try again");
    }
    registry.insert(key, conn);
    Ok(())
}

/// Whether `conn`'s event loop still runs (perhaps retrying an outage) and,
/// for a local host, still points at the host currently published here.
fn running(conn: &Conn) -> bool {
    !conn.task.is_finished()
        && conn
            .local
            .as_ref()
            .is_none_or(crate::engine::local_services::Endpoint::is_current)
}

/// Whether `key`'s connection is running and its stream healthy.
pub(super) fn is_current(key: &Key, _context: &Context) -> bool {
    conns()
        .get(key)
        .is_some_and(|conn| running(conn) && lock(&conn.shared).healthy)
}

/// Whether a live, healthy connection exists in the current context.
pub fn is_connected(service_key: &str) -> bool {
    let Some(context) = transport::current_context() else { return false };
    let Ok(key) = key_in(&context, service_key) else { return false };
    is_current(&key, &context)
}

/// Whether a connection in the current context may still come back on its
/// own: its event loop retries a dropped stream, so an outage alone never
/// ends it.
pub fn is_retained(service_key: &str) -> bool {
    let Some(context) = transport::current_context() else { return false };
    let Ok(key) = key_in(&context, service_key) else { return false };
    conns().get(&key).is_some_and(running)
}

pub(super) fn disconnect_inner(key: &Key) {
    let removed = conns().remove(key);
    if let Some(conn) = removed {
        release(conn);
    }
}

fn release(conn: Conn) {
    close(&conn);
    if let Some(subscription) = &conn.subscription {
        runtime::unsubscribe_service(subscription);
    }
}

/// Stop `conn`'s events, telling its listeners the host is out of reach.
fn close(conn: &Conn) {
    conn.task.abort();
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

/// Release only idle controller state. The event loop holds one shared
/// reference; additional references belong to outstanding operations or follow
/// readers.
pub(crate) fn evict_idle(service_key: &str) -> bool {
    let Ok(key) = current_key(service_key) else { return true };
    let lifecycle = lifecycle(&key);
    let _guard = lifecycle.lock().unwrap_or_else(|e| e.into_inner());
    let mut registry = conns();
    if registry.get(&key).is_some_and(|conn| {
        let view = lock(&conn.shared);
        Arc::strong_count(&conn.shared) > 2
            || !view.running.is_empty()
            || !view.permissions.is_empty()
    }) {
        return false;
    }
    let removed = registry.remove(&key);
    drop(registry);
    if let Some(conn) = removed {
        release(conn);
    }
    true
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

/// Retiring a local host closes its controller streams immediately.
pub(crate) fn local_stopped() {
    let mut registry = conns();
    let keys: Vec<_> = registry
        .iter()
        .filter(|(_, conn)| conn.local.as_ref().is_some_and(|local| !local.is_current()))
        .map(|(key, _)| key.clone())
        .collect();
    let retired: Vec<_> = keys.iter().filter_map(|key| registry.remove(key)).collect();
    drop(registry);
    for conn in retired {
        release(conn);
    }
}

/// Why the service is unreachable or unusable, or `None` when it is ready.
pub(crate) fn probe_reason(service_key: &str, owned: &Target) -> Option<String> {
    let context = owned.context();
    let key = match key_in(&context, service_key) {
        Ok(key) => key,
        Err(error) => return Some(format!("{error:#}")),
    };
    if is_current(&key, &context) {
        return None;
    }
    host_info(service_key, owned)
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
        .unwrap_or_else(|error| Some(format!("{error:#}")))
}

/// Read the host's declared profile without opening a session or event stream.
/// The temporary tunnel is closed even on failure; stale context answers fail.
pub(crate) fn host_info(service_key: &str, owned: &Target) -> Result<Value> {
    let context = owned.context();
    let key = key_in(&context, service_key)?;
    let origin = owned.open(&key.1, subscription_key(&key), 0, true)?;
    read_info(origin, owned.epoch())
}

fn read_info(origin: Origin, epoch: u64) -> Result<Value> {
    let result = GatewayClient::new(&origin.url())
        .map_err(|error| anyhow!("{error}"))
        .and_then(|client| {
            runtime::runtime()
                .block_on(async { tokio::time::timeout(CONNECT_TIMEOUT, client.info()).await })
                .context("the agent host did not answer in time")?
                .map_err(|error| anyhow!("{error}"))
        });
    let current = origin.is_current() && transport::is_current(epoch);
    origin.close_probe();
    if !current {
        bail!("the account or relay changed while reading the agent identity");
    }
    result
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    use std::thread;

    use super::*;

    #[test]
    fn identity_reads_only_info_and_rejects_a_changed_transport() {
        let _serial = transport::test_serial();
        runtime::init(std::env::temp_dir()).expect("runtime");
        for change_context in [false, true] {
            let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
            let address = listener.local_addr().expect("address");
            let epoch = transport::epoch();
            let server = thread::spawn(move || {
                let (mut socket, _) = listener.accept().expect("request");
                socket
                    .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                    .expect("timeout");
                let mut request = String::new();
                BufReader::new(&socket)
                    .read_line(&mut request)
                    .expect("request line");
                assert_eq!(request.trim(), "GET /acp/v1/info HTTP/1.1");
                if change_context {
                    transport::context_changed();
                }
                let body = r#"{"api":1,"profile":{"id":"grok","displayName":"Grok Build"}}"#;
                write!(
                    socket,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \
                     {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .expect("response");
            });
            let connections = conns().len();
            let result = read_info(
                Origin {
                    address: address.to_string(),
                    subscription: None,
                    local: None,
                    remote: None,
                    transient: None,
                },
                epoch,
            );
            server.join().expect("server");
            if change_context {
                assert!(result.is_err(), "a previous account's identity is discarded");
            } else {
                let info = result.expect("identity");
                assert_eq!(info["profile"]["id"], "grok");
                assert_eq!(info["profile"]["displayName"], "Grok Build");
                assert_eq!(conns().len(), connections, "no live session registered");
            }
        }
    }
}
