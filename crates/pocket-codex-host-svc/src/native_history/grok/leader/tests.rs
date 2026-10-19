//! A fake leader on this home's socket, speaking the leader's framing.

use std::{path::Path, time::Duration};

use serde_json::{json, Value};
use tempfile::TempDir;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{UnixListener, UnixStream},
};

use super::super::{
    tests::{append, grok_client, prompt, reply, session, stamped, summary, texts, ID},
    GrokHistory,
};

const WAIT: Duration = Duration::from_secs(10);

struct Peer(UnixStream);

impl Peer {
    /// The client's next message; `None` once it closed.
    async fn recv(&mut self) -> Option<Value> {
        let mut header = [0u8; 4];
        tokio::time::timeout(WAIT, self.0.read_exact(&mut header))
            .await
            .expect("the follower stalled")
            .ok()?;
        let mut body = vec![0u8; u32::from_be_bytes(header) as usize];
        self.0.read_exact(&mut body).await.ok()?;
        Some(serde_json::from_slice(&body).expect("frame"))
    }

    async fn send(&mut self, message: Value) {
        let body = message.to_string();
        self.0
            .write_all(&(body.len() as u32).to_be_bytes())
            .await
            .expect("send");
        self.0.write_all(body.as_bytes()).await.expect("send");
    }

    async fn acp(&mut self, payload: Value) {
        self.send(json!({"type": "acp", "payload": payload.to_string()}))
            .await;
    }

    /// The client's next ACP request.
    async fn request(&mut self) -> Value {
        let message = self.recv().await.expect("a request");
        assert_eq!(message["type"], "acp", "{message}");
        serde_json::from_str(message["payload"].as_str().expect("payload")).expect("request")
    }

    /// Whatever the client sends next is its leaving.
    async fn leaves(&mut self) {
        match self.recv().await {
            None => {},
            Some(message) => {
                assert_eq!(message["type"], "disconnect", "the follower only leaves: {message}");
                assert!(self.recv().await.is_none(), "nothing after leaving");
            },
        }
    }

    /// Accept registration with `version`; returns what the client sent.
    async fn register(&mut self, version: u32) -> Value {
        let register = self.recv().await.expect("register");
        self.send(json!({"type": "registered", "client_id": 7, "ready": true,
            "leader_protocol_version": version, "leader_binary_version": "1.0.62"}))
            .await;
        register
    }

    /// Register and answer the subscribing info read and the roster.
    async fn subscribe(&mut self, activity: &str) {
        self.register(1).await;
        let info = self.request().await;
        self.acp(json!({"jsonrpc": "2.0", "id": info["id"], "result": {"result": {"turns": 1}}}))
            .await;
        let roster = self.request().await;
        assert_eq!(roster["method"], "_x.ai/sessions/list");
        self.acp(json!({"jsonrpc": "2.0", "id": roster["id"], "result": {"result": {"sessions": [
            {"sessionId": "01a15501-0000-7000-8000-00000000000f", "resident": true,
                "activity": "working"},
            {"sessionId": ID, "resident": true, "activity": activity},
        ]}}}))
        .await;
    }
}

struct Home {
    dir: TempDir,
    listener: UnixListener,
    reader: GrokHistory,
}

impl Home {
    fn new() -> Self {
        let dir = TempDir::new().expect("home");
        let session_dir =
            session(dir.path(), "%2Fwork", ID, summary(ID, "Live", "2026-10-19T10:00:00Z"));
        append(&session_dir, &[stamped(prompt(0, "hi"), 1), stamped(reply("Hel"), 2)]);
        let listener = UnixListener::bind(dir.path().join("leader.sock")).expect("leader socket");
        let reader = GrokHistory::new(dir.path().into())
            .expect("reader")
            .with_owner_probe()
            .with_leader_follow();
        Self {
            dir,
            listener,
            reader,
        }
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    async fn accept(&self) -> Peer {
        let (stream, _) = tokio::time::timeout(WAIT, self.listener.accept())
            .await
            .expect("the follower connects")
            .expect("accept");
        Peer(stream)
    }
}

fn live_update(seq: u64, update: Value) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": ID,
        "update": update, "_meta": {"eventId": format!("{ID}-{seq}")}}})
}

