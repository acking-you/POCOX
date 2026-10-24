use std::sync::mpsc;
use std::time::{Duration, Instant};

use super::*;
use crate::engine::owned_child::tests::{refuse_stops, sleeper};

#[test]
fn local_process_exits_while_relay_cleanup_is_still_pending() {
    runtime::init(std::env::temp_dir()).expect("runtime");
    let (_process, child) = sleeper();
    let (withdrawing, entered) = mpsc::sync_channel(1);
    let (release, wait) = tokio::sync::oneshot::channel::<()>();
    let (completed, done) = mpsc::sync_channel(1);
    let started = Instant::now();
    std::thread::scope(|scope| {
        scope.spawn(|| {
            let exited = finish_host_stop("quit-slow-relay", Some(child), async {
                withdrawing.send(()).expect("test observes withdrawal");
                // The bound also releases this worker if an assertion fails.
                let _ = tokio::time::timeout(Duration::from_secs(10), wait).await;
            });
            completed.send(exited).expect("test observes completion");
        });
        entered
            .recv_timeout(Duration::from_secs(5))
            .expect("withdrawal started");
        let deadline = Instant::now() + Duration::from_secs(5);
        while child.running() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(!child.running(), "a pending relay must not postpone local process cleanup");
        eprintln!(
            "owned process stopped in {:?} while relay cleanup remained pending",
            started.elapsed()
        );
        assert!(done.try_recv().is_err(), "host cleanup still owns its pending withdrawal");
        release.send(()).expect("finish withdrawing");
        assert!(done
            .recv_timeout(Duration::from_secs(5))
            .expect("cleanup finished"));
    });
}

#[test]
fn concurrent_withdrawal_does_not_forget_a_process_that_failed_to_stop() {
    runtime::init(std::env::temp_dir()).expect("runtime");
    let (_process, child) = sleeper();
    refuse_stops(child, true);
    assert!(!finish_host_stop("quit-retained-child", Some(child), async {}));
    assert!(NATIVE
        .owners(|name| name == "quit-retained-child")
        .contains(&"quit-retained-child".into()));
    assert!(child.running(), "failed stop remains observable");
    refuse_stops(child, false);
    settle_retained("quit-retained-child").expect("retry stops the same owned process");
    assert!(!child.running(), "retry confirms process exit");
}

#[test]
fn desktop_quit_hands_over_ownership_only_after_cleanup() {
    use crate::engine::host_owner::{self, OwnerLock};

    // Quit closes process-global admission permanently. Run the complete
    // lifecycle in its own process, with a private hosting directory.
    const ISOLATED: &str = "POCOX_QUIT_OWNER_FIXTURE";
    if std::env::var_os(ISOLATED).is_none() {
        let output = std::process::Command::new(std::env::current_exe().expect("test executable"))
            .args([
                "--exact",
                "engine::serve::lifecycle::tests::desktop_quit_hands_over_ownership_only_after_cleanup",
                "--nocapture",
            ])
            .env(ISOLATED, "1")
            .output()
            .expect("isolated quit fixture");
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            output.status.success() && stdout.contains("1 passed"),
            "{stdout}\n{}",
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }
    let state = tempfile::tempdir().expect("state");
    let profiles = state.path().join("hosting");
    runtime::init(state.path().to_path_buf()).expect("runtime");
    runtime::configure_host(runtime::HostContext {
        device: "quit-fixture".into(),
        profiles: profiles.clone(),
        transport: None,
    })
    .expect("private hosting state");
    host_owner::claim_desktop();
    host_owner::require().expect("first app owns hosting");

    let (_process, child) = sleeper();
    NATIVE.hold("quit-owned-child", child);
    refuse_stops(child, true);
    assert!(serve_stop_all().is_err(), "quit cannot finish while its child lives");
    assert!(OwnerLock::try_acquire(&profiles).is_err(), "failed quit keeps ownership");
    host_owner::require().expect("the first app still owns its cleanup");

    refuse_stops(child, false);
    let record = profiles.join("quit-write.json");
    let write = host_owner::write_guard().expect("an admitted hosting-state write");
    std::thread::scope(|scope| {
        let (finished, done) = mpsc::channel();
        scope.spawn(move || finished.send(serve_stop_all()).expect("report quit"));
        let deadline = Instant::now() + Duration::from_secs(5);
        while child.running() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(!child.running(), "retry stops the owned child");
        assert!(done.try_recv().is_err(), "ownership waits for an admitted write");
        // Atomic writes inside a guarded transaction must not deadlock.
        host_profiles::files::write_private(&record, b"saved").expect("finish the write");
        drop(write);
        done.recv_timeout(Duration::from_secs(5))
            .expect("quit returned")
            .expect("retry finishes cleanup");
    });
    let replacement = OwnerLock::try_acquire(&profiles)
        .expect("a reopened app can own hosting before the old GUI finishes exiting");
    assert!(host_owner::require().is_err(), "the retired app cannot host again");
    host_owner::claim_desktop();
    assert!(host_owner::require().is_err(), "initialization cannot reopen a retired owner");
    assert!(host_profiles::files::write_private(&record, b"stale").is_err());
    assert_eq!(std::fs::read(&record).expect("saved record"), b"saved");
    serve_stop_all().expect("repeated quit is harmless");
    assert!(
        OwnerLock::try_acquire(&profiles).is_err(),
        "the old app never releases its replacement's lock"
    );
    drop(replacement);
}
