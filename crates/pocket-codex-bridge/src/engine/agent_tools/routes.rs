//! `/services/v1` on the device's management entry: the catalog, its event
//! stream, and the user's answers from any of their devices.
//!
//! Reached only through the relay by the user's own devices (the entry is
//! published in the account's namespace or under the relay key). Every
//! request, and every event a stream sends, first checks that the entry is
//! still admitted, so a stream ends by itself when management is withdrawn
//! or the account changes.

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
use serde::Deserialize;

use super::{
    catalog, consent,
    error::ToolError,
    model::{Catalog, CatalogEvent, Decision},
    shares, state,
};

/// Whether the entry still admits requests.
pub type Admitted = Arc<dyn Fn() -> bool + Send + Sync>;

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
        ToolError::NotOwner | ToolError::Off | ToolError::Declined => StatusCode::FORBIDDEN,
        ToolError::NotHosting | ToolError::Relay(_) => StatusCode::SERVICE_UNAVAILABLE,
        ToolError::Conflict(_) => StatusCode::CONFLICT,
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

fn events(admitted: Admitted) -> impl futures::Stream<Item = Result<Event, Infallible>> {
    let changes = state::changes();
    futures::stream::unfold(
        (changes, None::<Catalog>, admitted),
        |(mut changes, previous, admitted)| async move {
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
            Some((Ok(message), (changes, Some(catalog), admitted)))
        },
    )
}

/// The routes, guarded by `admitted`.
pub fn router(admitted: Admitted) -> Router {
    let guard = |admitted: &Admitted| -> Option<Response> { (!admitted()).then(refused) };
    let (a1, a2, a3, a4, a5) =
        (admitted.clone(), admitted.clone(), admitted.clone(), admitted.clone(), admitted);
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
                Sse::new(events(a2.clone()))
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