async fn until(what: &str, mut check: impl AsyncFnMut() -> bool) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while !check().await {
        assert!(tokio::time::Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test]
async fn a_terminal_clients_session_is_followed_live_and_never_answered() {
    let home = Home::new();
    // Without a registered terminal client the leader is not contacted.
    let mut follow = home.reader.follow(ID).expect("follow");
    assert!(
        tokio::time::timeout(Duration::from_millis(300), home.listener.accept())
            .await
            .is_err(),
        "no client holds the session"
    );
    let mut client = grok_client(home.path());
    let mut peer = home.accept().await;
    let register = peer.register(1).await;
    assert_eq!(register["type"], "register");
    assert_eq!(register["mode"], "stdio", "headless would wake Grok's web relay");
    assert_eq!(register["capabilities"], json!({}), "nothing to inject into the session");
    // Its first message names the session (which subscribes it), and reads.
    let info = peer.request().await;
    assert_eq!(info["method"], "_x.ai/session/info");
    assert_eq!(info["params"], json!({"sessionId": ID}));
    peer.acp(json!({"jsonrpc": "2.0", "id": info["id"], "result": {"result": {"turns": 1}}}))
        .await;
    let roster = peer.request().await;
    assert_eq!(roster["method"], "_x.ai/sessions/list");
    peer.acp(json!({"jsonrpc": "2.0", "id": roster["id"], "result": {"result": {"sessions": [
        {"sessionId": ID, "resident": true, "activity": "idle"}]}}}))
        .await;
    until("the follow is live", async || home.reader.liveness(ID).await.turn_state == "idle").await;
    assert!(follow.changed().await);
    peer.acp(json!({"jsonrpc": "2.0", "method": "_x.ai/queue/changed",
        "params": {"sessionId": ID, "runningPromptId": "p1"}}))
        .await;
    until("the turn runs", async || home.reader.liveness(ID).await.safety == "nativeOwnedRunning")
        .await;

    // A streamed chunk the log does not hold yet extends the last turn;
    // subscribed while idle, an `eventId` Grok never sent (3) is no gap.
    let before = home.reader.revision(ID).await.expect("revision")["revision"].clone();
    peer.acp(live_update(
        4,
        json!({"sessionUpdate": "agent_message_chunk",
        "content": {"type": "text", "text": "lo"}}),
    ))
    .await;
    until("the streamed text", async || {
        let page = home.reader.read_page(ID, None, 20).await.expect("page");
        texts(&page) == [vec!["hi", "Hello"]]
    })
    .await;
    assert_ne!(home.reader.revision(ID).await.expect("revision")["revision"], before);

    // Every subscriber gets the permission request; the user's own client
    // answers it, never this one.
    peer.acp(json!({"jsonrpc": "2.0", "id": "3|9", "method": "session/request_permission",
        "params": {"sessionId": ID, "toolCall": {"toolCallId": "t1"},
            "options": [{"optionId": "allow-once", "kind": "allow_once", "name": "Allow"}]}}))
        .await;
    peer.acp(json!({"jsonrpc": "2.0", "method": "_x.ai/queue/changed",
        "params": {"sessionId": ID, "runningPromptId": null}}))
        .await;
    until("the turn ended", async || home.reader.liveness(ID).await.turn_state == "idle").await;

    // The view leaves: the follower disconnects without having answered.
    drop(follow);
    peer.leaves().await;
    client.kill().expect("kill");
    client.wait().expect("reap");
}

#[tokio::test]
async fn the_follower_leaves_when_it_could_receive_what_only_a_driver_does() {
    let home = Home::new();
    let mut client = grok_client(home.path());
    let _follow = home.reader.follow(ID).expect("follow");

    // Another protocol is not followed: no read, no subscription.
    let mut peer = home.accept().await;
    peer.register(2).await;
    peer.leaves().await;

    // The leader does not hold the session: an empty info answer.
    let mut peer = home.accept().await;
    peer.register(1).await;
    let info = peer.request().await;
    peer.acp(json!({"jsonrpc": "2.0", "id": info["id"], "result": {"result": {}}}))
        .await;
    peer.leaves().await;

    // A driver-only request (the terminal client left): leave at once.
    let mut peer = home.accept().await;
    peer.subscribe("idle").await;
    until("the follow is live", async || home.reader.liveness(ID).await.turn_state == "idle").await;
    peer.acp(json!({"jsonrpc": "2.0", "id": "7|1", "method": "fs/read_text_file",
        "params": {"sessionId": ID, "path": "/etc/hosts"}}))
        .await;
    peer.leaves().await;
    until("the live state is gone", async || {
        home.reader.liveness(ID).await.turn_state == "unknown"
    })
    .await;

    // The terminal client's registration ends: leave within a second.
    let mut peer = home.accept().await;
    peer.subscribe("working").await;
    client.kill().expect("kill");
    client.wait().expect("reap");
    peer.leaves().await;
}
