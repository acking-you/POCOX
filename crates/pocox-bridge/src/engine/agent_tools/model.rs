//! Wire types shared by the host's catalog routes, controllers, the MCP
//! tools, the local CLI surface and the app.
//!
//! Everything a remote device wrote (titles, owner labels) is untrusted data:
//! bounded when it is read, shown as text, never followed as instructions.

use serde::{Deserialize, Serialize};

pub use super::builtin::BuiltinTool;

/// Version of `/services/v1` and of the local surface.
pub const PROTOCOL: u32 = 1;

/// Longest title or label kept from any source.
pub const MAX_LABEL: usize = 80;

/// Longest ACP session id the host admits, in bytes; kept exactly.
pub const MAX_SESSION_ID: usize = 1024;

/// Most ports one device shares at a time.
pub const MAX_SHARED_PORTS: usize = 8;

/// Most ports one share holds.
pub const MAX_PORTS_PER_SHARE: usize = 4;

/// The app's preferred endpoint port; the CLI host uses the next one.
pub const APP_PORT: u16 = 17863;

/// The CLI host's preferred endpoint port.
pub const CLI_PORT: u16 = 17864;

/// How long an agent's share or connection lives unless kept.
pub const AGENT_LEASE_MS: i64 = 24 * 60 * 60 * 1000;

/// Characters that change how text around them is shown without being
/// visible themselves: bidirectional controls (which can make "port 3715"
/// read as "5173" in a consent prompt), zero-width and other format marks.
fn invisible(c: char) -> bool {
    matches!(c,
        '\u{061C}' | '\u{200B}'..='\u{200F}' | '\u{202A}'..='\u{202E}'
        | '\u{2060}'..='\u{206F}' | '\u{FEFF}' | '\u{FFF9}'..='\u{FFFB}')
}

/// `text` without control or invisible formatting characters, trimmed and at
/// most [`MAX_LABEL`] characters.
pub fn bounded(text: &str) -> String {
    text.chars()
        .filter(|c| !c.is_control() && !invisible(*c))
        .collect::<String>()
        .trim()
        .chars()
        .take(MAX_LABEL)
        .collect()
}

/// One device's agent tools and shares, as its host owner reports them.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Catalog {
    /// [`PROTOCOL`].
    pub protocol: u32,
    /// The reporting device's id (the `<device>` of its keys).
    pub device: String,
    /// `macos`, `windows`, `linux`, ... of the reporting device.
    #[serde(default)]
    pub platform: String,
    /// Changes whenever anything below changes.
    pub revision: u64,
    /// The device's switch.
    pub tools: ToolsState,
    /// Ports this device shares.
    pub shares: Vec<ShareView>,
    /// Shares waiting for the user's answer.
    pub consents: Vec<ConsentView>,
    /// Agent hosts and APIs this device serves.
    #[serde(default)]
    pub services: Vec<HostedView>,
    /// Built-in tools a conversation on this device can be handed from the
    /// composer (none from a POCOX that predates them).
    #[serde(default)]
    pub builtin: Vec<BuiltinTool>,
}

/// The switch of one installation.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ToolsState {
    /// Agents can use the tools on this device.
    pub enabled: bool,
    /// The first share of each owner needs the user's answer.
    pub ask_before_sharing: bool,
}

/// Who made a share or connection, as POCOX recorded it.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct OwnerView {
    /// `user` or `agent`.
    pub kind: OwnerKind,
    /// Display name: `Codex · default`, `Claude Code`, `You`.
    pub label: String,
    /// `codex`, `claude`, `opencode`, `acp` or the MCP client's name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    /// The hosted instance, for a harness POCOX runs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<String>,
    /// The conversation (Codex thread or ACP session), when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conversation: Option<String>,
}

/// Whether a person or an agent made something.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum OwnerKind {
    /// The user, from the app or the CLI.
    User,
    /// An agent, through the MCP tools.
    Agent,
}

/// One share: loopback ports of the reporting device, published together.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ShareView {
    /// Stable id on the reporting device.
    pub id: String,
    /// What it is (`Landing page`).
    pub title: String,
    /// Path to open on the first port.
    pub path: String,
    /// The page is served over TLS (opened with `https`).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub secure: bool,
    /// Each port and its relay service.
    pub ports: Vec<PortView>,
    /// Who made it.
    pub owner: OwnerView,
    /// Unix milliseconds.
    pub created_ms: i64,
    /// When it ends on its own; `None` while kept by the user.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_ms: Option<i64>,
}

impl ShareView {
    /// The first port's relay key.
    pub fn first_key(&self) -> Option<&str> {
        self.ports.first().map(|port| port.key.as_str())
    }
}

/// One shared port.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PortView {
    /// The port number on the sharing device.
    pub port: u16,
    /// Its relay service key (`pcx:<device>:port:<port>`).
    pub key: String,
    /// Reachability as the sharing device sees it.
    pub status: PortStatus,
}

/// A shared port's state on the device that shares it.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum PortStatus {
    /// Published and answering.
    Online,
    /// Waiting for the relay.
    Starting,
    /// Published, but nothing answers on the port.
    Unreachable,
    /// The relay refused the registration; retried with a pause.
    Refused,
}

/// A share, or a connection to another device's Responses API, waiting for
/// the user's answer.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ConsentView {
    /// Answer with this id.
    pub id: String,
    /// Who asks.
    pub owner: OwnerView,
    /// What would be shared, or the name of the service to connect.
    pub title: String,
    /// Which ports (none for a connection).
    pub ports: Vec<u16>,
    /// The key of the service to connect; none for a share. Older apps,
    /// which do not know it, show the request by its title.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub service: Option<String>,
    /// Unix milliseconds.
    pub created_ms: i64,
    /// Unanswered requests lapse.
    pub expires_ms: i64,
}

