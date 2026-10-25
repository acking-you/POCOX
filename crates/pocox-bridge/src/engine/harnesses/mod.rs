//! Per-device management of the external harnesses this computer hosts
//! (Codex, native OpenCode, the `claude` CLI behind the Claude preset, Grok
//! Build): the installed version, whether its vendor publishes a newer one,
//! and updating it with the vendor's own installer, after which the
//! services that run it restart on the new version.
//!
//! Every device answers for itself, locally or through its device
//! management entry, and keeps its own settings (automatic update per
//! harness, restarting services). Requests name a harness kind only: the
//! executable, the installer and its arguments are this computer's own.
//! Version lookups and installers use the app's network proxy. See
//! `docs/harness-updates.md`.

mod command;
mod install;
mod kind;
mod latest;
mod restart;
mod service;
mod settings;
mod view;

pub use kind::Kind;
pub use service::{check, initialize, overview, set, update, Refusal};
pub use view::{Overview, SettingsChange};

#[cfg(test)]
mod tests;
