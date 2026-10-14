//! Provider-neutral session admission, with writer ownership and turn activity
//! represented independently. Only the serving host grants write access.

use serde::{Deserialize, Serialize};

/// Positive holder evidence, without command lines or process environments.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AccessHolder {
    /// `claude_code`, `opencode`, `pocket_host`, or `unknown`.
    pub client: String,
    /// Verified live process, when observable.
    pub pid: Option<u32>,
    /// Process creation time in Unix milliseconds, when observable.
    pub started_at: Option<i64>,
    /// Name of another Pocket host, when known.
    pub host_name: Option<String>,
    /// Exact reachable Pocket service key, never an invented navigation target.
    pub service_key: Option<String>,
}

/// The result of opening or inspecting one original session. A follow view
/// is not a grant to load, resume, signal, or fork an outside writer.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SessionAccess {
    /// Exact original native session identifier.
    pub session_id: String,
    /// Serving host incarnation.
    pub host_id: String,
    /// Engine generation within this incarnation.
    pub generation: u64,
    /// Canonical persisted source identity, when available.
    pub source_generation: Option<String>,
    /// `claude`, `opencode`, or a generic ACP provider profile.
    pub provider: String,
    /// `write`, `follow`, or `blocked`.
    pub mode: String,
    /// `this_host`, `none`, `pocket_host`, `native_client`, or `unknown`.
    pub writer: String,
    /// `idle`, `running`, `unfinished`, or `unknown`.
    pub turn: String,
    /// The enforced scope: `engine`, `pocket`, or `none`.
    pub exclusion: String,
    /// Stable provider-specific availability reason, localized by the UI.
    pub reason: String,
    /// Safe explanation with no credentials, when a reason needs detail.
    pub detail: Option<String>,
    /// Positive evidence of another holder, when available.
    pub holder: Option<AccessHolder>,
    /// The owning host can explicitly close its idle writer.
    pub can_release: bool,
    /// Foreground views should refresh this observation while following.
    pub recheck: bool,
}

impl SessionAccess {
    /// Start with conservative unknown ownership. Callers set only fields
    /// supported by fresh native evidence; absence of activity is insufficient.
    pub fn unknown(session: &str, host: &str, generation: u64, provider: &str) -> Self {
        Self {
            session_id: session.into(),
            host_id: host.into(),
            generation,
            source_generation: None,
            provider: provider.into(),
            mode: "follow".into(),
            writer: "unknown".into(),
            turn: "unknown".into(),
            exclusion: "none".into(),
            reason: "source_unknown".into(),
            detail: None,
            holder: None,
            can_release: false,
            recheck: true,
        }
    }
}
