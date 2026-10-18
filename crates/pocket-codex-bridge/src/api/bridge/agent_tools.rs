//! Agent tools: the switch, every device's services and shares, the user's
//! answers, and this device's connections to other devices' shares.

use super::*;
use crate::engine::agent_tools::{self as tools, connections, model, shares, tokens, watch};

/// The tools on this installation.
pub struct AgentToolsStatusDto {
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
    /// Safe explanation of a problem.
    pub problem: Option<String>,
    /// Ports shared now.
    pub shared_ports: u32,
    /// Connections now.
    pub connections: u32,
}

impl From<tools::Status> for AgentToolsStatusDto {
    fn from(s: tools::Status) -> Self {
        Self {
            supported: s.supported,
            hosting: s.hosting,
            enabled: s.enabled,
            ask_before_sharing: s.ask_before_sharing,
            endpoint: s.endpoint,
            problem: s.problem,
            shared_ports: u32::try_from(s.shared_ports).unwrap_or(u32::MAX),
            connections: u32::try_from(s.connections).unwrap_or(u32::MAX),
        }
    }
}

/// Who made a share or connection.
pub struct ToolsOwnerDto {
    /// `user` or `agent`.
    pub kind: String,
    /// Display name.
    pub label: String,
    /// The harness.
    pub harness: Option<String>,
    /// The hosted instance.
    pub host: Option<String>,
    /// The conversation (Codex thread or ACP session).
    pub conversation: Option<String>,
}

fn owner(o: model::OwnerView) -> ToolsOwnerDto {
    ToolsOwnerDto {
        kind: match o.kind {
            model::OwnerKind::User => "user",
            model::OwnerKind::Agent => "agent",
        }
        .into(),
        label: o.label,
        harness: o.harness,
        host: o.host,
        conversation: o.conversation,
    }
}

/// One shared port.
pub struct ToolsPortDto {
    /// Port number on the sharing device.
    pub port: u16,
    /// Relay key.
    pub key: String,
    /// `online`, `starting` or `unreachable`.
    pub status: String,
}

/// One share.
pub struct ToolsShareDto {
    /// Id on its device.
    pub id: String,
    /// Title.
    pub title: String,
    /// Path to open.
    pub path: String,
    /// The page is served over TLS (opened with `https`).
    pub secure: bool,
    /// Ports.
    pub ports: Vec<ToolsPortDto>,
    /// Who made it.
    pub owner: ToolsOwnerDto,
    /// Unix milliseconds.
    pub created_ms: i64,
    /// When it ends on its own; absent while kept.
    pub expires_ms: Option<i64>,
}

fn port_status(status: model::PortStatus) -> String {
    match status {
        model::PortStatus::Online => "online",
        model::PortStatus::Starting => "starting",
        model::PortStatus::Unreachable => "unreachable",
        model::PortStatus::Refused => "refused",
    }
    .into()
}

fn share(s: model::ShareView) -> ToolsShareDto {
    ToolsShareDto {
        id: s.id,
        title: s.title,
        path: s.path,
        secure: s.secure,
        ports: s
            .ports
            .into_iter()
            .map(|p| ToolsPortDto {
                port: p.port,
                key: p.key,
                status: port_status(p.status),
            })
            .collect(),
        owner: owner(s.owner),
        created_ms: s.created_ms,
        expires_ms: s.expires_ms,
    }
}

/// A share, or a connection to another device's Responses API, waiting for
/// the user's answer.
pub struct ToolsConsentDto {
    /// Answer with this id.
    pub id: String,
    /// Who asks.
    pub owner: ToolsOwnerDto,
    /// What would be shared, or the name of the service to connect.
    pub title: String,
    /// Which ports (none for a connection).
    pub ports: Vec<u16>,
    /// The key of the service to connect; none for a share.
    pub service: Option<String>,
    /// Unix milliseconds.
    pub created_ms: i64,
    /// When it lapses.
    pub expires_ms: i64,
}

/// One service of a device.
pub struct ToolsServiceDto {
    /// Relay key.
    pub key: String,
    /// `agent`, `api`, `port` or `host`.
    pub kind: String,
    /// Instance name (the port number for a shared port).
    pub name: String,
    /// The agent, for an agent host.
    pub agent: Option<String>,
    /// A shared port's title.
    pub title: Option<String>,
    /// A shared port's number.
    pub port: Option<u16>,
    /// `online`, `starting`, `unreachable` or `offline`.
    pub status: String,
    /// Who shared it.
    pub owner: Option<String>,
    /// The share it belongs to.
    pub share: Option<String>,
}

/// A built-in tool the composer can hand a conversation on a device.
pub struct ToolsBuiltinToolDto {
    /// Stable id (`services`, `share`, `connect`).
    pub id: String,
    /// English name, for an id this app does not know.
    pub title: String,
    /// What it lets the agent do, for an id this app does not know.
    pub summary: String,
    /// Picking it gives the user's consent for the conversation.
    pub gated: bool,
}

