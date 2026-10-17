//! How one native Codex host is pointed at its model service, per instance.
//!
//! Codex reads its provider from the merged configuration, and `-c` is a
//! global override (`codex-rs/utils/cli/src/config_override.rs`) that
//! `codex app-server` applies like every other subcommand
//! (`codex-rs/cli/src/main.rs`, `run_main_with_transport_options`). So an
//! instance's own provider is selected with child-only `-c` arguments; the
//! user's `config.toml`, other providers and other hosts are left as they
//! are. A key is never an argument: the provider names it with `env_key`
//! and only this child's environment holds it.
//!
//! Upstream supports exactly one wire API for a provider, `responses`
//! (`codex-rs/model-provider-info/src/lib.rs`, `WireApi`; `chat` is
//! refused), so every other protocol is refused here.
//!
//! `-c` tables deep-merge into the user's configuration
//! (`codex-rs/config/src/loader`), so the provider id carries the instance
//! and its saved, random authority generation ([`host_provider_id`]), which
//! makes an accidental shared table (lending it headers, auth or another
//! `env_key`) unlikely; one that names it anyway is caught by the effective
//! check below.
//! The official mode also resets `openai_base_url`, which would otherwise
//! reroute the built-in `openai` provider (`codex-rs/core/src/config/mod.rs`,
//! an empty value is ignored), and `chatgpt_base_url` to the upstream
//! default.
//!
//! Managed configuration and requirements are merged above `-c`
//! (`codex-rs/config/src/loader/mod.rs`, `config_requirements.rs`
//! `apply_exact_to_config`) and can still select another provider or
//! endpoint. So a launch carries the [`ExpectedRoute`] it selected, and the
//! host checks the app-server's own effective configuration (`config/read`,
//! which applies those layers) with [`verify_effective`] before using it.

use pocket_codex_core::provider::{ApiProtocol, ProviderEndpoint, Secret};

/// Prefix of the `model_providers` id of an instance's own provider.
/// Distinct from the setup wizard's `pocket` entry and from Codex's reserved
/// ids, so a user's own entries are never shadowed.
pub const HOST_PROVIDER_ID: &str = "pcx_host";

/// The `model_providers` id of `instance`'s own provider under the saved
/// `authority` generation: the prefix, the instance name in hex and the
/// generation's letters and digits (a TOML bare key; dots would split it).
pub fn host_provider_id(instance: &str, authority: &str) -> String {
    let mut id =
        String::with_capacity(HOST_PROVIDER_ID.len() + 2 + instance.len() * 2 + authority.len());
    id.push_str(HOST_PROVIDER_ID);
    id.push('_');
    for byte in instance.bytes() {
        id.push_str(&format!("{byte:02x}"));
    }
    id.push('_');
    id.extend(
        authority
            .chars()
            .filter(char::is_ascii_alphanumeric)
            .map(|c| c.to_ascii_lowercase()),
    );
    id
}

/// Codex's default ChatGPT backend (`codex-rs/core/src/config/mod.rs`).
pub const DEFAULT_CHATGPT_BASE_URL: &str = "https://chatgpt.com/backend-api/";

/// The child environment variable the provider's `env_key` names.
pub const HOST_PROVIDER_KEY_VAR: &str = "POCKET_CODEX_PROVIDER_KEY";

/// Codex's built-in provider for an OpenAI account (ChatGPT sign-in or an
/// OpenAI API key in `auth.json`).
pub const OFFICIAL_PROVIDER_ID: &str = "openai";

/// Where a Codex host gets its model service.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodexProviderMode {
    /// Whatever the user's own Codex configuration selects.
    Inherited,
    /// The official OpenAI provider, with the account in `auth.json`.
    Official,
    /// An instance-owned provider.
    Custom(ProviderEndpoint),
}

/// The child-only arguments and environment for one mode.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CodexLaunch {
    /// `-c` overrides, appended after `app-server --listen …`.
    pub args: Vec<String>,
    /// Secret environment (the key), for [`crate::spawn_with_env`].
    pub env: Vec<(String, Secret)>,
    /// What the effective configuration must hold; `None` when inherited.
    pub expected: Option<ExpectedRoute>,
}

