//! The `pocox` MCP server: `services` (read) and `connect` (act).
//!
//! Plain MCP tools over Streamable HTTP, so every MCP harness gets every
//! capability. Codex's `threadId` in a call's `_meta`, where present, names
//! the conversation an action belongs to. Schemas stay flat objects (no
//! top-level `oneOf`), which every model provider accepts.

use std::sync::Arc;

use axum::http::request::Parts;
use rmcp::model::{
    CallToolRequestParams, CallToolResponse, CallToolResult, ContentBlock, Implementation,
    InitializeResult, JsonObject, ListToolsResult, PaginatedRequestParams, ServerCapabilities,
    ServerConfig, Tool, ToolAnnotations,
};
use rmcp::service::RequestContext;
use rmcp::{ErrorData, RoleServer, ServerHandler};
use serde_json::{json, Value};

use super::connections::{self, ConnectRequest};
use super::error::{Pending, ToolError};
use super::model::{bounded, Lifetime, Overview, OwnerView, MAX_LIFETIME_MINUTES};
use super::shares::{self, Caller, ShareRequest};
use super::tokens::Principal;
use super::{catalog, persistence, render};

const INSTRUCTIONS: &str = "The user's devices and the services on them. Share a dev server or \
                            other local port with the user's phone and other devices, or connect \
                            to a service running on another of their devices. Sharing maps an \
                            already running server; it does not start it or install autostart. \
                            For ongoing use, share first, then use action=keep_sharing to save it \
                            across agent and POCOX restarts. Never treat permanent=true as saved.";

fn schema(value: Value) -> Arc<JsonObject> {
    match value {
        Value::Object(map) => Arc::new(map),
        _ => Arc::new(JsonObject::new()),
    }
}

/// Every tool, as harnesses list them. Hosted harnesses run all of them
/// without asking ([`super::inject`]): POCOX asks the user itself where it
/// matters, whatever the harness's approval policy.
pub fn tools() -> Vec<Tool> {
    vec![services_tool(), connect_tool()]
}

fn services_tool() -> Tool {
    Tool::new(
        "services",
        "List the user's devices (computers, phones) and the services on them through POCOX: \
         agent hosts (Codex, Claude, OpenCode), Responses APIs, and ports shared from a device \
         (dev servers, previews), with status and who shared them. Read-only.",
        schema(json!({
            "type": "object",
            "properties": {
                "device": {"type": "string", "description": "Only this device (its name)."},
                "kind": {
                    "type": "string",
                    "enum": ["agent", "api", "port", "all"],
                    "description": "Only this kind of service. Default all."
                },
                "status": {
                    "type": "string",
                    "enum": ["online", "offline", "all"],
                    "description": "Only services in this state. Default all."
                },
                "mine": {
                    "type": "boolean",
                    "description": "Only what this conversation shared or connected."
                }
            },
            "additionalProperties": false
        })),
    )
    .with_title("Devices and services")
    .annotate(
        ToolAnnotations::new()
            .read_only(true)
            .idempotent(true)
            .open_world(false),
    )
}

