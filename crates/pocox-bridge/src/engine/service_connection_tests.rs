//! Real loopback protocol exchanges without a relay or account backend.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use axum::http::StatusCode;
use axum::response::sse::{Event, KeepAlive};
use axum::response::Sse;
use axum::routing::get;
use axum::{Json, Router};
use futures::{SinkExt, StreamExt};
use pocox_pb::{RelaySession, Transport};
use serde_json::{json, Value};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::Message;

use super::*;
use crate::engine::local_services::Registration;
use crate::engine::{app_session, discovery, meta, session_engine};

fn context(relay: &str, namespace: Option<&str>) -> Context {
    Context::of(&Transport {
        session: RelaySession::for_test(relay),
        namespace: namespace.map(str::to_string),
    })
}

fn websocket(counter: Arc<AtomicUsize>) -> (SocketAddr, JoinHandle<()>) {
    runtime::runtime().block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("listen");
        let address = listener.local_addr().expect("address");
        let server = tokio::spawn(async move {
            let mut peers = tokio::task::JoinSet::new();
            loop {
                let (socket, _) = listener.accept().await.expect("accept");
                let counter = counter.clone();
                peers.spawn(async move {
                    let mut ws = tokio_tungstenite::accept_async_with_config(socket, Some(Default::default())).await.expect("websocket");
                    while let Some(Ok(message)) = ws.next().await {
                        let Message::Text(text) = message else { continue };
                        let request: Value = serde_json::from_str(&text).expect("RPC");
                        if request.get("id").is_none() { continue; }
                        counter.fetch_add(1, Ordering::SeqCst);
                        let mut reply = json!({"id": request["id"]});
                        match request["method"].as_str() {
                            Some("initialize") => reply["result"] = json!({"userAgent":"fixture"}),
                            Some("thread/list") => reply["result"] = json!({"data":[],"nextCursor":null}),
                            _ => reply["error"] = json!({"code":-32000,"message":"session is held by another writer"}),
                        }
                        if ws.send(Message::text(reply.to_string())).await.is_err() { break; }
                    }
                });
            }
        });
        (address, server)
    })
}

fn metadata() -> (SocketAddr, JoinHandle<()>) {
    runtime::runtime().block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("listen");
        let address = listener.local_addr().expect("address");
        let app = Router::new()
            .route(
                "/projects",
                get(|| async { Json(json!({"project_roots":[],"default_project":"fixture"})) }),
            )
            .route("/acp/v1/info", get(|| async { Json(acp_info()) }))
            .route("/acp/v1/snapshot", get(|| async {
                Json(json!({"info":acp_info(),"generation":1,"seq":0,"sessions":[],"permissions":[],"recentTurns":[]}))
            }))
            .route("/acp/v1/events", get(events))
            .route("/opencode/v1/info", get(|| async {
                let mut info = identity();
                info["api"] = json!(1);
                info["protocol"] = json!("opencode-http");
                info["version"] = json!("fixture");
                Json(info)
            }))
            .route("/opencode/v1/catalog", get(|| async {
                Json(json!({"identity":identity(),"data":{"models":[],"agents":[],"commands":[],"defaults":{},"providersConnected":0}}))
            }))
            .route("/opencode/v1/sessions", get(|| async { Json(json!({"identity":identity(),"data":[]})) }))
            .route("/opencode/v1/events", get(events))
            .fallback(|| async { StatusCode::FORBIDDEN });
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.expect("serve");
        });
        (address, server)
    })
}

fn acp_info() -> Value {
    json!({"api":1,"hostId":"fixture","phase":{"state":"ready"},"capabilities":{}})
}

fn identity() -> Value {
    json!({"hostId":"fixture","generation":1,"sourceGeneration":"source"})
}

async fn events() -> Sse<impl futures::Stream<Item = Result<Event, std::convert::Infallible>>> {
    Sse::new(futures::stream::pending()).keep_alive(KeepAlive::default())
}

