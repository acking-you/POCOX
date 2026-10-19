//! Agent tools: one MCP server, `pocox`, that lets any harness see the
//! user's devices and services, share a local port with the user's other
//! devices, and connect to a service elsewhere. See `docs/agent-tools.md`.
//!
//! ```text
//!   harness ──HTTP MCP (bearer)──► endpoint (127.0.0.1) ─┐
//!   pocox CLI ──/local/v1────────► endpoint              ├─► shares / connections ─► relay
//!   other devices ──relay──► management entry /services/v1 (catalog, events, answers)
//! ```
//!
//! The process that owns this machine's relay registrations (the desktop app,
//! or the CLI host) serves it. Phones only read other devices' catalogs and
//! connect to their shares.

pub mod builtin;
pub mod catalog;
pub mod connections;
mod consent;
pub mod error;
pub mod harness;
pub mod inject;
pub mod model;
pub mod render;
pub mod routes;
pub mod settings;
pub mod shares;
mod state;
pub mod tokens;
pub mod watch;

#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub mod endpoint;
#[cfg(not(any(target_os = "ios", target_os = "android")))]
mod mcp;

use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
    time::Duration,
};

use anyhow::Result;
use serde::{Deserialize, Serialize};
use tokio::task::JoinHandle;

pub use self::tokens::TokenView;
use self::{state::OwnerKey, tokens::Principal};
use crate::engine::{host_owner, host_profiles, runtime};

/// Whether this platform can serve the tools (desktops and the CLI host).
pub fn supported() -> bool {
    !cfg!(any(target_os = "ios", target_os = "android"))
}

static STARTED: AtomicBool = AtomicBool::new(false);
static STOPPING: AtomicBool = AtomicBool::new(false);
static SUPERVISOR: Mutex<Option<JoinHandle<()>>> = Mutex::new(None);
static WAKE: once_cell::sync::Lazy<tokio::sync::Notify> =
    once_cell::sync::Lazy::new(tokio::sync::Notify::new);

/// The tools on this installation, safe to show.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    /// This platform can serve them.
    pub supported: bool,
    /// This process serves them.
    pub hosting: bool,
    /// The user's switch.
    pub enabled: bool,
    /// Agents' first shares need the user's answer.
    pub ask_before_sharing: bool,
    /// The MCP URL while serving.
    pub endpoint: Option<String>,
    /// Why they are not serving, or what changed.
    pub problem: Option<String>,
    /// Ports shared now.
    pub shared_ports: usize,
    /// Connections now.
    pub connections: usize,
}

/// The current status.
pub fn status() -> Status {
    let state = state::lock();
    Status {
        supported: supported(),
        hosting: state.hosting,
        enabled: state.settings.enabled,
        ask_before_sharing: state.settings.ask_before_sharing,
        endpoint: state
            .endpoint
            .as_ref()
            .filter(|_| state.settings.enabled)
            .map(|base| format!("{}/mcp", base.trim_end_matches('/'))),
        problem: state.problem.clone(),
        shared_ports: state.shared_ports(),
        connections: state.connections.len(),
    }
}

/// End what the `revoked` callers shared or connected, and their requests
/// waiting for the user. A token withdrawn unused (a launch that adopted a
/// running instance, a session request the agent refused) ends only this:
/// the instance or session it was minted for may still run.
fn ended(revoked: &[Principal]) {
    if revoked.is_empty() {
        return;
    }
    let ids: Vec<&str> = revoked.iter().map(|p| p.id.as_str()).collect();
    let gone = |key: &OwnerKey| ids.contains(&key.token.as_str());
    consent::withdraw(gone);
    shares::end_owned(gone);
    connections::end_owned(gone);
}

/// The holders of `revoked` are gone: an instance stopped or started afresh,
/// a session closed, or the user revoked the token. Besides [`ended`], what
/// the user handed them from the composer ends.
fn retired(revoked: &[Principal]) {
    if revoked.is_empty() {
        return;
    }
    ungrant(&mut state::lock().granted, revoked);
    ended(revoked);
}