/// The route a launch selected, to compare with the app-server's effective
/// configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExpectedRoute {
    /// The `model_provider` id.
    pub provider: String,
    /// The official account (the built-in provider and endpoints).
    pub official: bool,
    /// A custom provider's base URL.
    pub base_url: Option<String>,
    /// A custom provider's `env_key` (`None`: keyless).
    pub env_key: Option<String>,
    /// The selected default model.
    pub model: Option<String>,
}

/// Why a mode cannot be launched.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodexLaunchError {
    /// Native Codex speaks only the Responses API.
    Protocol(ApiProtocol),
    /// The default model holds a control character.
    Model,
}

impl std::fmt::Display for CodexLaunchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Protocol(protocol) => write!(
                f,
                "native Codex supports only the Responses API for a custom provider (not \
                 `{protocol}`); choose an agent that speaks it"
            ),
            Self::Model => write!(f, "the default model name contains a control character"),
        }
    }
}

impl std::error::Error for CodexLaunchError {}

/// A TOML basic string for a `-c key=value` override. JSON string escapes
/// (`\"`, `\\`, `\n`, `\uXXXX`) are all valid TOML basic-string escapes.
fn toml_string(value: &str) -> String {
    serde_json::Value::String(value.to_string()).to_string()
}

fn set(args: &mut Vec<String>, key: &str, value: String) {
    args.push("-c".to_string());
    args.push(format!("{key}={value}"));
}

/// The launch for `mode` of the host `instance` (its canonical name) under
/// its saved `authority` generation.
pub fn codex_launch(
    mode: &CodexProviderMode,
    instance: &str,
    authority: &str,
) -> Result<CodexLaunch, CodexLaunchError> {
    let mut launch = CodexLaunch::default();
    match mode {
        CodexProviderMode::Inherited => {},
        CodexProviderMode::Official => {
            set(&mut launch.args, "model_provider", toml_string(OFFICIAL_PROVIDER_ID));
            set(&mut launch.args, "openai_base_url", toml_string(""));
            set(&mut launch.args, "chatgpt_base_url", toml_string(DEFAULT_CHATGPT_BASE_URL));
            launch.expected = Some(ExpectedRoute {
                provider: OFFICIAL_PROVIDER_ID.to_string(),
                official: true,
                base_url: None,
                env_key: None,
                model: None,
            });
        },
        CodexProviderMode::Custom(endpoint) => {
            if endpoint.protocol != ApiProtocol::Responses {
                return Err(CodexLaunchError::Protocol(endpoint.protocol));
            }
            let model = endpoint.model.as_deref().filter(|m| !m.is_empty());
            if model.is_some_and(|m| m.chars().any(char::is_control)) {
                return Err(CodexLaunchError::Model);
            }
            let id = host_provider_id(instance, authority);
            let entry = format!("model_providers.{id}");
            let args = &mut launch.args;
            // The former product name stays: hosts verify their effective
            // route against it, including ones started by an older release.
            set(args, &format!("{entry}.name"), toml_string("Pocket-Codex host provider"));
            set(args, &format!("{entry}.base_url"), toml_string(&endpoint.base_url));
            set(args, &format!("{entry}.wire_api"), toml_string("responses"));
            set(args, &format!("{entry}.requires_openai_auth"), "false".to_string());
            let keyed = endpoint.key.as_ref().filter(|k| !k.is_empty());
            if let Some(key) = keyed {
                set(args, &format!("{entry}.env_key"), toml_string(HOST_PROVIDER_KEY_VAR));
                launch
                    .env
                    .push((HOST_PROVIDER_KEY_VAR.to_string(), key.clone()));
            }
            set(args, "model_provider", toml_string(&id));
            if let Some(model) = model {
                set(args, "model", toml_string(model));
            }
            launch.expected = Some(ExpectedRoute {
                provider: id,
                official: false,
                base_url: Some(endpoint.base_url.clone()),
                env_key: keyed.map(|_| HOST_PROVIDER_KEY_VAR.to_string()),
                model: model.map(str::to_string),
            });
        },
    }
    Ok(launch)
}

/// Provider fields that add a credential or rewrite requests; only the
/// fields [`codex_launch`] sets may be present on the instance's provider.
const FOREIGN_PROVIDER_FIELDS: &[&str] =
    &["http_headers", "env_http_headers", "query_params", "experimental_bearer_token", "auth"];

fn text<'a>(value: &'a serde_json::Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(serde_json::Value::as_str)
}

