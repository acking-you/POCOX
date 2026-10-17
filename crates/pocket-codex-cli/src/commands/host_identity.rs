//! Installation identity shared by CLI publishers and their detached workers.

use anyhow::Result;
use pocket_codex_core::{
    device::{self, HostIdentity},
    paths,
};

/// Load this installation's identity, so published metadata carries it.
fn initialize() -> Result<&'static HostIdentity> {
    device::initialize(&paths::state_dir()?.join("identity"))
}

/// The device segment to publish under: an explicit override, else this
/// installation's persisted default. With an override the identity only
/// annotates metadata, so a damaged one is reported rather than fatal.
pub(super) fn device(explicit: Option<String>) -> Result<String> {
    match explicit {
        Some(device) => {
            initialize_for_metadata();
            Ok(device)
        },
        None => Ok(initialize()?.device().to_string()),
    }
}

/// [`initialize`] for a publisher whose keys do not depend on it.
pub(super) fn initialize_for_metadata() {
    if let Err(error) = initialize() {
        tracing::warn!("host identity unavailable; metadata omits it: {error:#}");
    }
}
