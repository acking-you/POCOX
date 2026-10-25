//! The helper's progress, published in the handoff directory for the app
//! and for the helper's other halves: each half replaces its own JSON file
//! whole, so a reader never sees a partial one.

use std::path::Path;

use anyhow::Result;
use serde::{Deserialize, Serialize};

/// The worker's status, which `--prepare` and the app read.
pub const WORKER: &str = "status.json";
/// The administrator half's status (installer only), which the worker reads.
pub const ELEVATED: &str = "elevated.json";
/// Written by the app or `--prepare` to call the update off.
const CANCEL: &str = "cancel";

/// Where a half of the handoff stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Stage {
    /// Ready: the app may quit now.
    Ready,
    /// The app has quit and the update is going in.
    Installing,
    /// Done; for the worker, also reopened.
    Complete,
    /// Called off before anything changed.
    Cancelled,
    /// Failed; the message says why.
    Failed,
}

/// A status file's contents.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Status {
    /// Where it stands.
    pub stage: Stage,
    /// What happened, for the app and its logs.
    pub message: String,
}

/// Publishes `stage` as `dir/name`.
pub fn write(dir: &Path, name: &str, stage: Stage, message: &str) -> Result<()> {
    let target = dir.join(name);
    let pending = target.with_extension("tmp");
    std::fs::write(
        &pending,
        serde_json::to_vec(&Status {
            stage,
            message: message.into(),
        })?,
    )?;
    // Replaces the previous status in one step on every platform.
    std::fs::rename(&pending, &target)?;
    Ok(())
}

/// The status published as `dir/name`, if any.
pub fn read(dir: &Path, name: &str) -> Option<Status> {
    let bytes = std::fs::read(dir.join(name)).ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// Calls off the update waiting in `dir`.
pub fn cancel(dir: &Path) {
    let _ = std::fs::write(dir.join(CANCEL), "cancelled");
}

/// Whether the update waiting in `dir` was called off.
pub fn cancelled(dir: &Path) -> bool {
    dir.join(CANCEL).exists()
}
