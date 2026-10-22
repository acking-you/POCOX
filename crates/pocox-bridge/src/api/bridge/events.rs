//! Event streams for Dart: the bridge log, meta-service retry progress and
//! app-server session events.

use tokio::{
    sync::{broadcast, broadcast::error::RecvError, watch},
    time::{Duration, Instant},
};

use super::*;
use crate::engine::{
    execution::{self, Lane},
    git_diff,
    session_projection::{self as projection, ProjectedEvent, Projection},
};

/// One app-server event mirrored for Dart. `kind` is the JSON-RPC method
/// (e.g. `turn/started`, `item/agentMessage/delta`, `turn/completed`).
pub struct AppEventDto {
    /// Thread activity decoded by the native projection.
    pub running: Option<bool>,
    /// Parsed file changes, with numbered rows and totals.
    pub diff: Option<super::diff::DiffDto>,
    /// JSON-RPC method name of the originating notification.
    pub kind: String,
    /// Thread id the event belongs to, when present.
    pub thread_id: Option<String>,
    /// Item id the event refers to, when present.
    pub item_id: Option<String>,
    /// Item type tag when this event carries an item (`agentMessage`,
    /// `commandExecution`, `webSearch`, `mcpToolCall`, `fileChange`,
    /// `reasoning`, …); `None` for turn-level events.
    pub item_type: Option<String>,
    /// One-line summary for tool/activity items (command, query, tool name…).
    pub title: Option<String>,
    /// Text payload (a streaming delta or an item's body/detail).
    pub text: Option<String>,
    /// User attachments or generated artifacts, as data URLs or host paths.
    pub images: Vec<String>,
    /// Token to answer a server approval request via [`app_respond_approval`];
    /// `None` for ordinary notifications.
    pub request_id: Option<String>,
    /// Full params JSON for fields not modelled above.
    pub raw: String,
    /// Native-decoded turn identity, without an item-id fallback.
    pub turn_id: Option<String>,
    /// Host-declared sending client; empty is distinct from absent.
    pub sender: Option<String>,
    /// Delta text carries a complete prefix and replaces the displayed text.
    pub text_is_snapshot: bool,
}

/// One captured runtime log line for the in-app log viewer.
pub struct LogLineDto {
    /// `TRACE` / `DEBUG` / `INFO` / `WARN` / `ERROR`.
    pub level: String,
    /// Event target (crate / module path).
    pub target: String,
    /// The rendered message + any structured fields.
    pub message: String,
    /// Capture time, unix milliseconds.
    pub timestamp_ms: i64,
}

fn to_log_dto(l: logging::LogLine) -> LogLineDto {
    LogLineDto {
        level: l.level,
        target: l.target,
        message: l.message,
        timestamp_ms: l.timestamp_ms,
    }
}

/// A filtered view of the single native log ring.
pub struct LogViewDto {
    /// Matched lines, oldest first.
    pub lines: Vec<LogLineDto>,
    /// Number of retained lines before filtering.
    pub total: u32,
    /// Disk records lost to queue saturation or write failure.
    pub disk_lost: u64,
}

/// Read logs only when a viewer needs them. Filtering runs off the UI thread.
pub async fn log_query(level: Option<String>, keyword: String) -> Result<LogViewDto> {
    execution::run(Lane::Read, move || {
        let view = logging::query(level.as_deref(), &keyword);
        Ok(LogViewDto {
            lines: view.lines.into_iter().map(to_log_dto).collect(),
            total: view.total as u32,
            disk_lost: view.disk_lost as u64,
        })
    })
    .await
}

/// Coalesced invalidations, never a backlog of log payloads. Query the latest
/// view at most once at a time; intermediate revisions need no replay.
pub fn log_changes(sink: StreamSink<u32>) {
    runtime::runtime().spawn(async move {
        let Some(mut rx) = logging::changes() else { return };
        loop {
            let revision = *rx.borrow_and_update() as u32;
            if sink.add(revision).is_err() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            if rx.changed().await.is_err() {
                break;
            }
        }
    });
}

/// Add a bounded controller diagnostic without performing disk I/O.
#[frb(sync)]
pub fn log_record(level: String, target: String, message: String) {
    logging::record(level, target, message);
}

/// Clear the shared in-memory history; persisted logs remain available.
#[frb(sync)]
pub fn log_clear() {
    logging::clear();
}

