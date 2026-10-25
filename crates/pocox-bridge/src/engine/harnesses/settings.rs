//! This device's harness update settings, in its hosting state
//! (`<state>/hosting/harnesses.json`): each device keeps its own, changed
//! locally or by an authorized controller through device management. Only
//! the app that owns the hosting state writes them.

use std::collections::BTreeSet;
use std::path::Path;

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

use super::view::SettingsChange;
use super::Kind;
use crate::engine::host_profiles::files::{write_private, Committed, FileLock};
use crate::engine::host_profiles::{self};

const FILE: &str = "harnesses.json";

/// The saved settings.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Settings {
    /// Restart services that use an updated harness (on by default).
    #[serde(default = "enabled")]
    pub(super) restart_services: bool,
    /// Harnesses this device updates by itself, by wire label; labels this
    /// version does not know are kept.
    #[serde(default)]
    pub(super) auto_update: BTreeSet<String>,
}

fn enabled() -> bool {
    true
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            restart_services: true,
            auto_update: BTreeSet::new(),
        }
    }
}

impl Settings {
    /// Whether `kind` updates by itself.
    pub(super) fn auto(&self, kind: Kind) -> bool {
        self.auto_update.contains(kind.label())
    }
}

/// The saved settings (the defaults when none were saved).
pub(super) fn load() -> Result<Settings> {
    load_in(&host_profiles::root()?)
}

pub(super) fn load_in(root: &Path) -> Result<Settings> {
    match std::fs::read(root.join(FILE)) {
        Ok(bytes) => serde_json::from_slice(&bytes).context("reading harness update settings"),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Settings::default()),
        Err(error) => Err(error).context("reading harness update settings"),
    }
}

/// Apply `change` and save it durably; returns the saved settings.
pub(super) fn change(change: &SettingsChange) -> Result<Settings> {
    crate::engine::host_owner::require()?;
    change_in(&host_profiles::root()?, change)
}

pub(super) fn change_in(root: &Path, change: &SettingsChange) -> Result<Settings> {
    if change.auto_update.is_some() != change.kind.is_some() {
        bail!("an automatic update setting names its harness");
    }
    let _lock = FileLock::acquire(root)?;
    let mut settings = load_in(root)?;
    if let (Some(kind), Some(auto)) = (change.kind, change.auto_update) {
        if auto {
            settings.auto_update.insert(kind.label().into());
        } else {
            settings.auto_update.remove(kind.label());
        }
    }
    if let Some(restart) = change.restart_services {
        settings.restart_services = restart;
    }
    if write_private(&root.join(FILE), &serde_json::to_vec(&settings)?)? != Committed::Durable {
        bail!("harness update settings could not be durably saved");
    }
    Ok(settings)
}
