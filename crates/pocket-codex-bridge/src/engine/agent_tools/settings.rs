//! The installation's agent-tools switch.
//!
//! Kept in its own private file beside the device-management preference, not
//! in `config.toml`: older builds refuse unknown fields there and would stop
//! starting after a downgrade.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::engine::host_profiles::{
    self,
    files::{write_private, Committed, FileLock},
};

/// What the user chose; every field has the shipped default when absent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    /// Agents can use the tools on this installation.
    #[serde(default = "yes")]
    pub enabled: bool,
    /// The first share of each owner needs the user's answer.
    #[serde(default = "yes")]
    pub ask_before_sharing: bool,
    /// The endpoint's port, chosen once so installed harness entries stay
    /// valid across restarts.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
}

fn yes() -> bool {
    true
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            enabled: true,
            ask_before_sharing: true,
            port: None,
        }
    }
}

impl Settings {
    /// What applies while the saved settings cannot be read: off, since the
    /// user may have switched the tools off.
    pub fn closed() -> Self {
        Self {
            enabled: false,
            ..Self::default()
        }
    }
}

fn path(root: &Path) -> PathBuf {
    root.join("agent-tools.json")
}

/// The settings saved in the hosting store `root`; defaults when none were
/// saved.
pub fn load_at(root: &Path) -> Result<Settings> {
    match std::fs::read(path(root)) {
        Ok(bytes) => serde_json::from_slice(&bytes).context("reading the agent tools setting"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Settings::default()),
        Err(error) => Err(error).context("reading the agent tools setting"),
    }
}

/// Change the settings saved in `root` under the store lock, durably. An
/// unreadable file is replaced, starting from [`Settings::closed`].
pub fn update_at(root: &Path, change: impl FnOnce(&mut Settings)) -> Result<Settings> {
    let _lock = FileLock::acquire(root)?;
    let mut settings = load_at(root).unwrap_or_else(|_| Settings::closed());
    change(&mut settings);
    // Once renamed into place the file is committed, synced or not.
    if write_private(&path(root), &serde_json::to_vec_pretty(&settings)?)? != Committed::Durable {
        tracing::warn!("the agent tools setting was saved but may not survive a crash");
    }
    Ok(settings)
}

/// This process's saved settings.
pub fn load() -> Result<Settings> {
    load_at(&host_profiles::root()?)
}

/// Change this process's saved settings.
pub fn update(change: impl FnOnce(&mut Settings)) -> Result<Settings> {
    update_at(&host_profiles::root()?, change)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unreadable_file_never_switches_the_tools_on() {
        let root = tempfile::tempdir().expect("dir");
        std::fs::write(path(root.path()), b"{not json").expect("write");
        assert!(load_at(root.path()).is_err());
        let saved = update_at(root.path(), |s| s.ask_before_sharing = false).expect("update");
        assert!(!saved.enabled && !saved.ask_before_sharing);
    }

    #[test]
    fn missing_fields_keep_the_shipped_defaults() {
        let parsed: Settings = serde_json::from_str("{}").expect("empty");
        assert_eq!(parsed, Settings::default());
        let parsed: Settings = serde_json::from_str(r#"{"enabled":false}"#).expect("partial");
        assert!(!parsed.enabled && parsed.ask_before_sharing);
        assert!(!serde_json::to_string(&Settings::default())
            .expect("json")
            .contains("port"));
    }
}
