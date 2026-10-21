//! Provider-neutral original-session access and native commands.

use pocox_host_svc::session_access::{AccessHolder, SessionAccess};

use super::*;
use crate::engine::{acp, opencode};

/// Positive holder evidence without command lines or environments.
pub struct AccessHolderDto {
    /// Observed client family.
    pub client: String,
    /// Verified process ID.
    pub pid: Option<u32>,
    /// Verified process creation time in Unix milliseconds.
    pub started_at: Option<i64>,
    /// Known POCOX host name.
    pub host_name: Option<String>,
    /// Known reachable service key; never inferred.
    pub service_key: Option<String>,
}

/// Current original-session admission; idle alone never grants write access.
pub struct SessionAccessDto {
    /// Exact original session ID.
    pub session_id: String,
    /// Serving host incarnation.
    pub host_id: String,
    /// Engine generation.
    pub generation: u64,
    /// Native source identity.
    pub source_generation: Option<String>,
    /// Native provider family.
    pub provider: String,
    /// write, follow, or blocked.
    pub mode: String,
    /// this_host, none, pocox_host, native_client, or unknown.
    pub writer: String,
    /// idle, running, unfinished, or unknown.
    pub turn: String,
    /// engine, pocox, or none.
    pub exclusion: String,
    /// Stable localized availability reason.
    pub reason: String,
    /// Safe explanation when needed.
    pub detail: Option<String>,
    /// Verified outside holder, when observable.
    pub holder: Option<AccessHolderDto>,
    /// Owning host can close its idle writer.
    pub can_release: bool,
    /// Refresh access while following.
    pub recheck: bool,
}

impl From<AccessHolder> for AccessHolderDto {
    fn from(v: AccessHolder) -> Self {
        Self {
            client: v.client,
            pid: v.pid,
            started_at: v.started_at,
            host_name: v.host_name,
            service_key: v.service_key,
        }
    }
}

impl From<AccessHolderDto> for AccessHolder {
    fn from(v: AccessHolderDto) -> Self {
        Self {
            client: v.client,
            pid: v.pid,
            started_at: v.started_at,
            host_name: v.host_name,
            service_key: v.service_key,
        }
    }
}

impl From<SessionAccess> for SessionAccessDto {
    fn from(v: SessionAccess) -> Self {
        Self {
            session_id: v.session_id,
            host_id: v.host_id,
            generation: v.generation,
            source_generation: v.source_generation,
            provider: v.provider,
            mode: v.mode,
            writer: v.writer,
            turn: v.turn,
            exclusion: v.exclusion,
            reason: v.reason,
            detail: v.detail,
            holder: v.holder.map(Into::into),
            can_release: v.can_release,
            recheck: v.recheck,
        }
    }
}

impl From<SessionAccessDto> for SessionAccess {
    fn from(v: SessionAccessDto) -> Self {
        Self {
            session_id: v.session_id,
            host_id: v.host_id,
            generation: v.generation,
            source_generation: v.source_generation,
            provider: v.provider,
            mode: v.mode,
            writer: v.writer,
            turn: v.turn,
            exclusion: v.exclusion,
            reason: v.reason,
            detail: v.detail,
            holder: v.holder.map(Into::into),
            can_release: v.can_release,
            recheck: v.recheck,
        }
    }
}

/// Inspect current writer admission without restoring or closing a native
/// session.
pub fn app_session_access(service_key: String, thread_id: String) -> Result<SessionAccessDto> {
    Ok(match session_engine::protocol_of(&service_key) {
        Protocol::Acp => acp::session_access(&service_key, &thread_id)?,
        Protocol::OpenCode => opencode::access(&service_key, &thread_id)?,
        other => return Err(session_engine::unsupported(other, "provider session access")),
    }
    .into())
}

/// Safely open the exact original session; another writer yields a follow view.
pub fn app_session_open(service_key: String, thread_id: String) -> Result<SessionAccessDto> {
    Ok(match session_engine::protocol_of(&service_key) {
        Protocol::Acp => acp::session_open(&service_key, &thread_id)?,
        Protocol::OpenCode => opencode::open(&service_key, &thread_id)?,
        other => return Err(session_engine::unsupported(other, "provider session access")),
    }
    .into())
}

/// Relinquish this host's idle writer against the exact displayed source
/// snapshot.
pub fn app_session_release(
    service_key: String,
    snapshot: SessionAccessDto,
) -> Result<SessionAccessDto> {
    let snapshot = snapshot.into();
    Ok(match session_engine::protocol_of(&service_key) {
        Protocol::Acp => acp::session_release(&service_key, &snapshot)?,
        Protocol::OpenCode => opencode::release(&service_key, &snapshot)?,
        other => return Err(session_engine::unsupported(other, "provider session release")),
    }
    .into())
}

/// Native command metadata; implementation templates remain private on the
/// host.
pub struct AgentCommandDto {
    /// Exact command name without the slash.
    pub name: String,
    /// Public description.
    pub description: Option<String>,
    /// Native origin such as command, skill, or mcp.
    pub source: String,
    /// Public argument hints.
    pub hints: Vec<String>,
}

/// List commands from the selected project without creating a session.
pub fn app_command_list_for_project(
    service_key: String,
    directory: Option<String>,
) -> Result<Vec<AgentCommandDto>> {
    match session_engine::protocol_of(&service_key) {
        Protocol::OpenCode => Ok(opencode::commands(&service_key, directory.as_deref())?
            .into_iter()
            .map(|c| AgentCommandDto {
                name: c.name,
                description: c.description,
                source: c.source,
                hints: c.hints,
            })
            .collect()),
        // An ACP agent's commands are its own, the same in every project.
        Protocol::Acp => Ok(acp::commands(&service_key)?
            .into_iter()
            .map(|c| AgentCommandDto {
                name: c.name,
                description: (!c.description.is_empty()).then_some(c.description),
                source: "command".into(),
                hints: c.hint.into_iter().collect(),
            })
            .collect()),
        other => Err(session_engine::unsupported(other, "commands")),
    }
}
