//! Native OpenCode wire values used by the host and controller.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A model reference; provider and model IDs are independent opaque strings.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Model {
    /// Native provider ID.
    #[serde(rename = "providerID")]
    pub provider_id: String,
    /// Native model ID, which may contain slashes.
    #[serde(rename = "modelID")]
    pub model_id: String,
}

/// Persisted native session metadata.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    /// Original OpenCode session ID.
    pub id: String,
    /// Session title.
    pub title: String,
    /// Authoritative working directory.
    pub directory: String,
    /// Parent session for native subagents.
    #[serde(default, rename = "parentID")]
    pub parent_id: Option<String>,
    /// Millisecond creation and update times.
    pub time: SessionTime,
}

/// Native session timestamps, in Unix milliseconds.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SessionTime {
    /// Creation time.
    pub created: u64,
    /// Most recent update.
    pub updated: u64,
    /// Archive time, when archived.
    #[serde(default)]
    pub archived: Option<u64>,
}

/// The state reported by one native server, not a database-wide writer lease.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Status {
    /// No execution runs in this server.
    Idle,
    /// Execution runs or is waiting for a tool, permission or answer.
    Busy,
    /// The server is retrying a provider request.
    Retry {
        /// Attempt count.
        attempt: u64,
        /// Provider's retry explanation.
        message: String,
        /// Next attempt time, in milliseconds.
        next: u64,
    },
    /// An unknown native status cannot grant write admission.
    #[serde(other)]
    Unknown,
}

impl Status {
    /// Whether this status positively reports ongoing execution.
    pub fn running(&self) -> bool {
        matches!(self, Self::Busy | Self::Retry { .. })
    }
}

/// A native message and its ordered parts. Tool inputs are provider-defined
/// JSON; the controller projects only the supported public fields.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Message {
    /// Native message metadata, including role, ID, model and completion.
    pub info: Value,
    /// Text, reasoning, tool, attachment and usage parts.
    pub parts: Vec<Value>,
}

/// A bounded native message window, oldest message first.
#[derive(Debug, Clone)]
pub struct MessagePage {
    /// Messages in this window.
    pub messages: Vec<Message>,
    /// Opaque `X-Next-Cursor` returned by the native server.
    pub next_before: Option<String>,
}

/// One input sent directly through OpenCode's native prompt API.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Prompt {
    /// Caller-generated native message ID for correlating admission/events.
    #[serde(skip_serializing_if = "Option::is_none", rename = "messageID")]
    pub message_id: Option<String>,
    /// Explicit model, when selected.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<Model>,
    /// Native primary agent, such as build or plan.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent: Option<String>,
    /// Exact variant advertised by the selected model.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub variant: Option<String>,
    /// Native text or file input parts.
    pub parts: Vec<Value>,
}

/// The statuses known to one server instance, keyed by original session ID.
pub type Statuses = BTreeMap<String, Status>;
