use std::{collections::VecDeque, net::SocketAddr};

use pocket_codex_host_svc::acp::fold::Transcript;
use pocket_codex_pb::RelaySession;
use serde_json::json;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};

use super::*;
use crate::engine::{session_engine::Supplement, transport::Transport};

fn transport(namespace: Option<&str>, relay: &str) -> Transport {
    Transport {
        session: RelaySession::for_test(relay),
        namespace: namespace.map(str::to_string),
    }
}

/// A connection to nowhere, registered directly.
fn fake_conn(key: &Key, generation: u64) -> Arc<Mutex<Shared>> {
    fake_conn_at(key, generation, "http://127.0.0.1:9/")
}

/// A connection to the gateway at `url`, registered directly.
fn fake_conn_at(key: &Key, generation: u64, url: &str) -> Arc<Mutex<Shared>> {
    let shared = Arc::new(Mutex::new(Shared {
        generation,
        healthy: true,
        ..Shared::default()
    }));
    let (tx, _) = broadcast::channel(8);
    conns().insert(key.clone(), Conn {
        client: GatewayClient::new(url).expect("client"),
        tx,
        task: runtime::runtime().spawn(std::future::pending::<()>()),
        shared: shared.clone(),
        subscription: None,
        local: None,
    });
    shared
}

fn link_of(key: &Key) -> Link {
    let conns = conns();
    let conn = conns.get(key).expect("registered");
    Link {
        client: conn.client.clone(),
        shared: conn.shared.clone(),
        tx: conn.tx.clone(),
        key: key.clone(),
    }
}

#[test]
fn the_same_logical_key_in_two_contexts_is_two_connections() {
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("init");
    let alice = Context::of(&transport(Some("alice"), "relay:1"));
    let own = Context::of(&transport(None, "relay:1"));
    let service = "pcx:studio:acp:same-key-test";
    let a = key_in(&alice, service).expect("alice key");
    let b = key_in(&own, service).expect("self-host key");
    assert_ne!(a, b);
    let alice_view = fake_conn(&a, 3);
    let own_view = fake_conn(&b, 9);
    lock(&alice_view)
        .permissions
        .insert("h".into(), serde_json::json!({}));
    assert!(is_current(&a, &alice) && is_current(&b, &own));
    assert!(lock(&own_view).permissions.is_empty(), "permissions stay apart");
    {
        let view = lock(&alice_view);
        assert_eq!(capabilities_of(&view.info, view.generation).generation, 3);
    }
    disconnect_inner(&a);
    assert!(!is_current(&a, &alice));
    assert!(is_current(&b, &own), "disconnecting one leaves the other");
    disconnect_inner(&b);
}

#[test]
fn namespaced_keys_must_match_the_account() {
    let alice = Context::of(&transport(Some("alice"), "relay:1"));
    let own = Context::of(&transport(None, "relay:1"));
    assert!(key_in(&alice, "pcxu:alice:studio:acp:a").is_ok());
    assert!(key_in(&alice, "pcxu:bob:studio:acp:a").is_err(), "another account");
    assert!(key_in(&own, "pcxu:alice:studio:acp:a").is_err(), "not a self-host key");
    assert_eq!(
        key_in(&alice, "pcxu:alice:studio:acp:a").expect("key"),
        key_in(&alice, "pcx:studio:acp:a").expect("key"),
        "both shapes name one service"
    );
}

#[test]
fn an_unhealthy_connection_is_not_current_and_offers_nothing_optional() {
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("init");
    let own = Context::of(&transport(None, "relay:health"));
    let key = key_in(&own, "pcx:studio:acp:health-test").expect("key");
    let shared = fake_conn(&key, 1);
    {
        let mut view = lock(&shared);
        view.info =
            serde_json::json!({"phase": {"state": "ready"}, "capabilities": {"image": true}});
    }
    assert!(is_current(&key, &own));
    translate::disconnected(&mut lock(&shared));
    assert!(!is_current(&key, &own), "a failed stream is not a healthy connection");
    disconnect_inner(&key);
}

#[test]
fn a_context_change_drops_every_connection() {
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("init");
    let own = Context::of(&transport(None, "relay:change"));
    let key = key_in(&own, "pcx:studio:acp:change-test").expect("key");
    fake_conn(&key, 1);
    transport::context_changed();
    assert!(!is_current(&key, &own));
}

