//! The HTTP API: GitHub device-flow auth, session refresh/logout, the
//! per-account `/v1/me` + `/v1/services` views, and `/v1/relay` — the endpoint
//! that hands a client its own relay credential so the backend leaves the data
//! path entirely.

use std::sync::Arc;
use std::time::Duration;

use axum::extract::{Path, Query, State};
use axum::http::header::{AUTHORIZATION, CACHE_CONTROL};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{Html, IntoResponse, Redirect, Response};
use axum::routing::{delete, get, post};
use axum::{Json, Router};
use pocox_account_proto::http::{
    DevicePollRequest, DevicePollResponse, DeviceStartRequest, DeviceStartResponse, LogoutRequest,
    MeResponse, RefreshResponse, RelayCredentialResponse, ServiceEntry, ServicesResponse,
    WebExchangeRequest, WebExchangeResponse, WebStartRequest, WebStartResponse,
};
use pocox_account_proto::key::NamespacedServiceId;
use pocox_account_proto::pairing::PairingErrorCode;
use pocox_auth::{Auth, AuthError, Claims, DeviceCaller, SessionMode};
use pocox_core::service::{ServiceId, ServiceKind};
use serde::Deserialize;
use tower_http::limit::RequestBodyLimitLayer;
use tower_http::timeout::TimeoutLayer;
use tower_http::trace::TraceLayer;

use crate::pairing::{self, Pairing, PairingError, PeerAddr};

/// Shared state for the HTTP handlers.
#[derive(Clone)]
pub struct AppState {
    /// The identity/session service.
    pub auth: Arc<Auth>,
    /// The relay plus the ADMINISTRATOR credential, for the two things the
    /// backend still does on an account's behalf: listing its services across
    /// namespaces, and retiring a registration whose owner is gone.
    pub relay: pocox_pb::RelaySession,
    /// Vends each account its own short-lived relay credential.
    pub credentials: crate::credentials::Credentials,
    /// Pairing-code login, or `None` when `POCOX_PAIRING_SECRET` is unset:
    /// pairing routes then answer 503, device tokens fail closed and GitHub
    /// is unaffected.
    pub pairing: Option<Arc<Pairing>>,
}

/// Build the HTTP API router.
pub fn router(state: AppState) -> Router {
    Router::new()
        .merge(pairing::router(state.clone()))
        .route("/healthz", get(healthz))
        .route("/auth/device/start", post(device_start))
        .route("/auth/device/poll", post(device_poll))
        .route("/auth/web/start", post(web_start))
        .route("/auth/web/callback", get(web_callback))
        .route("/auth/web/exchange", post(web_exchange))
        // Carries a device secret too. Like every pairing body, it is small.
        .route("/auth/refresh", post(refresh).layer(RequestBodyLimitLayer::new(8 * 1024)))
        .route("/auth/logout", post(logout))
        .route("/v1/me", get(me))
        .route("/v1/services", get(services))
        .route("/v1/relay", get(relay_credential))
        .route("/v1/services/{device}/{kind}/{name}", delete(deregister_service))
        // Bound every request so a slow upstream (GitHub) can't pin connections
        // on the unauthenticated /auth/* surface indefinitely.
        .layer(TimeoutLayer::with_status_code(
            StatusCode::REQUEST_TIMEOUT,
            Duration::from_secs(20),
        ))
        .layer(RequestBodyLimitLayer::new(64 * 1024))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

/// API error mapped to an HTTP status + JSON `{ "error": … }`.
enum ApiError {
    Unauthorized,
    BadRequest(&'static str),
    Unavailable(&'static str),
    Internal(String),
    /// A device session's failure, with its stable code.
    Pairing(PairingError),
}

impl From<PairingError> for ApiError {
    fn from(error: PairingError) -> Self {
        Self::Pairing(error)
    }
}

type ApiResult<T> = Result<T, ApiError>;

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            ApiError::Pairing(error) => return no_store(error.into_response()),
            ApiError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
            ApiError::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg),
            ApiError::Unavailable(msg) => (StatusCode::SERVICE_UNAVAILABLE, msg),
            ApiError::Internal(detail) => {
                // Log the detail server-side but never leak raw upstream/store/JWT
                // error strings (which fingerprint the backend) to the client.
                tracing::error!(error = %detail, "internal error");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal error")
            },
        };
        (status, Json(serde_json::json!({ "error": message }))).into_response()
    }
}

