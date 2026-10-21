//! The host-owned ACP client for one agent.
//!
//! ```text
//!        one lifecycle lock: start | stop | restart | exit handling
//! launch ──► negotiating ──► ready ──► gone (connection closed, or leader
//!               │                        │  exited while a descendant holds
//!          stop cuts it short            │  its output; seen unreaped)
//!               ▼                        ▼ watcher reports its generation
//!           teardown ◄──── supervisor: teardown unless done, bounded relaunch
//!
//! teardown: invalidate generation (end turns truthfully, withdraw
//!           permissions) → close writer → brief output drain
//!           → signal process group → reap leader
//! ```
//!
//! [`AgentHost`] owns the agent process for its whole life: whoever holds
//! the lifecycle lock and takes the running process performs the teardown.
//! [`AgentHost::stop`] is final and bounded and never waits for a slow
//! handshake. The leader is detected without being reaped, so its group is
//! still signalled safely. Launching never waits on the supervisor, so
//! launch, exit handling and relaunch never recurse.
//!
//! # Turns
//!
//! Turns are admitted under the state lock and acknowledged immediately; a
//! separate task dispatches `session/prompt` and awaits the answer. Every
//! prompt dispatch and every `session/cancel` of this host is written under
//! one *dispatch lane*, and each re-checks under it which turn is running.
//! `session/cancel` names only a session, so this is what keeps a cancel
//! meant for turn A from reaching a turn B: if A ended and B was admitted
//! meanwhile, either the cancel is queued before B's prompt (and the agent
//! sees it while nothing runs) or it sees that A is gone and is not sent. A
//! turn cancelled before dispatch is never sent.
//!
//! Every write is bounded. A prompt's dispatch budget starts when the turn
//! is admitted and covers waiting for the lane, for queue room and for the
//! complete write (see `peer`'s delivery rules); only a prompt the agent has
//! received in full then waits — without limit — for its answer. A cancel's
//! or permission answer's control budget likewise starts before the lane and
//! covers every reply it sends. A prompt that was never queued fails without
//! touching the connection. A control exchange that cannot complete in time
//! has already consumed what it answers (a permission request, a running
//! turn's withdrawn requests), so it closes the generation instead of
//! leaving the agent waiting on a live connection: the supervisor tears the
//! generation down (ending its turns truthfully) and restarts within the
//! restart budget. A retry then sees that the turn or request is gone.
//!
//! # Identity
//!
//! A mutation may carry the [`Identity`] (host incarnation and agent
//! generation) its caller acted on; when either changed, it is refused before
//! any side effect. A replacement host behind the same relay key restarts its
//! generations and may even see the same session ids.
//!
//! # Sessions
//!
//! Reopening a session is provisional until the agent confirms it: the
//! session accepts no prompt and grants no new file authority meanwhile, and
//! a failed reopen is revoked. A session's persisted working directory always
//! wins over what the agent lists later. Only [`MAX_TRANSCRIPTS`] sessions
//! hold a transcript; when all of them are running or reopening, another
//! session is refused instead of exceeding the pool.
//!
//! Admissions and titles are persisted off the event path: they are queued,
//! coalesced per session, under the state lock — so their order matches the
//! state's — and one worker writes them.
//!
//! [`MAX_TRANSCRIPTS`]: super::state::MAX_TRANSCRIPTS

use std::{
    collections::{HashMap, VecDeque},
    ffi::OsString,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, MutexGuard, Weak},
    time::Duration,
};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::{
    sync::{broadcast, mpsc, oneshot, watch},
    task::JoinHandle,
    time::Instant,
};

use super::{
    fold::{session_signal, SessionSignal},
    jsonrpc::{RequestId, RpcError},
    peer::{CallError, CloseReason, Inbound, Peer},
    schema::{self, AgentCapabilities, SessionSettings, TurnOutcome},
    spec::AgentSpec,
    state::{ActiveTurn, LogEntry, Permission, Phase, RequestKind, State, MAX_PERMISSIONS},
    store::{Change, Pending, SessionStore},
};
use crate::process::{self, AgentProcess};

