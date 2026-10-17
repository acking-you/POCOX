//! Opt-in production bridge lifecycle in an explicitly disposable process.
//! The launcher supplies isolated HOME/CODEX_HOME/OpenCode paths and a local
//! deterministic model endpoint. No user login or history is read.
use serde_json::json;

use super::*;
use crate::engine::{
    config, host_apply,
    host_profiles::{Change, Engine, KeyChange, ProfileInput, Runtime, RuntimeChange, Source},
    host_start::{self, Started},
    meta, opencode as controller, serve,
    session_engine::{self, StartOptions, TurnOptions},
};

fn change() -> Change {
    Change {
        input: ProfileInput {
            claude_env: Some(Default::default()),
            source: Source::Inherited,
            protocol: None,
            base_url: None,
            model: None,
        },
        key: KeyChange::Keep,
        runtime: RuntimeChange::Keep,
    }
}
struct Cleanup;
impl Drop for Cleanup {
    fn drop(&mut self) {
        let _ = serve::serve_stop_all();
    }
}

#[test]
#[ignore = "run only in a disposable process with PCX_NATIVE_FIXTURE_ROOT and PCX_OPENCODE_BIN"]
fn native_bridge_hosting_controller_and_original_resume() {
    let root = std::path::PathBuf::from(
        std::env::var_os("PCX_NATIVE_FIXTURE_ROOT").expect("explicit fixture"),
    );
    assert!(root.is_absolute() && root.join("isolated-fixture").is_file());
    for name in ["HOME", "CODEX_HOME", "OPENCODE_DB", "OPENCODE_CONFIG"] {
        assert!(
            std::path::PathBuf::from(std::env::var_os(name).expect(name)).starts_with(&root),
            "isolated {name}"
        );
    }
    let binary = std::env::var("PCX_OPENCODE_BIN").expect("installed native binary");
    runtime::init(root.join("support")).expect("isolated support");
    let mut config = pocket_codex_core::config::Config::default();
    config.pb_mapper.relay = Some("127.0.0.1:9".into());
    config.pb_mapper.key = Some("f".repeat(32));
    config::save_config(&root.join("support"), &config).expect("isolated offline relay");
    let _cleanup = Cleanup;
    let Started::OpenCode(report) = host_start::start_configured(
        Some("native-fixture"),
        Runtime::OpenCode {
            binary: Some(binary.clone()),
            separate_history: false,
        },
        change(),
    )
    .expect("native host") else {
        panic!("independent engine")
    };
    let name = &report.name;
    let key = &report.service_key;
    let row = serve::serve_status()
        .into_iter()
        .find(|row| &row.name == name)
        .expect("native status");
    assert_eq!(row.provider, "opencode");
    assert_eq!(row.protocol, "opencode-http");
    assert!(row.alive && row.api_service_key.is_empty() && row.opencode.is_some());
    let pid = row.pid.expect("owned process");
    let incarnation = row.incarnation.expect("incarnation");
    let owned = transport::resolve_owned_blocking().expect("self-host transport");
    assert!(local_gateway(key, &transport::Context::of(&owned.transport)).is_some());
    let duplicate = host_start::start_configured(
        Some("native-second"),
        Runtime::OpenCode {
            binary: Some(binary.clone()),
            separate_history: false,
        },
        change(),
    )
    .expect_err("source singleton");
    assert!(duplicate.to_string().contains("opencode_already_hosted"), "{duplicate}");
    assert!(!is_hosting("native-second"));
    assert_eq!(
        host_profiles::get("native-second")
            .expect("valid test fixture")
            .revision,
        0,
        "failed start restores saved record"
    );
    // With a history of its own, a second host runs beside the first.
    let Started::OpenCode(second) = host_start::start_configured(
        Some("native-second"),
        Runtime::OpenCode {
            binary: Some(binary.clone()),
            separate_history: true,
        },
        change(),
    )
    .expect("a second host with its own history") else {
        panic!("independent engine")
    };
    let rows = serve::serve_status();
    let second_row = rows
        .iter()
        .find(|row| row.name == second.name)
        .expect("second status");
    assert!(second_row
        .opencode
        .as_ref()
        .is_some_and(|s| s.separate_history));
    assert!(rows
        .iter()
        .find(|row| &row.name == name)
        .and_then(|row| row.opencode.as_ref())
        .is_some_and(|s| !s.separate_history));
    serve::serve_stop(&second.name).expect("second host stops alone");
    assert!(is_hosting(name) && !is_hosting(&second.name));
    let engine = session_engine::engine(key);
    assert_eq!(
        engine
            .probe_reason(key.clone())
            .expect("direct local probe"),
        None
    );
    engine
        .connect(key.clone(), 0)
        .expect("same-context direct connection, relay is offline");
    assert!(
        runtime::list_subscriptions().is_empty(),
        "local native connection has no relay subscription"
    );
    let caps = engine.capabilities(key);
    assert!(caps.negotiated && caps.commands && caps.question_multiple && caps.draft_options);
    assert!(caps.permission_options && !caps.permission_presets && !caps.voice);
    assert!(meta::project_config(key).is_ok(), "independent generic meta service");
    refresh_catalog(name).expect("refresh the exact native host catalog");
    let refreshed = serve::serve_status()
        .into_iter()
        .find(|row| &row.name == name)
        .expect("valid test fixture");
    assert_eq!(refreshed.incarnation.as_deref(), Some(incarnation.as_str()));
    assert!(refreshed
        .opencode
        .is_some_and(|catalog| catalog.models > 0 && catalog.problem.is_none()));
    let project = root.join("project");
    let original = engine
        .thread_start(key, StartOptions {
            cwd: Some(project.display().to_string()),
            model: Some("fixture/test".into()),
            ..Default::default()
        })
        .expect("native create");
    let access = controller::open(key, &original).expect("automatic open");
    assert_eq!(access.mode, "write");
    assert!(engine
        .thread_list(key)
        .expect("valid test fixture")
        .iter()
        .any(|s| s.id == original));
    let settings = engine
        .session_settings(key, &original)
        .expect("project native choices");
    assert!(settings.to_string().contains("careful"));
    let mut events = engine.subscribe_events(key).expect("controller events");
    engine
        .turn_start(key, &original, TurnOptions {
            text: "BRIDGE_NATIVE_FIXTURE".into(),
            ..Default::default()
        })
        .expect("once-only prompt");
    runtime::runtime().block_on(async {
        tokio::time::timeout(Duration::from_secs(45), async {
            loop {
                let event = events.recv().await.expect("live native event");
                if event.thread_id.as_deref() == Some(&original) && event.kind == "turn/completed" {
                    let raw: serde_json::Value =
                        serde_json::from_str(&event.raw).expect("valid test fixture");
                    assert_eq!(raw["turn"]["status"], "completed", "{raw}");
                    break;
                }
            }
        })
        .await
        .expect("native model completed");
    });
    let history = engine
        .thread_read(key, &original, false)
        .expect("original native transcript");
    assert!(
        history
            .items
            .iter()
            .any(|item| item.text.contains("BRIDGE_NATIVE_REPLY")),
        "{history:?}"
    );
    let view = controller::access(key, &original).expect("valid test fixture");
    let released = controller::release(key, &view).expect("release only this original");
    assert_eq!(released.reason, "released_here");
    assert_eq!(
        controller::access(key, &original)
            .expect("valid test fixture")
            .mode,
        "follow"
    );
    assert_eq!(
        controller::open(key, &original)
            .expect("valid test fixture")
            .mode,
        "write"
    );
    // The selected native session is a safe generic-meta file-link authority.
    let hosted = hosts()
        .hosts
        .get(name)
        .expect("valid test fixture")
        .host
        .clone();
    assert_eq!(
        runtime::runtime()
            .block_on(hosted.session_dir(&original))
            .expect("valid test fixture"),
        Some(project.display().to_string())
    );
    let previous = host_profiles::get(name).expect("valid test fixture");
    let bad = Change {
        runtime: RuntimeChange::Set(Runtime::OpenCode {
            binary: Some(root.join("missing-binary").display().to_string()),
            separate_history: false,
        }),
        ..change()
    };
    let bad = host_profiles::save_in(
        &host_profiles::root().expect("valid test fixture"),
        name,
        &bad,
        Some(previous.revision),
        Engine::OpenCode,
    )
    .expect("valid test fixture");
    let expected = host_apply::Expected {
        incarnation: Some(incarnation.clone()),
        revision: Some(bad.revision),
    };
    assert!(host_apply::apply(name, &expected).is_err(), "preflight fails before any stop");
    assert_eq!(relaunch(name).expect("valid test fixture").incarnation, incarnation);
    assert!(pocket_codex_core::process::pid_running(pid));
    let desired = Change {
        runtime: RuntimeChange::Set(Runtime::OpenCode {
            binary: Some(binary),
            separate_history: false,
        }),
        ..change()
    };
    let desired = host_profiles::save_in(
        &host_profiles::root().expect("valid test fixture"),
        name,
        &desired,
        Some(bad.revision),
        Engine::OpenCode,
    )
    .expect("valid test fixture");
    let applied = host_apply::apply(name, &host_apply::Expected {
        incarnation: Some(incarnation.clone()),
        revision: Some(desired.revision),
    })
    .expect("apply native runtime");
    assert!(applied.applied);
    assert_ne!(relaunch(name).expect("valid test fixture").incarnation, incarnation);
    assert!(!pocket_codex_core::process::pid_running(pid), "previous owned child exited");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while controller::is_connected(key) && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(!controller::is_connected(key), "host apply invalidates the previous live connection");
    engine
        .connect(key.clone(), 0)
        .expect("new native host connection");
    assert_eq!(
        controller::open(key, &original)
            .expect("valid test fixture")
            .session_id,
        original
    );
    assert!(engine
        .thread_read(key, &original, false)
        .expect("valid test fixture")
        .items
        .iter()
        .any(|item| item.text.contains("BRIDGE_NATIVE_REPLY")));
    engine.disconnect(key);
    serve::serve_stop(name).expect("confirmed native stop");
    assert!(!is_hosting(name));
    assert!(local_endpoints(key).is_none());
    serve::serve_stop_all().expect("quit drained all owned work");
    assert_eq!(opencode::runtime::pending_cleanup(), 0);
    std::fs::write(root.join("result.json"), serde_json::to_vec_pretty(&json!({"originalSession":original,"nativeProtocol":caps.protocol,"localWithoutRelay":true,"sourceSingleton":true,"originalHistoryAfterApply":true,"ownedProcessesStopped":true})).expect("valid test fixture")).expect("valid test fixture");
}