fn connect_tool() -> Tool {
    Tool::new(
        "connect",
        "Share a local port of this machine with the user's other devices (for example a dev \
         server the user wants to preview on their phone), stop sharing it, or connect to a \
         service on another of the user's devices so it is reachable on this machine. \
         action=share needs `ports`; stop_sharing needs `service` (a key or port); connect and \
         disconnect need `service` (a key, `device:kind:name` or `device/port`). A share or \
         connection lasts at most as long as its agent, with a default 24-hour timer. \
         `expires_in_minutes` changes the timer; legacy `permanent=true` removes ONLY the timer. \
         For long-term use, action=keep_sharing with `service` saves an existing share across \
         agent and POCOX restarts, after separate user consent. The saved share is managed by \
         the user, not the agent. POCOX and the local server still need to run. \
         Repeating share renews the timer. A connection's result says how it travels (direct P2P or the \
         relay), as `services` does for every connection. A share, or a connection to another \
         device's Responses API, may wait for the user's consent in POCOX; repeating the same \
         call continues it.",
        schema(json!({
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["share", "keep_sharing", "stop_sharing", "connect", "disconnect"],
                    "description": "What to do."
                },
                "ports": {
                    "type": "array",
                    "items": {"type": "integer", "minimum": 1, "maximum": 65535},
                    "maxItems": 4,
                    "description": "share: loopback ports of this machine, the page's port \
                                    first (add its API port so absolute localhost URLs keep \
                                    working)."
                },
                "title": {"type": "string", "description": "share: what it is, e.g. \"Landing page\"."},
                "path": {"type": "string", "description": "share: path to open, default \"/\"."},
                "scheme": {
                    "type": "string", "enum": ["http", "https"],
                    "description": "share: how the page is served, default http."
                },
                "wait_ready_seconds": {
                    "type": "integer", "minimum": 0, "maximum": 20,
                    "description": "share: how long to wait for the first port to answer."
                },
                "service": {
                    "type": "string",
                    "description": "keep_sharing, stop_sharing: share id, port or service key. \
                                    connect, disconnect: the service."
                },
                "local_port": {
                    "type": "integer", "minimum": 1, "maximum": 65535,
                    "description": "connect: local port to use instead of the service's own."
                },
                "expires_in_minutes": {
                    "type": "integer", "minimum": 1, "maximum": MAX_LIFETIME_MINUTES,
                    "description": "share, connect: end it after this many minutes instead of \
                                    the default 24 hours; repeating the call renews it."
                },
                "permanent": {
                    "type": "boolean",
                    "description": "Legacy name: share, connect only. Removes the expiry \
                                    timer but still ends when the agent or POCOX stops; does \
                                    NOT save across restarts. To save a share, use action \
                                    keep_sharing after sharing it."
                }
            },
            "required": ["action"],
            "additionalProperties": false
        })),
    )
    .with_title("Share or connect a service")
    .annotate(
        ToolAnnotations::new()
            .read_only(false)
            .destructive(false)
            .idempotent(true)
            .open_world(true),
    )
}

/// The tools, for one request.
#[derive(Clone, Default)]
pub struct Tools;

fn number(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .or_else(|| value.as_str().and_then(|s| s.trim().parse().ok()))
}

fn port(value: Option<&Value>) -> Option<u16> {
    value.and_then(number).and_then(|n| u16::try_from(n).ok())
}

fn text(value: Option<&Value>) -> Option<String> {
    value.and_then(Value::as_str).map(str::to_string)
}

/// The lifetime an agent asked for: `expires_in_minutes` or `permanent`.
fn lifetime(args: &JsonObject) -> Result<Lifetime, ToolError> {
    let minutes = args.get("expires_in_minutes").and_then(number);
    let permanent = args
        .get("permanent")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    match (minutes, permanent) {
        (Some(_), true) => {
            Err(ToolError::Invalid("Give `expires_in_minutes` or `permanent`, not both.".into()))
        },
        (Some(minutes @ 1..=MAX_LIFETIME_MINUTES), false) => Ok(Lifetime::Minutes(minutes)),
        (Some(_), false) => Err(ToolError::Invalid(format!(
            "`expires_in_minutes` is from 1 to {MAX_LIFETIME_MINUTES} (a week)."
        ))),
        (None, true) => Ok(Lifetime::Permanent),
        (None, false) => Ok(Lifetime::Lease),
    }
}

fn done(structured: Value, message: String) -> CallToolResult {
    let mut result = CallToolResult::structured(structured);
    result.content = vec![ContentBlock::text(message)];
    result
}

fn failed(error: &ToolError) -> CallToolResult {
    let mut result = CallToolResult::error(vec![ContentBlock::text(error.message())]);
    result.structured_content =
        Some(json!({"status": "error", "code": error.code(), "message": error.message()}));
    result
}

