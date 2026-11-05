//! `pocox pair` and `pocox devices`, as a user runs them: the real binary on an
//! isolated home against a real backend on a real relay.
#![allow(clippy::expect_used, clippy::unwrap_used, reason = "integration-test assertions")]

use std::io::Write as _;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use pb_mapper_testkit::{Relay, TEST_ADMIN_KEY};
use pocox_auth::Auth;
use pocox_backend::pairing::{Pairing, PairingSettings, TrustedProxies};
use pocox_backend::{router, AppState, Credentials};
use pocox_pb::RelaySession;
use pocox_store::Store;
use tokio::net::TcpListener;

/// A backend for these commands to reach.
struct Lab {
    base: String,
    relay: Relay,
    /// Where the backend reaches the relay; `None` is an outage.
    relay_link: Arc<Mutex<Option<SocketAddr>>>,
    pairing: Arc<Pairing>,
    _tasks: Vec<tokio::task::JoinHandle<()>>,
    _dir: tempfile::TempDir,
}

impl Lab {
    /// The backend loses the relay until [`Self::relay_returns`].
    fn relay_goes_away(&self) {
        *self.relay_link.lock().expect("link") = None;
    }

    fn relay_returns(&self) {
        *self.relay_link.lock().expect("link") = Some(self.relay.addr());
    }
}

/// A TCP path from the backend to the relay that can be cut.
async fn relay_link(
    target: SocketAddr,
) -> (Arc<Mutex<Option<SocketAddr>>>, SocketAddr, tokio::task::JoinHandle<()>) {
    let current = Arc::new(Mutex::new(Some(target)));
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("link bind");
    let addr = listener.local_addr().expect("link addr");
    let reading = Arc::clone(&current);
    let task = tokio::spawn(async move {
        while let Ok((mut downstream, _)) = listener.accept().await {
            let Some(target) = *reading.lock().expect("link") else {
                continue;
            };
            tokio::spawn(async move {
                if let Ok(mut upstream) = tokio::net::TcpStream::connect(target).await {
                    let _ = tokio::io::copy_bidirectional(&mut downstream, &mut upstream).await;
                }
            });
        }
    });
    (current, addr, task)
}

async fn lab() -> Lab {
    lab_with_key_life(Duration::from_secs(900)).await
}

async fn lab_with_key_life(single_key_ttl: Duration) -> Lab {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let relay = Relay::start("pocox-cli-pairing").await;
    let (relay_link, link_addr, link_task) = relay_link(relay.addr()).await;
    let dir = tempfile::tempdir().expect("database directory");
    let store = Store::connect(&format!("sqlite://{}", dir.path().join("backend.db").display()))
        .await
        .expect("store");
    let auth = Arc::new(
        Auth::new(store.clone(), pocox_auth::Config {
            github_client_id: "test-client".to_string(),
            github_client_secret: None,
            github_scope: "read:user".to_string(),
            jwt_secret: "test-jwt-secret-of-at-least-32-bytes!".to_string(),
            jwt_ttl_secs: 3600,
            refresh_ttl_secs: 1000,
            web_callback_url: None,
            pairing_secret: Some("test-pairing-secret-of-at-least-32-bytes".to_string()),
        })
        .expect("auth"),
    );
    auth.verify_pairing_key().await.expect("pairing key");
    let session = RelaySession::new(link_addr.to_string(), TEST_ADMIN_KEY);
    let settings = PairingSettings {
        linked_key_ttl: Duration::from_secs(1800),
        single_key_ttl,
        services_snapshot_ttl: Duration::ZERO,
        ..PairingSettings::default()
    };
    let trusted = TrustedProxies::parse(&settings.trusted_proxies).expect("proxies");
    let pairing =
        Pairing::new(Arc::clone(&auth), store, session.clone(), settings).expect("pairing");
    let app = router(AppState {
        auth,
        credentials: Credentials::new(session.clone()),
        relay: session,
        pairing: Some(Arc::clone(&pairing)),
    });
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("http bind");
    let base = format!("http://{}", listener.local_addr().expect("addr"));
    let server = tokio::spawn(pocox_backend::serve_plain(
        listener,
        app,
        Some(pocox_backend::ConnectionLimits::default()),
        trusted,
    ));
    Lab {
        base,
        relay,
        relay_link,
        pairing,
        _tasks: vec![link_task, server],
        _dir: dir,
    }
}

