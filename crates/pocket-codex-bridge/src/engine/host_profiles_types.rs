//! Host configuration values shared by persistence and launch.

use super::*;

/// Where a host gets its model service.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    /// The agent's own existing configuration.
    Inherited,
    /// The official account (native Codex only).
    Official,
    /// An instance-owned provider.
    Custom,
}

impl Source {
    /// Stable name.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Inherited => "inherited",
            Self::Official => "official",
            Self::Custom => "custom",
        }
    }

    /// Parse a stable name.
    pub fn parse(raw: &str) -> Option<Self> {
        [Self::Inherited, Self::Official, Self::Custom]
            .into_iter()
            .find(|s| s.as_str() == raw)
    }
}

/// A save/apply expected an older configuration revision.
#[derive(Debug)]
pub struct RevisionConflict {
    /// Current saved revision; reload before retrying.
    pub current: u64,
}
impl std::fmt::Display for RevisionConflict {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(
            "this host's saved configuration changed elsewhere; reload it before saving or \
             applying",
        )
    }
}
impl std::error::Error for RevisionConflict {}

/// The engine a configuration is for, which decides what it may select.
#[derive(Debug, Clone, Copy)]
pub enum Engine<'a> {
    /// Native Codex app-server.
    Codex,
    /// An ACP agent.
    Acp(&'a AgentSpec),
    /// Native OpenCode using inherited or instance-owned configuration.
    OpenCode,
}

impl Engine<'_> {
    pub(in crate::engine) fn allows(
        &self,
        source: Source,
        protocol: Option<ApiProtocol>,
    ) -> Result<()> {
        match (self, source) {
            (_, Source::Inherited) => Ok(()),
            (Engine::Codex, Source::Official) => Ok(()),
            (Engine::Acp(_) | Engine::OpenCode, Source::Official) => {
                bail!("only native Codex offers an official-account sign-in here")
            },
            (engine, Source::Custom) => {
                let protocol = protocol.ok_or_else(|| anyhow!("choose the provider's API"))?;
                let supported: &[ApiProtocol] = match engine {
                    Engine::Codex => &[ApiProtocol::Responses],
                    Engine::Acp(spec) => acp_provider::supported_protocols(spec),
                    Engine::OpenCode => &ApiProtocol::ALL,
                };
                if supported.is_empty() {
                    bail!(
                        "this agent has no supported provider configuration; it uses its own \
                         configuration"
                    );
                }
                if !supported.contains(&protocol) {
                    bail!("this agent cannot use a `{protocol}` provider; choose another agent");
                }
                Ok(())
            },
        }
    }

    pub(super) fn admits(&self, runtime: &Runtime) -> Result<()> {
        match (self, runtime) {
            (
                Engine::Codex,
                Runtime::Codex {
                    ..
                },
            ) => Ok(()),
            (
                Engine::OpenCode,
                Runtime::OpenCode {
                    ..
                },
            ) => Ok(()),
            (Engine::Acp(spec), Runtime::Acp(desired)) if *spec == desired => Ok(()),
            (Engine::Acp(_), Runtime::Acp(_)) => {
                bail!("the provider must be checked against the agent being saved")
            },
            _ => bail!("this runtime belongs to another kind of host"),
        }
    }
}

/// The runtime a host should run with.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Runtime {
    /// A native Codex host.
    Codex {
        /// The codex executable (`None`: the app's saved one, then `PATH`).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        binary: Option<String>,
        /// The app-server port (`0`: automatic).
        port: u16,
        /// The upstream proxy (`None`: inherit the app's environment).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        proxy: Option<String>,
    },
    /// An ACP agent: its profile and exact command line.
    Acp(AgentSpec),
    /// Native OpenCode; the server and gateway choose private loopback ports.
    #[serde(rename = "opencode")]
    OpenCode {
        /// Explicit executable, or the child PATH when absent.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        binary: Option<String>,
        /// Keep this host's sessions in a database of its own rather than
        /// OpenCode's default one, which only one host can serve at a time.
        /// Absent in records saved before it existed (the default database).
        #[serde(default, rename = "separateHistory", skip_serializing_if = "std::ops::Not::not")]
        separate_history: bool,
    },
}

impl std::fmt::Debug for Runtime {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            // A proxy URL may carry credentials: only whether one is set.
            Self::Codex {
                binary,
                port,
                proxy,
            } => f
                .debug_struct("Codex")
                .field("binary", binary)
                .field("port", port)
                .field("proxy", &proxy.is_some())
                .finish(),
            Self::OpenCode {
                binary,
                separate_history,
            } => f
                .debug_struct("OpenCode")
                .field("binary", binary)
                .field("separate_history", separate_history)
                .finish(),
            Self::Acp(spec) => f.debug_tuple("Acp").field(spec).finish(),
        }
    }
}

