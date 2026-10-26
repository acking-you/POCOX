//! What a device reports about its harnesses, on the management wire and to
//! the local app. Kinds, states and reasons are lower-case codes, strings on
//! the wire, so a controller tolerates codes a newer host adds; texts are the
//! controller's own. Nothing here carries child output, paths or proxy
//! values.

use serde::{Deserialize, Serialize};

use super::Kind;

/// One harness on this device.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Harness {
    /// `codex`, `opencode`, `claude` or `grok`.
    pub kind: String,
    /// Its executable was found.
    pub installed: bool,
    /// The installed version, when it reports one.
    pub version: Option<String>,
    /// The newest version its vendor publishes for this installation.
    pub latest: Option<String>,
    /// [`Self::latest`] is newer than [`Self::version`].
    pub update_available: bool,
    /// How it updates: `npm`, `bun`, `pnpm`, `brew`, `standalone` or `own`
    /// (the harness's own updater); absent when it cannot be updated here.
    pub method: Option<String>,
    /// An update can be started on this device.
    pub can_update: bool,
    /// Why it cannot be checked or updated: `unmanaged`, `winget`,
    /// `bundled`, `version_unknown` or `check_failed`.
    pub problem: Option<String>,
    /// This device updates it by itself once a newer version appears.
    pub auto_update: bool,
    /// Running services of this device that use it.
    pub services: Vec<String>,
}

/// Every harness this device can host, with its update settings.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Overview {
    /// One row per hostable kind, in display order; none before the first
    /// check.
    pub harnesses: Vec<Harness>,
    /// When the newest versions were last looked up (Unix milliseconds).
    pub checked_at_ms: Option<u64>,
    /// A lookup is running.
    pub checking: bool,
    /// Services that use an updated harness restart with the new version.
    pub restart_services: bool,
    /// The running or most recent update.
    pub job: Option<Job>,
}

/// One update of one harness.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    /// Its number on this device.
    pub run: u64,
    /// The harness it updates.
    pub kind: String,
    /// `running`, `done` or `failed`.
    pub state: String,
    /// While running: `stopping`, `updating`, `downloading`, `installing`,
    /// `verifying` or `restarting`.
    pub stage: Option<String>,
    /// Download measurements reported by the installer, when available.
    #[serde(default)]
    pub download: Option<Download>,
    /// Elapsed time measured on the host, independent of controller clock skew.
    #[serde(default)]
    pub elapsed_ms: Option<u64>,
    /// Started by this device's automatic update, not by a person.
    pub automatic: bool,
    /// The version before the update.
    pub from_version: Option<String>,
    /// The version installed after it, once known.
    pub to_version: Option<String>,
    /// Why it failed: `unavailable`, `tool_missing`, `in_use`, `permission`,
    /// `timed_out` or `failed`.
    pub failure: Option<String>,
    /// Services restarted with the installed version.
    pub restarted: Vec<String>,
    /// Services that use the harness but were not restarted, and why.
    pub not_restarted: Vec<Skipped>,
    /// When it started (Unix milliseconds).
    pub started_at_ms: u64,
    /// When it finished (Unix milliseconds).
    pub finished_at_ms: Option<u64>,
}

/// Installer-reported download progress. Absent values are unknown, not zero.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Download {
    /// Bytes received for the current file.
    pub downloaded_bytes: Option<u64>,
    /// Size of the current file, when known.
    pub total_bytes: Option<u64>,
    /// Current download speed reported by the installer, in bytes per second.
    pub bytes_per_second: Option<u64>,
    /// Download percentage, from 0 to 100; not overall installation progress.
    pub percent: Option<u8>,
}

/// A service an update did not restart.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Skipped {
    /// Its instance name.
    pub name: String,
    /// `disabled` (restarting is off), `adopted` (its app-server was not
    /// started by this app), `shared_server` (it follows OpenCode's own
    /// background server), `other_install` (it runs another installation
    /// of the harness), `changed` (it was restarted or replaced meanwhile),
    /// `busy` (another operation held it) or `failed` (its restart failed;
    /// it may be stopped).
    pub reason: String,
}

/// A change to this device's update settings; absent fields stay.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SettingsChange {
    /// The harness whose automatic update [`Self::auto_update`] sets.
    pub kind: Option<Kind>,
    /// Update [`Self::kind`] by itself once a newer version appears.
    pub auto_update: Option<bool>,
    /// Restart services that use an updated harness.
    pub restart_services: Option<bool>,
}
