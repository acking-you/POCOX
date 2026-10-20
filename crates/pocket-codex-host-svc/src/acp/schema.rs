//! The subset of the ACP v1 schema this client interprets.
//!
//! Only fields that drive behaviour are typed; everything else is carried as
//! raw JSON so unknown fields and future variants pass through untouched.
//! Capabilities are read conservatively: an optional feature counts as
//! supported only when the agent advertises it explicitly.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// The only protocol version this client implements.
pub const PROTOCOL_VERSION: u64 = 1;

/// The `initialize` request this client sends.
///
/// No filesystem, terminal, authentication-terminal, elicitation or session
/// extension capability is advertised: none is implemented on the host, so
/// a compliant agent never routes those requests here.
pub fn initialize_params() -> Value {
    json!({
        "protocolVersion": PROTOCOL_VERSION,
        "clientCapabilities": {
            "fs": {"readTextFile": false, "writeTextFile": false},
            "terminal": false,
        },
        "clientInfo": {
            "name": "pocket-codex",
            "title": "POCOX",
            "version": env!("CARGO_PKG_VERSION"),
        },
    })
}

/// Optional agent features, as negotiated by `initialize`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentCapabilities {
    /// `session/load` (history replay) — `agentCapabilities.loadSession`.
    pub load_session: bool,
    /// `session/list` — `sessionCapabilities.list`.
    pub list_sessions: bool,
    /// `session/resume` (no replay) — `sessionCapabilities.resume`.
    pub resume_session: bool,
    /// `session/close` — `sessionCapabilities.close`.
    pub close_session: bool,
    /// Image prompt content — `promptCapabilities.image`.
    pub image: bool,
    /// Audio prompt content — `promptCapabilities.audio`.
    pub audio: bool,
    /// Embedded resource prompt content — `promptCapabilities.embeddedContext`.
    pub embedded_context: bool,
    /// The `_session/steering` extension (supplementing a running turn) —
    /// the top-level `InitializeResponse._meta.steering.supported`, a
    /// sibling of `agentCapabilities`.
    #[serde(default)]
    pub steering: bool,
    /// HTTP MCP servers in `mcpServers` — `mcpCapabilities.http`.
    #[serde(default)]
    pub mcp_http: bool,
    /// Grok Build's own extensions — `InitializeResponse._meta.grokShell`
    /// from [`GROK_NATIVE_FROM`] on (`_meta.agentVersion`): prompts carry a
    /// `_meta.promptId` the queue and turn events report back, turns Grok
    /// starts by itself are announced, `_x.ai/interject` adds to a running
    /// turn and `_x.ai/session/rename` renames. See `docs/grok-build.md`.
    #[serde(default)]
    pub grok: bool,
}

/// The first Grok Build version whose extensions this client relies on:
/// the reference source in `deps/grok-build` (1.0.4 sends neither prompt
/// ids nor queue events).
pub const GROK_NATIVE_FROM: (u64, u64, u64) = (1, 0, 45);

/// Whether `initialize._meta` describes a Grok Build agent from
/// [`GROK_NATIVE_FROM`] on.
fn grok_native(meta: &Value) -> bool {
    if meta["grokShell"] != true {
        return false;
    }
    let Some(version) = meta["agentVersion"].as_str() else { return false };
    let mut parts = version
        .split(|c: char| !c.is_ascii_digit())
        .map(|part| part.parse::<u64>().ok());
    match (parts.next(), parts.next(), parts.next()) {
        (Some(Some(major)), Some(Some(minor)), Some(Some(patch))) => {
            (major, minor, patch) >= GROK_NATIVE_FROM
        },
        _ => false,
    }
}

/// The `_session/steering` extension request.
pub const STEERING_METHOD: &str = "_session/steering";

/// How an agent answered a `_session/steering` request sent with the
/// `promptRequired` idle behaviour.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SteerOutcome {
    /// Delivered into the running turn.
    Injected,
    /// No turn was running: the input was not consumed and has to be sent
    /// as an ordinary prompt.
    PromptRequired,
}

impl SteerOutcome {
    /// The wire value of this outcome.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Injected => "injected",
            Self::PromptRequired => "promptRequired",
        }
    }

    /// Interpret a `_session/steering` result. `None` for any other answer
    /// (including the `startedNewTurn` of agents that ignored the opt-in):
    /// what happened to the input is then unknown.
    pub fn from_result(result: &Value) -> Option<Self> {
        match result["outcome"].as_str()? {
            "injected" => Some(Self::Injected),
            "promptRequired" if result["reason"] == "noRunningTurn" => Some(Self::PromptRequired),
            _ => None,
        }
    }
}

