//! `/services/v1` on the device's management entry: the catalog, its event
//! stream, and the user's answers from any of their devices.
//!
//! The user's devices reach it through the relay (the entry is published in
//! the account's namespace or under the relay key). Like the rest of device
//! management, its listener is on this machine's loopback, so a program
//! running as the user here can reach it too: these routes trust the same
//! boundary (`docs/agent-tools.md`, Trust boundary). Browsers are refused by
//! the entry's loopback guard. Every request, and every event a stream sends,
//! first checks that the entry is still admitted, so a stream ends by itself
//! when management is withdrawn or the account changes.

use std::{convert::Infallible, sync::Arc, time::Duration};

use axum::{
    extract::Path,
    http::StatusCode,
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse, Response,
    },
    routing::{get, post},
    Json, Router,
};
use once_cell::sync::Lazy;
use serde::Deserialize;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};

use super::{
    catalog, consent,
    error::ToolError,
    model::{Catalog, CatalogEvent, Decision},
    shares, state,
};

/// Whether the entry still admits requests.
pub type Admitted = Arc<dyn Fn() -> bool + Send + Sync>;

/// Event streams served at once (one per controller following this device).
static STREAMS: Lazy<Arc<Semaphore>> = Lazy::new(|| Arc::new(Semaphore::new(32)));

fn refused() -> Response {
    (
        StatusCode::FORBIDDEN,
        Json(serde_json::json!({
            "code": "connection_changed",
            "message": "The device withdrew its entry or the connection changed. Refresh.",
        })),
    )
        .into_response()
}

/// The response for a tool failure.
pub fn failure(error: ToolError) -> Response {
    let status = match error {
        ToolError::NotFound(_) => StatusCode::NOT_FOUND,
        ToolError::Invalid(_) => StatusCode::BAD_REQUEST,
        ToolError::NotOwner
        | ToolError::Off
        | ToolError::Declined
        | ToolError::Revoked
        | ToolError::ContextChanged => StatusCode::FORBIDDEN,
        ToolError::NotHosting | ToolError::Relay(_) => StatusCode::SERVICE_UNAVAILABLE,
        ToolError::Conflict(_) => StatusCode::CONFLICT,
        ToolError::NotSaved => StatusCode::INTERNAL_SERVER_ERROR,
    };
    (status, Json(serde_json::json!({"code": error.code(), "message": error.message()})))
        .into_response()
}

fn reply<T: serde::Serialize>(result: Result<T, ToolError>) -> Response {
    match result {
        Ok(value) => Json(value).into_response(),
        Err(error) => failure(error),
    }
}

#[derive(Deserialize)]
struct Answer {
    decision: Decision,
}

/// Built-in tools the user picked in the composer of another of their
/// devices, for one conversation of an agent host on this device.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GrantBody {
    /// The agent service (`pcx:<device>:<kind>:<name>` or the account form).
    pub service: String,
    /// Its conversation (thread or session id).
    pub conversation: String,
    /// The picked built-in tools' ids.
    pub tools: Vec<String>,
}

/// A share the user asks for from another of their devices (Share and open
/// on a `localhost` link in a conversation).
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShareBody {
    /// Ports of the device that serves this route.
    pub ports: Vec<u16>,
    /// What it is.
    #[serde(default)]
    pub title: Option<String>,
    /// Path to open.
    #[serde(default)]
    pub path: Option<String>,
    /// The page is served over TLS.
    #[serde(default)]
    pub secure: bool,
}

