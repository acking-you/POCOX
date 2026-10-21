//! Claude host overrides. Values share the profile store's private-file
//! transaction and pins; readers receive only presence for credentials.

use std::{collections::BTreeMap, path::Path};

use anyhow::{anyhow, bail, Result};
use pocox_core::provider::{validate_base_url, Secret};

use super::{
    files::{key_file_name, key_path, valid_key_ref, write_private, Committed},
    Engine,
};

/// One editable, upstream-supported Claude environment variable.
#[derive(Clone, Copy)]
pub struct Variable {
    /// Its exact environment name.
    pub name: &'static str,
    /// Editor group: connection, models, reasoning, or network.
    pub group: &'static str,
    /// Never read this value back through the bridge.
    pub secret: bool,
    /// Allowed choices, or empty for a text value.
    pub choices: &'static [&'static str],
}

macro_rules! variable {
    ($name:literal, $group:literal, $secret:literal, $choices:expr) => {
        Variable {
            name: $name,
            group: $group,
            secret: $secret,
            choices: $choices,
        }
    };
}

/// Deliberately bounded to controls used by this host, not arbitrary process
/// injection. Permissions, executable loading and configuration paths stay
/// under the runtime's existing controls.
pub const VARIABLES: &[Variable] = &[
    variable!("ANTHROPIC_BASE_URL", "connection", false, &[]),
    variable!("ANTHROPIC_AUTH_TOKEN", "connection", true, &[]),
    variable!("ANTHROPIC_API_KEY", "connection", true, &[]),
    variable!("CLAUDE_CODE_OAUTH_TOKEN", "connection", true, &[]),
    variable!("ANTHROPIC_MODEL", "models", false, &[]),
    variable!("ANTHROPIC_DEFAULT_OPUS_MODEL", "models", false, &[]),
    variable!("ANTHROPIC_DEFAULT_SONNET_MODEL", "models", false, &[]),
    variable!("ANTHROPIC_DEFAULT_HAIKU_MODEL", "models", false, &[]),
    variable!("ANTHROPIC_CUSTOM_MODEL_OPTION", "models", false, &[]),
    variable!("CLAUDE_CODE_SUBAGENT_MODEL", "models", false, &[]),
    variable!("CLAUDE_CODE_EFFORT_LEVEL", "reasoning", false, &[
        "auto", "low", "medium", "high", "xhigh", "max"
    ]),
    variable!("MAX_THINKING_TOKENS", "reasoning", false, &[]),
    variable!("CLAUDE_CODE_MAX_OUTPUT_TOKENS", "reasoning", false, &[]),
    variable!("CLAUDE_CODE_DISABLE_THINKING", "reasoning", false, &["0", "1"]),
    variable!("CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING", "reasoning", false, &["0", "1"]),
    variable!("API_TIMEOUT_MS", "network", false, &[]),
    variable!("HTTP_PROXY", "network", true, &[]),
    variable!("HTTPS_PROXY", "network", true, &[]),
    variable!("NO_PROXY", "network", false, &[]),
    variable!("DISABLE_PROMPT_CACHING", "network", false, &["0", "1"]),
    variable!("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "network", false, &["0", "1"]),
];

pub fn variable(name: &str) -> Result<&'static Variable> {
    VARIABLES
        .iter()
        .find(|v| v.name == name)
        .ok_or_else(|| anyhow!("unsupported Claude environment variable"))
}

/// Explicit values, never formatted by derived Debug.
pub type Values = BTreeMap<String, Secret>;
/// All desired overrides; absent names inherit, null keeps a stored value.
pub type Input = BTreeMap<String, Option<String>>;

pub fn visible(values: &Values) -> Input {
    values
        .iter()
        .map(|(name, value)| {
            let secret = variable(name).map_or(true, |v| v.secret);
            (name.clone(), (!secret).then(|| value.expose().to_string()))
        })
        .collect()
}