#[test]
fn local_protocols_bypass_relay_and_retire_with_the_host() {
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("runtime");
    // Any accidental relay setup is observable, not merely a faster timeout.
    let relay = std::net::TcpListener::bind("127.0.0.1:0").expect("unused relay");
    relay.set_nonblocking(true).expect("nonblocking");
    let context =
        context(&relay.local_addr().expect("relay address").to_string(), Some("local-test"));
    transport::test_context(context.clone());
    let app = "pcx:local-test:app:direct";
    let meta_key = "pcx:local-test:meta:direct";
    let api = "pcx:local-test:api:direct";
    let gateways = ["pcx:local-test:acp:direct", "pcx:local-test:opencode:direct"];
    let counter = Arc::new(AtomicUsize::new(0));
    let (address, ws) = websocket(counter.clone());
    let (meta_address, http) = metadata();
    let register = |address| {
        Registration::new(&context, &[
            (app.into(), address),
            (meta_key.into(), meta_address),
            (api.into(), meta_address),
            (gateways[0].into(), meta_address),
            (gateways[1].into(), meta_address),
        ])
        .expect("register")
    };
    let host = register(address);
    let target = Target::resolve(app).expect("resolve without a relay credential");
    let origin = target
        .open(app, app.into(), 0, false)
        .expect("direct origin");
    assert_eq!(origin.address, address.to_string(), "no intermediate listener");
    assert!(discovery::local().iter().any(|id| id.key() == app));
    let engine = session_engine::engine(app);
    engine.connect(app.into(), 0).expect("protocol handshake");
    engine.connect(app.into(), 0).expect("reuse");
    assert_eq!(counter.load(Ordering::SeqCst), 1, "a live session reuses its handshake");
    assert!(engine.thread_list(app).expect("business RPC").is_empty());
    assert!(meta::default_projects_available(app).expect("local meta capability"));
    let projects = meta::project_config(app).expect("local meta request");
    assert_eq!(projects.default_project.as_deref(), Some("fixture"));
    assert!(
        meta::list_dir(app, "/outside").is_err(),
        "local transport preserves the HTTP permission failure"
    );
    assert!(
        engine.thread_resume(app, "foreign").is_err(),
        "the original protocol still refuses unadmitted writes"
    );
    assert!(app_session::probe_api(api.into(), &Target::resolve(api).expect("API route")));
    for gateway in gateways {
        let engine = session_engine::engine(gateway);
        assert!(engine
            .probe_reason(gateway.into())
            .expect("gateway probe")
            .is_none());
        engine
            .connect(gateway.into(), 0)
            .expect("gateway snapshot and live stream");
        engine
            .connect(gateway.into(), 0)
            .expect("reuse live gateway");
        assert!(engine.is_connected(gateway));
        assert!(
            engine.thread_resume(gateway, "foreign").is_err(),
            "gateway admission is preserved"
        );
    }
    let status = runtime::list_subscriptions()
        .into_iter()
        .find(|s| s.key == app)
        .expect("status");
    assert_eq!(status.path.path, runtime::TunnelPath::Local);
    assert_eq!(status.path.active_relay, 0);
    assert!(relay.accept().is_err(), "local discovery, connect and requests never dial the relay");

    drop(host);
    assert!(!origin.is_current());
    assert!(!app_session::is_connected(app), "retirement invalidates even an open socket");
    assert!(engine.model_list(app).is_err(), "retired connections cannot issue requests");
    assert!(Target::resolve(app).is_err(), "a stopped local target cannot fall back to relay");
    assert!(!discovery::local().iter().any(|id| id.key() == app));
    for gateway in gateways {
        assert!(
            !session_engine::engine(gateway).is_connected(gateway),
            "stop closes every protocol"
        );
    }
    let (replacement, new_ws) = websocket(counter.clone());
    let reopened = register(replacement);
    engine
        .connect(app.into(), 0)
        .expect("reconnect to replacement");
    assert_eq!(
        runtime::list_subscriptions()
            .into_iter()
            .find(|s| s.key == app)
            .expect("status")
            .local_addr,
        replacement.to_string()
    );
    assert!(!origin.is_current(), "a new host cannot revive an old snapshot");
    assert!(relay.accept().is_err(), "recovery is local too");
    engine.disconnect(app);
    drop(reopened);
    ws.abort();
    new_ws.abort();
    http.abort();
    transport::context_changed();
}