fn auth_err(err: AuthError) -> ApiError {
    match err {
        AuthError::BadRefresh | AuthError::BadExchange => ApiError::Unauthorized,
        AuthError::WebDisabled => ApiError::Unavailable("web login is not configured"),
        AuthError::BadRedirect => ApiError::BadRequest("redirect_uri is not allowed"),
        AuthError::BadWebState => ApiError::BadRequest("invalid or expired web login state"),
        other => ApiError::Internal(other.to_string()),
    }
}

fn now() -> i64 {
    time::OffsetDateTime::now_utc().unix_timestamp()
}

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
}

/// Who a request on a route both kinds of session share speaks for.
enum Caller {
    /// A GitHub account: verified statelessly, exactly as it always was.
    GitHub(Claims),
    /// A device, checked against the database on this request: a token alone
    /// would leave old-user access open on every route but `/v1/relay`.
    Device(Arc<Pairing>, Box<DeviceCaller>),
}

async fn authed(state: &AppState, headers: &HeaderMap) -> ApiResult<Caller> {
    let token = bearer(headers).ok_or(ApiError::Unauthorized)?;
    // A pairing client asked, so it gets the code that says to refresh. GitHub
    // clients send no such header, and their answer stays what it always was.
    let claims = state.auth.verify(token).map_err(|_| {
        if pairing::check_protocol(headers).is_ok() {
            ApiError::Pairing(PairingError::code(PairingErrorCode::SessionStale))
        } else {
            ApiError::Unauthorized
        }
    })?;
    if !pairing::is_device_token(&claims) {
        return Ok(Caller::GitHub(claims));
    }
    let Some(service) = state.pairing.clone() else {
        return Err(ApiError::Unauthorized);
    };
    let caller = state
        .auth
        .authenticate_device(&claims, now())
        .await
        .map_err(PairingError::from)?;
    Ok(Caller::Device(service, Box::new(caller)))
}

async fn healthz() -> &'static str {
    "ok"
}

async fn device_start(
    State(state): State<AppState>,
    Json(req): Json<DeviceStartRequest>,
) -> ApiResult<Json<DeviceStartResponse>> {
    let resp = state
        .auth
        .device_start(req.device_label.as_deref(), now())
        .await
        .map_err(auth_err)?;
    Ok(Json(resp))
}

async fn device_poll(
    State(state): State<AppState>,
    Json(req): Json<DevicePollRequest>,
) -> ApiResult<Json<DevicePollResponse>> {
    let resp = state
        .auth
        .device_poll(&req.poll_handle, now())
        .await
        .map_err(auth_err)?;
    Ok(Json(resp))
}

async fn web_start(
    State(state): State<AppState>,
    Json(req): Json<WebStartRequest>,
) -> ApiResult<Json<WebStartResponse>> {
    let resp = state
        .auth
        .web_start(
            &req.redirect_uri,
            &req.state,
            &req.code_challenge,
            req.device_label.as_deref(),
            now(),
        )
        .await
        .map_err(auth_err)?;
    Ok(Json(resp))
}

/// Query params GitHub appends to the backend's OAuth callback. `code` +
/// `state` on success; `error` (+ `state`) when the user denied or GitHub
/// failed.
#[derive(Debug, Deserialize)]
struct WebCallbackQuery {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
}

