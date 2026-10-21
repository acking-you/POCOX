//! Preparing the pinned Claude ACP adapter into this app's cache.
//!
//! Runs only when the user starts the Claude preset and no adapter is found
//! (see [`super::claude`]). It runs the npm bundled with a Node.js >= 22 that
//! was already found — `node <npm-cli.js> install --prefix <stage>` of
//! exactly [`ADAPTER_PACKAGE`]@[`ADAPTER_VERSION`] with install scripts off —
//! into a fresh staging directory under `<cache>/claude-agent-acp`, with
//! npm's own cache kept there too. Nothing global, no user configuration and
//! not the user's default Node.js is touched; only the child's environment
//! names the Node.js directory.
//!
//! The result counts only after verification
//! ([`super::claude::check_installation`], which every later reuse repeats):
//! the lockfile must record the package at the pinned version and registry
//! integrity, the installed manifest must agree, and the script must exist.
//! Then a completion marker
//! is written and the staging directory is renamed into place in one step,
//! so a partial preparation is never used. When another preparation won the
//! rename, its valid result is used; an invalid directory in the way is
//! moved aside, never deleted in place.
//!
//! Cancellation is honoured before npm starts, while it runs, and before
//! verification and publication; the time limit while it runs. Both stop
//! only the npm process group this started, then remove its staging
//! directory. A cancel after publication is too late: the result is ready.
//! npm's output is discarded (it may echo registry tokens from the user's npm
//! configuration); failures are reported by kind only.

use std::{
    ffi::OsString,
    path::{Path, PathBuf},
    time::Duration,
};

use tokio::sync::watch;

#[path = "claude_download.rs"]
mod download;

use super::claude::{
    check_installation, package_root, prepared_adapter, ready_marker, version_dir, ADAPTER_PACKAGE,
    ADAPTER_VERSION, READY_MARKER,
};
use crate::process::{self, leader_exited, Spawned};

/// Longest a preparation may run.
pub const PREPARE_TIMEOUT: Duration = Duration::from_secs(15 * 60);
const EXIT_POLL: Duration = Duration::from_millis(100);
const TERM_GRACE: Duration = Duration::from_millis(300);

/// What a preparation runs with.
#[derive(Debug, Clone)]
pub struct Prepare {
    /// A Node.js >= [`super::claude::MIN_NODE_MAJOR`].
    pub node: PathBuf,
    /// npm's CLI script installed with it.
    pub npm_cli: PathBuf,
    /// This app's runtime cache (`<state>/acp-runtime`).
    pub cache: PathBuf,
    /// The child's `PATH` (the Node.js directory is put first).
    pub path: Option<OsString>,
    /// Longest it may run ([`PREPARE_TIMEOUT`] by default).
    pub timeout: Duration,
}

/// Where a preparation is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    /// npm is downloading and installing the package.
    Installing,
    /// Actual npm package response bytes and their recent transfer rate.
    Downloading {
        /// Cumulative bytes received during this preparation.
        bytes: u64,
        /// Measured bytes per second over the recent sampling window.
        bytes_per_second: u64,
        /// Whether package responses are still arriving.
        active: bool,
    },
    /// The installed files are being checked.
    Verifying,
}

/// Why a preparation failed. Messages are safe to show.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum SetupError {
    /// The user cancelled it.
    #[error("the preparation was cancelled")]
    Cancelled,
    /// It ran out of time.
    #[error("the preparation did not finish in time; check the network and try again")]
    Timeout,
    /// npm could not be started.
    #[error("npm could not be started with the Node.js that was found")]
    Start,
    /// npm failed.
    #[error(
        "npm could not install {}@{} (exit status {}); check the network or the npm registry \
         configuration and try again",
        ADAPTER_PACKAGE,
        ADAPTER_VERSION,
        .0
    )]
    Install(String),
    /// What npm installed is not the pinned package.
    #[error(
        "the installed adapter did not match the expected {} package ({})",
        ADAPTER_VERSION,
        .0
    )]
    Corrupt(&'static str),
    /// The cache could not be written.
    #[error("the app cache could not be written ({0})")]
    Io(String),
}

fn io_error(error: std::io::Error) -> SetupError {
    SetupError::Io(error.kind().to_string())
}

/// The child's `PATH`: the Node.js directory first, so npm (and anything it
/// runs) uses that Node.js.
fn child_path(node: &Path, path: Option<&OsString>) -> Option<OsString> {
    let mut dirs: Vec<PathBuf> = node.parent().map(Path::to_path_buf).into_iter().collect();
    if let Some(path) = path {
        dirs.extend(std::env::split_paths(path));
    }
    std::env::join_paths(dirs).ok()
}

fn check_cancel(cancel: &watch::Receiver<bool>) -> Result<(), SetupError> {
    if *cancel.borrow() {
        Err(SetupError::Cancelled)
    } else {
        Ok(())
    }
}

fn install_args(npm_cli: &Path, stage: &Path) -> Option<Vec<String>> {
    Some(vec![
        "--require".into(),
        stage.join("download-progress.cjs").to_str()?.to_string(),
        npm_cli.to_str()?.to_string(),
        "install".into(),
        "--prefix".into(),
        stage.to_str()?.to_string(),
        "--no-audit".into(),
        "--no-fund".into(),
        "--ignore-scripts".into(),
        "--loglevel=error".into(),
        format!("{ADAPTER_PACKAGE}@{ADAPTER_VERSION}"),
    ])
}