pub fn normalized(input: &Input, previous: &Values, engine: Engine<'_>) -> Result<Values> {
    if !input.is_empty() && !matches!(engine, Engine::Acp(s) if s.profile_id == "claude") {
        bail!("Claude environment overrides require a Claude host");
    }
    let auth_count = ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"]
        .iter()
        .filter(|name| input.contains_key(**name))
        .count();
    if auth_count > 1 {
        bail!("choose one explicit Claude credential: bearer token, API key, or OAuth token");
    }
    input
        .iter()
        .map(|(name, value)| {
            let spec = variable(name)?;
            let value = match value {
                Some(value) => value.trim(),
                None => previous
                    .get(name)
                    .ok_or_else(|| {
                        anyhow!("the stored environment value is missing; enter it again")
                    })?
                    .expose(),
            };
            if value.is_empty() || value.len() > 8192 || value.chars().any(char::is_control) {
                bail!(
                    "{} needs a nonempty value without control characters (at most 8192 bytes)",
                    spec.name
                );
            }
            if spec.secret && !value.is_ascii() {
                bail!("{} needs an ASCII value", spec.name);
            }
            if !spec.choices.is_empty() && !spec.choices.contains(&value) {
                bail!("unsupported value for {}", spec.name);
            }
            match spec.name {
                "ANTHROPIC_BASE_URL" => {
                    validate_base_url(value)?;
                },
                "ANTHROPIC_AUTH_TOKEN" | "ANTHROPIC_API_KEY" | "CLAUDE_CODE_OAUTH_TOKEN" => {
                    super::secrets::check_key(value)?
                },
                "HTTP_PROXY" | "HTTPS_PROXY" => {
                    let proxy =
                        reqwest::Url::parse(value).map_err(|_| anyhow!("invalid proxy URL"))?;
                    if !matches!(proxy.scheme(), "http" | "https" | "socks5" | "socks5h")
                        || proxy.host_str().is_none()
                    {
                        bail!("the Claude proxy needs an absolute http, https or socks5 URL");
                    }
                },
                "MAX_THINKING_TOKENS" | "CLAUDE_CODE_MAX_OUTPUT_TOKENS" | "API_TIMEOUT_MS" => {
                    // Accept the upstream's decimal, exponent and separator spellings.
                    let number = value.replace('_', "").parse::<f64>().unwrap_or(f64::NAN);
                    if !number.is_finite()
                        || number < 0.0
                        || number.fract() != 0.0
                        || (number == 0.0 && spec.name != "MAX_THINKING_TOKENS")
                    {
                        bail!("invalid numeric value for {}", spec.name);
                    }
                },
                _ => {},
            }
            Ok((name.clone(), Secret::new(value)))
        })
        .collect()
}

pub fn read(root: &Path, name: &str, reference: Option<&str>) -> Result<Values> {
    let Some(reference) = reference else {
        return Ok(Values::new());
    };
    if !valid_key_ref(name, reference) {
        bail!("invalid environment file reference");
    }
    let path = key_path(root, reference);
    if std::fs::metadata(&path)
        .map_err(|_| anyhow!("the stored Claude environment is unavailable"))?
        .len()
        > 256 * 1024
    {
        bail!("the stored Claude environment is too large");
    }
    let bytes =
        std::fs::read(path).map_err(|_| anyhow!("the stored Claude environment is unavailable"))?;
    if bytes.len() > 256 * 1024 {
        bail!("the stored Claude environment is too large");
    }
    let values: BTreeMap<String, String> = serde_json::from_slice(&bytes)
        .map_err(|_| anyhow!("the stored Claude environment is unreadable"))?;
    // Values are validated again at launch against the actual engine.
    values
        .into_iter()
        .map(|(name, value)| {
            variable(&name)?;
            Ok((name, Secret::new(value)))
        })
        .collect()
}

