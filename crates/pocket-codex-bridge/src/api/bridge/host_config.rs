//! Per-host saved configuration (model service and desired runtime),
//! applying it to a running host, starting a new host with it, and the
//! official Codex sign-in that needs no running host.

use anyhow::bail;
use pocket_codex_core::provider::{ApiProtocol, Secret};

use super::{codex_setup::CodexLoginStartDto, hosting::AcpAgentSpecDto, *};
use crate::engine::{
    codex_login, host_apply,
    host_profiles::{
        self, Change, Engine, KeyChange, ProfileInput, Runtime, RuntimeChange, Source,
    },
    host_start::{self, NewHost, Started},
};

/// A host's runtime: what runs, not its model service.
pub struct HostRuntimeDto {
    /// `codex`, `opencode` or `acp`.
    pub kind: String,
    /// Codex: the executable (`None`: the app's saved codex, then `PATH`).
    pub binary: Option<String>,
    /// Codex: the app-server port (`0`: automatic).
    pub port: u16,
    /// Codex: the upstream proxy (`None`: inherit the app's environment).
    pub proxy: Option<String>,
    /// ACP: the agent's profile and exact command line.
    pub agent: Option<AcpAgentSpecDto>,
}

impl HostRuntimeDto {
    pub(super) fn into_runtime(self) -> Result<Runtime> {
        match self.kind.as_str() {
            "codex" => Ok(Runtime::Codex {
                binary: self.binary,
                port: self.port,
                proxy: self.proxy,
            }),
            "opencode" => {
                if self.port != 0 || self.proxy.is_some() || self.agent.is_some() {
                    bail!("OpenCode uses private automatic ports and its native configuration");
                }
                Ok(Runtime::OpenCode {
                    binary: self.binary,
                })
            },
            "acp" => Ok(Runtime::Acp(
                self.agent
                    .ok_or_else(|| anyhow!("an agent runtime needs its agent"))?
                    .into_spec(),
            )),
            other => Err(anyhow!("unknown runtime kind `{other}`")),
        }
    }

    pub(super) fn of(runtime: Runtime) -> Self {
        match runtime {
            Runtime::Codex {
                binary,
                port,
                proxy,
            } => Self {
                kind: "codex".into(),
                binary,
                port,
                proxy,
                agent: None,
            },
            Runtime::OpenCode {
                binary,
            } => Self {
                kind: "opencode".into(),
                binary,
                port: 0,
                proxy: None,
                agent: None,
            },
            Runtime::Acp(spec) => Self {
                kind: "acp".into(),
                binary: None,
                port: 0,
                proxy: None,
                agent: Some(AcpAgentSpecDto {
                    profile_id: spec.profile_id,
                    display_name: spec.display_name,
                    program: spec.program,
                    args: spec.args,
                }),
            },
        }
    }
}

/// What a running host actually runs with now (never the key).
pub struct HostActiveDto {
    /// Its run identity; pass it to [`app_serve_apply`].
    pub incarnation: String,
    /// Its runtime as launched (Codex: the exact executable used).
    pub runtime: HostRuntimeDto,
    /// Its model service as launched: `inherited`, `official` or `custom`.
    pub source: String,
    /// The saved revision it was launched with (`0`: never saved).
    pub revision: u64,
}

/// A host instance's saved configuration and, when it runs, its active
/// one. Never carries the key, only whether one is stored.
pub struct HostConfigDto {
    /// Saved Claude environment overrides; absent names inherit.
    pub claude_env: Vec<HostEnvironmentEntryDto>,
    /// `inherited` (the agent's own configuration), `official` (native Codex
    /// account) or `custom`.
    pub source: String,
    /// Custom provider API: `responses`, `anthropic-messages` or
    /// `chat-completions`.
    pub protocol: Option<String>,
    /// Custom provider base URL.
    pub base_url: Option<String>,
    /// Custom provider default model: the provider's model for new
    /// sessions, not a per-conversation choice.
    pub model: Option<String>,
    /// A key is stored for this instance.
    pub key_set: bool,
    /// Moves on every save; `0` when never saved. Pass it back as the
    /// expected revision so a concurrent save is not overwritten.
    pub revision: u64,
    /// The saved desired runtime, when one was saved.
    pub runtime: Option<HostRuntimeDto>,
    /// Why the saved record cannot be used (safe to show); saving replaces it.
    pub problem: Option<String>,
    /// What the running host runs with now; `None` when it does not run.
    pub active: Option<HostActiveDto>,
}

