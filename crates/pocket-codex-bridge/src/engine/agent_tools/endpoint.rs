//! The loopback endpoint: the MCP server at `/mcp` and the CLI's surface at
//! `/local/v1`.
//!
//! It listens on 127.0.0.1 only, refuses anything a browser could send (an
//! `Origin` header, or a `Host` that is not this loopback address, against DNS
//! rebinding) and requires a bearer token on every request but `hello`, with
//! which the CLI first checks that the listener is the POCOX process that
//! announced it (a fixed port could be taken by another program, even another
//! user's, while POCOX is not running). The MCP server is stateless, so a
//! harness keeps working across POCOX restarts, and refuses every call while
//! the user has switched the tools off.

use std::{net::SocketAddr, path::Path, sync::Arc};

use anyhow::{Context, Result};
use axum::{
    extract::{DefaultBodyLimit, Query, Request},
    http::{header, HeaderValue, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Extension, Json, Router,
};
use pocket_codex_core::history_sync::digest_bytes;
use rmcp::transport::streamable_http_server::{
    session::never::NeverSessionManager, StreamableHttpServerConfig, StreamableHttpService,
};
use serde::{Deserialize, Serialize};

pub use super::model::{APP_PORT, CLI_PORT};
use super::{
    catalog, connections,
    connections::ConnectRequest,
    mcp::Tools,
    model::PROTOCOL,
    routes::failure,
    shares::{self, Caller, ShareRequest},
    state,
    tokens::{Kind, Principal},
};

/// Where a running endpoint says it is, for the local CLI.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Discovery {
    /// [`PROTOCOL`].
    pub protocol: u32,
    /// `http://127.0.0.1:<port>`.
    pub url: String,
    /// The serving process.
    pub pid: u32,
    /// What this process proves it knows through `hello`; private like the
    /// file (and the user's token beside it).
    pub secret: String,
}

const DISCOVERY: &str = "endpoint.json";

/// A fresh random secret (128 bits from two v4 UUIDs, hex).
pub fn new_secret() -> String {
    format!("{}{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple())
}

/// The answer to `challenge` from a process that knows `secret`.
pub fn proof(secret: &str, challenge: &str) -> String {
    digest_bytes(format!("{secret}\n{challenge}").as_bytes())
}

/// Write the discovery file for this process.
pub fn announce(dir: &Path, url: &str, secret: &str) -> Result<()> {
    let discovery = Discovery {
        protocol: PROTOCOL,
        url: url.to_string(),
        pid: std::process::id(),
        secret: secret.to_string(),
    };
    crate::engine::host_profiles::files::write_private(
        &dir.join(DISCOVERY),
        &serde_json::to_vec(&discovery)?,
    )?;
    Ok(())
}

/// Remove the discovery file if this process wrote it.
pub fn withdraw(dir: &Path) {
    if read_discovery(dir).is_some_and(|d| d.pid == std::process::id()) {
        let _ = std::fs::remove_file(dir.join(DISCOVERY));
    }
}

/// The endpoint a POCOX process announced in `dir`.
pub fn read_discovery(dir: &Path) -> Option<Discovery> {
    std::fs::read(dir.join(DISCOVERY))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .filter(|d: &Discovery| d.protocol == PROTOCOL)
}

/// Bind the saved port, else the preferred one or one near it, else any.
pub fn bind(saved: Option<u16>, preferred: u16) -> Result<std::net::TcpListener> {
    let candidates = saved
        .into_iter()
        .chain(preferred..preferred.saturating_add(40))
        .chain(std::iter::once(0));
    for port in candidates {
        if let Ok(listener) = std::net::TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], port)))
        {
            listener
                .set_nonblocking(true)
                .context("setting the agent tools listener non-blocking")?;
            return Ok(listener);
        }
    }
    anyhow::bail!("no loopback port is free for the agent tools")
}

fn loopback_host(value: Option<&HeaderValue>, port: u16) -> bool {
    let Some(host) = value.and_then(|v| v.to_str().ok()) else { return false };
    [format!("127.0.0.1:{port}"), format!("localhost:{port}"), format!("[::1]:{port}")]
        .iter()
        .any(|allowed| host.eq_ignore_ascii_case(allowed))
}

async fn guard(port: u16, mut request: Request, next: Next) -> Response {
    let headers = request.headers();
    if headers.contains_key(header::ORIGIN) || !loopback_host(headers.get(header::HOST), port) {
        return StatusCode::FORBIDDEN.into_response();
    }
    // Proving who listens needs no token: the CLI asks before it sends one.
    if request.uri().path() == HELLO {
        return next.run(request).await;
    }
    // The switch governs agents only: the user's own surface stays up.
    if request.uri().path().starts_with("/mcp") && !state::lock().settings.enabled {
        return failure(super::error::ToolError::Off);
    }
    let principal = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| {
            v.strip_prefix("Bearer ")
                .or_else(|| v.strip_prefix("bearer "))
        })
        .and_then(|token| state::lock().tokens.authenticate(token));
    let Some(principal) = principal else {
        return (StatusCode::UNAUTHORIZED, [(header::WWW_AUTHENTICATE, "Bearer realm=\"pocox\"")])
            .into_response();
    };
    request.extensions_mut().insert(principal);
    next.run(request).await
}

