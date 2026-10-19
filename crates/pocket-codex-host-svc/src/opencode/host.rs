//! Owned native service and original-session admission. Native clients do not
//! honor the Pocket source claim; every mutation checks fresh holder evidence.

use std::{collections::BTreeMap, sync::Arc};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;

use super::{
    catalog::Catalog,
    client::{Client, ClientError},
    fold::Window,
    live::Live,
    ownership::{Evidence, Role, Source},
    public,
    runtime::Server,
    schema::{Session, Status},
};
use crate::session_access::{AccessHolder, SessionAccess};

mod operations;
mod retention;
pub use operations::{Answer, Input, Options};

/// Host identity which must accompany every controller mutation.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Identity {
    /// Random identity of this owned host incarnation.
    pub host_id: String,
    /// Engine generation in this incarnation.
    pub generation: u64,
    /// Canonical database identity observed at startup.
    pub source_generation: String,
}

/// Stable native gateway failures, with no native credentials or raw errors.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// The controller acted on an obsolete host/source.
    #[error("OpenCode host or history source changed; reconnect")]
    Stale,
    /// Stream readiness was lost or the host was stopped.
    #[error("OpenCode is reconnecting or stopped")]
    NotReady,
    /// Positive writer admission is unavailable.
    #[error("This original session is currently available for viewing only")]
    ReadOnly,
    /// A running turn prevents a new turn or release.
    #[error("This OpenCode session already has a running or unconfirmed turn")]
    Busy,
    /// The requested running turn is no longer current.
    #[error("The OpenCode turn changed; refresh before trying again")]
    TurnChanged,
    /// Input does not match supported public native controls.
    #[error("The OpenCode input or selected option is invalid")]
    InvalidInput,
    /// Bounded host resources are already in use.
    #[error("The OpenCode host has reached its session limit")]
    Capacity,
    /// The native session metadata route confirmed that the original ID is
    /// gone.
    #[error("The native OpenCode session no longer exists")]
    SessionNotFound,
    /// The native request failed; mutations are not retried.
    #[error(transparent)]
    Native(#[from] ClientError),
}

impl Error {
    /// Stable machine-readable error code.
    pub fn code(&self) -> &'static str {
        match self {
            Self::Stale => "stale_host",
            Self::NotReady => "not_ready",
            Self::ReadOnly => "read_only",
            Self::Busy => "busy",
            Self::TurnChanged => "turn_changed",
            Self::InvalidInput => "invalid_input",
            Self::Capacity => "capacity",
            Self::SessionNotFound => "session_not_found",
            Self::Native(_) => "native_request_failed",
        }
    }
}

#[derive(Default)]
struct Entry {
    directory: String,
    last_used: Option<std::time::Instant>,
    options: Options,
    options_pending: bool,
    released: bool,
    turn: Option<String>,
    dispatched: u64,
    operation_error: Option<String>,
}

struct Inner {
    identity: Identity,
    version: String,
    client: Client,
    source: Source,
    server: Mutex<Server>,
    live: Live,
    sessions: Mutex<BTreeMap<String, Entry>>,
    mutation: Mutex<()>,
    stop: CancellationToken,
}

impl Drop for Inner {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}

/// A native host survives controller disconnects; only explicit host shutdown
/// stops its owned server. It never attaches to or terminates another client.
#[derive(Clone)]
pub struct Host(Arc<Inner>);

/// Public host identity and executable version, without private addresses.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Info {
    /// Gateway wire version, independent of the executable version.
    pub api: u32,
    /// Native engine protocol identifier.
    pub protocol: String,
    /// Mutation identity.
    #[serde(flatten)]
    pub identity: Identity,
    /// Native external executable version.
    pub version: String,
}

/// A read answer bound to one host and native database incarnation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadResult<T> {
    /// Exact host/source which produced this data.
    pub identity: Identity,
    /// Sanitized native data.
    pub data: T,
}

/// One session's current conversation and controls.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    /// Persisted original session metadata.
    pub session: Session,
    /// Fresh provider-specific admission evidence.
    pub access: SessionAccess,
    /// Bounded native history with retained live text.
    pub window: Window,
    /// Native permission requests still pending in this project/session.
    pub permissions: Vec<Value>,
    /// Native questions still pending in this project/session.
    pub questions: Vec<Value>,
    /// Host's selections for the next message.
    pub options: Options,
    /// Stable current turn correlation ID, if active.
    pub turn_id: Option<String>,
    /// A detached operation's safe failure description, when present.
    pub operation_error: Option<String>,
}

