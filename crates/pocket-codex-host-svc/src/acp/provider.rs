//! Explicit provider routing for the Claude ACP adapter and the Grok
//! preset (whose route lives in [`super::grok`]: it needs a Grok home of its
//! own). Generic agents retain their own provider configuration.
//!
//! - **The Claude adapter** passes its process environment to Claude Code
//!   (`claude-agent-acp` 0.89.1 `dist/acp-agent.js`, the query's `env` is
//!   `{...process.env, ...options.env, …}`), but Claude Code applies the `env`
//!   of user and project `settings.json` after it. So the route also goes into
//!   each session's programmatic settings tier
//!   (`_meta.claudeCode.options.settings`, see
//!   [`AcpProviderLaunch::session_meta`]), the tier the adapter itself uses for
//!   its own provider routes. Anthropic Messages only, with a required key (no
//!   sign-in of the user's may reach another endpoint): `ANTHROPIC_BASE_URL`
//!   and `ANTHROPIC_API_KEY`, the other routing variables reset the way the
//!   adapter's own `createEnvForProvider` resets them (including
//!   `ANTHROPIC_CUSTOM_HEADERS`, so no inherited credential header reaches the
//!   new provider), and `apiKeyHelper` cleared.

use std::ffi::OsString;

use pocket_codex_core::provider::{ApiProtocol, ProviderEndpoint};
use serde_json::{json, Map, Value};

use super::{claude, grok, spec::AgentSpec};

/// What an agent's launch gets for its provider.
#[derive(Clone, Default)]
pub struct AcpProviderLaunch {
    /// Child-only environment (it may hold the key).
    pub env: Vec<(OsString, OsString)>,
    /// Inherited variables the child must not see (another account's
    /// credentials or endpoints); removed before `env` applies.
    pub env_remove: Vec<String>,
    /// Claude: `_meta` merged into every `session/new`, `session/load` and
    /// `session/resume` request (it holds the key; it travels only on the
    /// agent's own stdio pipe).
    pub session_meta: Option<Map<String, Value>>,
}

impl std::fmt::Debug for AcpProviderLaunch {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The environment and the session `_meta` may hold the key: only
        // names are shown.
        let names: Vec<_> = self.env.iter().map(|(k, _)| k).collect();
        f.debug_struct("AcpProviderLaunch")
            .field("env", &names)
            .field("env_remove", &self.env_remove)
            .field("session_meta", &self.session_meta.as_ref().map(|_| "[redacted]"))
            .finish()
    }
}

/// Why an agent cannot use a provider.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProviderError {
    /// This agent has no known provider mechanism.
    Unsupported,
    /// This agent cannot speak this protocol.
    Protocol(ApiProtocol),
    /// This agent needs a key (it would otherwise send its own sign-in).
    KeyRequired,
    /// The base URL or model holds text the agent would expand or reject.
    Unsafe,
}

impl std::fmt::Display for ProviderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unsupported => f.write_str(
                "this agent has no supported provider configuration; it uses its own configuration",
            ),
            Self::Protocol(protocol) => {
                write!(f, "this agent cannot use a `{protocol}` provider; choose another agent")
            },
            Self::KeyRequired => f.write_str(
                "this agent needs the provider's key, or it would send its own sign-in to the \
                 provider",
            ),
            Self::Unsafe => f.write_str(
                "the base URL or model contains `{`, `}`, `$` or a control character, which the \
                 agent would expand; remove it",
            ),
        }
    }
}

impl std::error::Error for ProviderError {}

/// The protocols `spec`'s agent can use with an instance provider; empty
/// for agents without a known mechanism.
pub fn supported_protocols(spec: &AgentSpec) -> &'static [ApiProtocol] {
    if spec.profile_id == claude::PROFILE_ID {
        // The Claude preset, with its bare adapter or an explicit path to it.
        &[ApiProtocol::AnthropicMessages]
    } else if grok::applies(spec) {
        // Grok's `api_backend`: `chat_completions`, `responses`, `messages`.
        &ApiProtocol::ALL
    } else {
        &[]
    }
}

/// Whether this adapter requires a default model and a provider key.
pub fn requirements(spec: &AgentSpec) -> (bool, bool) {
    if grok::applies(spec) {
        // A `[model.*]` entry names its model; without its own key grok
        // would fall back to the user's sign-in.
        return (true, true);
    }
    (false, spec.profile_id == claude::PROFILE_ID)
}

/// Whether `value` holds substitution syntax (`{env:}`, `${VAR}`) or a
/// control character.
fn unsafe_text(value: &str) -> bool {
    value
        .chars()
        .any(|c| matches!(c, '{' | '}' | '$') || c.is_control())
}

/// The Claude provider launch of `spec` for `endpoint`. Grok's route is
/// [`grok::provider_launch`] (it writes the host's Grok home).
pub fn launch(
    spec: &AgentSpec,
    endpoint: &ProviderEndpoint,
) -> Result<AcpProviderLaunch, ProviderError> {
    let supported = supported_protocols(spec);
    if supported.is_empty() || spec.profile_id != claude::PROFILE_ID {
        return Err(ProviderError::Unsupported);
    }
    if !supported.contains(&endpoint.protocol) {
        return Err(ProviderError::Protocol(endpoint.protocol));
    }
    let model = endpoint.model.as_deref().filter(|m| !m.is_empty());
    if unsafe_text(&endpoint.base_url) || model.is_some_and(unsafe_text) {
        return Err(ProviderError::Unsafe);
    }
    let key = endpoint
        .key
        .as_ref()
        .map(|k| k.expose())
        .filter(|k| !k.is_empty());
    let key = key.ok_or(ProviderError::KeyRequired)?;
    Ok(claude_route(endpoint, model, key))
}