/// Only the user's own token may use the local surface.
fn user(principal: &Principal) -> Option<Caller> {
    (principal.kind == Kind::User).then(|| Caller {
        principal: principal.clone(),
        conversation: None,
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShareBody {
    ports: Vec<u16>,
    title: Option<String>,
    path: Option<String>,
    wait_ready_seconds: Option<u64>,
    #[serde(default)]
    secure: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TargetBody {
    target: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AnswerBody {
    device: String,
    id: String,
    decision: super::model::Decision,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TokenBody {
    harness: String,
    label: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConnectBody {
    service: String,
    local_port: Option<u16>,
}

fn forbidden() -> Response {
    (StatusCode::FORBIDDEN, Json(serde_json::json!({"code": "user_only"}))).into_response()
}

const HELLO: &str = "/local/v1/hello";

#[derive(Deserialize)]
struct Hello {
    challenge: String,
}

fn local_routes(secret: Arc<str>) -> Router {
    Router::new()
        .route(
            HELLO,
            get(move |Query(hello): Query<Hello>| async move {
                if hello.challenge.is_empty() || hello.challenge.len() > 128 {
                    return StatusCode::BAD_REQUEST.into_response();
                }
                Json(serde_json::json!({"proof": proof(&secret, &hello.challenge)}))
                    .into_response()
            }),
        )
        .route(
            "/local/v1/status",
            get(|Extension(principal): Extension<Principal>| async move {
                if user(&principal).is_none() {
                    return forbidden();
                }
                Json(super::status()).into_response()
            }),
        )
        .route(
            "/local/v1/overview",
            get(|Extension(principal): Extension<Principal>| async move {
                if user(&principal).is_none() {
                    return forbidden();
                }
                match tokio::task::spawn_blocking(catalog::overview_blocking).await {
                    Ok(Ok(overview)) => Json(overview).into_response(),
                    Ok(Err(error)) => {
                        failure(super::error::ToolError::Relay(format!("{error:#}")))
                    },
                    Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
                }
            }),
        )
        .route(
            "/local/v1/share",
            post(|Extension(principal): Extension<Principal>, Json(body): Json<ShareBody>| async move {
                let Some(caller) = user(&principal) else { return forbidden() };
                let request = ShareRequest {
                    ports: body.ports,
                    title: body.title,
                    path: body.path,
                    wait_ready_seconds: body.wait_ready_seconds,
                    secure: body.secure,
                    epoch: None,
                };
                match shares::share(&caller, request).await {
                    Ok(Ok(shared)) => Json(shared).into_response(),
                    Ok(Err(pending)) => (
                        StatusCode::ACCEPTED,
                        Json(serde_json::json!({
                            "status": pending.status(), "message": pending.message(),
                        })),
                    )
                        .into_response(),
                    Err(error) => failure(error),
                }
            }),
        )
        .route(
            "/local/v1/stop",
            post(|Extension(principal): Extension<Principal>, Json(body): Json<TargetBody>| async move {
                let Some(caller) = user(&principal) else { return forbidden() };
                match shares::stop(Some(&caller), &body.target) {
                    Ok(share) => Json(share).into_response(),
                    Err(error) => failure(error),
                }
            }),
        )
        .route(
            "/local/v1/connect",
            post(|Extension(principal): Extension<Principal>, Json(body): Json<ConnectBody>| async move {
                let Some(caller) = user(&principal) else { return forbidden() };
                let request = ConnectRequest {
                    service: body.service,
                    local_port: body.local_port,
                };
                match connections::connect(&caller, request).await {
                    Ok(Ok(view)) => Json(view).into_response(),
                    Ok(Err(pending)) => (
                        StatusCode::ACCEPTED,
                        Json(serde_json::json!({
                            "status": pending.status(), "message": pending.message(),
                        })),
                    )
                        .into_response(),
                    Err(error) => failure(error),
                }
            }),
        )
        .route(
            "/local/v1/answer",
            post(|Extension(principal): Extension<Principal>, Json(body): Json<AnswerBody>| async move {
                if user(&principal).is_none() {
                    return forbidden();
                }
                let answered = tokio::task::spawn_blocking(move || {
                    super::answer_on(&body.device, &body.id, body.decision)
                })
                .await;
                match answered {
                    Ok(Ok(())) => Json(serde_json::json!({})).into_response(),
                    Ok(Err(error)) => failure(super::error::ToolError::NotFound(format!("{error:#}"))),
                    Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
                }
            }),
        )
        .route(
            "/local/v1/tokens",
            post(|Extension(principal): Extension<Principal>, Json(body): Json<TokenBody>| async move {
                if user(&principal).is_none() {
                    return forbidden();
                }
                match super::issue(&body.harness, body.label.as_deref()) {
                    Ok(issued) => Json(issued).into_response(),
                    Err(error) => failure(super::error::ToolError::Invalid(format!("{error:#}"))),
                }
            }),
        )
        .route(
            "/local/v1/disconnect",
            post(|Extension(principal): Extension<Principal>, Json(body): Json<TargetBody>| async move {
                let Some(caller) = user(&principal) else { return forbidden() };
                match connections::disconnect(Some(&caller), &body.target) {
                    Ok(view) => Json(view).into_response(),
                    Err(error) => failure(error),
                }
            }),
        )
}

/// The endpoint's routes for a listener on `port`, proving `secret` (the one
/// announced beside it) to the CLI.
pub fn router(port: u16, cancel: tokio_util::sync::CancellationToken, secret: Arc<str>) -> Router {
    let config = StreamableHttpServerConfig::default()
        .with_legacy_session_mode(false)
        .with_json_response(true)
        .enforce_origin_validation()
        .with_cancellation_token(cancel);
    let mcp =
        StreamableHttpService::new(|| Ok(Tools), Arc::new(NeverSessionManager::default()), config);
    local_routes(secret)
        .route_service("/mcp", mcp)
        .layer(DefaultBodyLimit::max(256 * 1024))
        .layer(middleware::from_fn(move |request: Request, next: Next| guard(port, request, next)))
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn rpc(
        client: &reqwest::Client,
        url: &str,
        token: Option<&str>,
        body: serde_json::Value,
    ) -> reqwest::Response {
        let mut request = client
            .post(url)
            .header("accept", "application/json, text/event-stream")
            .header("mcp-protocol-version", "2025-06-18")
            .json(&body);
        if let Some(token) = token {
            request = request.bearer_auth(token);
        }
        request.send().await.expect("response")
    }

    #[tokio::test]
    async fn harnesses_reach_the_tools_only_with_a_token_and_never_from_a_browser() {
        let (_, token) = state::lock()
            .tokens
            .mint(Kind::Installed, "Test harness", Some("test"), None)
            .expect("token");
        let listener = bind(None, 0).expect("bind");
        let port = listener.local_addr().expect("addr").port();
        let app = router(port, tokio_util::sync::CancellationToken::new(), Arc::from("s3cret"));
        let listener = tokio::net::TcpListener::from_std(listener).expect("listener");
        let server = tokio::spawn(async move { axum::serve(listener, app).await });
        let client = reqwest::Client::builder()
            .no_proxy()
            .build()
            .expect("client");
        let url = format!("http://127.0.0.1:{port}/mcp");
        let initialize = serde_json::json!({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                       "clientInfo": {"name": "test", "version": "1"}},
        });

        let anonymous = rpc(&client, &url, None, initialize.clone()).await;
        assert_eq!(anonymous.status(), StatusCode::UNAUTHORIZED);
        let browser = client
            .post(&url)
            .header("origin", "https://evil.example")
            .bearer_auth(&token)
            .json(&initialize)
            .send()
            .await
            .expect("response");
        assert_eq!(browser.status(), StatusCode::FORBIDDEN);
        // The local surface is the user's: an agent's token reads nothing.
        let status = client
            .get(format!("http://127.0.0.1:{port}/local/v1/status"))
            .bearer_auth(&token)
            .send()
            .await
            .expect("response");
        assert_eq!(status.status(), StatusCode::FORBIDDEN);
        let hello: serde_json::Value = client
            .get(format!("http://127.0.0.1:{port}{HELLO}?challenge=c1"))
            .send()
            .await
            .expect("response")
            .json()
            .await
            .expect("json");
        assert_eq!(hello["proof"], proof("s3cret", "c1"));

        let started: serde_json::Value = rpc(&client, &url, Some(&token), initialize)
            .await
            .json()
            .await
            .expect("json");
        assert_eq!(started["result"]["serverInfo"]["name"], "pocox");
        let listed: serde_json::Value = rpc(
            &client,
            &url,
            Some(&token),
            serde_json::json!({
                "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {},
            }),
        )
        .await
        .json()
        .await
        .expect("json");
        let names: Vec<&str> = listed["result"]["tools"]
            .as_array()
            .expect("tools")
            .iter()
            .filter_map(|tool| tool["name"].as_str())
            .collect();
        assert_eq!(names, ["services", "connect"]);
        // An action the request itself rules out answers as a tool error the
        // model can read, not as a protocol failure.
        let called: serde_json::Value = rpc(
            &client,
            &url,
            Some(&token),
            serde_json::json!({
                "jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": {"name": "connect", "arguments": {"action": "launch"}},
            }),
        )
        .await
        .json()
        .await
        .expect("json");
        assert_eq!(called["result"]["isError"], true);
        assert_eq!(called["result"]["structuredContent"]["code"], "invalid_request");
        server.abort();
    }

    #[test]
    fn only_this_loopback_authority_is_accepted() {
        let value = |s: &str| HeaderValue::from_str(s).expect("header");
        assert!(loopback_host(Some(&value("127.0.0.1:17863")), 17863));
        assert!(loopback_host(Some(&value("localhost:17863")), 17863));
        assert!(!loopback_host(Some(&value("evil.example:17863")), 17863));
        assert!(!loopback_host(Some(&value("127.0.0.1:80")), 17863));
        assert!(!loopback_host(None, 17863));
    }
}
