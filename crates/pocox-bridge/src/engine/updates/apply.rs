//! Putting a verified release file in place, as each platform allows.
//!
//! Where the app can replace itself (a macOS bundle, a Windows install, an
//! AppImage) a small helper waits for the app to quit through its normal
//! path, swaps the new version in and reopens it. A Linux package goes to
//! the desktop's package installer, an Android package to the system
//! installer (from Dart), and a portable archive to Downloads.
use std::path::{Path, PathBuf};

use super::{
    macos,
    manifest::{Host, Install, Method},
    Failure, Kind,
};

/// This installation, as far as choosing an update goes.
pub fn host() -> Host {
    let install = if cfg!(target_os = "macos") {
        Install::MacBundle
    } else if cfg!(target_os = "ios") {
        Install::Ios
    } else if cfg!(target_os = "android") {
        Install::Android
    } else if cfg!(windows) {
        let installed = exe_dir().is_some_and(|dir| dir.join("unins000.exe").is_file());
        if installed {
            Install::WindowsInstalled
        } else {
            Install::Portable
        }
    } else if app_image().is_some() {
        Install::AppImage
    } else if std::env::current_exe().is_ok_and(|exe| exe.starts_with("/usr/lib/pocox")) {
        Install::Deb
    } else {
        Install::Portable
    };
    Host {
        install,
        arch: std::env::consts::ARCH,
    }
}

fn exe_dir() -> Option<PathBuf> {
    std::env::current_exe()
        .ok()?
        .parent()
        .map(Path::to_path_buf)
}

/// The AppImage this process runs from (its runtime names it in
/// `APPIMAGE`).
fn app_image() -> Option<PathBuf> {
    let path = PathBuf::from(std::env::var_os("APPIMAGE")?);
    path.is_file().then_some(path)
}

/// Readies `file` (already checked against the manifest) for
/// [`hand_off`]: on macOS the verified bundle out of the disk image,
/// elsewhere the file itself.
pub fn stage(
    method: Method,
    file: &Path,
    work: &Path,
    version: &semver::Version,
) -> Result<PathBuf, Failure> {
    match method {
        Method::ReplaceBundle => macos::stage(file, work, version),
        _ => Ok(file.to_path_buf()),
    }
}

/// What applying a staged update did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Handoff {
    /// The helper waits: the app must now quit through its normal path.
    Quit,
    /// Handed to the desktop's installer (or the disk image opened for an
    /// administrator to drag in).
    Opened(PathBuf),
    /// Saved here for the user to unpack.
    Saved(PathBuf),
    /// Android: the app hands this package to the system installer.
    System(PathBuf),
}

/// Applies the update staged at `staged` (within `work`).
pub fn hand_off(method: Method, staged: &Path, work: &Path) -> Result<Handoff, Failure> {
    match method {
        Method::ReplaceBundle => {
            let bundle = macos::current_bundle().filter(|bundle| macos::can_replace(bundle));
            let Some(bundle) = bundle else {
                // Not ours to replace: open the image for an administrator to
                // drag the new version in.
                let image = dmg_in(work).ok_or_else(|| install("the disk image is gone"))?;
                open(&image)?;
                return Ok(Handoff::Opened(image));
            };
            helper(
                "install-update.sh",
                macos::SCRIPT,
                "/bin/bash",
                &[&bundle, staged, work],
                work,
            )?;
            Ok(Handoff::Quit)
        },
        Method::Installer => {
            let app = std::env::current_exe().map_err(install)?;
            helper(
                "install-update.ps1",
                WINDOWS_SCRIPT,
                "powershell.exe",
                &[staged, &app, work],
                work,
            )?;
            Ok(Handoff::Quit)
        },
        Method::ReplaceAppImage => {
            let target = app_image().ok_or_else(|| install("not running from an AppImage"))?;
            helper(
                "install-update.sh",
                APPIMAGE_SCRIPT,
                "/bin/sh",
                &[&target, staged, work],
                work,
            )?;
            Ok(Handoff::Quit)
        },
        Method::OpenPackage => {
            open(staged)?;
            Ok(Handoff::Opened(staged.to_path_buf()))
        },
        Method::SaveDownload => save_to_downloads(staged).map(Handoff::Saved),
        Method::SystemInstaller => Ok(Handoff::System(staged.to_path_buf())),
        Method::ReleasePage => Err(install("nothing to install on this device")),
    }
}

fn install(detail: impl std::fmt::Display) -> Failure {
    Failure::new(Kind::Install, detail)
}

