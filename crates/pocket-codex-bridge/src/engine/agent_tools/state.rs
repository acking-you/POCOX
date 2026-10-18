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
use pocket_codex_pb::Published;
use serde::{Deserialize, Serialize};
use tokio::sync::{watch, Notify};

use super::{
    model::{
        ConnectionView, ConsentView, Decision, HostedView, OwnerKind, OwnerView, PortStatus,
        PortView, ShareView,
    },
    settings::Settings,
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
}

impl SharedPort {
    fn status(&self) -> PortStatus {
        match (self.published.as_ref().is_some_and(|p| p.is_live()), self.reachable) {
            (false, _) => PortStatus::Starting,
            (true, true) => PortStatus::Online,
            (true, false) => PortStatus::Unreachable,
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
        self.key.is_none() || self.owner.kind == OwnerKind::User
    }

    /// The saved form.
    pub fn saved(&self) -> SavedShare {
        SavedShare {
            id: self.id.clone(),
            title: self.title.clone(),
            path: self.path.clone(),
            owner: self.owner.clone(),
            created_ms: self.created_ms,
            expires_ms: self.expires_ms,
            ports: self.ports.iter().map(|port| port.port).collect(),
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
    /// Recorded owner.
    pub owner: OwnerView,
    /// Unix milliseconds.
    pub created_ms: i64,
    /// When it ends on its own.
    pub expires_ms: Option<i64>,
    /// Its ports.
    pub ports: Vec<u16>,
}

/// A share waiting for the user.
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
    /// Recorded owner.
    pub owner: OwnerView,
    /// Who keeps it alive; `None` for the user's own.
    pub key: Option<OwnerKey>,
    /// When it ends on its own.
    pub expires_ms: Option<i64>,
}

impl Connection {
    /// The view the tools and the app show.
    pub fn view(&self) -> ConnectionView {
        ConnectionView {
            service: self.service.clone(),
            local: self.local.clone(),
            same_port: self.same_port,
            owner: self.owner.clone(),
            expires_ms: self.expires_ms,
        }
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
    /// Shares of this device.
    pub shares: Vec<Share>,
    /// Requests waiting for the user.
    pub consents: Vec<Consent>,
    /// Owners the user let share without asking again.
    pub allowed: HashSet<OwnerKey>,
    /// Recently declined owners (they are not asked again for a while).
    pub declined: Vec<(OwnerKey, i64)>,
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

    /// Save the shares that outlive this process.
    pub fn save_shares(&self) {
        let Some(dir) = &self.dir else { return };
        let saved: Vec<SavedShare> = self
            .shares
            .iter()
            .filter(|share| share.durable())
            .map(Share::saved)
            .collect();
        let bytes = match serde_json::to_vec(&saved) {
            Ok(bytes) => bytes,
            Err(error) => return tracing::warn!(%error, "shares not saved"),
        };
        if let Err(error) =
            crate::engine::host_profiles::files::write_private(&dir.join("shares.json"), &bytes)
        {
            tracing::warn!("shares not saved: {error:#}");
        }
    }
}

/// The saved shares in `dir`.
pub fn saved_shares(dir: &std::path::Path) -> Vec<SavedShare> {
    std::fs::read(dir.join("shares.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}
