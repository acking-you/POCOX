//! The per-connection event task: streaming after the watermark, recovery
//! from snapshots, retries of unreadable folds, and health (see the parent
//! module docs).

use super::*;

/// What the event task needs to notice a replaced local host.
pub(super) struct Watch {
    pub(super) logical: String,
    pub(super) context: Context,
    pub(super) local: Option<String>,
}

impl Watch {
    /// Whether a local host was stopped or replaced (another port).
    fn replaced(&self) -> bool {
        self.local.as_ref().is_some_and(|local| {
            crate::engine::serve_acp::local_gateway(&self.logical, &self.context).as_ref()
                != Some(local)
        })
    }
}

fn send_all(tx: &broadcast::Sender<AppEvent>, events: Vec<AppEvent>) {
    for event in events {
        let _ = tx.send(event);
    }
}

/// Read `turn` of `thread` as a fold, if the answer comes from the host
/// incarnation the view shows and from `generation` (a replacement behind
/// the same endpoint may reuse generation numbers and session ids).
async fn read_turn(
    client: &GatewayClient,
    shared: &Mutex<Shared>,
    thread: &str,
    turn: &str,
    generation: u64,
) -> Option<Value> {
    let host = lock(shared).host_id.clone();
    let history = client.history(thread, None, Some(turn), None).await.ok()?;
    (history["generation"].as_u64() == Some(generation)
        && history["hostId"].as_str() == Some(host.as_str()))
    .then_some(history)
}

/// Read and install the fold of running `turn`, or mark it unsynchronized
/// (retried later). `false` when it could not be read.
async fn sync_turn(
    client: &GatewayClient,
    tx: &broadcast::Sender<AppEvent>,
    shared: &Mutex<Shared>,
    thread: &str,
    turn: &str,
    generation: u64,
) -> bool {
    let history = read_turn(client, shared, thread, turn, generation).await;
    let mut view = lock(shared);
    if view.generation != generation {
        return false;
    }
    let installed = history.is_some_and(|history| {
        let events = translate::install(&mut view, thread, turn, &history);
        let installed = !view.live.needs_fold(thread, Some(turn));
        send_all(tx, events);
        installed
    });
    if installed {
        view.unsynced
            .remove(&(thread.to_string(), turn.to_string()));
    } else if view.running.get(thread).map(String::as_str) == Some(turn) {
        view.unreadable(thread, turn);
    }
    installed
}

/// Resynchronize from `snapshot` (see the module docs for the order).
/// Returns the watermark.
pub(super) async fn recover(
    client: &GatewayClient,
    tx: &broadcast::Sender<AppEvent>,
    shared: &Mutex<Shared>,
    snapshot: &Value,
) -> u64 {
    let plan = translate::reconcile(&mut lock(shared), snapshot);
    let generation = plan.generation;
    // A turn that ended is completed before anything newer is announced, so
    // its completion can never end its successor.
    for (thread, turn, outcome) in &plan.ended {
        let history = read_turn(client, shared, thread, turn, generation).await;
        send_all(tx, translate::finished(thread, turn, history.as_ref(), outcome.as_ref()));
    }
    for (thread, turn, agent_started) in &plan.started {
        send_all(tx, vec![translate::started(thread, turn, *agent_started)]);
    }
    for (thread, turn) in &plan.running {
        sync_turn(client, tx, shared, thread, turn, generation).await;
    }
    send_all(tx, plan.events);
    send_all(tx, vec![plan.host_state]);
    snapshot["seq"].as_u64().unwrap_or(0)
}

/// Retry the unsynchronized folds that are due.
async fn retry_due(
    client: &GatewayClient,
    tx: &broadcast::Sender<AppEvent>,
    shared: &Mutex<Shared>,
) {
    let (due, generation): (Vec<(String, String)>, u64) = {
        let view = lock(shared);
        let now = Instant::now();
        let due = view
            .unsynced
            .iter()
            .filter(|(_, retry)| retry.due <= now)
            .map(|(key, _)| key.clone())
            .collect();
        (due, view.generation)
    };
    for (thread, turn) in due {
        sync_turn(client, tx, shared, &thread, &turn, generation).await;
    }
}

/// Resolves when the earliest unsynchronized fold is due (never when none
/// is).
async fn retry_timer(shared: &Mutex<Shared>) {
    let next = lock(shared).next_retry();
    match next {
        Some(due) => tokio::time::sleep_until(due).await,
        None => std::future::pending().await,
    }
}

/// Why a stream stopped being followed.
enum Ended {
    /// The host asked for a resync.
    Reset,
    /// The stream ended or failed.
    Closed,
}