/// An answer that arrives after its connection was replaced (another
/// account, a reconnect, a replaced host) must not land in the new view.
#[test]
fn a_late_answer_never_lands_in_a_newer_connection() {
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("init");
    let own = Context::of(&transport(None, "relay:late"));
    let key = key_in(&own, "pcx:studio:acp:late-test").expect("key");
    let old_view = fake_conn(&key, 1);
    lock(&old_view).host_id = "old-host".into();
    let old = link_of(&key);
    let identity = old.identity();
    // The request is in flight; the connection is replaced meanwhile.
    disconnect_inner(&key);
    let new_view = fake_conn(&key, 1);
    lock(&new_view).host_id = "new-host".into();
    assert!(old
        .commit(&identity, |view| view.sessions.insert("s".into(), json!({})))
        .is_none());
    assert!(lock(&new_view).sessions.is_empty(), "the new view is untouched");
    // The same connection, but the host moved to another generation.
    let current = link_of(&key);
    let seen = current.identity();
    lock(&new_view).generation = 2;
    assert!(current.commit(&seen, |_| ()).is_none());
    assert!(current.commit(&current.identity(), |_| ()).is_some());
    disconnect_inner(&key);
}

/// A connection established while the context changes must not be
/// registered afterwards (it would serve the old account), and its
/// resources are released.
#[test]
fn a_connection_that_races_a_context_change_is_discarded() {
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("init");
    let own = Context::of(&transport(None, "relay:race"));
    let key = key_in(&own, "pcx:studio:acp:race-test").expect("key");
    let epoch = transport::epoch();
    // The connection is being established (network I/O) ...
    let task = runtime::runtime().spawn(std::future::pending::<()>());
    let (tx, mut rx) = broadcast::channel(8);
    let conn = Conn {
        client: GatewayClient::new("http://127.0.0.1:9/").expect("client"),
        tx,
        task,
        shared: Arc::new(Mutex::new(Shared {
            healthy: true,
            ..Shared::default()
        })),
        subscription: None,
        local: None,
    };
    // ... when the account changes.
    transport::context_changed();
    assert!(register(key.clone(), conn, epoch).is_err());
    assert!(conns().get(&key).is_none(), "never registered");
    assert!(rx.try_recv().is_ok(), "its listeners are told it is gone");
    // Registering in the current epoch works.
    let fresh = fake_conn(&key, 1);
    assert!(lock(&fresh).healthy);
    disconnect_inner(&key);
}

// ---- A scripted gateway over real HTTP -------------------------------

#[derive(Default)]
struct Script {
    snapshot: Value,
    /// Turn → history answer; `None` → the read fails.
    history: HashMap<String, Value>,
    history_fails: bool,
    refuse_events: bool,
    /// Events the next stream sends after its headers.
    queued: VecDeque<Value>,
    live: Option<broadcast::Sender<Value>>,
    streams: usize,
    /// The status and answer of `sessions/steer`.
    steer: Option<(&'static str, Value)>,
    /// Request bodies `sessions/steer` received.
    steered: Vec<Value>,
    /// When set, `sessions/steer` answers only once this is notified.
    steer_gate: Option<Arc<tokio::sync::Notify>>,
}

struct FakeGateway {
    addr: SocketAddr,
    script: Arc<Mutex<Script>>,
    live: broadcast::Sender<Value>,
}

fn script(gateway: &FakeGateway) -> MutexGuard<'_, Script> {
    gateway
        .script
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
}

async fn fake_gateway(snapshot: Value) -> FakeGateway {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let addr = listener.local_addr().expect("addr");
    let (live, _) = broadcast::channel(64);
    let script = Arc::new(Mutex::new(Script {
        snapshot,
        live: Some(live.clone()),
        ..Script::default()
    }));
    tokio::spawn({
        let script = script.clone();
        async move {
            while let Ok((socket, _)) = listener.accept().await {
                tokio::spawn(serve_one(socket, script.clone()));
            }
        }
    });
    FakeGateway {
        addr,
        script,
        live,
    }
}

fn query(path: &str, name: &str) -> Option<String> {
    path.split_once('?')?
        .1
        .split('&')
        .filter_map(|pair| pair.split_once('='))
        .find(|(key, _)| *key == name)
        .map(|(_, value)| value.to_string())
}

async fn reply(socket: &mut TcpStream, status: &str, body: &Value) {
    let body = body.to_string();
    let head = format!(
        "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: \
         close\r\n\r\n",
        body.len()
    );
    let _ = socket.write_all(head.as_bytes()).await;
    let _ = socket.write_all(body.as_bytes()).await;
}