/// GitHub's redirect lands here. We never return JSON to the browser: on a
/// recognized flow we 302 the browser back to the app (custom scheme /
/// loopback) with the one-time exchange code or an error; on an unknown/expired
/// state (or when the flow is disabled) we render a generic page instead of
/// redirecting somewhere unvalidated.
async fn web_callback(
    State(state): State<AppState>,
    Query(q): Query<WebCallbackQuery>,
) -> Response {
    let gh_state = q.state.unwrap_or_default();
    match state
        .auth
        .web_callback(q.code.as_deref(), &gh_state, q.error.as_deref(), now())
        .await
    {
        Ok(redirect) => Redirect::to(&redirect.location).into_response(),
        Err(AuthError::BadWebState | AuthError::WebDisabled) => web_callback_page(
            "This sign-in link is no longer valid. Return to POCOX and try again.",
        ),
        Err(e) => {
            tracing::error!(error = %e, "web callback failed");
            web_callback_page("Something went wrong signing in. Return to POCOX and try again.")
        },
    }
}

/// A minimal self-contained HTML page shown when the callback can't redirect
/// back into the app (unknown state, disabled flow, or an internal error).
fn web_callback_page(message: &str) -> Response {
    let body = format!(
        "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" \
         content=\"width=device-width, initial-scale=1\"><title>POCOX</title></head><body \
         style=\"font-family: system-ui, sans-serif; max-width: 28rem; margin: 4rem auto; \
         padding: 0 1.5rem; text-align: center; color: #1a1a1a;\"><h1 style=\"font-size: \
         1.25rem;\">POCOX</h1><p>{message}</p></body></html>"
    );
    Html(body).into_response()
}

async fn web_exchange(
    State(state): State<AppState>,
    Json(req): Json<WebExchangeRequest>,
) -> ApiResult<Json<WebExchangeResponse>> {
    let credential = state
        .auth
        .web_exchange(&req.exchange_code, &req.code_verifier, now())
        .await
        .map_err(auth_err)?;
    Ok(Json(WebExchangeResponse {
        credential,
    }))
}

/// `POST /auth/refresh` carries exactly one of a GitHub refresh token and a
/// device secret. Both at once is a mixed principal, not a choice for this
/// route to make.
#[derive(Deserialize)]
struct RefreshBody {
    refresh_token: Option<String>,
    device_secret: Option<String>,
}

async fn refresh(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<RefreshBody>,
) -> ApiResult<Response> {
    match (req.refresh_token, req.device_secret) {
        (Some(refresh_token), None) => {
            let credential = state
                .auth
                .refresh(&refresh_token, now())
                .await
                .map_err(auth_err)?;
            Ok(Json(RefreshResponse {
                credential,
            })
            .into_response())
        },
        (None, Some(device_secret)) => {
            pairing::check_protocol(&headers)?;
            let session = state
                .auth
                .refresh_device(&device_secret, now())
                .await
                .map_err(PairingError::from)?;
            Ok(([(CACHE_CONTROL, "no-store")], Json(session)).into_response())
        },
        _ => Err(ApiError::BadRequest("expected exactly one of refresh_token and device_secret")),
    }
}

async fn logout(
    State(state): State<AppState>,
    Json(req): Json<LogoutRequest>,
) -> ApiResult<StatusCode> {
    state
        .auth
        .logout(&req.refresh_token, now())
        .await
        .map_err(auth_err)?;
    Ok(StatusCode::NO_CONTENT)
}

/// A device's answer on a shared route. These are per-device and can carry a
/// relay credential, so nothing may cache them.
fn no_store(body: impl IntoResponse) -> Response {
    ([(CACHE_CONTROL, "no-store")], body).into_response()
}

async fn me(State(state): State<AppState>, headers: HeaderMap) -> ApiResult<Response> {
    Ok(match authed(&state, &headers).await? {
        Caller::GitHub(claims) => Json(MeResponse {
            account_id: claims.gh_id.map(|id| id.to_string()),
            login: claims.login,
        })
        .into_response(),
        Caller::Device(_, caller) => no_store(Json(MeResponse {
            login: caller.access.device.label,
            account_id: Some(caller.access.user.id),
        })),
    })
}

/// The relay namespace a device's user holds, if it has ever needed one.
fn stored_namespace(caller: &DeviceCaller) -> ApiResult<Option<u64>> {
    caller
        .access
        .user
        .namespace
        .as_deref()
        .map(|namespace| {
            namespace
                .parse()
                .map_err(|_| ApiError::Internal(format!("stored namespace `{namespace}`")))
        })
        .transpose()
}