/// The status line of a plain HTTP request to `/projects` through `address`;
/// `None` when the connection is refused or closed unanswered.
fn http_status(address: &str) -> Option<String> {
    use std::io::{Read, Write};
    let mut stream = std::net::TcpStream::connect(address).ok()?;
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(5)))
        .ok()?;
    stream
        .write_all(b"GET /projects HTTP/1.1\r\nHost: fixture\r\nConnection: close\r\n\r\n")
        .ok()?;
    let mut reply = String::new();
    stream.read_to_string(&mut reply).ok()?;
    reply.lines().next().map(str::to_string)
}

#[test]
fn an_exposed_local_api_keeps_its_port_and_follows_its_host() {
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("runtime");
    let relay = std::net::TcpListener::bind("127.0.0.1:0").expect("unused relay");
    relay.set_nonblocking(true).expect("nonblocking");
    let context = context(&relay.local_addr().expect("relay address").to_string(), None);
    transport::test_context(context.clone());
    let api = "pcx:forward-test:api:direct";
    let (first, first_server) = metadata();
    let host = Registration::new(&context, &[(api.into(), first)]).expect("host");
    let exposed = Target::resolve(api)
        .expect("local")
        .expose(api, 0)
        .expect("forward");
    assert_eq!(exposed.path.path, runtime::TunnelPath::Local);
    assert!(exposed.alive);
    assert_ne!(exposed.local_addr, first.to_string(), "the chosen port, not the listener");
    let ok = Some("HTTP/1.1 200 OK".to_string());
    assert_eq!(http_status(&exposed.local_addr), ok);

    drop(host);
    let status = |key: &str| {
        runtime::list_subscriptions()
            .into_iter()
            .find(|s| s.key == key)
            .expect("still subscribed")
    };
    assert!(!status(api).alive, "a stopped host shows as dropped");
    assert_eq!(http_status(&exposed.local_addr), None, "and refuses, with no relay fallback");

    // A restarted host listens elsewhere; the chosen port reaches it.
    let (second, second_server) = metadata();
    let reopened = Registration::new(&context, &[(api.into(), second)]).expect("restart");
    assert!(status(api).alive);
    assert_eq!(http_status(&exposed.local_addr), ok);
    let again = Target::resolve(api)
        .expect("local")
        .expose(api, 0)
        .expect("again");
    assert_eq!(again.local_addr, exposed.local_addr, "a live forward keeps its port");

    // A WebSocket upgrade and its frames pass through unchanged, as the
    // Responses API's WebSocket GET needs.
    let streaming = "pcx:forward-test:api:streaming";
    let (socket, socket_server) = websocket(Arc::new(AtomicUsize::new(0)));
    let socket_host = Registration::new(&context, &[(streaming.into(), socket)]).expect("host");
    let forwarded = Target::resolve(streaming)
        .expect("local")
        .expose(streaming, 0)
        .expect("forward");
    let reply = runtime::runtime().block_on(async {
        let (mut ws, _) =
            tokio_tungstenite::connect_async(format!("ws://{}/", forwarded.local_addr))
                .await
                .expect("upgrade through the forward");
        ws.send(Message::text(json!({"id": 1, "method": "initialize"}).to_string()))
            .await
            .expect("send");
        let Some(Ok(Message::Text(reply))) = ws.next().await else { panic!("no reply") };
        reply.to_string()
    });
    assert!(reply.contains("fixture"), "{reply}");
    runtime::unsubscribe_service(streaming);
    drop(socket_host);
    socket_server.abort();
    assert!(
        matches!(relay.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock),
        "nothing dialled the relay"
    );
    runtime::unsubscribe_service(api);
    drop(reopened);
    first_server.abort();
    second_server.abort();
    transport::context_changed();
}

