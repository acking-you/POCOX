//! Bounded loopback HTTP shared by the native client and the Pocox gateway.
//! Credentials never enter URLs or errors.

use std::{borrow::Cow, marker::PhantomData, time::Duration};

use pocox_core::provider::Secret;
use reqwest::{Method, RequestBuilder, Response};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::Value;
use url::Url;

use super::{client::ClientError, events::EventStream, wire::Dialect};

pub(super) const MAX_BODY: usize = 8 * 1024 * 1024;
// One accepted image prompt can persist 40 MiB of inline images. Read it
// within a separate native-only bound, then remove unavailable previews
// before applying the ordinary public history-window bound.
pub(super) const MAX_NATIVE_HISTORY_BODY: usize = 48 * 1024 * 1024;
pub(super) const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// How one peer reports a rejected request.
pub(crate) trait Peer {
    /// Bytes read from a rejected response; zero keeps only its status.
    const REJECTION_BODY: usize;

    /// Largest accepted body, given a native read's own bound.
    fn limit(native: usize) -> usize;

    /// Classify a rejection from its status and bounded body.
    fn rejection(status: u16, body: &[u8]) -> ClientError;
}

/// The private `opencode serve` process; its rejections are plain statuses.
pub(crate) enum Native {}

/// The relay-facing Pocox gateway; its rejections carry a stable code.
pub(crate) enum Pocox {}

impl Peer for Native {
    const REJECTION_BODY: usize = 0;

    fn limit(native: usize) -> usize {
        native
    }

    fn rejection(status: u16, _: &[u8]) -> ClientError {
        ClientError::Http(status)
    }
}

impl Peer for Pocox {
    const REJECTION_BODY: usize = 4096;

    fn limit(_: usize) -> usize {
        32 * 1024 * 1024
    }

    fn rejection(status: u16, body: &[u8]) -> ClientError {
        #[derive(Deserialize)]
        struct Rejection<'a> {
            #[serde(borrow)]
            code: Cow<'a, str>,
        }
        match serde_json::from_slice::<Rejection>(body) {
            Ok(Rejection {
                code,
            }) if matches!(
                &*code,
                "stale_host"
                    | "not_ready"
                    | "read_only"
                    | "busy"
                    | "turn_changed"
                    | "invalid_input"
                    | "capacity"
                    | "session_not_found"
                    | "native_request_failed"
            ) =>
            {
                ClientError::Gateway {
                    status,
                    code: code.into_owned(),
                }
            },
            _ => ClientError::InvalidResponse,
        }
    }
}

/// A loopback HTTP origin. The peer type decides how rejections decode.
pub(crate) struct Http<P> {
    origin: Url,
    http: reqwest::Client,
    password: Option<Secret>,
    peer: PhantomData<fn() -> P>,
}

impl<P> Clone for Http<P> {
    fn clone(&self) -> Self {
        Self {
            origin: self.origin.clone(),
            http: self.http.clone(),
            password: self.password.clone(),
            peer: PhantomData,
        }
    }
}

