//! Local hosting (desktop): run and manage local Codex app-server and ACP agent
//! hosts, the in-app equivalent of `pocox serve`.

use super::*;

/// Result of starting local hosting, mirrored for Dart. One host publishes two
/// tunnels (`app:<name>` remote control + `api:<name>` Responses proxy).
pub struct AppServeDto {
    /// Device id both services registered under.
    pub device: String,
    /// Service instance name (shared by the app + api tunnels).
    pub name: String,
    /// `pcx:<device>:app:<name>` key (what discovery + `app_connect` use).
    pub app_service_key: String,
    /// Loopback `host:port` codex is listening on.
    pub app_listen_addr: String,
    /// `pcx:<device>:api:<name>` key (what an `api connect` resolves).
    pub api_service_key: String,
    /// Loopback `host:port` the in-app Responses API proxy is listening on.
    pub api_listen_addr: String,
    /// `pcx:<device>:meta:<name>` key (the host meta service tunnel).
    pub meta_service_key: String,
    /// Loopback `host:port` the in-app meta service is listening on.
    pub meta_listen_addr: String,
    /// The codex process id.
    pub pid: u32,
    /// Whether an already-running host was reused instead of freshly spawned.
    pub reused: bool,
}

/// Status of one local host (a Codex app-server or an ACP agent gateway),
/// mirrored for Dart. Each host carries its tunnels' publish state so the UI
/// can offer per-tunnel 注销 / 重新注册.
pub struct AppServeStatusDto {
    /// Service instance name.
    pub name: String,
    /// Device id.
    pub device: String,
    /// codex process id; `None` for ACP hosts.
    pub pid: Option<u32>,
    /// codex is accepting on its listen port; for ACP, the agent is ready.
    pub alive: bool,
    /// Loopback `host:port` codex (or the ACP gateway) listens on.
    pub app_listen_addr: String,
    /// `pcx:<device>:app:<name>` key, or `pcx:<device>:acp:<name>` for ACP.
    pub app_service_key: String,
    /// The app tunnel is currently published.
    pub app_registered: bool,
    /// Loopback `host:port` the API proxy listens on.
    pub api_listen_addr: String,
    /// `pcx:<device>:api:<name>` key.
    pub api_service_key: String,
    /// The api tunnel is currently published.
    pub api_registered: bool,
    /// Loopback `host:port` the meta service listens on.
    pub meta_listen_addr: String,
    /// `pcx:<device>:meta:<name>` key.
    pub meta_service_key: String,
    /// The meta tunnel is currently published.
    pub meta_registered: bool,
    /// Legacy runtime flag; always false for external Codex hosts.
    pub embedded: bool,
    /// The resolved external codex binary path.
    pub codex_binary: Option<String>,
    /// Upstream proxy codex + the API proxy were started with, or `None` when
    /// they inherit the app's environment.
    pub proxy: Option<String>,
    /// Service provider family of this host: `codex` or `acp`.
    /// For `acp` the `app_*` fields describe the gateway and
    /// `api_*` are empty.
    pub provider: String,
    /// Provider version when known (ACP agents).
    pub provider_version: Option<String>,

    /// Wire protocol: `codex-app-server` or `acp`.
    pub protocol: String,
    /// Human-readable provider / agent name.
    pub provider_name: String,
    /// ACP agent profile id.
    pub profile_id: Option<String>,
    /// ACP agent phase: `starting`, `ready`, `failed` or `stopped`.
    pub agent_phase: Option<String>,
    /// Why the ACP agent is not running, safe to show.
    pub agent_error: Option<String>,
    /// The ACP agent reported that authentication is required.
    pub auth_required: bool,
    /// Native OpenCode runtime and sanitized catalog summary.
    pub opencode: Option<OpenCodeHostStatusDto>,
    /// Where the running host gets its model service, as launched:
    /// `inherited`, `official` or `custom`.
    pub config_source: Option<String>,
    /// The saved configuration revision the running host was launched with;
    /// compare with [`HostConfigDto::revision`] to show "restart to apply".
    pub config_revision: Option<u64>,
    /// This run's identity; it changes whenever the host is started again.
    /// Pass it to `app_serve_apply` so a replaced host is never restarted.
    pub incarnation: Option<String>,
    /// A lifecycle operation holds this host now: `starting`, `stopping`,
    /// `restarting` or `applying`; `None` when idle.
    pub busy: Option<String>,
}