/// One saved override. A missing value keeps a stored secret on input;
/// on output it reports that a secret is set without exposing it.
pub struct HostEnvironmentEntryDto {
    /// Exact supported variable name.
    pub name: String,
    /// Explicit value, or a retained secret.
    pub value: Option<String>,
}

/// One supported Claude environment control.
pub struct ClaudeVariableDto {
    /// Exact upstream variable name.
    pub name: String,
    /// Connection, models, reasoning, or network.
    pub group: String,
    /// The value must be masked and never read back.
    pub secret: bool,
    /// Allowed choices; empty means free text.
    pub choices: Vec<String>,
}

/// What a save asks for, everything but the key.
pub struct HostConfigInputDto {
    /// None keeps the existing set; Some replaces it, with absent names
    /// inheriting.
    pub claude_env: Option<Vec<HostEnvironmentEntryDto>>,
    /// `inherited`, `official` or `custom`.
    pub source: String,
    /// Custom provider API (see [`HostConfigDto::protocol`]).
    pub protocol: Option<String>,
    /// Custom provider base URL.
    pub base_url: Option<String>,
    /// Custom provider default model.
    pub model: Option<String>,
}

/// What an engine can select, so the editor offers only real mappings.
pub struct HostConfigSupportDto {
    /// Environment controls for Claude hosts, empty for other engines.
    pub claude_variables: Vec<ClaudeVariableDto>,
    /// Selectable sources, in display order.
    pub sources: Vec<String>,
    /// Custom provider APIs; empty when the agent has no known mechanism.
    pub protocols: Vec<String>,
    /// A custom provider must name its default model.
    pub model_required: bool,
    /// A custom provider must have a key.
    pub key_required: bool,
}

/// The outcome of applying a saved configuration to a running host.
pub struct HostApplyDto {
    /// Instance name.
    pub name: String,
    /// The host runs the new configuration.
    pub applied: bool,
    /// The new start failed and the previous configuration runs again.
    pub restored_previous: bool,
    /// Why the new start failed, when it did (safe to show).
    pub error: Option<String>,
    /// Why restoring the previous configuration failed too: the host is
    /// stopped.
    pub restore_error: Option<String>,
    /// The saved revision the host now runs, when it runs.
    pub revision: Option<u64>,
}

/// A host started by [`app_serve_start_configured`].
pub struct HostStartedDto {
    /// Instance name as hosted.
    pub name: String,
    /// `codex`, `opencode` or `acp`.
    pub provider: String,
    /// The controller key (`app:`, `opencode:` or `acp:`).
    pub service_key: String,
    /// An already-running host was reused.
    pub reused: bool,
}

pub(super) fn dto(
    profile: host_profiles::HostProfile,
    active: Option<HostActiveDto>,
) -> HostConfigDto {
    HostConfigDto {
        claude_env: profile
            .claude_env
            .into_iter()
            .map(|(name, value)| HostEnvironmentEntryDto {
                name,
                value,
            })
            .collect(),
        source: profile.source.as_str().to_string(),
        protocol: profile.protocol.map(|p| p.as_str().to_string()),
        base_url: profile.base_url,
        model: profile.model,
        key_set: profile.key_set,
        revision: profile.revision,
        runtime: profile.runtime.map(HostRuntimeDto::of),
        problem: profile.problem,
        active,
    }
}

