//! The helper's three modes, one per process of a handoff:
//!
//! - `--prepare <request>` runs while the app waits for it. It copies this
//!   executable into the handoff directory, so the release can replace the
//!   shipped one. For an installer it starts the administrator half from that
//!   copy. Then it starts the worker and returns once the worker is ready. The
//!   app quits only if it succeeds.
//! - `--worker <request> [<half>]` outlives the app. It pins the app's process,
//!   checks the download and readies the update: it unpacks and checks a
//!   portable release, or pins the administrator half (process id `<half>`) for
//!   an installer. Then it reports ready and waits for the app to exit. It puts
//!   the update in place, reopens the app, and shows anything that went wrong.
//! - `--elevated <request>` is the installer's administrator half. It starts
//!   before the app quits, so the administrator prompt comes while the app
//!   still runs and declining it leaves the app running. It waits for the app
//!   to exit, then runs the installer from the file it checked and still holds.

use std::ffi::{OsStr, OsString};
use std::fs::File;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{bail, ensure, Context, Result};
use ring::digest;

use super::process::{self, Process};
use super::version;
use crate::request::{self, Method, Request};
use crate::status::{self, Stage, Status};
use crate::{package, portable};

/// The worker's copy of this executable in the handoff directory.
const WORKER_EXE: &str = "pocox-update-worker.exe";
/// How long `--prepare` waits for the worker: long enough to unpack a
/// release and for the user to answer the administrator prompt.
const READY_WITHIN: Duration = Duration::from_secs(10 * 60);
/// How long the administrator half has to get ready once started.
const ELEVATED_READY_WITHIN: Duration = Duration::from_secs(60);
/// How long the installer may run.
const INSTALL_WITHIN: Duration = Duration::from_secs(15 * 60);
/// How long a move of the app's files is retried (a virus scan may still
/// hold a fresh file).
const PATIENCE: Duration = Duration::from_secs(10);
/// How long an update waits for an earlier, called-off one of the same copy
/// to let go.
const LOCK_PATIENCE: Duration = Duration::from_secs(15);

/// Runs the mode the arguments name: `--prepare`, `--worker` or `--elevated`,
/// each followed by the absolute path of the request.
pub fn run(mut arguments: impl Iterator<Item = OsString>) -> Result<()> {
    let mode = arguments.next().context("missing the updater mode")?;
    let path = PathBuf::from(arguments.next().context("missing the update request")?);
    // `--worker` also takes the administrator half's process id.
    let half = arguments
        .next()
        .map(|id| {
            id.to_str()
                .and_then(|id| id.parse::<u32>().ok())
                .context("malformed process id")
        })
        .transpose()?;
    ensure!(arguments.next().is_none(), "unexpected updater argument");
    let dir = request::handoff_dir(&path)?.to_path_buf();
    let (result, name) = match mode.to_str() {
        // Its error goes to the app through standard error.
        Some("--prepare") if half.is_none() => return prepare(&path, &dir),
        Some("--worker") => (worker(&path, &dir, half), status::WORKER),
        Some("--elevated") if half.is_none() => (elevated(&path, &dir), status::ELEVATED),
        _ => bail!("unknown updater mode or argument"),
    };
    if let Err(error) = &result {
        let reported = status::read(&dir, name).is_some_and(|found| found.stage == Stage::Failed);
        if !reported {
            let _ = status::write(&dir, name, Stage::Failed, &format!("{error:#}"));
        }
    }
    result
}

