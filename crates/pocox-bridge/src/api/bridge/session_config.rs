//! ACP session settings: config options and modes.

use super::*;
use crate::engine::execution::{self, Lane};

#[cfg(test)]
mod settings_dto_tests {
    use serde_json::json;

    use super::settings_dto;

    #[test]
    fn every_advertised_value_reaches_dart_verbatim() {
        let flat: Vec<_> = (0..200)
            .map(|i| json!({"value": format!("openrouter/vendor/m{i}"), "name": format!("M{i}")}))
            .collect();
        let dto = settings_dto(&json!({
            "configOptions": [
                {"id": "model", "name": "Model", "currentValue": "openrouter/vendor/m7",
                 "options": flat},
                {"id": "effort", "name": "Effort", "category": "thought_level",
                 "currentValue": "high",
                 "options": [{"group": "g", "name": "Group", "options": [
                     {"value": "low", "name": "Low"}, {"value": "high", "name": "High"}]}]},
            ],
        }));
        let model = &dto.config_options[0];
        assert_eq!(model.values.len(), 200);
        assert_eq!(model.values[199].value, "openrouter/vendor/m199");
        assert_eq!(model.current_value, "openrouter/vendor/m7");
        let effort = &dto.config_options[1];
        assert_eq!(effort.category.as_deref(), Some("thought_level"));
        assert_eq!(effort.values.len(), 2);
        assert_eq!(effort.values[1].group.as_deref(), Some("Group"));
    }
}

/// One value of an ACP select configuration option.
pub struct SessionConfigValueDto {
    /// Opaque value id, sent back verbatim.
    pub value: String,
    /// Label.
    pub name: String,
    /// Group label, when the agent groups values.
    pub group: Option<String>,
    /// Description.
    pub description: Option<String>,
}

/// One ACP select configuration option (model, mode, thought level, …).
pub struct SessionConfigOptionDto {
    /// Opaque option id.
    pub id: String,
    /// Label.
    pub name: String,
    /// Semantic category (`model`, `mode`, `thought_level`, …), UX only.
    pub category: Option<String>,
    /// Description.
    pub description: Option<String>,
    /// Current value id.
    pub current_value: String,
    /// Selectable values, in agent order.
    pub values: Vec<SessionConfigValueDto>,
}

/// One legacy ACP session mode.
pub struct SessionModeDto {
    /// Opaque mode id.
    pub id: String,
    /// Label.
    pub name: String,
    /// Description.
    pub description: Option<String>,
}

/// Per-session state an ACP agent reported. Everything is optional: agents
/// that report nothing show no controls.
pub struct SessionSettingsDto {
    /// Select configuration options.
    pub config_options: Vec<SessionConfigOptionDto>,
    /// Current legacy mode id.
    pub current_mode: Option<String>,
    /// Advertised legacy modes.
    pub modes: Vec<SessionModeDto>,
    /// Context tokens in use, when reported.
    pub usage_used: Option<i64>,
    /// Context window size, when reported.
    pub usage_size: Option<i64>,
    /// A turn is running.
    pub running: bool,
    /// Cancellation was requested and the agent has not finished yet.
    pub cancel_requested: bool,
}

fn opt_str(value: &serde_json::Value) -> Option<String> {
    value.as_str().map(str::to_string)
}

fn settings_dto(body: &serde_json::Value) -> SessionSettingsDto {
    let config_options = body["configOptions"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|option| {
            let mut values = Vec::new();
            for entry in option["options"].as_array().into_iter().flatten() {
                if let Some(nested) = entry["options"].as_array() {
                    for value in nested {
                        values.push(SessionConfigValueDto {
                            value: value["value"].as_str().unwrap_or("").to_string(),
                            name: value["name"].as_str().unwrap_or("").to_string(),
                            group: opt_str(&entry["name"]),
                            description: opt_str(&value["description"]),
                        });
                    }
                } else {
                    values.push(SessionConfigValueDto {
                        value: entry["value"].as_str().unwrap_or("").to_string(),
                        name: entry["name"].as_str().unwrap_or("").to_string(),
                        group: None,
                        description: opt_str(&entry["description"]),
                    });
                }
            }
            SessionConfigOptionDto {
                id: option["id"].as_str().unwrap_or("").to_string(),
                name: option["name"].as_str().unwrap_or("").to_string(),
                category: opt_str(&option["category"]),
                description: opt_str(&option["description"]),
                current_value: option["currentValue"].as_str().unwrap_or("").to_string(),
                values,
            }
        })
        .collect();
    let modes = body["modes"]["availableModes"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|mode| SessionModeDto {
            id: mode["id"].as_str().unwrap_or("").to_string(),
            name: mode["name"].as_str().unwrap_or("").to_string(),
            description: opt_str(&mode["description"]),
        })
        .collect();
    SessionSettingsDto {
        config_options,
        current_mode: opt_str(&body["modes"]["currentModeId"]),
        modes,
        usage_used: body["usage"]["used"].as_i64(),
        usage_size: body["usage"]["size"].as_i64(),
        running: body["runningTurnId"].is_string(),
        cancel_requested: body["cancelRequested"] == true,
    }
}

/// Latest native session choices in that session's project, or the ACP
/// controller's cached state. Unknown or unavailable settings return `None`.
#[frb(sync)]
pub fn app_session_settings(service_key: String, thread_id: String) -> Option<SessionSettingsDto> {
    engine(&service_key)
        .session_settings(&service_key, &thread_id)
        .map(|body| settings_dto(&body))
}

/// Refresh native session choices off the UI thread, or read cached ACP state.
/// OpenCode may perform network requests; UI callers should use this entry
/// point. Read failures are errors, never authoritative empty settings.
pub async fn app_session_settings_refresh(
    service_key: String,
    thread_id: String,
) -> Result<Option<SessionSettingsDto>> {
    execution::run(Lane::Read, move || {
        if session_engine::protocol_of(&service_key) == session_engine::Protocol::OpenCode {
            crate::engine::opencode::refresh_settings(&service_key, &thread_id)
                .map(|body| Some(settings_dto(&body)))
        } else {
            Ok(app_session_settings(service_key, thread_id))
        }
    })
    .await
}

/// Read draft choices in the selected native project without opening a session.
pub async fn app_draft_session_settings(
    service_key: String,
    directory: Option<String>,
) -> Result<Option<SessionSettingsDto>> {
    execution::run(Lane::Read, move || {
        if session_engine::protocol_of(&service_key) == session_engine::Protocol::OpenCode {
            crate::engine::opencode::draft_settings(&service_key, directory.as_deref())
                .map(|body| Some(settings_dto(&body)))
        } else {
            Ok(app_session_settings(service_key, String::new()))
        }
    })
    .await
}

/// Set an ACP select configuration option to one of its advertised values.
/// The agent answers with the complete new option state.
pub async fn app_set_session_config(
    service_key: String,
    thread_id: String,
    config_id: String,
    value: String,
) -> Result<()> {
    execution::run(Lane::Control, move || {
        engine(&service_key).set_session_config(&service_key, &thread_id, &config_id, &value)
    })
    .await
}

/// Switch an ACP session's legacy mode to one it advertised.
pub async fn app_set_session_mode(
    service_key: String,
    thread_id: String,
    mode_id: String,
) -> Result<()> {
    execution::run(Lane::Control, move || {
        engine(&service_key).set_session_mode(&service_key, &thread_id, &mode_id)
    })
    .await
}
