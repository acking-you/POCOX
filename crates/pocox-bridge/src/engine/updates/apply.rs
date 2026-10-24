//! Putting a verified release file in place, as each platform allows.
//!
//! Where the app can replace itself (a macOS bundle, a Windows install, an
//! AppImage) a small helper waits for the app to quit through its normal
//! path, swaps the new version in and reopens it. A Linux package goes to
//! the desktop's package installer, an Android package to the system
//! installer (from Dart), and a portable archive to Downloads.
use std::path::{Path, PathBuf};

use super::manifest::{Host, Install, Method};
use super::{macos, Failure, Kind};

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
            windows_helper(staged, &app, work, std::process::id())?;
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
/// id followed by `args`. It outlives the app in a process group of its own.
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
    const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    // DETACHED_PROCESS overrides CREATE_NO_WINDOW and makes Windows PowerShell
    // exit successfully without executing -File when its input is NUL.
    command.creation_flags(CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW);
}

#[cfg(not(any(unix, windows)))]
fn detach(_: &mut std::process::Command) {}

/// A successful spawn does not mean PowerShell ran the script. Wait for its
/// acknowledgement before asking Flutter to quit; startup failures stay in-app.
fn windows_helper(
    installer: &Path,
    app: &Path,
    work: &Path,
    pid: u32,
) -> Result<std::process::Child, Failure> {
    let script = work.join("install-update.ps1");
    std::fs::write(&script, WINDOWS_SCRIPT).map_err(install)?;
    // Each attempt owns its log and acknowledgement. A retry cannot accept a
    // stale acknowledgement, and a still-waiting helper owns install.lock.
    let attempt = work.join(format!("handoff-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&attempt).map_err(install)?;
    let ready = attempt.join("ready");
    let log = attempt.join("helper.log");
    let output = std::fs::File::create(&log).map_err(install)?;
    let mut command = std::process::Command::new("powershell.exe");
    command
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-WindowStyle",
            "Hidden",
            "-File",
        ])
        .arg(&script)
        .arg(pid.to_string())
        .arg(installer)
        .arg(app)
        .arg(work)
        .arg(&ready)
        .current_dir(work)
        .stdin(std::process::Stdio::null())
        .stdout(output.try_clone().map_err(install)?)
        .stderr(output);
    detach(&mut command);
    let mut child = command.spawn().map_err(install)?;
    let result = wait_for_helper(&mut child, &ready, std::time::Duration::from_secs(15));
    if result.is_err() {
        // The app is still alive, so a failed startup cannot have installed
        // anything. Do not leave a late helper waiting to act on a future quit.
        let _ = child.kill();
        let _ = child.wait();
    }
    result.map_err(|error| install(format!("{error}; see {}", log.display())))?;
    Ok(child)
}