impl Host {
    /// Begin observing an already started owned, or attached, native server
    /// before exposing any mutation routes. Failure drops and stops only an
    /// owned server.
    pub async fn new(server: Server) -> anyhow::Result<Self> {
        let mut source =
            Source::new(server.detection.database.clone(), server.pid, server.started)?;
        if let Some(service) = server.service() {
            source = source.attached(service.address());
        }
        let live = Live::start(server.client.clone()).await?;
        Ok(Self(Arc::new(Inner {
            identity: Identity {
                host_id: uuid::Uuid::new_v4().to_string(),
                generation: 1,
                source_generation: source.generation().into(),
            },
            version: server.detection.version.clone(),
            client: server.client.clone(),
            source,
            server: Mutex::new(server),
            live,
            sessions: Mutex::new(BTreeMap::new()),
            mutation: Mutex::new(()),
            stop: CancellationToken::new(),
        })))
    }

    /// Public identity and version for a controller handshake.
    pub fn info(&self) -> Info {
        Info {
            api: 1,
            protocol: "opencode-http".into(),
            identity: self.0.identity.clone(),
            version: self.0.version.clone(),
        }
    }

    /// Host-owned invalidations, shared by all controllers.
    pub fn live(&self) -> &Live {
        &self.0.live
    }

    pub(crate) fn is_stopped(&self) -> bool {
        self.0.stop.is_cancelled()
    }

    pub(crate) async fn stopped(&self) {
        self.0.stop.cancelled().await;
    }

    /// Stop only the server owned by this host, retaining its claim on an
    /// unconfirmed process exit. Shutdown serializes with every mutation.
    pub async fn stop(&self) -> anyhow::Result<()> {
        let _guard = self.0.mutation.lock().await;
        self.0.stop.cancel();
        self.0.live.stop().await;
        self.0.server.lock().await.stop().await
    }

    fn identity(&self, expected: &Identity) -> Result<(), Error> {
        if &self.0.identity != expected {
            return Err(Error::Stale);
        }
        if self.0.stop.is_cancelled() {
            return Err(Error::NotReady);
        }
        Ok(())
    }

    async fn writable_source(&self, expected: &Identity) -> Result<(), Error> {
        self.identity(expected)?;
        if !self.0.live.connected().await {
            return Err(Error::NotReady);
        }
        if self.0.source.inspect().await != Evidence::Clear {
            return Err(Error::ReadOnly);
        }
        Ok(())
    }

    /// Read bounded native session metadata; this does not load a writer.
    pub async fn sessions(&self, directory: Option<&str>) -> Result<Vec<Session>, Error> {
        Ok(self.0.client.sessions(directory, 100).await?)
    }

    /// Fresh native status for every project this gateway admitted, including
    /// native child sessions. Outside database holders make this inventory
    /// unknown; controller window eviction cannot hide an owned active turn.
    pub async fn running(&self) -> Result<Vec<String>, Error> {
        self.writable_source(&self.0.identity).await?;
        let directories: std::collections::BTreeSet<_> = self
            .0
            .sessions
            .lock()
            .await
            .values()
            .map(|entry| entry.directory.clone())
            .filter(|dir| !dir.is_empty())
            .collect();
        let mut running = std::collections::BTreeSet::new();
        for directory in directories {
            let statuses = self.0.client.statuses(&directory).await?;
            let entries: Vec<_> = self
                .0
                .sessions
                .lock()
                .await
                .iter()
                .filter(|(_, entry)| entry.directory == directory)
                .map(|(id, _)| id.clone())
                .collect();
            for id in entries {
                self.observe_idle(&id, statuses.get(&id).unwrap_or(&Status::Idle))
                    .await;
            }
            for (id, status) in statuses {
                if matches!(status, Status::Unknown) {
                    return Err(Error::NotReady);
                }
                if status.running() {
                    running.insert(id);
                }
            }
        }
        // A dispatch with no confirmed result remains active even when the
        // native server has not published its positive busy transition yet.
        running.extend(
            self.0
                .sessions
                .lock()
                .await
                .iter()
                .filter(|(_, entry)| entry.turn.is_some())
                .map(|(id, _)| id.clone()),
        );
        self.writable_source(&self.0.identity).await?;
        Ok(running.into_iter().collect())
    }

