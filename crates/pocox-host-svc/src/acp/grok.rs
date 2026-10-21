//! The Grok Build preset: the installed `grok` CLI speaks ACP itself
//! (`grok agent --no-leader stdio`; `--no-leader` keeps the agent in this
//! one process instead of a shared leader), so no adapter is involved.
//!
//! Its model service (see [`super::provider`]) comes in three forms:
//!
//! - **existing configuration**: the user's own `$GROK_HOME` (`~/.grok`) and
//!   environment, unchanged;
//! - **Grok account**: the same home, with the environment's API-key and
//!   custom-endpoint variables removed, so the agent uses the account the user
//!   signed in to (`authenticate` method `grok.com`, see
//!   [`super::grok_control`]);
//! - **custom provider**: Grok only defines third-party models as
//!   `[model.<id>]` tables in `$GROK_HOME/config.toml` (its `GROK_CONFIG`
//!   overlays strip them), so the host gets a Grok home of its own whose
//!   `config.toml` lists the provider's models. The key never reaches the file:
//!   each model names [`KEY_ENV`] as its `env_key`, which grok treats as the
//!   model's own credential (BYOK, `xai.api_key` auth) and never persists.
//!   Sessions, sign-ins and plugins of `~/.grok` are not shared with such a
//!   host.
//!
//! Upstream reference: `deps/grok-build` (`xai-grok-pager/docs/user-guide/
//! 11-custom-models.md`, `xai-grok-config/src/config_override.rs`).

use std::{
    ffi::OsString,
    fs,
    path::{Path, PathBuf},
};

use anyhow::{bail, ensure, Context, Result};
use pocox_core::provider::{ApiProtocol, ProviderEndpoint};

use super::{provider::AcpProviderLaunch, spec::AgentSpec};

/// The preset's profile id.
pub const PROFILE_ID: &str = "grok";
/// The preset's program (`~/.grok/bin/grok` from the official installer).
pub const PROGRAM: &str = "grok";
/// The preset's arguments.
pub const ARGS: &[&str] = &["agent", "--no-leader", "stdio"];
/// The variable selecting Grok's home directory.
pub const HOME_ENV: &str = "GROK_HOME";
/// The child-only variable holding a custom provider's key, named by every
/// generated model's `env_key`.
pub const KEY_ENV: &str = "POCOX_GROK_PROVIDER_KEY";
/// Anthropic Messages wire version sent to a `messages` provider: Grok's
/// own Messages client does not send one.
const ANTHROPIC_VERSION: &str = "2023-06-01";

/// Inherited variables that would route a Grok-account host to an API key,
/// another endpoint or another default model (`xai-grok-login`
/// `auth_method.rs`, `xai-grok-config` `endpoints.rs` and its `GROK_CONFIG`
/// overlays, which may set `models.default`).
const ACCOUNT_REMOVE: &[&str] = &[
    "XAI_API_KEY",
    "GROK_CODE_XAI_API_KEY",
    "GROK_MODELS_BASE_URL",
    "GROK_MODELS_LIST_URL",
    "GROK_XAI_API_BASE_URL",
    "GROK_CLI_CHAT_PROXY_BASE_URL",
    "GROK_CONFIG",
    "GROK_CONFIG_PATH",
    "GROK_DEFAULT_MODEL",
];

/// Inherited variables a custom-provider host must not see: the user's
/// credentials (inline or by path), sign-in providers, endpoints and config
/// overlays. Its own home holds no sign-in.
const PROVIDER_REMOVE: &[&str] = &[
    "XAI_API_KEY",
    "GROK_CODE_XAI_API_KEY",
    "GROK_AUTH",
    "GROK_AUTH_PATH",
    "GROK_AUTH_PROVIDER_COMMAND",
    "GROK_OIDC_ISSUER",
    "GROK_OIDC_CLIENT_ID",
    "GROK_LOGIN_DEVICE_FLOW",
    "GROK_MODELS_BASE_URL",
    "GROK_MODELS_LIST_URL",
    "GROK_XAI_API_BASE_URL",
    "GROK_CLI_CHAT_PROXY_BASE_URL",
    "GROK_CONFIG",
    "GROK_CONFIG_PATH",
    "GROK_DEFAULT_MODEL",
];

