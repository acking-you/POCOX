use super::*;

#[test]
fn startup_failure_error_carries_log_tail_and_port_hint() {
    let failure = StartupFailure {
        rpc_error: None,
        process_exited: true,
        port_in_use: true,
        listen: "ws://127.0.0.1:18080".to_string(),
        port: Some(18080),
        log_file: std::path::PathBuf::from("codex-app-server.log"),
        log_tail: vec!["Error: Address already in use (os error 10048)".to_string()],
    };
    let msg = startup_failure_error(failure).to_string();
    assert!(msg.contains("exited during startup"));
    assert!(msg.contains("codex-app-server.log"));
    assert!(msg.contains("os error 10048"));
    assert!(
        msg.contains("port 18081, or 0 to pick a free port automatically"),
        "should suggest the next port or an automatic one: {msg}"
    );
}

#[test]
fn host_log_cap_triggers_just_past_the_threshold() {
    assert!(!over_log_cap(0));
    assert!(!over_log_cap(MAX_HOST_LOG_BYTES), "at the cap is still fine");
    assert!(over_log_cap(MAX_HOST_LOG_BYTES + 1), "one byte over trips it");
    // The threshold itself is a size rather than a time window on purpose:
    // the burst that prompted this peaked at 72 MB/min, so "keep the last
    // six hours" would permit ~25 GB. Asserting the constant's value here
    // would be a tautology (clippy rightly flags it) — the guard that keeps
    // it honest is that this cap is measured in bytes at all.
}