/// Drop the grants of a hosted instance among `gone`, and of a session.
fn ungrant(granted: &mut std::collections::HashSet<state::Granted>, gone: &[Principal]) {
    granted.retain(|granted| {
        !gone.iter().any(|p| {
            p.host.as_deref() == Some(granted.host.as_str())
                && match p.kind {
                    tokens::Kind::Hosted => true,
                    tokens::Kind::Session => {
                        p.session.as_deref() == granted.conversation.as_deref()
                    },
                    _ => false,
                }
        })
    });
}

/// End everything agents made, their waiting requests and the user's
/// approvals (the switch went off, or the account or relay changed).
fn end_agents() {
    consent::withdraw(|_| true);
    {
        let mut state = state::lock();
        state.allowed.clear();
        state.granted.clear();
        state.declined.clear();
    }
    shares::end_owned(|_| true);
    connections::end_owned(|_| true);
}

/// Start serving the tools in this process. Idempotent; phones return at
/// once, and a second app on the hosting state leaves them to the first.
pub fn initialize() {
    if !supported() || STOPPING.load(Ordering::SeqCst) || STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    if host_owner::require().is_err() {
        state::lock().problem = Some(ELSEWHERE.into());
        return;
    }
    if let Err(error) = open() {
        tracing::warn!("agent tools unavailable: {error:#}");
        state::lock().problem = Some("The agent tools could not read their settings.".into());
        return;
    }
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    serving::reconcile();
    *SUPERVISOR.lock().unwrap_or_else(|p| p.into_inner()) =
        Some(runtime::runtime().spawn(supervise()));
}

fn open() -> Result<()> {
    let dir = host_profiles::root()?.join("agent-tools");
    let tokens = tokens::Tokens::open(&dir)?;
    // Unreadable settings never switch the tools on: the user may have
    // switched them off.
    let settings = settings::load();
    // The user's shares last until stopped: an unreadable file is set aside
    // for them, never overwritten.
    let (saved, blocked) = match state::saved_shares(&dir) {
        Ok(saved) => (saved, false),
        Err(error) => match state::set_aside_shares(&dir) {
            Ok(aside) => {
                tracing::warn!("saved shares unreadable, kept at {}: {error:#}", aside.display());
                (Vec::new(), false)
            },
            Err(moved) => {
                tracing::warn!("saved shares unreadable and kept in place: {error:#}; {moved}");
                (Vec::new(), true)
            },
        },
    };
    {
        let mut state = state::lock();
        state.shares_blocked = blocked;
        state.dir = Some(dir);
        state.tokens = tokens;
        state.hosting = true;
        match settings {
            Ok(settings) => state.settings = settings,
            Err(error) => {
                tracing::warn!("agent tools stay off: {error:#}");
                state.settings = settings::Settings::closed();
                state.settings_unreadable = true;
                state.problem = Some(UNREADABLE.into());
            },
        }
    }
    shares::restore(saved);
    Ok(())
}

const UNREADABLE: &str = "The agent tools setting could not be read, so the tools stay off. \
                          Switch them on again to save it anew.";

const ELSEWHERE: &str =
    "Another POCOX app on this computer serves the agent tools; use them there.";

async fn supervise() {
    let mut tick: u64 = 0;
    loop {
        if STOPPING.load(Ordering::SeqCst) {
            return;
        }
        if let Ok(Ok(saved)) = tokio::task::spawn_blocking(settings::load).await {
            apply(saved);
        }
        #[cfg(not(any(target_os = "ios", target_os = "android")))]
        let _ = tokio::task::spawn_blocking(serving::reconcile).await;
        if tick.is_multiple_of(2) {
            let _ = tokio::task::spawn_blocking(catalog::refresh_services).await;
        }
        shares::maintain(tick.is_multiple_of(3));
        retry_saves();
        connections::prune();
        consent::prune(&mut state::lock());
        tick = tick.wrapping_add(1);
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(2)) => {},
            _ = WAKE.notified() => {},
        }
    }
}