/// Whether `spec` is the Grok preset (by profile; an explicit path to the
/// `grok` executable still is).
pub fn applies(spec: &AgentSpec) -> bool {
    spec.profile_id == PROFILE_ID
}

/// The Grok home a launch with `env` (later entries win) uses: its
/// `GROK_HOME`, else this process's, else `~/.grok`.
pub fn effective_home(env: &[(OsString, OsString)]) -> Option<PathBuf> {
    env.iter()
        .rev()
        .find(|(key, _)| key == HOME_ENV)
        .map(|(_, value)| PathBuf::from(value))
        .or_else(|| {
            std::env::var_os(HOME_ENV)
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        })
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".grok")))
        .filter(|home| home.is_absolute())
}

/// The Grok-account route: the user's own home, without the environment's
/// API key or endpoint overrides.
pub fn account_launch() -> AcpProviderLaunch {
    AcpProviderLaunch {
        env_remove: names(ACCOUNT_REMOVE),
        ..Default::default()
    }
}

/// Whether `model`, the default the Grok-account route would run, is one the
/// user defined in `home/config.toml` (a `[model.*]` table matched by its
/// key, `id` or `model`): such a model has its own endpoint and credential,
/// so that host would not use the Grok account. With `model` unknown, the
/// file's own `models.default` is checked. An unreadable file cannot be
/// verified and is an error.
pub fn account_default_is_user_model(home: &Path, model: Option<&str>) -> Result<bool> {
    let path = home.join("config.toml");
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error).context("reading Grok's configuration"),
    };
    let config: toml::Table = text.parse().with_context(|| {
        format!("{} cannot be read, so Grok's default model cannot be checked", path.display())
    })?;
    let default = model.map(str::to_owned).or_else(|| {
        config
            .get("models")
            .and_then(|models| models.get("default"))
            .and_then(toml::Value::as_str)
            .map(str::to_owned)
    });
    let Some(default) = default else { return Ok(false) };
    let Some(models) = config.get("model").and_then(toml::Value::as_table) else {
        return Ok(false);
    };
    Ok(models.iter().any(|(key, entry)| {
        key == &default
            || ["id", "model"]
                .iter()
                .any(|field| entry.get(*field).and_then(toml::Value::as_str) == Some(&default))
    }))
}

fn names(list: &[&str]) -> Vec<String> {
    list.iter().map(|name| (*name).to_string()).collect()
}

/// The custom-provider route: write `home/config.toml` for `endpoint` with
/// `models` (id, display name) besides its default model, and launch with
/// `home` as `GROK_HOME`. Everything else Grok stores in that file is kept.
pub fn provider_launch(
    home: &Path,
    endpoint: &ProviderEndpoint,
    models: &[(String, String)],
) -> Result<AcpProviderLaunch> {
    let key = endpoint
        .key
        .as_ref()
        .map(|key| key.expose())
        .filter(|key| !key.is_empty())
        .context("Grok needs the provider's API key")?;
    let default = endpoint
        .model
        .as_deref()
        .filter(|model| !model.is_empty())
        .context("Grok needs the provider's default model")?;
    ensure!(
        safe(&endpoint.base_url) && safe(default),
        "the base URL or model contains `{{`, `}}`, `$` or a control character, which Grok would \
         expand; remove it"
    );
    let path = home.join("config.toml");
    // An unreadable file is left as it is: rewriting it would drop every
    // setting Grok keeps there.
    let existing = match fs::read_to_string(&path) {
        Ok(text) => text.parse::<toml::Table>().with_context(|| {
            format!("{} cannot be read; fix or remove it, then start again", path.display())
        })?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => toml::Table::new(),
        Err(error) => return Err(error).context("reading the host's Grok configuration"),
    };
    let config = config(existing, endpoint, default, models);
    write_private(home, &path, &config)?;
    Ok(AcpProviderLaunch {
        env: vec![(HOME_ENV.into(), home.as_os_str().to_owned()), (KEY_ENV.into(), key.into())],
        env_remove: names(PROVIDER_REMOVE),
        session_meta: None,
    })
}

