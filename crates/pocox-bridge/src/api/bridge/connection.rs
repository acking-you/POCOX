//! App-server remote control: connecting, probing and capabilities.

use super::*;
use crate::engine::execution::{self, Lane};

/// Display identity only; does not grant capabilities or establish a session.
pub struct AgentIdentityDto {
    /// Engine family (`codex`, `opencode` or `acp`).
    pub provider: String,
    /// Explicit profile id reported by the host; empty when unknown.
    pub profile_id: String,
    /// Agent display name reported by the host; empty when unknown.
    pub name: String,
}

/// Read an agent's display identity before connecting. ACP uses its existing
/// read-only info route over a temporary tunnel; native engines need no
/// request.
pub async fn app_agent_identity(service_key: String) -> Result<AgentIdentityDto> {
    execution::run(Lane::Background, move || {
        let caps = match session_engine::protocol_of(&service_key) {
            Protocol::Acp => {
                let owned = transport::resolve_owned_blocking()?;
                let info = crate::engine::acp::host_info(&service_key, &owned)?;
                crate::engine::acp::capabilities_of(&info, 0)
            },
            _ => engine(&service_key).capabilities(&service_key),
        };
        Ok(AgentIdentityDto {
            provider: caps.provider,
            profile_id: caps.profile_id,
            name: caps.provider_name,
        })
    })
    .await
}

/// Connect to a session service, dispatched by its key's protocol: a Codex
/// app-server (subscribe on `127.0.0.1:<local_port>`, open the JSON-RPC
/// websocket, run `initialize`) or an ACP gateway (`/acp/v1` snapshot, then
/// its event stream). Idempotent.
pub async fn app_connect(service_key: String, local_port: u16) -> Result<()> {
    execution::run(Lane::Control, move || {
        engine(&service_key).connect(service_key.clone(), local_port)
    })
    .await
}

/// Whether a live app-server session exists for `service_key`.
#[frb(sync)]
pub fn app_is_connected(service_key: String) -> bool {
    engine(&service_key).is_connected(&service_key)
}

/// Disconnect this controller's session and its pb-mapper subscription.
/// Work owned by a host (ACP turns, permissions) keeps running there.
pub async fn app_disconnect(service_key: String) -> Result<()> {
    execution::run(Lane::Control, move || {
        engine(&service_key).disconnect(&service_key);
        Ok(())
    })
    .await
}

/// Probe whether a session service is actually REACHABLE — its backend
/// answers — rather than merely registered on the relay, so a
/// registered-but-dead host shows as unreachable instead of a false "online".
/// Dispatched by the key's protocol: a Codex app-server gets a transient
/// tunnel + `initialize` with a timeout; an ACP gateway answers `/acp/v1`
/// info with a ready agent.
/// A live session short-circuits to `true`.
pub async fn app_probe(service_key: String) -> Result<bool> {
    Ok(app_probe_reason(service_key).await?.is_none())
}

/// Why [`app_probe`] considers a service unreachable, or `None` when it is
/// reachable.
///
/// A bare `false` made the UI say "the app-server did not respond", which is
/// wrong whenever the tunnel DID answer and refused us — a relay rejecting the
/// handshake (missing or stale authentication code) is the common case, and it
/// needs a different fix from a dead backend. This hands the transport's own
/// words to the UI so it can name the actual problem.
pub async fn app_probe_reason(service_key: String) -> Result<Option<String>> {
    execution::run(Lane::Background, move || engine(&service_key).probe_reason(service_key.clone()))
        .await
}

/// Probe whether an API proxy is actually REACHABLE — its host answers a
/// minimal HTTP request — rather than merely registered on the relay. The
/// services list uses this so a registered-but-dead API proxy (a live relay
/// registrant forwarding to an api-proxy that has died) shows unreachable
/// instead of a false "online", matching the app-server's [`app_probe`]. Opens
/// a transient tunnel, hits the proxy's local 403 fallback (no upstream model
/// call), then tears it down.
pub async fn api_probe(service_key: String) -> Result<bool> {
    execution::run(Lane::Background, move || {
        Ok(app_session::probe_api(service_key, &transport::resolve_blocking()?))
    })
    .await
}

/// Health-check an app-server THIS machine hosts itself, by its loopback
/// app-listen address (e.g. `127.0.0.1:18080`) — a direct `initialize`
/// handshake with no relay hop. Unlike a bare port-open check this catches a
/// wedged / half-open codex (the listener still `accept`s but never answers
/// RPC), so a locally-hosted server that has silently stopped serving reads
/// `false` instead of a false "running". Fast because it stays on loopback.
pub async fn app_probe_local(local_addr: String) -> Result<bool> {
    execution::run(Lane::Background, move || Ok(app_session::probe_endpoint(&local_addr))).await
}