/// Prepare the adapter and return its script; an already completed
/// preparation is returned at once. `stage` reports progress; `cancel`
/// turning `true` stops it.
pub async fn prepare(
    job: &Prepare,
    stage: impl Fn(Stage) + Sync,
    mut cancel: watch::Receiver<bool>,
) -> Result<PathBuf, SetupError> {
    if let Some(entry) = prepared_adapter(&job.cache) {
        return Ok(entry);
    }
    // A cancel that arrived before this point starts nothing.
    check_cancel(&cancel)?;
    let root = package_root(&job.cache);
    tokio::fs::create_dir_all(&root).await.map_err(io_error)?;
    let staging = root.join(format!(".stage-{}", uuid::Uuid::new_v4().simple()));
    tokio::fs::create_dir(&staging).await.map_err(io_error)?;
    let result = async {
        tokio::fs::write(staging.join("download-progress.cjs"), download::HOOK)
            .await
            .map_err(io_error)?;
        stage(Stage::Installing);
        install(job, &staging, &root, &mut cancel, &stage).await?;
        stage(Stage::Verifying);
        check_cancel(&cancel)?;
        verify(&staging)?;
        // The last point a cancel is honoured: once in place it is done.
        check_cancel(&cancel)?;
        install_into_place(&job.cache, &staging)
    }
    .await;
    // On success the staging directory was renamed away.
    let _ = tokio::fs::remove_dir_all(&staging).await;
    result
}

async fn install(
    job: &Prepare,
    staging: &Path,
    root: &Path,
    cancel: &mut watch::Receiver<bool>,
    progress: &(impl Fn(Stage) + Sync),
) -> Result<(), SetupError> {
    let args = install_args(&job.npm_cli, staging).ok_or(SetupError::Start)?;
    let npm_cache = root.join("npm-cache");
    let env: Vec<(OsString, OsString)> = [
        ("npm_config_cache", npm_cache.into_os_string()),
        ("npm_config_update_notifier", "false".into()),
        ("npm_config_fund", "false".into()),
        ("npm_config_audit", "false".into()),
    ]
    .into_iter()
    .map(|(key, value)| (OsString::from(key), value))
    .collect();
    let path = child_path(&job.node, job.path.as_ref());
    check_cancel(cancel)?;
    let Spawned {
        process,
        stdin,
        stdout,
    } = process::spawn(&job.node, &args, path.as_ref(), &env).map_err(|_| SetupError::Start)?;
    drop(stdin);
    let (samples, latest) = watch::channel(None);
    let mut drain = tokio::spawn(download::drain(stdout, samples));
    let mut rate = download::Rate::new(tokio::time::Instant::now());
    let leader = process.id();
    let deadline = tokio::time::Instant::now() + job.timeout;
    let stopped = loop {
        if let Some(sample) = *latest.borrow() {
            let bytes_per_second = rate.sample(tokio::time::Instant::now(), sample.bytes);
            progress(Stage::Downloading {
                bytes: sample.bytes,
                bytes_per_second,
                active: sample.active > 0,
            });
        }

        if *cancel.borrow() {
            break Some(SetupError::Cancelled);
        }
        if leader.is_none_or(leader_exited) {
            break None;
        }
        tokio::select! {
            changed = cancel.changed() => {
                // A dropped sender cancels too: nobody is waiting any more.
                if changed.is_err() || *cancel.borrow() {
                    break Some(SetupError::Cancelled);
                }
            },
            () = tokio::time::sleep_until(deadline) => break Some(SetupError::Timeout),
            () = tokio::time::sleep(EXIT_POLL) => {},
        }
    };
    if let Some(error) = stopped {
        process.terminate(TERM_GRACE).await;
        drain.abort();
        let _ = drain.await;
        return Err(error);
    }
    let status = process.finish().await;
    if tokio::time::timeout(Duration::from_secs(1), &mut drain)
        .await
        .is_err()
    {
        drain.abort();
        let _ = drain.await;
    }
    if let Some(sample) = *latest.borrow() {
        progress(Stage::Downloading {
            bytes: sample.bytes,
            bytes_per_second: 0,
            active: false,
        });
    }
    match status {
        Some(status) if status.success() => Ok(()),
        Some(status) => Err(SetupError::Install(
            status
                .code()
                .map_or_else(|| "signal".to_string(), |code| code.to_string()),
        )),
        None => Err(SetupError::Install("unknown".into())),
    }
}

/// Check what npm installed in `dir` ([`check_installation`], the same check
/// a later reuse makes).
pub fn verify(dir: &Path) -> Result<(), SetupError> {
    check_installation(dir)
        .map(drop)
        .map_err(SetupError::Corrupt)
}

/// Mark `staging` complete and move it into place.
fn install_into_place(cache: &Path, staging: &Path) -> Result<PathBuf, SetupError> {
    std::fs::write(staging.join(READY_MARKER), ready_marker().to_string()).map_err(io_error)?;
    let target = version_dir(cache);
    if std::fs::rename(staging, &target).is_err() {
        if let Some(entry) = prepared_adapter(cache) {
            // Another preparation finished first.
            return Ok(entry);
        }
        if target.exists() {
            // Something incomplete is in the way: keep it aside, not deleted.
            let aside = target.with_file_name(format!(
                ".invalid-{ADAPTER_VERSION}-{}",
                uuid::Uuid::new_v4().simple()
            ));
            std::fs::rename(&target, aside).map_err(io_error)?;
        }
        std::fs::rename(staging, &target).map_err(io_error)?;
    }
    prepared_adapter(cache).ok_or(SetupError::Corrupt("after install"))
}

#[cfg(all(test, unix))]
#[path = "claude_setup_tests.rs"]
mod tests;
