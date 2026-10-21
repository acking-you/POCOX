use std::sync::Mutex as StdMutex;

use serde_json::json;
use tokio::io::{duplex, split, AsyncBufReadExt, AsyncWriteExt, BufReader as TokioBufReader};

use super::*;

#[derive(Default)]
struct Recorder {
    requests: StdMutex<Vec<(RequestId, String)>>,
    notes: StdMutex<Vec<String>>,
}

impl Inbound for Recorder {
    fn notification(&self, _peer: &Peer, method: &str, _params: Option<Value>) {
        lock(&self.notes).push(method.to_string());
    }

    fn request(&self, peer: &Peer, id: RequestId, method: &str, _params: Option<Value>) {
        lock(&self.requests).push((id.clone(), method.to_string()));
        peer.respond_now(id, Ok(json!({"handled": method})));
    }
}

struct Agent {
    lines: tokio::io::Lines<TokioBufReader<tokio::io::ReadHalf<tokio::io::DuplexStream>>>,
    out: tokio::io::WriteHalf<tokio::io::DuplexStream>,
}

impl Agent {
    async fn next(&mut self) -> Value {
        let line = self.lines.next_line().await.expect("read").expect("line");
        serde_json::from_str(&line).expect("json")
    }

    async fn send(&mut self, value: Value) {
        let mut line = serde_json::to_vec(&value).expect("encode");
        line.push(b'\n');
        self.out.write_all(&line).await.expect("write");
    }
}

fn pair() -> (Peer, Agent, Arc<Recorder>) {
    let (host, agent) = duplex(1 << 20);
    let (host_read, host_write) = split(host);
    let (agent_read, agent_write) = split(agent);
    let recorder = Arc::new(Recorder::default());
    let peer = Peer::spawn(host_read, host_write, recorder.clone());
    let agent = Agent {
        lines: TokioBufReader::new(agent_read).lines(),
        out: agent_write,
    };
    (peer, agent, recorder)
}

#[tokio::test]
async fn concurrent_requests_settle_by_id_and_namespaces_stay_apart() {
    let (peer, mut agent, recorder) = pair();
    let first = tokio::spawn({
        let peer = peer.clone();
        async move { peer.request("a", json!({}), None).await }
    });
    let one = agent.next().await;
    let second = tokio::spawn({
        let peer = peer.clone();
        async move { peer.request("b", json!({}), None).await }
    });
    let two = agent.next().await;
    // The agent reuses our id for its own request, and answers with a
    // string id first: neither may settle our numeric request.
    agent
        .send(json!({"jsonrpc": "2.0", "id": one["id"], "method": "x/y", "params": {}}))
        .await;
    let handled = agent.next().await;
    assert_eq!(handled["id"], one["id"]);
    assert_eq!(handled["result"]["handled"], "x/y");
    agent
        .send(json!({"jsonrpc": "2.0", "id": one["id"].to_string(), "result": "wrong"}))
        .await;
    agent
        .send(json!({"jsonrpc": "2.0", "id": two["id"], "result": "second"}))
        .await;
    agent
        .send(json!({"jsonrpc": "2.0", "id": one["id"], "error": {"code": -32000, "message": "auth"}}))
        .await;
    assert_eq!(second.await.expect("join"), Ok(json!("second")));
    match first.await.expect("join") {
        Err(CallError::Rpc(error)) => assert_eq!(error.code, RpcError::AUTH_REQUIRED),
        other => panic!("unexpected {other:?}"),
    }
    assert_eq!(lock(&recorder.requests).len(), 1);
}

#[tokio::test]
async fn eof_fails_pending_requests() {
    let (peer, agent, _) = pair();
    let call = tokio::spawn({
        let peer = peer.clone();
        async move { peer.request("a", json!({}), None).await }
    });
    drop(agent);
    assert_eq!(call.await.expect("join"), Err(CallError::Closed));
    assert_eq!(peer.closed().await, CloseReason::Eof);
    assert_eq!(peer.request("b", json!({}), None).await, Err(CallError::Closed));
}