/// Save again what could not be saved: a revocation or a stopped share must
/// reach the disk, or a restart would bring it back.
fn retry_saves() {
    let mut state = state::lock();
    if let Err(error) = state.tokens.flush() {
        tracing::debug!("agent tool tokens still not saved: {error:#}");
    }
    if state.shares_unsaved {
        let _ = state.save_shares();
    }
}

/// Take `saved` as the current settings, ending agents' work when the
/// switch went off.
fn apply(saved: settings::Settings) {
    let mut state = state::lock();
    if std::mem::take(&mut state.settings_unreadable) {
        if state.problem.as_deref() == Some(UNREADABLE) {
            state.problem = None;
        }
        state::changed(&mut state);
    }
    let was = state.settings;
    if was == saved {
        return;
    }
    state.settings = saved;
    if !saved.ask_before_sharing {
        state.allowed.clear();
        state.granted.clear();
    }
    state::changed(&mut state);
    drop(state);
    if was.ask_before_sharing && !saved.ask_before_sharing {
        // Nothing waits for an answer any more: those calls go ahead now.
        consent::withdraw(|_| true);
    }
    if was.enabled && !saved.enabled {
        tracing::info!("agent tools switched off; ending what agents shared");
        end_agents();
    }
}

/// Switch the tools on or off on this installation.
pub fn set_enabled(enabled: bool) -> Result<Status> {
    host_owner::require()?;
    let saved = settings::update(|s| s.enabled = enabled)?;
    apply(saved);
    WAKE.notify_one();
    Ok(status())
}

/// Ask (or not) before an agent's first share.
pub fn set_ask_before_sharing(ask: bool) -> Result<Status> {
    host_owner::require()?;
    let saved = settings::update(|s| s.ask_before_sharing = ask)?;
    apply(saved);
    Ok(status())
}

/// Tokens issued on this installation.
pub fn tokens() -> Vec<TokenView> {
    state::lock().tokens.list()
}

/// A token issued to a harness the user installs the tools into, with the
/// endpoint it reaches.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Issued {
    /// The MCP URL.
    pub url: String,
    /// The token (shown once).
    pub token: String,
    /// Its id, for revoking.
    pub id: String,
}

fn harness_label(harness: &str) -> &str {
    match harness {
        "codex" => "Codex",
        "claude" => "Claude Code",
        "opencode" => "OpenCode",
        _ => "MCP client",
    }
}

/// Issue a token for `harness` (`codex`, `claude`, `opencode` or another
/// MCP client).
pub fn issue(harness: &str, label: Option<&str>) -> Result<Issued> {
    host_owner::require()?;
    let url = status()
        .endpoint
        .ok_or_else(|| anyhow::anyhow!("the agent tools are switched off on this device"))?;
    let label = label.unwrap_or_else(|| harness_label(harness));
    let (principal, token) =
        state::lock()
            .tokens
            .mint(tokens::Kind::Installed, label, Some(harness), None)?;
    Ok(Issued {
        url,
        token,
        id: principal.id,
    })
}

/// Revoke a token; what its holder shared or connected ends. Fails, changing
/// nothing, when the revocation cannot be saved.
pub fn revoke(id: &str) -> Result<()> {
    host_owner::require()?;
    let revoked = state::lock().tokens.revoke_where(|p| p.id == id)?;
    retired(&revoked);
    Ok(())
}

fn host_key(device: &str) -> String {
    pocket_codex_core::service::ServiceId::new(
        device,
        pocket_codex_core::service::ServiceKind::Host,
        "pocket",
    )
    .key()
}

fn is_local(device: &str) -> bool {
    state::lock().hosting && runtime::device_id().is_ok_and(|id| id == device)
}

fn on_device(device: &str, segments: &[&str], body: serde_json::Value) -> Result<()> {
    let _: serde_json::Value = crate::engine::management_client::request(
        &host_key(device),
        reqwest::Method::POST,
        segments,
        Some(&body),
    )?;
    Ok(())
}

