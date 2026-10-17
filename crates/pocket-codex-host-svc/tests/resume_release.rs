//! A failed release must not reach the app-server's resume path.
#![cfg(unix)]

use std::{fs::File, io::Write, process::Command};

use anyhow::{ensure, Context, Result};

const CHILD_HOME: &str = "PCX_RELEASE_TEST_HOME";
const SESSION: &str = "c75dce68-7855-4fd4-9e5c-f43771c03bd9";

#[test]
fn held_rollout_blocks_resume_before_connecting() -> Result<()> {
    if let Some(home) = std::env::var_os(CHILD_HOME) {
        ensure!(std::env::var_os("CODEX_HOME").as_ref() == Some(&home));
        let runtime = tokio::runtime::Runtime::new()?;
        // Nothing listens here: the app-server reports no loaded thread.
        let reader = pocket_codex_host_svc::app_server::CodexReader::new("127.0.0.1:0".parse()?);
        let outcome =
            runtime.block_on(pocket_codex_host_svc::resume::force_resume(&reader, SESSION))?;
        ensure!(outcome.still_held, "the parent still holds the fixture rollout");
        ensure!(outcome.killed.is_empty() && outcome.survived.is_empty());
        ensure!(!outcome.resumed);
        ensure!(
            outcome
                .resume_error
                .as_deref()
                .is_some_and(|error| error.contains("previous session owner was not released")),
            "must reject release failure before resuming: {:?}",
            outcome.resume_error
        );
        return Ok(());
    }

    let root = tempfile::tempdir()?;
    let sessions = root.path().join("sessions/2026/10/14");
    std::fs::create_dir_all(&sessions)?;
    let path = sessions.join(format!("rollout-2026-10-14T00-00-00-{SESSION}.jsonl"));
    // Keep a non-app-server owner alive. Releasing this session must neither
    // kill the parent test process nor proceed past its surviving file handle.
    let mut held = File::create(path)?;
    writeln!(
        held,
        "{}",
        serde_json::json!({
            "type":"session_meta", "payload":{"id":SESSION,"source":"cli"}
        })
    )?;
    held.sync_all()?;
    let output = Command::new(std::env::current_exe()?)
        .args(["--exact", "held_rollout_blocks_resume_before_connecting", "--nocapture"])
        .env("CODEX_HOME", root.path())
        .env(CHILD_HOME, root.path())
        .output()
        .context("running isolated release regression")?;
    ensure!(
        output.status.success(),
        "release regression failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    drop(held);
    Ok(())
}