#[test]
fn truncating_a_live_host_log_frees_it_in_place() {
    let dir = std::env::temp_dir().join(format!("pcx-logcap-{}", std::process::id()));
    // This test can run before every other runtime-using test. Initialize
    // explicitly instead of depending on the test runner's random order.
    runtime::init(std::env::temp_dir()).expect("init runtime");
    std::fs::create_dir_all(&dir).expect("tmp dir");
    let log = dir.join("codex-default.log");
    std::fs::write(&log, vec![b'x'; 1024]).expect("write");

    // Hold the file open the way the spawned child does, so this exercises
    // the case that rules out `remove_file`.
    let writer = std::fs::OpenOptions::new()
        .append(true)
        .open(&log)
        .expect("open writer");

    assert!(runtime::runtime().block_on(truncate_host_log(&log)));
    assert_eq!(std::fs::metadata(&log).expect("meta").len(), 0, "space is freed now");

    // The still-open writer keeps working, and its next append lands at 0 —
    // which the tailer's `len < pos` branch resyncs to.
    use std::io::Write as _;
    let mut writer = writer;
    writer.write_all(b"after\n").expect("append after truncate");
    writer.flush().expect("flush");
    assert_eq!(std::fs::read(&log).expect("read"), b"after\n");

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn built_in_engine_is_rejected_before_loading_configuration() {
    let err = serve_start(0, None, None, None, true).expect_err("built-in unavailable");
    assert!(err
        .to_string()
        .contains("built-in engine is not implemented"));
}

#[test]
fn self_host_start_is_not_gated_on_an_account() {
    // A support dir of its own holding only a self-host configuration
    // (relay + key, no account), independent of the process-global
    // support dir and of what other tests left there. The start must get
    // past configuration to binary resolution (and fail there, before
    // spawning or touching any relay) instead of demanding a GitHub
    // sign-in as it once did. This proves only the gate; hosting two
    // instances side by side needs a real codex and is not exercised.
    use pocox_core::config::Config;

    use crate::engine::config::save_config;

    let support = tempfile::tempdir().expect("support dir");
    let mut config = Config::default();
    config.set_relay("relay.invalid:7666");
    config.set_relay_key("k".repeat(32));
    save_config(support.path(), &config).expect("save self-host config");
    let saved = std::fs::read(support.path().join("config.toml")).ok();
    // Inside the support dir, which exists, so nothing outside is named.
    let missing = support.path().join("no-codex-here").join("codex");
    // The saved host configuration is read from the fixture too, never
    // from this machine's state directory.
    let profiles = support.path().join("hosting");
    let err = serve_start_in(support.path(), &profiles, CodexStart {
        port: 0,
        binary: Binary::Requested(Some(missing.display().to_string())),
        name: "self-host-gate".into(),
        proxy: None,
        provider: None,
    })
    .expect_err("no codex at that path");
    let msg = err.to_string();
    assert!(msg.contains("could not find the codex binary"), "{msg}");
    assert!(!msg.contains("sign in"), "{msg}");
    assert!(!hosts_locked().contains_key("self-host-gate"), "nothing was recorded");
    assert!(!profiles.exists(), "resolving the saved configuration created nothing");
    assert_eq!(
        std::fs::read(support.path().join("config.toml")).ok(),
        saved,
        "a missing binary is not saved as the codex path"
    );
}

#[test]
fn hosts_locked_recovers_a_poisoned_lock() {
    // Poison the process-global host mutex the way a real panic-while-holding
    // would: a thread panics with the guard held. (Quiet the hook so the
    // intentional panic doesn't spam the test log.)
    let prev = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let _ = std::thread::spawn(|| {
        let _guard = hosts().lock().expect("acquire before poisoning");
        panic!("intentional: poison the hosts mutex");
    })
    .join();
    std::panic::set_hook(prev);

    // The raw lock is now poisoned...
    assert!(hosts().lock().is_err(), "the mutex should be poisoned after the panic");
    // ...but the recovering accessor still hands back a usable guard instead
    // of panicking (which, cascading across every serve/status/stop call,
    // is what would take hosting down after one unlucky panic).
    let mut guard = hosts_locked();
    let before = guard.len();
    // It's a normal, mutable map — prove it's fully usable post-recovery.
    guard.retain(|_, _| true);
    assert_eq!(guard.len(), before);
}

#[test]
fn a_broken_saved_configuration_fails_the_start_before_any_spawn() {
    let support = tempfile::tempdir().expect("support dir");
    let profiles = support.path().join("hosting");
    std::fs::create_dir_all(&profiles).expect("dir");
    let broken = serde_json::json!({ "version": 2, "hosts": { "broken-host": {
        "source": "mystery", "revision": 1
    } } });
    std::fs::write(profiles.join("profiles.json"), broken.to_string()).expect("write");
    let err = serve_start_in(support.path(), &profiles, CodexStart {
        port: 0,
        binary: Binary::Requested(None),
        name: "broken-host".into(),
        proxy: None,
        provider: None,
    })
    .expect_err("never launched with another provider");
    assert!(err.to_string().contains("invalid"), "{err}");
    assert!(!hosts_locked().contains_key("broken-host"));
}

/// A recorded host with no process behind it: its tasks idle until aborted,
/// and the closed discard port stands for its listener.
fn fake_host(name: &str, incarnation: &str, adopted: bool) -> LocalServe {
    runtime::init(std::env::temp_dir()).expect("init runtime");
    let idle = || runtime::runtime().spawn(std::future::pending::<()>());
    let local: SocketAddr = "127.0.0.1:9".parse().expect("addr");
    LocalServe {
        device: "test-device".into(),
        name: name.into(),
        app_key: format!("pcx:test-device:app:{name}"),
        app_local: local,
        pid: 0,
        child: None,
        app_register: None,
        watchdog: idle(),
        log_tail: None,
        api_key: format!("pcx:test-device:api:{name}"),
        api_local: local,
        api_proxy: idle(),
        api_register: None,
        meta_key: format!("pcx:test-device:meta:{name}"),
        meta_local: local,
        meta_svc: idle(),
        meta_register: None,
        codex_binary: None,
        binary_path: None,
        incarnation: incarnation.into(),
        adopted,
        proxy: None,
        config: host_profiles::Resolved::inherited(),
    }
}

fn finishes(handle: &tokio::task::AbortHandle) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !handle.is_finished() {
        if Instant::now() > deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    true
}

#[test]
fn a_host_committed_after_the_quit_began_is_torn_down_not_recorded() {
    use std::sync::atomic::AtomicBool;

    // A start paused between its spawn and its commit while the quit runs:
    // when it resumes, the fence is closed.
    let closed = AtomicBool::new(true);
    let host = fake_host("quit-fence-late", "inc-1", true);
    let watchdog = host.watchdog.abort_handle();
    let api = host.api_proxy.abort_handle();
    let err = lifecycle::commit_host_unless(&closed, host).expect_err("quitting");
    assert!(err.to_string().contains("quitting"), "{err}");
    assert!(!hosts_locked().contains_key("quit-fence-late"), "never recorded");
    assert!(finishes(&watchdog) && finishes(&api), "its tasks were stopped");

    // Before the quit, the same commit records the host.
    let open = AtomicBool::new(false);
    lifecycle::commit_host_unless(&open, fake_host("quit-fence-early", "inc-1", true))
        .expect("recorded");
    let recorded = hosts_locked().remove("quit-fence-early").expect("recorded");
    stop_host_tasks(recorded);
}

/// The app's own app-server exited and another `codex app-server` took its
/// port (the very process the former by-URL lookup would have signalled):
/// teardown, an adopted host's included, signals only the exact child it
/// started, so the replacement keeps running.
#[cfg(unix)]
#[test]
fn teardown_signals_only_its_exact_child_never_a_replacement_on_its_port() {
    use crate::engine::owned_child::tests::Fixture;
    let dir = tempfile::tempdir().expect("tempdir");
    let codex = dir.path().join("codex");
    std::fs::copy("/bin/bash", &codex).expect("a process named codex");
    let mut sleeper = std::process::Command::new("/bin/sh");
    sleeper.args(["-c", "exec sleep 60"]);
    let (mut original, owned) = Fixture::start(&mut sleeper);
    original.kill().expect("kill");
    original.wait().expect("reap");
    assert!(!owned.running(), "the original exited");

    let url = "ws://127.0.0.1:9";
    let mut replacing = std::process::Command::new(&codex);
    replacing.args(["-c", "while :; do sleep 1; done", "app-server", "--listen", url]);
    let (mut replacement, other) = Fixture::start(&mut replacing);
    let deadline = Instant::now() + Duration::from_secs(5);
    while pocox_core::process::find_codex_app_server(url) != Some(replacement.id()) {
        assert!(Instant::now() < deadline, "the replacement serves the host's URL");
        std::thread::sleep(Duration::from_millis(20));
    }

    let owned_host = LocalServe {
        child: Some(owned),
        ..fake_host("replaced-port", "i", false)
    };
    assert!(stop_host_tasks(owned_host), "its own child is gone");
    let adopted_host = LocalServe {
        child: Some(other),
        ..fake_host("adopted-port", "i", true)
    };
    assert!(stop_host_tasks(adopted_host), "an adopted host signals nothing");
    assert!(other.running(), "the replacement was never signalled");
    replacement.kill().expect("kill");
    replacement.wait().expect("reap");
}

#[test]
fn a_watchdog_restart_is_fenced_by_the_lease_and_its_incarnation() {
    let name = "watchdog-fence";
    hosts_locked().insert(name.into(), fake_host(name, "inc-1", false));
    let guard = codex::restart_guard(name, "inc-1", Duration::ZERO).expect("owned and free");
    drop(guard);
    // A stop (or apply, or quit) holding the instance wins; the restart
    // skips this round instead of racing it.
    let stop = host_lease::acquire(name, Op::Stop).expect("free");
    assert!(codex::restart_guard(name, "inc-1", Duration::from_millis(20)).is_none());
    // And while the restart holds the lease, a stop waits for it.
    drop(stop);
    let restarting = codex::restart_guard(name, "inc-1", Duration::ZERO).expect("again");
    assert!(host_lease::acquire_within(name, Op::Stop, Duration::from_millis(20)).is_err());
    drop(restarting);
    // A replaced or stopped host is never restarted by an old watchdog.
    assert!(codex::restart_guard(name, "inc-0", Duration::ZERO).is_none());
    let ls = hosts_locked().remove(name).expect("recorded");
    assert!(codex::restart_guard(name, "inc-1", Duration::ZERO).is_none());
    // Tear the fixture down without signalling anything.
    let adopted = LocalServe {
        adopted: true,
        ..ls
    };
    stop_host_tasks(adopted);
}

#[test]
fn a_stop_by_another_spelling_stops_the_recorded_host() {
    hosts_locked().insert("Spelled Host".into(), fake_host("Spelled Host", "inc-1", true));
    serve_stop("spelled-host").expect("stop");
    assert!(!hosts_locked().contains_key("Spelled Host"), "the recorded key was resolved");
    assert_eq!(lifecycle::table_name("spelled-host"), None);
}

#[test]
fn a_keyed_hosts_viewer_shows_only_notices_and_others_their_output() {
    use pocox_core::redact::{ADDR_IN_USE, OUTPUT_WITHHELD};
    let redactor = host_profiles::Redactor::new(Some(&pocox_core::provider::Secret::new(
        "sk-dummy-tail-0123",
    )));
    for line in
        [&b"auth: Bearer sk-dummy-tail-0123\n"[..], b"key=sk-dummy-tail-0123%0A\n", b"ready\n"]
    {
        assert_eq!(codex::shown_line(line, &redactor), None, "raw output is never shown");
    }
    for notice in [OUTPUT_WITHHELD, ADDR_IN_USE] {
        assert_eq!(codex::shown_line(notice.as_bytes(), &redactor).as_deref(), Some(notice));
    }
    let plain = host_profiles::Redactor::new(None);
    assert_eq!(codex::shown_line(b"  \n", &plain), None);
    assert_eq!(codex::shown_line(b"ready\n", &plain).as_deref(), Some("ready"));
    let notice = codex::withheld_partial(70_000);
    assert!(notice.contains("70000") && !notice.contains("sk-"));
}

/// The tailer's state across separate reads of an appended log, the dummy
/// key split at every position over reads and lines and past an overflow:
/// for a keyed host nothing but the notices is shown; without a key the
/// output is shown as written and an over-long line is withheld whole.
#[test]
fn the_tailer_of_a_keyed_host_shows_nothing_of_its_raw_output() {
    use pocox_core::redact::OUTPUT_WITHHELD;
    const KEY: &str = "sk-ABC0123";
    let redactor = host_profiles::Redactor::new(Some(&pocox_core::provider::Secret::new(KEY)));
    for i in 0..=KEY.len() {
        let (a, b) = KEY.split_at(i);
        let mut tail = codex::TailState::new(redactor.clone());
        let mut shown = Vec::new();
        let text = format!("{OUTPUT_WITHHELD}\nauth {a}\n{b} ok\n");
        for read in text.as_bytes().chunks(3) {
            shown.extend(tail.read(read));
        }
        let mut long = vec![b'x'; 64 * 1024];
        long.extend_from_slice(a.as_bytes());
        shown.extend(tail.read(&long));
        shown.extend(tail.read(format!("{b}\n{b}\n").as_bytes()));
        assert_eq!(shown, [OUTPUT_WITHHELD], "split at {i}");
    }
    let mut plain = codex::TailState::new(host_profiles::Redactor::new(None));
    let mut shown = Vec::new();
    for read in [&b"booting\nauth "[..], b"ok\n"] {
        shown.extend(plain.read(read));
    }
    shown.extend(plain.read(&[b'y'; 64 * 1024 + 1]));
    shown.extend(plain.read(b"z\nready\n"));
    assert_eq!(shown, [
        "booting".to_string(),
        "auth ok".to_string(),
        codex::withheld_partial(64 * 1024 + 1),
        "ready".to_string()
    ]);
}

/// The status row of `name`, if any (Codex rows only: no relay recovery).
fn row(name: &str) -> Option<ServeStatus> {
    codex_status().into_iter().find(|s| s.name == name)
}

/// While a codex kept for `name` may run, the name is listed with the
/// reason (so its Stop stays reachable) and is not free for an ACP host.
fn held_back(name: &str) {
    let row = row(name).expect("still listed");
    assert_eq!(row.agent_error.as_deref(), Some(lifecycle::NOT_EXITED));
    assert!(!row.alive);
    assert_eq!(row.provider, "codex");
    assert!(is_hosting_codex(name));
    let refused = super::super::hosting::reserve(name)
        .err()
        .expect("not free");
    assert!(refused.to_string().contains("Codex"), "{refused}");
}

/// The name is free again once its codex exited: no row, and an ACP host
/// may take it.
fn released(name: &str) {
    assert!(row(name).is_none(), "no longer listed");
    assert!(!is_hosting_codex(name));
    drop(super::super::hosting::reserve(name).expect("free"));
}

/// A host whose codex does not exit on stop stays owned: every stop of
/// the name fails and tries it again, it stays listed with the reason, no
/// ACP host can take the name and nothing launches beside it; once it
/// exits the next stop succeeds and the name is free.
#[cfg(unix)]
#[test]
fn a_failed_stop_keeps_the_codex_owned_until_it_exits() {
    use crate::engine::owned_child::tests::{refuse_stops, sleeper};
    let name = "retained-stop";
    let (mut process, child) = sleeper();
    refuse_stops(child, true);
    hosts_locked().insert(name.into(), LocalServe {
        child: Some(child),
        ..fake_host(name, "inc-1", false)
    });
    let first = serve_stop(name).expect_err("its codex did not exit");
    assert!(first.to_string().contains("did not exit"), "{first}");
    assert!(!hosts_locked().contains_key(name), "the record is gone");
    assert_eq!(NATIVE.owners(|o| o == name), [name], "the codex is still owned");
    held_back(name);
    let again = serve_stop(name).expect_err("tried again, still running");
    assert!(again.to_string().contains("did not exit"), "{again}");
    held_back(name);
    assert!(lifecycle::settle_retained(name).is_err(), "nothing launches beside it");
    assert!(child.running(), "a refused stop signalled nothing");
    refuse_stops(child, false);
    serve_stop(name).expect("it exited");
    assert!(!child.running() && NATIVE.owners(|o| o == name).is_empty());
    released(name);
    let _ = process.wait();
}

/// A watchdog restart whose old codex did not exit keeps the host record
/// and lists the reason on it, until a stop sees it exit.
#[cfg(unix)]
#[test]
fn a_host_whose_old_codex_was_kept_lists_the_reason_on_its_own_row() {
    use crate::engine::owned_child::tests::{refuse_stops, sleeper};
    let name = "retained-restart";
    let (mut process, child) = sleeper();
    refuse_stops(child, true);
    hosts_locked().insert(name.into(), LocalServe {
        child: Some(child),
        ..fake_host(name, "inc-1", false)
    });
    // What `restart_codex` does with the unresponsive codex.
    assert!(!NATIVE.stop(name, child, Duration::ZERO));
    assert!(hosts_locked().contains_key(name), "the host is still recorded");
    held_back(name);
    assert_eq!(codex_status().iter().filter(|s| s.name == name).count(), 1, "one row");
    refuse_stops(child, false);
    serve_stop(name).expect("stopped");
    released(name);
    let _ = process.wait();
}

/// A start committed after the quit began tears its host down; a codex that
/// does not exit then is kept for the quit's retry, never forgotten.
#[cfg(unix)]
#[test]
fn a_late_commit_whose_codex_does_not_exit_stays_owned() {
    use std::sync::atomic::AtomicBool;

    use crate::engine::owned_child::tests::{refuse_stops, sleeper};
    let name = "retained-late-commit";
    let (mut process, child) = sleeper();
    refuse_stops(child, true);
    let host = LocalServe {
        child: Some(child),
        ..fake_host(name, "inc-1", false)
    };
    let err = lifecycle::commit_host_unless(&AtomicBool::new(true), host).expect_err("quitting");
    assert!(err.to_string().contains("did not exit"), "{err}");
    assert!(!hosts_locked().contains_key(name));
    assert_eq!(NATIVE.owners(|o| o == name), [name]);
    held_back(name);
    // What a quit's retry does for it: fails while it runs, then succeeds.
    assert_eq!(NATIVE.settle(|o| o == name, Duration::ZERO), [name]);
    refuse_stops(child, false);
    assert!(NATIVE.settle(|o| o == name, EXIT_WAIT).is_empty());
    released(name);
    let _ = process.wait();
}

/// A start whose codex was kept after a failed launch (readiness, route
/// refusal or bring-up: each stops it through the ledger) has no record,
/// yet its name is listed and held back until a stop of the name sees it
/// exit; that stop is the retry.
#[cfg(unix)]
#[test]
fn a_failed_start_whose_codex_was_kept_is_listed_and_stopped_by_name() {
    use crate::engine::owned_child::tests::{refuse_stops, sleeper};
    let name = "retained-start";
    let (mut process, child) = sleeper();
    refuse_stops(child, true);
    assert!(!NATIVE.stop(name, child, Duration::ZERO), "the start's cleanup failed");
    held_back(name);
    serve_stop(name).expect_err("still running");
    held_back(name);
    refuse_stops(child, false);
    serve_stop(name).expect("its stop is the retry");
    released(name);
    let _ = process.wait();
}