/// One device: an OS account's home with nothing shared with this machine's.
struct Device {
    home: tempfile::TempDir,
    backend: String,
    scope: Option<String>,
}

impl Device {
    fn new(lab: &Lab) -> Self {
        Self {
            home: tempfile::tempdir().expect("home"),
            backend: lab.base.clone(),
            scope: None,
        }
    }

    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_pocox"));
        let home = self.home.path();
        command
            .env("HOME", home)
            .env("XDG_CONFIG_HOME", home.join(".config"))
            .env("XDG_DATA_HOME", home.join(".local/share"))
            .env("XDG_STATE_HOME", home.join(".local/state"))
            .env("POCOX_BACKEND", &self.backend)
            .env_remove("PB_MAPPER_SERVER")
            .env_remove("MSG_HEADER_KEY")
            .env_remove("RUST_LOG")
            .env_remove("POCOX_DEVICE_SCOPE")
            .stdin(Stdio::null());
        if let Some(scope) = &self.scope {
            command.env("POCOX_DEVICE_SCOPE", scope);
        }
        command
    }

    fn run(&self, args: &[&str]) -> Output {
        self.command().args(args).output().expect("run pocox")
    }

    fn ok(&self, args: &[&str]) -> String {
        let output = self.run(args);
        assert!(output.status.success(), "{args:?} failed: {}", shown(&output));
        String::from_utf8_lossy(&output.stdout).into_owned()
    }

    /// `args` with `input` on stdin.
    fn piped(&self, args: &[&str], input: &str) -> Output {
        let mut child = self
            .command()
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("run pocox");
        child
            .stdin
            .take()
            .expect("stdin")
            .write_all(input.as_bytes())
            .expect("write stdin");
        child.wait_with_output().expect("wait")
    }

    /// Every file under this home, for what they must not hold.
    fn files(&self) -> Vec<PathBuf> {
        fn walk(dir: &Path, found: &mut Vec<PathBuf>) {
            for entry in std::fs::read_dir(dir).expect("list").flatten() {
                let path = entry.path();
                if path.is_dir() {
                    walk(&path, found);
                } else {
                    found.push(path);
                }
            }
        }
        let mut found = Vec::new();
        walk(self.home.path(), &mut found);
        found
    }

    /// The device store's one record.
    fn store_file(&self) -> PathBuf {
        self.files()
            .into_iter()
            .find(|path| {
                path.components()
                    .any(|part| part.as_os_str() == "device-store")
                    && path
                        .extension()
                        .is_some_and(|extension| extension == "json")
            })
            .expect("a device store record")
    }

    fn config_file(&self) -> Option<PathBuf> {
        self.files()
            .into_iter()
            .find(|path| path.file_name().is_some_and(|name| name == "config.toml"))
    }

    fn secret(&self) -> String {
        let record: serde_json::Value =
            serde_json::from_slice(&std::fs::read(self.store_file()).expect("read"))
                .expect("record");
        record["secret"].as_str().expect("secret").to_string()
    }
}