/// One device.
pub struct ToolsDeviceDto {
    /// Device id.
    pub name: String,
    /// Platform, when its catalog answered.
    pub platform: Option<String>,
    /// Something of it is on the relay.
    pub online: bool,
    /// Its catalog answered (newer POCOX).
    pub catalog: bool,
    /// Its tools switch, when known.
    pub tools_enabled: Option<bool>,
    /// Its services.
    pub services: Vec<ToolsServiceDto>,
    /// Its shares.
    pub shares: Vec<ToolsShareDto>,
    /// Its shares waiting for the user.
    pub consents: Vec<ToolsConsentDto>,
    /// Its built-in tools (none from an older POCOX).
    pub builtin_tools: Vec<ToolsBuiltinToolDto>,
}

/// A service of another device reachable here.
pub struct ToolsConnectionDto {
    /// The remote service's key.
    pub service: String,
    /// `127.0.0.1:<port>`.
    pub local: String,
    /// Whether it got the service's own port number.
    pub same_port: bool,
    /// Who keeps it.
    pub owner: ToolsOwnerDto,
    /// When it ends on its own.
    pub expires_ms: Option<i64>,
}

fn connection(c: model::ConnectionView) -> ToolsConnectionDto {
    ToolsConnectionDto {
        service: c.service,
        local: c.local,
        same_port: c.same_port,
        owner: owner(c.owner),
        expires_ms: c.expires_ms,
    }
}

/// Every device and service visible now.
pub struct ToolsOverviewDto {
    /// This device.
    pub this_device: String,
    /// This device first.
    pub devices: Vec<ToolsDeviceDto>,
    /// This device's connections.
    pub connections: Vec<ToolsConnectionDto>,
}

fn overview(o: model::Overview) -> ToolsOverviewDto {
    ToolsOverviewDto {
        this_device: o.this_device,
        devices: o
            .devices
            .into_iter()
            .map(|d| ToolsDeviceDto {
                name: d.name,
                platform: d.platform,
                online: d.online,
                catalog: d.catalog,
                tools_enabled: d.tools.map(|t| t.enabled),
                services: d
                    .services
                    .into_iter()
                    .map(|s| ToolsServiceDto {
                        key: s.key,
                        kind: s.kind,
                        name: s.name,
                        agent: s.agent,
                        title: s.title,
                        port: s.port,
                        status: s.status,
                        owner: s.owner,
                        share: s.share,
                    })
                    .collect(),
                shares: d.shares.into_iter().map(share).collect(),
                consents: d
                    .consents
                    .into_iter()
                    .map(|c| ToolsConsentDto {
                        id: c.id,
                        owner: owner(c.owner),
                        title: c.title,
                        ports: c.ports,
                        service: c.service,
                        created_ms: c.created_ms,
                        expires_ms: c.expires_ms,
                    })
                    .collect(),
                builtin_tools: d
                    .builtin
                    .into_iter()
                    .map(|t| ToolsBuiltinToolDto {
                        id: t.id,
                        title: t.title,
                        summary: t.summary,
                        gated: t.gated,
                    })
                    .collect(),
            })
            .collect(),
        connections: o.connections.into_iter().map(connection).collect(),
    }
}

/// Something new on a device.
pub struct ToolsRefDto {
    /// The device.
    pub device: String,
    /// The share or consent request.
    pub id: String,
}

/// One update of [`tools_watch`].
pub struct ToolsUpdateDto {
    /// Everything visible now.
    pub overview: ToolsOverviewDto,
    /// Shares announced since the previous update, this device's own
    /// included.
    pub added: Vec<ToolsRefDto>,
}

fn refs(items: Vec<(String, String)>) -> Vec<ToolsRefDto> {
    items
        .into_iter()
        .map(|(device, id)| ToolsRefDto {
            device,
            id,
        })
        .collect()
}

/// A share this device made.
pub struct ToolsSharedDto {
    /// The share.
    pub share: ToolsShareDto,
    /// `http://localhost:<port><path>`.
    pub on_this_machine: String,
    /// The `pocox://open` link.
    pub open: String,
    /// When it ends, in words.
    pub ends: String,
}

/// A token issued on this installation (never the token itself).
pub struct ToolsTokenDto {
    /// Revoke with this id.
    pub id: String,
    /// `user`, `hosted` or `installed`.
    pub kind: String,
    /// Display name.
    pub label: String,
    /// The harness.
    pub harness: Option<String>,
    /// Unix milliseconds.
    pub created_ms: i64,
}

/// The tools on this installation.
#[frb(sync)]
pub fn tools_status() -> AgentToolsStatusDto {
    tools::status().into()
}

/// Switch the tools on or off on this installation.
pub fn tools_set_enabled(enabled: bool) -> Result<AgentToolsStatusDto> {
    Ok(tools::set_enabled(enabled)?.into())
}

/// Ask (or not) before an agent's first share.
pub fn tools_set_ask_before_sharing(ask: bool) -> Result<AgentToolsStatusDto> {
    Ok(tools::set_ask_before_sharing(ask)?.into())
}

/// Every device and service visible now, read once.
pub fn tools_overview() -> Result<ToolsOverviewDto> {
    Ok(overview(tools::catalog::overview_blocking()?))
}