/// Health-check an API proxy THIS machine hosts itself, by its loopback
/// api-listen address — a direct minimal HTTP request, no relay hop. Lets a
/// local host's API tunnel read "online" the instant its proxy is up instead
/// of waiting on a slower transient relay round-trip. Mirrors
/// [`app_probe_local`].
pub async fn api_probe_local(local_addr: String) -> Result<bool> {
    execution::run(Lane::Background, move || Ok(app_session::probe_http_endpoint(&local_addr)))
        .await
}

/// What a session service's provider supports, so the shared session UI can
/// hide controls that do not apply. Optional ACP capabilities remain
/// conservative (`false`) until a feature is actually available.
pub struct AppCapabilitiesDto {
    /// `codex` or `acp`.
    pub provider: String,
    /// Fast service tier toggle.
    pub fast: bool,
    /// Approval / sandbox permission presets.
    pub permission_presets: bool,
    /// Guardian (auto-review) approvals.
    pub guardian: bool,
    /// Account rate-limit snapshot.
    pub rate_limits: bool,
    /// Taking over a session held by another local process.
    pub takeover: bool,
    /// Monitoring another writer of the same session.
    pub external_writer_monitor: bool,
    /// Sessions read directly from this device's disk.
    pub local_sessions: bool,
    /// Plan collaboration mode.
    pub plan_mode: bool,
    /// Wire protocol: `codex-app-server` or `acp`.
    pub protocol: String,
    /// Human-readable agent name (ACP: the host's profile name).
    pub provider_name: String,
    /// ACP agent profile id from the host; empty for Codex or when unknown.
    pub profile_id: String,
    /// Whether the values come from a live ACP negotiation.
    pub negotiated: bool,
    /// Host generation the values belong to (ACP; 0 otherwise). A change
    /// invalidates cached capabilities and session settings.
    pub generation: u64,
    /// Native live voice calls.
    pub voice: bool,
    /// Native composer dictation.
    pub dictation: bool,
    /// Image attachments in prompts.
    pub image_input: bool,
    /// Supplementing a running turn (`turn/steer`).
    pub steer: bool,
    /// Renaming sessions.
    pub rename: bool,
    /// Manual compaction.
    pub compact: bool,
    /// Working-tree diff.
    pub git_diff: bool,
    /// A service-wide model catalog for the model picker.
    pub model_catalog: bool,
    /// Per-session agent options (ACP select options / modes).
    pub session_config: bool,
    /// Approvals carry the agent's own options, answered by option id.
    pub permission_options: bool,
    /// Native slash-command catalog.
    pub commands: bool,
    /// Model, variant and agent choices before creating a session.
    pub draft_options: bool,
    /// Native questions can accept multiple choices.
    pub question_multiple: bool,
    /// The provider supports a textual permission rejection explanation.
    pub permission_feedback: bool,
    /// Native thread metadata (Guardian pre-resume checks).
    pub native_metadata: bool,
    /// How earlier sessions reopen: `native`, `load`, `resume`, `none` or
    /// `unknown`.
    pub session_reopen: String,
    /// Source of the session list: `native`, `agent` or `host`.
    pub session_list: String,
    /// `full` or `retained` (only what the host still holds).
    pub history_scope: String,
    /// Running-session inventory: `meta`, `engine` or `none`.
    pub running_inventory: String,
    /// The agent reported that authentication is required.
    pub auth_required: bool,
}

/// Capabilities of the connection behind `service_key` (no network). Codex
/// is fixed; ACP reflects the host's current negotiation and
/// is conservative until connected.
#[frb(sync)]
pub fn app_capabilities(service_key: String) -> AppCapabilitiesDto {
    let c = engine(&service_key).capabilities(&service_key);
    AppCapabilitiesDto {
        provider: c.provider,
        fast: c.fast,
        permission_presets: c.permission_presets,
        guardian: c.guardian,
        rate_limits: c.rate_limits,
        takeover: c.takeover,
        external_writer_monitor: c.external_writer_monitor,
        local_sessions: c.local_sessions,
        plan_mode: c.plan_mode,
        protocol: c.protocol,
        provider_name: c.provider_name,
        profile_id: c.profile_id,
        negotiated: c.negotiated,
        generation: c.generation,
        voice: c.voice,
        dictation: c.dictation,
        image_input: c.image_input,
        steer: c.steer,
        rename: c.rename,
        compact: c.compact,
        git_diff: c.git_diff,
        model_catalog: c.model_catalog,
        session_config: c.session_config,
        permission_options: c.permission_options,
        commands: c.commands,
        draft_options: c.draft_options,
        question_multiple: c.question_multiple,
        permission_feedback: c.permission_feedback,
        native_metadata: c.native_metadata,
        session_reopen: c.session_reopen,
        session_list: c.session_list,
        history_scope: c.history_scope,
        running_inventory: c.running_inventory,
        auth_required: c.auth_required,
    }
}

/// Ids of sessions executing now, from the engine itself (ACP).
/// Codex lists them through the meta service instead.
pub async fn app_running_threads(service_key: String) -> Result<Vec<String>> {
    execution::run(Lane::Read, move || engine(&service_key).running_threads(&service_key)).await
}