/// One in-flight retry of a host meta request, mirrored for Dart.
pub struct RetryProgressDto {
    /// Attempts made so far (1-based).
    pub attempt: u32,
    /// Total attempt budget before the request gives up.
    pub max_attempts: u32,
}

/// Stream retry progress for host meta requests, so the UI can show "retrying
/// 2/10" instead of appearing frozen through the backoff.
///
/// Notifications only — the request's own success or failure is still delivered
/// by whichever call the UI made. A dropped tick is harmless (a newer one
/// supersedes it), so lag is skipped rather than treated as an error.
pub fn meta_retry_events(sink: StreamSink<RetryProgressDto>) -> Result<()> {
    runtime::runtime().spawn(async move {
        let mut rx = meta::subscribe_retries();
        loop {
            match rx.recv().await {
                Ok(p) => {
                    if sink
                        .add(RetryProgressDto {
                            attempt: p.attempt,
                            max_attempts: p.max_attempts,
                        })
                        .is_err()
                    {
                        break;
                    }
                },
                Err(RecvError::Lagged(_)) => continue,
                Err(RecvError::Closed) => break,
            }
        }
    });
    Ok(())
}

/// Which events of its conversation a projected feed carries.
#[derive(Clone, Copy)]
pub enum EventTopic {
    /// Everything.
    All,
    /// Turn starts, ends and thread status: what the session list shows.
    Activity,
    /// Realtime voice signalling, plus turn starts a dictation must refuse.
    Realtime,
}

impl EventTopic {
    fn admits(self, kind: &str) -> bool {
        match self {
            EventTopic::All => true,
            EventTopic::Activity => matches!(
                kind,
                "turn/started" | "turn/completed" | "turn/failed" | "thread/status/changed"
            ),
            // A dictation interrupts any turn its thread starts.
            EventTopic::Realtime => kind.starts_with("thread/realtime/") || kind == "turn/started",
        }
    }
}

/// Filter at the native boundary before copying payloads into Dart. Inventory
/// changes, resolved requests and turn ends concern every view: a turn ending
/// elsewhere still refreshes that conversation's summary.
fn accepts(event: &app_session::AppEvent, thread: Option<&str>, topic: EventTopic) -> bool {
    let service_wide = matches!(
        event.kind.as_str(),
        "thread/deleted"
            | "thread/name/updated"
            | "thread/started"
            | "thread/archived"
            | "thread/unarchived"
            | "session/access/changed"
            | "serverRequest/resolved"
            | "turn/completed"
            | "turn/failed"
    );
    let in_thread = service_wide
        || thread.is_none()
        || event.thread_id.is_none()
        || event.thread_id.as_deref() == thread;
    in_thread && topic.admits(&event.kind)
}

/// The conversation a projected feed is narrowed to. Moving it retargets the
/// running feed in place, so no event falls between two subscriptions.
#[frb(opaque)]
pub struct EventFeed {
    thread: watch::Sender<Option<String>>,
}

/// A feed narrowed to `thread_id`; `None` follows every conversation.
#[frb(sync)]
pub fn event_feed_create(thread_id: Option<String>) -> EventFeed {
    EventFeed {
        thread: watch::channel(thread_id).0,
    }
}

/// Retarget every stream of `feed` at once, without resubscribing.
#[frb(sync)]
pub fn event_feed_follow(feed: &EventFeed, thread_id: Option<String>) {
    feed.thread.send_replace(thread_id);
}

/// Stream live app-server events of `service_key` through a native
/// projection narrowed by `feed` and `topic`. Service-wide events (inventory,
/// resolved requests, other conversations' turn ends) still pass the thread
/// filter. The stream closes when the session disconnects or the feed lags and
/// requires history recovery.
pub fn app_projected_events(
    service_key: String,
    feed: &EventFeed,
    topic: EventTopic,
    sink: StreamSink<AppEventDto>,
) {
    let thread = feed.thread.subscribe();
    // Subscribe inside the task: a disconnected service closes the stream
    // (`onDone`, which the UI's reconnect handles). A setup `Err` would reach
    // Dart on an unawaited future instead of the stream.
    runtime::runtime().spawn(async move {
        let Ok(rx) = engine(&service_key).subscribe_events(&service_key) else { return };
        forward_projected_events(rx, thread, topic, |update| {
            let ev = update.event;
            sink.add(AppEventDto {
                diff: update.diff.map(Into::into),
                running: update.running,
                kind: ev.kind,
                thread_id: ev.thread_id,
                item_id: ev.item_id,
                item_type: ev.item_type,
                title: ev.title,
                text: ev.text,
                images: ev.images,
                request_id: ev.request_id,
                raw: ev.raw,
                turn_id: update.turn_id,
                sender: update.sender,
                text_is_snapshot: update.text_is_snapshot,
            })
            .is_ok()
        })
        .await;
    });
}

