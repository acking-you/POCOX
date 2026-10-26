use std::collections::BTreeMap;
use std::path::Path;

use super::command::{classify, Failure};
use super::install::{self, Manager, Method};
use super::view::SettingsChange;
use super::{latest, settings, Kind};

/// A controller names a harness and a setting, never a program, an argument
/// or a field this host does not know.
#[test]
fn requests_name_a_harness_only() {
    assert_eq!(serde_json::from_str::<Kind>("\"opencode\"").expect("kind"), Kind::OpenCode);
    for value in ["\"/usr/bin/npm\"", "\"codex --version\"", "\"Codex\""] {
        assert!(serde_json::from_str::<Kind>(value).is_err(), "{value}");
    }
    for value in [
        serde_json::json!({"kind": "codex", "autoUpdate": true, "program": "/tmp/x"}),
        serde_json::json!({"restartServices": true, "args": ["--global"]}),
    ] {
        assert!(serde_json::from_value::<SettingsChange>(value).is_err());
    }
}

#[test]
fn older_hosts_can_omit_progress_measurements() {
    let job: super::view::Job = serde_json::from_value(serde_json::json!({
        "run": 1, "kind": "codex", "state": "running", "stage": "updating",
        "automatic": false, "restarted": [], "notRestarted": [], "startedAtMs": 1
    }))
    .expect("an older host's job");
    assert!(job.download.is_none());
    assert!(job.elapsed_ms.is_none());
}

#[test]
fn versions_are_read_from_each_vendor_and_compared_within_a_line() {
    for (output, version) in [
        ("codex-cli 0.46.0\n", "0.46.0"),
        ("opencode v2.1.4", "2.1.4"),
        ("1.19.4\n", "1.19.4"),
        ("2.1.296 (Claude Code)\n", "2.1.296"),
        ("grok 1.0.62 (abcdef123456) [stable]\n", "1.0.62"),
    ] {
        assert_eq!(install::version_text(output).as_deref(), Some(version), "{output}");
    }
    assert_eq!(install::version_text("codex-cli dev"), None);
    assert!(install::is_newer("0.47.0", "0.46.0", None));
    assert!(!install::is_newer("0.46.0", "0.46.0", None));
    assert!(!install::is_newer("0.47.0-alpha.1", "0.47.0", None));
    assert!(install::is_newer("1.0.0", "0.99.3", None));
    // OpenCode 2 is a migration of its own, never an update of OpenCode 1.
    assert!(!install::is_newer("2.1.4", "1.19.4", Some(1)));
    assert!(install::is_newer("1.19.5", "1.19.4", Some(1)));
    assert!(!install::is_newer("unknown", "1.0.0", None));
}

fn touch(path: &Path) {
    std::fs::create_dir_all(path.parent().expect("parent")).expect("dirs");
    std::fs::write(path, b"").expect("file");
}

/// As upstream's install context, judged from the executable POCOX runs.
#[test]
fn codex_installations_update_as_their_installer_does() {
    let root = tempfile::tempdir().expect("temp");
    let home = root.path().join("codex-home");
    let standalone = home.join("packages/standalone/releases/0.46.0/codex");
    touch(&standalone);
    assert_eq!(install::codex_method(&standalone, Some(&home), false), Method::Standalone);

    // An npm global shim beside its package (Windows' layout).
    let npm = root.path().join("npm");
    touch(&npm.join("node_modules/@openai/codex/package.json"));
    touch(&npm.join("codex.cmd"));
    assert_eq!(
        install::codex_method(&npm.join("codex.cmd"), Some(&home), false),
        Method::Package(Manager::Npm)
    );
    // Bun links its `bin` beside `install/global`.
    let bun = root.path().join(".bun");
    touch(&bun.join("install/global/node_modules/@openai/codex/package.json"));
    touch(&bun.join("bin/codex"));
    assert_eq!(
        install::codex_method(&bun.join("bin/codex"), Some(&home), false),
        Method::Package(Manager::Bun)
    );
    // pnpm keeps global packages in `global/<n>` beside its shims.
    let pnpm = root.path().join("pnpm");
    touch(&pnpm.join("global/5/node_modules/@openai/codex/package.json"));
    touch(&pnpm.join("codex"));
    assert_eq!(
        install::codex_method(&pnpm.join("codex"), Some(&home), false),
        Method::Package(Manager::Pnpm)
    );

    let copied = root.path().join("tools/codex");
    touch(&copied);
    assert_eq!(install::codex_method(&copied, Some(&home), false), Method::Not("unmanaged"));
    assert_eq!(
        install::codex_method(Path::new("/opt/homebrew/bin/codex"), None, true),
        Method::Brew
    );
    assert_eq!(
        install::codex_method(Path::new("/opt/homebrew/bin/codex"), None, false),
        Method::Not("unmanaged")
    );
}