async fn serve_one(mut socket: TcpStream, script: Arc<Mutex<Script>>) {
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        if socket.read(&mut byte).await.unwrap_or(0) == 0 {
            return;
        }
        head.push(byte[0]);
    }
    let head = String::from_utf8_lossy(&head).to_string();
    let path = head.split_whitespace().nth(1).unwrap_or("").to_string();
    let lock = |script: &Mutex<Script>| {
        script
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .snapshot
            .clone()
    };
    if path.starts_with("/acp/v1/sessions/steer") {
        let length = head
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().ok())
                    .flatten()
            })
            .unwrap_or(0);
        let mut body = vec![0u8; length];
        if socket.read_exact(&mut body).await.is_err() {
            return;
        }
        let (status, answer, gate) = {
            let mut script = script.lock().unwrap_or_else(|poison| poison.into_inner());
            script
                .steered
                .push(serde_json::from_slice(&body).unwrap_or(Value::Null));
            let (status, answer) = script.steer.clone().unwrap_or(("404 Not Found", json!({})));
            (status, answer, script.steer_gate.clone())
        };
        if let Some(gate) = gate {
            gate.notified().await;
        }
        reply(&mut socket, status, &answer).await;
    } else if path.starts_with("/acp/v1/snapshot") {
        let snapshot = lock(&script);
        reply(&mut socket, "200 OK", &snapshot).await;
    } else if path.starts_with("/acp/v1/sessions/history") {
        let answer = {
            let script = script.lock().unwrap_or_else(|poison| poison.into_inner());
            let turn = query(&path, "turn").unwrap_or_default();
            (!script.history_fails)
                .then(|| script.history.get(&turn).cloned())
                .flatten()
        };
        match answer {
            Some(history) => reply(&mut socket, "200 OK", &history).await,
            None => {
                reply(&mut socket, "503 Service Unavailable", &json!({"code": "down"})).await;
            },
        }
    } else if path.starts_with("/acp/v1/events") {
        let (refuse, queued, live) = {
            let mut script = script.lock().unwrap_or_else(|poison| poison.into_inner());
            script.streams += 1;
            let queued: Vec<Value> = script.queued.drain(..).collect();
            (script.refuse_events, queued, script.live.clone())
        };
        if refuse {
            reply(&mut socket, "503 Service Unavailable", &json!({})).await;
            return;
        }
        let Some(live) = live else { return };
        let mut live = live.subscribe();
        let head = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncache-control: \
                    no-cache\r\nconnection: close\r\n\r\n";
        if socket.write_all(head.as_bytes()).await.is_err() {
            return;
        }
        for event in queued {
            let frame = format!("data: {event}\n\n");
            if socket.write_all(frame.as_bytes()).await.is_err() {
                return;
            }
        }
        loop {
            let frame = match tokio::time::timeout(Duration::from_secs(1), live.recv()).await {
                Ok(Ok(event)) => format!("data: {event}\n\n"),
                Ok(Err(_)) => return,
                Err(_) => ": keep\n\n".to_string(),
            };
            if socket.write_all(frame.as_bytes()).await.is_err() {
                return;
            }
        }
    } else {
        reply(&mut socket, "404 Not Found", &json!({})).await;
    }
}

fn snapshot(sessions: Value, recent: Value) -> Value {
    json!({
        "info": {"api": 1, "hostId": "h", "phase": {"state": "ready"},
            "capabilities": {"image": true}},
        "generation": 1, "seq": 5, "sessions": sessions, "permissions": [],
        "recentTurns": recent,
    })
}

fn chunk(text: &str) -> Value {
    json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})
}

/// The host's fold of turn `turn` after `chunks`, as a history answer at
/// watermark `seq`.
fn history_of(turn: &str, chunks: &[&str], seq: u64, running: bool) -> Value {
    let mut host = Transcript::default();
    host.begin_turn(turn, "q", &[]);
    for text in chunks {
        host.apply(Some(turn), &chunk(text));
    }
    let running_turn = if running { json!(turn) } else { Value::Null };
    json!({"window": [host.turns[0]], "truncated": false, "seq": seq, "generation": 1,
        "hostId": "h", "session": {"runningTurnId": running_turn}})
}

async fn drain(rx: &mut broadcast::Receiver<AppEvent>) -> Vec<AppEvent> {
    let mut out = Vec::new();
    while let Ok(Ok(event)) = tokio::time::timeout(Duration::from_millis(300), rx.recv()).await {
        out.push(event);
    }
    out
}

fn no_watch() -> Watch {
    Watch {
        logical: String::new(),
        context: Context::of(&transport(None, "relay:none")),
        local: None,
    }
}

