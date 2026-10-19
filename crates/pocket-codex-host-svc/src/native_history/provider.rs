//! Concrete reader dispatch shared by local browsing and hosted ACP views.
use anyhow::{bail, Result};
use pocket_codex_core::process::ProcessIdentity;
use serde_json::Value;

use super::{ClaimError, ClaudeHistory, GrokHistory, NativePage, SessionClaim};
use crate::sessions::SessionLiveness;

/// An explicitly selected native source. No variant admits or resumes sessions.
pub enum NativeHistory {
    /// Official read-only Claude SDK with optional verified native ownership.
    Claude(std::sync::Arc<ClaudeHistory>),
    /// Grok Build's own session store under its home.
    Grok(std::sync::Arc<GrokHistory>),
    /// Existing OpenCode database, available on desktop hosts only.
    #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
    OpenCode(super::OpenCodeHistory),
}

impl NativeHistory {
    /// Stable projection identity used by history reconciliation.
    pub fn provider(&self) -> &'static str {
        match self {
            Self::Claude(_) => "claude/native-v1",
            Self::Grok(_) => "grok/native-v1",
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(_) => "opencode/native-v1",
        }
    }

    /// The provider a session access names (`claude`, `grok`, `opencode`).
    pub fn access_provider(&self) -> &'static str {
        match self {
            Self::Claude(_) => "claude",
            Self::Grok(_) => "grok",
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(_) => "opencode",
        }
    }

    /// The provider's name in an explanation.
    pub(crate) fn display_name(&self) -> &'static str {
        match self {
            Self::Claude(_) => "Claude",
            Self::Grok(_) => "Grok",
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(_) => "OpenCode",
        }
    }

    /// Whether the ACP agent process itself writes an admitted session, and
    /// registers nowhere (Grok's `agent stdio`), rather than a native child
    /// that registers as its owner (the Claude adapter's CLI).
    pub(crate) fn agent_writes_unregistered(&self) -> bool {
        matches!(self, Self::Grok(_))
    }

    /// List one source-scoped inventory page.
    pub async fn list_sessions(&self, cursor: Option<&str>, limit: usize) -> Result<Value> {
        match self {
            Self::Claude(reader) => reader.list_sessions(cursor, limit).await,
            Self::Grok(reader) => reader.list_sessions(cursor, limit).await,
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(reader) => reader.list_sessions(cursor, limit).await,
        }
    }
    /// Read the source revision without starting a runtime.
    pub async fn revision(&self, session: &str) -> Result<Value> {
        match self {
            Self::Claude(reader) => reader.revision(session).await,
            Self::Grok(reader) => reader.revision(session).await,
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(reader) => reader.revision(session).await,
        }
    }
    /// Read a bounded window, without acquiring write permission.
    pub async fn read_page(
        &self,
        session: &str,
        before: Option<&str>,
        limit: usize,
    ) -> Result<NativePage> {
        match self {
            Self::Claude(reader) => reader.read_page(session, before, limit).await,
            Self::Grok(reader) => reader.read_page(session, before, limit).await,
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(reader) => reader.read_page(session, before, limit).await,
        }
    }
    /// Read one explicit native turn.
    pub async fn read_turn(&self, session: &str, turn: &str) -> Result<NativePage> {
        match self {
            Self::Claude(reader) => reader.read_turn(session, turn).await,
            Self::Grok(reader) => reader.read_turn(session, turn).await,
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(reader) => reader.read_turn(session, turn).await,
        }
    }
    /// Reading a file or database never proves that an external writer is idle.
    pub async fn liveness(&self, session: &str) -> SessionLiveness {
        match self {
            Self::Claude(reader) => reader.liveness(session).await,
            Self::Grok(reader) => reader.liveness(session).await,
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(_) => super::ownership::unknown(session),
        }
    }

    /// Fresh evidence for an explicit handoff, never the display cache.
    pub(crate) async fn handoff_liveness(&self, session: &str) -> SessionLiveness {
        match self {
            Self::Claude(reader) => reader.handoff_liveness(session).await,
            Self::Grok(reader) => reader.handoff_liveness(session).await,
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(_) => super::ownership::unknown(session),
        }
    }

    /// Verified native holders that have no turn running (Claude), or every
    /// verified holder (Grok records no turn state).
    pub(crate) async fn idle_owners(&self, session: &str) -> Result<Vec<ProcessIdentity>> {
        match self {
            Self::Claude(reader) => reader.idle_owners(session).await,
            Self::Grok(reader) => reader.owners(session).await,
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(_) => bail!("this source has no ownership probe"),
        }
    }

    /// Verified native holders, a running one included.
    pub(crate) async fn writer_owners(&self, session: &str) -> Result<Vec<ProcessIdentity>> {
        match self {
            Self::Claude(reader) => reader.writer_owners(session).await,
            Self::Grok(reader) => reader.owners(session).await,
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(_) => bail!("this source has no ownership probe"),
        }
    }

    /// The cross-process Pocket claim for `session` in this source.
    pub(crate) fn claim_session(&self, session: &str) -> Result<SessionClaim, ClaimError> {
        match self {
            Self::Claude(reader) => reader.claim_session(session),
            Self::Grok(reader) => reader.claim_session(session),
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(_) => Err(ClaimError::Unavailable),
        }
    }

    /// Of `sessions`, those no verified native client holds.
    pub(crate) async fn unowned_sessions(&self, sessions: &[String]) -> Result<Vec<String>> {
        match self {
            Self::Claude(reader) => reader.unowned_sessions(sessions).await,
            Self::Grok(reader) => reader.unowned_sessions(sessions).await,
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(_) => bail!("this source has no ownership probe"),
        }
    }
}
