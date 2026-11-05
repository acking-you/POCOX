//! Route table and the checks every pairing route shares.

use std::sync::Arc;

use axum::extract::rejection::JsonRejection;
use axum::extract::{FromRequest, Request, State};
use axum::http::header::{AUTHORIZATION, CACHE_CONTROL};
use axum::http::{HeaderMap, HeaderValue, StatusCode};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, patch, post};
use axum::{Json, Router};
use pocox_account_proto::pairing::{
    is_operation_id, secret_is_well_formed, DeviceSession, OperationKind as WireKind,
    OperationStatus, OperationView, PairDeviceRequest, PairingErrorCode, PAIRING_PROTOCOL_HEADER,
    PAIRING_PROTOCOL_VERSION,
};
use pocox_auth::pairing::hash_device_secret;
use pocox_auth::{DeviceCaller, Principal, SessionMode};
use pocox_store::pairing::{
    DeviceAccess, NewDevice, NewDeviceOutcome, OperationKind, OperationState, PairOperation,
    Prepared,
};

use super::address::PeerAddr;
use super::error::{PairingError, PairingResult};
use super::service::{ClientBucket, Pairing};
use crate::api::AppState;

/// Pairing bodies are small. The API's general limit is much larger.
const MAX_BODY_BYTES: usize = 8 * 1024;

pub(super) fn now() -> i64 {
    time::OffsetDateTime::now_utc().unix_timestamp()
}

/// Every pairing route. Refreshing a device and the routes GitHub sessions
/// share are in [`crate::api`], on top of [`gate`].
pub(crate) fn router(state: AppState) -> Router<AppState> {
    Router::new()
        .route("/v1/pair/device", post(create_device))
        .route("/v1/pair/activate", post(super::routes_code::activate))
        .route("/v1/pair/code", get(super::routes_code::code).patch(super::routes_code::set_paused))
        .route("/v1/pair/code/rotate", post(super::routes_code::rotate))
        .route("/v1/pair/preview", post(super::routes_link::preview))
        .route("/v1/pair/link", post(super::routes_link::link))
        .route("/v1/pair/leave", post(super::routes_link::leave))
        .route("/v1/pair/restore/requests", post(super::routes_restore::create_request))
        .route("/v1/pair/restore/{request_id}", get(super::routes_restore::request_status))
        .route("/v1/pair/restore", post(super::routes_restore::confirm))
        .route("/v1/devices", get(super::routes_group::list))
        .route(
            "/v1/devices/{id}",
            patch(super::routes_group::rename).delete(super::routes_group::remove),
        )
        .route("/v1/devices/{id}/restore", post(super::routes_restore::decide))
        .route("/v1/pair/operations/{id}", get(operation))
        .layer(middleware::from_fn_with_state(state, shared_limits))
}

/// Codes and tokens pass through these responses, so nothing may cache them;
/// and only so many pairing requests run at once.
///
/// The body is read before a slot is taken, under its own short bound.
/// Otherwise one client stalling its uploads could hold every slot while
/// sending nothing.
async fn shared_limits(State(state): State<AppState>, request: Request, next: Next) -> Response {
    let Some(pairing) = state.pairing.clone() else {
        return no_store(next.run(request).await);
    };
    let (parts, body) = request.into_parts();
    let body = axum::body::to_bytes(body, MAX_BODY_BYTES);
    let bytes = match tokio::time::timeout(pairing.settings.body_read_timeout, body).await {
        Ok(Ok(bytes)) => bytes,
        Ok(Err(_)) => {
            let error = PairingError::code(PairingErrorCode::InvalidRequest).into_response();
            return no_store((StatusCode::PAYLOAD_TOO_LARGE, error).into_response());
        },
        Err(_) => {
            let error = PairingError::code(PairingErrorCode::InvalidRequest).into_response();
            return no_store((StatusCode::REQUEST_TIMEOUT, error).into_response());
        },
    };
    let permit = match pairing.enter() {
        Ok(permit) => permit,
        Err(error) => return no_store(error.into_response()),
    };
    let response = next
        .run(Request::from_parts(parts, axum::body::Body::from(bytes)))
        .await;
    drop(permit);
    no_store(response)
}