fn prepare(path: &Path, dir: &Path) -> Result<()> {
    let request = Request::read(path)?;
    let worker = dir.join(WORKER_EXE);
    ensure!(
        status::read(dir, status::WORKER).is_none() && !status::cancelled(dir) && !worker.exists(),
        "this update handoff was already used"
    );
    std::fs::copy(std::env::current_exe()?, &worker).context("copying the update helper")?;
    // The administrator prompt comes from here: the app in the foreground
    // started this process, so Windows shows the prompt in front of it rather
    // than as a flashing taskbar button.
    let half = match request.method {
        Method::Installer => Some(start_elevated(&worker, path, dir, &request)?),
        Method::ReplaceFolder => None,
    };
    let half_id = half.as_ref().map(|half| half.id().to_string());
    let mut arguments = vec![OsStr::new("--worker"), path.as_os_str()];
    arguments.extend(half_id.as_deref().map(OsStr::new));
    let child = process::spawn(&worker, &arguments, dir).inspect_err(|_| status::cancel(dir))?;
    let deadline = Instant::now() + READY_WITHIN;
    loop {
        match status::read(dir, status::WORKER) {
            Some(Status {
                stage: Stage::Ready, ..
            }) => return Ok(()),
            Some(Status {
                stage: Stage::Failed | Stage::Cancelled,
                message,
            }) => bail!("{message}"),
            _ => {},
        }
        if child.wait(Duration::from_millis(50))? || Instant::now() >= deadline {
            status::cancel(dir);
            // The worker may have reported between the read and its exit.
            if let Some(failed) = failure(dir, status::WORKER) {
                bail!("{failed}");
            }
            bail!("the update helper stopped before it was ready");
        }
    }
}

fn failure(dir: &Path, name: &str) -> Option<String> {
    status::read(dir, name)
        .filter(|found| found.stage == Stage::Failed)
        .map(|found| found.message)
}

/// What the worker readied before the app quit.
enum Readied {
    /// The unpacked release, in this staging folder.
    Folder(PathBuf),
    /// The administrator half, waiting to run the installer.
    Installer(Process),
}

fn worker(path: &Path, dir: &Path, half: Option<u32>) -> Result<()> {
    let request = Request::read(path)?;
    let app_dir = request.app_dir()?.to_path_buf();
    let app = Process::pin(request.process_id)?;
    let _owner = process::exclusive(&lock_name(&app_dir), LOCK_PATIENCE)?;
    let package = package::open_verified(&request.package, request.size, &request.sha256)?;
    let readied = match request.method {
        Method::ReplaceFolder => Readied::Folder(unpack(&request, &package, &app_dir)?),
        Method::Installer => {
            let half = half.context("the installer's administrator half is missing")?;
            Readied::Installer(Process::pin(half)?)
        },
    };
    drop(package);
    status::write(dir, status::WORKER, Stage::Ready, "waiting for POCOX to quit")?;
    if !quit(&app, &request, dir)? {
        if let Readied::Folder(staging) = &readied {
            portable::clear(staging);
        }
        // The administrator half sees this too and installs nothing.
        status::cancel(dir);
        return status::write(
            dir,
            status::WORKER,
            Stage::Cancelled,
            "POCOX did not quit, so nothing was changed",
        );
    }
    status::write(dir, status::WORKER, Stage::Installing, "")?;
    let outcome = match &readied {
        Readied::Folder(staging) => {
            portable::swap(&app_dir, &staging.join("new"), &staging.join("old"), PATIENCE)
        },
        Readied::Installer(half) => finish_install(half, dir, &request),
    };
    // Reopened either way: the new version, or the old one put back.
    let reopened = if request.reopen { reopen(&request) } else { Ok(()) };
    match outcome.and(reopened) {
        Ok(()) => {
            status::write(dir, status::WORKER, Stage::Complete, &request.version)?;
            if let Readied::Folder(staging) = &readied {
                portable::clear(staging);
            }
            let _ = std::fs::remove_file(&request.package);
            Ok(())
        },
        Err(error) => {
            status::write(dir, status::WORKER, Stage::Failed, &format!("{error:#}"))?;
            if request.show_errors {
                process::alert(&format!(
                    "POCOX could not update to {}.\n\n{error:#}\n\nThe update's logs are in:\n{}",
                    request.version,
                    dir.display()
                ));
            }
            Err(error)
        },
    }
}

/// The name of the lock one update of the copy in `app_dir` holds.
fn lock_name(app_dir: &Path) -> String {
    let folder = app_dir.to_string_lossy().to_lowercase();
    let hash = digest::digest(&digest::SHA256, folder.as_bytes());
    let short: String = hash.as_ref()[..8]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    format!("Local\\pocox-update-{short}")
}