/// A check whose probes ran before an update finished never puts back the
/// version the update replaced; it still brings the newest one it found.
#[test]
fn a_check_never_replaces_what_a_later_update_installed() {
    let found = |kind, version: &str, latest: &str| super::service::Found {
        installed: Some(install::Installed {
            kind,
            path: format!("/bin/{}", kind.label()).into(),
            version: Some(version.into()),
            method: Method::Own,
            source: install::Source::Unchecked,
        }),
        latest: Some(latest.into()),
    };
    let version = |found: &super::service::Found| {
        found
            .installed
            .as_ref()
            .and_then(|installed| installed.version.clone())
    };
    let mut current = BTreeMap::from([
        (Kind::Codex, found(Kind::Codex, "0.47.0", "0.47.0")),
        (Kind::OpenCode, found(Kind::OpenCode, "1.19.4", "1.19.4")),
    ]);
    let checked = BTreeMap::from([
        (Kind::Codex, found(Kind::Codex, "0.46.0", "0.48.0")),
        (Kind::OpenCode, found(Kind::OpenCode, "1.19.5", "1.19.5")),
    ]);
    super::service::publish(&mut current, checked, |kind| kind == Kind::Codex);
    assert_eq!(version(&current[&Kind::Codex]).as_deref(), Some("0.47.0"));
    assert_eq!(current[&Kind::Codex].latest.as_deref(), Some("0.48.0"));
    assert_eq!(version(&current[&Kind::OpenCode]).as_deref(), Some("1.19.5"));
}

#[test]
fn each_device_keeps_its_own_settings() {
    let root = tempfile::tempdir().expect("temp");
    let saved = settings::load_in(root.path()).expect("defaults");
    assert!(saved.restart_services);
    assert!(!saved.auto(Kind::Codex));
    let codex = |auto| SettingsChange {
        kind: Some(Kind::Codex),
        auto_update: Some(auto),
        restart_services: None,
    };
    let saved = settings::change_in(root.path(), &codex(true)).expect("saved");
    assert!(saved.auto(Kind::Codex) && saved.restart_services);
    let saved = settings::change_in(root.path(), &SettingsChange {
        restart_services: Some(false),
        ..SettingsChange::default()
    })
    .expect("saved");
    assert!(saved.auto(Kind::Codex) && !saved.restart_services);
    assert!(settings::change_in(root.path(), &SettingsChange {
        auto_update: Some(true),
        ..SettingsChange::default()
    })
    .is_err());
    // A harness a newer version added stays enabled through this one.
    std::fs::write(
        root.path().join("harnesses.json"),
        br#"{"restartServices":true,"autoUpdate":["codex","future"]}"#,
    )
    .expect("newer file");
    let saved = settings::change_in(root.path(), &codex(false)).expect("saved");
    assert!(!saved.auto(Kind::Codex));
    assert!(saved.auto_update.contains("future"));
    assert_eq!(settings::load_in(root.path()).expect("read back"), saved);
}

#[test]
fn grok_reports_its_own_latest_version_or_why_it_could_not() {
    let answer = r#"{"currentVersion":"1.0.61 (abcdef)","latestVersion":"1.0.62","updateAvailable":true,"installer":"internal","channel":"stable","autoUpdate":true,"error":null}"#;
    assert_eq!(latest::grok_latest(answer).expect("latest"), "1.0.62");
    let failed = r#"{"currentVersion":"1.0.61","latestVersion":null,"error":"offline"}"#;
    assert!(latest::grok_latest(failed).is_err());
    assert!(latest::grok_latest("not json").is_err());
}

