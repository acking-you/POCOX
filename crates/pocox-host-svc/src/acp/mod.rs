//! Generic Agent Client Protocol (ACP v1) support.
//!
//! The host runs any ACP-compatible agent as an owned subprocess, configured
//! as an executable plus argument vector ([`spec`]), and is its only ACP
//! client: strict JSON-RPC 2.0 over stdio ([`jsonrpc`], [`peer`]), version
//! and capability negotiation ([`schema`]), and the session, turn and
//! permission lifecycle ([`host`], [`state`]). Controllers never speak ACP;
//! they use the versioned POCOX gateway ([`api`], [`client`]) over
//! loopback or a relay tunnel. Both sides fold updates with [`fold`]; a
//! controller keeps its live folds aligned with the host's through
//! [`replica`]. Session authority is recorded per agent source ([`store`]).
//!
//! Optional features are used only when the agent advertises them:
//! `session/load` (replay), `session/resume` (no replay), `session/list`,
//! `session/close`, image prompts, select configuration options, legacy
//! modes and the `_session/steering` extension (supplementing a running
//! turn). The Claude preset's launch is resolved by [`claude`] (adapter,
//! Node.js runtime and native CLI) and its adapter can be prepared into an
//! app-owned cache by [`claude_setup`]. The client advertises no file system,
//! terminal, elicitation, boolean-option or other extension capability, and
//! answers such requests with "method not found" without touching any file.

pub mod api;
pub mod claude;
pub mod claude_setup;
pub mod client;
pub mod fold;
pub mod grok;
pub mod grok_control;
pub mod host;
pub mod jsonrpc;
pub mod mcp;
pub mod peer;
pub mod provider;
pub mod replica;
pub mod schema;
pub mod session_control;
pub mod spec;
pub mod state;
pub mod store;

pub use client::{ClientError, GatewayClient};
pub use host::{AgentHost, HostError, HostOptions, Identity};
pub use mcp::{McpGrant, SessionMcp};
pub use replica::Replica;
pub use schema::SteerOutcome;
pub use spec::{AgentSpec, Preset, SpecError, PRESETS};
pub use store::{SessionStore, SourceId};