/// A turn A finished while this controller was away and B now runs in
/// the same session: A completes first, B is announced after, and every
/// recovered item names its own turn.
#[tokio::test]
async fn recovery_completes_the_old_turn_before_announcing_its_successor() {
    let gateway = fake_gateway(snapshot(
        json!([{"sessionId": "s", "runningTurnId": "B"}]),
        json!([{"sessionId": "s", "turnId": "A", "outcome": {"kind": "stopped", "stopReason": "end_turn"}}]),
    ))
    .await;
    {
        let mut script = script(&gateway);
        script
            .history
            .insert("A".into(), history_of("A", &["old answer"], 5, false));
        script
            .history
            .insert("B".into(), history_of("B", &["new"], 5, true));
    }
    let client = GatewayClient::new(&format!("http://{}/", gateway.addr)).expect("client");
    let shared = Mutex::new(Shared::default());
    lock(&shared).running.insert("s".into(), "A".into());
    let (tx, mut rx) = broadcast::channel(64);
    let snapshot = script(&gateway).snapshot.clone();
    recover(&client, &tx, &shared, &snapshot).await;
    let events = drain(&mut rx).await;
    let position =
        |pred: &dyn Fn(&AppEvent) -> bool| events.iter().position(pred).expect("expected event");
    let turn_of = |event: &AppEvent| {
        serde_json::from_str::<Value>(&event.raw).expect("json")["turnId"]
            .as_str()
            .map(str::to_string)
    };
    let completed_a = position(&|e| e.kind == "turn/completed" && e.raw.contains("\"A\""));
    let started_b = position(&|e| e.kind == "turn/started" && e.raw.contains("\"B\""));
    let item_b = position(&|e| e.item_id.as_deref() == Some("B:m1"));
    assert!(completed_a < started_b, "A completes before B is announced");
    assert!(started_b < item_b);
    let item_a = &events[position(&|e| e.item_id.as_deref() == Some("A:m1"))];
    assert_eq!(turn_of(item_a).as_deref(), Some("A"));
    assert_eq!(turn_of(&events[item_b]).as_deref(), Some("B"));
    assert_eq!(events.last().map(|e| e.kind.as_str()), Some(translate::HOST_STATE));
    assert_eq!(lock(&shared).running.get("s").map(String::as_str), Some("B"));
}

/// History cannot be read when the controller joins mid-turn, and an
/// update arrives meanwhile. Nothing partial is shown; once history is
/// readable again the fold is installed on a timer — without another
/// event or reconnect — and the turn ends with the host's text and ids.
#[tokio::test]
async fn an_unreadable_fold_stays_unsynchronized_and_recovers_by_itself() {
    let gateway =
        fake_gateway(snapshot(json!([{"sessionId": "s", "runningTurnId": "t"}]), json!([]))).await;
    script(&gateway).history_fails = true;
    let client = GatewayClient::new(&format!("http://{}/", gateway.addr)).expect("client");
    let shared = Arc::new(Mutex::new(Shared::default()));
    let (tx, mut rx) = broadcast::channel(256);
    let first = script(&gateway).snapshot.clone();
    let task = tokio::spawn(event_loop(client, tx, shared.clone(), first, None, no_watch()));
    tokio::time::sleep(Duration::from_millis(200)).await;
    let _ = gateway
        .live
        .send(json!({"type": "update", "sessionId": "s", "turnId": "t",
        "seq": 6, "update": chunk(" world")}));
    let early = drain(&mut rx).await;
    assert!(
        early.iter().all(|e| e.item_id.is_none()),
        "no item is shown from an unseeded fold: {:?}",
        early.iter().map(|e| &e.kind).collect::<Vec<_>>()
    );
    assert!(lock(&shared).live.needs_fold("s", Some("t")), "explicitly unsynchronized");
    // History is readable again, reflecting everything up to seq 6.
    {
        let mut script = script(&gateway);
        script.history_fails = false;
        script
            .history
            .insert("t".into(), history_of("t", &["Hello", " world"], 6, true));
    }
    let mut seen = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(15);
    let synced = || {
        let view = lock(&shared);
        view.unsynced.is_empty() && !view.live.needs_fold("s", Some("t"))
    };
    while !synced() {
        assert!(Instant::now() < deadline, "the fold was never installed");
        seen.extend(drain(&mut rx).await);
    }
    let _ = gateway
        .live
        .send(json!({"type": "update", "sessionId": "s", "turnId": "t",
        "seq": 7, "update": chunk("!")}));
    let _ = gateway
        .live
        .send(json!({"type": "turn_ended", "sessionId": "s", "turnId": "t",
        "seq": 8, "outcome": {"kind": "stopped", "stopReason": "end_turn"}}));
    seen.extend(drain(&mut rx).await);
    task.abort();
    let mut text = String::new();
    for event in seen.iter().filter(|e| e.item_id.as_deref() == Some("t:m1")) {
        let piece = event.text.clone().unwrap_or_default();
        if event.kind.contains("delta") {
            text.push_str(&piece);
        } else if !piece.is_empty() {
            text = piece;
        }
    }
    assert_eq!(text, "Hello world!", "the host's full text under the host's id");
    assert!(seen.iter().any(|e| e.kind == "turn/completed"));
}