fn no_store(mut response: Response) -> Response {
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    response
}

/// A JSON body whose rejection is a pairing error rather than plain text.
pub(super) struct PairJson<T>(pub(super) T);

impl<S, T> FromRequest<S> for PairJson<T>
where
    Json<T>: FromRequest<S, Rejection = JsonRejection>,
    S: Send + Sync,
{
    type Rejection = PairingError;

    async fn from_request(request: Request, state: &S) -> Result<Self, Self::Rejection> {
        let Json(value) = Json::<T>::from_request(request, state)
            .await
            .map_err(|_| PairingError::code(PairingErrorCode::InvalidRequest))?;
        Ok(Self(value))
    }
}

/// The pairing service, or 503 when this backend has no pairing secret.
pub(crate) fn enabled(state: &AppState) -> PairingResult<Arc<Pairing>> {
    state
        .pairing
        .clone()
        .ok_or(PairingError::code(PairingErrorCode::PairingDisabled))
}

/// Refuse a client whose pairing protocol is missing or unsupported, before any
/// side effect.
pub(crate) fn check_protocol(headers: &HeaderMap) -> PairingResult<()> {
    let supported = headers
        .get(PAIRING_PROTOCOL_HEADER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.trim().parse::<u32>().ok())
        == Some(PAIRING_PROTOCOL_VERSION);
    if supported {
        Ok(())
    } else {
        Err(PairingError::code(PairingErrorCode::PairingClientUpgradeRequired))
    }
}

/// Whether a verified token is a device session.
pub(crate) fn is_device_token(claims: &pocox_auth::Claims) -> bool {
    matches!(claims.principal(), Some(Principal::Device { .. }))
}

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
}

/// Authenticate a device session for a pairing route.
///
/// A GitHub session is refused rather than converted, and a device token passes
/// only if the database agrees about its row, user, generation and state right
/// now.
pub(crate) async fn gate(
    state: &AppState,
    headers: &HeaderMap,
) -> PairingResult<(Arc<Pairing>, DeviceCaller)> {
    let pairing = enabled(state)?;
    check_protocol(headers)?;
    let token = bearer(headers).ok_or(PairingError::code(PairingErrorCode::SessionStale))?;
    let claims = state
        .auth
        .verify(token)
        .map_err(|_| PairingError::code(PairingErrorCode::SessionStale))?;
    if !is_device_token(&claims) {
        return Err(PairingError::code(PairingErrorCode::DeviceSessionRequired));
    }
    let caller = state.auth.authenticate_device(&claims, now()).await?;
    Ok((pairing, caller))
}

/// Require a current session: a retiring one may not read codes or change
/// anything.
pub(super) fn require_current(caller: &DeviceCaller) -> PairingResult<()> {
    match caller.mode {
        SessionMode::Current => Ok(()),
        SessionMode::Retiring {
            ..
        } => Err(PairingError::code(PairingErrorCode::GraceRestricted)),
    }
}

/// Require a well-formed operation id.
pub(super) fn require_operation_id(id: &str) -> PairingResult<()> {
    if is_operation_id(id) {
        Ok(())
    } else {
        Err(PairingError::code(PairingErrorCode::InvalidRequest))
    }
}

fn wire_kind(kind: OperationKind) -> WireKind {
    match kind {
        OperationKind::Link => WireKind::Link,
        OperationKind::Leave => WireKind::Leave,
        OperationKind::Remove => WireKind::Remove,
        OperationKind::Restore => WireKind::Restore,
        OperationKind::Retake => WireKind::Retake,
        OperationKind::Rotate => WireKind::Rotate,
        OperationKind::Decide => WireKind::Decide,
    }
}

impl Pairing {
    /// A session for this secret, issued only because it is current right now.
    /// A stored result never holds one. `None` while another transition is
    /// moving it.
    async fn session_for_secret(
        &self,
        secret_hash: &[u8],
        at: i64,
    ) -> PairingResult<Option<DeviceSession>> {
        let Some(access) = self.store.device_by_secret(secret_hash).await? else {
            return Ok(None);
        };
        if access.device.pending_transition_id.is_some() || access.session.grace_deadline.is_some()
        {
            return Ok(None);
        }
        Ok(Some(self.auth.issue_device_session(&access, at)?))
    }