fn set_field(value: &serde_json::Value, key: &str) -> bool {
    value.get(key).is_some_and(|v| !v.is_null())
}

/// Compare `expected` with the app-server's effective configuration (the
/// `config` of a `config/read` response). `Err` lists what differs, as
/// fixed codes that never hold a value from the configuration.
pub fn verify_effective(
    expected: &ExpectedRoute,
    config: &serde_json::Value,
) -> Result<(), Vec<&'static str>> {
    let mut differs = Vec::new();
    if text(config, "model_provider") != Some(expected.provider.as_str()) {
        differs.push("model_provider");
    }
    if let Some(model) = &expected.model {
        if text(config, "model") != Some(model.as_str()) {
            differs.push("model");
        }
    }
    let providers = config.get("model_providers");
    if expected.official {
        if text(config, "openai_base_url").is_some_and(|url| !url.is_empty()) {
            differs.push("openai_base_url");
        }
        if text(config, "chatgpt_base_url").is_some_and(|url| url != DEFAULT_CHATGPT_BASE_URL) {
            differs.push("chatgpt_base_url");
        }
        if providers.is_some_and(|p| set_field(p, OFFICIAL_PROVIDER_ID)) {
            differs.push("model_providers.openai");
        }
    } else {
        match providers.and_then(|p| p.get(&expected.provider)) {
            None => differs.push("model_providers"),
            Some(entry) => {
                if text(entry, "base_url") != expected.base_url.as_deref() {
                    differs.push("base_url");
                }
                if text(entry, "wire_api").is_some_and(|api| api != "responses") {
                    differs.push("wire_api");
                }
                if text(entry, "env_key") != expected.env_key.as_deref() {
                    differs.push("env_key");
                }
                if entry
                    .get("requires_openai_auth")
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false)
                {
                    differs.push("requires_openai_auth");
                }
                if FOREIGN_PROVIDER_FIELDS.iter().any(|f| set_field(entry, f)) {
                    differs.push("credential_fields");
                }
            },
        }
    }
    if differs.is_empty() {
        Ok(())
    } else {
        Err(differs)
    }
}

/// The effective configuration of the app-server at `ws_url` (the `config`
/// of `config/read`, which applies managed layers and requirements), within
/// `budget`.
pub async fn read_effective_config(
    ws_url: &str,
    budget: std::time::Duration,
) -> anyhow::Result<serde_json::Value> {
    use anyhow::Context as _;
    let deadline = tokio::time::Instant::now() + budget;
    let (client, _events) =
        tokio::time::timeout_at(deadline, crate::client::AppClient::connect(ws_url))
            .await
            .context("config check: websocket connect timed out")??;
    tokio::time::timeout_at(deadline, client.initialize("pocket-codex", true))
        .await
        .context("config check: initialize timed out")??;
    let mut response =
        tokio::time::timeout_at(deadline, client.request("config/read", serde_json::json!({})))
            .await
            .context("config check: config/read timed out")??;
    Ok(response
        .get_mut("config")
        .map(serde_json::Value::take)
        .unwrap_or_default())
}

