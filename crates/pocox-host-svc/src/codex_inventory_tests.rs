use std::io::Write;

use super::*;

const STARTED: &str = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n";

fn thread(id: &str, path: &Path, status: Value) -> Value {
    json!({"id": id, "path": path, "status": status, "preview": "hi", "cwd": "/repo",
        "source": "vscode", "updatedAt": 7})
}

#[test]
fn the_app_server_owns_its_loaded_threads_and_files_decide_the_rest() {
    let dir = tempfile::tempdir().expect("tempdir");
    let rollout = |name: &str| {
        let path = dir.path().join(format!("rollout-{name}.jsonl"));
        std::fs::write(&path, STARTED).expect("rollout");
        path
    };
    let running = rollout("running");
    let idle = rollout("idle");
    let crashed = rollout("crashed");
    let foreign = rollout("foreign");
    // Another process (here: this test) still writes this one.
    let _writer = std::fs::OpenOptions::new()
        .append(true)
        .open(&foreign)
        .expect("writer");
    // Listed by its plain name after Codex compressed it.
    let cold = dir.path().join("rollout-cold.jsonl");
    std::fs::write(
        dir.path().join("rollout-cold.jsonl.zst"),
        zstd::encode_all(STARTED.as_bytes(), 0).expect("encode"),
    )
    .expect("compressed");
    let mut guardian = thread("guardian", &idle, json!({"type": "active", "activeFlags": []}));
    guardian["threadSource"] = json!("guardian_review");

    let listed = annotate(&[
        thread(
            "running",
            &running,
            json!({"type": "active", "activeFlags": ["waitingOnApproval"]}),
        ),
        thread("idle", &idle, json!({"type": "idle"})),
        thread("crashed", &crashed, json!({"type": "notLoaded"})),
        thread("foreign", &foreign, json!({"type": "notLoaded"})),
        thread("cold", &cold, json!({"type": "notLoaded"})),
        guardian,
    ]);
    fn view(s: &LocalSession) -> (Option<&str>, &str, &str, bool, bool) {
        (s.status.as_deref(), &s.turn_state, &s.safety, s.allows_resume, s.requires_takeover)
    }
    // Running here: joining it is a plain resume, nothing is evicted.
    assert_eq!(view(&listed[0]), (Some("active"), "incomplete", "ownedRunning", true, false));
    // Loaded and idle, or held by nobody: an unfinished turn was interrupted.
    assert_eq!(view(&listed[1]), (Some("idle"), "aborted", "resumableUnfinished", true, false));
    assert_eq!(
        view(&listed[2]),
        (Some("notLoaded"), "aborted", "resumableUnfinished", true, false)
    );
    // Another process writes it: only the files can tell, and it looks running.
    assert_eq!(view(&listed[3]), (Some("notLoaded"), "incomplete", "ownedRunning", false, false));
    assert!(listed[3].held_open);
    assert_eq!(view(&listed[4]), (Some("notLoaded"), "unknown", "resumable", true, false));
    assert!(!listed[5].allows_resume, "Guardian reviews stay read-only");
    assert_eq!(
        (listed[0].preview.as_str(), listed[0].source.as_deref(), listed[0].updated_at),
        ("hi", Some("vscode"), 7)
    );
}

#[test]
fn a_foreign_writer_that_finished_needs_a_takeover() {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("rollout-done.jsonl");
    let mut writer = std::fs::File::create(&path).expect("writer");
    writeln!(
        writer,
        "{STARTED}{{\"type\":\"event_msg\",\"payload\":{{\"type\":\"task_complete\"}}}}"
    )
    .expect("turn");
    let listed = annotate(&[thread("done", &path, json!({"type": "notLoaded"}))]);
    assert_eq!(listed[0].safety, "ownedIdle");
    assert!(listed[0].allows_resume && listed[0].requires_takeover);
}