    /// An operation as the client sees it. `with_session` says whether this
    /// response may carry a fresh session: see [`Self::finish_mutation`].
    pub(super) async fn operation_view(
        &self,
        operation: &PairOperation,
        with_session: bool,
        at: i64,
    ) -> PairingResult<OperationView> {
        let (status, error, session) = match operation.state {
            OperationState::Prepared | OperationState::RelayApplied => {
                (OperationStatus::Pending, None, None)
            },
            OperationState::Failed => (
                OperationStatus::Failed,
                operation
                    .result_code
                    .as_deref()
                    .and_then(PairingErrorCode::from_stored),
                None,
            ),
            OperationState::Committed => (
                OperationStatus::Completed,
                None,
                if with_session {
                    self.session_for_secret(&operation.actor_secret_hash, at)
                        .await?
                } else {
                    None
                },
            ),
        };
        Ok(OperationView {
            operation_id: operation.id.clone(),
            kind: wire_kind(operation.kind),
            status,
            error,
            session,
        })
    }

    /// The response to a mutation: 202 while relay work is incomplete, the
    /// stable failure code if it failed, and the completed result
    /// otherwise.
    pub(super) async fn respond_to_operation(
        &self,
        operation: &PairOperation,
        with_session: bool,
    ) -> PairingResult<Response> {
        let view = self.operation_view(operation, with_session, now()).await?;
        match view.status {
            OperationStatus::Failed => {
                Err(PairingError::code(view.error.unwrap_or(PairingErrorCode::PreviewStale)))
            },
            OperationStatus::Completed => Ok((StatusCode::OK, Json(view)).into_response()),
            OperationStatus::Pending | OperationStatus::Unknown => {
                Ok((StatusCode::ACCEPTED, Json(view)).into_response())
            },
        }
    }

    /// Drive what a mutation prepared and answer it.
    ///
    /// The answer carries a session only if this very request moved this
    /// device, whose old token it just killed. A no-op, a replay or a
    /// removal of a peer moved nobody, and a token that could renew itself
    /// by asking for one would never need the secret again: a restored
    /// `config.toml` would stay signed in forever.
    pub(super) async fn finish_mutation(
        self: &Arc<Self>,
        prepared: Prepared,
    ) -> PairingResult<Response> {
        let moved_caller = prepared.is_new
            && !prepared.operation.no_op
            && matches!(
                prepared.operation.kind,
                OperationKind::Link
                    | OperationKind::Leave
                    | OperationKind::Restore
                    | OperationKind::Retake
            );
        let driven = self.drive_in_foreground(prepared.operation).await?;
        self.respond_to_operation(&driven, moved_caller).await
    }

    /// `transition_pending` for a device reached by its secret. The operation's
    /// id goes only to the device that asked for it.
    async fn pending_refusal(&self, access: &DeviceAccess, secret_hash: &[u8]) -> PairingError {
        let own = match &access.device.pending_transition_id {
            Some(id) => self.store.operation(id).await.ok().flatten(),
            None => None,
        }
        .filter(|operation| operation.actor_secret_hash == secret_hash)
        .map(|operation| operation.id);
        pocox_store::Refusal::TransitionPending {
            operation_id: own,
        }
        .into()
    }

    /// If `id` was already used, this request is a retry: its result, or a
    /// conflict if the input differs. Checked before anything that might
    /// have expired since.
    pub(super) async fn replay(
        &self,
        id: &str,
        fingerprint: &[u8],
    ) -> PairingResult<Option<PairOperation>> {
        match self.store.operation(id).await? {
            Some(operation) if operation.fingerprint == fingerprint => Ok(Some(operation)),
            Some(_) => Err(PairingError::code(PairingErrorCode::OperationConflict)),
            None => Ok(None),
        }
    }
}

