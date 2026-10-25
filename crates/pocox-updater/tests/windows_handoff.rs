//! The helper end to end, with real processes: a stand-in app that waits to
//! be told to quit, the release's files and a stand-in installer. Nothing
//! touches the real app or elevates.
#![cfg(all(windows, feature = "handoff"))]
#![allow(
    clippy::unwrap_used,
    reason = "integration-test failures should fail at the observed boundary"
)]

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use ring::digest;
use serde_json::{json, Value};

/// A stand-in app reporting `version`: it records that it started (in its
/// working directory). Started by a test, it runs until told to quit on its
/// piped input; reopened by the helper (a hidden console, no pipe), it exits
/// at once rather than outliving the test.
fn app_source(version: &str) -> String {
    format!(
        r#"using System; using System.IO; using System.Reflection;
[assembly: AssemblyInformationalVersion("{version}")]
class App {{ static void Main() {{
  File.WriteAllText(Path.Combine(Environment.CurrentDirectory, "started-{version}"), "");
  if (Console.IsInputRedirected) Console.ReadLine();
}} }}"#
    )
}

/// A stand-in installer: copies `new.exe` from beside it over `/DIR`'s
/// `pocox.exe`, unless its `mode` file says `noop`; logs to `/LOG`.
const INSTALLER: &str = r#"using System; using System.IO;
class Installer { static int Main(string[] args) {
  string here = AppDomain.CurrentDomain.BaseDirectory, dir = null;
  foreach (string arg in args) {
    if (arg.StartsWith("/DIR=")) dir = arg.Substring(5);
    if (arg.StartsWith("/LOG=")) File.WriteAllText(arg.Substring(5), "installer ran");
  }
  if (File.ReadAllText(Path.Combine(here, "mode")) != "noop")
    File.Copy(Path.Combine(here, "new.exe"), Path.Combine(dir, "pocox.exe"), true);
  return 0;
} }"#;

fn compile(output: &Path, source: &str) {
    let input = output.with_extension("cs");
    fs::write(&input, source).unwrap();
    let compiler = Path::new(&std::env::var_os("SystemRoot").unwrap())
        .join("Microsoft.NET/Framework64/v4.0.30319/csc.exe");
    let result = Command::new(compiler)
        .arg("/nologo")
        .arg(format!("/out:{}", output.display()))
        .arg(&input)
        .output()
        .unwrap();
    assert!(result.status.success(), "{}", String::from_utf8_lossy(&result.stdout));
}

struct Fixtures {
    _dir: tempfile::TempDir,
    old: PathBuf,
    new: PathBuf,
    stale: PathBuf,
    installer: PathBuf,
}

fn fixtures() -> &'static Fixtures {
    static FIXTURES: OnceLock<Fixtures> = OnceLock::new();
    FIXTURES.get_or_init(|| {
        let dir = tempfile::tempdir().unwrap();
        let path = |name: &str| dir.path().join(name);
        compile(&path("old.exe"), &app_source("0.7.6+1"));
        compile(&path("new.exe"), &app_source("0.7.7+2"));
        compile(&path("stale.exe"), &app_source("0.7.5+0"));
        compile(&path("installer.exe"), INSTALLER);
        Fixtures {
            old: path("old.exe"),
            new: path("new.exe"),
            stale: path("stale.exe"),
            installer: path("installer.exe"),
            _dir: dir,
        }
    })
}

/// The running old app; ended even when an assertion fails.
struct App(Child);

impl App {
    fn quit(&mut self) {
        self.0.stdin.take().unwrap().write_all(b"\n").unwrap();
        self.0.wait().unwrap();
    }
}

impl Drop for App {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// One handoff: a copy of the old app running from `app_dir`, and the
/// release file in its own handoff directory.
struct Handoff {
    // Dropped first: a running app would keep its folder from being removed.
    app: App,
    request: PathBuf,
    root: tempfile::TempDir,
}

impl Handoff {
    fn app_dir(&self) -> PathBuf {
        self.root.path().join("POCOX app")
    }

    fn dir(&self) -> PathBuf {
        self.request.parent().unwrap().to_path_buf()
    }

    fn prepare(&self) -> std::process::Output {
        Command::new(env!("CARGO_BIN_EXE_pocox-updater"))
            .arg("--prepare")
            .arg(&self.request)
            .output()
            .unwrap()
    }