/// The `_session/steering` params for `session` and its content `prompt`,
/// opting into the `promptRequired` idle behaviour so that an idle agent
/// never starts a turn on its own.
pub fn steering_params(session: &str, prompt: Vec<Value>) -> Value {
    json!({
        "sessionId": session,
        "prompt": prompt,
        "_meta": {"steering": {"idleBehavior": "promptRequired"}},
    })
}

/// Agent self-description from `agentInfo`, when supplied.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentInfo {
    /// Programmatic name.
    pub name: Option<String>,
    /// Display title.
    pub title: Option<String>,
    /// Version string.
    pub version: Option<String>,
}

/// One advertised authentication method (display only; this client never
/// calls `authenticate`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthMethod {
    /// Method id.
    pub id: String,
    /// Display name.
    pub name: String,
}

/// The outcome of `initialize`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Negotiated {
    /// Negotiated protocol version.
    pub protocol_version: u64,
    /// Optional features.
    pub capabilities: AgentCapabilities,
    /// Agent self-description.
    pub agent: AgentInfo,
    /// Advertised authentication methods.
    pub auth_methods: Vec<AuthMethod>,
    /// The agent's slash commands: the latest `available_commands_update`
    /// of any session, seeded from Grok's `initialize._meta.availableCommands`
    /// (commands are the agent's, so a new session or draft offers them
    /// before its own update arrives).
    #[serde(default)]
    pub commands: Vec<Value>,
}

/// Why `initialize` could not be accepted.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum NegotiationError {
    /// The response was not an `InitializeResponse`.
    #[error("the agent's initialize response is malformed")]
    Malformed,
    /// The agent only speaks another protocol version.
    #[error("the agent speaks ACP version {0}; this app supports version 1")]
    UnsupportedVersion(u64),
}

fn non_null_object(value: &Value) -> bool {
    value.is_object()
}

fn short(value: &Value, limit: usize) -> Option<String> {
    value
        .as_str()
        .map(|text| text.chars().take(limit).collect::<String>())
        .filter(|text| !text.trim().is_empty())
}

/// Interpret an `initialize` result.
pub fn negotiate(result: &Value) -> Result<Negotiated, NegotiationError> {
    let version = result["protocolVersion"]
        .as_u64()
        .ok_or(NegotiationError::Malformed)?;
    if version != PROTOCOL_VERSION {
        return Err(NegotiationError::UnsupportedVersion(version));
    }
    let agent = &result["agentCapabilities"];
    let session = &agent["sessionCapabilities"];
    let prompt = &agent["promptCapabilities"];
    let capabilities = AgentCapabilities {
        load_session: agent["loadSession"] == true,
        list_sessions: non_null_object(&session["list"]),
        resume_session: non_null_object(&session["resume"]),
        close_session: non_null_object(&session["close"]),
        // Grok takes image prompts (its terminal client sends them, and it
        // checks and forwards them to the model) without advertising them.
        image: prompt["image"] == true || grok_native(&result["_meta"]),
        audio: prompt["audio"] == true,
        embedded_context: prompt["embeddedContext"] == true,
        // Grok's interjection is its steering (see `host/grok.rs`).
        steering: result["_meta"]["steering"]["supported"] == true || grok_native(&result["_meta"]),
        mcp_http: agent["mcpCapabilities"]["http"] == true,
        grok: grok_native(&result["_meta"]),
    };
    let info = &result["agentInfo"];
    let auth_methods = result["authMethods"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|method| {
            Some(AuthMethod {
                id: short(&method["id"], 256)?,
                name: short(&method["name"], 256).unwrap_or_default(),
            })
        })
        .take(16)
        .collect();
    Ok(Negotiated {
        protocol_version: version,
        capabilities,
        agent: AgentInfo {
            name: short(&info["name"], 256),
            title: short(&info["title"], 256),
            version: short(&info["version"], 128),
        },
        auth_methods,
        commands: available_commands(&result["_meta"]["availableCommands"]),
    })
}

/// The kind hint of a permission option.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PermissionOption {
    /// Opaque option id, returned verbatim when chosen.
    pub option_id: String,
    /// Agent-provided label.
    pub name: String,
    /// `allow_once` / `allow_always` / `reject_once` / `reject_always`, or an
    /// unknown future value (kept verbatim; the UI treats it neutrally).
    pub kind: String,
}

/// Most options accepted on one permission request.
pub const MAX_PERMISSION_OPTIONS: usize = 16;