/// The user picked built-in `tools` in the composer for `conversation` of
/// the agent service `service` hosted here: the gated ones are granted to
/// that conversation, as if the user had answered Allow in this conversation
/// (to the whole instance for a harness that names no conversation, native
/// OpenCode), and its requests waiting for an answer go ahead. Nothing is
/// recorded while agents share without asking: switching asking on again
/// must not find an earlier pick standing in for an answer. `epoch` binds a
/// request from another device to the account or relay it was made for.
pub fn grant(
    service: &str,
    conversation: &str,
    tools: &[String],
    epoch: Option<u64>,
) -> Result<(), error::ToolError> {
    let (device, host, conversation) = grant_target(service, conversation)?;
    if runtime::device_id().ok().as_deref() != Some(device.as_str()) {
        return Err(error::ToolError::NotFound(format!("`{}`", model::bounded(service))));
    }
    let gated: Vec<String> = builtin::catalog()
        .into_iter()
        .filter(|tool| tool.gated && tools.contains(&tool.id))
        .map(|tool| tool.id)
        .collect();
    let mut state = state::lock();
    if !state.hosting {
        return Err(error::ToolError::NotHosting);
    }
    if !state.settings.enabled {
        return Err(error::ToolError::Off);
    }
    if epoch.is_some_and(|epoch| !crate::engine::transport::is_current(epoch)) {
        return Err(error::ToolError::ContextChanged);
    }
    if gated.is_empty() || !state.settings.ask_before_sharing {
        return Ok(());
    }
    for tool in &gated {
        state.granted.insert(state::Granted {
            host: host.clone(),
            conversation: conversation.clone(),
            tool: tool.clone(),
        });
    }
    let woken = consent::settle_granted(&mut state, &host, conversation.as_deref(), &gated);
    state::changed(&mut state);
    drop(state);
    for answered in woken {
        answered.notify_waiters();
    }
    Ok(())
}

/// Where a grant for `conversation` of `service` applies: the device, the
/// hosted instance, and the conversation its agents name, in the form their
/// calls carry it (none for native OpenCode, whose instance is the owner).
/// Only agent hosts take grants.
fn grant_target(
    service: &str,
    conversation: &str,
) -> Result<(String, String, Option<String>), error::ToolError> {
    use pocket_codex_account_proto::key::NamespacedServiceId;
    use pocket_codex_core::service::{ServiceId, ServiceKind};
    let id = ServiceId::parse_key(service)
        .or_else(|| NamespacedServiceId::parse_key(service).map(|id| id.service))
        .ok_or_else(|| error::ToolError::Invalid("Not a service key.".into()))?;
    let conversation = match id.kind {
        ServiceKind::OpenCode => None,
        // Codex names its thread in each call's `_meta`, read bounded.
        ServiceKind::App => Some(model::bounded(conversation)),
        // An ACP session's token is bound to its exact id.
        ServiceKind::Acp if conversation.len() <= model::MAX_SESSION_ID => {
            Some(conversation.to_string())
        },
        ServiceKind::Acp => return Err(error::ToolError::Invalid("Not a session id.".into())),
        _ => return Err(error::ToolError::Invalid("Not an agent host.".into())),
    };
    if conversation.as_deref().is_some_and(str::is_empty) {
        return Err(error::ToolError::Invalid("No conversation.".into()));
    }
    Ok((id.device, model::bounded(&id.name), conversation))
}

/// [`grant`] on `device`, from any of the user's devices.
pub fn grant_on(device: &str, service: &str, conversation: &str, tools: &[String]) -> Result<()> {
    if is_local(device) {
        return grant(service, conversation, tools, None).map_err(Into::into);
    }
    on_device(
        device,
        &["services", "v1", "grants"],
        serde_json::json!({ "service": service, "conversation": conversation, "tools": tools }),
    )
}