    /// Waits for the worker's status to reach one of `stages`.
    fn status(&self, stages: &[&str]) -> Value {
        let deadline = Instant::now() + Duration::from_secs(40);
        let mut last = Value::Null;
        loop {
            if let Ok(bytes) = fs::read(self.dir().join("status.json")) {
                last = serde_json::from_slice(&bytes).unwrap();
                if stages.contains(&last["stage"].as_str().unwrap()) {
                    return last;
                }
            }
            assert!(Instant::now() < deadline, "no {stages:?} status, last {last}");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// Waits for the app reporting `version` to have started from its folder.
    fn reopened(&self, version: &str) -> bool {
        let marker = self.app_dir().join(format!("started-{version}"));
        let deadline = Instant::now() + Duration::from_secs(10);
        while !marker.exists() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        marker.exists()
    }

    fn read(&self, name: &str) -> Vec<u8> {
        fs::read(self.app_dir().join(name)).unwrap()
    }
}

fn sha256(path: &Path) -> String {
    digest::digest(&digest::SHA256, &fs::read(path).unwrap())
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// Starts the old app and writes a request for `package`, made in the
/// handoff directory by `make`.
fn start(method: &str, make: impl FnOnce(&Path) -> PathBuf, tamper: bool) -> Handoff {
    let root = tempfile::Builder::new()
        .prefix("update 更新 & ")
        .tempdir()
        .unwrap();
    let app_dir = root.path().join("POCOX app");
    fs::create_dir_all(app_dir.join("data")).unwrap();
    fs::copy(&fixtures().old, app_dir.join("pocox.exe")).unwrap();
    fs::write(app_dir.join("data/app.so"), "old code").unwrap();
    fs::write(app_dir.join("pocox_bridge.dll"), "old bridge").unwrap();
    fs::write(app_dir.join("notes.txt"), "mine").unwrap();
    let dir = root.path().join("handoff");
    fs::create_dir(&dir).unwrap();
    let package = make(&dir);
    let app = App(Command::new(app_dir.join("pocox.exe"))
        .current_dir(root.path())
        .stdin(Stdio::piped())
        .spawn()
        .unwrap());
    let request = dir.join("request.json");
    let sha = if tamper { "0".repeat(64) } else { sha256(&package) };
    let body = json!({
        "processId": app.0.id(), "app": app_dir.join("pocox.exe"), "package": package,
        "size": fs::metadata(&package).unwrap().len(), "sha256": sha, "version": "0.7.7",
        "method": method, "elevate": false, "showErrors": false, "exitTimeoutSeconds": 30,
    });
    fs::write(&request, body.to_string()).unwrap();
    Handoff {
        root,
        app,
        request,
    }
}

/// The portable release archive, its app built from `exe`.
fn release(exe: &'static Path) -> impl FnOnce(&Path) -> PathBuf {
    move |dir| {
        let path = dir.join("pocox-app-v0.7.7-windows-x64.zip");
        let mut zip = zip::ZipWriter::new(fs::File::create(&path).unwrap());
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        for (name, contents) in [
            ("pocox.exe", fs::read(exe).unwrap()),
            ("data/app.so", b"new code".to_vec()),
            ("pocox_bridge.dll", b"new bridge".to_vec()),
        ] {
            zip.start_file(name, options).unwrap();
            zip.write_all(&contents).unwrap();
        }
        zip.finish().unwrap();
        path
    }
}

/// The stand-in installer with its `mode` and the new app beside it.
fn installer(mode: &'static str) -> impl FnOnce(&Path) -> PathBuf {
    move |dir| {
        fs::write(dir.join("mode"), mode).unwrap();
        fs::copy(&fixtures().new, dir.join("new.exe")).unwrap();
        let path = dir.join("pocox-app-v0.7.7-windows-x64-setup.exe");
        fs::copy(&fixtures().installer, &path).unwrap();
        path
    }
}

#[test]
fn a_portable_copy_is_replaced_after_it_quits_and_reopens() {
    let mut handoff = start("replace_folder", release(&fixtures().new), false);
    let prepared = handoff.prepare();
    assert!(prepared.status.success(), "{}", String::from_utf8_lossy(&prepared.stderr));
    assert_eq!(handoff.status(&["ready"])["stage"], "ready");
    assert_eq!(handoff.read("data/app.so"), b"old code", "nothing changes before the app quits");

    handoff.app.quit();
    let status = handoff.status(&["complete", "failed", "cancelled"]);
    assert_eq!(status["stage"], "complete", "{status}");
    assert_eq!(handoff.read("pocox.exe"), fs::read(&fixtures().new).unwrap());
    assert_eq!(handoff.read("data/app.so"), b"new code");
    assert_eq!(handoff.read("notes.txt"), b"mine", "the user's own files stay");
    assert!(handoff.reopened("0.7.7+2"), "the new version reopens from its folder");
    assert!(!handoff.app_dir().join(".pocox-update").exists());
}

#[test]
fn a_failed_swap_restores_the_copy_and_reopens_it() {
    use std::os::windows::fs::OpenOptionsExt;

    let mut handoff = start("replace_folder", release(&fixtures().new), false);
    assert!(handoff.prepare().status.success());
    // A straggler holds a file of the old version: it cannot be moved aside.
    let held = fs::OpenOptions::new()
        .read(true)
        .share_mode(0)
        .open(handoff.app_dir().join("pocox_bridge.dll"))
        .unwrap();
    handoff.app.quit();
    let status = handoff.status(&["complete", "failed"]);
    drop(held);
    assert_eq!(status["stage"], "failed", "{status}");
    assert_eq!(handoff.read("pocox.exe"), fs::read(&fixtures().old).unwrap());
    assert_eq!(handoff.read("data/app.so"), b"old code");
    assert!(handoff.reopened("0.7.6+1"), "the old version reopens");
}

#[test]
fn a_bad_release_is_refused_while_the_app_still_runs() {
    for (make, tamper, why) in [
        (release(&fixtures().stale), false, "reports version 0.7.5+0"),
        (release(&fixtures().new), true, "checksum differs"),
    ] {
        let mut handoff = start("replace_folder", make, tamper);
        let prepared = handoff.prepare();
        assert!(!prepared.status.success());
        let error = String::from_utf8_lossy(&prepared.stderr);
        assert!(error.contains(why), "{error}");
        assert!(handoff.app.0.try_wait().unwrap().is_none(), "the app keeps running");
        assert_eq!(handoff.read("data/app.so"), b"old code");
        assert!(!handoff.app_dir().join(".pocox-update").exists());
    }
}

#[test]
fn an_installer_runs_after_the_app_quits_and_its_result_is_checked() {
    let mut handoff = start("installer", installer("success"), false);
    let prepared = handoff.prepare();
    assert!(prepared.status.success(), "{}", String::from_utf8_lossy(&prepared.stderr));
    assert!(!handoff.dir().join("installer.log").exists(), "it waits for the app to quit");
    handoff.app.quit();
    let status = handoff.status(&["complete", "failed"]);
    assert_eq!(status["stage"], "complete", "{status}");
    assert_eq!(handoff.read("pocox.exe"), fs::read(&fixtures().new).unwrap());
    assert!(handoff.reopened("0.7.7+2"));

    // An installer that reports success without installing the release.
    let mut handoff = start("installer", installer("noop"), false);
    assert!(handoff.prepare().status.success());
    handoff.app.quit();
    let status = handoff.status(&["complete", "failed"]);
    assert!(
        status["message"]
            .as_str()
            .unwrap()
            .contains("reports version 0.7.6+1"),
        "{status}"
    );
    assert!(handoff.reopened("0.7.6+1"));
}

#[test]
fn a_called_off_update_changes_nothing_when_the_app_quits_later() {
    let mut handoff = start("installer", installer("success"), false);
    assert!(handoff.prepare().status.success());
    fs::write(handoff.dir().join("cancel"), "cancelled").unwrap();
    handoff.app.quit();
    assert_eq!(handoff.status(&["cancelled", "complete", "failed"])["stage"], "cancelled");
    std::thread::sleep(Duration::from_millis(500));
    assert!(!handoff.dir().join("installer.log").exists());
    assert_eq!(handoff.read("pocox.exe"), fs::read(&fixtures().old).unwrap());
}
