//! Event streams for Dart: the bridge log, meta-service retry progress and
//! app-server session events.

use super::*;

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
    crate::engine::execution::run(crate::engine::execution::Lane::Read, move || {
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

/// Stream captured `tracing` events for the in-app log viewer: the retained
/// recent history (oldest first) followed by every new event live, until the
/// Dart side drops the stream. Subscribes before replaying history so nothing
/// is missed in between (a line captured right at that boundary may appear
/// twice — harmless for a log tail).
pub fn log_events(sink: StreamSink<LogLineDto>) -> Result<()> {
    runtime::runtime().spawn(async move {
        let Some(mut rx) = logging::subscribe() else {
            return;
        };
        for line in logging::snapshot() {
            if sink.add(to_log_dto(line)).is_err() {
                return;
            }
        }
        loop {
            match rx.recv().await {
                Ok(line) => {
                    if sink.add(to_log_dto(line)).is_err() {
                        break;
                    }
                },
                // Dropped some lines under load — keep streaming the rest.
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
    Ok(())
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
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
    Ok(())
}

/// Stream live app-server events (turn/item notifications) for `service_key`.
/// The Dart side receives one [`AppEventDto`] per notification until the
/// session is disconnected or the feed lags and requires history recovery.
pub fn app_events(service_key: String, sink: StreamSink<AppEventDto>) -> Result<()> {
    // Subscribe *inside* the task and always return `Ok` at setup. If the service
    // isn't connected, the task returns immediately and dropping `sink` closes the
    // Dart stream (`onDone`), which the UI's reconnect path already handles.
    // Returning the error from here instead would be worse: flutter_rust_bridge
    // delivers a stream function's setup `Err` on an *unawaited* Future, so it
    // surfaces as an uncaught async error on the Dart side — fatal on desktop
    // (no global handler) — rather than a catchable stream `onError`/`onDone`.
    runtime::runtime().spawn(async move {
        let subscribed = engine(&service_key).subscribe_events(&service_key);
        let rx = match subscribed {
            Ok(rx) => rx,
            // Not connected: close the stream so Dart sees `onDone`.
            Err(_) => return,
        };
        forward_app_events(rx, |ev| {
            sink.add(AppEventDto {
                diff: None,
                running: None,
                kind: ev.kind,
                thread_id: ev.thread_id,
                item_id: ev.item_id,
                item_type: ev.item_type,
                title: ev.title,
                text: ev.text,
                images: ev.images,
                request_id: ev.request_id,
                raw: ev.raw,
                turn_id: None,
                sender: None,
                text_is_snapshot: false,
            })
            .is_ok()
        })
        .await;
    });
    Ok(())
}

pub(super) async fn forward_app_events(
    mut rx: tokio::sync::broadcast::Receiver<app_session::AppEvent>,
    mut send: impl FnMut(app_session::AppEvent) -> bool,
) {
    use tokio::sync::broadcast::error::RecvError;

    loop {
        match rx.recv().await {
            Ok(event) => {
                if !send(event) {
                    break;
                }
            },
            Err(RecvError::Lagged(skipped)) => {
                // Missing final items or turn/completed cannot be recovered by
                // later deltas. Close only this feed so Dart reloads history.
                tracing::warn!(skipped, "app event feed lagged; closing for history recovery");
                forward_retained_requests(&mut rx, &mut send);
                break;
            },
            Err(RecvError::Closed) => break,
        }
    }
}

fn forward_retained_requests(
    rx: &mut tokio::sync::broadcast::Receiver<app_session::AppEvent>,
    send: &mut impl FnMut(app_session::AppEvent) -> bool,
) {
    // History cannot reconstruct request IDs. Preserve prompts in the retained
    // tail before closing, without waiting for new data or chasing new events.
    let retained = rx.len();
    for _ in 0..retained {
        match rx.try_recv() {
            Ok(event) => {
                if event.request_id.is_some() && !send(event) {
                    return;
                }
            },
            Err(tokio::sync::broadcast::error::TryRecvError::Lagged(_)) => {},
            Err(_) => break,
        }
    }
}

#[cfg(test)]
#[path = "bridge_events_tests.rs"]
mod bridge_events_tests;

/// Subscribe to a native controller projection. `topic` is `all`, `activity`
/// or `realtime`; an optional thread filter still admits service-wide events.
pub fn app_projected_events(
    service_key: String,
    thread_id: Option<String>,
    topic: String,
    sink: StreamSink<AppEventDto>,
) {
    runtime::runtime().spawn(async move {
        let Ok(rx) = engine(&service_key).subscribe_events(&service_key) else { return };
        forward_projected_events(rx, thread_id, topic, |update| {
            let ev = update.event;
            sink.add(AppEventDto {
                diff: update.diff.as_deref().map(super::diff::dto),
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

async fn forward_projected_events(
    mut rx: tokio::sync::broadcast::Receiver<app_session::AppEvent>,
    thread: Option<String>,
    topic: String,
    mut send: impl FnMut(crate::engine::session_projection::ProjectedEvent) -> bool,
) {
    use tokio::{
        sync::broadcast::error::RecvError,
        time::{Duration, Instant},
    };

    use crate::engine::session_projection::{self as projection, Projection};
    let mut view = Projection::default();
    let mut pending: Option<app_session::AppEvent> = None;
    let mut deadline = Instant::now();
    loop {
        let received = if pending.is_some() {
            tokio::select! {
                event = rx.recv() => Some(event),
                _ = tokio::time::sleep_until(deadline) => None,
            }
        } else {
            Some(rx.recv().await)
        };
        let Some(received) = received else {
            if let Some(event) = pending.take() {
                if !send_projected(&mut view, &mut send, event).await {
                    break;
                }
            }
            continue;
        };
        let event = match received {
            Ok(event) => event,
            Err(error) => {
                if let Some(event) = pending.take() {
                    if !send_projected(&mut view, &mut send, event).await {
                        break;
                    }
                }
                if let RecvError::Lagged(skipped) = error {
                    tracing::warn!(
                        skipped,
                        "controller projection lagged; closing for history recovery"
                    );
                    forward_retained_requests(&mut rx, &mut |event| {
                        !projection::accepts(&event, thread.as_deref(), &topic)
                            || send(view.apply(event))
                    });
                }
                break;
            },
        };
        if !projection::accepts(&event, thread.as_deref(), &topic) {
            continue;
        }
        if let Some(previous) = &mut pending {
            if projection::can_merge(previous, &event) {
                previous
                    .text
                    .get_or_insert_default()
                    .push_str(event.text.as_deref().unwrap_or_default());
                continue;
            }
        }
        if let Some(previous) = pending.take() {
            if !send_projected(&mut view, &mut send, previous).await {
                break;
            }
        }
        if projection::text_delta(&event) {
            deadline = Instant::now() + Duration::from_millis(16);
            pending = Some(event);
        } else if !send_projected(&mut view, &mut send, event).await {
            break;
        }
    }
}

async fn send_projected(
    view: &mut crate::engine::session_projection::Projection,
    send: &mut impl FnMut(crate::engine::session_projection::ProjectedEvent) -> bool,
    event: app_session::AppEvent,
) -> bool {
    let mut update = view.apply(event);
    if update.event.item_type.as_deref() == Some("fileChange") {
        let text = update.event.text.clone().unwrap_or_default();
        match crate::engine::execution::run(crate::engine::execution::Lane::Cpu, move || {
            Ok(crate::engine::git_diff::parse(&text))
        })
        .await
        {
            Ok(diff) => update.diff = Some(diff),
            Err(error) => {
                tracing::warn!(%error, "diff projection unavailable; closing for history recovery");
                return false;
            },
        }
    }
    send(update)
}