mod grok;
pub(crate) use self::grok::grok_permission_option;
mod handoff;
mod inbound;
mod lifecycle;
mod native_history;
mod persist;
mod sessions;
mod steer;
mod turns;

use self::{
    inbound::AgentInbound,
    persist::{Apply, Persist},
};

const INIT_TIMEOUT: Duration = Duration::from_secs(20);
const SESSION_TIMEOUT: Duration = Duration::from_secs(60);
const LOAD_TIMEOUT: Duration = Duration::from_secs(120);
const CONFIG_TIMEOUT: Duration = Duration::from_secs(30);
const LIST_TIMEOUT: Duration = Duration::from_secs(30);
const CLOSE_TIMEOUT: Duration = Duration::from_secs(10);
/// Budget for delivering a prompt: the lane, queue room and the write.
const DISPATCH_TIMEOUT: Duration = Duration::from_secs(30);
/// Budget for a cancel or a permission answer: the lane (for a cancel),
/// queue room and every write.
const CONTROL_TIMEOUT: Duration = Duration::from_secs(10);
/// Longest wait for the agent's answer to a delivered supplement.
const STEER_ANSWER_TIMEOUT: Duration = Duration::from_secs(30);

/// The delivery budgets (see the module docs); tests shorten them.
#[derive(Debug, Clone, Copy)]
struct Budgets {
    dispatch: Duration,
    control: Duration,
    /// How long a delivered supplement waits for the agent's answer.
    answer: Duration,
}

impl Default for Budgets {
    fn default() -> Self {
        Self {
            dispatch: DISPATCH_TIMEOUT,
            control: CONTROL_TIMEOUT,
            answer: STEER_ANSWER_TIMEOUT,
        }
    }
}
/// Budget for pending session-record writes when stopping.
const FLUSH_GRACE: Duration = Duration::from_secs(2);
const WRITER_GRACE: Duration = Duration::from_secs(1);
const OUTPUT_GRACE: Duration = Duration::from_secs(2);
const TERM_GRACE: Duration = Duration::from_millis(300);
const RESTART_DELAY: Duration = Duration::from_secs(2);
const RESTART_WINDOW: Duration = Duration::from_secs(600);
const MAX_RESTARTS: usize = 3;
/// How often a running generation checks whether its leader exited.
const EXIT_POLL: Duration = Duration::from_millis(200);
/// Largest prompt text.
pub const MAX_PROMPT_TEXT: usize = 1024 * 1024;
/// Most images per prompt.
pub const MAX_PROMPT_IMAGES: usize = 16;
/// Largest image data URL.
pub const MAX_IMAGE_BYTES: usize = 8 * 1024 * 1024;
const MAX_ID: usize = 1024;
const DEFAULT_WINDOW_TURNS: usize = 20;
const MAX_WINDOW_TURNS: usize = 100;

/// Retained events followed by the live receiver from the same log snapshot.
pub type EventSubscription = (Vec<Arc<LogEntry>>, broadcast::Receiver<Arc<LogEntry>>);

