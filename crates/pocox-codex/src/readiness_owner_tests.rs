//! Readiness attribution against real sockets and processes: what answered
//! must be held by a process the launch started, whatever its arguments.

use std::{net::TcpListener, path::PathBuf};

use pocox_core::state::CodexProcessInfo;

use super::*;
use crate::process::still_owned;

fn fresh(port: u16, spawned: Option<ProcessIdentity>) -> SpawnReport {
    SpawnReport {
        info: CodexProcessInfo {
            pid: spawned.map_or(0, |s| s.pid),
            listen: format!("ws://127.0.0.1:{port}"),
            log_file: PathBuf::from("unused.log"),
            started_at: String::new(),
        },
        reused: false,
        log_offset: 0,
        listener_confirmed: true,
        spawned,
        owned: None,
    }
}

/// A child this test starts that runs but never listens; killed and reaped
/// when dropped, also when an assertion fails first.
#[cfg(unix)]
struct Unbound(std::process::Child);

#[cfg(unix)]
impl Drop for Unbound {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[cfg(unix)]
fn unbound_child() -> (Unbound, ProcessIdentity) {
    let child = Unbound(
        std::process::Command::new("/bin/sh")
            .args(["-c", "exec sleep 60"])
            .spawn()
            .expect("sh"),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(id) = ProcessIdentity::of(child.0.id()) {
            return (child, id);
        }
        assert!(Instant::now() < deadline, "the child started");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn refusal(result: Result<(), StartupFailure>) -> String {
    result.expect_err("refused").rpc_error.expect("a reason")
}

/// The finding's case: our live child does not hold the socket while this
/// test process (someone else, for that child) does. Refused, also when the
/// port wait had already named that child as the owner.
#[cfg(unix)]
#[test]
fn a_foreign_listener_beside_our_unbound_child_is_refused() {
    let foreign = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = foreign.local_addr().expect("addr").port();
    let (_child, ours) = unbound_child();
    let mut report = fresh(port, Some(ours));
    assert!(refusal(attribute(&mut report)).contains("did not start"));
    assert_eq!(report.owned, None, "nothing is recorded as this launch's");

    // An owner seen earlier that still runs is not enough.
    let mut earlier = fresh(port, Some(ours));
    earlier.owned = Some(ours);
    assert!(refusal(attribute(&mut earlier)).contains("did not start"));
    assert_eq!(earlier.owned, None);
    assert!(!still_owned(&SpawnReport {
        owned: Some(ours),
        ..fresh(port, Some(ours))
    }));

    // Nothing listening is no owner either.
    drop(foreign);
    let mut unbound = fresh(port, Some(ours));
    assert!(refusal(attribute(&mut unbound)).contains("nothing this launch started"));
}

/// The launch's own process holding the socket is the owner, and stays so
/// only while it holds it.
#[test]
fn the_process_holding_the_socket_is_the_owner() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let me = ProcessIdentity::of(std::process::id()).expect("this process runs");
    let mut report = fresh(port, Some(me));
    report.info.pid = 0;
    attribute(&mut report).expect("owned");
    assert_eq!(report.owned, Some(me));
    assert_eq!(report.info.pid, me.pid, "the recorded pid is the server's");
    assert!(still_owned(&report));
    drop(listener);
    assert!(!still_owned(&report), "the socket left the owner");
}

/// Without an identity to attribute from, or for another start time,
/// nothing can be told: refused. Adopted servers and unix sockets are
/// never this launch's claim.
#[test]
fn an_owner_that_cannot_be_told_is_refused_and_adoption_is_untouched() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let me = ProcessIdentity::of(std::process::id()).expect("this process runs");
    let stale = ProcessIdentity {
        started: me.started.wrapping_add(1),
        ..me
    };
    for spawned in [None, Some(stale)] {
        let mut report = fresh(port, spawned);
        assert!(refusal(attribute(&mut report)).contains("cannot be told"));
    }
    let mut adopted = SpawnReport {
        reused: true,
        ..fresh(port, None)
    };
    attribute(&mut adopted).expect("adopted");
    assert_eq!(adopted.owned, None);
    assert!(still_owned(&adopted));
    let unix = SpawnReport {
        info: CodexProcessInfo {
            listen: "unix:///tmp/pcx-unused.sock".into(),
            ..fresh(port, None).info
        },
        ..fresh(port, None)
    };
    assert!(still_owned(&unix));
    drop(listener);
}