pub fn write(root: &Path, name: &str, values: &Values) -> Result<Option<String>> {
    if values.is_empty() {
        return Ok(None);
    }
    let file = key_file_name(name, Some(&uuid::Uuid::new_v4().to_string()));
    let path = key_path(root, &file);
    let raw: BTreeMap<&str, &str> = values
        .iter()
        .map(|(n, v)| (n.as_str(), v.expose()))
        .collect();
    let bytes = serde_json::to_vec(&raw)?;
    if write_private(&path, &bytes)? == Committed::Uncertain {
        let _ = std::fs::remove_file(path);
        bail!("the environment could not be stored durably; nothing was saved");
    }
    Ok(Some(file))
}

/// Resolve defaults once for this launch, then apply the explicit host values.
/// The connection group stays coherent when the parent already supplies one.
pub fn launch(
    spec: &pocox_host_svc::acp::AgentSpec,
    resolved: &super::Resolved,
    launch: &mut pocox_host_svc::acp::provider::AcpProviderLaunch,
) -> Result<()> {
    normalized(&visible(&resolved.claude_env), &resolved.claude_env, Engine::Acp(spec))?;
    let names: Vec<_> = VARIABLES.iter().map(|v| v.name).collect();
    let defaults = pocox_codex::external_tool_environment(&names)?;
    let inherited = std::env::vars_os().collect::<Vec<_>>();
    apply(resolved, launch, defaults, &inherited)
}