/// `existing` with POCOX's tables replaced: every `[model.*]` entry, and
/// the default and allowed models (the catalog shows only the provider's).
fn config(
    mut existing: toml::Table,
    endpoint: &ProviderEndpoint,
    default: &str,
    models: &[(String, String)],
) -> String {
    let backend = match endpoint.protocol {
        ApiProtocol::ChatCompletions => "chat_completions",
        ApiProtocol::Responses => "responses",
        ApiProtocol::AnthropicMessages => "messages",
    };
    let mut ids: Vec<(String, String)> = vec![(default.to_string(), default.to_string())];
    for (id, name) in models {
        if safe(id) && safe(name) && !ids.iter().any(|(known, _)| known == id) {
            ids.push((id.clone(), name.clone()));
        }
    }
    let mut table = toml::Table::new();
    for (id, name) in &ids {
        let mut model = toml::Table::new();
        model.insert("model".into(), id.clone().into());
        model.insert("name".into(), name.clone().into());
        model.insert("base_url".into(), endpoint.base_url.clone().into());
        model.insert("env_key".into(), KEY_ENV.into());
        model.insert("api_backend".into(), backend.into());
        if endpoint.protocol == ApiProtocol::AnthropicMessages {
            // Newer Grok sends the key as `x-api-key`; older ones keep Bearer.
            model.insert("auth_scheme".into(), "x_api_key".into());
            let mut headers = toml::Table::new();
            headers.insert("anthropic-version".into(), ANTHROPIC_VERSION.into());
            model.insert("extra_headers".into(), headers.into());
        }
        table.insert(id.clone(), model.into());
    }
    existing.insert("model".into(), table.into());
    let models_table = existing
        .entry("models")
        .or_insert_with(|| toml::Table::new().into());
    if !models_table.is_table() {
        *models_table = toml::Table::new().into();
    }
    if let Some(models_table) = models_table.as_table_mut() {
        models_table.insert("default".into(), default.into());
        models_table.insert(
            "allowed_models".into(),
            toml::Value::Array(ids.iter().map(|(id, _)| id.clone().into()).collect()),
        );
    }
    format!(
        "# Written by POCOX on every start of this Grok host; [model.*], models.default and \
         models.allowed_models are replaced.\n{}",
        toml::to_string(&existing).unwrap_or_default()
    )
}

/// Whether Grok takes `value` literally (its config expands `$VAR`).
fn safe(value: &str) -> bool {
    !value.is_empty()
        && !value
            .chars()
            .any(|c| matches!(c, '{' | '}' | '$') || c.is_control())
}

