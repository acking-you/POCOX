use super::*;

#[test]
fn unknown_hosts_are_not_hosting() {
    assert!(!is_hosting("no-such-acp-host"));
    assert!(local_endpoints("pcx:dev:acp:no-such").is_none());
    assert!(deregister("no-such-acp-host", "acp").is_err());
    assert!(restart("no-such-acp-host").is_err());
}

/// A start paused just before entering the host table while the app
/// quits: the quit sees (and stops) its host, and the start may not
/// enter the table afterwards. Nothing starts once the barrier closed.
#[test]
fn a_quit_sees_every_start_in_flight_and_none_enters_afterwards() {
    use std::sync::Barrier;

    let barrier = Arc::new(Mutex::new(Owners::<&'static str>::default()));
    let table = Arc::new(Mutex::new(Vec::<&'static str>::new()));
    let paused = Arc::new(Barrier::new(2));
    let resume = Arc::new(Barrier::new(2));
    let starter = std::thread::spawn({
        let (barrier, table) = (barrier.clone(), table.clone());
        let (paused, resume) = (paused.clone(), resume.clone());
        move || {
            let id = barrier
                .lock()
                .expect("lock")
                .begin("agent-1")
                .expect("open");
            // Launched and published; about to enter the table.
            paused.wait();
            resume.wait();
            let mut barrier = barrier.lock().expect("lock");
            if barrier.commit(id) {
                table.lock().expect("table").push("agent-1");
                true
            } else {
                false
            }
        }
    });
    paused.wait();
    let to_stop = barrier.lock().expect("lock").close();
    assert_eq!(to_stop, vec!["agent-1"], "the quit stops the start in flight");
    resume.wait();
    assert!(!starter.join().expect("starter"), "the start is refused");
    assert!(table.lock().expect("table").is_empty(), "nothing entered after the quit");
    assert_eq!(barrier.lock().expect("lock").begin("agent-2"), None, "no new start");
    // A refused start stays owned (a later quit still sees it) until it
    // was cleaned up.
    assert_eq!(barrier.lock().expect("lock").close(), vec!["agent-1"]);
    barrier.lock().expect("lock").cleaned(1);
    assert!(barrier.lock().expect("lock").close().is_empty());
}

// ---- The production table, with agents that never launch -----------

fn fixture_context(relay: &str) -> transport::Context {
    transport::Context::of(&fixture_transport(relay))
}

fn fixture_transport(relay: &str) -> transport::Transport {
    transport::Transport {
        session: pocket_codex_pb::RelaySession::for_test(relay),
        namespace: None,
    }
}

/// A hosted entry whose agent was created (and is owned) but never
/// launched: stopping it touches no process.
fn fixture_host(name: &str, context: transport::Context) -> AcpServe {
    let rt = runtime::runtime();
    let _runtime = rt.enter();
    let program = PathBuf::from("/nonexistent/fixture-agent");
    let host = AgentHost::create(HostOptions {
        spec: AgentSpec {
            profile_id: "fixture".into(),
            display_name: "Fixture".into(),
            program: program.display().to_string(),
            args: Vec::new(),
        },
        program: program.clone(),
        path: None,
        env: Vec::new(),
        store: SessionStore::memory(SourceId::with_key("fixture", &program, &[])),
    });
    let id = owners().begin(host.clone()).expect("the barrier is open");
    assert!(owners().commit(id));
    AcpServe {
        device: "dev".into(),
        name: name.into(),
        key: ServiceId::new("dev", ServiceKind::Acp, name).key(),
        meta_key: ServiceId::new("dev", ServiceKind::Meta, name).key(),
        gateway_local: "127.0.0.1:9".parse().expect("addr"),
        meta_local: "127.0.0.1:9".parse().expect("addr"),
        gateway_task: rt.spawn(std::future::pending::<()>()),
        meta_task: rt.spawn(std::future::pending::<()>()),
        register: Slot::default(),
        meta_register: Slot::default(),
        host,
        program: program.display().to_string(),
        context,
        config: None,
        launch: None,
        _owner: Owner(id),
    }
}

/// A retired host hands back the launch it ran, unchanged, and is stopped:
/// an apply's rollback relaunches that, never a fresh lookup.
#[test]
fn retiring_a_host_hands_back_its_exact_launch() {
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("init");
    let mut serving = fixture_host("retire-capture-test", fixture_context("relay.test:1"));
    let agent = serving.host.clone();
    let program = PathBuf::from("/opt/fixture/agent-v1");
    let mut provider_launch = acp::provider::AcpProviderLaunch::default();
    provider_launch
        .env
        .push(("FIXTURE_ROUTE".into(), "captured".into()));
    serving.launch = Some(Captured {
        program: program.clone(),
        claude: None,
        provider_launch,
        source: SourceId::with_key("fixture", &program, &[]),
        state: PathBuf::from("/nonexistent/state"),
    });
    serving.config = Some(host_profiles::Resolved {
        revision: 7,
        ..host_profiles::Resolved::inherited()
    });
    hosts().insert("retire-capture-test".into(), serving);
    let previous = retire("retire-capture-test").expect("captured");
    assert_eq!(previous.program, program, "the resolved executable, not a new lookup");
    assert_eq!(previous.spec.profile_id, "fixture");
    assert_eq!(previous.provider.revision, 7);
    assert_eq!(previous.provider_launch.env, [(
        std::ffi::OsString::from("FIXTURE_ROUTE"),
        std::ffi::OsString::from("captured")
    )]);
    assert!(!is_hosting("retire-capture-test"));
    assert_eq!(phase(&agent), "stopped");
    assert!(retire("retire-capture-test").is_none(), "nothing left to retire");
}

fn phase(host: &AgentHost) -> String {
    host.info()["phase"]["state"]
        .as_str()
        .unwrap_or_default()
        .to_string()
}

fn pause(at: &'static str) -> (Arc<std::sync::Barrier>, Arc<std::sync::Barrier>) {
    let pair = (Arc::new(std::sync::Barrier::new(2)), Arc::new(std::sync::Barrier::new(2)));
    test_pauses().insert(at, pair.clone());
    pair
}

/// Tests of the quit barrier reopen it afterwards.
fn reopen() {
    owners().closing = false;
}

/// An ordinary stop removed its host from the table and is paused
/// before it stops the agent, when the app quits: the quit must not
/// return before that agent is stopped.
#[test]
fn a_quit_waits_for_an_agent_still_being_retired() {
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("init");
    let serving = fixture_host("retire-quit-test", fixture_context("relay.test:1"));
    let agent = serving.host.clone();
    hosts().insert("retire-quit-test".into(), serving);
    let (reached, resume) = pause("retire");
    let retiring = std::thread::spawn(|| stop("retire-quit-test"));
    reached.wait();
    assert!(!is_hosting("retire-quit-test"), "out of the table, not yet cleaned up");
    assert_ne!(phase(&agent), "stopped");
    stop_all();
    assert_eq!(phase(&agent), "stopped", "the quit stopped the retiring agent");
    resume.wait();
    retiring.join().expect("retirement");
    assert!(owners().agents.is_empty(), "every owner was released after cleanup");
    reopen();
}

/// Two quits overlap: the second must not return before the agents the
/// first one drained are stopped.
#[test]
fn overlapping_quits_both_wait_for_every_agent() {
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("init");
    let serving = fixture_host("double-quit-test", fixture_context("relay.test:1"));
    let agent = serving.host.clone();
    hosts().insert("double-quit-test".into(), serving);
    let (reached, resume) = pause("quit");
    let first = std::thread::spawn(stop_all);
    reached.wait();
    assert!(!is_hosting("double-quit-test"), "the first quit drained the table");
    stop_all();
    assert_eq!(phase(&agent), "stopped", "the second quit waited for it too");
    resume.wait();
    first.join().expect("first quit");
    assert!(owners().agents.is_empty());
    reopen();
}

/// Fixture resolution in `context`'s relay, current now.
fn resolved(relay: &str) -> Result<transport::Owned> {
    Ok(transport::Owned {
        transport: fixture_transport(relay),
        epoch: transport::epoch(),
    })
}

fn revision(name: &str) -> (u64, String) {
    let hosts = hosts();
    let host = hosts.get(name).expect("hosted");
    (host.register.revision, host.host.host_id().to_string())
}

/// A publication of host A is still waiting for the relay when A is
/// stopped and B starts under the same name in another context; a
/// deregistration overlapping a publication is the same case. The late
/// result never touches the newer state.
#[test]
fn a_late_publication_never_replaces_a_newer_hosts_registration() {
    let _serial = transport::test_serial();
    runtime::init(std::env::temp_dir()).expect("init");
    let name = "publish-race-test";
    let a = fixture_host(name, fixture_context("relay-a.test:1"));
    hosts().insert(name.into(), a);
    let reached = Arc::new(std::sync::Barrier::new(2));
    let resume = Arc::new(std::sync::Barrier::new(2));
    let late = std::thread::spawn({
        let (reached, resume) = (reached.clone(), resume.clone());
        move || {
            reregister_with(
                name,
                "acp",
                || resolved("relay-a.test:1"),
                |_, _, _, _, _| {
                    reached.wait();
                    resume.wait();
                    Ok(None)
                },
            )
        }
    });
    reached.wait();
    stop(name);
    let b = fixture_host(name, fixture_context("relay-b.test:1"));
    hosts().insert(name.into(), b);
    let before = revision(name);
    resume.wait();
    late.join()
        .expect("join")
        .expect("a late result is dropped, not an error");
    assert_eq!(revision(name), before, "B's registration is untouched");

    // A publication of B itself is installed.
    reregister_with(name, "acp", || resolved("relay-b.test:1"), |_, _, _, _, _| Ok(None))
        .expect("publish");
    let installed = revision(name);
    assert_eq!(installed.0, before.0 + 1);
    // B, resolved in another context, is refused before publishing.
    assert!(reregister_with(
        name,
        "acp",
        || resolved("relay-a.test:1"),
        |_, _, _, _, _| { panic!("never published into another context") }
    )
    .is_err());

    // A deregistration while a publication is in flight wins.
    let late = std::thread::spawn({
        let (reached, resume) = (reached.clone(), resume.clone());
        move || {
            reregister_with(
                name,
                "acp",
                || resolved("relay-b.test:1"),
                |_, _, _, _, _| {
                    reached.wait();
                    resume.wait();
                    Ok(None)
                },
            )
        }
    });
    reached.wait();
    deregister(name, "acp").expect("deregister");
    let deregistered = revision(name);
    resume.wait();
    late.join().expect("join").expect("dropped");
    assert_eq!(revision(name), deregistered, "the deregistration stands");
    stop(name);
    assert!(owners().agents.is_empty());
}

#[test]
fn presets_resolve_only_existing_programs() {
    assert!(locate("/definitely/not/here/agent", Some("fixture")).is_none());
    assert!(locate("definitely-not-an-installed-agent-xyz", None).is_none());
}

#[test]
fn an_instance_provider_gets_its_own_session_source_per_authority() {
    let root = tempfile::tempdir().expect("state");
    let program = PathBuf::from("/opt/agent");
    let args = vec!["acp".to_string()];
    let plain = launch::source_of(root.path(), &program, &args, None).expect("plain");
    assert_eq!(
        plain,
        SourceId::derive(root.path(), &program, &args).expect("derive"),
        "an inherited host keeps the source it always had"
    );
    let one = launch::source_of(root.path(), &program, &args, Some("a-1")).expect("one");
    let two = launch::source_of(root.path(), &program, &args, Some("a-2")).expect("two");
    assert_ne!(one, plain);
    assert_ne!(one, two, "another account or provider never adopts these sessions");
}