fn shown(output: &Output) -> String {
    format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

/// The code a `pocox pair` printed.
fn code_in(text: &str) -> String {
    text.split_whitespace()
        .find(|token| {
            let bytes = token.as_bytes();
            bytes.len() == 14 && bytes[4] == b'-' && bytes[9] == b'-'
        })
        .unwrap_or_else(|| panic!("no code in: {text}"))
        .to_string()
}

/// The first device a `pocox devices` listing shows that is not this one.
fn peer_id(listing: &str) -> String {
    listing
        .lines()
        .find(|line| line.contains("set up") && !line.contains("this device"))
        .and_then(|line| {
            line.split(|ch: char| ch.is_whitespace() || ch == '│' || ch == '|')
                .find(|cell| !cell.is_empty())
        })
        .unwrap_or_else(|| panic!("no peer in: {listing}"))
        .to_string()
}

/// An activated device and its code.
fn set_up(lab: &Lab) -> (Device, String) {
    let device = Device::new(lab);
    let printed = device.ok(&["pair", "--yes", "--no-wait"]);
    (device, code_in(&printed))
}

#[tokio::test(flavor = "multi_thread")]
async fn a_device_shows_its_code_and_another_joins_with_it_from_stdin() {
    let lab = lab().await;
    let (first, code) = set_up(&lab);

    // Nobody confirmed on the second device: it holds a code and nothing else.
    let second = Device::new(&lab);
    let printed = second.ok(&["pair", "--no-wait"]);
    assert_ne!(code_in(&printed), code);
    let account = second.ok(&["account"]);
    assert!(account.contains("not configured"), "preparing activates nothing: {account}");

    // A code in argv is refused before anything happens: other accounts can read
    // it.
    let refused = second.run(&["pair", "join", &code]);
    assert!(!refused.status.success(), "argv is not a way in");

    // Off a terminal, a change nobody confirmed does not happen.
    let unconfirmed = second.piped(&["pair", "join"], &format!("{code}\n"));
    assert!(!unconfirmed.status.success(), "{}", shown(&unconfirmed));
    assert!(second.ok(&["account"]).contains("not configured"));

    let joined = second.piped(&["pair", "join", "--yes"], &format!("{code}\n"));
    assert!(joined.status.success(), "{}", shown(&joined));
    let listed = first.ok(&["devices"]);
    assert_eq!(listed.matches("set up").count(), 2, "{listed}");
    assert!(second.ok(&["account"]).contains("pairing code"));
}

#[tokio::test(flavor = "multi_thread")]
async fn the_secret_reaches_no_file_but_the_store_and_no_output() {
    let lab = lab().await;
    let device = Device::new(&lab);
    let output = device
        .command()
        .args(["pair", "--yes", "--no-wait"])
        .env("RUST_LOG", "trace")
        .output()
        .expect("run");
    assert!(output.status.success(), "{}", shown(&output));
    let secret = device.secret();
    let store = device.store_file();
    assert!(!shown(&output).contains(&secret), "not in anything printed, at any log level");
    assert!(!shown(&output).contains("pcxd1_"));
    let code = code_in(&String::from_utf8_lossy(&output.stdout));
    assert!(
        !String::from_utf8_lossy(&output.stderr).contains(&code),
        "the code is the command's output and appears in no log"
    );
    for file in device.files() {
        if file == store {
            continue;
        }
        let held = String::from_utf8_lossy(&std::fs::read(&file).expect("read")).into_owned();
        assert!(!held.contains(&secret), "{} holds the secret", file.display());
    }
    let config = std::fs::read_to_string(device.config_file().expect("config")).expect("read");
    assert!(config.contains("device_code"));
    assert!(!config.contains("refresh_token"));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let mode = |path: &Path| {
            std::fs::metadata(path)
                .expect("metadata")
                .permissions()
                .mode()
                & 0o777
        };
        assert_eq!(mode(&store), 0o600);
        assert_eq!(mode(store.parent().expect("parent")), 0o700);
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn logging_out_keeps_the_identity_and_pairing_resumes_it() {
    let lab = lab().await;
    let (first, code) = set_up(&lab);
    let second = Device::new(&lab);
    let joined = second.piped(&["pair", "join", "--yes"], &format!("{code}\n"));
    assert!(joined.status.success(), "{}", shown(&joined));
    let secret = second.secret();

    second.ok(&["logout"]);
    assert_eq!(second.secret(), secret, "the store is not deleted");
    assert!(second.ok(&["account"]).contains("not configured"));
    assert_eq!(first.ok(&["devices"]).matches("set up").count(), 2, "logging out is not leaving");

    let resumed = second.ok(&["pair", "--yes", "--no-wait"]);
    assert_eq!(second.secret(), secret);
    assert_ne!(code_in(&resumed), code, "it keeps its own code");
    assert!(second.ok(&["account"]).contains("pairing code"));
    // GitHub's own way back stays what it was.
    assert!(!second.run(&["login", "--resume"]).status.success(), "nothing was set aside");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_removed_device_is_told_and_comes_back_only_by_continuing() {
    let lab = lab().await;
    let (first, code) = set_up(&lab);
    let second = Device::new(&lab);
    let joined = second.piped(&["pair", "join", "--yes"], &format!("{code}\n"));
    assert!(joined.status.success(), "{}", shown(&joined));

    let id = peer_id(&first.ok(&["devices"]));
    assert!(
        !first
            .piped(&["devices", "remove", &id], "")
            .status
            .success(),
        "confirm first"
    );
    first.ok(&["devices", "remove", &id, "--yes"]);
    assert_eq!(first.ok(&["devices"]).matches("set up").count(), 1);

    // It holds a session of its own and no relay access.
    let services = second.run(&["services", "list"]);
    assert!(!services.status.success(), "{}", shown(&services));
    assert!(shown(&services).contains("device_not_activated"), "{}", shown(&services));
    let again = second.run(&["pair", "--no-wait"]);
    assert!(again.status.success(), "{}", shown(&again));
    assert!(shown(&again).contains("not set up"), "{}", shown(&again));
    assert!(shown(&again).contains("removed this one"), "it says what happened: {}", shown(&again));
    second.ok(&["pair", "--yes", "--no-wait"]);
    assert!(second.run(&["services", "list"]).status.success(), "Continue restored access");
    assert_eq!(first.ok(&["devices"]).matches("set up").count(), 1, "but not its old group");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_restored_device_takes_the_code_and_the_old_copy_is_told_to_start_over() {
    let lab = lab().await;
    let (old, code) = set_up(&lab);
    let listing = old.ok(&["devices"]);
    let id = listing
        .lines()
        .find(|line| line.contains("this device"))
        .and_then(|line| {
            line.split(|ch: char| ch.is_whitespace() || ch == '│' || ch == '|')
                .find(|cell| !cell.is_empty())
        })
        .unwrap_or_else(|| panic!("no device in: {listing}"))
        .to_string();

    let reinstalled = Device::new(&lab);
    let restored =
        reinstalled.piped(&["pair", "restore", "--yes", "--device", &id], &format!("{code}\n"));
    assert!(restored.status.success(), "{}", shown(&restored));
    assert_eq!(code_in(&reinstalled.ok(&["pair", "--no-wait"])), code, "the same code");

    let dead = old.secret();
    let refused = old.run(&["pair", "--no-wait"]);
    assert!(!refused.status.success());
    assert!(shown(&refused).contains("start-over"), "{}", shown(&refused));
    assert!(shown(&refused).contains("old access ends"), "and until when: {}", shown(&refused));
    assert_eq!(old.secret(), dead, "nothing reclaims a device on its own");
    let fresh = old.ok(&["pair", "start-over", "--yes"]);
    assert_ne!(old.secret(), dead);
    assert_ne!(code_in(&fresh), code);
}

#[tokio::test(flavor = "multi_thread")]
async fn managing_a_device_that_was_never_set_up_says_so_and_creates_nothing() {
    let lab = lab().await;
    let never = Device::new(&lab);
    for args in [&["pair", "pause"][..], &["pair", "rotate"], &["pair", "leave", "--yes"], &[
        "devices",
        "remove",
        "some-device",
        "--yes",
    ]] {
        let output = never.run(args);
        assert!(!output.status.success(), "{args:?} did nothing, and says so");
        assert!(shown(&output).contains("no pairing identity"), "{args:?}: {}", shown(&output));
    }
    assert!(
        !never.files().iter().any(|path| path
            .extension()
            .is_some_and(|extension| extension == "json")
            && path
                .components()
                .any(|part| part.as_os_str() == "device-store")),
        "no secret was saved"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_change_still_under_way_has_its_own_exit_code_and_shows_up_later() {
    let lab = lab().await;
    let (first, code) = set_up(&lab);
    let second = Device::new(&lab);
    let joined = second.piped(&["pair", "join", "--yes"], &format!("{code}\n"));
    assert!(joined.status.success(), "{}", shown(&joined));
    // Holding a key is what makes leaving owe the relay work.
    assert!(second.run(&["services", "list"]).status.success());

    lab.relay_goes_away();
    let mut leaving = second
        .command()
        .args(["pair", "leave", "--yes"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("leave");
    tokio::time::sleep(Duration::from_secs(3)).await;
    // Ctrl-C ends the wait for it, not the change.
    let sent = Command::new("kill")
        .args(["-INT", &leaving.id().to_string()])
        .status()
        .expect("kill");
    assert!(sent.success());
    let output = tokio::task::spawn_blocking(move || {
        let status = loop {
            if let Some(status) = leaving.try_wait().expect("poll") {
                break status;
            }
            std::thread::sleep(Duration::from_millis(50));
        };
        (status, leaving)
    })
    .await
    .expect("join");
    assert_eq!(output.0.code(), Some(75), "neither success nor failure");

    let listed = second.run(&["devices"]);
    assert!(shown(&listed).contains("under way"), "{}", shown(&listed));
    let again = second.run(&["pair", "leave", "--yes"]);
    assert!(!again.status.success(), "and it is not started twice");
    assert!(shown(&again).contains("transition_pending"), "{}", shown(&again));

    lab.relay_returns();
    lab.pairing
        .reconcile_once()
        .await
        .expect("the worker's pass");
    let listed = second.run(&["devices"]);
    assert!(!shown(&listed).contains("under way"), "{}", shown(&listed));
    assert_eq!(first.ok(&["devices"]).matches("set up").count(), 1, "it did leave");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_set_up_device_is_told_what_to_do_instead_of_restoring() {
    let lab = lab().await;
    let (device, _) = set_up(&lab);
    for args in [&["pair", "restore", "--retake"][..], &["pair", "restore", "--ask"]] {
        let refused = device.run(args);
        assert!(!refused.status.success());
        assert!(shown(&refused).contains("pair pause"), "{args:?}: {}", shown(&refused));
        assert!(shown(&refused).contains("devices remove"), "{args:?}: {}", shown(&refused));
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn a_move_says_every_installation_goes_along_and_restore_names_its_devices() {
    let lab = lab().await;
    let (first, code) = set_up(&lab);
    // A set-up device with no peers has other installations too.
    let (lone, _) = set_up(&lab);
    let joined = lone.piped(&["pair", "join", "--yes"], &format!("{code}\n"));
    assert!(joined.status.success(), "{}", shown(&joined));
    assert!(shown(&joined).contains("every POCOX installation"), "{}", shown(&joined));

    // With no terminal to pick on, it shows the ids it asks for.
    let reinstalled = Device::new(&lab);
    let asked = reinstalled.piped(&["pair", "restore", "--yes"], &format!("{code}\n"));
    assert!(!asked.status.success());
    let listing = first.ok(&["devices"]);
    let id = listing
        .lines()
        .find(|line| line.contains("this device"))
        .and_then(|line| {
            line.split(|ch: char| ch.is_whitespace() || ch == '│' || ch == '|')
                .find(|cell| !cell.is_empty())
        })
        .expect("an id");
    assert!(shown(&asked).contains(id), "{}", shown(&asked));
    assert!(shown(&asked).contains("--device"), "{}", shown(&asked));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_github_session_comes_back_to_the_backend_it_was_on_and_never_over_another() {
    let lab = lab().await;
    let (device, _) = set_up(&lab);
    device.ok(&["logout"]);
    // Signed in on the backend `$POCOX_BACKEND` names, which `config.toml` does
    // not.
    let config = device.config_file().expect("config");
    let github = "[account]\ntoken = 'github-jwt'\nrefresh_token = 'github-refresh'\nlogin = \
                  'alice'\naccount_id = '1'\nprovider = 'github'\n";
    std::fs::write(&config, github).expect("sign in");
    // Pairing on a spelling of it, so `[account]` names a backend either way.
    let spelled = format!("{}/", lab.base);
    device.ok(&["pair", "--yes", "--no-wait", "--backend", &spelled]);
    let raw = std::fs::read_to_string(&config).expect("read");
    assert!(raw.contains("device_code"), "{raw}");
    assert!(!raw.contains("github-refresh"), "{raw}");

    let resumed = device.run(&["login", "--resume"]);
    assert!(resumed.status.success(), "{}", shown(&resumed));
    let raw = std::fs::read_to_string(&config).expect("read");
    assert!(raw.contains("github-refresh"), "{raw}");

    // Going back over a GitHub session here would lose its token.
    device.ok(&["pair", "--yes", "--no-wait"]);
    std::fs::write(&config, github.replace("alice", "newer")).expect("a newer sign-in");
    let refused = device.run(&["login", "--resume"]);
    assert!(!refused.status.success());
    assert!(shown(&refused).contains("already signed in"), "{}", shown(&refused));
    let raw = std::fs::read_to_string(&config).expect("read");
    assert!(raw.contains("newer"), "{raw}");
}

/// A computer that sleeps past a single device's one-hour key used to wake to a
/// worker that exited, under a `pocox serve` still saying it was exposing.
#[cfg(unix)]
#[tokio::test(flavor = "multi_thread")]
async fn a_worker_that_slept_past_its_key_carries_on_with_the_next_one() {
    // The relay's shortest.
    let lab = lab_with_key_life(Duration::from_secs(10)).await;
    let (device, _) = set_up(&lab);
    let mut worker = worker_of(&device, &lab).await;
    tokio::time::sleep(Duration::from_secs(1)).await;
    let signal = |name: &str| {
        let sent = Command::new("kill")
            .args([name, &worker.id().to_string()])
            .status()
            .expect("kill");
        assert!(sent.success());
    };
    signal("-STOP");
    tokio::time::sleep(Duration::from_secs(13)).await;
    signal("-CONT");

    let log = || std::fs::read_to_string(device.home.path().join("worker.log")).expect("log");
    let deadline = Instant::now() + Duration::from_secs(30);
    while !log().contains("continuing on its replacement") {
        tokio::time::sleep(Duration::from_millis(250)).await;
        assert!(worker.try_wait().expect("poll").is_none(), "it exited: {}", log());
        assert!(Instant::now() < deadline, "the relay never refused it: {}", log());
    }
    let deadline = Instant::now() + Duration::from_secs(20);
    let listed = loop {
        tokio::time::sleep(Duration::from_secs(1)).await;
        let listed = device.ok(&["services", "list"]);
        if listed.contains("worker-device") {
            break listed;
        }
        assert!(Instant::now() < deadline, "never published again: {listed}\n{}", log());
    };
    assert!(worker.try_wait().expect("poll").is_none(), "{listed}\n{}", log());
    let _ = worker.kill();
    let _ = worker.wait();
}

#[tokio::test(flavor = "multi_thread")]
async fn a_scope_is_a_device_of_its_own_on_one_home() {
    let lab = lab().await;
    let mut device = Device::new(&lab);
    let plain = code_in(&device.ok(&["pair", "--no-wait"]));
    device.scope = Some("one".to_string());
    let one = code_in(&device.ok(&["pair", "--no-wait"]));
    device.scope = Some("two".to_string());
    let two = code_in(&device.ok(&["pair", "--no-wait"]));
    assert_ne!(plain, one);
    assert_ne!(one, two);
    device.scope = None;
    assert_eq!(code_in(&device.ok(&["pair", "--no-wait"])), plain, "and keeps its code");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_code_can_be_paused_and_a_rotation_waits_a_day() {
    let lab = lab().await;
    let (first, code) = set_up(&lab);
    first.ok(&["pair", "pause"]);
    let second = Device::new(&lab);
    let refused = second.piped(&["pair", "join", "--yes"], &format!("{code}\n"));
    assert!(!refused.status.success());
    assert!(shown(&refused).contains("linking_paused"), "{}", shown(&refused));
    first.ok(&["pair", "resume"]);
    let joined = second.piped(&["pair", "join", "--yes"], &format!("{code}\n"));
    assert!(joined.status.success(), "{}", shown(&joined));
    let rotate = first.run(&["pair", "rotate"]);
    assert!(!rotate.status.success());
    assert!(shown(&rotate).contains("rate_limited"), "{}", shown(&rotate));
}

#[test]
fn a_cleartext_backend_never_gets_a_secret() {
    let home = tempfile::tempdir().expect("home");
    let output = Command::new(env!("CARGO_BIN_EXE_pocox"))
        .args(["pair", "--no-wait", "--backend", "http://backend.example"])
        .env("HOME", home.path())
        .env("XDG_CONFIG_HOME", home.path().join("config"))
        .env("XDG_DATA_HOME", home.path().join("data"))
        .env("XDG_STATE_HOME", home.path().join("state"))
        .stdin(Stdio::null())
        .output()
        .expect("run");
    assert!(!output.status.success());
    assert!(shown(&output).contains("https://"), "{}", shown(&output));
}

/// A relay worker for `device`, started the way a managed one would be, with
/// the credential that device's session gets.
async fn worker_of(device: &Device, lab: &Lab) -> Child {
    let config = std::fs::read_to_string(device.config_file().expect("config")).expect("read");
    let config: toml::Table = toml::from_str(&config).expect("config");
    let token = config["account"]["token"]
        .as_str()
        .expect("token")
        .to_string();
    let relay: pocox_account_proto::http::RelayCredentialResponse = reqwest::Client::new()
        .get(format!("{}/v1/relay", lab.base))
        .header(
            pocox_account_proto::pairing::PAIRING_PROTOCOL_HEADER,
            pocox_account_proto::pairing::PAIRING_PROTOCOL_VERSION.to_string(),
        )
        .bearer_auth(token)
        .send()
        .await
        .expect("relay request")
        .error_for_status()
        .expect("a key")
        .json()
        .await
        .expect("credential");
    let transport = pocox_pb::Transport {
        session: RelaySession::new(relay.relay_addr.clone(), relay.credential.clone()),
        namespace: Some(relay.namespace),
    };
    let key = transport.key(&pocox_core::service::ServiceId::new(
        "worker-device",
        pocox_core::service::ServiceKind::App,
        "worker",
    ));
    let local = std::net::TcpListener::bind("127.0.0.1:0").expect("a local service");
    device
        .command()
        .args(["__worker", "pb-register", "--key", &key, "--relay", &relay.relay_addr])
        .args(["--local-addr", &local.local_addr().expect("addr").to_string()])
        .env("MSG_HEADER_KEY", &relay.credential)
        .stdout(Stdio::null())
        .stderr(std::fs::File::create(device.home.path().join("worker.log")).expect("log"))
        .spawn()
        .expect("worker")
}

/// A detached relay worker outlives the command that spawned it, so nothing but
/// itself can notice that its device was removed.
#[tokio::test(flavor = "multi_thread")]
async fn a_running_worker_stops_when_its_device_is_removed() {
    let lab = lab().await;
    let (first, code) = set_up(&lab);
    let second = Device::new(&lab);
    let joined = second.piped(&["pair", "join", "--yes"], &format!("{code}\n"));
    assert!(joined.status.success(), "{}", shown(&joined));
    let listing = first.ok(&["devices"]);
    let id = peer_id(&listing);

    let mut worker = worker_of(&second, &lab).await;
    tokio::time::sleep(Duration::from_secs(3)).await;
    assert!(worker.try_wait().expect("poll").is_none(), "it runs while its identity stands");

    first.ok(&["devices", "remove", &id, "--yes"]);
    let deadline = Instant::now() + Duration::from_secs(90);
    let status = loop {
        if let Some(status) = worker.try_wait().expect("poll") {
            break status;
        }
        if Instant::now() > deadline {
            let _ = worker.kill();
            panic!("the worker outlived its device's removal");
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    };
    // The relay's refusal of its revoked key got there first, which is what this
    // worker can see at once. Its check of the identity covers a relay it cannot
    // reach.
    let said = std::fs::read_to_string(second.home.path().join("worker.log")).expect("log");
    assert!(!status.success(), "a failure the supervisor can see");
    assert!(said.contains("temporary_key_revoked"), "{said}");
}