/// The host was replaced behind the same endpoint (same generation
/// number, same session id) and this view's stream has not seen the
/// reset yet, so the connection still shows the old host. Older pages,
/// windows and turn reads answered by the replacement are refused: no
/// item of B is shown as A's history and the paging cursor stays. An
/// answer of the right host for a connection replaced meanwhile is
/// refused too, even when it is empty.
#[test]
fn history_answered_by_a_replacement_behind_the_same_endpoint_is_refused() {
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("init");
    let rt = runtime::runtime();
    let gateway = rt.block_on(fake_gateway(snapshot(json!([]), json!([]))));
    let url = format!("http://{}/", gateway.addr);
    let mut from_b = history_of("b-turn", &["from B"], 9, false);
    from_b["hostId"] = json!("replacement");
    from_b["hasOlder"] = json!(false);
    script(&gateway)
        .history
        .insert(String::new(), from_b.clone());
    script(&gateway).history.insert("a-turn".into(), from_b);
    let own = Context::of(&transport(None, "relay:replaced"));
    let key = key_in(&own, "pcx:studio:acp:replaced-test").expect("key");
    let view = fake_conn_at(&key, 1, &url);
    {
        let mut view = lock(&view);
        view.host_id = "h".into();
        view.oldest.insert("s".into(), "a-turn".into());
    }
    let link = link_of(&key);
    assert!(ops::older_page(&link, "s").is_err(), "B's page is not A's older history");
    assert_eq!(
        lock(&view).oldest.get("s").map(String::as_str),
        Some("a-turn"),
        "the paging cursor did not move"
    );
    assert!(ops::read_window(&link, "s").is_err());
    assert_eq!(lock(&view).oldest.get("s").map(String::as_str), Some("a-turn"));

    // The right host and generation, but the connection was replaced
    // while the (empty) answer was in flight.
    let mut empty = json!({"available": false, "sessionId": "s", "seq": 9,
        "generation": 1, "hostId": "h"});
    script(&gateway)
        .history
        .insert(String::new(), empty.clone());
    disconnect_inner(&key);
    let newer = fake_conn_at(&key, 1, &url);
    lock(&newer).host_id = "h".into();
    assert!(ops::read_window(&link, "s").is_err(), "a stale completion, even empty");
    // Through the current connection the same answer is accepted.
    let current = link_of(&key);
    let read = ops::read_window(&current, "s").expect("current view");
    assert!(read.items.iter().all(|item| item.item_type == "historyGap"));
    empty["hostId"] = json!("replacement");
    script(&gateway).history.insert(String::new(), empty);
    assert!(ops::read_window(&current, "s").is_err(), "and refused from another host");
    disconnect_inner(&key);
}