#[test]
fn ownership_requires_the_exact_service_context_and_live_incarnation() {
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("runtime");
    let alice = context("offline.test:1", Some("alice"));
    let bob = context("offline.test:1", Some("bob"));
    let other_relay = context("other.test:1", Some("alice"));
    let service = "pcx:same-label:api:identity-test";
    let address: SocketAddr = "127.0.0.1:10101".parse().expect("address");
    let first = Registration::new(&alice, &[(service.into(), address)]).expect("host");
    let old = local_services::lookup(&alice, service)
        .expect("lookup")
        .expect("local");
    assert!(local_services::lookup(&bob, service)
        .expect("other account")
        .is_none());
    assert!(local_services::lookup(&other_relay, service)
        .expect("other relay")
        .is_none());
    assert!(local_services::lookup(&alice, "pcx:same-label:api:other")
        .expect("other service")
        .is_none());
    assert!(local_services::lookup(&alice, "pcxu:bob:same-label:api:identity-test").is_err());
    assert!(local_services::lookup(&alice, "pcxu:alice:same-label:api:identity-test")
        .expect("namespace")
        .is_some());
    drop(first);
    let mut second =
        Registration::new(&alice, &[(service.into(), address)]).expect("same port, new lifetime");
    assert!(!old.is_current());
    let before_restart = local_services::lookup(&alice, service)
        .expect("lookup")
        .expect("host");
    second.suspend();
    assert!(local_services::lookup(&alice, service).is_err());
    second.resume().expect("in-place restart");
    assert!(!before_restart.is_current(), "reusing a port cannot revive an old client");
    drop(second);
    assert!(Registration::new(&alice, &[(
        service.into(),
        "192.0.2.1:80".parse().expect("remote")
    )])
    .is_err());
}

#[test]
fn fresh_process_rebuilds_routes_from_owned_hosts() {
    const STATE: &str = "POCOX_LOCAL_ROUTE_TEST_STATE";
    if let Some(directory) = std::env::var_os(STATE) {
        let directory = std::path::PathBuf::from(directory);
        runtime::init(directory.clone()).expect("isolated runtime");
        runtime::configure_host(runtime::HostContext {
            device: runtime::device_id().expect("persistent identity"),
            profiles: directory.join("hosting"),
            transport: None,
        })
        .expect("isolated hosting state");
        crate::engine::host_owner::claim_desktop();
        crate::engine::host_owner::require().expect("this process owns the hosting lock");
        let context = context("127.0.0.1:1", None);
        transport::test_context(context.clone());
        let service = format!("pcx:{}:app:reopen", runtime::device_id().expect("identity"));
        let marker = directory.join("previous-service.txt");
        if let Ok(previous) = std::fs::read_to_string(&marker) {
            assert_eq!(previous, service, "reopening retains device identity");
        }
        assert!(local_services::lookup(&context, &service)
            .expect("new registry")
            .is_none());
        let (address, socket) = websocket(Arc::new(AtomicUsize::new(0)));
        let host = Registration::new(&context, &[(service.clone(), address)]).expect("new host");
        let engine = session_engine::engine(&service);
        engine
            .connect(service.clone(), 0)
            .expect("fresh process connects locally");
        std::fs::write(marker, &service).expect("record identity");
        drop(host);
        assert!(!engine.is_connected(&service));
        socket.abort();
        crate::engine::host_owner::release_desktop().expect("release after cleanup");
        return;
    }
    let directory = tempfile::tempdir().expect("isolated app state");
    for _ in 0..2 {
        let output = std::process::Command::new(std::env::current_exe().expect("test executable"))
            .args([
                "--exact",
                "engine::service_connection::tests::fresh_process_rebuilds_routes_from_owned_hosts",
                "--nocapture",
            ])
            .env(STATE, directory.path())
            .output()
            .expect("fresh process");
        assert!(
            output.status.success(),
            "fresh process failed: {} {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
}