fn active_of(name: &str) -> Option<HostActiveDto> {
    host_apply::active(name).map(|active| HostActiveDto {
        incarnation: active.incarnation,
        runtime: HostRuntimeDto::of(active.runtime),
        source: active.source.as_str().to_string(),
        revision: active.revision,
    })
}

fn parse_protocol(raw: Option<&str>) -> Result<Option<ApiProtocol>> {
    raw.map(str::trim)
        .filter(|p| !p.is_empty())
        .map(|p| ApiProtocol::parse(p).ok_or_else(|| anyhow!("unknown provider API `{p}`")))
        .transpose()
}

pub(super) fn change_of(
    input: HostConfigInputDto,
    key_action: &str,
    key: Option<String>,
) -> Result<Change> {
    let source = Source::parse(input.source.trim())
        .ok_or_else(|| anyhow!("unknown configuration source `{}`", input.source))?;
    let key = match key_action {
        "keep" => KeyChange::Keep,
        "remove" => KeyChange::Remove,
        "replace" => {
            KeyChange::Replace(Secret::new(key.ok_or_else(|| anyhow!("a new key is required"))?))
        },
        other => return Err(anyhow!("unknown key action `{other}`")),
    };
    let claude_env = input
        .claude_env
        .map(|entries| {
            let mut values = std::collections::BTreeMap::new();
            for entry in entries {
                if values.insert(entry.name, entry.value).is_some() {
                    bail!("duplicate Claude environment variable");
                }
            }
            Ok(values)
        })
        .transpose()?;
    Ok(Change {
        input: ProfileInput {
            claude_env,
            source,
            protocol: parse_protocol(input.protocol.as_deref())?,
            base_url: input.base_url,
            model: input.model,
        },
        key,
        runtime: RuntimeChange::Keep,
    })
}

/// The saved configuration of host `name` (inherited when never saved) and
/// what it runs with now.
pub fn host_config_get(name: String) -> Result<HostConfigDto> {
    let profile = host_profiles::get(&name)?;
    Ok(dto(profile, active_of(&name)))
}

/// Model-service choices for the selected native engine or ACP agent.
#[frb(sync)]
pub fn host_config_supported(
    spec: Option<AcpAgentSpecDto>,
    engine: Option<String>,
) -> HostConfigSupportDto {
    if engine
        .as_deref()
        .is_some_and(|engine| engine != "codex" && engine != "acp")
    {
        return HostConfigSupportDto {
            claude_variables: Vec::new(),
            sources: if engine.as_deref() == Some("opencode") {
                vec!["inherited".into(), "custom".into()]
            } else {
                Vec::new()
            },
            protocols: if engine.as_deref() == Some("opencode") {
                ApiProtocol::ALL
                    .iter()
                    .map(|p| p.as_str().to_string())
                    .collect()
            } else {
                Vec::new()
            },
            model_required: engine.as_deref() == Some("opencode"),
            key_required: engine.as_deref() == Some("opencode"),
        };
    }
    use pocket_codex_host_svc::acp::provider;
    let claude_variables = if spec.as_ref().is_some_and(|s| s.profile_id == "claude") {
        host_profiles::environment::VARIABLES
            .iter()
            .map(|v| ClaudeVariableDto {
                name: v.name.to_string(),
                group: v.group.to_string(),
                secret: v.secret,
                choices: v.choices.iter().map(|s| (*s).to_string()).collect(),
            })
            .collect()
    } else {
        Vec::new()
    };
    let (sources, protocols, (model_required, key_required)): (&[Source], &[ApiProtocol], _) =
        match spec {
            None => (
                &[Source::Inherited, Source::Official, Source::Custom],
                &[ApiProtocol::Responses],
                (false, false),
            ),
            Some(spec) => {
                let spec = spec.into_spec();
                let protocols = provider::supported_protocols(&spec);
                let sources: &[Source] = if protocols.is_empty() {
                    &[Source::Inherited]
                } else {
                    &[Source::Inherited, Source::Custom]
                };
                (sources, protocols, provider::requirements(&spec))
            },
        };
    HostConfigSupportDto {
        claude_variables,
        sources: sources.iter().map(|s| s.as_str().to_string()).collect(),
        protocols: protocols.iter().map(|p| p.as_str().to_string()).collect(),
        model_required,
        key_required,
    }
}

