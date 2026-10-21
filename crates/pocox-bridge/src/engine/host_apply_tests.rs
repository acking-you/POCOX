use std::{cell::RefCell, time::Duration};

use pocox_core::provider::{ApiProtocol, ProviderEndpoint, Secret};

use super::*;
use crate::engine::host_profiles::{Resolved, Source};

fn resolved(revision: u64) -> Resolved {
    Resolved {
        revision,
        ..Resolved::inherited()
    }
}

fn keyed(revision: u64, key: &str) -> Resolved {
    Resolved {
        claude_env: Default::default(),
        source: Source::Custom,
        endpoint: Some(ProviderEndpoint {
            protocol: ApiProtocol::Responses,
            base_url: "https://gw.example.com".into(),
            key: Some(Secret::new(key)),
            model: None,
        }),
        authority: Some("a".into()),
        runtime: None,
        revision,
    }
}

/// The steps an apply took, in order.
#[derive(Default)]
struct Log(RefCell<Vec<&'static str>>);

impl Log {
    fn push(&self, step: &'static str) {
        self.0.borrow_mut().push(step);
    }

    fn steps(&self) -> Vec<&'static str> {
        self.0.borrow().clone()
    }
}

fn expected(incarnation: &str, revision: u64) -> Expected {
    Expected {
        incarnation: Some(incarnation.into()),
        revision: Some(revision),
    }
}

#[test]
fn a_successful_apply_prepares_before_it_stops_and_restores_nothing() {
    let lease = host_lease::acquire("apply-test-ok", Op::Apply).expect("lease");
    let log = Log::default();
    let (desired, previous) = (resolved(4), resolved(3));
    let current = Current {
        incarnation: "run-1",
        desired: &desired,
        previous: &previous,
    };
    let report = orchestrate(
        &lease,
        &current,
        &expected("run-1", 4),
        || {
            log.push("prepare");
            Ok("next")
        },
        || {
            log.push("stop");
            Ok(())
        },
        |next| {
            assert_eq!(next, "next", "the prepared launch is the one started");
            log.push("start");
            Ok(())
        },
        |()| panic!("no restore"),
    )
    .expect("applied");
    assert_eq!(log.steps(), ["prepare", "stop", "start"]);
    assert!(report.applied && !report.restored_previous);
    assert_eq!(report.revision, Some(4));
    assert!(report.error.is_none() && report.restore_error.is_none());
}

#[test]
fn a_replaced_host_or_a_newer_save_is_never_applied() {
    let lease = host_lease::acquire("apply-test-stale", Op::Apply).expect("lease");
    let (desired, previous) = (resolved(4), resolved(3));
    let current = Current {
        incarnation: "run-2",
        desired: &desired,
        previous: &previous,
    };
    for (seen, why) in
        [(expected("run-1", 4), "replaced"), (expected("run-2", 3), "saved configuration changed")]
    {
        let err = orchestrate(
            &lease,
            &current,
            &seen,
            || -> Result<()> { panic!("nothing is prepared") },
            || panic!("nothing is stopped"),
            |()| panic!("nothing is started"),
            |_: ()| panic!("nothing is restored"),
        )
        .expect_err("stale");
        assert!(err.to_string().contains(why), "{err}");
    }
}

#[test]
fn a_launch_that_cannot_be_prepared_interrupts_nothing() {
    let lease = host_lease::acquire("apply-test-prepare", Op::Apply).expect("lease");
    let (desired, previous) = (keyed(2, "sk-next"), resolved(1));
    let current = Current {
        incarnation: "run",
        desired: &desired,
        previous: &previous,
    };
    let err = orchestrate(
        &lease,
        &current,
        &Expected::default(),
        || -> Result<()> { Err(anyhow!("executable not found\nheader: sk-next")) },
        || panic!("the running host is never stopped"),
        |()| panic!("never started"),
        |_: ()| panic!("never restored"),
    )
    .expect_err("unprepared");
    assert!(err.to_string().contains("executable not found"));
    assert!(!err.to_string().contains("sk-next"), "the key is withheld");
}

#[test]
fn a_failed_start_restores_the_exact_previous_launch() {
    let lease = host_lease::acquire("apply-test-restore", Op::Apply).expect("lease");
    let log = Log::default();
    let (desired, previous) = (keyed(5, "sk-new"), keyed(4, "sk-old"));
    let current = Current {
        incarnation: "run",
        desired: &desired,
        previous: &previous,
    };
    let report = orchestrate(
        &lease,
        &current,
        &Expected::default(),
        || Ok(()),
        || {
            log.push("stop");
            Ok(())
        },
        |()| {
            log.push("start");
            Err(anyhow!("bind failed; child said sk-new"))
        },
        |()| {
            log.push("restore");
            Ok(previous.revision)
        },
    )
    .expect("reported");
    assert_eq!(log.steps(), ["stop", "start", "restore"]);
    assert!(!report.applied && report.restored_previous);
    assert_eq!(report.revision, Some(4), "the previous revision runs again");
    let error = report.error.expect("error");
    assert!(error.contains("bind failed") || error.contains("withheld"));
    assert!(!error.contains("sk-new"));
}