impl Runtime {
    /// The engine this runtime launches, which decides what its
    /// configuration may select.
    pub(crate) fn engine(&self) -> Engine<'_> {
        match self {
            Self::Codex {
                ..
            } => Engine::Codex,
            Self::Acp(spec) => Engine::Acp(spec),
            Self::OpenCode {
                ..
            } => Engine::OpenCode,
        }
    }

    /// Validated and trimmed, or why not.
    pub(super) fn normalized(&self) -> Result<Self> {
        match self {
            Self::Codex {
                binary,
                port,
                proxy,
            } => {
                let proxy = trimmed(proxy.as_deref());
                if let Some(p) = proxy.as_deref() {
                    pocket_codex_api_proxy::validate_proxy(p)?;
                }
                Ok(Self::Codex {
                    binary: trimmed(binary.as_deref()),
                    port: *port,
                    proxy,
                })
            },
            Self::OpenCode {
                binary,
                separate_history,
            } => Ok(Self::OpenCode {
                binary: trimmed(binary.as_deref()),
                separate_history: *separate_history,
            }),
            Self::Acp(spec) => {
                spec.validate().map_err(|e| anyhow!("{e}"))?;
                Ok(Self::Acp(spec.clone()))
            },
        }
    }
}

/// A saved configuration, as readers see it: the key only as set or not.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostProfile {
    /// Where the host gets its model service.
    pub source: Source,
    /// The custom provider's API.
    pub protocol: Option<ApiProtocol>,
    /// The custom provider's base URL.
    pub base_url: Option<String>,
    /// The custom provider's default model.
    pub model: Option<String>,
    /// Whether a key is stored.
    pub key_set: bool,
    /// Saved Claude overrides; credentials are present with no value.
    pub claude_env: environment::Input,
    /// The desired runtime, when one was saved.
    pub runtime: Option<Runtime>,
    /// Moves on every save; `0` when nothing was ever saved.
    pub revision: u64,
    /// Why the saved record cannot be used as is (safe to show); saving
    /// replaces it.
    pub problem: Option<String>,
}

impl HostProfile {
    pub(super) fn inherited() -> Self {
        Self {
            source: Source::Inherited,
            protocol: None,
            base_url: None,
            model: None,
            key_set: false,
            claude_env: Default::default(),
            runtime: None,
            revision: 0,
            problem: None,
        }
    }
}

/// What a save asks for (everything but the key and the runtime).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProfileInput {
    /// None keeps existing overrides; Some replaces the complete set.
    pub claude_env: Option<environment::Input>,
    /// Where the host should get its model service.
    pub source: Source,
    /// The custom provider's API.
    pub protocol: Option<ApiProtocol>,
    /// The custom provider's base URL.
    pub base_url: Option<String>,
    /// The custom provider's default model.
    pub model: Option<String>,
}

impl std::fmt::Debug for ProfileInput {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProfileInput")
            .field("source", &self.source)
            .field("protocol", &self.protocol)
            .field("model", &self.model)
            .field(
                "environment",
                &self
                    .claude_env
                    .as_ref()
                    .map(|v| v.keys().collect::<Vec<_>>()),
            )
            .finish_non_exhaustive()
    }
}

/// What a save does with the stored key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyChange {
    /// Leave it as it is (set or not).
    Keep,
    /// Store this one instead.
    Replace(Secret),
    /// Remove it.
    Remove,
}

/// What a save does with the desired runtime.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuntimeChange {
    /// Leave it as it is.
    Keep,
    /// Save this one.
    Set(Runtime),
    /// Forget it (the host runs as started). No editor asks for this yet;
    /// the store's handling of it is exercised by its tests.
    #[cfg(test)]
    Clear,
}

/// One save: model service, key and runtime, committed together.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Change {
    /// The model service.
    pub input: ProfileInput,
    /// The key.
    pub key: KeyChange,
    /// The desired runtime.
    pub runtime: RuntimeChange,
}

/// The configuration a launch resolves to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    /// Explicit Claude environment values for this revision.
    pub claude_env: environment::Values,
    /// Where the host gets its model service.
    pub source: Source,
    /// The custom provider, with its key.
    pub endpoint: Option<ProviderEndpoint>,
    /// The opaque authority generation (see the module docs); `None` when
    /// inherited.
    pub authority: Option<String>,
    /// The desired runtime of the same revision.
    pub runtime: Option<Runtime>,
    /// The saved revision this is.
    pub revision: u64,
}

impl Resolved {
    /// What an instance without a record resolves to.
    pub fn inherited() -> Self {
        Self {
            source: Source::Inherited,
            claude_env: Default::default(),
            endpoint: None,
            authority: None,
            runtime: None,
            revision: 0,
        }
    }
}