/// `GET /v1/services` query. ACP services are listed only on
/// request: an older client cannot deserialize a kind it does not know and
/// would fail the whole listing.
#[derive(Default, Deserialize)]
struct ServicesQuery {
    #[serde(default)]
    include_acp: bool,
    #[serde(default)]
    include_opencode: bool,
}

/// Which opt-in kinds a caller asked to see.
#[derive(Clone, Copy, Default)]
struct OptInKinds {
    acp: bool,
    opencode: bool,
}

/// List the caller's own services, as the relay sees them.
///
/// Scoped by the account's relay NAMESPACE first and its key prefix second. The
/// namespace is what actually attributes a registration: a service name is
/// whatever its registrant typed, so another account could register the literal
/// string `pcxu:<this-user>:mac:app:default` inside its own namespace, and a
/// prefix-only filter would show that phantom here. The prefix check stays
/// because it is what parses the key into device/kind/name.
async fn services(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<ServicesQuery>,
) -> ApiResult<Response> {
    let opt_in = OptInKinds {
        acp: query.include_acp,
        opencode: query.include_opencode,
    };
    let claims = match authed(&state, &headers).await? {
        Caller::GitHub(claims) => claims,
        // A retiring session may look too, within its overlap: the same user's view.
        Caller::Device(service, caller) => {
            let _slot = service.enter()?;
            let Some(namespace) = stored_namespace(&caller)? else {
                return Ok(no_store(Json(ServicesResponse::default())));
            };
            let all = service.service_snapshot().await?;
            return Ok(no_store(Json(ServicesResponse {
                services: own_services(&all, namespace, &caller.access.user.id, opt_in),
            })));
        },
    };
    let Some(namespace) = state
        .credentials
        .namespace_of(&claims.sub)
        .await
        .map_err(|e| ApiError::Internal(format!("resolving the account namespace: {e:#}")))?
    else {
        // No credential ever issued, so nothing can have been registered.
        return Ok(Json(ServicesResponse::default()).into_response());
    };
    let all = pocox_pb::all_services(&state.relay)
        .await
        .map_err(|e| ApiError::Internal(format!("relay status: {e}")))?;
    Ok(Json(ServicesResponse {
        services: own_services(&all, namespace, &claims.sub, opt_in),
    })
    .into_response())
}

/// The subset of `all` that belongs to `user_id` in relay `namespace`.
///
/// Factored out of the handler so the attribution rule is testable without a
/// relay — it is the rule that keeps one account's listing from showing
/// another's registrations.
fn own_services(
    all: &[pocox_pb::ServiceRecord],
    namespace: u64,
    user_id: &str,
    opt_in: OptInKinds,
) -> Vec<ServiceEntry> {
    let prefix = NamespacedServiceId::user_prefix(user_id);
    all.iter()
        // BOTH conditions, and the namespace is the load-bearing one: a service
        // name is whatever its registrant typed, so account B can register the
        // literal string `pcxu:<A>:mac:app:default` inside B's own namespace. The
        // prefix alone would attribute that to A.
        .filter(|svc| svc.namespace == namespace && svc.name.starts_with(&prefix))
        .filter_map(|svc| NamespacedServiceId::parse_key(&svc.name))
        // Only surface the kinds clients consume directly. The meta service is a
        // colocated implementation detail (clients derive its key from the app
        // key), and an unrecognised kind must never be sent — an older client
        // can't deserialize a kind it doesn't know and would fail the whole
        // listing, so omit both here.
        .filter(|nsid| match nsid.service.kind {
            ServiceKind::App | ServiceKind::Api => true,
            ServiceKind::Acp => opt_in.acp,
            ServiceKind::OpenCode => opt_in.opencode,
            ServiceKind::Meta | ServiceKind::Host | ServiceKind::Port | ServiceKind::Unknown => false,
        })
        .map(|nsid| ServiceEntry {
            device: nsid.service.device,
            kind: nsid.service.kind,
            name: nsid.service.name,
        })
        .collect()
}

