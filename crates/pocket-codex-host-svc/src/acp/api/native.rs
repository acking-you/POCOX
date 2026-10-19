//! Native transcript follow consumes a stream permit, never a writer lease.

use super::*;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct FollowQuery {
    session_id: String,
    host_id: String,
    generation: u64,
}

pub(super) async fn access(
    State(state): State<ApiState>,
    Query(query): Query<FollowQuery>,
) -> Result<Json<crate::session_access::SessionAccess>, ApiError> {
    state
        .host
        .session_access(&query.session_id, &Identity {
            host_id: Some(query.host_id),
            generation: Some(query.generation),
        })
        .await
        .map(Json)
        .map_err(ApiError)
}

pub(super) async fn auto_open(
    State(state): State<ApiState>,
    Json(query): Json<FollowQuery>,
) -> Result<Json<crate::session_access::SessionAccess>, ApiError> {
    state
        .host
        .session_open(&query.session_id, &Identity {
            host_id: Some(query.host_id),
            generation: Some(query.generation),
        })
        .await
        .map(Json)
        .map_err(ApiError)
}

pub(super) async fn access_release(
    State(state): State<ApiState>,
    Json(snapshot): Json<crate::session_access::SessionAccess>,
) -> Result<Json<crate::session_access::SessionAccess>, ApiError> {
    state
        .host
        .session_release(&snapshot)
        .await
        .map(Json)
        .map_err(ApiError)
}

pub(super) async fn control(
    State(state): State<ApiState>,
    Query(query): Query<FollowQuery>,
) -> Result<Json<crate::acp::session_control::SessionControl>, ApiError> {
    state
        .host
        .session_control(&query.session_id, &Identity {
            host_id: Some(query.host_id),
            generation: Some(query.generation),
        })
        .await
        .map(Json)
        .map_err(ApiError)
}

pub(super) async fn release(
    State(state): State<ApiState>,
    Json(query): Json<FollowQuery>,
) -> ApiResult {
    state
        .host
        .release_session(&query.session_id, &Identity {
            host_id: Some(query.host_id),
            generation: Some(query.generation),
        })
        .await
        .map(Json)
        .map_err(ApiError)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct AcquireBody {
    #[serde(flatten)]
    identity: FollowQuery,
    source_generation: String,
}

pub(super) async fn acquire(
    State(state): State<ApiState>,
    Json(body): Json<AcquireBody>,
) -> ApiResult {
    let query = body.identity;
    state
        .host
        .acquire_session(&query.session_id, &body.source_generation, &Identity {
            host_id: Some(query.host_id),
            generation: Some(query.generation),
        })
        .await
        .map(Json)
        .map_err(ApiError)
}

pub(super) async fn status(
    State(state): State<ApiState>,
    Query(query): Query<FollowQuery>,
) -> Result<Json<Value>, ApiError> {
    if query.host_id != state.host.host_id() {
        return Err(ApiError(HostError::Stale));
    }
    let body = state
        .host
        .native_status(&query.session_id)
        .await
        .map_err(ApiError)?;
    if body["generation"].as_u64() != Some(query.generation) {
        return Err(ApiError(HostError::Stale));
    }
    Ok(Json(body))
}

pub(super) async fn follow(
    State(state): State<ApiState>,
    Query(query): Query<FollowQuery>,
) -> Response {
    if query.host_id != state.host.host_id() || query.session_id.len() > 1024 {
        return ApiError(HostError::Stale).into_response();
    }
    let Ok(permit) = state.streams.clone().try_acquire_owned() else {
        return (StatusCode::SERVICE_UNAVAILABLE, "too many event streams").into_response();
    };
    let (tx, rx) = mpsc::channel::<std::result::Result<Event, Infallible>>(4);
    tokio::spawn(async move {
        let _permit = permit;
        // A live source (Grok's leader) wakes the stream at once; others,
        // and file-only changes, are seen by the 2-second poll.
        let mut live = state.host.native_follow(&query.session_id);
        loop {
            let result = tokio::select! {
                () = tx.closed() => return,
                result = state.host.native_status(&query.session_id) => result,
            };
            let body = match result {
                Ok(body) if body["generation"].as_u64() == Some(query.generation) => body,
                _ => return,
            };
            // Heartbeats let the receiver release a disposed view even when
            // the transcript is unchanged. Only revisions trigger a re-read.
            if tx
                .send(Ok(Event::default().data(body.to_string())))
                .await
                .is_err()
            {
                return;
            }
            let woke = tokio::select! {
                () = tx.closed() => return,
                () = tokio::time::sleep(std::time::Duration::from_secs(2)) => false,
                changed = crate::native_history::NativeFollow::next(&mut live) => changed,
            };
            if woke {
                // Coalesce a streamed burst into one re-read.
                tokio::select! {
                    () = tx.closed() => return,
                    () = tokio::time::sleep(LIVE_COALESCE) => {},
                }
            }
        }
    });
    Sse::new(ReceiverStream::new(rx)).into_response()
}

/// How long a live change waits for the rest of its burst.
const LIVE_COALESCE: std::time::Duration = std::time::Duration::from_millis(200);