/// The host refuses the event stream (its limit is reached): a snapshot
/// is still readable, but the view must stay unhealthy — no negotiated
/// capabilities — until a stream actually opens.
#[tokio::test]
async fn a_refused_stream_keeps_the_view_unhealthy_until_a_slot_opens() {
    let gateway = fake_gateway(snapshot(json!([]), json!([]))).await;
    script(&gateway).refuse_events = true;
    let client = GatewayClient::new(&format!("http://{}/", gateway.addr)).expect("client");
    let shared = Arc::new(Mutex::new(Shared::default()));
    let (tx, _rx) = broadcast::channel(64);
    let first = script(&gateway).snapshot.clone();
    let task = tokio::spawn(event_loop(client, tx, shared.clone(), first, None, no_watch()));
    tokio::time::sleep(Duration::from_millis(1500)).await;
    {
        let view = lock(&shared);
        assert!(!view.healthy, "a snapshot without a stream is not healthy");
        assert!(script(&gateway).streams >= 1, "the stream was asked for");
    }
    script(&gateway).refuse_events = false;
    let deadline = Instant::now() + Duration::from_secs(15);
    while !lock(&shared).healthy {
        assert!(Instant::now() < deadline, "never became healthy once a slot opened");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let view = lock(&shared);
    assert!(capabilities_of(&view.info, view.generation).negotiated);
    drop(view);
    task.abort();
}

/// The agent identity comes from the host's explicit profile, never from
/// the instance name a user chose for the host.
#[test]
fn capabilities_carry_the_hosts_profile_identity() {
    let caps = capabilities_of(
        &json!({"profile": {"id": "fixture", "displayName": "Fixture Agent"}, "name": "claude"}),
        1,
    );
    assert_eq!(caps.profile_id, "fixture");
    assert_eq!(caps.provider_name, "Fixture Agent");
    let bare = capabilities_of(&json!({"name": "fixture-agent"}), 1);
    assert!(bare.profile_id.is_empty(), "an instance name is not an identity");
}

/// Supplementing is offered only when the ready agent advertised steering.
#[test]
fn steering_is_offered_only_when_negotiated() {
    let info = |phase: &str, caps: Value| json!({"phase": {"state": phase}, "capabilities": caps});
    assert!(capabilities_of(&info("ready", json!({"steering": true})), 1).steer);
    assert!(!capabilities_of(&info("ready", json!({})), 1).steer, "absent");
    assert!(!capabilities_of(&info("ready", json!({"steering": "true"})), 1).steer, "malformed");
    assert!(!capabilities_of(&info("starting", json!({"steering": true})), 1).steer, "not ready");
    assert!(!capabilities_of(&json!({}), 1).steer, "unnegotiated");
}

/// The agent's own commands enable the palette (and `/compact` the menu
/// item), and Grok's extensions renaming and multi-answer questions, only
/// once ready; later lists arrive with the host state.
#[test]
fn commands_and_grok_extensions_follow_the_ready_agent() {
    let info = |phase: &str, caps: Value, commands: Value| json!({"phase": {"state": phase}, "capabilities": caps, "commands": commands});
    let compact = json!([{"name": "compact", "description": "Compress"}]);
    let caps = capabilities_of(&info("ready", json!({"grok": true}), compact.clone()), 1);
    assert!(caps.commands && caps.compact && caps.rename && caps.question_multiple);
    let plain = capabilities_of(&info("ready", json!({}), json!([{"name": "review"}])), 1);
    assert!(plain.commands && !plain.compact && !plain.rename && !plain.question_multiple);
    let starting = capabilities_of(&info("starting", json!({"grok": true}), compact), 1);
    assert!(!starting.commands && !starting.rename);

    let mut shared = Shared {
        info: info("ready", json!({}), json!([])),
        ..Shared::default()
    };
    translate::gateway_event(
        &mut shared,
        &json!({"type": "host_state", "phase": {"state": "ready"},
        "authRequired": false, "commands": [{"name": "compact", "description": ""}]}),
    );
    assert!(capabilities_of(&shared.info, 1).compact, "a later list replaces the first");
}

/// Every user message of a live turn — its prompt, a supplement, the prompt
/// of a turn the agent started — comes with its sender as the host names it,
/// so the view that sent it keeps its own copy and every other view shows
/// the host's. A prompt with images comes once its fold is installed. A host
/// that names no sender brings the turn's start alone, as before.
#[test]
fn live_messages_name_their_sender() {
    // (kind, item type, text, the raw's clientId; absent is `None`)
    type Seen = (String, Option<String>, Option<String>, Option<Value>);
    fn seen(events: Vec<AppEvent>) -> Vec<Seen> {
        events
            .into_iter()
            .map(|event| {
                let raw: Value = serde_json::from_str(&event.raw).expect("raw");
                (event.kind, event.item_type, event.text, raw.get("clientId").cloned())
            })
            .collect()
    }
    let message = |text: &str, sender: Value| {
        (
            "item/completed".to_string(),
            Some("userMessage".to_string()),
            Some(text.to_string()),
            Some(sender),
        )
    };
    let start = |sender: Option<Value>| ("turn/started".to_string(), None, None, sender);
    let mut shared = Shared::default();
    let mut apply = |body: Value| seen(translate::gateway_event(&mut shared, &body));
    assert_eq!(
        apply(json!({"type": "turn_started", "sessionId": "s", "turnId": "t", "userText": "hi",
            "imageCount": 0, "clientId": "view-1", "seq": 1})),
        vec![start(Some(json!("view-1"))), message("hi", json!("view-1"))]
    );
    assert_eq!(
        apply(json!({"type": "supplement", "sessionId": "s", "turnId": "t", "text": "more",
            "imageCount": 0, "clientId": null, "seq": 2})),
        vec![message("more", Value::Null)],
        "another device's"
    );
    assert_eq!(
        apply(json!({"type": "turn_started", "sessionId": "g", "turnId": "f", "userText": "own",
            "imageCount": 0, "agentStarted": true, "seq": 3})),
        vec![start(Some(Value::Null)), message("own", Value::Null)],
        "a turn the agent started, from a host before `clientId`"
    );
    assert_eq!(
        apply(json!({"type": "turn_started", "sessionId": "o", "turnId": "x", "userText": "old",
            "imageCount": 0, "seq": 4})),
        vec![start(None)],
        "a host that names no sender"
    );

    // A prompt with images: announced at once, its message with its fold.
    assert_eq!(
        apply(json!({"type": "turn_started", "sessionId": "p", "turnId": "i", "userText": "pic",
            "imageCount": 1, "clientId": "phone", "seq": 5})),
        vec![start(Some(json!("phone")))]
    );
    let mut host = Transcript::default();
    host.begin_turn("i", "pic", &["data:image/png;base64,AA".to_string()]);
    host.apply(Some("i"), &chunk("seen"));
    let history = json!({"window": [host.turns[0]], "truncated": false, "seq": 6,
        "session": {"runningTurnId": "i"}});
    let messages = |events: &[Seen]| {
        events
            .iter()
            .filter(|event| event.1.as_deref() == Some("userMessage"))
            .count()
    };
    let installed = seen(translate::install(&mut shared, "p", "i", &history));
    assert_eq!(installed[0], message("pic", json!("phone")));
    assert_eq!(installed[1].2.as_deref(), Some("seen"));
    assert_eq!(messages(&installed), 1);
    let again = seen(translate::install(&mut shared, "p", "i", &history));
    assert_eq!(messages(&again), 0, "once");
}

/// A host-held question becomes the app's structured question request,
/// numbered in order and keeping each question's own options.
#[test]
fn a_held_question_is_a_structured_question_request() {
    let event = translate::permission_event(&json!({
        "type": "permission", "handle": "h1", "sessionId": "s", "turnId": "t",
        "toolCall": {"title": "Question"}, "options": [],
        "questions": [{"question": "Pick one", "multiSelect": true,
            "options": [{"label": "A", "description": "first"}]}],
    }));
    assert_eq!(event.kind, "item/tool/requestUserInput");
    assert_eq!(event.request_id.as_deref(), Some("h1"));
    let raw: Value = serde_json::from_str(&event.raw).expect("raw");
    assert_eq!(raw["questions"][0]["id"], "q0");
    assert_eq!(raw["questions"][0]["question"], "Pick one");
    assert_eq!(raw["questions"][0]["multiple"], true);
    assert_eq!(raw["questions"][0]["options"][0]["label"], "A");
}

/// A supplement names the caller's turn (else the running one this view
/// shows) and identity, and its outcome maps exactly; anything else is an
/// error, never a prompt.
#[test]
fn a_supplement_names_its_turn_and_maps_only_known_outcomes() {
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("init");
    let rt = runtime::runtime();
    let gateway = rt.block_on(fake_gateway(snapshot(json!([]), json!([]))));
    let url = format!("http://{}/", gateway.addr);
    let own = Context::of(&transport(None, "relay:steer"));
    let key = key_in(&own, "pcx:studio:acp:steer-test").expect("key");
    let view = fake_conn_at(&key, 4, &url);
    {
        let mut view = lock(&view);
        view.host_id = "h".into();
        view.running.insert("s".into(), "t1".into());
    }
    let link = link_of(&key);
    script(&gateway).steer = Some(("200 OK", json!({"outcome": "injected", "turnId": "t1"})));
    assert_eq!(
        ops::supplement(&link, "s", None, "more", &[], Some("view-1")).expect("injected"),
        Supplement::Injected("t1".into())
    );
    let sent = script(&gateway).steered.pop().expect("sent");
    assert_eq!(sent["turnId"], "t1", "the running turn this view shows");
    assert_eq!((sent["hostId"].clone(), sent["generation"].clone()), (json!("h"), json!(4)));
    assert_eq!(sent["text"], "more");
    assert_eq!(sent["clientId"], "view-1", "the view's own name for it");

    script(&gateway).steer = Some(("200 OK", json!({"outcome": "promptRequired", "turnId": null})));
    assert_eq!(
        ops::supplement(&link, "s", Some("t1"), "more", &[], None).expect("idle"),
        Supplement::PromptRequired
    );
    script(&gateway).steer = Some(("200 OK", json!({"outcome": "startedNewTurn"})));
    assert!(ops::supplement(&link, "s", Some("t1"), "more", &[], None).is_err(), "unknown outcome");
    script(&gateway).steer = Some(("200 OK", json!({"outcome": "injected", "turnId": null})));
    assert!(ops::supplement(&link, "s", Some("t1"), "more", &[], None).is_err(), "no turn named");
    script(&gateway).steer = Some((
        "409 Conflict",
        json!({"code": "turn_changed", "message": "the turn changed before the message reached it; nothing was sent"}),
    ));
    let refused = ops::supplement(&link, "s", Some("t1"), "more", &[], None).expect_err("refused");
    assert!(refused.to_string().contains("turn changed"), "{refused}");
    assert_eq!(script(&gateway).steered.len(), 4, "each was sent once, never retried");
    // The host confirms another turn than the one asked for.
    script(&gateway).steer = Some(("200 OK", json!({"outcome": "injected", "turnId": "t2"})));
    assert!(ops::supplement(&link, "s", Some("t1"), "more", &[], None).is_err(), "another turn");
    script(&gateway).steer = Some(("200 OK", json!({"outcome": "injected", "turnId": " "})));
    assert!(ops::supplement(&link, "s", Some("t1"), "more", &[], None).is_err(), "a blank turn");
    disconnect_inner(&key);
}

/// An answer that arrives after its connection was replaced, or after the
/// view moved to another generation, is neither "added" nor "not consumed":
/// either outcome is reported as uncertain, so the caller keeps its input
/// and starts nothing for a host it did not ask.
#[test]
fn a_late_supplement_answer_is_owned_by_the_connection_and_host_that_asked() {
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("init");
    let rt = runtime::runtime();
    let gateway = rt.block_on(fake_gateway(snapshot(json!([]), json!([]))));
    let url = format!("http://{}/", gateway.addr);
    let own = Context::of(&transport(None, "relay:late-steer"));
    let key = key_in(&own, "pcx:studio:acp:late-steer-test").expect("key");
    // Moves the view away from the connection that asked.
    type Replace = fn(&Key, &str);
    let replace: [(&str, Replace); 2] = [
        ("replaced connection", |key, url| {
            disconnect_inner(key);
            let newer = fake_conn_at(key, 4, url);
            lock(&newer).host_id = "h".into();
        }),
        ("new generation", |key, _| {
            let conns = conns();
            let mut view = lock(&conns.get(key).expect("registered").shared);
            view.generation = 5;
        }),
    ];
    for (outcome, answer) in [
        ("injected", json!({"outcome": "injected", "turnId": "t1"})),
        ("promptRequired", json!({"outcome": "promptRequired", "turnId": null})),
    ] {
        for (change, apply) in replace {
            let view = fake_conn_at(&key, 4, &url);
            lock(&view).host_id = "h".into();
            let link = link_of(&key);
            let gate = Arc::new(tokio::sync::Notify::new());
            let sent_before = {
                let mut script = script(&gateway);
                script.steer = Some(("200 OK", answer.clone()));
                script.steer_gate = Some(gate.clone());
                script.steered.len()
            };
            let pending = std::thread::spawn(move || {
                ops::supplement(&link, "s", Some("t1"), "more", &[], None)
                    .map_err(|e| e.to_string())
            });
            let deadline = Instant::now() + Duration::from_secs(10);
            while script(&gateway).steered.len() == sent_before {
                assert!(Instant::now() < deadline, "the request never arrived");
                std::thread::sleep(Duration::from_millis(10));
            }
            apply(&key, &url);
            gate.notify_one();
            let late = pending.join().expect("thread");
            let error = late.expect_err(&format!("{outcome} after a {change}"));
            assert!(error.contains("may or may not"), "{outcome} after a {change}: {error}");
            script(&gateway).steer_gate = None;
            disconnect_inner(&key);
        }
    }
    assert_eq!(script(&gateway).steered.len(), 4, "each was sent once, never retried");
}

#[test]
fn session_release_rejects_stale_display_before_contacting_a_replacement_host() {
    use pocket_codex_host_svc::session_access::SessionAccess;
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("init");
    let own = Context::of(&transport(None, "relay:control"));
    let key = key_in(&own, "pcx:studio:acp:control-test").expect("key");
    let shared = fake_conn(&key, 3);
    lock(&shared).host_id = "new-host".into();
    let mut old = SessionAccess::unknown("original", "old-host", 3, "claude");
    old.source_generation = Some("old-source".into());
    let link = link_of(&key);
    let err = access::release_on_link(&link, &old).expect_err("stale host");
    assert!(err.to_string().contains("changed"), "{err}");
    let old_generation = SessionAccess {
        host_id: "new-host".into(),
        generation: 2,
        ..old
    };
    let err = access::release_on_link(&link, &old_generation).expect_err("stale generation");
    assert!(err.to_string().contains("changed"), "{err}");
    assert!(lock(&shared).sessions.is_empty());
    disconnect_inner(&key);
}
