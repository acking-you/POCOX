//! The host owner's record of shares, consent requests and connections.
//!
//! One lock guards it; nothing awaits while holding it. Every change moves
//! the revision, which wakes the catalog's event streams.

use std::{
    collections::HashSet,
    net::SocketAddr,
    path::PathBuf,
    sync::{Arc, Mutex, MutexGuard},
};

use once_cell::sync::Lazy;
use pocox_pb::Published;
use serde::{Deserialize, Serialize};
use tokio::sync::{watch, Notify};

use super::{
    builtin::{CONNECT, SHARE},
    error::ToolError,
    model::{
        ConnectionView, ConsentView, Decision, HostedView, OwnerKind, OwnerView, PortStatus,
        PortView, ShareView,
    },
    settings::Settings,
    shares::Caller,
    tokens::Tokens,
};

/// Who keeps something alive: a token, and the conversation it named.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct OwnerKey {
    /// Token id.
    pub token: String,
    /// Conversation, when the caller named one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation: Option<String>,
}

/// A gated built-in tool the user picked in the composer for one
/// conversation of a hosted instance: its agents use it without asking, as
/// if the user had answered Allow in this conversation.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Granted {
    /// The hosted instance.
    pub host: String,
    /// The conversation; `None` for an instance whose harness names none
    /// (native OpenCode), where the instance is the owner.
    pub conversation: Option<String>,
    /// The built-in tool's id.
    pub tool: String,
}

/// One shared port and its registration.
pub struct SharedPort {
    /// Port number on this device.
    pub port: u16,
    /// Bare relay key.
    pub key: String,
    /// The loopback address that answered (`127.0.0.1` or `[::1]`).
    pub addr: SocketAddr,
    /// The registration, once published.
    pub published: Option<Published>,
    /// The transport epoch it was published in.
    pub epoch: u64,
    /// The last local check found a listener.
    pub reachable: bool,
    /// A publication is in flight (only one at a time).
    pub publishing: bool,
    /// Its share call finished: a user's port is saved only once published,
    /// so a failed share never reaches the file.
    pub confirmed: bool,
    /// The relay refused the last registration.
    pub refused: bool,
    /// No new publication before this (Unix milliseconds).
    pub retry_at_ms: i64,
}

impl SharedPort {
    /// A port reserved for publication.
    pub fn new(port: u16, key: String, addr: SocketAddr, reachable: bool) -> Self {
        Self {
            port,
            key,
            addr,
            published: None,
            epoch: 0,
            reachable,
            publishing: false,
            confirmed: true,
            refused: false,
            retry_at_ms: 0,
        }
    }

    fn status(&self) -> PortStatus {
        if self.published.as_ref().is_some_and(|p| p.is_live()) {
            return if self.reachable { PortStatus::Online } else { PortStatus::Unreachable };
        }
        if self.refused {
            PortStatus::Refused
        } else {
            PortStatus::Starting
        }
    }
}

/// One share.
pub struct Share {
    /// Stable id.
    pub id: String,
    /// Title.
    pub title: String,
    /// Path to open.
    pub path: String,
    /// The page is served over TLS.
    pub secure: bool,
    /// Recorded owner.
    pub owner: OwnerView,
    /// Who keeps it alive; `None` once the user kept it.
    pub key: Option<OwnerKey>,
    /// Unix milliseconds.
    pub created_ms: i64,
    /// When it ends on its own.
    pub expires_ms: Option<i64>,
    /// Its ports.
    pub ports: Vec<SharedPort>,
}

impl Share {
    /// The catalog view.
    pub fn view(&self) -> ShareView {
        ShareView {
            id: self.id.clone(),
            title: self.title.clone(),
            path: self.path.clone(),
            secure: self.secure,
            ports: self
                .ports
                .iter()
                .map(|port| PortView {
                    port: port.port,
                    key: port.key.clone(),
                    status: port.status(),
                })
                .collect(),
            owner: self.owner.clone(),
            created_ms: self.created_ms,
            expires_ms: self.expires_ms,
        }
    }

    /// Whether it survives a restart: kept shares and the user's own. An
    /// agent's share ends with the process that served its tools.
    pub fn durable(&self) -> bool {
        (self.key.is_none() || self.owner.kind == OwnerKind::User)
            && self.ports.iter().any(|port| port.confirmed)
    }