/// Apply events from `stream` after `watermark` until it resets or ends,
/// retrying unsynchronized folds when they are due.
async fn follow(
    client: &GatewayClient,
    tx: &broadcast::Sender<AppEvent>,
    shared: &Mutex<Shared>,
    stream: &mut EventStream,
    watermark: &mut u64,
) -> Ended {
    loop {
        let next = tokio::select! {
            next = stream.next() => next,
            () = retry_timer(shared) => {
                retry_due(client, tx, shared).await;
                continue;
            },
        };
        let Some(Ok(body)) = next else { return Ended::Closed };
        if body["type"] == "reset" {
            return Ended::Reset;
        }
        let seq = body["seq"].as_u64().unwrap_or(0);
        if seq <= *watermark {
            continue;
        }
        *watermark = seq;
        apply(client, tx, shared, &body).await;
    }
}

async fn fresh_snapshot(client: &GatewayClient) -> Option<Value> {
    let snapshot = client.snapshot().await.ok()?;
    check_api(&snapshot).is_ok().then_some(snapshot)
}

/// Stream events after the watermark; resynchronize from a snapshot on
/// reset or after an outage; track health; end when a local host was
/// replaced. `opened` is a stream already opened at `first`'s watermark.
pub(super) async fn event_loop(
    client: GatewayClient,
    tx: broadcast::Sender<AppEvent>,
    shared: Arc<Mutex<Shared>>,
    first: Value,
    mut opened: Option<EventStream>,
    watch: Watch,
) {
    let mut watermark = recover(&client, &tx, &shared, &first).await;
    let mut backoff = Duration::from_secs(1);
    loop {
        let (host_id, generation) = {
            let view = lock(&shared);
            (view.host_id.clone(), view.generation)
        };
        let stream = match opened.take() {
            Some(stream) => Ok(stream),
            None => client.events(Some(&host_id), generation, watermark).await,
        };
        match stream {
            Ok(mut stream) => {
                let reopened = !lock(&shared).healthy;
                // Back after an outage: catch up from a fresh snapshot while
                // the stream is open (events up to its watermark are skipped).
                let caught_up = if reopened {
                    match fresh_snapshot(&client).await {
                        Some(snapshot) => {
                            watermark = recover(&client, &tx, &shared, &snapshot).await;
                            true
                        },
                        None => false,
                    }
                } else {
                    true
                };
                if caught_up {
                    lock(&shared).healthy = true;
                    backoff = Duration::from_secs(1);
                    if let Ended::Reset =
                        follow(&client, &tx, &shared, &mut stream, &mut watermark).await
                    {
                        if let Some(snapshot) = fresh_snapshot(&client).await {
                            watermark = recover(&client, &tx, &shared, &snapshot).await;
                            continue;
                        }
                    }
                }
            },
            // Refused (the host's stream limit) or unreachable: either way
            // there is no live view, whatever a snapshot would say.
            Err(error) => tracing::debug!(%error, "ACP gateway event stream unavailable"),
        }
        let events = translate::disconnected(&mut lock(&shared));
        send_all(&tx, events);
        if watch.replaced() {
            // Another host serves this key here now; the next connect
            // reaches it instead of retrying a dead port.
            return;
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(Duration::from_secs(30));
    }
}

/// Translate one live event; a turn this controller never saw begin gets
/// its fold from the host first (or stays unsynchronized when it cannot be
/// read yet).
async fn apply(
    client: &GatewayClient,
    tx: &broadcast::Sender<AppEvent>,
    shared: &Mutex<Shared>,
    body: &Value,
) {
    let thread = body["sessionId"].as_str().unwrap_or("");
    let turn = body["turnId"].as_str();
    let missing = {
        let view = lock(shared);
        let content = matches!(body["type"].as_str(), Some("update" | "supplement" | "turn_ended"));
        turn.filter(|turn| {
            content && view.live.needs_fold(thread, Some(turn)) && view.may_read(thread, turn)
        })
        .map(|turn| (turn.to_string(), view.generation))
    };
    if let Some((turn, generation)) = missing {
        sync_turn(client, tx, shared, thread, &turn, generation).await;
    }
    let begun_unsynced = {
        let mut view = lock(shared);
        if body["type"] == "turn_ended" {
            if let Some(turn) = turn {
                view.unsynced
                    .remove(&(thread.to_string(), turn.to_string()));
            }
        }
        let events = translate::gateway_event(&mut view, body);
        send_all(tx, events);
        // A turn whose prompt carried images is begun from the host's fold
        // only (see `Replica::apply`): read it now, after announcing it.
        turn.filter(|turn| {
            body["type"] == "turn_started" && view.live.needs_fold(thread, Some(turn))
        })
        .map(|turn| (turn.to_string(), view.generation))
    };
    if let Some((turn, generation)) = begun_unsynced {
        sync_turn(client, tx, shared, thread, &turn, generation).await;
    }
}