fn write_private(home: &Path, path: &Path, contents: &str) -> Result<()> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder
        .create(home)
        .context("creating the host's Grok home")?;
    if !fs::symlink_metadata(home)?.file_type().is_dir() {
        bail!("the host's Grok home is not a directory");
    }
    let temp = home.join(".config.toml.pocox");
    {
        let mut options = fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        use std::io::Write;
        let mut file = options
            .open(&temp)
            .context("writing the host's Grok configuration")?;
        file.write_all(contents.as_bytes())?;
        file.sync_all()?;
    }
    fs::rename(&temp, path).context("installing the host's Grok configuration")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use pocox_core::provider::Secret;

    use super::*;

    fn endpoint(protocol: ApiProtocol) -> ProviderEndpoint {
        ProviderEndpoint {
            protocol,
            base_url: "https://gw.example.com/v1".into(),
            key: Some(Secret::new("sk-grok-secret")),
            model: Some("m-default".into()),
        }
    }

    #[test]
    fn a_custom_provider_gets_its_own_home_without_the_key_on_disk() {
        let home = tempfile::TempDir::new().expect("home");
        let dir = home.path().join("host");
        fs::create_dir_all(&dir).expect("dir");
        // Grok's own settings in the file survive; an old model goes.
        fs::write(
            dir.join("config.toml"),
            "[marketplace]\nofficial_marketplace_auto_installed = true\n[model.stale]\nmodel = \
             \"stale\"\nbase_url = \"https://old\"\n",
        )
        .expect("seed");
        let models = vec![("m-2".to_string(), "Model Two".to_string())];
        let launch =
            provider_launch(&dir, &endpoint(ApiProtocol::AnthropicMessages), &models).expect("ok");
        let text = fs::read_to_string(dir.join("config.toml")).expect("config");
        assert!(!text.contains("sk-grok-secret"), "the key never reaches the file");
        let config: toml::Table = text.parse().expect("toml");
        assert_eq!(config["marketplace"]["official_marketplace_auto_installed"], true.into());
        let model = config["model"].as_table().expect("models");
        assert!(!model.contains_key("stale"));
        assert_eq!(model["m-default"]["env_key"], KEY_ENV.into());
        assert_eq!(model["m-2"]["api_backend"], "messages".into());
        assert_eq!(model["m-2"]["auth_scheme"], "x_api_key".into());
        assert_eq!(config["models"]["default"], "m-default".into());
        assert_eq!(
            config["models"]["allowed_models"],
            toml::Value::Array(vec!["m-default".into(), "m-2".into()])
        );
        let env: Vec<_> = launch
            .env
            .iter()
            .map(|(k, _)| k.to_str().expect("utf8"))
            .collect();
        assert_eq!(env, [HOME_ENV, KEY_ENV]);
        let removed: Vec<_> = launch.env_remove.iter().map(String::as_str).collect();
        for name in ["XAI_API_KEY", "GROK_AUTH_PATH", "GROK_CONFIG"] {
            assert!(removed.contains(&name), "{name} is not inherited");
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(dir.join("config.toml"))
                .expect("meta")
                .permissions()
                .mode();
            assert_eq!(mode & 0o077, 0, "private file");
        }
    }

    #[test]
    fn an_unreadable_host_configuration_is_left_intact() {
        let home = tempfile::TempDir::new().expect("home");
        fs::write(home.path().join("config.toml"), "[models\nbroken").expect("seed");
        let error = provider_launch(home.path(), &endpoint(ApiProtocol::Responses), &[])
            .expect_err("refused");
        assert!(format!("{error:#}").contains("cannot be read"));
        assert_eq!(
            fs::read_to_string(home.path().join("config.toml")).expect("kept"),
            "[models\nbroken"
        );
    }

    #[test]
    fn a_user_defined_default_is_not_the_grok_account() {
        let home = tempfile::TempDir::new().expect("home");
        let check = |model: Option<&str>| account_default_is_user_model(home.path(), model);
        assert!(!check(Some("grok-4.6")).expect("no file"));
        fs::write(
            home.path().join("config.toml"),
            "[models]\ndefault = \"my-gw\"\n[model.my-gw]\nmodel = \"gpt-x\"\nbase_url =              \"https://gw\"\n[model.\"grok-4.6\"]\nbase_url = \"https://other\"\n",
        )
        .expect("config");
        assert!(check(None).expect("models.default"));
        assert!(check(Some("gpt-x")).expect("by model"));
        // Overriding a built-in model's endpoint makes it user-defined too.
        assert!(check(Some("grok-4.6")).expect("override"));
        assert!(!check(Some("grok-4.5")).expect("built-in"));
        fs::write(home.path().join("config.toml"), "not = [toml").expect("broken");
        assert!(check(Some("grok-4.5")).is_err(), "cannot be verified");
    }

    #[test]
    fn expandable_or_missing_fields_are_refused() {
        let home = tempfile::TempDir::new().expect("home");
        let mut unsafe_url = endpoint(ApiProtocol::Responses);
        unsafe_url.base_url = "https://$HOST/v1".into();
        assert!(provider_launch(home.path(), &unsafe_url, &[]).is_err());
        let mut keyless = endpoint(ApiProtocol::Responses);
        keyless.key = None;
        assert!(provider_launch(home.path(), &keyless, &[]).is_err());
        let mut modelless = endpoint(ApiProtocol::ChatCompletions);
        modelless.model = None;
        assert!(provider_launch(home.path(), &modelless, &[]).is_err());
    }
}
