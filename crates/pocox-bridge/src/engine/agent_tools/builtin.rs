//! POCOX's built-in tools, in one place for every target: the tools the
//! `pocox` MCP server serves (hosted harnesses run them without their own
//! prompt), and the capabilities a user hands an agent from the composer.
//! New tools are added here; the app lists what a device publishes.

use serde::{Deserialize, Serialize};

/// The names of the `pocox` MCP server's tools.
pub const MCP_TOOLS: [&str; 2] = ["services", "connect"];

/// A capability the user can pick in the composer for a message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuiltinTool {
    /// Stable id (`services`, `share`, `connect`).
    pub id: String,
    /// English name, for apps that do not know the id yet.
    pub title: String,
    /// What it lets the agent do, for the agent and for apps that do not
    /// know the id yet.
    pub summary: String,
    /// Whether an agent needs the user's consent to use it. Picking it in
    /// the composer gives that consent for the conversation, like Allow in
    /// this conversation.
    pub gated: bool,
}

/// The capability that sharing a port needs the user's consent for.
pub const SHARE: &str = "share";

/// The capability that connecting another device's Responses API needs the
/// user's consent for: it spends that device's model account. Connecting a
/// shared port needs none (it was shared with the user's devices).
pub const CONNECT: &str = "connect";

/// What this POCOX offers, in the order the composer lists it.
pub fn catalog() -> Vec<BuiltinTool> {
    let tool = |id: &str, title: &str, summary: &str, gated: bool| BuiltinTool {
        id: id.into(),
        title: title.into(),
        summary: summary.into(),
        gated,
    };
    vec![
        tool(
            "services",
            "Devices and services",
            "List the user's devices and the services on them (pocox `services`).",
            false,
        ),
        tool(
            SHARE,
            "Share a port",
            "Share a local port with the user's other devices (pocox `connect`, action `share`); \
             the user has allowed it for this conversation.",
            true,
        ),
        tool(
            CONNECT,
            "Connect a service",
            "Make a service on another of the user's devices reachable here (pocox `connect`, \
             action `connect`), a Responses API included; the user has allowed it for this \
             conversation.",
            true,
        ),
    ]
}
