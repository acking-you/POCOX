//! Native OpenCode HTTP and server-sent event transport.
//!
//! OpenCode remains an external executable. Its native server owns sessions,
//! messages, tools and model execution; this module never speaks ACP.

pub mod catalog;
pub mod client;
pub mod events;
mod http;
pub mod schema;
mod wire;

pub mod runtime;

pub mod api;
pub mod fold;
pub mod gateway;
pub mod host;
pub mod live;
pub mod ownership;
pub mod public;
pub mod service;