/// Native OpenCode runtime and sanitized service-default catalog summary.
pub struct OpenCodeHostStatusDto {
    /// Installed executable version.
    pub version: String,
    /// Connected native provider count.
    pub providers_connected: u32,
    /// Usable native model count.
    pub models: u32,
    /// Global default when actually exposed by the native API.
    pub default_model: Option<String>,
    /// Visible primary native agents.
    pub agents: Vec<String>,
    /// Safe runtime or catalog diagnostic.
    pub problem: Option<String>,
    /// The host keeps its sessions in a database of its own, not in
    /// OpenCode's default one.
    pub separate_history: bool,
}
impl From<crate::engine::serve_opencode::OpenCodeStatus> for OpenCodeHostStatusDto {
    fn from(s: crate::engine::serve_opencode::OpenCodeStatus) -> Self {
        Self {
            version: s.version,
            providers_connected: s.providers_connected,
            models: s.models,
            default_model: s.default_model,
            agents: s.agents,
            problem: s.problem,
            separate_history: s.separate_history,
        }
    }
}

/// Refresh one running OpenCode host's sanitized native catalog summary.
pub fn opencode_refresh(name: String) -> Result<()> {
    crate::engine::serve_opencode::refresh_catalog(&name)
}

/// Installed external OpenCode; detection never starts or resumes a session.
pub struct OpenCodeEnvironmentDto {
    /// Resolved executable path.
    pub path: Option<String>,
    /// Native executable version.
    pub version: Option<String>,
    /// Installation or inspection failure, safe to show.
    pub problem: Option<String>,
}

/// Inspect an explicit OpenCode executable or the host's child PATH.
pub fn opencode_detect(binary: Option<String>) -> OpenCodeEnvironmentDto {
    match crate::engine::serve_opencode::detect(binary.as_deref()) {
        Ok((path, version)) => OpenCodeEnvironmentDto {
            path: Some(path),
            version: Some(version),
            problem: None,
        },
        Err(error) => OpenCodeEnvironmentDto {
            path: None,
            version: None,
            problem: Some(error.to_string()),
        },
    }
}

/// An ACP agent executable and argument vector, passed verbatim without a
/// shell.
pub struct AcpAgentSpecDto {
    /// Profile id (`claude` for the preset, or a custom id).
    pub profile_id: String,
    /// Name shown in the UI.
    pub display_name: String,
    /// Executable: an explicit path, or a bare name searched on `PATH`.
    pub program: String,
    /// Arguments, one entry per argument.
    pub args: Vec<String>,
}

impl AcpAgentSpecDto {
    pub(super) fn into_spec(self) -> pocket_codex_host_svc::acp::AgentSpec {
        pocket_codex_host_svc::acp::AgentSpec {
            profile_id: self.profile_id,
            display_name: self.display_name,
            program: self.program,
            args: self.args,
        }
    }
}

/// A built-in ACP agent preset.
pub struct AcpPresetDto {
    /// Profile id.
    pub id: String,
    /// Display name.
    pub display_name: String,
    /// Bare executable name.
    pub program: String,
    /// Default arguments.
    pub args: Vec<String>,
}

/// Result of hosting an ACP agent.
pub struct AcpServeDto {
    /// Device id the services registered under.
    pub device: String,
    /// Instance name.
    pub name: String,
    /// `pcx:<device>:acp:<name>` key.
    pub service_key: String,
    /// Loopback gateway address.
    pub listen_addr: String,
    /// `pcx:<device>:meta:<name>` key.
    pub meta_service_key: String,
    /// Profile id.
    pub profile_id: String,
    /// Display name.
    pub display_name: String,
    /// Whether an existing host was reused.
    pub reused: bool,
}

/// Built-in ACP agent presets (Claude through its external stdio adapter).
#[frb(sync)]
pub fn acp_presets() -> Vec<AcpPresetDto> {
    pocket_codex_host_svc::acp::PRESETS
        .iter()
        .map(|preset| AcpPresetDto {
            id: preset.id.to_string(),
            display_name: preset.display_name.to_string(),
            program: preset.program.to_string(),
            args: preset.args.iter().map(|arg| arg.to_string()).collect(),
        })
        .collect()
}

/// Whether this device can host ACP agents (Unix desktops). Any device can
/// use a remote ACP host.
#[frb(sync)]
pub fn acp_hosting_supported() -> bool {
    serve_acp::hosting_supported()
}

/// Whether another POCOX app on this computer owned its hosting state when
/// this one started: this one then starts, restores and publishes nothing for
/// its whole run.
#[frb(sync)]
pub fn hosting_owned_elsewhere() -> bool {
    crate::engine::host_owner::owned_elsewhere()
}

/// The executable `program` resolves to (explicit path, `PATH`, then the
/// preset's install locations), or `None`.
pub fn acp_locate(program: String, profile_id: Option<String>) -> Option<String> {
    serve_acp::locate(&program, profile_id.as_deref()).map(|p| p.display().to_string())
}