    /// The saved form.
    pub fn saved(&self) -> SavedShare {
        SavedShare {
            id: self.id.clone(),
            title: self.title.clone(),
            path: self.path.clone(),
            secure: self.secure,
            owner: self.owner.clone(),
            created_ms: self.created_ms,
            expires_ms: self.expires_ms,
            ports: self
                .ports
                .iter()
                .filter(|port| port.confirmed)
                .map(|port| port.port)
                .collect(),
        }
    }
}

/// A share as saved across restarts.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedShare {
    /// Stable id.
    pub id: String,
    /// Title.
    pub title: String,
    /// Path to open.
    pub path: String,
    /// The page is served over TLS.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub secure: bool,
    /// Recorded owner.
    pub owner: OwnerView,
    /// Unix milliseconds.
    pub created_ms: i64,
    /// When it ends on its own.
    pub expires_ms: Option<i64>,
    /// Its ports.
    pub ports: Vec<u16>,
}

/// A share or connection waiting for the user.
pub struct Consent {
    /// What controllers show.
    pub view: ConsentView,
    /// Whose request it is.
    pub key: OwnerKey,
    /// The user's answer, once given.
    pub decision: Option<Decision>,
    /// Wakes the calls waiting for the answer.
    pub answered: Arc<Notify>,
}

impl Consent {
    /// The capability it asks for ([`SHARE`] or [`CONNECT`]).
    pub fn tool(&self) -> &'static str {
        if self.view.service.is_some() {
            CONNECT
        } else {
            SHARE
        }
    }
}

/// A service of another device reachable here.
pub struct Connection {
    /// The remote service's bare key.
    pub service: String,
    /// The runtime registry key of its tunnel.
    pub registry_key: String,
    /// `127.0.0.1:<port>`.
    pub local: String,
    /// Whether it got the service's own port number.
    pub same_port: bool,
    /// Recorded owner: who made it, or the user once they took it over.
    pub owner: OwnerView,
    /// The agents that keep it alive, each until its own lease ends. It ends
    /// with the last of them, unless it is the user's.
    pub holders: Vec<(OwnerKey, i64)>,
    /// The user's own: kept until the user ends it.
    pub user: bool,
}

impl Connection {
    /// The view the tools and the app show.
    pub fn view(&self) -> ConnectionView {
        ConnectionView {
            service: self.service.clone(),
            local: self.local.clone(),
            same_port: self.same_port,
            owner: self.owner.clone(),
            expires_ms: if self.user {
                None
            } else {
                self.holders.iter().map(|(_, until)| *until).max()
            },
        }
    }

    /// Whether `owner` keeps it alive.
    pub fn held_by(&self, owner: &OwnerKey) -> bool {
        self.holders.iter().any(|(key, _)| key == owner)
    }

    /// Whether nothing keeps it alive any more.
    pub fn abandoned(&self) -> bool {
        !self.user && self.holders.is_empty()
    }
}