#[test]
fn a_separate_history_is_a_file_named_after_its_instance() {
    assert_eq!(history_database("My Host").expect("name"), "pocket-codex-my-host.db");
    let long = history_database(&"x".repeat(300)).expect("a long name");
    assert!(long.len() < 64 && !long.contains('/'), "{long}");
    assert_eq!(long, history_database(&"X".repeat(300)).expect("the same instance"));
    assert!(history_database(" ").is_err());
}

#[test]
fn configured_default_survives_catalog_failure_and_inherited_stays_unknown() {
    let catalog = || {
        serde_json::from_value(
            json!({"models":[],"agents":[],"commands":[],"defaults":{},"providersConnected":0}),
        )
        .expect("valid test fixture")
    };
    let custom = OpenCodeStatus::new("fixture".into(), Ok(catalog()), Some("chosen-model".into()));
    assert_eq!(custom.default_model.as_deref(), Some("chosen-model"));
    let failed = OpenCodeStatus::new(
        "fixture".into(),
        Err(opencode::host::Error::NotReady),
        custom.default_model,
    );
    assert_eq!(failed.default_model.as_deref(), Some("chosen-model"));
    assert!(failed.problem.is_some());
    assert!(OpenCodeStatus::new("fixture".into(), Ok(catalog()), None)
        .default_model
        .is_none());
}
