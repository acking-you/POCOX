//! Real socket lifecycle through the retention owner; no external agent or
//! relay.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use futures::{SinkExt, StreamExt};
use pocox_pb::{RelaySession, Transport};
use serde_json::{json, Value};
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::Message;

use super::*;
use crate::engine::app_session;
use crate::engine::local_services::Registration;

struct Peer {
    address: SocketAddr,
    handshakes: Arc<AtomicUsize>,
    commands: broadcast::Sender<Value>,
    task: JoinHandle<()>,
}

impl Peer {
    fn new() -> Self {
        runtime::runtime().block_on(async {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("retention fixture");
            let address = listener.local_addr().expect("retention fixture");
            let handshakes = Arc::new(AtomicUsize::new(0));
            let count = handshakes.clone();
            let (commands, _) = broadcast::channel::<Value>(16);
            let events = commands.clone();
            let task = tokio::spawn(async move {
                let mut peers = tokio::task::JoinSet::new();
                loop {
                    let (socket, _) = listener.accept().await.expect("retention fixture");
                    let count = count.clone();
                    let mut events = events.subscribe();
                    peers.spawn(async move {
                        let mut ws = tokio_tungstenite::accept_async_with_config(socket, Some(Default::default())).await.expect("retention fixture");
                        loop {
                            tokio::select! {
                                message = ws.next() => {
                                    let Some(Ok(message)) = message else { break };
                                    let Message::Text(text) = message else { continue };
                                    let request: Value = serde_json::from_str(&text).expect("retention fixture");
                                    if request.get("method").is_none() || request.get("id").is_none() { continue; }
                                    if request["method"] == "initialize" { count.fetch_add(1, Ordering::SeqCst); }
                                    let result = if request["method"] == "turn/start" { json!({"turn":{"id":"turn"}}) } else { json!({"data":[],"nextCursor":null}) };
                                    if ws.send(Message::text(json!({"id": request["id"], "result": result}).to_string())).await.is_err() { break; }
                                }
                                event = events.recv() => {
                                    let Ok(event) = event else { break };
                                    if ws.send(Message::text(event.to_string())).await.is_err() { break; }
                                }
                            }
                        }
                    });
                }
            });
            Self { address, handshakes, commands, task }
        })
    }

    fn emit(&self, service: &str, event: Value) {
        let mut events = app_session::subscribe_events(service).expect("retention fixture");
        self.commands.send(event).expect("retention fixture");
        runtime::runtime().block_on(async {
            tokio::time::timeout(Duration::from_secs(2), events.recv())
                .await
                .expect("retention fixture")
                .expect("retention fixture");
        });
    }
}

impl Drop for Peer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

#[test]
fn retained_sockets_evict_idle_services_and_fence_retired_owners() {
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("retention fixture");
    let context = transport::Context::of(&Transport {
        session: RelaySession::for_test("127.0.0.1:9"),
        namespace: Some("window-test".into()),
    });
    transport::test_context(context.clone());
    let a = "pcx:window-test:app:a";
    let b = "pcx:window-test:app:b";
    let c = "pcx:window-test:app:c";
    let peers = [Peer::new(), Peer::new(), Peer::new()];
    let mut registration = Registration::new(&context, &[
        (a.into(), peers[0].address),
        (b.into(), peers[1].address),
        (c.into(), peers[2].address),
    ])
    .expect("retention fixture");
    let mut window = Window::default();
    let settings = ConnectionWindowConfig {
        capacity: 2,
        ..Default::default()
    };
    let epoch = transport::epoch();
    for service in [a, b, a] {
        window
            .connect(service.into(), 0, settings, epoch)
            .expect("retention fixture");
    }
    assert_eq!(peers[0].handshakes.load(Ordering::SeqCst), 1, "switching back reuses the socket");
    window
        .connect(c.into(), 0, settings, epoch)
        .expect("retention fixture");
    assert!(app_session::is_connected(a));
    assert!(!app_session::is_connected(b), "LRU releases the complete idle connection");
    assert!(runtime::list_subscriptions()
        .iter()
        .all(|entry| entry.key != b));

    // Acceptance precedes turn/started: switching must already protect it.
    app_session::turn_start(
        a,
        "work",
        "run".into(),
        Vec::new(),
        None,
        None,
        None,
        None,
        None,
        None,
        None,
    )
    .expect("retention fixture");
    peers[2].emit(c, json!({"id":42,"method":"item/tool/requestUserInput","params":{"threadId":"question","questions":[]}}));
    assert_eq!(app_session::pending_requests(c).len(), 1);
    assert!(
        window.connect(b.into(), 0, settings, epoch).is_err(),
        "busy services cannot be evicted"
    );
    assert!(app_session::is_connected(a) && app_session::is_connected(c));
    assert!(!app_session::is_connected(b), "failed admission releases its staging connection");
    assert_eq!(window.selected.as_deref(), Some(c));

    let smaller = ConnectionWindowConfig {
        capacity: 1,
        ..settings
    };
    assert!(!window.trim(smaller, c, 0), "shrinking cannot interrupt a turn");
    peers[0].emit(
        a,
        json!({"method":"turn/completed","params":{"threadId":"work","turn":{"id":"turn"}}}),
    );
    assert!(window.trim(smaller, c, 0));
    assert!(!app_session::is_connected(a));
    assert!(app_session::is_connected(c));

    registration.suspend();
    window.refresh();
    assert!(window.entries.is_empty());
    assert!(
        window.connect(c.into(), 0, settings, epoch).is_err(),
        "a stopped local host cannot fall back to a relay"
    );
    registration.resume().expect("retention fixture");
    window
        .connect(c.into(), 0, settings, epoch)
        .expect("retention fixture");
    assert_eq!(
        peers[2].handshakes.load(Ordering::SeqCst),
        2,
        "same-port restart requires a fresh socket"
    );
    let closed = std::net::TcpListener::bind("127.0.0.1:0").expect("retention fixture");
    let failed = "pcx:window-test:app:failed";
    let _failed_registration = Registration::new(&context, &[(
        failed.into(),
        closed.local_addr().expect("retention fixture"),
    )])
    .expect("retention fixture");
    drop(closed);
    assert!(window.connect(failed.into(), 0, smaller, epoch).is_err());
    assert_eq!(
        window.selected.as_deref(),
        Some(c),
        "failed handshakes preserve the selected service"
    );
    assert!(app_session::is_connected(c));
    transport::context_changed();
    window.refresh();
    assert!(window.entries.is_empty() && window.selected.is_none());
    assert!(
        window.connect(c.into(), 0, settings, epoch).is_err(),
        "queued old-context selections cannot reconnect"
    );
    assert!(!app_session::is_connected(c));
}