/// Everything the host owner tracks.
#[derive(Default)]
pub struct State {
    /// The saved switch.
    pub settings: Settings,
    /// Issued tokens.
    pub tokens: Tokens,
    /// Private directory for tokens and saved shares.
    pub dir: Option<PathBuf>,
    /// This process serves the tools.
    pub hosting: bool,
    /// The endpoint's URL while it serves.
    pub endpoint: Option<String>,
    /// Why the endpoint is not serving, safe to show.
    pub problem: Option<String>,
    /// The saved settings could not be read: the tools stay off until they
    /// can.
    pub settings_unreadable: bool,
    /// The last save of the shares failed; the supervisor tries again.
    pub shares_unsaved: bool,
    /// The saved shares could not be read or set aside: never overwritten,
    /// so nothing that changes them can be saved this run.
    pub shares_blocked: bool,
    /// Shares of this device.
    pub shares: Vec<Share>,
    /// Requests waiting for the user.
    pub consents: Vec<Consent>,
    /// Owners the user let use a capability ([`SHARE`] or [`CONNECT`])
    /// without asking again.
    pub allowed: HashSet<(OwnerKey, &'static str)>,
    /// Gated built-in tools the user handed conversations from the composer.
    pub granted: HashSet<Granted>,
    /// Owners recently declined a capability, and until when they are not
    /// asked again for it.
    pub declined: Vec<(OwnerKey, &'static str, i64)>,
    /// Connections of this device.
    pub connections: Vec<Connection>,
    /// Agent hosts and APIs this process serves, as last read.
    pub services: Vec<HostedView>,
    /// Moves with every change.
    pub revision: u64,
}

static STATE: Lazy<Mutex<State>> = Lazy::new(Mutex::default);
static CHANGES: Lazy<watch::Sender<u64>> = Lazy::new(|| watch::channel(0).0);

/// The state, locked.
pub fn lock() -> MutexGuard<'static, State> {
    STATE.lock().unwrap_or_else(|poison| poison.into_inner())
}

/// Record a change: wakes every catalog stream.
pub fn changed(state: &mut State) {
    state.revision = state.revision.wrapping_add(1);
    CHANGES.send_replace(state.revision);
}

/// A receiver that wakes on every change.
pub fn changes() -> watch::Receiver<u64> {
    CHANGES.subscribe()
}

/// Unix milliseconds.
pub fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

impl State {
    /// Whether `caller` may still act now: an agent needs this process to
    /// serve the tools, the switch on and a token nobody revoked meanwhile.
    /// Checked again right before anything is published or connected, since
    /// a call can wait a long time for a port or for the user.
    pub fn admits(&self, caller: &Caller) -> Result<(), ToolError> {
        if caller.is_user() {
            return Ok(());
        }
        if !self.hosting {
            return Err(ToolError::NotHosting);
        }
        if !self.settings.enabled {
            return Err(ToolError::Off);
        }
        if !self.tokens.contains(&caller.principal.id) {
            return Err(ToolError::Revoked);
        }
        Ok(())
    }

    /// Whether the user handed gated built-in tool `tool` to the
    /// conversation `key` of `caller`'s hosted instance from the composer.
    pub fn granted(&self, caller: &Caller, key: &OwnerKey, tool: &str) -> bool {
        caller.principal.host.as_ref().is_some_and(|host| {
            self.granted.contains(&Granted {
                host: host.clone(),
                conversation: key.conversation.clone(),
                tool: tool.to_string(),
            })
        })
    }

    /// Ports already shared on this device.
    pub fn shared_ports(&self) -> usize {
        self.shares.iter().map(|share| share.ports.len()).sum()
    }

    /// The share that holds `port`, if any.
    pub fn share_with_port(&self, port: u16) -> Option<&Share> {
        self.shares
            .iter()
            .find(|share| share.ports.iter().any(|p| p.port == port))
    }

    /// Save the shares that outlive this process. A failure is remembered
    /// and retried by the supervisor; a caller that must not report success
    /// unsaved checks the result.
    pub fn save_shares(&mut self) -> anyhow::Result<()> {
        if self.shares_blocked {
            anyhow::bail!("the saved shares could not be read, so they are not overwritten");
        }
        let Some(dir) = &self.dir else { return Ok(()) };
        let saved: Vec<SavedShare> = self
            .shares
            .iter()
            .filter(|share| share.durable())
            .map(Share::saved)
            .collect();
        let written = serde_json::to_vec(&saved)
            .map_err(anyhow::Error::from)
            .and_then(|bytes| {
                crate::engine::host_profiles::files::write_private(&dir.join("shares.json"), &bytes)
            });
        self.shares_unsaved = written.is_err();
        if let Err(error) = &written {
            tracing::warn!("shares not saved: {error:#}");
        }
        written.map(drop)
    }
}

/// The shares saved in `dir`: none when nothing was saved, an error when the
/// file cannot be read or parsed.
pub fn saved_shares(dir: &std::path::Path) -> anyhow::Result<Vec<SavedShare>> {
    use anyhow::Context as _;
    match std::fs::read(dir.join("shares.json")) {
        Ok(bytes) => serde_json::from_slice(&bytes).context("reading the saved shares"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(error) => Err(error).context("reading the saved shares"),
    }
}

/// Move an unreadable shares file aside (kept for the user, never
/// overwritten); returns where it went.
pub fn set_aside_shares(dir: &std::path::Path) -> std::io::Result<PathBuf> {
    let aside = dir.join(format!("shares.json.unreadable-{}", now_ms()));
    std::fs::rename(dir.join("shares.json"), &aside)?;
    Ok(aside)
}