/// Answer consent request `id` of `device`, from any of the user's devices.
pub fn answer_on(device: &str, id: &str, decision: model::Decision) -> Result<()> {
    if is_local(device) {
        return consent::answer(id, decision).map_err(Into::into);
    }
    on_device(
        device,
        &["services", "v1", "consents", id],
        serde_json::json!({ "decision": decision }),
    )
}

/// Share `ports` of `device` as the user (this device directly, another one
/// through its management entry).
pub fn share_on(
    device: &str,
    ports: Vec<u16>,
    title: Option<String>,
    path: Option<String>,
    secure: bool,
) -> Result<model::Shared> {
    if is_local(device) {
        let request = shares::ShareRequest {
            ports,
            title,
            path,
            wait_ready_seconds: Some(5),
            secure,
            epoch: None,
        };
        let shared =
            runtime::runtime().block_on(shares::share(&shares::Caller::user("You"), request));
        return match shared {
            Ok(Ok(shared)) => Ok(shared),
            Ok(Err(pending)) => Err(anyhow::anyhow!(pending.message())),
            Err(error) => Err(anyhow::anyhow!(error.message())),
        };
    }
    let body =
        serde_json::json!({ "ports": ports, "title": title, "path": path, "secure": secure });
    crate::engine::management_client::request(
        &host_key(device),
        reqwest::Method::POST,
        &["services", "v1", "shares"],
        Some(&body),
    )
}

/// Stop share `id` of `device`, as the user.
pub fn stop_on(device: &str, id: &str) -> Result<()> {
    if is_local(device) {
        return shares::stop(None, id).map(drop).map_err(Into::into);
    }
    on_device(device, &["services", "v1", "shares", id, "stop"], serde_json::json!({}))
}

/// Keep share `id` of `device` until the user stops it.
pub fn keep_on(device: &str, id: &str) -> Result<()> {
    if is_local(device) {
        return shares::keep(id).map(drop).map_err(Into::into);
    }
    on_device(device, &["services", "v1", "shares", id, "keep"], serde_json::json!({}))
}

/// The account or relay changed: connections belong to the old one, and so
/// do agents' shares and the user's answers (they were for another audience).
/// The user's own shares are published again under the new one by the
/// supervisor, as hosts are.
pub fn context_changed() {
    connections::context_changed();
    end_agents();
    WAKE.notify_one();
}

/// Stop serving on quit. Shares the user made are restored on the next
/// start; everything else ends.
pub fn stop() {
    STOPPING.store(true, Ordering::SeqCst);
    if let Some(task) = SUPERVISOR.lock().unwrap_or_else(|p| p.into_inner()).take() {
        task.abort();
    }
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    serving::stop();
    let ports: Vec<state::SharedPort> = {
        let mut state = state::lock();
        state.hosting = false;
        state
            .shares
            .drain(..)
            .flat_map(|share| share.ports)
            .collect()
    };
    let published: Vec<_> = ports.into_iter().filter_map(|p| p.published).collect();
    if !published.is_empty() && tokio::runtime::Handle::try_current().is_err() {
        runtime::runtime().block_on(async {
            let stops = futures::future::join_all(published.into_iter().map(|p| p.stop()));
            let _ = tokio::time::timeout(Duration::from_secs(3), stops).await;
        });
    }
    connections::context_changed();
}

/// The endpoint's lifetime: serving while this process hosts.
#[cfg(not(any(target_os = "ios", target_os = "android")))]
mod serving {
    use std::sync::Mutex;

    use tokio::task::JoinHandle;
    use tokio_util::sync::CancellationToken;

    use super::{endpoint, settings, state};
    use crate::engine::runtime;

    struct Serving {
        base: String,
        cancel: CancellationToken,
        task: JoinHandle<()>,
    }

    impl Drop for Serving {
        fn drop(&mut self) {
            self.cancel.cancel();
            self.task.abort();
        }
    }

    static SERVING: Mutex<Option<Serving>> = Mutex::new(None);