impl<P: Peer> Http<P> {
    /// Connect to an HTTP loopback endpoint. Native authentication uses the
    /// server's `opencode` Basic user and a private password, when configured.
    /// Redirects and environment proxies are disabled.
    pub(crate) fn new(origin: &str, password: Option<Secret>) -> Result<Self, ClientError> {
        let mut origin = Url::parse(origin).map_err(|_| ClientError::InvalidEndpoint)?;
        let local = origin.host_str().is_some_and(|host| {
            host == "localhost"
                || host
                    .trim_matches(['[', ']'])
                    .parse::<std::net::IpAddr>()
                    .is_ok_and(|ip| ip.is_loopback())
        });
        if origin.scheme() != "http"
            || !local
            || !origin.username().is_empty()
            || origin.password().is_some()
            || origin.query().is_some()
            || origin.fragment().is_some()
        {
            return Err(ClientError::InvalidEndpoint);
        }
        if !origin.path().ends_with('/') {
            origin.set_path(&format!("{}/", origin.path()));
        }
        let http = reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(5))
            .build()
            .map_err(ClientError::from)?;
        Ok(Self {
            origin,
            http,
            password,
            peer: PhantomData,
        })
    }

    /// One request with encoded path segments and an optional `directory`
    /// query, which supports every UTF-8 path unlike an HTTP header.
    pub(crate) fn request(
        &self,
        method: Method,
        path: &[&str],
        directory: Option<&str>,
    ) -> Result<RequestBuilder, ClientError> {
        let mut url = self.origin.clone();
        {
            let mut segments = url
                .path_segments_mut()
                .map_err(|_| ClientError::InvalidEndpoint)?;
            segments.pop_if_empty();
            for segment in path {
                if segment.is_empty() || matches!(*segment, "." | "..") {
                    return Err(ClientError::InvalidEndpoint);
                }
                segments.push(segment);
            }
        }
        let mut request = self.http.request(method, url);
        if let Some(password) = &self.password {
            request = request.basic_auth("opencode", Some(password.expose()));
        }
        if let Some(directory) = directory {
            request = request.query(&[("directory", directory)]);
        }
        Ok(request)
    }

    /// Send once and decode within `limit`. Network errors are never retried
    /// because a mutation may already have been accepted.
    pub(crate) async fn call<T: DeserializeOwned>(
        &self,
        request: RequestBuilder,
        limit: usize,
    ) -> Result<T, ClientError> {
        decode::<P, T>(request.send().await.map_err(ClientError::from)?, limit).await
    }

    /// Read one JSON resource.
    pub(crate) async fn get<T: DeserializeOwned>(
        &self,
        path: &[&str],
        directory: Option<&str>,
        query: &[(&str, &str)],
    ) -> Result<T, ClientError> {
        let request = self.request(Method::GET, path, directory)?.query(query);
        self.call(request.timeout(REQUEST_TIMEOUT), MAX_BODY).await
    }

    /// Submit one JSON mutation.
    pub(crate) async fn mutate<T: DeserializeOwned>(
        &self,
        method: Method,
        path: &[&str],
        directory: Option<&str>,
        body: &impl Serialize,
    ) -> Result<T, ClientError> {
        let request = self.request(method, path, directory)?.json(body);
        self.call(request.timeout(REQUEST_TIMEOUT), MAX_BODY).await
    }

    /// Open an SSE stream whose frames `framing` decodes.
    pub(crate) async fn event_source(
        &self,
        path: &[&str],
        query: &[(&str, &str)],
        framing: Dialect,
    ) -> Result<EventStream, ClientError> {
        let response = tokio::time::timeout(
            Duration::from_secs(10),
            self.request(Method::GET, path, None)?.query(query).send(),
        )
        .await
        .map_err(|_| ClientError::Timeout)?
        .map_err(ClientError::from)?;
        if !response.status().is_success() {
            return Err(ClientError::Http(response.status().as_u16()));
        }
        if !response
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.starts_with("text/event-stream"))
        {
            return Err(ClientError::InvalidResponse);
        }
        Ok(EventStream::new(response, framing))
    }
}

/// Decode a response within the peer's bound. An empty success body decodes
/// as JSON `null`, so `()`-like targets accept `204 No Content`.
pub(crate) async fn decode<P: Peer, T: DeserializeOwned>(
    response: Response,
    native_limit: usize,
) -> Result<T, ClientError> {
    let status = response.status();
    if !status.is_success() {
        let body = if P::REJECTION_BODY == 0 {
            Vec::new()
        } else {
            read(response, P::REJECTION_BODY).await?
        };
        return Err(P::rejection(status.as_u16(), &body));
    }
    let bytes = read(response, P::limit(native_limit)).await?;
    if bytes.is_empty() {
        serde_json::from_value(Value::Null).map_err(|_| ClientError::InvalidResponse)
    } else {
        serde_json::from_slice(&bytes).map_err(|_| ClientError::InvalidResponse)
    }
}

async fn read(mut response: Response, limit: usize) -> Result<Vec<u8>, ClientError> {
    if response
        .content_length()
        .is_some_and(|size| size > limit as u64)
    {
        return Err(ClientError::TooLarge);
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(ClientError::from)? {
        if bytes.len().saturating_add(chunk.len()) > limit {
            return Err(ClientError::TooLarge);
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoint_credentials_and_nonlocal_destinations_are_rejected() {
        for url in [
            "https://example.com",
            "http://127.0.0.1:9/?key=x",
            "http://u:p@localhost:9",
            "http://localhost:9/#x",
            "file:///tmp/socket",
        ] {
            assert!(Http::<Native>::new(url, None).is_err(), "{url}");
        }
        assert!(Http::<Native>::new("http://127.0.0.1:4096", None).is_ok());
        assert!(Http::<Pocox>::new("http://[::1]:4096/opencode/v1/native", None).is_ok());
    }

    #[test]
    fn opaque_ids_and_utf8_directories_cannot_change_the_request_origin() {
        let http = Http::<Native>::new("http://127.0.0.1:4096", None).expect("client");
        let request = http
            .request(
                Method::GET,
                &["session", "ses_foo/bar?x", "message"],
                Some("/tmp/中文 project"),
            )
            .expect("request")
            .build()
            .expect("build");
        assert_eq!(request.url().path(), "/session/ses_foo%2Fbar%3Fx/message");
        assert_eq!(request.url().query_pairs().next().expect("directory").1, "/tmp/中文 project");
    }
}
