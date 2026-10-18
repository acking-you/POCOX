//! Bounded native HTTP requests. Credentials never enter URLs or errors.

use std::time::Duration;

use pocket_codex_core::provider::Secret;
use reqwest::{Method, RequestBuilder, Response};
use serde::de::DeserializeOwned;
use serde_json::Value;
use url::Url;

use super::{
    events::EventStream,
    public,
    schema::{Message, MessagePage},
};

const MAX_BODY: usize = 8 * 1024 * 1024;
// One accepted image prompt can persist 40 MiB of inline images. Read it
// within a separate native-only bound, then remove unavailable previews
// before applying the ordinary public history-window bound.
const MAX_NATIVE_HISTORY_BODY: usize = 48 * 1024 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// A failure talking to the native server, without echoed secrets or URLs.
#[derive(Debug, thiserror::Error)]
pub enum ClientError {
    /// Invalid local endpoint or request path.
    #[error("the OpenCode endpoint or request path is invalid")]
    InvalidEndpoint,
    /// The request could not complete; a mutation's outcome may be uncertain.
    #[error("the OpenCode server request did not complete")]
    Transport,
    /// The local process cannot allocate another file or socket.
    #[error("{}", pocket_codex_core::error::FILE_LIMIT_MESSAGE)]
    FileLimit,
    /// The request exceeded its connection or response budget.
    #[error("the agent request timed out; check the host connection and retry")]
    Timeout,
    /// A native HTTP rejection.
    #[error("the OpenCode server returned HTTP {0}")]
    Http(u16),
    /// A Pocket gateway rejection, retaining its typed code without its body.
    #[error("the OpenCode gateway rejected the request ({code}, HTTP {status})")]
    Gateway {
        /// HTTP status of the gateway rejection.
        status: u16,
        /// Recognized stable gateway failure code.
        code: String,
    },
    /// The server returned unexpected JSON or SSE.
    #[error("the OpenCode server returned an invalid response")]
    InvalidResponse,
    /// The requested data exceeds the transport's memory bound.
    #[error("the OpenCode response exceeds the bounded transfer limit")]
    TooLarge,
    /// An event connection ended and requires fresh reconciliation.
    #[error("the OpenCode event stream ended; reconnect to refresh session state")]
    EventStreamEnded,
}

impl From<reqwest::Error> for ClientError {
    fn from(error: reqwest::Error) -> Self {
        if pocket_codex_core::error::is_file_limit(&error) {
            Self::FileLimit
        } else if error.is_timeout() {
            Self::Timeout
        } else {
            Self::Transport
        }
    }
}

/// A private native server client, or a relay-mapped native gateway client.
#[derive(Clone)]
pub struct Client {
    origin: Url,
    http: reqwest::Client,
    password: Option<Secret>,
    gateway: bool,
}