/// Save host `name`'s configuration for its saved engine or the ACP agent
/// `spec`, and, with `runtime`, its desired runtime (an
/// agent runtime is checked as that agent). `key_action` is `keep`,
/// `replace` (with `key`) or `remove`. With `expected_revision`, a save
/// made elsewhere meanwhile is refused. Nothing that runs changes until
/// [`app_serve_apply`].
pub fn host_config_save(
    name: String,
    input: HostConfigInputDto,
    key_action: String,
    key: Option<String>,
    expected_revision: Option<u64>,
    spec: Option<AcpAgentSpecDto>,
    runtime: Option<HostRuntimeDto>,
) -> Result<HostConfigDto> {
    let mut change = change_of(input, &key_action, key)?;
    let runtime = runtime.map(HostRuntimeDto::into_runtime).transpose()?;
    let spec = spec.map(AcpAgentSpecDto::into_spec);
    if let Some(runtime) = runtime {
        change.runtime = RuntimeChange::Set(runtime);
    }
    let profile =
        save_profile(&host_profiles::root()?, &name, &change, expected_revision, spec.as_ref())?;
    Ok(dto(profile, active_of(&name)))
}

fn save_profile(
    root: &std::path::Path,
    name: &str,
    change: &Change,
    expected: Option<u64>,
    spec: Option<&pocket_codex_host_svc::acp::AgentSpec>,
) -> Result<host_profiles::HostProfile> {
    let saved = host_profiles::get_in(root, name)?;
    // Editors omit an unchanged runtime. Its saved engine still decides
    // which APIs are valid; absence of an ACP spec does not imply Codex.
    let runtime = match &change.runtime {
        RuntimeChange::Set(runtime) => Some(runtime),
        RuntimeChange::Keep if spec.is_none() => saved.runtime.as_ref(),
        _ => None,
    };
    let engine = match runtime {
        Some(Runtime::OpenCode {
            ..
        }) => Engine::OpenCode,
        Some(Runtime::Acp(agent)) => Engine::Acp(agent),
        Some(Runtime::Codex {
            ..
        }) => Engine::Codex,
        None => spec.map_or(Engine::Codex, Engine::Acp),
    };
    // The runtime used for validation must still be the one we read.
    host_profiles::save_in(root, name, change, expected.or(Some(saved.revision)), engine)
}

/// Restart the running host `name` with its saved configuration and
/// desired runtime. `expected_incarnation` ([`HostActiveDto::incarnation`])
/// and `expected_revision` ([`HostConfigDto::revision`]) name what the
/// caller reviewed: a replaced host or a newer save is refused. Only that
/// host restarts; controllers reconnect. A failed start restores the
/// previous configuration exactly.
pub fn app_serve_apply(
    name: String,
    expected_incarnation: Option<String>,
    expected_revision: Option<u64>,
) -> Result<HostApplyDto> {
    let expected = host_apply::Expected {
        incarnation: expected_incarnation,
        revision: expected_revision,
    };
    let report = host_apply::apply(&name, &expected)?;
    Ok(HostApplyDto {
        name: report.name,
        applied: report.applied,
        restored_previous: report.restored_previous,
        error: report.error,
        restore_error: report.restore_error,
        revision: report.revision,
    })
}

