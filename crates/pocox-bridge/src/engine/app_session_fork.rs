//! Branch a thread with the app-server's own `thread/fork`.
//!
//! The request goes over the connection serving the source, so it runs on that
//! host against that host's history. Nothing here resolves a local rollout, and
//! `path` is never sent. `thread/fork` only reads the source: it does not load,
//! evict or signal whoever holds it.

use std::sync::Arc;

use anyhow::{bail, Result};
use pocox_codex::client::AppClient;
use pocox_codex::protocol::ErrorPayload;
use serde_json::json;

use super::threads::{parse_thread_meta, read_thread_metadata};
use super::{client_for, record_runtime_config, ThreadMeta};
use crate::engine::runtime;

/// JSON-RPC `invalid request`: the server checked the fork and declined it.
const INVALID_REQUEST: i64 = -32600;
/// JSON-RPC `method not found`: the server has no such operation.
const METHOD_NOT_FOUND: i64 = -32601;
/// How far a preview is looked for through forks of forks.
const MAX_PREVIEW_HOPS: usize = 8;

/// A session branched from another.
#[derive(Clone, Debug)]
pub struct ThreadFork {
    /// The new session, listing the source it branched from.
    pub thread: ThreadMeta,
    /// Its newest turn is marked interrupted: an unfinished turn of the source
    /// is frozen that way, and any later output stays with the source.
    pub last_turn_interrupted: bool,
    /// The requested boundary is what the new session ended up with. False when
    /// its newest turn is another one or could not be read. An older server may
    /// ignore a boundary it does not know and copy the whole history instead.
    pub boundary_confirmed: bool,
}

/// What a fork request did. A refusal is an `Err`: nothing was created.
#[derive(Clone, Debug)]
pub enum ForkOutcome {
    /// The new session exists.
    Created(ThreadFork),
    /// The request was sent but its answer never arrived or says too little, so
    /// a session may exist. Retrying could create a second one; the reason is
    /// for display only.
    Unknown(String),
}

/// Branch `thread_id` into a new session, through `through_turn_id` (inclusive)
/// or up to what the source has saved now.
pub fn thread_fork(
    service_key: &str,
    thread_id: &str,
    through_turn_id: Option<&str>,
) -> Result<ForkOutcome> {
    let client = client_for(service_key)?;
    let mut source = read_thread_metadata(&client, thread_id)?;
    anyhow::ensure!(
        source.thread_source.as_deref() != Some("guardian_review"),
        "Guardian approval sessions are read-only; open their parent session"
    );
    let mut params = json!({
        "threadId": thread_id,
        // Paged afterwards like any other thread.
        "excludeTurns": true,
        // A goal carries over, but only the next explicit turn may act on it.
        "deferGoalContinuation": true,
    });
    if let Some(turn) = through_turn_id {
        params["lastTurnId"] = json!(turn);
    }
    let response = match runtime::runtime().block_on(client.request("thread/fork", params)) {
        Ok(response) => response,
        Err(err) => return fork_failure(err),
    };
    let Some(mut thread) = response.get("thread").and_then(parse_thread_meta) else {
        return Ok(ForkOutcome::Unknown("thread/fork answered without a thread".into()));
    };
    thread
        .forked_from_id
        .get_or_insert_with(|| thread_id.to_owned());
    if thread.preview.is_empty() {
        inherit_preview(&client, &mut source);
        thread.preview = source.preview;
    }
    record_runtime_config(service_key, &thread.id, &response);
    let newest = newest_turn(&client, &thread.id);
    let boundary_confirmed = through_turn_id.is_none_or(|turn| {
        newest
            .as_ref()
            .is_some_and(|(newest_id, _)| newest_id == turn)
    });
    Ok(ForkOutcome::Created(ThreadFork {
        last_turn_interrupted: newest.is_some_and(|(_, status)| status == "interrupted"),
        boundary_confirmed,
        thread,
    }))
}