/// The Claude preset's local environment, mirrored for Dart: paths and
/// versions only, never credentials.
pub struct AcpClaudeStatusDto {
    /// The preset can start now.
    pub ready: bool,
    /// `installed` / `prepared` / `missing`.
    pub adapter: String,
    /// The adapter executable.
    pub adapter_path: Option<String>,
    /// `found` / `tooOld` / `missing` / `notNeeded`.
    pub runtime: String,
    /// The Node.js version found (or the newest too-old one).
    pub runtime_version: Option<String>,
    /// The Node.js executable used.
    pub runtime_path: Option<String>,
    /// `inherited` / `found` / `missing` (the adapter's bundled CLI is used).
    pub cli: String,
    /// The native `claude` CLI handed to the adapter.
    pub cli_path: Option<String>,
    /// Start can prepare the pinned adapter first.
    pub can_prepare: bool,
    /// The npm package and version Start prepares.
    pub package: String,
    /// Why it cannot start, when it cannot.
    pub problem: Option<String>,
}

/// The preparation of Claude's pinned ACP adapter, mirrored for Dart.
pub struct AcpClaudeSetupDto {
    /// `idle` / `running` / `done` / `failed` / `cancelled`.
    pub state: String,
    /// `installing` / `downloading` / `verifying` while running.
    pub stage: Option<String>,
    /// Milliseconds since it started.
    pub elapsed_ms: u64,
    /// Actual package bytes received; absent when telemetry is unavailable.
    pub downloaded_bytes: Option<u64>,
    /// Recent measured package transfer rate, in bytes per second.
    pub download_bytes_per_second: Option<u64>,
    /// Why it failed (safe to show).
    pub error: Option<String>,
    /// The run this state belongs to (0 before any).
    pub run: u64,
    /// This call started [`Self::run`]; a call that joined one did not.
    pub started: bool,
}

fn setup_dto(snapshot: claude_setup::Snapshot) -> AcpClaudeSetupDto {
    AcpClaudeSetupDto {
        state: snapshot.state.to_string(),
        stage: snapshot.stage.map(str::to_string),
        elapsed_ms: snapshot.elapsed_ms,
        downloaded_bytes: snapshot.downloaded_bytes,
        download_bytes_per_second: snapshot.download_bytes_per_second,
        error: snapshot.error,
        run: snapshot.run,
        started: snapshot.started,
    }
}

/// Detect the adapter, a Node.js new enough for it and the native CLI
/// (runs `node --version` on candidates; nothing is installed or changed).
pub fn acp_claude_status() -> Result<AcpClaudeStatusDto> {
    let status = claude_setup::status()?;
    Ok(AcpClaudeStatusDto {
        ready: status.ready,
        adapter: status.adapter.to_string(),
        adapter_path: status.adapter_path,
        runtime: status.runtime.to_string(),
        runtime_version: status.runtime_version,
        runtime_path: status.runtime_path,
        cli: status.cli.to_string(),
        cli_path: status.cli_path,
        can_prepare: status.can_prepare,
        package: format!(
            "{}@{}",
            pocket_codex_host_svc::acp::claude::ADAPTER_PACKAGE,
            pocket_codex_host_svc::acp::claude::ADAPTER_VERSION
        ),
        problem: status.problem,
    })
}

/// Start preparing Claude's pinned ACP adapter in this app's cache (or join
/// the preparation already running) and return at once; detection runs in
/// the preparation. Poll [`acp_claude_prepare_state`]: a preparation that
/// cannot run here ends `failed` with the reason.
pub fn acp_claude_prepare_start() -> Result<AcpClaudeSetupDto> {
    Ok(setup_dto(claude_setup::prepare_start()))
}

/// Where the adapter preparation is.
#[frb(sync)]
pub fn acp_claude_prepare_state() -> AcpClaudeSetupDto {
    setup_dto(claude_setup::prepare_state())
}

/// Cancel the running adapter preparation; it stops only its own npm process.
#[frb(sync)]
pub fn acp_claude_prepare_cancel() -> AcpClaudeSetupDto {
    setup_dto(claude_setup::prepare_cancel())
}

/// Cancel preparation run `run` only (the one its caller started); a later
/// run started by another caller keeps going.
#[frb(sync)]
pub fn acp_claude_prepare_cancel_run(run: u64) -> AcpClaudeSetupDto {
    setup_dto(claude_setup::prepare_cancel_run(run))
}