/// Start a new host `name` with `runtime` and this configuration, saved and
/// started as one operation: a failed start puts the previous saved
/// configuration back. Refused when the name is already hosting.
pub fn app_serve_start_configured(
    name: Option<String>,
    runtime: HostRuntimeDto,
    input: HostConfigInputDto,
    key_action: String,
    key: Option<String>,
) -> Result<HostStartedDto> {
    let change = change_of(input, &key_action, key)?;
    let host = match runtime.into_runtime()? {
        Runtime::Codex {
            binary,
            port,
            proxy,
        } => NewHost::Codex {
            port,
            binary,
            proxy,
        },
        Runtime::Acp(spec) => NewHost::Acp(spec),
        Runtime::OpenCode {
            binary,
        } => NewHost::OpenCode {
            binary,
        },
    };
    let started = host_start::start_configured(name.as_deref(), host, change)?;
    crate::engine::management::enable_after_hosting();
    Ok(match started {
        Started::Codex(r) => HostStartedDto {
            name: r.name,
            provider: "codex".into(),
            service_key: r.app_service_key,
            reused: r.reused,
        },
        Started::OpenCode(r) => HostStartedDto {
            name: r.name,
            provider: "opencode".into(),
            service_key: r.service_key,
            reused: false,
        },
        Started::Acp(r) => HostStartedDto {
            name: r.name,
            provider: "acp".into(),
            service_key: r.service_key,
            reused: r.reused,
        },
    })
}

/// How the private sign-in codex reports its account, and how one login
/// attempt there ended.
pub struct CodexLocalAuthDto {
    /// A credential is configured (it may predate this sign-in).
    pub authenticated: bool,
    /// `chatgpt` or `apikey` when configured.
    pub method: Option<String>,
    /// The asked-for login finished: `true` succeeded, `false` failed;
    /// `None` while it has not finished (or no login was named).
    pub completed: Option<bool>,
    /// Why it failed, when it did.
    pub error: Option<String>,
}

/// Start a private loopback codex for one official sign-in (never published
/// on the relay; other sign-ins are untouched), with `binary` (`None`: the
/// saved codex, then `PATH`) and `proxy` for its OAuth traffic. Returns the
/// session id the other calls take.
pub fn codex_local_session_open(binary: Option<String>, proxy: Option<String>) -> Result<String> {
    codex_login::open(binary, proxy)
}

/// Stop the private sign-in codex `session_id`; nothing for another id.
/// Fails while its codex has not been seen to exit; calling it again tries
/// that codex again.
pub fn codex_local_session_close(session_id: String) -> Result<()> {
    codex_login::close(&session_id)
}

/// Begin the official ChatGPT login on the private sign-in codex.
pub fn codex_local_login_start(session_id: String) -> Result<CodexLoginStartDto> {
    let s = codex_login::login_start(&session_id)?;
    Ok(CodexLoginStartDto {
        mode: s.mode,
        login_id: s.login_id,
        auth_url: s.auth_url,
        verification_url: s.verification_url,
        user_code: s.user_code,
    })
}

/// The private sign-in codex's account and how login `login_id` ended.
pub fn codex_local_auth_status(
    session_id: String,
    login_id: Option<String>,
) -> Result<CodexLocalAuthDto> {
    let status = codex_login::auth_status(&session_id, login_id.as_deref())?;
    Ok(CodexLocalAuthDto {
        authenticated: status.authenticated,
        method: status.method,
        completed: status.completed.as_ref().map(|c| c.success),
        error: status.completed.and_then(|c| c.error),
    })
}

/// Cancel login `login_id` on the private sign-in codex.
pub fn codex_local_login_cancel(session_id: String, login_id: String) -> Result<()> {
    codex_login::login_cancel(&session_id, &login_id)
}