/// Force-deregister one of the caller's own services from the relay. The relay
/// key is derived server-side from the verified user id, so a caller can only
/// ever drop keys in their own `pcxu:<user>:` namespace. Best-effort: a client
/// still hosting the service will reconnect and re-register shortly after.
async fn deregister_service(
    State(state): State<AppState>,
    PeerAddr(peer): PeerAddr,
    headers: HeaderMap,
    Path((device, kind, name)): Path<(String, String, String)>,
) -> ApiResult<Response> {
    let claims = match authed(&state, &headers).await? {
        Caller::GitHub(claims) => claims,
        Caller::Device(service, caller) => {
            pairing::check_protocol(&headers)?;
            let _slot = service.enter()?;
            // A retiring session reads but never deregisters.
            if matches!(caller.mode, SessionMode::Retiring { .. }) {
                return Err(PairingError::code(PairingErrorCode::GraceRestricted).into());
            }
            let kind: ServiceKind = kind
                .parse()
                .map_err(|_| PairingError::code(PairingErrorCode::InvalidRequest))?;
            let relay_key = NamespacedServiceId::new(
                &caller.access.user.id,
                ServiceId::new(&device, kind, &name),
            )
            .key();
            if let Some(namespace) = stored_namespace(&caller)? {
                let bucket = service.client_bucket(peer, &headers);
                service
                    .retire_device_service(&caller.access.device.id, namespace, &relay_key, bucket)
                    .await?;
            }
            return Ok(no_store(StatusCode::NO_CONTENT));
        },
    };
    let kind: ServiceKind = kind
        .parse()
        .map_err(|_| ApiError::BadRequest("invalid service kind"))?;
    let relay_key =
        NamespacedServiceId::new(&claims.sub, ServiceId::new(&device, kind, &name)).key();
    // Asks the RELAY to drop the registration's connections. It used to cancel a
    // broker session that owned the tunnel; with clients registering directly the
    // backend no longer holds anything to cancel, so the authority it does have —
    // its administrator credential — is what retires the key.
    //
    // Both the namespace and the key come from the verified token, so a caller
    // can only ever name a service of their own. Naming the namespace is not
    // optional: the relay reads an absent one as the administrator's, where an
    // account's services never live, so omitting it would retire nothing.
    let Some(namespace) = state
        .credentials
        .namespace_of(&claims.sub)
        .await
        .map_err(|e| ApiError::Internal(format!("resolving the account namespace: {e:#}")))?
    else {
        // No credential, so nothing of this account's is registered. The
        // post-condition the caller wants already holds.
        return Ok(StatusCode::NO_CONTENT.into_response());
    };
    pocox_pb::retire_service(&state.relay, namespace, &relay_key)
        .await
        .map_err(|e| ApiError::Internal(format!("retiring {relay_key}: {e:#}")))?;
    Ok(StatusCode::NO_CONTENT.into_response())
}

/// Hand this account the relay address and a short-lived credential, so the
/// client can register and subscribe against the relay directly.
///
/// This is the endpoint that takes the backend off the data path: everything
/// after it is client↔relay. The credential is per-account (see
/// [`crate::credentials`]) and scoped to the account's namespace by the relay
/// itself, so possession of it grants nothing outside that account.
async fn relay_credential(
    State(state): State<AppState>,
    PeerAddr(peer): PeerAddr,
    headers: HeaderMap,
) -> ApiResult<Response> {
    let claims = match authed(&state, &headers).await? {
        Caller::GitHub(claims) => claims,
        Caller::Device(service, caller) => {
            // An old client can present a device JWT for up to its hour, and a key from
            // a namespace fails every direct session on an older SDK.
            pairing::check_protocol(&headers)?;
            let _slot = service.enter()?;
            let bucket = service.client_bucket(peer, &headers);
            return Ok(no_store(Json(service.relay_credential(caller, bucket).await?)));
        },
    };
    let (credential, expires_at) = state
        .credentials
        .for_account(&claims.sub)
        .await
        .map_err(|e| ApiError::Internal(format!("issuing a relay credential: {e:#}")))?;
    Ok(Json(RelayCredentialResponse {
        relay_addr: state.credentials.relay_addr().to_string(),
        credential,
        expires_at,
        // From the VERIFIED token, never from the request: this is the one place
        // an account's namespace is decided, and a client that asked for another
        // one would still be confined by the credential it gets back.
        namespace: NamespacedServiceId::namespace_of(&claims.sub),
    })
    .into_response())
}