    async fn session(&self, session: &str) -> Result<Session, Error> {
        if session.is_empty() || session.len() > 256 {
            return Err(Error::InvalidInput);
        }
        self.0
            .client
            .session(session)
            .await
            .map_err(|error| match error {
                ClientError::Http(404) => Error::SessionNotFound,
                error => Error::Native(error),
            })
    }

    /// Real native model, agent and command inventory for a selected project.
    pub async fn catalog(&self, directory: Option<&str>) -> Result<Catalog, Error> {
        Ok(self.0.client.catalog(directory).await?)
    }

    async fn status(&self, session: &Session) -> Result<Status, Error> {
        let statuses = self.0.client.statuses(&session.directory).await?;
        let status = statuses.get(&session.id).cloned().unwrap_or(Status::Idle);
        self.observe_idle(&session.id, &status).await;
        Ok(status)
    }

    async fn observe_idle(&self, session: &str, status: &Status) {
        if matches!(status, Status::Idle) {
            let transition = self.0.live.status(session).await;
            if let Some(entry) = self.0.sessions.lock().await.get_mut(session) {
                if entry.turn.is_some()
                    && transition.is_some_and(|(seq, status, busy)| {
                        busy > entry.dispatched && seq > busy && matches!(status, Status::Idle)
                    })
                {
                    entry.turn = None;
                }
            }
        }
    }

    /// Inspect access without resuming, aborting or signaling any writer.
    pub async fn access(&self, session: &str) -> Result<SessionAccess, Error> {
        let session = self.session(session).await?;
        self.access_to(&session).await
    }

    async fn access_to(&self, session: &Session) -> Result<SessionAccess, Error> {
        let id = &self.0.identity;
        let mut access =
            SessionAccess::unknown(&session.id, &id.host_id, id.generation, "opencode");
        access.source_generation = Some(id.source_generation.clone());
        if self.0.stop.is_cancelled() {
            access.reason = "host_stopped".into();
            return Ok(access);
        }
        if !self.0.live.connected().await {
            access.reason = "transition".into();
            return Ok(access);
        }
        match self.0.source.inspect().await {
            Evidence::External(holders) if holders.iter().all(|h| h.role == Role::Client) => {
                // Clients of the attached background server: it reports the
                // session's turn, never which sessions a client shows.
                let status = self.status(session).await?;
                if matches!(status, Status::Unknown) {
                    return Ok(access);
                }
                // A turn this host dispatched is not the client's.
                let ours = self
                    .0
                    .sessions
                    .lock()
                    .await
                    .get(&session.id)
                    .is_some_and(|entry| entry.turn.is_some());
                let theirs = status.running() && !ours;
                access.turn = if status.running() || ours { "running" } else { "idle" }.into();
                access.writer = "native_client".into();
                access.reason =
                    if theirs { "external_running" } else { "external_source_open" }.into();
                access.holder = holders.first().map(|holder| AccessHolder {
                    client: if theirs { "opencode" } else { "opencode_client" }.into(),
                    pid: Some(holder.pid),
                    started_at: i64::try_from(holder.started_at).ok(),
                    host_name: None,
                    service_key: None,
                });
            },
            Evidence::External(holders) => {
                access.reason = "external_source_open".into();
                access.writer = "native_client".into();
                // Name OpenCode 2's background server when it is one of them:
                // it outlives the client that started it.
                let holder = holders
                    .iter()
                    .find(|holder| holder.role == Role::BackgroundServer)
                    .or(holders.first());
                access.holder = holder.map(|holder| AccessHolder {
                    client: if holder.role == Role::BackgroundServer {
                        "opencode_service"
                    } else {
                        "unknown"
                    }
                    .into(),
                    pid: Some(holder.pid),
                    started_at: i64::try_from(holder.started_at).ok(),
                    host_name: None,
                    service_key: None,
                });
            },
            Evidence::Unknown => {
                access.detail = Some(
                    "Cannot verify the native database holders. Check that the source is \
                     unchanged and the host has a working lsof executable."
                        .into(),
                );
            },
            Evidence::Clear => {
                let status = self.status(session).await?;
                let entries = self.0.sessions.lock().await;
                let entry = entries.get(&session.id);
                if matches!(status, Status::Unknown) {
                    return Ok(access);
                }
                let running = status.running() || entry.is_some_and(|entry| entry.turn.is_some());
                access.turn = if running { "running" } else { "idle" }.into();
                access.exclusion = "pocket".into();
                if entry.is_some_and(|entry| entry.released) {
                    access.reason = "released_here".into();
                    access.writer = "none".into();
                } else if entry.is_none() {
                    // Cache eviction never grants write admission. A controller
                    // must explicitly reopen the original ID, as after release.
                    access.reason = "not_opened".into();
                    access.writer = "none".into();
                } else {
                    access.mode = "write".into();
                    access.writer = "this_host".into();
                    access.reason = "owned".into();
                    access.can_release = !running;
                }
            },
        }
        Ok(access)
    }