fn claude_route(endpoint: &ProviderEndpoint, model: Option<&str>, key: &str) -> AcpProviderLaunch {
    let mut route: Vec<(&str, &str)> = vec![
        // The routing reset of the adapter's own provider override.
        ("ANTHROPIC_AUTH_TOKEN", ""),
        ("ANTHROPIC_BEDROCK_BASE_URL", ""),
        ("ANTHROPIC_VERTEX_BASE_URL", ""),
        ("ANTHROPIC_VERTEX_PROJECT_ID", ""),
        ("CLAUDE_CODE_USE_BEDROCK", "0"),
        ("CLAUDE_CODE_USE_VERTEX", "0"),
        ("CLAUDE_CODE_OAUTH_TOKEN", ""),
        // Inherited headers may carry another account's credential.
        ("ANTHROPIC_CUSTOM_HEADERS", ""),
        ("ANTHROPIC_BASE_URL", endpoint.base_url.as_str()),
        ("ANTHROPIC_API_KEY", key),
    ];
    if let Some(model) = model {
        route.push(("ANTHROPIC_MODEL", model));
    }
    let env = route
        .iter()
        .map(|(k, v)| (OsString::from(k), OsString::from(v)))
        .collect();
    let values: Map<String, Value> = route
        .iter()
        .map(|(k, v)| ((*k).to_string(), Value::String((*v).to_string())))
        .collect();
    let options = json!({
        "env": values,
        "settings": { "apiKeyHelper": "", "env": values },
    });
    let mut meta = Map::new();
    meta.insert("claudeCode".into(), json!({ "options": options }));
    AcpProviderLaunch {
        env,
        env_remove: Vec::new(),
        session_meta: Some(meta),
    }
}

#[cfg(test)]
mod tests {
    use pocket_codex_core::provider::Secret;

    use super::*;

    fn spec(profile: &str, program: &str) -> AgentSpec {
        AgentSpec {
            profile_id: profile.into(),
            display_name: "Agent".into(),
            program: program.into(),
            args: vec!["acp".into()],
        }
    }

    fn endpoint(protocol: ApiProtocol) -> ProviderEndpoint {
        ProviderEndpoint {
            protocol,
            base_url: "https://gw.example.com/v1".into(),
            key: Some(Secret::new("sk-acp")),
            model: Some("m1".into()),
        }
    }

    #[test]
    fn claude_takes_anthropic_messages_through_env_and_session_settings() {
        let claude = spec(claude::PROFILE_ID, claude::ADAPTER_BIN);
        let launch = launch(&claude, &endpoint(ApiProtocol::AnthropicMessages)).expect("ok");
        let get = |name: &str| {
            launch
                .env
                .iter()
                .find(|(k, _)| k == name)
                .map(|(_, v)| v.to_string_lossy().into_owned())
        };
        assert_eq!(get("ANTHROPIC_BASE_URL").as_deref(), Some("https://gw.example.com/v1"));
        assert_eq!(get("ANTHROPIC_API_KEY").as_deref(), Some("sk-acp"));
        assert_eq!(get("ANTHROPIC_AUTH_TOKEN").as_deref(), Some(""));
        assert_eq!(get("CLAUDE_CODE_USE_BEDROCK").as_deref(), Some("0"));
        // An inherited dummy credential header is replaced, not passed on.
        assert_eq!(get("ANTHROPIC_CUSTOM_HEADERS").as_deref(), Some(""));
        assert_eq!(get("ANTHROPIC_MODEL").as_deref(), Some("m1"));
        let meta = Value::Object(launch.session_meta.clone().expect("session meta"));
        let options = &meta["claudeCode"]["options"];
        let settings = &options["settings"];
        assert_eq!(settings["apiKeyHelper"], "");
        assert_eq!(settings["env"]["ANTHROPIC_BASE_URL"], "https://gw.example.com/v1");
        assert_eq!(settings["env"]["ANTHROPIC_API_KEY"], "sk-acp");
        assert_eq!(settings["env"]["CLAUDE_CODE_OAUTH_TOKEN"], "");
        assert_eq!(settings["env"]["ANTHROPIC_CUSTOM_HEADERS"], "");
        assert_eq!(options["env"], settings["env"]);
        assert!(!format!("{launch:?}").contains("sk-acp"), "meta is redacted too");
        for protocol in [ApiProtocol::Responses, ApiProtocol::ChatCompletions] {
            assert_eq!(
                super::launch(&claude, &endpoint(protocol)).err(),
                Some(ProviderError::Protocol(protocol))
            );
        }
    }

    #[test]
    fn claude_refuses_a_keyless_provider() {
        let claude = spec(claude::PROFILE_ID, claude::ADAPTER_BIN);
        for key in [None, Some(Secret::new(""))] {
            let mut keyless = endpoint(ApiProtocol::AnthropicMessages);
            keyless.key = key;
            assert_eq!(launch(&claude, &keyless).err(), Some(ProviderError::KeyRequired));
        }
    }

    #[test]
    fn other_agents_have_no_provider_mechanism() {
        for other in [spec("custom-x-1234", "my-agent"), spec("custom-claude-1", "claude")] {
            assert!(supported_protocols(&other).is_empty());
            assert_eq!(
                launch(&other, &endpoint(ApiProtocol::Responses)).err(),
                Some(ProviderError::Unsupported)
            );
        }
    }
}