#[cfg(test)]
mod tests {
    use pocox_pb::ServiceRecord;

    use super::*;

    fn record(namespace: u64, name: &str) -> ServiceRecord {
        ServiceRecord {
            namespace,
            name: name.to_string(),
        }
    }

    #[test]
    fn a_listing_is_scoped_by_namespace_not_just_by_key_prefix() {
        // The attack this closes: account B registers a name that LOOKS like one of
        // A's. The relay is right to allow it — B's namespace is B's to fill — so
        // the filter, not the relay, has to refuse to attribute it to A.
        const ALICE_NS: u64 = 11;
        const BOB_NS: u64 = 22;
        let all = vec![
            record(ALICE_NS, "pcxu:alice:mac:app:default"),
            // Bob's namespace, Alice's name. Must NOT appear in Alice's listing.
            record(BOB_NS, "pcxu:alice:mac:app:phantom"),
            record(BOB_NS, "pcxu:bob:studio:app:default"),
        ];

        let alice = own_services(&all, ALICE_NS, "alice", OptInKinds::default());
        assert_eq!(alice.len(), 1, "expected only Alice's own service, got {alice:?}");
        assert_eq!(alice[0].name, "default");

        // And the converse: Alice's namespace does not leak into Bob's listing
        // either, even though one of those names carries his prefix.
        let bob = own_services(&all, BOB_NS, "bob", OptInKinds::default());
        assert_eq!(bob.len(), 1, "expected only Bob's own service, got {bob:?}");
        assert_eq!(bob[0].device, "studio");
    }

    #[test]
    fn a_listing_hides_meta_and_unparsable_keys() {
        const NS: u64 = 7;
        let all = vec![
            record(NS, "pcxu:alice:mac:app:default"),
            record(NS, "pcxu:alice:mac:api:default"),
            // Colocated implementation detail: clients derive it from the app key.
            record(NS, "pcxu:alice:mac:meta:default"),
            // Same namespace, but not one of ours at all.
            record(NS, "some-unrelated-service"),
        ];
        let mut kinds: Vec<String> = own_services(&all, NS, "alice", OptInKinds::default())
            .into_iter()
            .map(|s| s.kind.as_key_segment().to_string())
            .collect();
        kinds.sort();
        assert_eq!(kinds, vec!["api", "app"]);
    }

    #[test]
    fn agent_services_are_independently_opt_in_and_still_namespace_scoped() {
        const ALICE_NS: u64 = 7;
        const BOB_NS: u64 = 8;
        let all = vec![
            record(ALICE_NS, "pcxu:alice:mac:app:default"),
            record(ALICE_NS, "pcxu:alice:mac:acp:agent"),
            record(ALICE_NS, "pcxu:alice:mac:opencode:native"),
            record(ALICE_NS, "pcxu:alice:mac:meta:agent"),
            // Bob's namespace carrying Alice's prefix must never be attributed.
            record(BOB_NS, "pcxu:alice:mac:acp:phantom"),
            record(BOB_NS, "pcxu:alice:mac:opencode:phantom"),
        ];
        let kinds = |opt_in| {
            let mut kinds: Vec<String> = own_services(&all, ALICE_NS, "alice", opt_in)
                .into_iter()
                .map(|s| format!("{}:{}", s.kind.as_key_segment(), s.name))
                .collect();
            kinds.sort();
            kinds
        };
        assert_eq!(kinds(OptInKinds::default()), vec!["app:default"]);
        assert_eq!(
            kinds(OptInKinds {
                acp: true,
                ..OptInKinds::default()
            }),
            vec!["acp:agent", "app:default"]
        );
        assert_eq!(
            kinds(OptInKinds {
                opencode: true,
                ..OptInKinds::default()
            }),
            vec!["app:default", "opencode:native"]
        );
    }
}