/// Forward accepted events in order, coalescing adjacent text deltas for at
/// most 16 ms. A lag closes the feed (after the retained requests history
/// cannot reconstruct) so the controller reloads history.
async fn forward_projected_events(
    mut rx: broadcast::Receiver<app_session::AppEvent>,
    thread: watch::Receiver<Option<String>>,
    topic: EventTopic,
    mut send: impl FnMut(ProjectedEvent) -> bool,
) {
    let mut view = Projection::default();
    let mut pending: Option<app_session::AppEvent> = None;
    let mut deadline = Instant::now();
    loop {
        let received = if pending.is_some() {
            tokio::select! {
                event = rx.recv() => Some(event),
                () = tokio::time::sleep_until(deadline) => None,
            }
        } else {
            Some(rx.recv().await)
        };
        let event = match received {
            Some(Ok(event)) => event,
            // The coalescing window closed.
            None => {
                if !send_pending(&mut view, &mut send, &mut pending).await {
                    break;
                }
                continue;
            },
            Some(Err(error)) => {
                if send_pending(&mut view, &mut send, &mut pending).await {
                    if let RecvError::Lagged(skipped) = error {
                        tracing::warn!(
                            skipped,
                            "controller projection lagged; closing for history recovery"
                        );
                        forward_retained_requests(&mut rx, &mut |event| {
                            !accepts(&event, thread.borrow().as_deref(), topic)
                                || send(view.apply(event))
                        });
                    }
                }
                break;
            },
        };
        if !accepts(&event, thread.borrow().as_deref(), topic) {
            continue;
        }
        if let Some(previous) = pending
            .as_mut()
            .filter(|p| projection::can_merge(p, &event))
        {
            let text = previous.text.get_or_insert_default();
            text.push_str(event.text.as_deref().unwrap_or_default());
            continue;
        }
        if !send_pending(&mut view, &mut send, &mut pending).await {
            break;
        }
        if projection::text_delta(&event) {
            deadline = Instant::now() + Duration::from_millis(16);
            pending = Some(event);
        } else if !send_projected(&mut view, &mut send, event).await {
            break;
        }
    }
}

async fn send_pending(
    view: &mut Projection,
    send: &mut impl FnMut(ProjectedEvent) -> bool,
    pending: &mut Option<app_session::AppEvent>,
) -> bool {
    match pending.take() {
        Some(event) => send_projected(view, send, event).await,
        None => true,
    }
}

async fn send_projected(
    view: &mut Projection,
    send: &mut impl FnMut(ProjectedEvent) -> bool,
    event: app_session::AppEvent,
) -> bool {
    let mut update = view.apply(event);
    if update.event.item_type.as_deref() == Some("fileChange") {
        // The event moves to the parser and back; its text is never copied.
        let parsed = execution::compute(move || {
            let text = update.event.text.as_deref().unwrap_or_default();
            update.diff = Some(git_diff::parse(text));
            update
        });
        update = match parsed.await {
            Ok(update) => update,
            Err(error) => {
                tracing::warn!(%error, "diff projection failed; closing for history recovery");
                return false;
            },
        };
    }
    send(update)
}

fn forward_retained_requests(
    rx: &mut broadcast::Receiver<app_session::AppEvent>,
    send: &mut impl FnMut(app_session::AppEvent) -> bool,
) {
    // History cannot reconstruct request IDs. Preserve prompts in the retained
    // tail before closing, without waiting for new data or chasing new events.
    for _ in 0..rx.len() {
        match rx.try_recv() {
            Ok(event) => {
                if event.request_id.is_some() && !send(event) {
                    return;
                }
            },
            Err(broadcast::error::TryRecvError::Lagged(_)) => {},
            Err(_) => break,
        }
    }
}

#[cfg(test)]
#[path = "bridge_events_tests.rs"]
mod bridge_events_tests;
