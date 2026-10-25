//! What the app asks of the helper: `request.json`, alone in a handoff
//! directory of its own that also receives the helper's status and logs.

use std::path::{Path, PathBuf};

use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};

/// How the release is put in place.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Method {
    /// Run the release's installer quietly over the installed copy.
    Installer,
    /// Swap the release archive's files into the portable copy's folder.
    ReplaceFolder,
}

/// One update handoff.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    /// The running app's process. Nothing changes until it has exited.
    pub process_id: u32,
    /// The running app's executable, reopened afterwards.
    pub app: PathBuf,
    /// The downloaded release file: the installer or the archive.
    pub package: PathBuf,
    /// Its exact size, from the signed manifest.
    pub size: u64,
    /// Its SHA-256 (lower-case hex), from the signed manifest.
    pub sha256: String,
    /// The release's version (`0.7.7`), which the app must report after
    /// the update.
    pub version: String,
    /// How it is put in place.
    pub method: Method,
    /// Whether the installer runs as administrator (it installs under
    /// Program Files). Tests turn this off.
    #[serde(default = "yes")]
    pub elevate: bool,
    /// Whether the app is reopened afterwards.
    #[serde(default = "yes")]
    pub reopen: bool,
    /// Whether a failure after the app quit is shown in a message box.
    #[serde(default = "yes")]
    pub show_errors: bool,
    /// How long the app has to quit before the update is called off.
    #[serde(default = "exit_timeout")]
    pub exit_timeout_seconds: u64,
}

fn yes() -> bool {
    true
}

fn exit_timeout() -> u64 {
    120
}

impl Request {
    /// The request at `path`, if it is complete and consistent.
    pub fn read(path: &Path) -> Result<Self> {
        ensure!(path.is_absolute(), "the update request must be an absolute path");
        let bytes = std::fs::read(path)
            .with_context(|| format!("reading the update request {}", path.display()))?;
        ensure!(bytes.len() <= 16 * 1024, "the update request is too large");
        let request: Self = serde_json::from_slice(&bytes).context("malformed update request")?;
        ensure!(request.process_id != 0, "the update request names no app process");
        ensure!(
            request.app.is_absolute() && request.package.is_absolute(),
            "update paths must be absolute"
        );
        ensure!(request.app.is_file(), "the app is missing: {}", request.app.display());
        ensure!(
            request.package.is_file(),
            "the downloaded update is missing: {}",
            request.package.display()
        );
        ensure!(
            request.size > 0
                && request.sha256.len() == 64
                && request
                    .sha256
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            "the update request has no valid size and SHA-256"
        );
        ensure!(
            !request.version.is_empty()
                && request.version.len() <= 64
                && request
                    .version
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b".+-".contains(&b)),
            "the update request has no valid version"
        );
        ensure!(
            (1..=600).contains(&request.exit_timeout_seconds),
            "the update request has no valid exit timeout"
        );
        Ok(request)
    }

    /// The folder the app runs from.
    pub fn app_dir(&self) -> Result<&Path> {
        self.app.parent().context("the app has no folder")
    }
}

/// The handoff directory a request file sits in.
pub fn handoff_dir(request: &Path) -> Result<&Path> {
    request.parent().context("the update request has no folder")
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, reason = "test failures should fail at the observed boundary")]

    use super::*;

    #[test]
    fn requests_must_name_real_files_and_the_signed_identity() {
        let dir = tempfile::tempdir().unwrap();
        let (app, package) = (dir.path().join("pocox.exe"), dir.path().join("update.zip"));
        std::fs::write(&app, "app").unwrap();
        std::fs::write(&package, "zip").unwrap();
        let path = dir.path().join("request.json");
        let write = |value: serde_json::Value| std::fs::write(&path, value.to_string()).unwrap();
        let mut request = serde_json::json!({
            "processId": 7, "app": app, "package": package, "size": 3,
            "sha256": "a".repeat(64), "version": "0.7.7", "method": "replace_folder",
        });
        write(request.clone());
        let read = Request::read(&path).unwrap();
        assert_eq!(read.method, Method::ReplaceFolder);
        assert!(read.elevate && read.reopen && read.show_errors);

        request["sha256"] = "A".repeat(64).into();
        write(request.clone());
        assert!(Request::read(&path).is_err(), "hashes are lower-case hex");
        request["sha256"] = "a".repeat(64).into();
        request["package"] = dir.path().join("gone.zip").to_string_lossy().into();
        write(request);
        assert!(Request::read(&path).is_err(), "the package must exist");
    }
}