fn pending(pending: &Pending) -> CallToolResult {
    let value = json!({"status": pending.status(), "message": pending.message()});
    done(value, pending.message())
}

/// An agent sees no conversation id in what it gets back, as in `services`:
/// a tunnel or share it joined may be held for another conversation.
fn for_agent(caller: &Caller, owner: &mut OwnerView) {
    if !caller.is_user() {
        owner.conversation = None;
    }
}

async fn services(caller: &Caller, args: &JsonObject) -> CallToolResult {
    let overview: Result<Overview, ToolError> =
        tokio::task::spawn_blocking(catalog::overview_blocking)
            .await
            .map_err(|e| ToolError::Relay(e.to_string()))
            .and_then(|r| r.map_err(|e| ToolError::Relay(format!("{e:#}"))));
    let overview = match overview {
        Ok(overview) => overview,
        Err(error) => return failed(&error),
    };
    let filter = render::Filter {
        device: text(args.get("device")),
        kind: text(args.get("kind")),
        status: text(args.get("status")),
        mine: args
            .get("mine")
            .and_then(Value::as_bool)
            .unwrap_or(false)
            .then(|| caller.key()),
    };
    let mut overview = render::filter(overview, &filter);
    if !caller.is_user() {
        overview = render::for_agent(overview);
    }
    let message = render::table(&overview);
    done(serde_json::to_value(&overview).unwrap_or_default(), message)
}

async fn act(caller: &Caller, args: &JsonObject) -> CallToolResult {
    let action = text(args.get("action")).unwrap_or_default();
    let service = text(args.get("service"));
    let lifetime = match lifetime(args) {
        Ok(lifetime) => lifetime,
        Err(error) => return failed(&error),
    };
    match action.as_str() {
        "keep_sharing" => match service.as_deref() {
            Some(service) => match persistence::request_keep(caller, service).await {
                Ok(Ok(mut shared)) => {
                    for_agent(caller, &mut shared.share.owner);
                    let message = render::shared(&shared);
                    let mut value = serde_json::to_value(&shared).unwrap_or_default();
                    value["status"] = json!("shared");
                    value["service"] = json!(shared.share.first_key());
                    done(value, message)
                },
                Ok(Err(waiting)) => pending(&waiting),
                Err(error) => failed(&error),
            },
            None => failed(&ToolError::Invalid("keep_sharing needs `service`.".into())),
        },
        "share" => {
            let request = ShareRequest {
                ports: args
                    .get("ports")
                    .and_then(Value::as_array)
                    .map(|ports| ports.iter().filter_map(|p| port(Some(p))).collect())
                    .or_else(|| port(args.get("port")).map(|p| vec![p]))
                    .unwrap_or_default(),
                title: text(args.get("title")),
                path: text(args.get("path")),
                wait_ready_seconds: args.get("wait_ready_seconds").and_then(number),
                secure: text(args.get("scheme")).as_deref() == Some("https"),
                epoch: None,
                lifetime,
            };
            match shares::share(caller, request).await {
                Ok(Ok(mut shared)) => {
                    for_agent(caller, &mut shared.share.owner);
                    let message = render::shared(&shared);
                    let mut value = serde_json::to_value(&shared).unwrap_or_default();
                    value["status"] = json!("shared");
                    value["service"] = json!(shared.share.first_key());
                    done(value, message)
                },
                Ok(Err(waiting)) => pending(&waiting),
                Err(error) => failed(&error),
            }
        },
        "stop_sharing" => match service.as_deref() {
            Some(service) => match shares::stop(Some(caller), service) {
                Ok(mut share) => {
                    for_agent(caller, &mut share.owner);
                    done(
                        json!({"status": "stopped", "share": share}),
                        format!("Stopped sharing {}.", share.title),
                    )
                },
                Err(error) => failed(&error),
            },
            None => failed(&ToolError::Invalid("stop_sharing needs `service`.".into())),
        },
        "connect" => match service {
            Some(service) => {
                let request = ConnectRequest {
                    service,
                    local_port: port(args.get("local_port")),
                    lifetime,
                };
                match connections::connect(caller, request).await {
                    Ok(Ok(mut view)) => {
                        for_agent(caller, &mut view.owner);
                        let message = render::connected(&view);
                        let mut value = serde_json::to_value(&view).unwrap_or_default();
                        value["status"] = json!("connected");
                        done(value, message)
                    },
                    Ok(Err(waiting)) => pending(&waiting),
                    Err(error) => failed(&error),
                }
            },
            None => failed(&ToolError::Invalid("connect needs `service`.".into())),
        },
        "disconnect" => match service.as_deref() {
            Some(service) => match connections::disconnect(Some(caller), service) {
                Ok(view) => done(
                    json!({"status": "disconnected", "service": view.service}),
                    format!("Disconnected {}.", view.service),
                ),
                Err(error) => failed(&error),
            },
            None => failed(&ToolError::Invalid("disconnect needs `service`.".into())),
        },
        other => failed(&ToolError::Invalid(format!(
            "Unknown action `{}`; use share, keep_sharing, stop_sharing, connect or disconnect.",
            bounded(other)
        ))),
    }
}