fn apply(
    resolved: &super::Resolved,
    launch: &mut pocox_host_svc::acp::provider::AcpProviderLaunch,
    mut defaults: Vec<(std::ffi::OsString, std::ffi::OsString)>,
    parent: &[(std::ffi::OsString, std::ffi::OsString)],
) -> Result<()> {
    use std::ffi::OsString;

    use serde_json::{json, Map, Value};
    let connection: Vec<_> = VARIABLES
        .iter()
        .filter(|v| v.group == "connection")
        .map(|v| v.name)
        .collect();
    let inherited: Vec<_> = parent
        .iter()
        .filter(|(name, _)| connection.iter().any(|n| name == n))
        .cloned()
        .collect();
    if !inherited.is_empty() {
        defaults.retain(|(name, _)| !connection.iter().any(|n| name == n));
        defaults.extend(inherited);
    }
    let custom = resolved.source == super::Source::Custom;
    if custom {
        defaults.retain(|(name, _)| !connection.iter().any(|n| name == n));
    }
    let mut explicit = Map::<String, Value>::new();
    for (name, value) in &resolved.claude_env {
        if custom && (connection.contains(&name.as_str()) || name == "ANTHROPIC_MODEL") {
            continue;
        }
        // Choosing a credential is unambiguous even if another auth mechanism
        // was inherited. Empty values clear only this child's alternatives.
        if matches!(
            name.as_str(),
            "ANTHROPIC_AUTH_TOKEN" | "ANTHROPIC_API_KEY" | "CLAUDE_CODE_OAUTH_TOKEN"
        ) {
            for other in ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"] {
                if !resolved.claude_env.contains_key(other) {
                    explicit.insert(other.into(), json!(""));
                }
            }
        }
        explicit.insert(name.clone(), json!(value.expose()));
    }
    defaults.extend(
        explicit
            .iter()
            .filter_map(|(k, v)| v.as_str().map(|v| (OsString::from(k), OsString::from(v)))),
    );
    // Custom provider endpoint/key fields are authoritative over environment
    // connection overrides. Behavioral overrides remain independent.
    defaults.append(&mut launch.env);
    launch.env = defaults;
    if !explicit.is_empty() {
        let meta = launch.session_meta.get_or_insert_with(Map::new);
        let claude = meta
            .entry("claudeCode")
            .or_insert_with(|| json!({"options": {}}));
        let options = claude
            .get_mut("options")
            .and_then(Value::as_object_mut)
            .ok_or_else(|| anyhow!("invalid Claude launch options"))?;
        for field in ["env", "settings"] {
            options.entry(field).or_insert_with(|| json!({}));
        }
        let settings = options
            .get_mut("settings")
            .and_then(Value::as_object_mut)
            .ok_or_else(|| anyhow!("invalid Claude settings"))?;
        let env = settings
            .entry("env")
            .or_insert_with(|| json!({}))
            .as_object_mut()
            .ok_or_else(|| anyhow!("invalid Claude environment"))?;
        env.extend(explicit.clone());
        options
            .get_mut("env")
            .and_then(Value::as_object_mut)
            .ok_or_else(|| anyhow!("invalid Claude environment"))?
            .extend(explicit);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{super::*, *};

    fn agent() -> AgentSpec {
        AgentSpec {
            profile_id: "claude".into(),
            display_name: "Claude".into(),
            program: "claude-agent-acp".into(),
            args: vec![],
        }
    }
    fn input(entries: &[(&str, Option<&str>)]) -> Input {
        entries
            .iter()
            .map(|(n, v)| ((*n).into(), v.map(str::to_string)))
            .collect()
    }
    fn change(env: Option<Input>) -> Change {
        Change {
            input: ProfileInput {
                source: Source::Inherited,
                protocol: None,
                base_url: None,
                model: None,
                claude_env: env,
            },
            key: KeyChange::Remove,
            runtime: RuntimeChange::Set(Runtime::Acp(agent())),
        }
    }

    #[test]
    fn environment_is_private_transactional_and_changes_authority() {
        let root = tempfile::tempdir().expect("fixture");
        let spec = agent();
        let engine = Engine::Acp(&spec);
        let a = change(Some(input(&[
            ("ANTHROPIC_AUTH_TOKEN", Some("secret-first")),
            ("ANTHROPIC_DEFAULT_OPUS_MODEL", Some("exact.model-id")),
        ])));
        let first = save_in(root.path(), "host", &a, None, engine).expect("save");
        assert_eq!(first.claude_env["ANTHROPIC_AUTH_TOKEN"], None);
        assert_eq!(
            first.claude_env["ANTHROPIC_DEFAULT_OPUS_MODEL"].as_deref(),
            Some("exact.model-id")
        );
        assert!(!format!("{a:?}").contains("secret-first"));
        let original = resolve_in(root.path(), "host").expect("resolve");
        assert!(original.authority.is_some());
        let profiles = std::fs::read_to_string(profiles_path(root.path())).expect("record");
        assert!(!profiles.contains("secret-first"));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            for file in std::fs::read_dir(root.path().join("keys")).expect("keys") {
                assert_eq!(
                    file.expect("file")
                        .metadata()
                        .expect("metadata")
                        .permissions()
                        .mode()
                        & 0o777,
                    0o600
                );
            }
        }
        let kept = save_in(
            root.path(),
            "host",
            &change(Some(first.claude_env)),
            Some(first.revision),
            engine,
        )
        .expect("keep hidden secret");
        assert_eq!(resolve_in(root.path(), "host").expect("resolve").authority, original.authority);
        let (_, pending) = stage_in(
            root.path(),
            "host",
            &change(Some(input(&[("ANTHROPIC_AUTH_TOKEN", Some("secret-second"))]))),
            Some(kept.revision),
            engine,
        )
        .expect("stage");
        assert_ne!(pending.resolved().expect("resolved").authority, original.authority);
        // An unrelated durable save cannot sweep the rollback's pinned file.
        save_in(root.path(), "other", &change(None), None, engine).expect("other save");
        pending.rollback().expect("rollback");
        assert_eq!(
            resolve_in(root.path(), "host")
                .expect("restored")
                .claude_env,
            original.claude_env
        );
        let current = get_in(root.path(), "host").expect("get");
        save_in(root.path(), "host", &change(Some(Input::new())), Some(current.revision), engine)
            .expect("inherit");
        let restored = resolve_in(root.path(), "host").expect("resolve");
        assert!(restored.claude_env.is_empty() && restored.authority.is_none());
    }

    #[test]
    fn a_missing_environment_can_be_explicitly_replaced_but_not_silently_kept() {
        let root = tempfile::tempdir().expect("fixture");
        let spec = agent();
        let engine = Engine::Acp(&spec);
        save_in(
            root.path(),
            "host",
            &change(Some(input(&[("ANTHROPIC_AUTH_TOKEN", Some("secret"))]))),
            None,
            engine,
        )
        .expect("save");
        let record = load(root.path())
            .expect("profiles")
            .hosts
            .remove("host")
            .expect("host");
        std::fs::remove_file(key_path(
            root.path(),
            record.claude_env.as_deref().expect("environment"),
        ))
        .expect("remove fixture file");
        assert!(save_in(root.path(), "host", &change(None), None, engine).is_err());
        assert!(save_in(
            root.path(),
            "host",
            &change(Some(input(&[("ANTHROPIC_AUTH_TOKEN", None)]))),
            None,
            engine
        )
        .is_err());
        save_in(root.path(), "host", &change(Some(Input::new())), None, engine)
            .expect("explicitly inherit");
        assert!(get_in(root.path(), "host")
            .expect("profile")
            .problem
            .is_none());
    }

    #[test]
    fn invalid_changes_cannot_commit_or_echo_values() {
        let spec = agent();
        for entries in [
            input(&[("NODE_OPTIONS", Some("private-bad-value"))]),
            input(&[("ANTHROPIC_AUTH_TOKEN", None)]),
            input(&[("ANTHROPIC_API_KEY", Some("a")), ("ANTHROPIC_AUTH_TOKEN", Some("b"))]),
            input(&[("API_TIMEOUT_MS", Some("NaN"))]),
            input(&[("CLAUDE_CODE_EFFORT_LEVEL", Some("ultra"))]),
        ] {
            let error =
                normalized(&entries, &Values::new(), Engine::Acp(&spec)).expect_err("invalid");
            assert!(!error.to_string().contains("private-bad-value"));
        }
        assert!(normalized(
            &input(&[("ANTHROPIC_MODEL", Some("exact.model"))]),
            &Values::new(),
            Engine::Codex
        )
        .is_err());
    }

    #[test]
    fn explicit_values_win_and_connection_defaults_are_coherent() {
        let mut resolved = Resolved::inherited();
        resolved.claude_env = normalized(
            &input(&[
                ("ANTHROPIC_AUTH_TOKEN", Some("host-token")),
                ("ANTHROPIC_DEFAULT_OPUS_MODEL", Some("exact.model-id")),
            ]),
            &Values::new(),
            Engine::Acp(&agent()),
        )
        .expect("input");
        let defaults = vec![
            ("ANTHROPIC_BASE_URL".into(), "https://shell.invalid".into()),
            ("ANTHROPIC_API_KEY".into(), "shell-key".into()),
            ("CLAUDE_CODE_EFFORT_LEVEL".into(), "high".into()),
        ];
        let parent = vec![("ANTHROPIC_BASE_URL".into(), "https://parent.invalid".into())];
        let mut launch = pocox_host_svc::acp::provider::AcpProviderLaunch::default();
        apply(&resolved, &mut launch, defaults, &parent).expect("launch");
        let env: BTreeMap<_, _> = launch.env.into_iter().collect();
        assert_eq!(
            env.get(std::ffi::OsStr::new("ANTHROPIC_BASE_URL"))
                .expect("url"),
            "https://parent.invalid"
        );
        assert_eq!(
            env.get(std::ffi::OsStr::new("ANTHROPIC_AUTH_TOKEN"))
                .expect("token"),
            "host-token"
        );
        assert_eq!(
            env.get(std::ffi::OsStr::new("ANTHROPIC_API_KEY"))
                .expect("clear"),
            ""
        );
        assert_eq!(
            env.get(std::ffi::OsStr::new("ANTHROPIC_DEFAULT_OPUS_MODEL"))
                .expect("model"),
            "exact.model-id"
        );
        assert_eq!(
            env.get(std::ffi::OsStr::new("CLAUDE_CODE_EFFORT_LEVEL"))
                .expect("default"),
            "high"
        );
        let meta = launch.session_meta.expect("meta");
        assert_eq!(
            meta["claudeCode"]["options"]["settings"]["env"]["ANTHROPIC_AUTH_TOKEN"],
            "host-token"
        );
        assert!(!redact("bad host-token", &resolved).contains("host-token"));
    }
}