/// Name a fork by the conversation it inherited. Codex reports no preview for a
/// fork, and does not list it, until it has a turn of its own, while its
/// transcript already holds the source's.
pub(super) fn inherit_preview(client: &Arc<AppClient>, thread: &mut ThreadMeta) {
    let mut source = thread.forked_from_id.clone();
    for _ in 0..MAX_PREVIEW_HOPS {
        if !thread.preview.is_empty() {
            return;
        }
        let Some(id) = source.take() else {
            return;
        };
        let Ok(ancestor) = read_thread_metadata(client, &id) else {
            return;
        };
        thread.preview = ancestor.preview;
        source = ancestor.forked_from_id;
    }
}

/// Separate what the server refused from what may have happened anyway. Other
/// server errors can follow the new thread's creation.
fn fork_failure(err: anyhow::Error) -> Result<ForkOutcome> {
    match err
        .downcast_ref::<ErrorPayload>()
        .map(|payload| payload.code)
    {
        Some(METHOD_NOT_FOUND) => {
            bail!("this Codex version cannot fork conversations; update Codex on the host")
        },
        Some(INVALID_REQUEST) => Err(err),
        _ => Ok(ForkOutcome::Unknown(format!("{err:#}"))),
    }
}

/// A thread's newest turn as its id and status, when the server can say.
fn newest_turn(client: &Arc<AppClient>, thread_id: &str) -> Option<(String, String)> {
    let page = runtime::runtime()
        .block_on(client.request(
            "thread/turns/list",
            json!({
                "threadId": thread_id,
                "limit": 1,
                "sortDirection": "desc",
                "itemsView": "notLoaded",
            }),
        ))
        .ok()?;
    let turn = page.get("data")?.as_array()?.first()?;
    Some((turn.get("id")?.as_str()?.to_owned(), turn.get("status")?.as_str()?.to_owned()))
}

#[cfg(test)]
mod tests {
    use futures::{SinkExt, StreamExt};
    use serde_json::Value;
    use tokio::net::{TcpListener, TcpStream};
    use tokio::sync::broadcast;
    use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
    use tokio_tungstenite::tungstenite::Message;
    use tokio_tungstenite::{accept_async_with_config, WebSocketStream};

    use super::super::{sessions, Session};
    use super::*;

    const SOURCE: &str = "source-thread";
    const FORK: &str = "fork-thread";

    /// A scripted peer: each reply is a `result` or, when it has `code`, an
    /// error. `None` closes the connection instead of answering.
    struct Peer(tokio::task::JoinHandle<Vec<Value>>);

    impl Peer {
        fn requests(self) -> Vec<Value> {
            runtime::runtime().block_on(self.0).expect("peer task")
        }
    }

    fn scripted(replies: Vec<Option<Value>>) -> (Arc<AppClient>, Peer) {
        runtime::init(std::env::temp_dir()).expect("runtime");
        runtime::runtime().block_on(async {
            let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
            let url = format!("ws://{}", listener.local_addr().expect("address"));
            let peer = tokio::spawn(async move {
                let (stream, _) = listener.accept().await.expect("accept");
                let mut socket = accept_async_with_config(stream, Some(WebSocketConfig::default()))
                    .await
                    .expect("handshake");
                answer_all(&mut socket, replies).await
            });
            let (client, _) = AppClient::connect(&url).await.expect("connect");
            (Arc::new(client), Peer(peer))
        })
    }

    async fn answer_all(
        socket: &mut WebSocketStream<TcpStream>,
        replies: Vec<Option<Value>>,
    ) -> Vec<Value> {
        let mut seen = Vec::new();
        for reply in replies {
            let frame = socket
                .next()
                .await
                .expect("frame")
                .expect("frame")
                .into_text()
                .expect("text");
            let request: Value = serde_json::from_str(&frame).expect("json");
            let id = request["id"].clone();
            seen.push(request);
            let Some(reply) = reply else {
                return seen;
            };
            let frame = if reply.get("code").is_some() {
                json!({"id": id, "error": reply})
            } else {
                json!({"id": id, "result": reply})
            };
            socket
                .send(Message::text(frame.to_string()))
                .await
                .expect("send");
        }
        seen
    }