    /// Open the exact native ID automatically when fresh evidence permits it.
    /// Follow-only opens never mutate the native server or outside clients.
    pub async fn open(&self, session: &str, expected: &Identity) -> Result<Snapshot, Error> {
        let _guard = self.0.mutation.lock().await;
        self.identity(expected)?;
        let metadata = self.session(session).await?;
        if self.writable_source(expected).await.is_ok() {
            let page = self
                .0
                .client
                .messages(session, &metadata.directory, None)
                .await?;
            self.reserve_session_slot(Some(session)).await?;
            let mut entries = self.0.sessions.lock().await;
            let entry = entries.entry(session.into()).or_insert_with(|| Entry {
                options: Options::restore(&page.messages),
                ..Entry::default()
            });
            if !entry.options_pending && entry.turn.is_none() {
                entry.options = Options::restore(&page.messages);
            }
            entry.last_used = Some(std::time::Instant::now());
            entry.directory = metadata.directory.clone();
            entry.released = false;
        }
        self.snapshot(session, None).await
    }

    /// Read original history and still-pending requests with a bounded live
    /// overlay. Failed reads are never reported as authoritative empty history.
    pub async fn snapshot(&self, session: &str, before: Option<&str>) -> Result<Snapshot, Error> {
        let session = self.session(session).await?;
        // Turn state first, so the history read after it is at least as new:
        // an ended turn is never paired with history from before its end,
        // which 2.x, without a live overlay, would report as the outcome.
        let access = self.access_to(&session).await?;
        let (page, permissions, questions) = tokio::try_join!(
            self.0
                .client
                .messages(&session.id, &session.directory, before),
            self.0.client.permissions(&session.directory),
            self.0.client.questions(&session.directory),
        )?;
        let window = self
            .0
            .live
            .window(&session.id, page, before.is_none())
            .await;
        let mut entries = self.0.sessions.lock().await;
        let entry = entries.get_mut(&session.id);
        let (options, turn_id, operation_error) = if let Some(entry) = entry {
            if access.turn == "running" && entry.turn.is_none() {
                entry.turn = window
                    .messages
                    .iter()
                    .rev()
                    .find(|m| m.info["role"] == "user")
                    .and_then(|m| m.info["id"].as_str())
                    .map(str::to_owned);
            }
            (entry.options.clone(), entry.turn.clone(), entry.operation_error.clone())
        } else {
            (Options::restore(&window.messages), None, None)
        };
        let pending = |items: Vec<Value>, question| {
            items
                .iter()
                .filter(|item| item["sessionID"] == session.id)
                .map(|item| public::pending(item, question))
                .collect()
        };
        Ok(Snapshot {
            permissions: pending(permissions, false),
            questions: pending(questions, true),
            session,
            access,
            window,
            options,
            turn_id,
            operation_error,
        })
    }
}

#[async_trait::async_trait]
impl crate::file_links::SessionDirResolver for Host {
    async fn session_dir(&self, session: &str) -> anyhow::Result<Option<String>> {
        match self.session(session).await {
            Ok(session) if std::path::Path::new(&session.directory).is_absolute() => {
                Ok(Some(session.directory))
            },
            Ok(_) => anyhow::bail!("OpenCode session has no absolute project directory"),
            Err(Error::SessionNotFound) => Ok(None),
            Err(error) => Err(error.into()),
        }
    }
}