impl Client {
    /// Connect to an HTTP loopback endpoint. Native authentication uses the
    /// server's `opencode` Basic user and a private password, when configured.
    /// Redirects and environment proxies are disabled.
    pub fn new(origin: &str, password: Option<Secret>) -> Result<Self, ClientError> {
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
            gateway: false,
        })
    }

    pub(super) fn gateway(origin: &str) -> Result<Self, ClientError> {
        let mut client = Self::new(origin, None)?;
        client.gateway = true;
        Ok(client)
    }

    fn request(
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
            // OpenCode accepts the encoded directory through the query as
            // well; unlike an HTTP header it supports every UTF-8 path.
            request = request.query(&[("directory", directory)]);
        }
        Ok(request)
    }

    /// Read one native JSON resource with encoded path segments and query.
    pub async fn get<T: DeserializeOwned>(
        &self,
        path: &[&str],
        directory: Option<&str>,
        query: &[(&str, &str)],
    ) -> Result<T, ClientError> {
        let response = self
            .request(Method::GET, path, directory)?
            .query(query)
            .timeout(REQUEST_TIMEOUT)
            .send()
            .await
            .map_err(ClientError::from)?;
        decode(response, self.gateway).await
    }

    /// Submit one native JSON mutation, once. Network errors are never
    /// automatically retried because acceptance may already have occurred.
    pub async fn mutate<T: DeserializeOwned>(
        &self,
        method: Method,
        path: &[&str],
        directory: Option<&str>,
        body: &impl serde::Serialize,
    ) -> Result<T, ClientError> {
        let response = self
            .request(method, path, directory)?
            .json(body)
            .timeout(REQUEST_TIMEOUT)
            .send()
            .await
            .map_err(ClientError::from)?;
        decode(response, self.gateway).await
    }

    /// Wait for a native command's response without a turn-length timeout.
    /// The owning host must cancel this future when it shuts down. This is
    /// never retried and is not exposed as an arbitrary proxy operation.
    pub async fn command(
        &self,
        session: &str,
        directory: &str,
        body: &Value,
    ) -> Result<Value, ClientError> {
        let response = self
            .request(Method::POST, &["session", session, "command"], Some(directory))?
            .json(body)
            .send()
            .await
            .map_err(ClientError::from)?;
        decode(response, self.gateway).await
    }

    /// Read at most 20 public native messages, keeping the server's opaque
    /// cursor. Oversized pages are read again with fewer messages; a single
    /// oversized public message fails visibly instead of ending history.
    pub async fn messages(
        &self,
        session: &str,
        directory: &str,
        before: Option<&str>,
    ) -> Result<MessagePage, ClientError> {
        let mut limit = 20;
        loop {
            match self.message_page(session, directory, before, limit).await {
                Err(ClientError::TooLarge) if limit > 1 => limit /= 2,
                result => return result,
            }
        }
    }

    async fn message_page(
        &self,
        session: &str,
        directory: &str,
        before: Option<&str>,
        limit: usize,
    ) -> Result<MessagePage, ClientError> {
        let mut request = self
            .request(Method::GET, &["session", session, "message"], Some(directory))?
            .query(&[("limit", limit)]);
        if let Some(before) = before {
            request = request.query(&[("before", before)]);
        }
        let response = request
            .timeout(REQUEST_TIMEOUT)
            .send()
            .await
            .map_err(ClientError::from)?;
        let next_before = response
            .headers()
            .get("x-next-cursor")
            .map(|value| {
                value
                    .to_str()
                    .map(str::to_owned)
                    .map_err(|_| ClientError::InvalidResponse)
            })
            .transpose()?;
        if next_before
            .as_ref()
            .is_some_and(|cursor| cursor.len() > 4096)
        {
            return Err(ClientError::InvalidResponse);
        }
        let messages: Vec<Message> =
            decode_bounded(response, self.gateway, MAX_NATIVE_HISTORY_BODY).await?;
        let messages: Vec<_> = messages.into_iter().map(public::message).collect();
        if serde_json::to_vec(&messages)
            .map_err(|_| ClientError::InvalidResponse)?
            .len()
            > MAX_BODY
        {
            return Err(ClientError::TooLarge);
        }
        Ok(MessagePage {
            messages,
            next_before,
        })
    }

    /// Open the native stream. Readiness comes from `server.connected`, not
    /// merely a successful earlier snapshot or health response.
    pub async fn events(&self, directory: Option<&str>) -> Result<EventStream, ClientError> {
        let path: &[&str] = if directory.is_some() { &["event"] } else { &["global", "event"] };
        self.event_source(path, directory, &[]).await
    }

    pub(super) async fn event_source(
        &self,
        path: &[&str],
        directory: Option<&str>,
        query: &[(&str, &str)],
    ) -> Result<EventStream, ClientError> {
        let response = tokio::time::timeout(
            Duration::from_secs(10),
            self.request(Method::GET, path, directory)?
                .query(query)
                .send(),
        )
        .await
        .map_err(|_| ClientError::Timeout)?
        .map_err(ClientError::from)?;
        success(&response)?;
        if !response
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.starts_with("text/event-stream"))
        {
            return Err(ClientError::InvalidResponse);
        }
        Ok(EventStream::new(response))
    }
}

fn success(response: &Response) -> Result<(), ClientError> {
    if response.status().is_success() {
        Ok(())
    } else {
        Err(ClientError::Http(response.status().as_u16()))
    }
}

async fn decode<T: DeserializeOwned>(response: Response, gateway: bool) -> Result<T, ClientError> {
    decode_bounded(response, gateway, MAX_BODY).await
}

async fn decode_bounded<T: DeserializeOwned>(
    mut response: Response,
    gateway: bool,
    native_limit: usize,
) -> Result<T, ClientError> {
    let rejected = !response.status().is_success();
    if rejected && !gateway {
        return Err(ClientError::Http(response.status().as_u16()));
    }
    let limit = if rejected {
        4096
    } else if gateway {
        32 * 1024 * 1024
    } else {
        native_limit
    };
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
    if rejected {
        let body: Value =
            serde_json::from_slice(&bytes).map_err(|_| ClientError::InvalidResponse)?;
        let code = body["code"]
            .as_str()
            .filter(|code| {
                matches!(
                    *code,
                    "stale_host"
                        | "not_ready"
                        | "read_only"
                        | "busy"
                        | "turn_changed"
                        | "invalid_input"
                        | "capacity"
                        | "session_not_found"
                        | "native_request_failed"
                )
            })
            .ok_or(ClientError::InvalidResponse)?;
        return Err(ClientError::Gateway {
            status: response.status().as_u16(),
            code: code.into(),
        });
    }
    if bytes.is_empty() {
        serde_json::from_value(Value::Null).map_err(|_| ClientError::InvalidResponse)
    } else {
        serde_json::from_slice(&bytes).map_err(|_| ClientError::InvalidResponse)
    }
}

#[cfg(test)]
#[path = "client_tests.rs"]
mod history_tests;

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
            assert!(Client::new(url, None).is_err(), "{url}");
        }
        assert!(Client::new("http://127.0.0.1:4096", None).is_ok());
        assert!(Client::new("http://[::1]:4096/opencode/v1/native", None).is_ok());
    }

    #[test]
    fn opaque_ids_and_utf8_directories_cannot_change_the_request_origin() {
        let client = Client::new("http://127.0.0.1:4096", None).expect("client");
        let request = client
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