    fn session(client: Arc<AppClient>) -> String {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let key = format!("fork-test-{}", NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
        sessions()
            .lock()
            .expect("sessions")
            .insert(key.clone(), Session {
                owner: None,
                client,
                events: broadcast::channel(1).0,
                forwarder: runtime::runtime().spawn(std::future::pending()),
                active_turns: Default::default(),
                runtime_config: Default::default(),
                pending_approvals: Default::default(),
                transcript: Default::default(),
                pagination: Default::default(),
            });
        key
    }

    fn metadata(thread_source: Option<&str>) -> Option<Value> {
        Some(json!({"thread": {"id": SOURCE, "threadSource": thread_source, "preview": "first"}}))
    }

    fn forked() -> Option<Value> {
        Some(json!({"thread": {"id": FORK, "forkedFromId": SOURCE, "cwd": "/work"}}))
    }

    fn turns(id: &str, status: &str) -> Option<Value> {
        Some(json!({"data": [{"id": id, "status": status}]}))
    }

    fn created(outcome: ForkOutcome) -> ThreadFork {
        match outcome {
            ForkOutcome::Created(fork) => fork,
            ForkOutcome::Unknown(reason) => panic!("expected a new session: {reason}"),
        }
    }

    #[test]
    fn fork_runs_on_the_serving_connection_with_only_the_native_parameters() {
        let (client, peer) = scripted(vec![metadata(None), forked(), turns("turn-3", "completed")]);
        let key = session(client);
        let fork = created(thread_fork(&key, SOURCE, Some("turn-3")).expect("fork"));
        let requests = peer.requests();
        assert_eq!(requests[1]["method"], "thread/fork");
        assert_eq!(
            requests[1]["params"],
            json!({
                "threadId": SOURCE,
                "lastTurnId": "turn-3",
                "excludeTurns": true,
                "deferGoalContinuation": true,
            }),
            "no path, no resume and no prompt may travel with a fork"
        );
        assert_eq!(fork.thread.id, FORK);
        assert_eq!(fork.thread.forked_from_id.as_deref(), Some(SOURCE));
        assert_eq!(fork.thread.parent_thread_id, None, "a fork is not a spawned agent");
        assert_eq!(fork.thread.preview, "first", "named by what it inherited");
        assert!(fork.boundary_confirmed);
        assert!(!fork.last_turn_interrupted);
    }

    #[test]
    fn guardian_review_is_refused_before_any_fork_is_sent() {
        let (client, peer) = scripted(vec![metadata(Some("guardian_review"))]);
        let key = session(client);
        let error = thread_fork(&key, SOURCE, None).expect_err("read-only source");
        assert!(error.to_string().contains("Guardian"));
        assert_eq!(peer.requests().len(), 1);
    }

    #[test]
    fn an_ignored_boundary_is_reported_rather_than_presented_as_the_selection() {
        // An older server drops the field it does not know.
        let (client, peer) = scripted(vec![metadata(None), forked(), turns("turn-9", "completed")]);
        let key = session(client);
        let fork = created(thread_fork(&key, SOURCE, Some("turn-3")).expect("fork"));
        peer.requests();
        assert!(!fork.boundary_confirmed);
    }

    #[test]
    fn a_frozen_running_turn_is_reported() {
        let (client, peer) =
            scripted(vec![metadata(None), forked(), turns("turn-9", "interrupted")]);
        let key = session(client);
        let fork = created(thread_fork(&key, SOURCE, None).expect("fork"));
        peer.requests();
        assert!(fork.last_turn_interrupted);
        assert!(fork.boundary_confirmed, "no boundary was asked for");
    }

    #[test]
    fn refusals_create_nothing_while_a_lost_answer_stays_unknown() {
        for (code, message) in [
            (INVALID_REQUEST, "lastTurnId 't' identifies an in-progress turn"),
            (METHOD_NOT_FOUND, "method not found"),
        ] {
            let refusal = Some(json!({"code": code, "message": message}));
            let (client, peer) = scripted(vec![metadata(None), refusal]);
            let key = session(client);
            assert!(thread_fork(&key, SOURCE, None).is_err(), "{message}");
            peer.requests();
        }
        for reply in [None, Some(json!({"code": -32603, "message": "failed after creating"}))] {
            let (client, peer) = scripted(vec![metadata(None), reply]);
            let key = session(client);
            assert!(matches!(
                thread_fork(&key, SOURCE, None).expect("not a refusal"),
                ForkOutcome::Unknown(_)
            ));
            peer.requests();
        }
    }
}