/// [`read_effective_config`] and [`verify_effective`] from synchronous code
/// (also inside a Tokio runtime): `Err` is safe to show.
pub fn check_effective_blocking(
    ws_url: &str,
    expected: &ExpectedRoute,
    budget: std::time::Duration,
) -> Result<(), String> {
    // A separate thread avoids nesting block_on inside a caller's runtime.
    let read = std::thread::scope(|scope| {
        scope
            .spawn(|| -> anyhow::Result<serde_json::Value> {
                tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()?
                    .block_on(read_effective_config(ws_url, budget))
            })
            .join()
            .unwrap_or_else(|_| Err(anyhow::anyhow!("config check thread panicked")))
    });
    let config = read.map_err(|error| {
        format!("the host's effective Codex configuration could not be read: {error:#}")
    })?;
    verify_effective(expected, &config).map_err(|differs| {
        format!(
            "Codex's effective configuration does not use the provider chosen for this host \
             (overridden: {}); a managed configuration or requirement takes precedence. Use the \
             existing configuration, or change the overriding setting",
            differs.join(", ")
        )
    })
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    const AUTHORITY: &str = "A1";

    fn launch_of(
        mode: &CodexProviderMode,
        instance: &str,
    ) -> Result<CodexLaunch, CodexLaunchError> {
        codex_launch(mode, instance, AUTHORITY)
    }

    fn endpoint(protocol: ApiProtocol, key: Option<&str>) -> ProviderEndpoint {
        ProviderEndpoint {
            protocol,
            base_url: "https://gw.example.com/v1".into(),
            key: key.map(Secret::new),
            model: Some("gpt-5.5".into()),
        }
    }

    #[test]
    fn inherited_adds_nothing() {
        assert_eq!(launch_of(&CodexProviderMode::Inherited, "h"), Ok(CodexLaunch::default()));
    }

    #[test]
    fn official_selects_the_built_in_provider_and_endpoints() {
        let launch = launch_of(&CodexProviderMode::Official, "h").expect("official");
        // The resets keep a user's `openai_base_url` / `chatgpt_base_url`
        // from rerouting the official account to another endpoint.
        assert_eq!(launch.args, [
            "-c",
            "model_provider=\"openai\"",
            "-c",
            "openai_base_url=\"\"",
            "-c",
            "chatgpt_base_url=\"https://chatgpt.com/backend-api/\"",
        ]);
        assert!(launch.env.is_empty());
        let expected = launch.expected.expect("expected");
        assert!(expected.official);
        assert_eq!(expected.provider, "openai");
    }

    #[test]
    fn a_custom_provider_is_child_only_and_the_key_never_an_argument() {
        let mode = CodexProviderMode::Custom(endpoint(ApiProtocol::Responses, Some("sk-123")));
        let launch = launch_of(&mode, "h").expect("custom");
        assert_eq!(launch.args, [
            "-c",
            "model_providers.pcx_host_68_a1.name=\"Pocket-Codex host provider\"",
            "-c",
            "model_providers.pcx_host_68_a1.base_url=\"https://gw.example.com/v1\"",
            "-c",
            "model_providers.pcx_host_68_a1.wire_api=\"responses\"",
            "-c",
            "model_providers.pcx_host_68_a1.requires_openai_auth=false",
            "-c",
            "model_providers.pcx_host_68_a1.env_key=\"POCKET_CODEX_PROVIDER_KEY\"",
            "-c",
            "model_provider=\"pcx_host_68_a1\"",
            "-c",
            "model=\"gpt-5.5\"",
        ]);
        assert!(launch.args.iter().all(|a| !a.contains("sk-123")));
        assert_eq!(launch.env.len(), 1);
        assert_eq!(launch.env[0].0, HOST_PROVIDER_KEY_VAR);
        assert_eq!(launch.env[0].1.expose(), "sk-123");
        assert!(!format!("{launch:?}").contains("sk-123"));
        let expected = launch.expected.expect("expected");
        assert_eq!(expected.env_key.as_deref(), Some(HOST_PROVIDER_KEY_VAR));
        assert_eq!(expected.model.as_deref(), Some("gpt-5.5"));
    }

    #[test]
    fn a_keyless_provider_names_no_env_key() {
        let mode = CodexProviderMode::Custom(endpoint(ApiProtocol::Responses, None));
        let launch = launch_of(&mode, "h").expect("custom");
        assert!(launch.args.iter().all(|a| !a.contains("env_key")));
        assert!(launch.env.is_empty());
        assert_eq!(launch.expected.expect("expected").env_key, None);
    }

    #[test]
    fn other_protocols_are_refused() {
        for protocol in [ApiProtocol::AnthropicMessages, ApiProtocol::ChatCompletions] {
            let mode = CodexProviderMode::Custom(endpoint(protocol, Some("k")));
            assert_eq!(launch_of(&mode, "h"), Err(CodexLaunchError::Protocol(protocol)));
        }
    }

    #[test]
    fn values_are_quoted_toml_strings() {
        let mut quoted = endpoint(ApiProtocol::Responses, None);
        quoted.base_url = "https://gw.example.com/a\"b".into();
        let launch = launch_of(&CodexProviderMode::Custom(quoted), "h").expect("custom");
        assert!(launch.args.contains(
            &"model_providers.pcx_host_68_a1.base_url=\"https://gw.example.com/a\\\"b\"".into()
        ));
    }

    #[test]
    fn each_instance_and_generation_has_its_own_provider_id() {
        assert_eq!(host_provider_id("h", "A1"), "pcx_host_68_a1");
        assert_eq!(host_provider_id("a.b", "x.y-z"), "pcx_host_612e62_xyz", "no dotted key");
        assert_ne!(host_provider_id("a", "g"), host_provider_id("b", "g"));
        // A user's table under the old name-only id is never this provider.
        assert_ne!(host_provider_id("h", "g"), "pcx_host_68");
        assert_ne!(host_provider_id("h", "g1"), host_provider_id("h", "g2"));
    }

    #[test]
    fn a_model_with_a_control_character_is_refused() {
        let mut bad = endpoint(ApiProtocol::Responses, None);
        bad.model = Some("gpt\nmodel_provider=\"x\"".into());
        assert_eq!(launch_of(&CodexProviderMode::Custom(bad), "h"), Err(CodexLaunchError::Model));
    }

    fn custom_expected() -> ExpectedRoute {
        let mode = CodexProviderMode::Custom(endpoint(ApiProtocol::Responses, Some("sk-x")));
        launch_of(&mode, "h")
            .expect("custom")
            .expected
            .expect("expected")
    }

    /// The effective configuration `config/read` returns for an unaltered
    /// custom launch (null fields as upstream serialises unset options).
    fn effective_custom() -> serde_json::Value {
        json!({
            "model": "gpt-5.5",
            "model_provider": "pcx_host_68_a1",
            "model_providers": { "pcx_host_68_a1": {
                "name": "Pocket-Codex host provider",
                "base_url": "https://gw.example.com/v1",
                "wire_api": "responses",
                "requires_openai_auth": false,
                "env_key": "POCKET_CODEX_PROVIDER_KEY",
                "http_headers": null,
            } },
        })
    }

    #[test]
    fn the_effective_custom_route_is_accepted_only_unaltered() {
        let expected = custom_expected();
        assert_eq!(verify_effective(&expected, &effective_custom()), Ok(()));
        let altered = |path: &[&str], value: serde_json::Value| {
            let mut config = effective_custom();
            let mut at = &mut config;
            for key in &path[..path.len() - 1] {
                at = &mut at[*key];
            }
            at[path[path.len() - 1]] = value;
            verify_effective(&expected, &config).expect_err("refused")
        };
        let entry = |field: &'static str| ["model_providers", "pcx_host_68_a1", field];
        // Managed layers merged above `-c`: another provider, endpoint or key.
        assert_eq!(altered(&["model_provider"], json!("corp")), ["model_provider"]);
        assert_eq!(altered(&["model"], json!("other")), ["model"]);
        assert_eq!(altered(&entry("base_url"), json!("https://corp.example")), ["base_url"]);
        assert_eq!(altered(&entry("env_key"), json!("CORP_KEY")), ["env_key"]);
        assert_eq!(altered(&entry("requires_openai_auth"), json!(true)), ["requires_openai_auth"]);
        // Dummy colliding credential fields.
        for field in FOREIGN_PROVIDER_FIELDS {
            let dummy = json!({ "authorization": "Bearer dummy-collision" });
            assert_eq!(altered(&entry(field), dummy), ["credential_fields"], "{field}");
        }
        let mut missing = effective_custom();
        missing["model_providers"] = json!({});
        assert_eq!(verify_effective(&expected, &missing), Err(vec!["model_providers"]));
    }

    #[test]
    fn the_effective_official_route_keeps_the_built_in_endpoints() {
        let expected = launch_of(&CodexProviderMode::Official, "h")
            .expect("official")
            .expected
            .expect("expected");
        let ok = json!({
            "model_provider": "openai",
            "chatgpt_base_url": DEFAULT_CHATGPT_BASE_URL,
            "model_providers": {},
        });
        assert_eq!(verify_effective(&expected, &ok), Ok(()));
        assert_eq!(verify_effective(&expected, &json!({ "model_provider": "openai" })), Ok(()));
        let routed = json!({
            "model_provider": "openai",
            "chatgpt_base_url": "https://corp.example/backend-api/",
            "openai_base_url": "https://corp.example/v1",
            "model_providers": { "openai": { "base_url": "https://corp.example/v1" } },
        });
        assert_eq!(
            verify_effective(&expected, &routed),
            Err(vec!["openai_base_url", "chatgpt_base_url", "model_providers.openai"])
        );
        let required = json!({ "model_provider": "corp" });
        assert_eq!(verify_effective(&expected, &required), Err(vec!["model_provider"]));
    }
}