    fn preferred() -> u16 {
        if runtime::host_profiles_dir().is_some() {
            endpoint::CLI_PORT
        } else {
            endpoint::APP_PORT
        }
    }

    /// Keep the endpoint serving (it refuses agents while the switch is
    /// off). Blocking.
    pub fn reconcile() {
        let (saved, dir) = {
            let state = state::lock();
            (state.settings.port, state.dir.clone())
        };
        let mut serving = SERVING.lock().unwrap_or_else(|p| p.into_inner());
        if serving.as_ref().is_some_and(|s| !s.task.is_finished()) {
            return;
        }
        let listener = match endpoint::bind(saved, preferred()) {
            Ok(listener) => listener,
            Err(error) => {
                tracing::warn!("agent tools endpoint unavailable: {error:#}");
                state::lock().problem =
                    Some("No loopback port is free for the agent tools.".into());
                return;
            },
        };
        let Ok(addr) = listener.local_addr() else { return };
        let base = format!("http://127.0.0.1:{}", addr.port());
        let moved = saved.is_some_and(|port| port != addr.port());
        if saved != Some(addr.port()) {
            if let Err(error) = settings::update(|s| s.port = Some(addr.port())) {
                tracing::warn!("agent tools port not saved: {error:#}");
            }
        }
        let cancel = CancellationToken::new();
        let secret = endpoint::new_secret();
        let app = endpoint::router(addr.port(), cancel.clone(), secret.as_str().into());
        let task = runtime::runtime().spawn(crate::engine::host_services::supervise(
            "agent tools",
            addr,
            listener,
            move |listener| {
                let app = app.clone();
                async move {
                    axum::serve(listener, app)
                        .await
                        .map_err(anyhow::Error::from)
                }
            },
        ));
        if let Some(dir) = &dir {
            if let Err(error) = endpoint::announce(dir, &base, &secret) {
                tracing::warn!("agent tools endpoint not announced: {error:#}");
            }
        }
        tracing::info!(endpoint = %base, "agent tools serving");
        let mut state = state::lock();
        state.endpoint = Some(base.clone());
        state.problem = moved.then(|| {
            format!(
                "Port {} was taken, so the agent tools moved to {}. Install the tools in other \
                 harnesses again.",
                saved.unwrap_or_default(),
                addr.port()
            )
        });
        state::changed(&mut state);
        *serving = Some(Serving {
            base,
            cancel,
            task,
        });
    }

    /// Stop serving and withdraw the discovery file.
    pub fn stop() {
        let gone = SERVING.lock().unwrap_or_else(|p| p.into_inner()).take();
        if let Some(serving) = gone {
            tracing::info!(endpoint = %serving.base, "agent tools stopped");
        }
        let dir = state::lock().dir.clone();
        if let Some(dir) = dir {
            endpoint::withdraw(&dir);
        }
        state::lock().endpoint = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_grant_names_the_conversation_its_harness_reports() {
        let conversation = |service: &str, id: &str| grant_target(service, id).ok().map(|t| t.2);
        assert_eq!(
            grant_target("pcx:studio:app:live", "t1").ok(),
            Some(("studio".into(), "live".into(), Some("t1".into())))
        );
        assert_eq!(conversation("pcxu:u1:studio:acp:claude", "s1"), Some(Some("s1".into())));
        // Native OpenCode names no conversation: its instance is the owner.
        assert_eq!(conversation("pcx:studio:opencode:oc", "ses_1"), Some(None));
        assert_eq!(conversation("pcx:studio:port:5173", "t1"), None, "not an agent host");
        assert_eq!(conversation("pcx:studio:app:live", ""), None, "no conversation");
        // An ACP session's token holds its id exactly, however long.
        let long = format!("ses_{}", "x".repeat(600));
        assert_eq!(conversation("pcx:studio:acp:claude", &long), Some(Some(long.clone())));
        let too_long = "x".repeat(model::MAX_SESSION_ID + 1);
        assert_eq!(conversation("pcx:studio:acp:claude", &too_long), None);
    }
}
