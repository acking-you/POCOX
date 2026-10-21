//! Provider-native history access, independent of ACP session admission.
//!
//! These readers never resume a session, send a prompt, or infer write
//! ownership from a successful read. A readable transcript can still have
//! another live writer.

mod claim;
mod claude;
mod command;
mod discovery;
mod grok;
#[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
mod opencode;
mod ownership;
mod provider;
mod source;

pub use claim::{ClaimError, SessionClaim};
pub use claude::ClaudeHistory;
pub use grok::{GrokHistory, NativeFollow};
#[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
pub use opencode::OpenCodeHistory;
pub use provider::NativeHistory;
use serde::{Deserialize, Serialize};

use crate::acp::fold::Turn;

/// A bounded native transcript page, oldest-to-newest within the page.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativePage {
    /// Native session identifier, never a controller-local alias.
    pub session_id: String,
    /// Identity of the persisted source; replacement invalidates old windows.
    pub generation: String,
    /// Content revision used for cache invalidation and follow polling.
    pub revision: String,
    /// Persisted source length, used to recognize in-place truncation.
    pub source_bytes: u64,
    /// Recorded project directory on the source host.
    pub cwd: String,
    /// Public native title or first-prompt preview.
    pub title: String,
    /// Native update timestamp in milliseconds since the Unix epoch.
    pub updated_at: u64,
    /// The selected turns; no hidden reasoning or internal metadata.
    pub turns: Vec<Turn>,
    /// Older native turns exist before this page.
    pub has_older: bool,
    /// Exclusive turn boundary for the next older page.
    pub next_before: Option<String>,
    /// Exact canonical turn count when the native reader provides it.
    /// SQL message counts cannot account for public orphan prefixes.
    pub total_turns: Option<usize>,
    /// Content was omitted to respect display or transport limits.
    pub truncated: bool,
}