fn wait_for_helper(
    child: &mut std::process::Child,
    ready: &Path,
    timeout: std::time::Duration,
) -> Result<(), String> {
    let deadline = std::time::Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait().map_err(|error| error.to_string())? {
            return Err(format!("update helper exited before taking over ({status})"));
        }
        if std::fs::read(ready).is_ok_and(|contents| contents == b"ready") {
            return Ok(());
        }
        if std::time::Instant::now() >= deadline {
            return Err("update helper did not acknowledge startup".into());
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
}

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
/// quietly (elevated: it installs under Program Files), then reopens the app.
/// Keep diagnostics and, on failure or UAC cancellation, the verified package.
const WINDOWS_SCRIPT: &str = r#"param([int]$ProcessId, [string]$Installer, [string]$App, [string]$Work, [string]$Ready)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$lock = $null
$reopen = $false
$installed = $false
try {
  $lock = [IO.File]::Open((Join-Path $Work 'install.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
  $parent = [Diagnostics.Process]::GetProcessById($ProcessId)
  $null = $parent.Handle
  if (!(Test-Path -LiteralPath $Installer -PathType Leaf)) { throw 'The verified installer is missing' }
  if (!(Test-Path -LiteralPath $App -PathType Leaf)) { throw 'The installed app is missing' }
  [IO.File]::WriteAllText($Ready, 'ready')
  if (!$parent.WaitForExit(120000)) { throw 'The app did not exit within two minutes' }
  $installDir = Split-Path -LiteralPath $App
  $reopen = $true
  $installLog = Join-Path (Split-Path -LiteralPath $Ready) 'installer.log'
  $setup = Start-Process -FilePath $Installer -Verb RunAs -Wait -PassThru `
    -ArgumentList '/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NORESTARTAPPLICATIONS', '/SP-', `
      ('/LOG="' + $installLog + '"'), ('/DIR="' + $installDir + '"')
  if ($setup.ExitCode -ne 0) { throw "The installer exited with code $($setup.ExitCode)" }
  $installed = $true
} catch {
  [Console]::Error.WriteLine($_.ToString())
} finally {
  if ($reopen) {
    try { Start-Process -FilePath $App -WorkingDirectory $installDir -NoNewWindow }
    catch { [Console]::Error.WriteLine($_.ToString()); $installed = $false }
  }
  if ($lock) { $lock.Dispose() }
}
if (!$installed) { exit 1 }
# Retain both logs for diagnosis; the next download clears this work directory.
Remove-Item -LiteralPath $Installer -Force -ErrorAction SilentlyContinue
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

#[cfg(all(test, windows))]
mod tests {
    use std::fs;
    use std::process::{Child, Command, Stdio};
    use std::time::{Duration, Instant};

    use super::*;

    /// Reap subprocesses even when an assertion fails. None may reach the real
    /// installed app, elevate, or outlive its temporary test installation.
    struct Process(Child);

    impl Drop for Process {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    fn powershell() -> Command {
        let mut command = Command::new("powershell.exe");
        command
            .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        detach(&mut command);
        command
    }

    #[test]
    fn windows_helper_acknowledges_startup_and_rejects_concurrent_install() {
        let dir = tempfile::tempdir().unwrap();
        let installer = dir.path().join("installer.exe");
        fs::write(&installer, "not executed while this process is alive").unwrap();
        let app = std::env::current_exe().unwrap();
        let mut helper =
            Process(windows_helper(&installer, &app, dir.path(), std::process::id()).unwrap());
        assert!(helper.0.try_wait().unwrap().is_none(), "helper must be waiting for us");
        let error = windows_helper(&installer, &app, dir.path(), std::process::id())
            .expect_err("a second helper must not take over the same update");
        assert_eq!(error.kind, Kind::Install);
        assert!(installer.exists(), "a failed handoff must retain the verified package");
    }

    #[test]
    fn windows_helper_does_not_handoff_missing_installer() {
        let dir = tempfile::tempdir().unwrap();
        let app = std::env::current_exe().unwrap();
        let error =
            windows_helper(&dir.path().join("missing.exe"), &app, dir.path(), std::process::id())
                .expect_err("preflight failure must keep the app running");
        assert_eq!(error.kind, Kind::Install);
        let logs: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .map(|entry| entry.unwrap().path().join("helper.log"))
            .filter(|path| path.is_file())
            .collect();
        assert_eq!(logs.len(), 1);
        assert!(!fs::read(&logs[0]).unwrap().is_empty(), "startup error must be recorded");
    }

    #[test]
    fn successful_process_exit_without_acknowledgement_is_a_failure() {
        let dir = tempfile::tempdir().unwrap();
        let mut helper = Process(powershell().args(["-Command", "exit 0"]).spawn().unwrap());
        assert!(wait_for_helper(&mut helper.0, &dir.path().join("ready"), Duration::from_secs(10))
            .is_err());
        assert!(helper.0.wait().unwrap().success(), "exit code alone is insufficient");
    }

    #[test]
    fn unresponsive_helper_does_not_authorize_quit() {
        let dir = tempfile::tempdir().unwrap();
        let mut helper = Process(
            powershell()
                .args(["-Command", "Start-Sleep 60"])
                .spawn()
                .unwrap(),
        );
        assert!(wait_for_helper(
            &mut helper.0,
            &dir.path().join("ready"),
            Duration::from_millis(50)
        )
        .is_err());
        assert!(
            helper.0.try_wait().unwrap().is_none(),
            "a running process is not an acknowledgement"
        );
    }

    #[test]
    fn windows_script_waits_installs_and_reopens() {
        run_installer(0);
    }

    #[test]
    fn windows_script_retains_failed_installer_and_reopens_old_app() {
        run_installer(7);
    }

    fn run_installer(exit_code: i32) {
        let dir = tempfile::tempdir().unwrap();
        let work = dir.path().join("更新 work & packages");
        let install_dir = dir.path().join("installed app");
        fs::create_dir(&work).unwrap();
        fs::create_dir(&install_dir).unwrap();
        let installer = work.join("setup.cmd");
        fs::write(
            &installer,
            format!("@echo off\r\n>\"%~dp0installed\" echo done\r\nexit /b {exit_code}\r\n"),
        )
        .unwrap();
        let app = install_dir.join("app.cmd");
        fs::write(
            &app,
            "@echo off\r\npowershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \
             \"%~dp0app.ps1\"\r\n",
        )
        .unwrap();
        fs::write(
            install_dir.join("app.ps1"),
            r#"$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AppConsole {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
}
'@
if ([AppConsole]::GetConsoleWindow() -ne [IntPtr]::Zero) { exit 9 }
# The reopened child must outlive its helper and start in the install directory.
Start-Sleep -Milliseconds 1000
[IO.File]::WriteAllText((Join-Path (Get-Location) 'reopened'), 'done')
"#,
        )
        .unwrap();
        let ready = work.join("ready");
        let script = work.join("test-update.ps1");
        let (params, body) = WINDOWS_SCRIPT.split_once('\n').unwrap();
        // Only the interactive UAC boundary is replaced. The shipped script
        // still waits on a real process and runs real installer/app subprocesses.
        let elevation = r#"
function Start-Process {
  param($FilePath, $Verb, [switch]$Wait, [switch]$PassThru, $ArgumentList,
        $WorkingDirectory, [switch]$NoNewWindow)
  $options = @{ FilePath = $FilePath; Wait = $Wait; PassThru = $PassThru }
  if ($Verb -eq 'RunAs' -or $NoNewWindow) { $options.NoNewWindow = $true }
  if ($WorkingDirectory) { $options.WorkingDirectory = $WorkingDirectory }
  if ($ArgumentList) { $options.ArgumentList = $ArgumentList }
  Microsoft.PowerShell.Management\Start-Process @options
}
"#;
        fs::write(&script, format!("{params}\n{elevation}\n{body}")).unwrap();
        let mut parent = Process(
            powershell()
                .args(["-Command", "Start-Sleep 60"])
                .spawn()
                .unwrap(),
        );
        let log = work.join("helper.log");
        let output = fs::File::create(&log).unwrap();
        let mut helper = Process(
            powershell()
                .arg("-File")
                .arg(&script)
                .arg(parent.0.id().to_string())
                .args([&installer, &app, &work, &ready])
                .stdout(output.try_clone().unwrap())
                .stderr(output)
                .spawn()
                .unwrap(),
        );
        wait_for_helper(&mut helper.0, &ready, Duration::from_secs(10)).unwrap();
        assert!(!work.join("installed").exists(), "installer must wait for the app to exit");
        parent.0.kill().unwrap();
        parent.0.wait().unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        let status = loop {
            if let Some(status) = helper.0.try_wait().unwrap() {
                break status;
            }
            assert!(Instant::now() < deadline, "helper did not finish after parent exit");
            std::thread::sleep(Duration::from_millis(50));
        };
        let logs = fs::read_to_string(&log).unwrap();
        assert_eq!(status.success(), exit_code == 0, "{logs}");
        assert!(work.join("installed").exists(), "installer must run after parent exit: {logs}");
        // Start-Process deliberately does not wait for the reopened app.
        while !install_dir.join("reopened").exists() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        assert!(install_dir.join("reopened").exists(), "app must reopen: {logs}");
        assert_eq!(installer.exists(), exit_code != 0, "keep failed packages for recovery");
        if exit_code != 0 {
            assert!(logs.contains("7"), "record the installer failure: {logs}");
        }
    }
}