#[tokio::test]
async fn timeouts_forget_the_request_and_ignore_late_answers() {
    let (peer, mut agent, _) = pair();
    let late = peer
        .request("slow", json!({}), Some(Duration::from_millis(20)))
        .await;
    assert_eq!(late, Err(CallError::Timeout));
    let sent = agent.next().await;
    agent
        .send(json!({"jsonrpc": "2.0", "id": sent["id"], "result": 1}))
        .await;
    let next = tokio::spawn({
        let peer = peer.clone();
        async move { peer.request("next", json!({}), None).await }
    });
    let request = agent.next().await;
    assert_ne!(request["id"], sent["id"]);
    agent
        .send(json!({"jsonrpc": "2.0", "id": request["id"], "result": 2}))
        .await;
    assert_eq!(next.await.expect("join"), Ok(json!(2)));
}

#[tokio::test]
async fn malformed_frames_get_an_error_and_notifications_are_delivered() {
    let (peer, mut agent, recorder) = pair();
    agent.out.write_all(b"{not json\n").await.expect("write");
    let error = agent.next().await;
    assert_eq!(error["id"], Value::Null);
    assert_eq!(error["error"]["code"], RpcError::PARSE);
    agent
        .send(json!({"jsonrpc": "2.0", "method": "session/update", "params": {}}))
        .await;
    agent
        .send(json!({"jsonrpc": "2.0", "id": null, "method": "null/id", "params": {}}))
        .await;
    let answered = agent.next().await;
    assert_eq!(answered["id"], Value::Null);
    assert_eq!(answered["result"]["handled"], "null/id");
    assert_eq!(*lock(&recorder.notes), vec!["session/update".to_string()]);
    assert!(!peer.is_closed());
}

#[tokio::test]
async fn oversized_frames_close_the_connection() {
    let (peer, mut agent, _) = pair();
    let chunk = vec![b'a'; 1024 * 1024];
    for _ in 0..9 {
        if agent.out.write_all(&chunk).await.is_err() {
            break;
        }
    }
    assert_eq!(peer.closed().await, CloseReason::Protocol);
}