/// Launch and host an ACP agent as `acp:<name>` plus `meta:<name>`. Works in
/// self-host and account mode. Stopping hosting stops the agent.
pub fn app_serve_start_acp(name: Option<String>, spec: AcpAgentSpecDto) -> Result<AcpServeDto> {
    let r = serve_acp::start(name, spec.into_spec())?;
    crate::engine::management::enable_after_hosting();
    Ok(AcpServeDto {
        device: r.device,
        name: r.name,
        service_key: r.service_key,
        listen_addr: r.listen_addr,
        meta_service_key: r.meta_service_key,
        profile_id: r.profile_id,
        display_name: r.display_name,
        reused: r.reused,
    })
}

/// Restart the agent of a local ACP host (new process, new generation).
pub fn app_serve_restart_acp(name: String) -> Result<()> {
    serve_acp::restart(&name)
}

/// Legacy version endpoint; returns `unavailable` because no engine is bundled.
pub fn embedded_codex_version() -> String {
    pocket_codex_codex::EMBEDDED_CODEX_COMMIT.to_string()
}

/// Start hosting a local codex app-server **and** Responses API proxy under the
/// signed-in account, publishing both `app:<name>` and `api:<name>`. Re-hosting
/// a name whose codex is still alive just re-registers any dropped tunnels.
/// `proxy` is the upstream proxy both use to reach chatgpt.com (`None` =
/// inherit env). Desktop only. `embedded` is retained for bridge compatibility;
/// passing true returns a built-in-engine-not-implemented error before startup.
pub fn app_serve_start(
    port: u16,
    binary_override: Option<String>,
    name: Option<String>,
    proxy: Option<String>,
    embedded: bool,
) -> Result<AppServeDto> {
    let r = serve::serve_start(port, binary_override, name, proxy, embedded)?;
    crate::engine::management::enable_after_hosting();
    Ok(AppServeDto {
        device: r.device,
        name: r.name,
        app_service_key: r.app_service_key,
        app_listen_addr: r.app_listen_addr,
        api_service_key: r.api_service_key,
        api_listen_addr: r.api_listen_addr,
        meta_service_key: r.meta_service_key,
        meta_listen_addr: r.meta_listen_addr,
        pid: r.pid,
        reused: r.reused,
    })
}

/// Snapshot of every local host (for the status cards + periodic re-probe).
pub fn app_serve_status() -> Vec<AppServeStatusDto> {
    serve::serve_status().into_iter().map(Into::into).collect()
}

impl From<serve::ServeStatus> for AppServeStatusDto {
    fn from(s: serve::ServeStatus) -> Self {
        Self {
            name: s.name,
            device: s.device,
            pid: s.pid,
            alive: s.alive,
            app_listen_addr: s.app_listen_addr,
            app_service_key: s.app_service_key,
            app_registered: s.app_registered,
            api_listen_addr: s.api_listen_addr,
            api_service_key: s.api_service_key,
            api_registered: s.api_registered,
            meta_listen_addr: s.meta_listen_addr,
            meta_service_key: s.meta_service_key,
            meta_registered: s.meta_registered,
            embedded: s.embedded,
            codex_binary: s.codex_binary,
            proxy: s.proxy,
            provider: s.provider,
            provider_version: s.provider_version,
            protocol: s.protocol,
            provider_name: s.provider_name,
            profile_id: s.profile_id,
            agent_phase: s.agent_phase,
            agent_error: s.agent_error,
            auth_required: s.auth_required,
            opencode: s.opencode.map(Into::into),
            config_source: s.config_source,
            config_revision: s.config_revision,
            incarnation: s.incarnation,
            busy: s.busy,
        }
    }
}

/// Take one tunnel (`kind` = `"app"`/`"api"`/`"meta"`) of a local host off the
/// relay without stopping the host — a reversible unpublish. The codex / API
/// proxy / meta service keep running; [`app_serve_reregister`] re-publishes it.
pub fn app_serve_deregister(name: String, kind: String) -> Result<()> {
    serve::serve_deregister(&name, &kind)
}

/// Re-publish a previously deregistered tunnel (`kind` = `"app"`/`"api"`/
/// `"meta"`) of a still-running local host.
pub fn app_serve_reregister(name: String, kind: String) -> Result<()> {
    serve::serve_reregister(&name, &kind)
}

/// Fully stop one local host by name (both tunnels + watchdog + API proxy, and
/// stops codex).
pub fn app_serve_stop(name: String) -> Result<()> {
    serve::serve_stop_remembered(&name, None)
}

/// Stop every local host (called on app quit so a real quit leaves no orphan
/// codex). A no-op when nothing is hosting. An error says what may still
/// run: the app must not exit as if it had stopped; calling it again retries.
pub fn app_serve_stop_all() -> Result<()> {
    serve::serve_stop_all()
}

/// The resolved `codex` binary path (persisted config → `$PATH`), or `None` so
/// the UI can prompt the user to point at one.
pub fn codex_locate() -> Option<String> {
    serve::codex_locate()
}