/// `POST /v1/pair/device`: idempotently create an inactive device for a new
/// secret. Takes no hint and looks nothing up, so a first open cannot pull
/// anyone into a stranger's group.
async fn create_device(
    State(state): State<AppState>,
    PeerAddr(peer): PeerAddr,
    headers: HeaderMap,
    PairJson(request): PairJson<PairDeviceRequest>,
) -> PairingResult<Response> {
    let pairing = enabled(&state)?;
    check_protocol(&headers)?;
    if !secret_is_well_formed(&request.device_secret) {
        return Err(PairingError::code(PairingErrorCode::InvalidRequest));
    }
    let label = pocox_account_proto::pairing::parse_label(&request.label)
        .ok_or(PairingError::code(PairingErrorCode::InvalidRequest))?;
    let platform = request
        .platform
        .as_deref()
        .and_then(pocox_account_proto::pairing::parse_label);
    let hash = hash_device_secret(&request.device_secret);
    let at = now();
    // A retry of a known secret returns its status without being charged or
    // creating anything; only a new secret pays admission.
    let known = pairing.store.device_by_secret(&hash).await?;
    if known.is_none() {
        if let Some(grace_deadline) = pairing.store.superseded_secret(&hash).await? {
            return Err(pocox_auth::AuthError::DeviceSuperseded {
                grace_deadline,
            }
            .into());
        }
        pairing.require_capable_relay().await?;
        let bucket: ClientBucket = pairing.client_bucket(peer, &headers);
        pairing
            .limiters
            .new_devices
            .charge(bucket.0, at)
            .map_err(|wait| PairingError::retry_later(PairingErrorCode::RateLimited, wait))?;
        pairing
            .charge_backend("new_devices", pairing.settings.limits.new_devices_backend, at)
            .await?;
    }
    let outcome = pairing
        .store
        .create_device(
            NewDevice {
                secret_hash: &hash,
                label: &label,
                platform: platform.as_deref(),
                now: at,
            },
            pairing.derive_lookup.as_ref(),
        )
        .await?;
    let access = match outcome {
        NewDeviceOutcome::Created(access) | NewDeviceOutcome::Existing(access) => access,
        NewDeviceOutcome::Superseded {
            grace_deadline,
        } => {
            return Err(pocox_auth::AuthError::DeviceSuperseded {
                grace_deadline,
            }
            .into());
        },
    };
    // A pending device still answers with its status; only a current, idle one gets
    // a session here.
    if access.device.pending_transition_id.is_some() || access.session.grace_deadline.is_some() {
        return Err(pairing.pending_refusal(&access, &hash).await);
    }
    let session = state.auth.issue_device_session(&access, at)?;
    Ok(Json(session).into_response())
}

/// `GET /v1/pair/operations/{id}`: read a result after a lost response or stale
/// JWT. Authorized by the actor's current secret, sent as the bearer value.
/// Knowing an operation id alone yields nothing.
async fn operation(
    State(state): State<AppState>,
    headers: HeaderMap,
    axum::extract::Path(id): axum::extract::Path<String>,
) -> PairingResult<Response> {
    let pairing = enabled(&state)?;
    check_protocol(&headers)?;
    let secret = bearer(&headers).ok_or(PairingError::code(PairingErrorCode::DeviceUnknown))?;
    if !secret_is_well_formed(secret) {
        return Err(PairingError::code(PairingErrorCode::DeviceUnknown));
    }
    let hash = hash_device_secret(secret);
    if pairing.store.device_by_secret(&hash).await?.is_none() {
        return Err(match pairing.store.superseded_secret(&hash).await? {
            Some(grace_deadline) => pocox_auth::AuthError::DeviceSuperseded {
                grace_deadline,
            }
            .into(),
            None => PairingError::code(PairingErrorCode::DeviceUnknown),
        });
    }
    let found = pairing
        .store
        .operation(&id)
        .await?
        .filter(|operation| operation.actor_secret_hash == hash)
        .ok_or(PairingError::code(PairingErrorCode::OperationUnknown))?;
    let view = pairing.operation_view(&found, true, now()).await?;
    let status = match view.status {
        OperationStatus::Pending | OperationStatus::Unknown => StatusCode::ACCEPTED,
        OperationStatus::Completed | OperationStatus::Failed => StatusCode::OK,
    };
    Ok((status, Json(view)).into_response())
}