#[test]
fn installer_failures_are_told_apart() {
    let busy = "npm error code EBUSY\nnpm error syscall rename";
    assert_eq!(classify(busy, false), Failure::InUse);
    let locked = "npm error code EPERM\nnpm error syscall rename";
    assert_eq!(classify(locked, true), Failure::InUse);
    assert_eq!(classify(locked, false), Failure::Permission);
    assert_eq!(classify("npm error code EACCES\npermission denied", false), Failure::Permission);
    assert_eq!(classify("npm error 404 Not Found", false), Failure::Failed);
}

fn codex_at(path: &Path, version: Option<&str>) -> install::Installed {
    install::Installed {
        kind: Kind::Codex,
        path: path.to_path_buf(),
        version: version.map(str::to_string),
        method: Method::Brew,
        source: install::Source::Cask("codex"),
    }
}

/// Homebrew can replace the cask's symlink and then fail unrelated maintenance.
/// The same launch path must verify the upgrade and allow its services to
/// restart.
#[cfg(unix)]
#[test]
fn an_installer_error_does_not_discard_a_verified_upgrade() {
    use std::os::unix::fs::{self, PermissionsExt};

    use super::command::{self, Invocation};

    let root = tempfile::tempdir().expect("temp");
    let old = root.path().join("codex-0.163.0");
    let new = root.path().join("codex-0.164.0");
    for (path, version) in [(&old, "0.163.0"), (&new, "0.164.0")] {
        std::fs::write(path, format!("#!/bin/sh\nprintf 'codex-cli {version}\\n'\n"))
            .expect("version fixture");
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).expect("executable");
    }
    let path = root.path().join("codex");
    fs::symlink(&old, &path).expect("old launch path");
    let before = codex_at(&path, None).recheck().expect("installed");
    assert_eq!(before.version.as_deref(), Some("0.163.0"));
    let result = command::install(
        &Invocation {
            program: "/bin/sh".into(),
            args: vec![
                "-c".into(),
                "rm \"$1\" && ln -s \"$2\" \"$1\"; printf 'maintenance failed\\n' >&2; exit 1"
                    .into(),
                "fixture".into(),
                path.to_string_lossy().into_owned(),
                new.to_string_lossy().into_owned(),
            ],
        },
        |_| {},
    );
    assert_eq!(result, Err(Failure::Failed));
    let after = before.recheck().expect("updated launch path");
    assert_eq!(after.path, path);
    assert_eq!(after.version.as_deref(), Some("0.164.0"));
    assert_eq!(before.verify(Some(&after), result), Ok(install::Change::Updated));
}

#[test]
fn an_update_needs_version_evidence_from_the_same_installation() {
    let before = codex_at(Path::new("/managed/codex"), Some("0.163.0"));
    assert_eq!(before.verify(Some(&before), Ok(())), Ok(install::Change::Unchanged));
    assert_eq!(before.verify(Some(&before), Err(Failure::Permission)), Err(Failure::Permission));
    let other = codex_at(Path::new("/other/codex"), Some("0.164.0"));
    assert_eq!(before.verify(Some(&other), Ok(())), Err(Failure::Failed));
    let older = codex_at(&before.path, Some("0.162.0"));
    assert_eq!(before.verify(Some(&older), Ok(())), Err(Failure::Failed));
    let unknown = codex_at(&before.path, None);
    assert_eq!(before.verify(Some(&unknown), Ok(())), Err(Failure::Failed));
    assert_eq!(before.verify(None, Err(Failure::TimedOut)), Err(Failure::TimedOut));
}

#[test]
fn a_removed_executable_is_not_replaced_by_another_detected_installation() {
    let root = tempfile::tempdir().expect("temp");
    let before = codex_at(&root.path().join("codex"), Some("0.163.0"));
    touch(&before.path);
    // An existing but non-executable file cannot confirm an upgrade either.
    let unreadable = before.recheck().expect("file exists");
    assert_eq!(before.verify(Some(&unreadable), Ok(())), Err(Failure::Failed));
    std::fs::remove_file(&before.path).expect("installer removed old executable");
    assert!(before.recheck().is_none(), "verification stays on the managed launch path");
}
