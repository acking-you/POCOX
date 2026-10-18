//! Giving the tools to the harnesses POCOX launches, without touching the
//! user's files: Codex through launch overrides, ACP agents through each
//! session's `mcpServers`, native OpenCode through its inline configuration.
//! A token reaches a harness only through its environment, its ACP session
//! request or its inline configuration; never through a command line.

use std::{
    ffi::{OsStr, OsString},
    sync::Arc,
};

use anyhow::{Context, Result};
use pocket_codex_core::provider::Secret;
use pocket_codex_host_svc::acp::{McpGrant, SessionMcp};
use serde_json::{json, Map, Value};

use super::{
    state,
    tokens::{Kind, Principal},
};

/// The environment variable that carries a hosted Codex's token.
pub const TOKEN_VAR: &str = "POCOX_TOOLS_TOKEN";

/// What one launch gets: where the tools are, and its own token.
pub struct Grant {
    /// The MCP URL.
    pub url: String,
    /// The token (secret).
    pub token: Secret,
    /// The token's id.
    pub token_id: String,
}

fn endpoint() -> Option<String> {
    let state = state::lock();
    (state.hosting && state.settings.enabled)
        .then(|| state.endpoint.clone())
        .flatten()
}

fn mcp_url(base: &str) -> String {
    format!("{}/mcp", base.trim_end_matches('/'))
}

/// A token for the hosted instance `host` of `harness`, while the tools are
/// on; `None` launches the harness without them.
pub fn hosted(host: &str, harness: &str, label: &str) -> Option<Grant> {
    let base = endpoint()?;
    let minted = state::lock()
        .tokens
        .mint(Kind::Hosted, label, Some(harness), Some(host));
    match minted {
        Ok((principal, secret)) => Some(Grant {
            url: mcp_url(&base),
            token: Secret::new(secret),
            token_id: principal.id,
        }),
        Err(error) => {
            tracing::warn!("agent tools not given to `{host}`: {error:#}");
            None
        },
    }
}

/// A hosted launch came up: an adopted process kept its earlier token, so the
/// new one is withdrawn; a fresh one replaces the earlier tokens of `host`.
pub fn hosted_started(host: &str, grant: &Grant, reused: bool) {
    let id = grant.token_id.clone();
    let revoked = state::lock().tokens.revoke_where(|p| {
        p.kind == Kind::Hosted
            && p.host.as_deref() == Some(host)
            && if reused { p.id == id } else { p.id != id }
    });
    super::ended(&revoked);
}

/// A hosted instance stopped: its tokens are revoked and what its harness
/// shared or connected ends.
pub fn hosted_stopped(host: &str) {
    let revoked = state::lock().tokens.revoke_where(|p| {
        matches!(p.kind, Kind::Hosted | Kind::Session) && p.host.as_deref() == Some(host)
    });
    super::ended(&revoked);
}

/// Codex launch overrides for `grant`, with the token's environment entry.
pub fn codex(grant: &Grant) -> (Vec<String>, (String, Secret)) {
    let mut args = Vec::new();
    let mut set = |key: &str, value: String| {
        args.push("-c".to_string());
        args.push(format!("mcp_servers.pocox.{key}={value}"));
    };
    let quoted = |text: &str| Value::String(text.to_string()).to_string();
    set("url", quoted(&grant.url));
    set("bearer_token_env_var", quoted(TOKEN_VAR));
    set("enabled", "true".into());
    set("startup_timeout_sec", "10".into());
    // Longer than the time a share waits for the user's answer.
    set("tool_timeout_sec", "180".into());
    set("tools.services.approval_mode", quoted("approve"));
    (args, (TOKEN_VAR.to_string(), grant.token.clone()))
}

