//! MCP servers an owner adds to its agent's sessions.
//!
//! ACP sends `mcpServers` with every `session/new`, `session/load` and
//! `session/resume`. An owner that serves tools over HTTP hands them to each
//! session it opens, but only to an agent that advertised
//! `mcpCapabilities.http`; other agents keep an empty list.

use serde_json::{Map, Value};

/// Told the id of the session a grant was accepted for; dropped uncalled when
/// the request failed.
pub type Adopt = Box<dyn FnOnce(&str) + Send>;

/// What one session request gets.
pub struct McpGrant {
    /// `mcpServers` entries (ACP `McpServer` objects).
    pub servers: Vec<Value>,
    /// Merged into the request's `_meta` (objects merge key by key).
    pub meta: Option<Map<String, Value>>,
    /// Told the session's id once the agent created or reopened it with this
    /// grant; dropped uncalled when the request failed, so the owner can
    /// withdraw what it handed out.
    pub adopt: Option<Adopt>,
}

/// Supplies the MCP servers of each session request.
pub trait SessionMcp: Send + Sync {
    /// The grant for a session being created (`None`) or reopened; `None`
    /// sends no servers.
    fn grant(&self, session: Option<&str>) -> Option<McpGrant>;

    /// The host stopped tracking `session` (evicted, or closed after a
    /// failed claim): what it was granted can end.
    fn closed(&self, _session: &str) {}
}

/// Merge `patch` into `target`: objects key by key, anything else replaced.
pub fn merge(target: &mut Value, patch: Value) {
    match (target, patch) {
        (Value::Object(target), Value::Object(patch)) => {
            for (key, value) in patch {
                merge(target.entry(key).or_insert(Value::Null), value);
            }
        },
        (target, patch) => *target = patch,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn options_merge_without_dropping_a_provider_route() {
        let mut meta = json!({"claudeCode": {"options": {"env": {"ANTHROPIC_BASE_URL": "u"}}}});
        merge(
            &mut meta,
            json!({"claudeCode": {"options": {"allowedTools": ["mcp__pocox__services"]}}}),
        );
        assert_eq!(meta["claudeCode"]["options"]["env"]["ANTHROPIC_BASE_URL"], "u");
        assert_eq!(meta["claudeCode"]["options"]["allowedTools"][0], "mcp__pocox__services");
    }
}
