//! Opt-in isolated integration of the host session routes with an installed
//! external Codex executable. Set POCOX_TEST_CODEX_BINARY to the native binary
//! and run this test with --ignored. Sessions, configuration and listeners are
//! temporary; no model turn is started and no existing host is contacted.

use std::{
    io::Write,
    path::{Path, PathBuf},
    process::Stdio,
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{ensure, Context, Result};
use pocox_codex::client::AppClient;
use pocox_host_svc::store::{ConfigStore, HostStore};
use serde_json::{json, Value};

const PLAIN: &str = "5f0b7c8e-3c5f-4b8e-9d6a-2f1e0c9b8a71";
const COLD: &str = "6a1c8d9f-4d6a-4c9f-8e7b-3a2f1d0c9b82";

#[tokio::test]
#[ignore = "requires POCOX_TEST_CODEX_BINARY; creates an isolated external app-server"]
async fn host_inventory_follows_the_app_server_and_reads_compressed_rollouts() -> Result<()> {
    let binary = PathBuf::from(
        std::env::var_os("POCOX_TEST_CODEX_BINARY").context("POCOX_TEST_CODEX_BINARY required")?,
    );
    let temporary = tempfile::tempdir()?;
    let home = temporary.path().join("codex-home");
    let day = home.join("sessions/2026/09/25");
    std::fs::create_dir_all(&day)?;
    std::fs::write(
        home.join("config.toml"),
        r#"
model = "fixture-model"
model_provider = "fixture"
[model_providers.fixture]
name = "Isolated inventory fixture"
base_url = "http://127.0.0.1:9/v1"
wire_api = "responses"
requires_openai_auth = false
"#,
    )?;
    // The file-only probes read the same home as the app-server. This is the
    // only test in its binary, so nothing else observes the variable.
    std::env::set_var("CODEX_HOME", &home);
    std::fs::write(
        day.join(format!("rollout-2026-09-25T00-00-00-{PLAIN}.jsonl")),
        rollout(PLAIN, temporary.path()),
    )?;
    std::fs::write(
        day.join(format!("rollout-2026-09-25T00-00-01-{COLD}.jsonl.zst")),
        zstd::encode_all(rollout(COLD, temporary.path()).as_bytes(), 0)?,
    )?;

    let reserved = std::net::TcpListener::bind("127.0.0.1:0")?;
    let address = reserved.local_addr()?;
    drop(reserved);
    let log = std::fs::File::create(temporary.path().join("app-server.log"))?;
    let mut process = tokio::process::Command::new(binary)
        .args(["app-server", "--listen", &format!("ws://{address}")])
        .env("CODEX_HOME", &home)
        .current_dir(temporary.path())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(log)
        .kill_on_drop(true)
        .spawn()?;
    let deadline = Instant::now() + Duration::from_secs(20);
    let (controller, events) = loop {
        if let Ok(client) = AppClient::connect(&format!("ws://{address}")).await {
            break client;
        }
        ensure!(
            Instant::now() < deadline && process.try_wait()?.is_none(),
            "isolated app-server did not start"
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    };
    drop(events);
    controller.initialize("pocox-inventory-test", true).await?;

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let base = format!("http://{}", listener.local_addr()?);
    let store = Arc::new(ConfigStore::open(temporary.path().join("threads.json")).await?);
    let host = Arc::new(HostStore::open(temporary.path().join("host.json")).await?);
    let server = tokio::spawn(pocox_host_svc::serve(listener, address, store, host));
    let http = reqwest::Client::new();
    let get = |path: String| {
        let http = http.clone();
        let url = format!("{base}{path}");
        async move {
            http.get(url)
                .send()
                .await?
                .error_for_status()?
                .json::<Value>()
                .await
        }
    };
    let find = |listing: &Value, id: &str| -> Result<Value> {
        listing["sessions"]
            .as_array()
            .context("sessions")?
            .iter()
            .find(|s| s["thread_id"] == id)
            .cloned()
            .with_context(|| format!("{id} missing from {listing}"))
    };

    // Listed by the app-server, the compressed rollout included.
    let listing = get("/sessions".into()).await?;
    let cold = find(&listing, COLD)?;
    ensure!(cold["status"] == "notLoaded" && cold["allows_resume"] == true, "{cold}");
    ensure!(find(&listing, PLAIN)?["status"] == "notLoaded", "{listing}");
    let transcript = get(format!("/sessions/{COLD}/transcript")).await?;
    ensure!(transcript.to_string().contains("Inventory fixture"), "{transcript}");

    // Loaded by one client: idle, joinable, nothing to evict.
    controller
        .request("thread/resume", json!({"threadId": PLAIN, "excludeTurns": true}))
        .await?;
    let plain = find(&get("/sessions".into()).await?, PLAIN)?;
    ensure!(
        plain["status"] == "idle"
            && plain["allows_resume"] == true
            && plain["requires_takeover"] == false,
        "{plain}"
    );
    let running = get("/sessions?running_only=true".into()).await?;
    ensure!(running["sessions"].as_array().is_some_and(Vec::is_empty), "{running}");
    let liveness = get(format!("/sessions/{PLAIN}/liveness")).await?;
    ensure!(
        liveness["holders"].as_array().is_some_and(Vec::is_empty)
            && liveness["requires_takeover"] == false,
        "{liveness}"
    );
    let joined: Value = http
        .post(format!("{base}/sessions/{PLAIN}/resume"))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;
    ensure!(
        joined["resumed"] == true && joined["killed"].as_array().is_some_and(Vec::is_empty),
        "{joined}"
    );

    server.abort();
    drop(controller);
    process.kill().await?;
    process.wait().await?;
    Ok(())
}

fn rollout(id: &str, cwd: &Path) -> String {
    let line = |kind: &str, payload: Value| json!({"timestamp": "2026-09-25T00:00:00Z", "type": kind, "payload": payload});
    let mut out = Vec::new();
    for value in [
        line(
            "session_meta",
            json!({"id": id, "session_id": id, "timestamp": "2026-09-25T00:00:00Z", "cwd": cwd,
                "originator": "codex", "cli_version": "0.0.0", "source": "cli",
                "model_provider": "fixture", "history_mode": "legacy",
                "selected_capability_roots": []}),
        ),
        line("event_msg", json!({"type": "task_started", "turn_id": "turn"})),
        line(
            "response_item",
            json!({"type": "message", "role": "user",
                "content": [{"type": "input_text", "text": "Inventory fixture"}]}),
        ),
        line(
            "event_msg",
            json!({"type": "user_message", "message": "Inventory fixture", "images": [],
                "local_images": [], "text_elements": []}),
        ),
        line("event_msg", json!({"type": "task_complete", "turn_id": "turn"})),
    ] {
        writeln!(out, "{value}").expect("in-memory write");
    }
    String::from_utf8(out).expect("utf-8 fixture")
}