fn dmg_in(work: &Path) -> Option<PathBuf> {
    std::fs::read_dir(work)
        .ok()?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .find(|path| path.extension().is_some_and(|ext| ext == "dmg"))
}

/// Writes `script` into `work` and starts it, detached, with this process's
/// id followed by `args`. It outlives the app, in a process group of its own
/// so the app's quit (which stops its own children) leaves it running.
fn helper(
    name: &str,
    script: &str,
    interpreter: &str,
    args: &[&Path],
    work: &Path,
) -> Result<(), Failure> {
    let path = work.join(name);
    std::fs::write(&path, script).map_err(install)?;
    let mut command = std::process::Command::new(interpreter);
    if cfg!(windows) {
        command.args([
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-WindowStyle",
            "Hidden",
            "-File",
        ]);
    }
    command
        .arg(&path)
        .arg(std::process::id().to_string())
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    detach(&mut command);
    command.spawn().map_err(install)?;
    Ok(())
}

#[cfg(unix)]
fn detach(command: &mut std::process::Command) {
    use std::os::unix::process::CommandExt;
    command.process_group(0);
}

#[cfg(windows)]
fn detach(command: &mut std::process::Command) {
    use std::os::windows::process::CommandExt;
    const DETACHED_PROCESS: u32 = 0x0000_0008;
    const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    command.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW);
}

#[cfg(not(any(unix, windows)))]
fn detach(_: &mut std::process::Command) {}

/// Opens `path` with the desktop's handler for it.
fn open(path: &Path) -> Result<(), Failure> {
    let opener = if cfg!(target_os = "macos") {
        "/usr/bin/open"
    } else if cfg!(windows) {
        "explorer.exe"
    } else {
        "xdg-open"
    };
    std::process::Command::new(opener)
        .arg(path)
        .spawn()
        .map(drop)
        .map_err(install)
}

/// Copies `file` into the user's Downloads folder and shows it there.
fn save_to_downloads(file: &Path) -> Result<PathBuf, Failure> {
    let downloads = directories::UserDirs::new()
        .and_then(|dirs| dirs.download_dir().map(Path::to_path_buf))
        .or_else(|| directories::UserDirs::new().map(|dirs| dirs.home_dir().join("Downloads")))
        .ok_or_else(|| install("no Downloads folder"))?;
    std::fs::create_dir_all(&downloads).map_err(install)?;
    let name = file
        .file_name()
        .ok_or_else(|| install("the file has no name"))?;
    let target = downloads.join(name);
    std::fs::copy(file, &target).map_err(install)?;
    let _ = std::fs::remove_file(file);
    let reveal = if cfg!(target_os = "macos") {
        std::process::Command::new("/usr/bin/open")
            .arg("-R")
            .arg(&target)
            .spawn()
    } else if cfg!(windows) {
        std::process::Command::new("explorer.exe")
            .arg(format!("/select,{}", target.display()))
            .spawn()
    } else {
        std::process::Command::new("xdg-open")
            .arg(&downloads)
            .spawn()
    };
    // Showing the folder is a courtesy; the file is saved either way.
    if let Err(error) = reveal {
        tracing::debug!(%error, "could not show the saved update");
    }
    Ok(target)
}

/// Windows: waits for the app (`ProcessId`) to exit, runs the installer
/// quietly (elevated: it installs under Program Files), then reopens the app
/// whether or not it updated.
const WINDOWS_SCRIPT: &str = r#"param([int]$ProcessId, [string]$Installer, [string]$App, [string]$Work)
try { Wait-Process -Id $ProcessId -Timeout 120 -ErrorAction Stop } catch { }
if (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) { exit 1 }
try {
  Start-Process -FilePath $Installer -Verb RunAs -Wait `
    -ArgumentList '/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
} catch { }
Start-Process -FilePath $App
Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
"#;

/// Linux AppImage: waits for the app (`$1`) to exit, moves the new image
/// (`$3`) over the running one (`$2`) and reopens it.
const APPIMAGE_SCRIPT: &str = r#"#!/bin/sh
pid="$1"; target="$2"; staged="$3"; work="$4"
i=0
while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 600 ]; do
  sleep 0.2; i=$((i + 1))
done
kill -0 "$pid" 2>/dev/null && exit 1
if [ -f "$staged" ]; then
  chmod +x "$staged" && mv -f "$staged" "$target"
fi
nohup "$target" >/dev/null 2>&1 &
rm -rf "$work"
"#;