/// Sign codex out through the private sign-in codex.
pub fn codex_local_logout(session_id: String) -> Result<()> {
    codex_login::logout(&session_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(profile: &str) -> AcpAgentSpecDto {
        AcpAgentSpecDto {
            profile_id: profile.into(),
            display_name: "Agent".into(),
            program: "agent".into(),
            args: Vec::new(),
        }
    }

    #[test]
    fn the_editor_is_offered_only_real_mappings() {
        let codex = host_config_supported(None, None);
        assert_eq!(codex.sources, ["inherited", "official", "custom"]);
        assert_eq!(codex.protocols, ["responses"]);
        let opencode = host_config_supported(None, Some("opencode".into()));
        assert_eq!(opencode.sources, ["inherited", "custom"]);
        assert_eq!(opencode.protocols, ["responses", "anthropic-messages", "chat-completions"]);
        assert!(opencode.model_required && opencode.key_required);
        let claude = host_config_supported(Some(spec("claude")), None);
        assert_eq!(claude.protocols, ["anthropic-messages"]);
        assert!(claude.key_required && !claude.model_required);
        assert!(!codex.model_required && !codex.key_required);
        let generic = host_config_supported(Some(spec("custom-x-1")), None);
        assert_eq!(generic.sources, ["inherited"]);
        assert!(generic.protocols.is_empty());
    }

    #[test]
    fn editing_only_the_model_service_keeps_the_saved_native_engine() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut change = Change {
            input: ProfileInput {
                source: Source::Custom,
                protocol: Some(ApiProtocol::Responses),
                base_url: Some("https://model.example/v1".into()),
                model: Some("model-one".into()),
                claude_env: None,
            },
            key: KeyChange::Replace(Secret::new("stored-key")),
            runtime: RuntimeChange::Set(Runtime::OpenCode {
                binary: None,
            }),
        };
        let mut saved =
            save_profile(dir.path(), "native", &change, Some(0), None).expect("start config");
        change.runtime = RuntimeChange::Keep;
        change.key = KeyChange::Keep;
        for protocol in ApiProtocol::ALL {
            change.input.protocol = Some(protocol);
            saved = save_profile(dir.path(), "native", &change, Some(saved.revision), None)
                .expect("save model service without resending runtime");
            assert_eq!(saved.protocol, Some(protocol));
            assert!(saved.key_set);
            assert!(matches!(saved.runtime, Some(Runtime::OpenCode { .. })));
        }
        change.input.source = Source::Official;
        assert!(save_profile(dir.path(), "native", &change, Some(saved.revision), None).is_err());
        assert_eq!(host_profiles::get_in(dir.path(), "native").expect("unchanged"), saved);
    }

    #[test]
    fn unknown_values_are_refused_before_anything_is_saved() {
        let input = || HostConfigInputDto {
            claude_env: None,
            source: "custom".into(),
            protocol: Some("responses".into()),
            base_url: Some("https://gw.example.com".into()),
            model: None,
        };
        let bad_source = HostConfigInputDto {
            source: "somewhere".into(),
            ..input()
        };
        let save = |input, action: &str| {
            host_config_save("h".into(), input, action.into(), None, None, None, None)
        };
        assert!(save(bad_source, "keep").is_err());
        assert!(save(input(), "rotate").is_err());
        assert!(save(input(), "replace").is_err());
        let bad_runtime = HostRuntimeDto {
            kind: "vm".into(),
            binary: None,
            port: 0,
            proxy: None,
            agent: None,
        };
        assert!(bad_runtime.into_runtime().is_err());
        assert!(parse_protocol(Some("chat")).is_err());
        assert_eq!(parse_protocol(Some(" ")).expect("blank"), None);
    }

    #[test]
    fn runtimes_cross_the_bridge_unchanged() {
        let codex = Runtime::Codex {
            binary: Some("/opt/codex".into()),
            port: 4500,
            proxy: None,
        };
        let back = HostRuntimeDto::of(codex.clone())
            .into_runtime()
            .expect("codex");
        assert_eq!(back, codex);
        let agent = Runtime::Acp(spec("custom-x-1").into_spec());
        let back = HostRuntimeDto::of(agent.clone())
            .into_runtime()
            .expect("acp");
        assert_eq!(back, agent);
    }
}
