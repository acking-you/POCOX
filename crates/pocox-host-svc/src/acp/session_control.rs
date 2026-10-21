//! A displayed ownership snapshot. Every action revalidates its identities.

use serde::{Deserialize, Serialize};

/// Concrete operations offered by the host for one original native session.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionControl {
    /// Exact native session id.
    pub session_id: String,
    /// Host incarnation that produced this snapshot.
    pub host_id: String,
    /// Agent generation that produced this snapshot.
    pub generation: u64,
    /// Persisted source identity, required for an acquisition.
    pub source_generation: Option<String>,
    /// Native provider, independent of the instance's display name.
    pub provider: String,
    /// Ownership state; unknown future states must remain read-only.
    pub status: String,
    /// This host already owns the writer; another controller may attach.
    pub can_continue: bool,
    /// The idle writer can be closed on this host's existing connection.
    pub can_release: bool,
    /// An explicit, freshly checked original-session acquisition is available.
    pub can_acquire: bool,
}