/// Follow every device's services and shares; ends when the Dart stream is
/// cancelled.
pub fn tools_watch(sink: StreamSink<ToolsUpdateDto>) -> Result<()> {
    runtime::runtime().spawn(watch::run(move |update: watch::Update| {
        sink.add(ToolsUpdateDto {
            overview: overview(update.overview),
            added: refs(update.added),
        })
        .is_ok()
    }));
    Ok(())
}

/// Answer a consent request of `device`: `allow_once`,
/// `allow_conversation` or `deny`.
pub fn tools_answer(device: String, consent_id: String, decision: String) -> Result<()> {
    let decision: model::Decision = serde_json::from_value(serde_json::Value::String(decision))
        .map_err(|_| anyhow!("unknown decision"))?;
    tools::answer_on(&device, &consent_id, decision)
}

/// Hand built-in `tools` the user picked in the composer to `conversation`
/// of agent service `service`, on whichever device hosts it: the gated ones
/// need no consent prompt in that conversation.
pub fn tools_grant(service: String, conversation: String, tools: Vec<String>) -> Result<()> {
    use pocket_codex_account_proto::key::NamespacedServiceId;
    use pocket_codex_core::service::ServiceId;
    let device = ServiceId::parse_key(&service)
        .or_else(|| NamespacedServiceId::parse_key(&service).map(|id| id.service))
        .map(|id| id.device)
        .ok_or_else(|| anyhow!("not a service key"))?;
    tools::grant_on(&device, &service, &conversation, &tools)
}

/// Stop a share of `device`, as the user.
pub fn tools_stop_share(device: String, share_id: String) -> Result<()> {
    tools::stop_on(&device, &share_id)
}

/// Keep a share of `device` until the user stops it.
pub fn tools_keep_share(device: String, share_id: String) -> Result<()> {
    tools::keep_on(&device, &share_id)
}

/// Share ports of this computer with the user's other devices.
pub fn tools_share(
    ports: Vec<u16>,
    title: Option<String>,
    path: Option<String>,
) -> Result<ToolsSharedDto> {
    let request = shares::ShareRequest {
        ports,
        title,
        path,
        wait_ready_seconds: Some(5),
        secure: false,
        epoch: None,
    };
    let caller = shares::Caller::user("You");
    match runtime::runtime().block_on(shares::share(&caller, request)) {
        Ok(Ok(shared)) => Ok(ToolsSharedDto {
            share: share(shared.share),
            on_this_machine: shared.on_this_machine,
            open: shared.open,
            ends: shared.ends,
        }),
        Ok(Err(pending)) => Err(anyhow!(pending.message())),
        Err(error) => Err(anyhow!(error.message())),
    }
}

/// Share `ports` of `device` as the user: this computer, or another of the
/// user's devices (Share and open on a `localhost` link; `secure` for an
/// `https://localhost` one).
pub fn tools_share_on(
    device: String,
    ports: Vec<u16>,
    title: Option<String>,
    path: Option<String>,
    secure: bool,
) -> Result<ToolsSharedDto> {
    let shared = tools::share_on(&device, ports, title, path, secure)?;
    Ok(ToolsSharedDto {
        share: share(shared.share),
        on_this_machine: shared.on_this_machine,
        open: shared.open,
        ends: shared.ends,
    })
}

/// Make another device's shared port or API reachable on this device, at
/// the same port number when it is free.
pub fn tools_connect(service: String, local_port: Option<u16>) -> Result<ToolsConnectionDto> {
    let request = connections::ConnectRequest {
        service,
        local_port,
    };
    let caller = shares::Caller::user("This device");
    match runtime::runtime().block_on(connections::connect(&caller, request)) {
        Ok(Ok(view)) => Ok(connection(view)),
        Ok(Err(pending)) => Err(anyhow!(pending.message())),
        Err(error) => Err(anyhow!(error.message())),
    }
}

/// End this device's connection to `service`.
pub fn tools_disconnect(service: String) -> Result<()> {
    connections::disconnect(None, &service)
        .map(drop)
        .map_err(|error| anyhow!(error.message()))
}

/// Tokens issued on this installation.
#[frb(sync)]
pub fn tools_tokens() -> Vec<ToolsTokenDto> {
    tools::tokens()
        .into_iter()
        .map(|t| ToolsTokenDto {
            id: t.id,
            kind: match t.kind {
                tokens::Kind::User => "user",
                tokens::Kind::Hosted => "hosted",
                tokens::Kind::Session => "session",
                tokens::Kind::Installed => "installed",
            }
            .into(),
            label: t.label,
            harness: t.harness,
            created_ms: t.created_ms,
        })
        .collect()
}

/// Revoke a token; what its holder shared or connected ends.
pub fn tools_revoke(token_id: String) -> Result<()> {
    tools::revoke(&token_id)
}

/// A ready-to-paste entry for a harness POCOX does not launch (`codex`,
/// `claude`, `opencode` or `generic`), with a token issued to it, shown once.
pub fn tools_harness_config(harness: String) -> Result<String> {
    let issued = tools::issue(&harness, None)?;
    Ok(tools::harness::snippet(&harness, &issued))
}