/// A failed host operation. Messages are safe to show: they never contain
/// agent arguments or stderr.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum HostError {
    /// The agent is not running (or the caller's generation is gone).
    #[error("the agent is not running")]
    NotReady,
    /// The caller acted on another host incarnation or agent generation.
    #[error("the agent host changed; refresh and try again")]
    Stale,
    /// The session is not known to this host.
    #[error("unknown session")]
    UnknownSession,
    /// Browsing native history does not acquire another session's writer.
    #[error("native history is read-only; explicitly acquire the session before sending")]
    ReadOnly,
    /// Another cooperative POCOX host retains the original session claim.
    #[error("another POCOX host owns this original session")]
    PocoxOwned,
    /// A turn is running in the session.
    #[error("a turn is already running in this session")]
    Busy,
    /// The turn a supplement was meant for is not the one running (it
    /// ended, is ending, has not reached the agent yet, or another one
    /// runs); nothing was sent.
    #[error("the turn changed before the message reached it; nothing was sent")]
    TurnChanged,
    /// The session is still being reopened.
    #[error("the session is still loading")]
    Loading,
    /// Every retained transcript belongs to a running or reopening session.
    #[error("too many sessions are busy on this agent host; wait for one to finish")]
    Capacity,
    /// The permission handle is unknown.
    #[error("unknown permission request")]
    UnknownPermission,
    /// The permission was already answered, withdrawn or cancelled.
    #[error("this permission request was already resolved")]
    AlreadyResolved,
    /// The option is not one the request offered; the request stays pending.
    #[error("that option was not offered for this request")]
    InvalidOption,
    /// Malformed input.
    #[error("invalid request: {0}")]
    InvalidInput(String),
    /// The agent does not support what was asked.
    #[error("{0}")]
    Unsupported(String),
    /// The agent answered with ACP `auth_required`.
    #[error("the agent requires authentication; sign in with the agent on the host")]
    AuthRequired,
    /// The agent supports neither `session/load` nor `session/resume`.
    #[error("this agent cannot reopen earlier sessions")]
    NotReopenable,
    /// The agent rejected the request.
    #[error("the agent rejected the request: {0}")]
    Agent(String),
    /// No answer in time.
    #[error("the agent did not answer in time")]
    Timeout,
    /// Too much pending work.
    #[error("too many pending operations")]
    Limit,
    /// The agent could not be started.
    #[error("{0}")]
    Start(String),
}

impl HostError {
    /// Stable machine-readable code.
    pub fn code(&self) -> &'static str {
        match self {
            Self::NotReady => "not_ready",
            Self::Stale => "stale_host",
            Self::UnknownSession => "unknown_session",
            Self::ReadOnly => "native_read_only",
            Self::PocoxOwned => "pocox_host",
            Self::Busy => "busy",
            Self::TurnChanged => "turn_changed",
            Self::Loading => "loading",
            Self::Capacity => "capacity",
            Self::UnknownPermission => "unknown_permission",
            Self::AlreadyResolved => "already_resolved",
            Self::InvalidOption => "invalid_option",
            Self::InvalidInput(_) => "invalid_input",
            Self::Unsupported(_) => "unsupported",
            Self::AuthRequired => "auth_required",
            Self::NotReopenable => "not_reopenable",
            Self::Agent(_) => "agent_error",
            Self::Timeout => "timeout",
            Self::Limit => "limit",
            Self::Start(_) => "start_failed",
        }
    }
}

/// The host incarnation and agent generation a caller acted on (see the
/// module docs). An absent field is not checked.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Identity {
    /// [`AgentHost::host_id`] the caller saw.
    #[serde(default)]
    pub host_id: Option<String>,
    /// The agent generation the caller saw.
    #[serde(default)]
    pub generation: Option<u64>,
}

fn clip(text: &str, limit: usize) -> String {
    text.chars().take(limit).collect()
}

/// What to host.
pub struct HostOptions {
    /// Agent profile and command line.
    pub spec: AgentSpec,
    /// Resolved executable.
    pub program: PathBuf,
    /// `PATH` for the child only, when it must differ from the inherited one.
    pub path: Option<OsString>,
    /// Extra environment for the owned child.
    pub env: Vec<(OsString, OsString)>,
    /// Inherited variables removed from the owned child's environment
    /// before `env` applies (credentials an instance provider replaces).
    pub env_remove: Vec<String>,
    /// Admitted-session record of this agent source.
    pub store: SessionStore,
}

struct Running {
    generation: u64,
    peer: Peer,
    process: AgentProcess,
    watcher: JoinHandle<()>,
}