/// An agent that stays alive but never reads its input, until the queue
/// is exhausted. A frame whose deadline passes while it waits for room
/// was never queued, so the connection stays open; closing releases
/// waiters that have no deadline.
#[tokio::test]
async fn deadlines_cover_an_exhausted_queue_and_closing_releases_every_waiter() {
    let (host, agent) = duplex(64);
    let (host_read, host_write) = split(host);
    let peer = Peer::spawn(host_read, host_write, Arc::new(Recorder::default()));
    let big = json!("x".repeat(MAX_FRAME_BYTES - 1024));
    let mut fills = Vec::new();
    for _ in 0..MAX_QUEUED_BYTES / (MAX_FRAME_BYTES - 1024) {
        fills.push(tokio::spawn({
            let (peer, big) = (peer.clone(), big.clone());
            async move { peer.send_request("fill", big, None).await.map(|_| ()) }
        }));
    }
    let frame = MAX_FRAME_BYTES - 1024;
    tokio::time::timeout(Duration::from_secs(5), async {
        while peer.shared.budget.available_permits() >= frame {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("the queue fills");
    let started = Instant::now();
    let late = peer
        .request("session/load", big.clone(), Some(Duration::from_millis(200)))
        .await;
    assert_eq!(late, Err(CallError::Timeout), "the deadline covers queue admission");
    assert!(started.elapsed() < Duration::from_secs(3));
    assert!(!peer.is_closed(), "nothing of it was queued, so nothing is half-sent");
    let cancel = peer
        .notify("session/cancel", big.clone(), Instant::now() + Duration::from_millis(100))
        .await;
    assert_eq!(cancel, Err(CallError::Timeout), "control traffic fails boundedly");
    assert!(!peer.is_closed());
    let stuck = tokio::spawn({
        let peer = peer.clone();
        let big = big.clone();
        async move { peer.request("session/prompt", big, None).await }
    });
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(!stuck.is_finished(), "a request without a deadline waits for room");
    peer.shutdown(Duration::from_millis(50)).await;
    let released = tokio::time::timeout(Duration::from_secs(5), stuck)
        .await
        .expect("closing wakes the waiter")
        .expect("join");
    assert_eq!(released, Err(CallError::Closed));
    for fill in fills {
        let filled = tokio::time::timeout(Duration::from_secs(5), fill)
            .await
            .expect("closing wakes the queued frames")
            .expect("join");
        assert_eq!(filled, Err(CallError::Closed));
    }
    drop(agent);
}

/// The writer is blocked in the middle of a frame while the queue still
/// has room. Queue admission alone is not delivery: the deadline also
/// covers the write, and a frame that may be partly written closes the
/// connection at once, so its rest never reaches a later exchange.
#[tokio::test]
async fn a_frame_not_written_in_time_closes_the_connection() {
    let (host, mut agent) = duplex(64);
    let (host_read, host_write) = split(host);
    let peer = Peer::spawn(host_read, host_write, Arc::new(Recorder::default()));
    let started = Instant::now();
    let prompt = peer
        .send_request(
            "session/prompt",
            json!("p".repeat(64 * 1024)),
            Some(Instant::now() + Duration::from_millis(200)),
        )
        .await
        .map(|_| ());
    assert_eq!(prompt, Err(CallError::Timeout));
    assert!(started.elapsed() < Duration::from_secs(3));
    assert_eq!(peer.closed().await, CloseReason::Stalled);
    assert_eq!(
        peer.notify("session/cancel", json!({}), Instant::now() + Duration::from_secs(1))
            .await,
        Err(CallError::Closed),
        "nothing is written after a frame that may be partial"
    );
    // Whatever reached the agent ends without the rest of the frame.
    let mut seen = 0;
    let mut buf = vec![0u8; 4096];
    while let Ok(Ok(read)) = tokio::time::timeout(
        Duration::from_millis(300),
        tokio::io::AsyncReadExt::read(&mut agent, &mut buf),
    )
    .await
    {
        if read == 0 {
            break;
        }
        seen += read;
    }
    assert!(seen < 64 * 1024, "the frame was never completed");
}

/// A frame the agent reads is delivered: the call returns after the
/// write, and the request is then answered as usual.
#[tokio::test]
async fn delivered_frames_return_after_the_write() {
    let (peer, mut agent, _) = pair();
    let deadline = Instant::now() + Duration::from_secs(5);
    peer.notify("session/cancel", json!({"sessionId": "s"}), deadline)
        .await
        .expect("delivered");
    assert_eq!(agent.next().await["method"], "session/cancel");
    let call = peer
        .send_request("session/prompt", json!({}), Some(deadline))
        .await
        .expect("delivered");
    let sent = agent.next().await;
    agent
        .send(json!({"jsonrpc": "2.0", "id": sent["id"], "result": {"stopReason": "end_turn"}}))
        .await;
    assert_eq!(call.wait(None).await, Ok(json!({"stopReason": "end_turn"})));
    assert!(!peer.is_closed());
}

#[tokio::test]
async fn dropped_partial_write_abandons_the_peer() {
    let (host, mut agent) = duplex(64);
    let (reader, writer) = split(host);
    let peer = Peer::spawn(reader, writer, Arc::new(Recorder::default()));
    let mut response = Box::pin(peer.respond(
        RequestId::Number(1),
        Ok(json!("x".repeat(8192))),
        Instant::now() + Duration::from_secs(10),
    ));
    assert!(tokio::time::timeout(Duration::from_millis(20), &mut response)
        .await
        .is_err());
    let mut prefix = [0; 1];
    tokio::io::AsyncReadExt::read_exact(&mut agent, &mut prefix)
        .await
        .expect("partly written");
    drop(response);
    assert_eq!(peer.closed().await, CloseReason::Stalled);
}

#[tokio::test]
async fn automatic_reply_deadline_covers_waiting_behind_an_unbounded_write() {
    let (host, _agent) = duplex(64);
    let (reader, writer) = split(host);
    let peer = Peer::spawn(reader, writer, Arc::new(Recorder::default()));
    let mut prompt = Box::pin(peer.send_request("session/prompt", json!("x".repeat(8192)), None));
    assert!(tokio::time::timeout(Duration::from_millis(20), &mut prompt)
        .await
        .is_err());
    peer.respond_now_until(
        RequestId::Number(1),
        Ok(json!({})),
        Instant::now() + Duration::from_millis(30),
    );
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(1), peer.closed())
            .await
            .expect("owned deadline"),
        CloseReason::Stalled
    );
    assert!(prompt.await.is_err());
}

#[tokio::test]
async fn shutdown_flushes_queued_answers_then_closes_the_output() {
    let (peer, mut agent, _) = pair();
    peer.respond_now(RequestId::Str("q".into()), Ok(json!("done")));
    peer.shutdown(Duration::from_secs(1)).await;
    let answer = agent.next().await;
    assert_eq!(answer["id"], "q");
    assert!(agent.lines.next_line().await.expect("read").is_none());
    assert_eq!(peer.request("late", json!({}), None).await, Err(CallError::Closed));
}
