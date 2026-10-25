//! Windows: the update goes through `pocox-updater.exe`, shipped beside the
//! app (the `pocox-updater` crate). Its `--prepare` mode runs to the end
//! before the app is asked to quit. It checks the download again and
//! readies the update: it unpacks and checks a portable release, or takes
//! the administrator prompt for the installer. Then it leaves a worker
//! waiting for the app to exit. Any failure up to there keeps the app
//! running and is shown in it.

use std::path::Path;
use std::process::{Command, Stdio};

use super::apply::{exe_dir, install};
use super::{Failure, Staged};

/// The update helper's file name, beside `pocox.exe`.
pub const HELPER: &str = "pocox-updater.exe";

/// Hands `update` to the helper, which then waits for the app to quit.
pub fn hand_off(update: &Staged) -> Result<(), Failure> {
    let helper = exe_dir()
        .map(|dir| dir.join(HELPER))
        .filter(|path| path.is_file())
        .ok_or_else(|| install(format!("{HELPER} is missing beside the app")))?;
    let app = std::env::current_exe().map_err(install)?;
    call_off_earlier(&update.work);
    let attempt = update
        .work
        .join(format!("handoff-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&attempt).map_err(install)?;
    let request = attempt.join("request.json");
    let body = serde_json::json!({
        "processId": std::process::id(),
        "app": app,
        "package": update.path,
        "size": update.asset.size,
        "sha256": update.asset.sha256,
        "version": update.version.to_string(),
        "method": update.method.name(),
    });
    std::fs::write(&request, body.to_string()).map_err(install)?;
    let output = Command::new(&helper)
        .arg("--prepare")
        .arg(&request)
        .stdin(Stdio::null())
        .output()
        .map_err(install)?;
    if output.status.success() {
        return Ok(());
    }
    let reason = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let reason = if reason.is_empty() {
        format!("the update helper exited with {}", output.status)
    } else {
        reason
    };
    Err(install(format!("{reason} (details in {})", attempt.display())))
}

/// Calls off the handoffs an earlier try left waiting (the app did not quit
/// then), so their workers let go of this copy before the next one starts.
fn call_off_earlier(work: &Path) {
    let Some(downloads) = work.parent().and_then(|root| std::fs::read_dir(root).ok()) else {
        return;
    };
    for download in downloads.flatten() {
        let Ok(attempts) = std::fs::read_dir(download.path()) else { continue };
        for attempt in attempts.flatten() {
            if attempt
                .file_name()
                .to_string_lossy()
                .starts_with("handoff-")
            {
                let _ = std::fs::write(attempt.path().join("cancel"), "cancelled");
            }
        }
    }
}