struct Inner {
    host_id: String,
    spec: AgentSpec,
    program: PathBuf,
    /// Arguments launched instead of `spec.args` (see
    /// [`AgentHost::create_launching`]).
    launch_args: Option<Vec<String>>,
    /// `_meta` merged into every session creation and reopen request (see
    /// [`AgentHost::create_configured`]). May hold a secret: never logged.
    session_meta: Option<serde_json::Map<String, Value>>,
    /// MCP servers for each session, for an agent that accepts HTTP ones.
    session_mcp: Mutex<Option<Arc<dyn crate::acp::SessionMcp>>>,
    path: Option<OsString>,
    env: Vec<(OsString, OsString)>,
    env_remove: Vec<String>,
    store: Arc<SessionStore>,
    native_history: Option<crate::native_history::NativeHistory>,
    persist: Persist,
    state: Mutex<State>,
    lifecycle: tokio::sync::Mutex<Option<Running>>,
    /// Separate from replay state and dropped after the process owner. A
    /// normal teardown retains these claims until native exit is verified.
    native_claims: Mutex<HashMap<String, handoff::HeldClaim>>,
    /// Explicit release suppresses background automatic admission.
    released_here: Mutex<HashMap<String, std::time::Instant>>,
    /// Orders every prompt dispatch and `session/cancel` (see the module
    /// docs).
    dispatch: tokio::sync::Mutex<()>,
    /// Orders configuration exchanges and idle-session release.
    session_control: tokio::sync::Mutex<()>,
    /// Set once by [`AgentHost::stop`]: no launch starts or completes after.
    stopping: watch::Sender<bool>,
    restarts: Mutex<VecDeque<std::time::Instant>>,
    budgets: Mutex<Budgets>,
    /// Generations that ended on their own, and why, for the supervisor. At
    /// most one message per launched generation, so the channel stays small.
    closed: mpsc::UnboundedSender<(u64, &'static str)>,
    /// Test hook: where a cancel waits between its last check and its write.
    #[cfg(test)]
    cancel_pause: Mutex<Option<Pause>>,
}

/// "Reached" and "resume" barriers of a test pause.
#[cfg(test)]
type Pause = (Arc<tokio::sync::Barrier>, Arc<tokio::sync::Barrier>);

/// One hosted ACP agent.
#[derive(Clone)]
pub struct AgentHost {
    inner: Arc<Inner>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poison| poison.into_inner())
}

fn valid_id(id: &str) -> Result<(), HostError> {
    if id.is_empty() || id.len() > MAX_ID {
        return Err(HostError::InvalidInput("invalid id".into()));
    }
    Ok(())
}

/// An existing directory, as an absolute canonical UTF-8 path.
async fn validate_cwd(cwd: &str) -> Result<String, HostError> {
    let path = Path::new(cwd);
    if !path.is_absolute() {
        return Err(HostError::InvalidInput(
            "the working directory must be an absolute path".into(),
        ));
    }
    let real = tokio::fs::canonicalize(path)
        .await
        .map_err(|_| HostError::InvalidInput("the working directory does not exist".into()))?;
    if !tokio::fs::metadata(&real)
        .await
        .is_ok_and(|meta| meta.is_dir())
    {
        return Err(HostError::InvalidInput("the working directory is not a folder".into()));
    }
    real.to_str()
        .map(str::to_string)
        .ok_or_else(|| HostError::InvalidInput("the working directory is not valid UTF-8".into()))
}