/// Unpacks the checked archive into the app's staging folder and checks the
/// version it holds; returns the staging folder.
fn unpack(request: &Request, archive: &File, app_dir: &Path) -> Result<PathBuf> {
    let staging = app_dir.join(portable::STAGING);
    // An earlier update's leftovers; this update owns the copy now.
    portable::clear(&staging);
    ensure!(
        !staging.exists(),
        "an earlier update's files in {} are still in use",
        staging.display()
    );
    let new = staging.join("new");
    let checked = (|| {
        portable::unpack(archive, &new)?;
        let exe = request
            .app
            .file_name()
            .context("the app has no file name")?;
        let unpacked = new.join(exe);
        ensure!(unpacked.is_file(), "the update archive has no {}", exe.to_string_lossy());
        version::expect(&unpacked, &request.version)
    })();
    if let Err(error) = checked {
        portable::clear(&staging);
        return Err(error);
    }
    Ok(staging)
}

/// Starts the administrator half from `helper` and waits until it holds the
/// installer.
fn start_elevated(helper: &Path, path: &Path, dir: &Path, request: &Request) -> Result<Process> {
    let mut parameters = OsString::from("--elevated \"");
    // Windows paths cannot contain quotes.
    parameters.push(path);
    parameters.push("\"");
    let half = process::launch(helper, &parameters, request.elevate)?;
    let deadline = Instant::now() + ELEVATED_READY_WITHIN;
    loop {
        match status::read(dir, status::ELEVATED) {
            Some(Status {
                stage: Stage::Ready, ..
            }) => return Ok(half),
            Some(Status {
                stage: Stage::Failed,
                message,
            }) => bail!("{message}"),
            _ => {},
        }
        if half.wait(Duration::from_millis(50))? || Instant::now() >= deadline {
            status::cancel(dir);
            if let Some(failed) = failure(dir, status::ELEVATED) {
                bail!("{failed}");
            }
            bail!("the installer helper stopped before it was ready");
        }
    }
}

/// Waits for the administrator half to run the installer, then checks the
/// version the app reports.
fn finish_install(half: &Process, dir: &Path, request: &Request) -> Result<()> {
    ensure!(half.wait(INSTALL_WITHIN)?, "the installer did not finish within 15 minutes");
    match status::read(dir, status::ELEVATED) {
        Some(Status {
            stage: Stage::Complete, ..
        }) => version::expect(&request.app, &request.version),
        Some(Status {
            stage: Stage::Failed | Stage::Cancelled,
            message,
        }) => bail!("{message}"),
        _ => {
            bail!("the installer helper stopped without a result (exit code {})", half.exit_code()?)
        },
    }
}

fn elevated(path: &Path, dir: &Path) -> Result<()> {
    let request = Request::read(path)?;
    let app = Process::pin(request.process_id)?;
    let installer = package::open_verified(&request.package, request.size, &request.sha256)?;
    status::write(dir, status::ELEVATED, Stage::Ready, "")?;
    if !quit(&app, &request, dir)? {
        return status::write(
            dir,
            status::ELEVATED,
            Stage::Cancelled,
            "POCOX did not quit, so nothing was installed",
        );
    }
    status::write(dir, status::ELEVATED, Stage::Installing, "")?;
    let exit = Command::new(&request.package)
        .args(["/SILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/NORESTARTAPPLICATIONS", "/SP-"])
        .arg(format!("/LOG={}", dir.join("installer.log").display()))
        .arg(format!("/DIR={}", request.app_dir()?.display()))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("running the installer")?;
    drop(installer);
    ensure!(
        exit.success(),
        "the installer exited with code {}",
        exit.code()
            .map_or_else(|| "none".into(), |code| code.to_string())
    );
    status::write(dir, status::ELEVATED, Stage::Complete, "")
}

/// Waits for the app to exit. False when the update was called off or the
/// app did not exit in time: nothing may change then.
fn quit(app: &Process, request: &Request, dir: &Path) -> Result<bool> {
    let deadline = Instant::now() + Duration::from_secs(request.exit_timeout_seconds);
    loop {
        if status::cancelled(dir) || Instant::now() >= deadline {
            return Ok(false);
        }
        if app.wait(Duration::from_millis(100))? {
            return Ok(!status::cancelled(dir));
        }
    }
}

fn reopen(request: &Request) -> Result<()> {
    process::spawn(&request.app, &[], request.app_dir()?)
        .map(drop)
        .context("reopening POCOX")
}
