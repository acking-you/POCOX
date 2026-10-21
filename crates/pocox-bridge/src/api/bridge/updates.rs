//! App updates from GitHub Releases: a quiet background check, and on the
//! user's word a verified download that installs as the platform allows.
//! See `engine::updates`; every change reaches the UI through
//! [`update_watch`].
use anyhow::Result;
use flutter_rust_bridge::frb;

use crate::{
    engine::{
        runtime,
        updates::{self, Kind, Snapshot},
    },
    frb_generated::StreamSink,
};

/// Everything the UI shows about updates.
pub struct UpdateStateDto {
    /// The running version.
    pub current: String,
    /// `idle`, `checking`, `up_to_date`, `available`, `downloading`,
    /// `verifying`, `ready`, `verified_only`, `installing`, `opened`,
    /// `saved` or `failed`.
    pub phase: String,
    /// The newest release, once a check found one.
    pub latest: Option<String>,
    /// Whether it is newer than the running version.
    pub newer: bool,
    /// How it applies here: `replace_bundle`, `installer`,
    /// `replace_app_image` (each ends with the app quitting),
    /// `open_package`, `save_download`, `system_installer` or
    /// `release_page`.
    pub method: String,
    /// The size of its file for this installation, in bytes.
    pub size: Option<i64>,
    /// Bytes downloaded so far.
    pub received: i64,
    /// The newest release's page (every release before a check).
    pub page: String,
    /// When GitHub last answered a check (Unix milliseconds).
    pub checked_at_ms: Option<i64>,
    /// Why the last action or background check failed: `network`,
    /// `signature`, `checksum`, `verification`, `install`, `permission` or
    /// `quit`.
    pub failure: Option<String>,
    /// The underlying error of [`Self::failure`].
    pub failure_detail: Option<String>,
    /// The saved or opened file; on Android the package to install.
    pub path: Option<String>,
    /// The newest version the user has been told about.
    pub announced: Option<String>,
}

impl From<Snapshot> for UpdateStateDto {
    fn from(snapshot: Snapshot) -> Self {
        Self {
            current: snapshot.current,
            phase: snapshot.phase.name().into(),
            latest: snapshot.latest,
            newer: snapshot.newer,
            method: snapshot.method.name().into(),
            size: snapshot.size.map(|size| size as i64),
            received: snapshot.received as i64,
            page: snapshot.page,
            checked_at_ms: snapshot.checked_at,
            failure: snapshot.failure.as_ref().map(|f| f.kind.name().into()),
            failure_detail: snapshot.failure.map(|f| f.detail),
            path: snapshot.path,
            announced: snapshot.announced,
        }
    }
}

/// The update state now.
#[frb(sync)]
pub fn update_state() -> UpdateStateDto {
    updates::updater().snapshot().into()
}

/// Follows the update state: the current one, then every change.
pub fn update_watch(sink: StreamSink<UpdateStateDto>) -> Result<()> {
    updates::updater().watch(move |snapshot| sink.add(snapshot.clone().into()).is_ok());
    Ok(())
}

/// Starts the quiet background check (once per process; later calls do
/// nothing).
#[frb(sync)]
pub fn update_start_background() {
    updates::updater().start_background();
}

/// Checks for a newer release now (`force`), or only when the last answer
/// is older than the background interval.
pub fn update_check(force: bool) -> UpdateStateDto {
    runtime::runtime()
        .block_on(updates::updater().check(force))
        .into()
}

/// Downloads and verifies the newest release's file for this installation.
pub fn update_download() -> UpdateStateDto {
    runtime::runtime()
        .block_on(updates::updater().download())
        .into()
}

/// Stops a download in progress.
#[frb(sync)]
pub fn update_cancel() {
    updates::updater().cancel();
}

/// Applies the downloaded update. When the method restarts the app, the
/// caller quits through its normal path next; on Android it hands `path` to
/// the system installer.
pub fn update_install() -> UpdateStateDto {
    updates::updater().install().into()
}

/// Reports a failure of the app's own part (`quit`, `permission`,
/// `install`).
#[frb(sync)]
pub fn update_report(kind: String, detail: String) {
    updates::updater().report(Kind::parse(&kind), detail);
}

/// Remembers that the user has been told about `version`.
#[frb(sync)]
pub fn update_announce(version: String) {
    updates::updater().announce(version);
}
