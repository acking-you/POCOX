//! Non-bridged engine: pure logic + the tokio runtime/registry. Kept
//! separate from `api/` so it is unit-testable without flutter_rust_bridge.
pub mod account;
pub mod acp;
pub mod agent_tools;
pub mod app_session;
pub mod claude_setup;
pub mod codex_login;
pub mod config;
pub mod daemon;
pub mod discovery;
// The galaxy's frame geometry, called by the app through `dart:ffi`.
#[cfg(feature = "flutter")]
pub mod galaxy;
pub mod grok_account;
pub mod host_apply;
mod host_lease;
pub mod host_lifecycle;
mod host_names;
pub mod host_owner;
pub mod host_profiles;
mod host_services;
pub mod host_start;
pub mod hosting;
#[cfg(test)]
mod hosting_live_tests;
pub mod logging;
pub mod management;
pub mod management_client;
pub mod management_runtimes;
pub mod meta;
pub mod native_sessions;
pub mod opencode;
mod owned_child;
pub mod runtime;
pub mod serve;
pub mod serve_acp;
pub mod serve_opencode;
pub mod session_cache;
pub mod session_engine;
pub mod session_sync;
pub mod sessions;
pub mod transport;
pub mod updates;