impl AgentHost {
    fn state(&self) -> MutexGuard<'_, State> {
        lock(&self.inner.state)
    }

    /// The agent profile.
    pub fn spec(&self) -> &AgentSpec {
        &self.inner.spec
    }

    /// This host's incarnation: a fresh id for every [`AgentHost::create`],
    /// so a controller never mistakes a replacement host (whose
    /// generations and sequence numbers start over) for the one it knew.
    pub fn host_id(&self) -> &str {
        &self.inner.host_id
    }

    fn stopping(&self) -> bool {
        *self.inner.stopping.borrow()
    }

    fn budgets(&self) -> Budgets {
        *lock(&self.inner.budgets)
    }

    /// Deliver a control frame's outcome: an exchange that did not complete
    /// closes the generation (see the module docs).
    fn control_outcome(
        &self,
        generation: u64,
        peer: &Peer,
        delivered: Result<(), CallError>,
    ) -> Result<(), HostError> {
        delivered.map_err(|error| {
            if error != CallError::Closed {
                peer.abandon();
            }
            self.call_error(generation, error)
        })
    }

    /// Whether a caller that saw `expected` acted on this host in
    /// `generation`.
    fn is_current(&self, expected: Option<&Identity>, generation: u64) -> bool {
        expected.is_none_or(|expected| {
            expected
                .host_id
                .as_deref()
                .is_none_or(|host| host == self.inner.host_id)
                && expected.generation.is_none_or(|g| g == generation)
        })
    }

    /// The running generation's connection, if `expected` still holds.
    fn ready_for(
        &self,
        expected: Option<&Identity>,
    ) -> Result<(u64, Peer, AgentCapabilities), HostError> {
        let ready = self.ready()?;
        if !self.is_current(expected, ready.0) {
            return Err(HostError::Stale);
        }
        Ok(ready)
    }

    /// Wait up to `limit` until every session-record write submitted so far
    /// is applied. `false` when it did not finish in time.
    pub async fn flush_store(&self, limit: Duration) -> bool {
        self.inner.persist.flush(limit).await
    }

    /// The running generation's connection. A closed connection is not
    /// ready, even before the supervisor has torn its generation down.
    fn ready(&self) -> Result<(u64, Peer, AgentCapabilities), HostError> {
        let state = self.state();
        match (&state.phase, &state.peer, &state.negotiated) {
            (Phase::Ready, Some(peer), Some(negotiated)) if !peer.is_closed() => {
                Ok((state.generation, peer.clone(), negotiated.capabilities.clone()))
            },
            _ => Err(HostError::NotReady),
        }
    }

    /// The agent signalled ACP `auth_required` in `generation`.
    fn note_auth_required(&self, generation: u64) {
        let mut state = self.state();
        if state.generation == generation && !state.auth_required {
            state.auth_required = true;
            state.host_event();
        }
    }

    fn call_error(&self, generation: u64, error: CallError) -> HostError {
        match error {
            CallError::Rpc(error) if error.code == RpcError::AUTH_REQUIRED => {
                self.note_auth_required(generation);
                HostError::AuthRequired
            },
            CallError::Rpc(error) => HostError::Agent(clip(&error.message, 300)),
            CallError::Closed => HostError::NotReady,
            CallError::Timeout => HostError::Timeout,
            CallError::Busy => HostError::Limit,
            CallError::TooLarge => HostError::InvalidInput("the message is too large".into()),
        }
    }

    /// Public description: incarnation, phase, profile, negotiated agent
    /// and features.
    pub fn info(&self) -> Value {
        self.info_with_state(&self.state())
    }

    /// Atomic snapshot plus sequence watermark.
    pub fn snapshot(&self) -> Value {
        let state = self.state();
        state.snapshot(self.info_with_state(&state))
    }

    fn info_with_state(&self, state: &State) -> Value {
        let mut info = info_of(&self.inner.host_id, &self.inner.spec, state);
        info["nativeHistory"] = json!(self.inner.native_history.is_some());
        info
    }

    /// Events after `after` in `generation`, and a receiver for later ones;
    /// `None` when the caller must resynchronize from a new snapshot.
    pub fn subscribe(&self, generation: u64, after: u64) -> Option<EventSubscription> {
        let state = self.state();
        if state.generation != generation {
            return None;
        }
        let backlog = state.log.since(after)?;
        Some((backlog, state.log.subscribe()))
    }
}

fn info_of(host_id: &str, spec: &AgentSpec, state: &State) -> Value {
    let negotiated = state.negotiated.as_ref();
    json!({
        "api": 1,
        "hostId": host_id,
        "hostingSupported": process::hosting_supported(),
        "generation": state.generation,
        "phase": state.phase,
        "authRequired": state.auth_required,
        "profile": {"id": spec.profile_id, "displayName": spec.display_name},
        "protocolVersion": negotiated.map(|n| n.protocol_version),
        "agent": negotiated.map(|n| &n.agent),
        "capabilities": negotiated.map(|n| &n.capabilities),
        "authMethods": negotiated.map(|n| &n.auth_methods),
        "commands": negotiated.map(|n| &n.commands),
    })
}

#[cfg(all(test, unix))]
mod grok_tests;
#[cfg(all(test, unix))]
mod tests;