/// Parse a `session/request_permission` params object into its session id,
/// tool call and options. `None` when malformed.
pub fn permission_request(params: &Value) -> Option<(String, Value, Vec<PermissionOption>)> {
    let session = params["sessionId"].as_str()?.to_string();
    let tool_call = params.get("toolCall").filter(|v| v.is_object())?.clone();
    let raw = params["options"].as_array()?;
    if raw.is_empty() || raw.len() > MAX_PERMISSION_OPTIONS {
        return None;
    }
    let mut options = Vec::with_capacity(raw.len());
    for option in raw {
        let option_id = option["optionId"].as_str()?.to_string();
        if option_id.len() > 1024
            || options
                .iter()
                .any(|o: &PermissionOption| o.option_id == option_id)
        {
            return None;
        }
        options.push(PermissionOption {
            option_id,
            name: option["name"].as_str()?.chars().take(512).collect(),
            kind: option["kind"].as_str()?.chars().take(64).collect(),
        });
    }
    Some((session, tool_call, options))
}

/// Session state an agent reports on `session/new|load|resume`, and in
/// `config_option_update` / `current_mode_update`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSettings {
    /// Single-select configuration options (models, modes, thought levels,
    /// …), verbatim. Boolean options are dropped: this client does not
    /// advertise boolean support, so a compliant agent never sends them.
    pub config_options: Vec<Value>,
    /// Legacy mode state (`availableModes` / `currentModeId`), verbatim.
    pub modes: Option<Value>,
    /// The slash commands of the last `available_commands_update`, as
    /// [`available_commands`] keeps them.
    #[serde(default)]
    pub commands: Vec<Value>,
    /// Context window per model id, where the setup answer's model list
    /// names one (Grok's `models.availableModels[]._meta.totalContextTokens`).
    #[serde(default)]
    pub context_windows: Vec<(String, u64)>,
}

/// The well-formed entries of an `availableCommands` list, without their
/// `_meta`: `{name, description, input?: {hint}}`, bounded.
pub fn available_commands(raw: &Value) -> Vec<Value> {
    raw.as_array()
        .into_iter()
        .flatten()
        .filter_map(|command| {
            let name = command["name"].as_str()?;
            if name.is_empty() || name.len() > 64 || name.chars().any(char::is_whitespace) {
                return None;
            }
            let description: String = command["description"]
                .as_str()
                .unwrap_or_default()
                .chars()
                .take(512)
                .collect();
            let mut entry = json!({"name": name, "description": description});
            if let Some(hint) = command["input"]["hint"].as_str() {
                entry["input"] = json!({"hint": hint.chars().take(256).collect::<String>()});
            }
            Some(entry)
        })
        .take(128)
        .collect()
}

/// Keep only well-formed select options.
pub fn select_options(raw: &Value) -> Vec<Value> {
    raw.as_array()
        .into_iter()
        .flatten()
        .filter(|option| {
            option["id"].is_string()
                && option["name"].is_string()
                && option["type"] == "select"
                && option["currentValue"].is_string()
                && option["options"].is_array()
        })
        .take(32)
        .cloned()
        .collect()
}

impl SessionSettings {
    /// From a session setup response.
    pub fn from_response(result: &Value) -> Self {
        let modes = result
            .get("modes")
            .filter(|modes| {
                modes["availableModes"].is_array() && modes["currentModeId"].is_string()
            })
            .cloned();
        let context_windows = result["models"]["availableModels"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|model| {
                Some((
                    model["modelId"].as_str()?.chars().take(256).collect(),
                    model["_meta"]["totalContextTokens"].as_u64()?,
                ))
            })
            .take(64)
            .collect();
        Self {
            config_options: select_options(&result["configOptions"]),
            modes,
            commands: Vec::new(),
            context_windows,
        }
    }

    /// The context window of the model the `model` option selects, when the
    /// setup answer named it.
    pub fn context_window(&self) -> Option<u64> {
        let current = self
            .config_options
            .iter()
            .find(|option| option["category"] == "model")?["currentValue"]
            .as_str()?;
        self.context_windows
            .iter()
            .find(|(model, _)| model == current)
            .map(|(_, size)| *size)
    }

