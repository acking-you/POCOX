//! Opt-in, against an installed Grok Build in a throwaway home:
//!
//! ```sh
//! cargo test -p pocket_codex_bridge --lib grok_account -- --ignored --test-threads=1
//! ```
//!
//! The sign-in contacts Grok's device-code service and is cancelled before
//! anyone approves it; nothing is signed in.

use std::time::{Duration, Instant};

use serde_json::json;

use super::*;

const SESSION: &str = "01a15501-b678-7db0-b062-a1f5b1edc8d1";

/// A session as Grok 1.0 stores one (shape of a real `summary.json`).
fn seed(home: &std::path::Path) {
    let dir = home.join("sessions").join("%2Fwork").join(SESSION);
    std::fs::create_dir_all(&dir).expect("dir");
    let summary = json!({
        "info": {"id": SESSION, "cwd": "/work"},
        "session_summary": "ping",
        "created_at": "2026-10-19T16:32:18.147991Z",
        "updated_at": "2026-10-19T16:32:19.422614Z",
        "num_messages": 2,
        "num_chat_messages": 5,
        "current_model_id": "fake-1",
        "next_trace_turn": 1,
        "chat_format_version": 1,
        "last_active_at": "2026-10-19T16:32:19.422614Z",
        "generated_title": "ping",
        "agent_name": "grok-build-plan",
        "sandbox_profile": "off",
    });
    std::fs::write(dir.join("summary.json"), summary.to_string()).expect("summary");
}

fn titles() -> Vec<String> {
    let source = native_sessions::source("grok", None, true).expect("source");
    let listed = runtime::runtime()
        .block_on(source.reader.list_sessions(None, 10))
        .expect("list");
    listed["sessions"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|row| row["title"].as_str().unwrap_or_default().to_string())
        .collect()
}

#[test]
#[ignore = "needs an installed Grok Build and its device-code service"]
fn grok_account_and_local_sessions_through_grok_itself() {
    let home = tempfile::TempDir::new().expect("home");
    // reason: an opt-in test run alone (`--test-threads=1`); the variable
    // selects only the throwaway Grok home this process's `grok` uses.
    std::env::set_var(grok::HOME_ENV, home.path());
    runtime::init(home.path().join("support")).expect("runtime");
    seed(home.path());

    let account = status(None).expect("status");
    assert!(!account.signed_in, "a fresh home has no sign-in");

    let attempt = sign_in_start(None).expect("start");
    let deadline = Instant::now() + Duration::from_secs(30);
    let waiting = loop {
        let state = sign_in_state(attempt).expect("state");
        if state.phase == "waiting" || state.ended() {
            break state;
        }
        assert!(Instant::now() < deadline, "no sign-in page");
        std::thread::sleep(Duration::from_millis(200));
    };
    assert_eq!(waiting.phase, "waiting", "{waiting:?}");
    assert!(waiting
        .url
        .as_deref()
        .is_some_and(|url| url.starts_with("https://")));
    assert!(waiting.code.is_some(), "the device code is shown");
    sign_in_cancel(attempt).expect("cancel");
    assert!(!status(None).expect("status").signed_in, "nothing was signed in");

    // The Grok-account route refuses a default model the user defined.
    let preset = pocket_codex_host_svc::acp::spec::preset(grok::PROFILE_ID)
        .expect("preset")
        .spec();
    let route = grok::account_launch();
    super::super::host_profiles::grok::account_preflight(&preset, &route)
        .expect("Grok's own default model");
    std::fs::write(
        home.path().join("config.toml"),
        "[models]\ndefault = \"mine\"\n[model.mine]\nmodel = \"m\"\nbase_url = \
         \"http://127.0.0.1:9/v1\"\n",
    )
    .expect("config");
    let refused = super::super::host_profiles::grok::account_preflight(&preset, &route)
        .expect_err("a user-defined default");
    assert!(format!("{refused:#}").contains("would not use the Grok account"), "{refused:#}");
    std::fs::remove_file(home.path().join("config.toml")).expect("restore");

    assert_eq!(titles(), ["ping"]);
    manage_session(SESSION, Some("Renamed here"), None).expect("rename");
    assert_eq!(titles(), ["Renamed here"]);
    manage_session(SESSION, None, None).expect("delete");
    assert!(titles().is_empty());
}