#[test]
fn a_restore_launches_what_the_stop_captured_and_never_prepares_again() {
    let lease = host_lease::acquire("apply-test-captured", Op::Apply).expect("lease");
    let prepared = std::cell::Cell::new(0);
    let (desired, previous) = (resolved(3), resolved(2));
    let current = Current {
        incarnation: "run",
        desired: &desired,
        previous: &previous,
    };
    let report = orchestrate(
        &lease,
        &current,
        &Expected::default(),
        || {
            prepared.set(prepared.get() + 1);
            Ok("new launch")
        },
        // The stop hands back the exact previous launch (an executable that
        // may no longer be found by a new lookup).
        || Ok(Some("previous launch: /opt/agent-v1")),
        |next| {
            assert_eq!(next, "new launch");
            Err(anyhow!("the new agent failed"))
        },
        |captured| {
            assert_eq!(captured, Some("previous launch: /opt/agent-v1"), "exactly what ran");
            Ok(previous.revision)
        },
    )
    .expect("reported");
    assert_eq!(prepared.get(), 1, "only the new launch was prepared");
    assert!(report.restored_previous);
    assert_eq!(report.revision, Some(2));
}

#[test]
fn a_failed_restore_is_reported_not_hidden() {
    let lease = host_lease::acquire("apply-test-restore-fail", Op::Apply).expect("lease");
    let (desired, previous) = (resolved(2), keyed(1, "sk-old"));
    let current = Current {
        incarnation: "run",
        desired: &desired,
        previous: &previous,
    };
    let report = orchestrate(
        &lease,
        &current,
        &Expected::default(),
        || Ok(()),
        || Ok(()),
        |()| Err(anyhow!("bind failed")),
        |()| Err(anyhow!("gone: sk-old")),
    )
    .expect("reported");
    assert!(!report.applied && !report.restored_previous);
    assert_eq!(report.revision, None, "the host is stopped");
    let restore_error = report.restore_error.expect("restore error");
    assert!(!restore_error.contains("sk-old"), "the old key is withheld too");
}

#[test]
fn the_lease_is_held_through_every_step() {
    let lease = host_lease::acquire("apply-test-lease", Op::Apply).expect("lease");
    let (desired, previous) = (resolved(2), resolved(1));
    let current = Current {
        incarnation: "run",
        desired: &desired,
        previous: &previous,
    };
    let excluded = || {
        assert!(is_applying("apply-test-lease"));
        // A start or stop from another thread waits for the apply.
        let other = std::thread::spawn(|| {
            host_lease::acquire_within("apply-test-lease", Op::Start, Duration::from_millis(20))
                .is_err()
        });
        assert!(other.join().expect("other"), "no start slips in");
    };
    orchestrate(
        &lease,
        &current,
        &Expected::default(),
        || {
            excluded();
            Ok(())
        },
        || {
            excluded();
            Ok(())
        },
        |()| {
            excluded();
            Err(anyhow!("fail"))
        },
        |()| {
            excluded();
            Ok(1)
        },
    )
    .expect("reported");
    drop(lease);
    assert!(!is_applying("apply-test-lease"));
}

/// The running host's codex did not exit: nothing is started and nothing
/// is restored beside it; the failure says so (without the key).
#[test]
fn a_failed_stop_starts_nothing() {
    let lease = host_lease::acquire("apply-test-stop-fails", Op::Apply).expect("lease");
    let log = Log::default();
    let (desired, previous) = (resolved(2), keyed(1, "sk-old"));
    let current = Current {
        incarnation: "run",
        desired: &desired,
        previous: &previous,
    };
    let err = orchestrate(
        &lease,
        &current,
        &Expected::default(),
        || {
            log.push("prepare");
            Ok(())
        },
        || -> Result<()> {
            log.push("stop");
            Err(anyhow!("an earlier codex did not exit\nchild said sk-old"))
        },
        |()| panic!("nothing is started after a failed stop"),
        |()| panic!("nothing is restored beside a running codex"),
    )
    .expect_err("the stop failed");
    assert_eq!(log.steps(), ["prepare", "stop"]);
    let message = err.to_string();
    assert!(message.contains("did not stop") && message.contains("did not exit"), "{message}");
    assert!(!message.contains("sk-old"), "the key is withheld");
}

#[test]
fn applying_a_host_that_is_not_running_changes_nothing() {
    // Refused from the in-process host tables, before anything is stopped.
    let err = apply("apply-not-running-host", &Expected::default()).expect_err("not running");
    assert!(err.to_string().contains("is not hosting"), "{err}");
    assert!(!is_applying("apply-not-running-host"));
    assert!(!serve::is_hosting_codex("apply-not-running-host"));
    assert!(!serve_acp::is_hosting("apply-not-running-host"));
}

#[test]
fn an_unsaved_runtime_restarts_with_the_running_one() {
    let running = serve::CodexRelaunch {
        name: "h".into(),
        port: 4501,
        binary: Some("/opt/codex".into()),
        proxy: Some("http://127.0.0.1:7890".into()),
        provider: resolved(1),
        incarnation: "run".into(),
        adopted: false,
    };
    let dir = tempfile::tempdir().expect("support");
    let (binary, port, proxy) = codex_runtime(dir.path(), &running, None).expect("runtime");
    assert_eq!(binary, std::path::PathBuf::from("/opt/codex"));
    assert_eq!(port, 4501);
    assert_eq!(proxy, running.proxy);
    let acp = Runtime::Acp(pocox_host_svc::acp::AgentSpec {
        profile_id: "x".into(),
        display_name: "X".into(),
        program: "x".into(),
        args: Vec::new(),
    });
    assert!(codex_runtime(dir.path(), &running, Some(&acp)).is_err());
    let missing = Runtime::Codex {
        binary: Some(dir.path().join("no-codex").display().to_string()),
        port: 0,
        proxy: None,
    };
    let err = codex_runtime(dir.path(), &running, Some(&missing)).expect_err("checked first");
    assert!(err.to_string().contains("could not find the codex binary"), "{err}");
}