impl ServerHandler for Tools {
    fn get_info(&self) -> ServerConfig {
        InitializeResult::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(
                Implementation::new("pocox", env!("CARGO_PKG_VERSION")).with_title("POCOX"),
            )
            .with_instructions(INSTRUCTIONS)
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        Ok(ListToolsResult::with_all_items(tools()))
    }

    fn get_tool(&self, name: &str) -> Option<Tool> {
        tools().into_iter().find(|tool| tool.name == name)
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        let principal = context
            .extensions
            .get::<Parts>()
            .and_then(|parts| parts.extensions.get::<Principal>())
            .cloned()
            .ok_or_else(|| ErrorData::invalid_request("missing caller", None))?;
        // The SDK moves the request's `_meta` into the context.
        let conversation = context
            .meta
            .0
            .get("threadId")
            .or_else(|| {
                request
                    .meta
                    .as_ref()
                    .and_then(|meta| meta.0.get("threadId"))
            })
            .and_then(Value::as_str)
            .map(bounded)
            .filter(|id| !id.is_empty());
        let caller = Caller {
            principal,
            conversation,
        };
        let args = request.arguments.unwrap_or_default();
        let result = match request.name.as_ref() {
            "services" => services(&caller, &args).await,
            "connect" => act(&caller, &args).await,
            name => {
                return Err(ErrorData::invalid_params(format!("unknown tool `{name}`"), None));
            },
        };
        Ok(CallToolResponse::Complete(result))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_served_tools_are_the_ones_harnesses_are_told_about() {
        let served: Vec<String> = tools().iter().map(|tool| tool.name.to_string()).collect();
        assert_eq!(served, super::super::builtin::MCP_TOOLS);
    }

    #[test]
    fn an_agent_picks_a_lifetime_or_none_but_not_both() {
        let args = |value: Value| value.as_object().cloned().unwrap_or_default();
        assert_eq!(lifetime(&args(json!({}))), Ok(Lifetime::Lease));
        assert_eq!(lifetime(&args(json!({"permanent": true}))), Ok(Lifetime::Permanent));
        assert_eq!(lifetime(&args(json!({"expires_in_minutes": 90}))), Ok(Lifetime::Minutes(90)));
        assert!(lifetime(&args(json!({"expires_in_minutes": 0}))).is_err());
        assert!(lifetime(&args(json!({"expires_in_minutes": 20_000}))).is_err());
        assert!(lifetime(&args(json!({"expires_in_minutes": 5, "permanent": true}))).is_err());
    }
}