    /// Whether `value` is one of the advertised values of select `config`.
    pub fn allows_config_value(&self, config: &str, value: &str) -> bool {
        self.config_options
            .iter()
            .find(|option| option["id"] == config)
            .is_some_and(|option| {
                option["options"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .any(|entry| {
                        // Ungrouped entries carry `value`; grouped ones nest them.
                        entry["value"] == value
                            || entry["options"]
                                .as_array()
                                .into_iter()
                                .flatten()
                                .any(|nested| nested["value"] == value)
                    })
            })
    }

    /// Whether `mode` is an advertised legacy mode.
    pub fn allows_mode(&self, mode: &str) -> bool {
        self.modes.as_ref().is_some_and(|modes| {
            modes["availableModes"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|entry| entry["id"] == mode)
        })
    }

    /// Apply a `current_mode_update`.
    pub fn set_current_mode(&mut self, mode: &str) {
        if let Some(modes) = self.modes.as_mut() {
            modes["currentModeId"] = Value::String(mode.to_string());
        }
    }
}

/// How a prompt turn ended. Serialized as `{"kind": "stopped",
/// "stopReason": …}`, `{"kind": "failed", "message": …}`,
/// `{"kind": "agentExited"}` or `{"kind": "cancelled"}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum TurnOutcome {
    /// The agent answered `session/prompt` with a stop reason (verbatim, so
    /// an unknown future reason survives).
    Stopped {
        /// The stop reason.
        stop_reason: String,
    },
    /// The agent answered with an error.
    Failed {
        /// Short error message.
        message: String,
    },
    /// The agent process ended before answering.
    AgentExited,
    /// Cancelled before the prompt was sent: the agent never started it.
    Cancelled,
}