/// One message of a catalog's event stream: the whole catalog, and what is
/// new since the previous message on the same stream.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CatalogEvent {
    /// The catalog now.
    pub catalog: Catalog,
    /// Shares that appeared since the previous message (none in the first).
    #[serde(default)]
    pub added: Vec<String>,
}

impl CatalogEvent {
    /// The event for `catalog` after `previous` (`None` for a stream's first).
    pub fn after(previous: Option<&Catalog>, catalog: Catalog) -> Self {
        let added = match previous {
            None => Vec::new(),
            Some(previous) => catalog
                .shares
                .iter()
                .filter(|share| previous.shares.iter().all(|old| old.id != share.id))
                .map(|share| share.id.clone())
                .collect(),
        };
        Self {
            catalog,
            added,
        }
    }
}

/// The user's answer to a consent request.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Decision {
    /// Share this time.
    AllowOnce,
    /// Share, and let this conversation (or token) share again without asking.
    AllowConversation,
    /// Do not share.
    Deny,
}

/// An agent host or API the reporting device serves.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct HostedView {
    /// Relay key.
    pub key: String,
    /// `agent` or `api`.
    pub kind: String,
    /// Instance name.
    pub name: String,
    /// `codex`, `claude`, `opencode` or another ACP agent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    /// `online` or `starting`.
    pub status: String,
}

/// Every device and service the caller can see, with this device's own
/// connections.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Overview {
    /// The device answering.
    pub this_device: String,
    /// This device first, then the others by name.
    pub devices: Vec<DeviceView>,
    /// Services of other devices reachable on this device.
    pub connections: Vec<ConnectionView>,
}

/// One device in an [`Overview`].
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DeviceView {
    /// Device id.
    pub name: String,
    /// Platform, when its catalog answered.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
    /// Something of it is on the relay right now.
    pub online: bool,
    /// Its catalog answered (a device without one needs a newer POCOX for
    /// titles, owners and consent).
    pub catalog: bool,
    /// Its tools switch, when its catalog answered.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tools: Option<ToolsState>,
    /// Its services.
    pub services: Vec<ServiceEntry>,
    /// Its shares (with owners and expiry), when its catalog answered.
    #[serde(default)]
    pub shares: Vec<ShareView>,
    /// Shares of it waiting for the user.
    #[serde(default)]
    pub consents: Vec<ConsentView>,
    /// Its built-in tools, when its catalog answered.
    #[serde(default)]
    pub builtin: Vec<BuiltinTool>,
}

/// One service in an [`Overview`].
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ServiceEntry {
    /// Relay key.
    pub key: String,
    /// `agent`, `api`, `port` or `host`.
    pub kind: String,
    /// Instance name (the port number for a shared port).
    pub name: String,
    /// The agent, for an agent host.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    /// A shared port's title.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// A shared port's number.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    /// `online`, `starting`, `unreachable` or `offline`.
    pub status: String,
    /// Who shared it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    /// The share it belongs to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub share: Option<String>,
}

/// A service of another device reachable on this one.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionView {
    /// The remote service's key.
    pub service: String,
    /// `127.0.0.1:<port>` on this device.
    pub local: String,
    /// Whether it got the service's own port number.
    pub same_port: bool,
    /// Who keeps it.
    pub owner: OwnerView,
    /// When it ends on its own.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_ms: Option<i64>,
}

/// What a successful share returns.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Shared {
    /// The share.
    pub share: ShareView,
    /// `http://localhost:<port><path>`, valid here and, once connected with
    /// the same port, on the user's devices.
    pub on_this_machine: String,
    /// A link the POCOX apps open (`pocox://open?service=…&path=…`).
    pub open: String,
    /// When it ends, in words.
    pub ends: String,
}

/// The `pocox://open` link for a service and path (`scheme=https` when the
/// page is served over TLS).
pub fn open_link(service: &str, path: &str, secure: bool) -> String {
    let scheme = if secure { "&scheme=https" } else { "" };
    format!("pocox://open?service={}&path={}{scheme}", encode(service), encode(path))
}

/// `http` or `https`.
pub fn scheme(secure: bool) -> &'static str {
    if secure {
        "https"
    } else {
        "http"
    }
}

fn encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' | b':' => {
                out.push(byte as char)
            },
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// A normalized path to open: starts with `/`, bounded, no scheme or host.
pub fn clean_path(path: Option<&str>) -> String {
    let path = path.map(str::trim).unwrap_or("/");
    if path.is_empty() || path.contains("://") || path.starts_with("//") {
        return "/".into();
    }
    let path: String = path.chars().filter(|c| !c.is_control()).take(512).collect();
    if path.starts_with('/') {
        path
    } else {
        format!("/{path}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn links_and_paths_never_carry_another_origin() {
        assert_eq!(clean_path(Some("https://evil.example/x")), "/");
        assert_eq!(clean_path(Some("//evil.example")), "/");
        assert_eq!(clean_path(Some("docs?q=1")), "/docs?q=1");
        assert_eq!(
            open_link("pcx:studio:port:5173", "/a b", false),
            "pocox://open?service=pcx:studio:port:5173&path=/a%20b"
        );
        assert!(open_link("pcx:studio:port:8443", "/", true).ends_with("&scheme=https"));
        assert_eq!(bounded(&format!(" {}\u{7} ", "x".repeat(200))).len(), MAX_LABEL);
    }
}
