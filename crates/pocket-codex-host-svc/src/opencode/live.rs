//! One upstream event connection, retained independently of controllers.

use std::{sync::Arc, time::Duration};

use serde::{Deserialize, Serialize};
use tokio::sync::{broadcast, Mutex};
use tokio_util::sync::CancellationToken;

use super::{
    client::{Client, ClientError},
    events::EventStream,
    fold::{Fold, Window},
    schema::MessagePage,
};

/// A small invalidation. Consumers refetch a merged window; native deltas
/// have no replay contract and therefore never pass directly to controllers.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Change {
    /// Host observation counter.
    pub sequence: u64,
    /// Affected original session, or all sessions on a stream transition.
    pub session_id: Option<String>,
}

struct Inner {
    fold: Arc<Mutex<Fold>>,
    events: broadcast::Sender<Change>,
    stop: CancellationToken,
}

impl Drop for Inner {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}

/// Shared native stream lifetime; dropping the last owner closes its stream.
#[derive(Clone)]
pub struct Live(Arc<Inner>);

impl Live {
    /// Confirm `server.connected` before returning. The native server must not
    /// admit a write until this observer can retain its unpersisted deltas.
    pub async fn start(client: Client) -> Result<Self, ClientError> {
        let (stream, fold) = connect(&client).await?;
        let fold = Arc::new(Mutex::new(fold));
        let (events, _) = broadcast::channel(64);
        let stop = CancellationToken::new();
        tokio::spawn(run(client, stream, fold.clone(), events.clone(), stop.clone()));
        Ok(Self(Arc::new(Inner {
            fold,
            events,
            stop,
        })))
    }

    /// Subscribe before obtaining a snapshot to avoid missed invalidations.
    pub fn subscribe(&self) -> broadcast::Receiver<Change> {
        self.0.events.subscribe()
    }

    /// Current host event counter.
    pub async fn sequence(&self) -> u64 {
        self.0.fold.lock().await.sequence()
    }

    /// Whether the stream currently has confirmed upstream readiness.
    pub async fn connected(&self) -> bool {
        self.0.fold.lock().await.connected()
    }

    /// Latest observed native status and its event counter.
    pub async fn status(&self, session: &str) -> Option<(u64, super::schema::Status, u64)> {
        self.0.fold.lock().await.status(session)
    }

    /// Publish a local host-state invalidation, without exposing native data.
    pub async fn invalidate(&self, session: &str) {
        let mut fold = self.0.fold.lock().await;
        fold.apply(super::events::Event {
            directory: None,
            kind: "host.changed".into(),
            properties: serde_json::json!({"sessionID":session}),
        });
        let _ = self.0.events.send(Change {
            sequence: fold.sequence(),
            session_id: Some(session.into()),
        });
    }

    /// Snapshot the native history plus live overlay under one host watermark.
    pub async fn window(&self, session: &str, page: MessagePage, tail: bool) -> Window {
        self.0.fold.lock().await.window(session, page, tail)
    }

    /// Stop only this observer, for an explicitly stopped owned host.
    pub async fn stop(&self) {
        self.0.stop.cancel();
        self.0.fold.lock().await.disconnect();
    }
}

async fn connect(client: &Client) -> Result<(EventStream, Fold), ClientError> {
    let mut stream = client.events(None).await?;
    let event = tokio::time::timeout(Duration::from_secs(10), stream.next())
        .await
        .map_err(|_| ClientError::Transport)?
        .ok_or(ClientError::EventStreamEnded)??;
    if event.kind != "server.connected" {
        return Err(ClientError::InvalidResponse);
    }
    let mut fold = Fold::default();
    fold.apply(event);
    Ok((stream, fold))
}

async fn run(
    client: Client,
    mut stream: EventStream,
    fold: Arc<Mutex<Fold>>,
    events: broadcast::Sender<Change>,
    stop: CancellationToken,
) {
    loop {
        let next = tokio::select! { _ = stop.cancelled() => break, next = stream.next() => next };
        match next {
            Some(Ok(event)) => {
                if event.kind == "server.heartbeat" {
                    continue;
                }
                let mut fold = fold.lock().await;
                let session_id = fold.apply(event);
                let _ = events.send(Change {
                    sequence: fold.sequence(),
                    session_id,
                });
            },
            _ => {
                {
                    let mut fold = fold.lock().await;
                    fold.disconnect();
                    let _ = events.send(Change {
                        sequence: fold.sequence(),
                        session_id: None,
                    });
                }
                loop {
                    let connection = tokio::select! {
                        _ = stop.cancelled() => return,
                        connection = async {
                            tokio::time::sleep(Duration::from_secs(1)).await;
                            connect(&client).await
                        } => connection,
                    };
                    if let Ok((next, _)) = connection {
                        stream = next;
                        let mut fold = fold.lock().await;
                        fold.apply(super::events::Event {
                            directory: None,
                            kind: "server.connected".into(),
                            properties: serde_json::Value::Null,
                        });
                        let _ = events.send(Change {
                            sequence: fold.sequence(),
                            session_id: None,
                        });
                        break;
                    }
                }
            },
        }
    }
}
