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
