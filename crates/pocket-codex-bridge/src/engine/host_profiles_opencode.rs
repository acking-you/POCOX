//! Child-only native OpenCode provider configuration; never an ACP adapter.

use std::ffi::{OsStr, OsString};

use anyhow::{anyhow, ensure, Context, Result};
use pocket_codex_core::provider::ApiProtocol;
use serde_json::{json, Map, Value};

use super::{host_names, Engine, Resolved, Source};

#[path = "host_profiles_opencode_models.rs"]
mod models;

fn literal(value: &str) -> bool {
    // Native config expands these before parsing JSON; provider URLs also
    // expand ${VAR} when the SDK is resolved.
    !value.contains("{env:")
        && !value.contains("{file:")
        && !value.contains("${")
        && !value.chars().any(char::is_control)
}

pub(super) fn validate_fields(url: Option<&str>, model: Option<&str>) -> Result<()> {
    let url = url.ok_or_else(|| anyhow!("the provider base URL is required"))?;
    let model = model
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| anyhow!("OpenCode needs the custom provider's model name"))?;
    ensure!(
        literal(url) && literal(model),
        "the provider URL or model contains native configuration substitution syntax"
    );
    Ok(())
}

pub(super) fn validate_key(key: &str) -> Result<()> {
    ensure!(!key.trim().is_empty(), "OpenCode needs the custom provider's API key");
    ensure!(literal(key), "the API key contains native configuration substitution syntax");
    Ok(())
}

/// Preserve native global/project files and data paths. Only this owned
/// child's model routing is overridden, including its auxiliary model.
pub(in crate::engine) fn environment(
    resolved: &Resolved,
    name: &str,
    inherited: Option<&OsStr>,
) -> Result<Vec<(OsString, OsString)>> {
    environment_with_models(resolved, name, inherited, Map::new())
}

pub(in crate::engine) async fn discover_environment(
    resolved: &Resolved,
    name: &str,
    inherited: Option<&OsStr>,
) -> Result<(Vec<(OsString, OsString)>, Option<String>)> {
    // Validate local configuration before any authenticated request.
    let fallback = environment(resolved, name, inherited)?;
    if resolved.source == Source::Inherited {
        return Ok((fallback, None));
    }
    let endpoint = resolved
        .endpoint
        .as_ref()
        .context("the saved provider is incomplete")?;
    match models::discover(endpoint).await {
        Ok(models) => Ok((environment_with_models(resolved, name, inherited, models)?, None)),
        Err(error) => Ok((
            fallback,
            Some(format!(
                "Gateway models unavailable: {error}. Only the configured default model is \
                 available; apply the host configuration again to retry."
            )),
        )),
    }
}

fn environment_with_models(
    resolved: &Resolved,
    name: &str,
    inherited: Option<&OsStr>,
    mut models: Map<String, Value>,
) -> Result<Vec<(OsString, OsString)>> {
    Engine::OpenCode.allows(resolved.source, resolved.endpoint.as_ref().map(|e| e.protocol))?;
    if resolved.source == Source::Inherited {
        return Ok(Vec::new());
    }
    let endpoint = resolved
        .endpoint
        .as_ref()
        .context("the saved provider is incomplete; edit the host")?;
    validate_fields(Some(&endpoint.base_url), endpoint.model.as_deref())?;
    let model = endpoint
        .model
        .as_deref()
        .context("the provider model is missing")?;
    let key = endpoint
        .key
        .as_ref()
        .context("OpenCode needs the custom provider's API key")?;
    validate_key(key.expose())?;
    let authority = resolved
        .authority
        .as_deref()
        .context("save the provider configuration again")?;
    ensure!(
        !authority.is_empty()
            && authority
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_')),
        "the saved provider authority is invalid; save it again"
    );
    let id = format!("pocket-{}-{authority}", host_names::canonical(name)?);
    let npm = match endpoint.protocol {
        ApiProtocol::Responses => "@ai-sdk/openai",
        ApiProtocol::AnthropicMessages => "@ai-sdk/anthropic",
        ApiProtocol::ChatCompletions => "@ai-sdk/openai-compatible",
    };
    // A configured alias may be callable even when /models lists canonical IDs.
    models
        .entry(model.to_owned())
        .or_insert_with(|| json!({"name": model}));
    let mut config = inherited_config(inherited)?;
    let providers = config.entry("provider").or_insert_with(|| json!({}));
    let providers = providers
        .as_object_mut()
        .context("native provider configuration must be an object")?;
    providers.insert(
        id.clone(),
        json!({
            "name": format!("Pocket · {}", host_names::canonical(name)?),
            "npm": npm,
            "env": [],
            "options": {"baseURL": endpoint.base_url, "apiKey": key.expose()},
            "models": models,
        }),
    );
    // A separate provider identity avoids built-in OAuth loaders or inherited
    // keys/headers. Restriction prevents fallback to another configured service.
    config.insert("enabled_providers".into(), json!([id]));
    let selection = format!("{id}/{model}");
    config.insert("model".into(), json!(selection));
    config.insert("small_model".into(), json!(selection));
    Ok(vec![("OPENCODE_CONFIG_CONTENT".into(), serde_json::to_string(&config)?.into())])
}

fn inherited_config(raw: Option<&OsStr>) -> Result<Map<String, Value>> {
    let Some(raw) = raw else { return Ok(Map::new()) };
    let raw = raw
        .to_str()
        .context("OPENCODE_CONFIG_CONTENT must be UTF-8")?;
    if raw.trim().is_empty() {
        return Ok(Map::new());
    }
    // OpenCode accepts JSONC. Keep comments/trailing commas usable without
    // forwarding parser errors, which could quote a credential from the input.
    json5::from_str(raw)
        .map_err(|_| anyhow!("OPENCODE_CONFIG_CONTENT must contain a valid config object"))
}

#[cfg(test)]
#[path = "host_profiles_opencode_tests.rs"]
mod tests;
