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