/// The catalog's events; `permit` is held for the stream's lifetime.
fn events(
    admitted: Admitted,
    permit: OwnedSemaphorePermit,
) -> impl futures::Stream<Item = Result<Event, Infallible>> {
    let changes = state::changes();
    futures::stream::unfold(
        (changes, None::<Catalog>, admitted, permit),
        |(mut changes, previous, admitted, permit)| async move {
            if previous.is_some() {
                loop {
                    tokio::select! {
                        changed = changes.changed() => {
                            if changed.is_err() {
                                return None;
                            }
                            break;
                        },
                        _ = tokio::time::sleep(Duration::from_secs(2)) => {
                            if !admitted() {
                                return None;
                            }
                        },
                    }
                }
                // Several changes in a burst become one message.
                tokio::time::sleep(Duration::from_millis(150)).await;
                changes.borrow_and_update();
            }
            if !admitted() {
                return None;
            }
            let catalog = catalog::local().ok()?;
            let event = CatalogEvent::after(previous.as_ref(), catalog.clone());
            let message = Event::default().event("catalog").json_data(event).ok()?;
            Some((Ok(message), (changes, Some(catalog), admitted, permit)))
        },
    )
}

/// The routes, guarded by `admitted`, for an entry admitted under transport
/// `epoch` (a share asked under it is never made under another account).
pub fn router(admitted: Admitted, epoch: u64) -> Router {
    let guard = |admitted: &Admitted| -> Option<Response> { (!admitted()).then(refused) };
    let (a1, a2, a3, a4, a5, a6, a7) = (
        admitted.clone(),
        admitted.clone(),
        admitted.clone(),
        admitted.clone(),
        admitted.clone(),
        admitted.clone(),
        admitted,
    );
    Router::new()
        .route(
            "/services/v1",
            get(move || async move {
                if let Some(refusal) = guard(&a1) {
                    return refusal;
                }
                match catalog::local() {
                    Ok(catalog) => Json(catalog).into_response(),
                    Err(_) => failure(ToolError::NotHosting),
                }
            }),
        )
        .route(
            "/services/v1/events",
            get(move || async move {
                if let Some(refusal) = guard(&a2) {
                    return refusal;
                }
                let Ok(permit) = STREAMS.clone().try_acquire_owned() else {
                    return StatusCode::SERVICE_UNAVAILABLE.into_response();
                };
                Sse::new(events(a2.clone(), permit))
                    .keep_alive(KeepAlive::default())
                    .into_response()
            }),
        )
        .route(
            "/services/v1/consents/{id}",
            post(move |Path(id): Path<String>, Json(answer): Json<Answer>| async move {
                if let Some(refusal) = guard(&a3) {
                    return refusal;
                }
                reply(consent::answer(&id, answer.decision).map(|()| serde_json::json!({})))
            }),
        )
        .route(
            "/services/v1/grants",
            post(move |Json(body): Json<GrantBody>| async move {
                if let Some(refusal) = guard(&a7) {
                    return refusal;
                }
                reply(
                    super::grant(&body.service, &body.conversation, &body.tools, Some(epoch))
                        .map(|()| serde_json::json!({})),
                )
            }),
        )
        .route(
            "/services/v1/shares",
            post(move |Json(body): Json<ShareBody>| async move {
                if let Some(refusal) = guard(&a6) {
                    return refusal;
                }
                // The user asked, from one of their own devices: no consent
                // prompt, and the share lasts until they stop it.
                let caller = shares::Caller::user("You");
                let request = shares::ShareRequest {
                    ports: body.ports,
                    title: body.title,
                    path: body.path,
                    wait_ready_seconds: Some(5),
                    secure: body.secure,
                    epoch: Some(epoch),
                };
                match shares::share(&caller, request).await {
                    Ok(Ok(shared)) => Json(shared).into_response(),
                    Ok(Err(pending)) => failure(ToolError::Invalid(pending.message())),
                    Err(error) => failure(error),
                }
            }),
        )
        .route(
            "/services/v1/shares/{id}/stop",
            post(move |Path(id): Path<String>, Json(_): Json<serde_json::Value>| async move {
                if let Some(refusal) = guard(&a4) {
                    return refusal;
                }
                reply(shares::stop(None, &id))
            }),
        )
        .route(
            "/services/v1/shares/{id}/keep",
            post(move |Path(id): Path<String>, Json(_): Json<serde_json::Value>| async move {
                if let Some(refusal) = guard(&a5) {
                    return refusal;
                }
                reply(shares::keep(&id))
            }),
        )
}
