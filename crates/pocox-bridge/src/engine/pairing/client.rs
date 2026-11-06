//! HTTP to the pairing routes.
//!
//! Follows no redirect: a device secret is sent as a bearer value and in JSON
//! bodies, and a 307 would carry those bodies to wherever it points. Every
//! request names the pairing protocol, and no request or response body is ever
//! logged.

use std::path::Path;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use pocox_account_proto::pairing::{
    DeviceRefreshRequest, DeviceSession, OperationView, PairDeviceRequest, PairingErrorBody,
    PAIRING_PROTOCOL_HEADER, PAIRING_PROTOCOL_VERSION,
};
use pocox_core::pairing::CanonicalBackend;
use reqwest::redirect::Policy;
use reqwest::{Method, RequestBuilder, Response, StatusCode};
use serde::de::DeserializeOwned;

use super::error::PairingError;
use crate::engine::network;

/// Longer than the backend's own bounds on its slowest answer, which is a 202.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(45);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

/// A connection to one backend's pairing routes.
#[derive(Clone)]
pub(crate) struct Client {
    http: reqwest::Client,
    base: String,
}

impl Client {
    /// A client for `backend`, through this installation's proxy setting.
    pub(crate) fn new(support: &Path, backend: &CanonicalBackend) -> Result<Self> {
        let http = network::client(support)?
            .redirect(Policy::none())
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(REQUEST_TIMEOUT)
            .build()
            .context("building the pairing HTTP client")?;
        Ok(Self {
            http,
            base: backend.as_str().to_string(),
        })
    }

    /// A request to `path`, naming the pairing protocol.
    pub(crate) fn request(&self, method: Method, path: &str) -> RequestBuilder {
        self.http
            .request(method, format!("{}{path}", self.base))
            .header(PAIRING_PROTOCOL_HEADER, PAIRING_PROTOCOL_VERSION.to_string())
    }

    /// `request`, once the backend accepted it.
    pub(crate) async fn accepted(&self, request: RequestBuilder, what: &str) -> Result<Response> {
        let response = request
            .send()
            .await
            .map_err(reqwest::Error::without_url)
            .with_context(|| format!("calling {what}"))?;
        accepted(response, what).await
    }

    /// `request`'s JSON answer.
    pub(crate) async fn json<T: DeserializeOwned>(
        &self,
        request: RequestBuilder,
        what: &str,
    ) -> Result<T> {
        self.accepted(request, what)
            .await?
            .json()
            .await
            .map_err(reqwest::Error::without_url)
            .with_context(|| format!("parsing the answer to {what}"))
    }

    /// A session for `secret`, which the backend already knows.
    pub(crate) async fn refresh(&self, secret: &str) -> Result<DeviceSession> {
        self.json(
            self.request(Method::POST, "/auth/refresh")
                .json(&DeviceRefreshRequest {
                    device_secret: secret.to_string(),
                }),
            "/auth/refresh",
        )
        .await
    }

    /// Create the inactive device `secret` proves, or read its session again.
    pub(crate) async fn create(
        &self,
        secret: &str,
        label: &str,
        platform: Option<String>,
    ) -> Result<DeviceSession> {
        self.json(
            self.request(Method::POST, "/v1/pair/device")
                .json(&PairDeviceRequest {
                    device_secret: secret.to_string(),
                    label: label.to_string(),
                    platform,
                }),
            "/v1/pair/device",
        )
        .await
    }

    /// Read an operation's result. Takes the secret itself as the bearer value,
    /// because the JWT may already be dead by then.
    pub(crate) async fn read_operation(&self, secret: &str, id: &str) -> Result<OperationView> {
        self.json(
            self.request(Method::GET, &format!("/v1/pair/operations/{id}"))
                .bearer_auth(secret),
            "/v1/pair/operations",
        )
        .await
    }
}

/// `response`, or the backend's refusal as a [`PairingError`].
pub(crate) async fn accepted(response: Response, what: &str) -> Result<Response> {
    let status = response.status();
    if status.is_success() {
        return Ok(response);
    }
    if status.is_redirection() {
        bail!("the backend tried to redirect {what}; nothing was sent on");
    }
    let retry_header = response
        .headers()
        .get(reqwest::header::RETRY_AFTER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse().ok());
    match response.json::<PairingErrorBody>().await {
        Ok(body) => Err(PairingError::from_body(status.as_u16(), body, retry_header).into()),
        Err(_) if matches!(status, StatusCode::NOT_FOUND | StatusCode::METHOD_NOT_ALLOWED) => {
            Err(PairingError::without_pairing(status.as_u16()).into())
        },
        Err(_) => bail!("{what} failed: HTTP {status}"),
    }
}
