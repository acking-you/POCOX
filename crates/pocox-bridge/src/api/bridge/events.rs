//! Event streams for Dart: the bridge log, meta-service retry progress and
//! app-server session events.

use super::*;

/// One app-server event mirrored for Dart. `kind` is the JSON-RPC method
/// (e.g. `turn/started`, `item/agentMessage/delta`, `turn/completed`).
pub struct AppEventDto {
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
                kind: ev.kind,
                thread_id: ev.thread_id,
                item_id: ev.item_id,
                item_type: ev.item_type,
                title: ev.title,
                text: ev.text,
                images: ev.images,
                request_id: ev.request_id,
                raw: ev.raw,
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