/// Merge the tools into native OpenCode's inline configuration in `env`
/// (adding one when the launch has none, over the inherited value).
pub fn opencode(
    grant: &Grant,
    env: &mut Vec<(OsString, OsString)>,
    inherited: Option<&OsStr>,
) -> Result<()> {
    let name = OsString::from("OPENCODE_CONFIG_CONTENT");
    let current = env
        .iter()
        .rev()
        .find(|(key, _)| *key == name)
        .map(|(_, value)| value.clone())
        .or_else(|| inherited.map(OsStr::to_os_string));
    let mut config: Map<String, Value> = match current.as_deref().and_then(OsStr::to_str) {
        Some(raw) if !raw.trim().is_empty() => json5::from_str(raw).map_err(|_| {
            anyhow::anyhow!("OPENCODE_CONFIG_CONTENT must contain a valid config object")
        })?,
        _ => Map::new(),
    };
    let servers = config.entry("mcp").or_insert_with(|| json!({}));
    servers
        .as_object_mut()
        .context("OpenCode's `mcp` configuration must be an object")?
        .insert(
            "pocox".into(),
            json!({
                "type": "remote",
                "url": grant.url,
                "enabled": true,
                "headers": {"Authorization": format!("Bearer {}", grant.token.expose())},
                // Static token: OpenCode must not start an OAuth flow on a 401.
                "oauth": false,
                // Longer than the time a share waits for the user's answer.
                "timeout": 180_000,
            }),
        );
    env.retain(|(key, _)| *key != name);
    env.push((name, serde_json::to_string(&config)?.into()));
    Ok(())
}

/// Per-session tools for a hosted ACP agent.
struct AcpTools {
    host: String,
    harness: String,
    label: String,
    claude: bool,
}

impl SessionMcp for AcpTools {
    fn grant(&self, session: Option<&str>) -> Option<McpGrant> {
        let base = endpoint()?;
        let (principal, secret): (Principal, String) = {
            let mut state = state::lock();
            let minted = state.tokens.mint(
                Kind::Session,
                &self.label,
                Some(&self.harness),
                Some(&self.host),
            );
            let (principal, secret) = minted.ok()?;
            if let Some(session) = session {
                state.tokens.bind_session(&principal.id, session);
            }
            (principal, secret)
        };
        let servers = vec![json!({
            "type": "http",
            "name": "pocox",
            "url": mcp_url(&base),
            "headers": [{"name": "Authorization", "value": format!("Bearer {secret}")}],
        })];
        // The Claude adapter passes these options to Claude Code: the read
        // tool runs without a prompt.
        let meta = self.claude.then(|| {
            let mut meta = Map::new();
            meta.insert(
                "claudeCode".into(),
                json!({"options": {"allowedTools": ["mcp__pocox__services"]}}),
            );
            meta
        });
        let id = principal.id;
        Some(McpGrant {
            servers,
            meta,
            adopt: Some(Box::new(move |session: &str| {
                state::lock().tokens.bind_session(&id, session);
            })),
        })
    }
}

/// The tools for hosted ACP instance `host` running `profile`.
pub fn acp(host: &str, profile: Option<&str>, label: &str) -> Arc<dyn SessionMcp> {
    let claude = profile == Some("claude");
    Arc::new(AcpTools {
        host: host.to_string(),
        harness: profile.unwrap_or("acp").to_string(),
        label: label.to_string(),
        claude,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grant() -> Grant {
        Grant {
            url: "http://127.0.0.1:17863/mcp".into(),
            token: Secret::new("pcxt_secret"),
            token_id: "t".into(),
        }
    }

    #[test]
    fn codex_gets_the_endpoint_by_override_and_the_token_by_environment() {
        let (args, (var, token)) = codex(&grant());
        assert!(args.contains(&"mcp_servers.pocox.url=\"http://127.0.0.1:17863/mcp\"".to_string()));
        assert!(args.iter().all(|arg| !arg.contains("pcxt_")), "no token in argv");
        assert_eq!((var.as_str(), token.expose()), (TOKEN_VAR, "pcxt_secret"));
    }

    #[test]
    fn opencode_keeps_its_inline_configuration_and_gains_the_server() {
        let mut env = vec![(
            OsString::from("OPENCODE_CONFIG_CONTENT"),
            OsString::from(r#"{"model": "p/m", "mcp": {"other": {"type": "local"}}}"#),
        )];
        opencode(&grant(), &mut env, None).expect("merge");
        assert_eq!(env.len(), 1);
        let config: Value = serde_json::from_str(env[0].1.to_str().unwrap()).expect("json");
        assert_eq!(config["model"], "p/m");
        assert_eq!(config["mcp"]["other"]["type"], "local");
        assert_eq!(config["mcp"]["pocox"]["headers"]["Authorization"], "Bearer pcxt_secret");
        let mut inherited_only = Vec::new();
        opencode(&grant(), &mut inherited_only, Some(OsStr::new("{\"theme\": \"x\",}")))
            .expect("inherited JSONC");
        let config: Value =
            serde_json::from_str(inherited_only[0].1.to_str().unwrap()).expect("json");
        assert_eq!(config["theme"], "x");
    }
}