impl TurnOutcome {
    /// From a `session/prompt` result.
    pub fn from_prompt_result(result: &Value) -> Self {
        match result["stopReason"].as_str() {
            Some(reason) => Self::Stopped {
                stop_reason: reason.chars().take(64).collect(),
            },
            None => Self::Failed {
                message: "the agent's prompt response has no stop reason".into(),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capabilities_require_explicit_advertisement() {
        let bare = negotiate(&json!({"protocolVersion": 1})).expect("minimal");
        assert_eq!(bare.capabilities, AgentCapabilities::default());
        let full = negotiate(&json!({
            "protocolVersion": 1,
            "agentCapabilities": {
                "loadSession": true,
                "promptCapabilities": {"image": true, "audio": false},
                "sessionCapabilities": {"list": {}, "resume": {}, "close": null},
            },
            "agentInfo": {"name": "beta", "version": "2.0"},
            "authMethods": [{"id": "login", "name": "Log in"}],
        }))
        .expect("full");
        assert!(full.capabilities.load_session);
        assert!(full.capabilities.list_sessions);
        assert!(full.capabilities.resume_session);
        assert!(!full.capabilities.close_session);
        assert!(full.capabilities.image);
        assert_eq!(full.agent.version.as_deref(), Some("2.0"));
        assert_eq!(full.auth_methods.len(), 1);
    }

    #[test]
    fn steering_is_read_from_the_top_level_meta_only() {
        let supported = negotiate(&json!({
            "protocolVersion": 1, "_meta": {"steering": {"supported": true}},
        }))
        .expect("supported");
        assert!(supported.capabilities.steering);
        for result in [
            json!({"protocolVersion": 1}),
            json!({"protocolVersion": 1, "_meta": {"steering": {"supported": "true"}}}),
            json!({"protocolVersion": 1, "_meta": {"steering": true}}),
            json!({"protocolVersion": 1, "_meta": null}),
            // Inside `agentCapabilities` is not where the extension lives.
            json!({"protocolVersion": 1,
                "agentCapabilities": {"_meta": {"steering": {"supported": true}}}}),
        ] {
            assert!(!negotiate(&result).expect("valid").capabilities.steering, "{result}");
        }
        // A capability record written before the field existed reads as off.
        let old: AgentCapabilities =
            serde_json::from_value(json!({"loadSession": true, "listSessions": false,
                "resumeSession": false, "closeSession": false, "image": false,
                "audio": false, "embeddedContext": false}))
            .expect("old record");
        assert!(!old.steering);
    }

    #[test]
    fn steering_outcomes_are_exact() {
        assert_eq!(
            SteerOutcome::from_result(&json!({"outcome": "injected"})),
            Some(SteerOutcome::Injected)
        );
        assert_eq!(
            SteerOutcome::from_result(
                &json!({"outcome": "promptRequired", "reason": "noRunningTurn"})
            ),
            Some(SteerOutcome::PromptRequired)
        );
        for unknown in [
            json!({"outcome": "startedNewTurn"}),
            json!({"outcome": "promptRequired"}),
            json!({"outcome": "Injected"}),
            json!({}),
            json!(null),
        ] {
            assert_eq!(SteerOutcome::from_result(&unknown), None, "{unknown}");
        }
        let params = steering_params("s", vec![json!({"type": "text", "text": "x"})]);
        assert_eq!(params["_meta"]["steering"]["idleBehavior"], "promptRequired");
        assert_eq!(params["prompt"][0]["text"], "x");
    }

    #[test]
    fn other_versions_are_refused() {
        assert_eq!(
            negotiate(&json!({"protocolVersion": 2})),
            Err(NegotiationError::UnsupportedVersion(2))
        );
        assert_eq!(negotiate(&json!({})), Err(NegotiationError::Malformed));
    }

    #[test]
    fn the_client_advertises_no_host_file_or_terminal_access() {
        let params = initialize_params();
        assert_eq!(params["clientCapabilities"]["fs"]["readTextFile"], false);
        assert_eq!(params["clientCapabilities"]["fs"]["writeTextFile"], false);
        assert_eq!(params["clientCapabilities"]["terminal"], false);
        assert!(params["clientCapabilities"].get("elicitation").is_none());
        assert!(params["clientCapabilities"].get("session").is_none());
    }

    #[test]
    fn permission_options_keep_opaque_ids_and_reject_duplicates() {
        let (session, _, options) = permission_request(&json!({
            "sessionId": "s",
            "toolCall": {"toolCallId": "t"},
            "options": [
                {"optionId": "opt:1 ✓", "name": "Allow", "kind": "allow_once"},
                {"optionId": "x", "name": "Future", "kind": "ask_later"},
            ],
        }))
        .expect("valid");
        assert_eq!(session, "s");
        assert_eq!(options[0].option_id, "opt:1 ✓");
        assert_eq!(options[1].kind, "ask_later");
        assert!(permission_request(&json!({
            "sessionId": "s", "toolCall": {},
            "options": [
                {"optionId": "a", "name": "A", "kind": "allow_once"},
                {"optionId": "a", "name": "B", "kind": "reject_once"},
            ],
        }))
        .is_none());
        assert!(
            permission_request(&json!({"sessionId": "s", "toolCall": {}, "options": []})).is_none()
        );
    }

    #[test]
    fn settings_validate_values_and_drop_booleans() {
        let mut settings = SessionSettings::from_response(&json!({
            "configOptions": [
                {"id": "model", "name": "Model", "type": "select", "currentValue": "a",
                 "options": [{"value": "a", "name": "A"}, {"group": "g", "name": "G", "options": [{"value": "b", "name": "B"}]}]},
                {"id": "fast", "name": "Fast", "type": "boolean", "currentValue": false},
            ],
            "modes": {"currentModeId": "ask", "availableModes": [{"id": "ask", "name": "Ask"}, {"id": "code", "name": "Code"}]},
        }));
        assert_eq!(settings.config_options.len(), 1);
        assert!(settings.allows_config_value("model", "b"));
        assert!(!settings.allows_config_value("model", "z"));
        assert!(!settings.allows_config_value("fast", "true"));
        assert!(settings.allows_mode("code"));
        settings.set_current_mode("code");
        assert_eq!(settings.modes.expect("modes")["currentModeId"], "code");
    }

    #[test]
    fn a_long_model_catalog_keeps_every_value() {
        // The 32 limit counts option definitions; a provider catalog can have
        // hundreds of values when agents list all configured providers.
        let values: Vec<_> = (0..300)
            .map(|i| json!({"value": format!("p/vendor/m{i}"), "name": format!("M{i}")}))
            .collect();
        let settings = SessionSettings::from_response(&json!({
            "configOptions": [
                {"id": "model", "name": "Model", "type": "select",
                 "currentValue": "p/vendor/m0", "options": values},
            ],
        }));
        assert_eq!(
            settings.config_options[0]["options"]
                .as_array()
                .map(Vec::len),
            Some(300)
        );
        assert!(settings.allows_config_value("model", "p/vendor/m299"));
    }

    #[test]
    fn outcomes_use_the_gateway_wire_shape() {
        let stopped = TurnOutcome::Stopped {
            stop_reason: "end_turn".into(),
        };
        assert_eq!(
            serde_json::to_value(&stopped).expect("encode"),
            json!({"kind": "stopped", "stopReason": "end_turn"})
        );
        assert_eq!(
            serde_json::to_value(TurnOutcome::AgentExited).expect("encode"),
            json!({"kind": "agentExited"})
        );
    }

    #[test]
    fn unknown_stop_reasons_survive() {
        assert_eq!(
            TurnOutcome::from_prompt_result(&json!({"stopReason": "paused_for_review"})),
            TurnOutcome::Stopped {
                stop_reason: "paused_for_review".into()
            }
        );
    }
}
