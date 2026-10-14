use super::*;

#[test]
fn stale_pid_replaced_image_or_changed_directory_never_matches() {
    let record = Record {
        pid: 42,
        session_id: "session".into(),
        cwd: "/work".into(),
        started_at: 100_999,
        status: "idle".into(),
    };
    let process = ProcessIdentity {
        pid: 42,
        started: 100,
        executable: "/cli".into(),
        cwd: "/work".into(),
    };
    let matches = |value: &ProcessIdentity| {
        matches_identity(&record, &process.executable, &record.cwd, value)
    };
    assert!(matches(&process));
    assert!(!matches(&ProcessIdentity {
        pid: 43,
        ..process.clone()
    }));
    assert!(!matches(&ProcessIdentity {
        started: 104,
        ..process.clone()
    }));
    assert!(!matches(&ProcessIdentity {
        executable: "/another".into(),
        ..process.clone()
    }));
    assert!(!matches(&ProcessIdentity {
        cwd: "/another".into(),
        ..process.clone()
    }));
}

#[test]
fn empty_inventory_is_not_permission_to_resume() {
    let status = inspect_records("session", std::path::Path::new("/missing"), &[]);
    assert_eq!(status.safety, "nativeUnknown");
    assert!(!status.allows_resume);
    assert!(!status.requires_takeover);
}

#[test]
fn verified_activity_never_implies_an_exclusive_write_lease() {
    let process = process_identity(std::process::id()).expect("own identity");
    let mut record = Record {
        pid: process.pid,
        session_id: "session".into(),
        cwd: process.cwd.clone(),
        started_at: process.started * 1000,
        status: "idle".into(),
    };
    for (state, expected) in [
        ("idle", "nativeOwnedIdle"),
        ("busy", "nativeOwnedRunning"),
        ("running", "nativeOwnedRunning"),
        ("future-state", "nativeUnknown"),
    ] {
        record.status = state.into();
        let live = inspect_records("session", &process.executable, &[record.clone()]);
        assert_eq!(live.safety, expected);
        assert!(live.held_open);
        assert_eq!(live.holders.len(), 1);
        assert!(!live.allows_resume);
        assert!(!live.requires_takeover);
    }
    let duplicate = inspect_records("session", &process.executable, &[record.clone(), record]);
    assert_eq!(duplicate, unknown("session"));
}

#[tokio::test]
async fn failed_probe_remains_unknown_and_does_not_reuse_older_evidence() {
    let probe =
        Probe::new("/definitely-missing-claude".into(), "/home".into(), "/home/.claude".into());
    let id = "a0000000-0000-4000-8000-000000000000";
    *probe.cache.lock().await = Some(Inventory {
        at: Instant::now() - CACHE_TTL,
        records: vec![Record {
            pid: std::process::id(),
            session_id: id.into(),
            cwd: std::env::current_dir().expect("cwd"),
            started_at: 1,
            status: "running".into(),
        }],
    });
    let result = probe.inspect(id).await;
    assert_eq!(result, unknown(id));
    assert!(probe
        .cache
        .lock()
        .await
        .as_ref()
        .is_some_and(|value| value.records.is_empty()));
}

#[cfg(unix)]
#[tokio::test]
async fn handoff_probe_bypasses_display_cache_and_distinguishes_failure_from_empty() {
    use std::os::unix::fs::PermissionsExt;
    let root = tempfile::tempdir().expect("fixture");
    let program = root.path().join("inventory");
    std::fs::write(&program, "#!/bin/sh\ncat >/dev/null\nprintf '[]'\n").expect("script");
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).expect("mode");
    let probe = Probe::new(program.clone(), root.path().into(), root.path().into());
    let id = "a0000000-0000-4000-8000-000000000000";
    *probe.cache.lock().await = Some(Inventory {
        at: Instant::now(),
        records: vec![Record {
            pid: 123,
            session_id: id.into(),
            cwd: root.path().into(),
            started_at: 1,
            status: "running".into(),
        }],
    });
    assert!(probe
        .idle_owners(id)
        .await
        .expect("fresh empty inventory")
        .is_empty());
    std::fs::write(&program, "#!/bin/sh\ncat >/dev/null\nprintf 'not-json'\n").expect("failure");
    assert!(probe.idle_owners(id).await.is_err(), "parse failure is not a released session");
    assert!(probe.idle_owners("invalid").await.is_err());
}

#[tokio::test]
#[ignore = "requires a parent-owned native CLI runtime fixture"]
async fn native_cli_fixture_ownership_is_read_only() {
    let get = |name| std::env::var(name).expect("explicit fixture variable");
    let probe = Probe::new(
        get("PCX_TEST_CLAUDE").into(),
        get("PCX_TEST_HOME").into(),
        get("PCX_TEST_CLAUDE_ROOT").into(),
    );
    let session = get("PCX_TEST_CLAUDE_SESSION");
    let pid: u32 = get("PCX_TEST_CLAUDE_PID").parse().expect("fixture pid");
    let result = probe.inspect(&session).await;
    if get("PCX_TEST_CLAUDE_ALIVE") == "1" {
        assert!(result.held_open, "native inventory must identify its live fixture");
        assert!(result.holders.iter().any(|holder| holder.pid == pid));
    } else {
        assert_eq!(result, unknown(&session));
    }
    assert!(!result.allows_resume);
    assert!(!result.requires_takeover);
}
