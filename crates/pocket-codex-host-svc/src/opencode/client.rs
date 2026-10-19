//! Native OpenCode operations. Every OpenCode major version implements them
//! once, and this client calls the detected version's implementation through
//! a static `match`.

use pocket_codex_core::provider::Secret;
use serde_json::Value;

use super::{
    catalog::Catalog,
    events::EventStream,
    http::{Http, Native, MAX_BODY},
    public,
    schema::{CommandInput, MessagePage, Prompt, Session, Statuses},
    wire::{dispatch, Dialect, Health, Reply},
};

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
    /// The model or agent selection failed, so the message was never sent.
    #[error("the OpenCode {selection} selection failed; the message was not sent")]
    Preflight {
        /// `model` or `agent`.
        selection: &'static str,
    },
    /// The answer does not fit this OpenCode form.
    #[error(
        "this OpenCode form cannot take that answer here; choose a listed option or reject it"
    )]
    UnsupportedForm,
}

impl ClientError {
    /// Whether the native server certainly did not admit the request.
    pub fn not_sent(&self) -> bool {
        matches!(self, Self::Http(400..=499) | Self::Preflight { .. })
    }
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

/// The authenticated client of one private native server.
#[derive(Clone)]
pub struct Client {
    http: Http<Native>,
    dialect: Dialect,
}

impl Client {
    /// Speak `dialect` to a loopback server, authenticating as its `opencode`
    /// Basic user when `password` is set.
    pub(crate) fn new(
        origin: &str,
        password: Option<Secret>,
        dialect: Dialect,
    ) -> Result<Self, ClientError> {
        Ok(Self {
            http: Http::new(origin, password)?,
            dialect,
        })
    }

    pub(crate) async fn health(&self) -> Result<Health, ClientError> {
        dispatch!(self.dialect, W => W::health(&self.http).await)
    }

    /// Make the server open its database; no session is restored or prompted.
    pub(crate) async fn open_source(&self) -> Result<(), ClientError> {
        dispatch!(self.dialect, W => W::open(&self.http).await)
    }

    /// Bounded session metadata, across every project when `directory` is
    /// absent. This does not load a writer.
    pub async fn sessions(
        &self,
        directory: Option<&str>,
        limit: usize,
    ) -> Result<Vec<Session>, ClientError> {
        dispatch!(self.dialect, W => W::sessions(&self.http, directory, limit).await)
    }

    /// One session's metadata; a missing ID is `Http(404)`.
    pub async fn session(&self, id: &str) -> Result<Session, ClientError> {
        dispatch!(self.dialect, W => W::session(&self.http, id).await)
    }

    /// Create an empty session in `directory`.
    pub async fn create_session(&self, directory: &str) -> Result<Session, ClientError> {
        dispatch!(self.dialect, W => W::create(&self.http, directory).await)
    }

    /// Rename a session.
    pub async fn rename(
        &self,
        id: &str,
        directory: &str,
        title: &str,
    ) -> Result<Session, ClientError> {
        dispatch!(self.dialect, W => W::rename(&self.http, id, directory, title).await)
    }

    /// Execution states this server reports; absent sessions are idle.
    pub async fn statuses(&self, directory: &str) -> Result<Statuses, ClientError> {
        dispatch!(self.dialect, W => W::statuses(&self.http, directory).await)
    }

    /// Models, agents and commands for a project.
    pub async fn catalog(&self, directory: Option<&str>) -> Result<Catalog, ClientError> {
        dispatch!(self.dialect, W => W::catalog(&self.http, directory).await)
    }

    /// Pending permission requests in `directory`.
    pub async fn permissions(&self, directory: &str) -> Result<Vec<Value>, ClientError> {
        dispatch!(self.dialect, W => W::permissions(&self.http, directory).await)
    }

    /// Pending questions in `directory`.
    pub async fn questions(&self, directory: &str) -> Result<Vec<Value>, ClientError> {
        dispatch!(self.dialect, W => W::questions(&self.http, directory).await)
    }

    /// Admit one prompt, once. `select` marks the prompt's model and agent as
    /// changed since the last admitted prompt.
    pub async fn prompt(
        &self,
        session: &str,
        directory: &str,
        prompt: &Prompt,
        select: bool,
    ) -> Result<(), ClientError> {
        dispatch!(self.dialect, W => W::prompt(&self.http, session, directory, prompt, select).await)
    }

    /// Wait for a native command without a turn-length timeout. The owning
    /// host must cancel this future when it shuts down; it is never retried.
    pub async fn command(
        &self,
        session: &str,
        directory: &str,
        command: &CommandInput,
        select: bool,
    ) -> Result<(), ClientError> {
        dispatch!(self.dialect, W => W::command(&self.http, session, directory, command, select).await)
    }

    pub(crate) async fn reply(
        &self,
        session: &str,
        request: &str,
        directory: &str,
        reply: Reply<'_>,
    ) -> Result<(), ClientError> {
        dispatch!(self.dialect, W => W::reply(&self.http, session, request, directory, reply).await)
    }

    /// Interrupt execution; `false` means nothing was running here.
    pub async fn abort(&self, session: &str, directory: &str) -> Result<bool, ClientError> {
        dispatch!(self.dialect, W => W::abort(&self.http, session, directory).await)
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
        let page = dispatch!(self.dialect, W => {
            W::page(&self.http, session, directory, before, limit).await?
        });
        let messages: Vec<_> = page.messages.into_iter().map(public::message).collect();
        if !fits(&messages, MAX_BODY) {
            return Err(ClientError::TooLarge);
        }
        Ok(MessagePage {
            messages,
            next_before: page.next_before,
        })
    }

    /// Open the global native stream. Readiness comes from `server.connected`,
    /// not merely a successful earlier snapshot or health response.
    pub async fn events(&self) -> Result<EventStream, ClientError> {
        self.http
            .event_source(self.dialect.events(), &[], self.dialect)
            .await
    }
}

/// Whether `value` serializes within `limit` bytes, measured without
/// buffering it and stopping at the first byte over.
fn fits(value: &impl serde::Serialize, limit: usize) -> bool {
    struct Budget(usize);
    impl std::io::Write for Budget {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0 = self
                .0
                .checked_sub(bytes.len())
                .ok_or(std::io::ErrorKind::FileTooLarge)?;
            Ok(bytes.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    serde_json::to_writer(Budget(limit), value).is_ok()
}

#[cfg(test)]
#[path = "client_tests.rs"]
mod history_tests;
