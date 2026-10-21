//! Public native catalog fields. Provider credentials and options stay local.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::schema::Model;

/// One usable native model and only the controls it actually advertises.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CatalogModel {
    /// Exact provider identifier.
    pub provider: String,
    /// Provider's display label.
    pub provider_name: String,
    /// Exact model identifier, which may itself contain slashes.
    pub id: String,
    /// Model display label.
    pub name: String,
    /// Exact named native variants, without their private option contents.
    pub variants: Vec<String>,
    /// The model accepts image input.
    pub images: bool,
}

impl CatalogModel {
    /// Picker value, preserving the original provider and model identifiers.
    pub fn key(&self) -> String {
        format!("{}/{}", self.provider, self.id)
    }

    /// Native prompt's structured model selection.
    pub fn selection(&self) -> Model {
        Model {
            provider_id: self.provider.clone(),
            model_id: self.id.clone(),
        }
    }
}

/// A selectable, visible primary native agent.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct Agent {
    /// Exact agent name sent on prompts.
    pub name: String,
    /// Public description; no prompt, tools or permission configuration.
    pub description: Option<String>,
}

/// Public command metadata; templates and provider options never cross the
/// wire.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
pub struct Command {
    /// Exact name, without `/`.
    pub name: String,
    /// Public description.
    pub description: Option<String>,
    /// Native origin such as `command`, `mcp`, or `skill`.
    pub source: String,
    /// Native argument hints.
    pub hints: Vec<String>,
}

/// Sanitized provider/agent/command inventory for one project instance.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Catalog {
    /// Models from native connected providers only.
    pub models: Vec<CatalogModel>,
    /// Visible agents which may lead a conversation.
    pub agents: Vec<Agent>,
    /// Commands advertised by the same instance.
    pub commands: Vec<Command>,
    /// Native provider defaults, kept only when they name a usable model.
    pub defaults: BTreeMap<String, String>,
    /// Number of native connected providers.
    pub providers_connected: usize,
}

/// The 1.x `/provider` answer.
#[derive(Deserialize)]
pub(crate) struct Providers {
    all: Vec<Value>,
    default: BTreeMap<String, String>,
    connected: Vec<String>,
}

impl Catalog {
    /// The public 1.x catalog. Raw provider configuration is discarded here,
    /// before anything is serialized for a controller.
    pub(crate) fn public(providers: Providers, agents: Vec<Value>, commands: Vec<Value>) -> Self {
        let connected: BTreeSet<_> = providers.connected.into_iter().collect();
        let mut models = Vec::new();
        for provider in providers.all {
            let Some(id) = provider["id"].as_str().filter(|id| connected.contains(*id)) else {
                continue;
            };
            let name = provider["name"].as_str().unwrap_or(id);
            let Some(entries) = provider["models"].as_object() else { continue };
            for (key, model) in entries {
                if model["status"] == "deprecated" {
                    continue;
                }
                let id = model["id"].as_str().unwrap_or(key);
                models.push(CatalogModel {
                    provider: provider["id"].as_str().unwrap_or_default().into(),
                    provider_name: name.into(),
                    id: id.into(),
                    name: model["name"].as_str().unwrap_or(id).into(),
                    variants: model["variants"]
                        .as_object()
                        .into_iter()
                        .flat_map(|v| v.keys().cloned())
                        .collect(),
                    images: model["capabilities"]["input"]["image"] == true,
                });
            }
        }
        let agents = agents
            .into_iter()
            .filter(|a| a["hidden"] != true && a["mode"] != "subagent")
            .filter_map(|a| {
                Some(Agent {
                    name: a["name"].as_str()?.into(),
                    description: a["description"].as_str().map(str::to_owned),
                })
            })
            .collect();
        let commands = commands
            .into_iter()
            .filter_map(|c| {
                Some(Command {
                    name: c["name"].as_str()?.into(),
                    description: c["description"].as_str().map(str::to_owned),
                    source: c["source"].as_str().unwrap_or("command").into(),
                    hints: c["hints"]
                        .as_array()
                        .into_iter()
                        .flatten()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect(),
                })
            })
            .collect();
        Self::assemble(models, agents, commands, providers.default, connected.len())
    }

    /// Order and deduplicate models, keeping only defaults that name one.
    pub(crate) fn assemble(
        mut models: Vec<CatalogModel>,
        agents: Vec<Agent>,
        commands: Vec<Command>,
        defaults: BTreeMap<String, String>,
        providers_connected: usize,
    ) -> Self {
        models.sort_by_key(CatalogModel::key);
        models.dedup_by(|a, b| a.provider == b.provider && a.id == b.id);
        let defaults = defaults
            .into_iter()
            .filter(|(provider, id)| {
                models
                    .iter()
                    .any(|model| &model.provider == provider && &model.id == id)
            })
            .collect();
        Self {
            models,
            agents,
            commands,
            defaults,
            providers_connected,
        }
    }

    /// Resolve one exact picker key. Never guess a model from its suffix.
    pub fn model(&self, key: &str) -> Option<&CatalogModel> {
        self.models.iter().find(|model| model.key() == key)
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn secrets_disconnected_models_hidden_agents_and_templates_never_leave_the_host() {
        let providers = serde_json::from_value(json!({
            "connected":["a"], "default":{"a":"nested/model","b":"private"},
            "all":[
                {"id":"a","name":"Provider A","options":{"apiKey":"SECRET_PROVIDER"},
                 "models":{"nested/model":{"name":"Real model","capabilities":{"input":{"image":true}},
                    "headers":{"Authorization":"SECRET_HEADER"},"variants":{"careful":{"apiKey":"SECRET_VARIANT"}}}}},
                {"id":"b","models":{"private":{}}}
            ]
        })).expect("provider response");
        let catalog = Catalog::public(
            providers,
            vec![
                json!({"name":"build","mode":"primary","prompt":"SECRET_PROMPT"}),
                json!({"name":"hidden","hidden":true}),
                json!({"name":"helper","mode":"subagent"}),
            ],
            vec![json!({"name":"review","template":"SECRET_TEMPLATE","hints":["path"]})],
        );
        assert_eq!(catalog.models.len(), 1);
        assert_eq!(catalog.models[0].key(), "a/nested/model");
        assert_eq!(catalog.models[0].variants, ["careful"]);
        assert!(catalog.models[0].images);
        assert_eq!(catalog.agents.len(), 1);
        assert_eq!(catalog.defaults.len(), 1);
        let wire = serde_json::to_string(&catalog).expect("public catalog");
        assert!(!wire.contains("SECRET"));
        assert!(!wire.contains("private"));
        assert!(catalog.model("nested/model").is_none());
    }
}
