//! A real backend through its real accept loop, on a real relay, with this
//! engine's installations pointed at it.
//!
//! Clients reach the backend through [`Front`], a TCP proxy that can lose an
//! answer after the backend has given it, which is what a lost response is. The
//! backend reaches the relay through [`RelayLink`], which can cut it off.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use pb_mapper_testkit::{Relay, TEST_ADMIN_KEY};
use pocox_account_proto::pairing::{CodeStatus, DeviceSession};
use pocox_auth::Auth;
use pocox_backend::pairing::{Pairing, PairingSettings, TrustedProxies};
use pocox_backend::{router, AppState, Credentials};
use pocox_core::config::Config;
use pocox_pb::RelaySession;
use pocox_store::Store;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

use super::identity::{Identity, TEST_STORES};
use super::{flows, NativeHint};
use crate::engine::config::{load_config, save_config};

const JWT_SECRET: &str = "test-jwt-secret-of-at-least-32-bytes!";
const PAIRING_SECRET: &str = "test-pairing-secret-of-at-least-32-bytes";

/// The proxy between clients and the backend.
#[derive(Clone, Default)]
pub(super) struct Front {
    plan: Arc<Mutex<FrontPlan>>,
}

#[derive(Default)]
struct FrontPlan {
    lose: Vec<String>,
    seen: Vec<String>,
}

impl Front {
    async fn start(target: SocketAddr) -> (Self, String, JoinHandle<()>) {
        let front = Self::default();
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("front bind");
        let base = format!("http://{}", listener.local_addr().expect("front addr"));
        let plan = front.plan.clone();
        let task = tokio::spawn(async move {
            while let Ok((client, _)) = listener.accept().await {
                tokio::spawn(forward(client, target, plan.clone()));
            }
        });
        (front, base, task)
    }

    /// The next answer to a request whose line holds `route` never arrives.
    pub(super) fn lose_answer_to(&self, route: &str) {
        self.plan.lock().expect("plan").lose.push(route.to_string());
    }

    /// How many requests held `route` in their request line.
    pub(super) fn count(&self, route: &str) -> usize {
        let plan = self.plan.lock().expect("plan");
        plan.seen.iter().filter(|line| line.contains(route)).count()
    }

    /// How many requests have passed in all.
    pub(super) fn total(&self) -> usize {
        self.plan.lock().expect("plan").seen.len()
    }
}

/// Carry one connection. Once the backend answers a request whose answer is to
/// be lost, the connection closes without passing that answer on.
async fn forward(mut client: TcpStream, target: SocketAddr, plan: Arc<Mutex<FrontPlan>>) {
    let Ok(mut server) = TcpStream::connect(target).await else {
        return;
    };
    let lose = AtomicBool::new(false);
    let (mut client_read, mut client_write) = client.split();
    let (mut server_read, mut server_write) = server.split();
    let requests = async {
        let mut buffer = [0u8; 16 * 1024];
        loop {
            let Ok(count) = client_read.read(&mut buffer).await else {
                return;
            };
            if count == 0 {
                return;
            }
            let head = String::from_utf8_lossy(&buffer[..count]);
            if let Some(line) = head
                .lines()
                .next()
                .filter(|line| line.ends_with("HTTP/1.1"))
            {
                let mut plan = plan.lock().expect("plan");
                plan.seen.push(line.to_string());
                if let Some(index) = plan.lose.iter().position(|route| line.contains(route)) {
                    plan.lose.remove(index);
                    lose.store(true, Ordering::SeqCst);
                }
            }
            if server_write.write_all(&buffer[..count]).await.is_err() {
                return;
            }
        }
    };
    let answers = async {
        let mut buffer = [0u8; 16 * 1024];
        loop {
            let Ok(count) = server_read.read(&mut buffer).await else {
                return;
            };
            if count == 0 || lose.load(Ordering::SeqCst) {
                return;
            }
            if client_write.write_all(&buffer[..count]).await.is_err() {
                return;
            }
        }
    };
    tokio::select! {
        () = requests => {},
        () = answers => {},
    }
}

/// The proxy between the backend and the relay.
#[derive(Clone)]
pub(super) struct RelayLink {
    target: Arc<Mutex<Option<SocketAddr>>>,
}

impl RelayLink {
    async fn start(target: SocketAddr) -> (Self, SocketAddr, JoinHandle<()>) {
        let link = Self {
            target: Arc::new(Mutex::new(Some(target))),
        };
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("link bind");
        let addr = listener.local_addr().expect("link addr");
        let current = link.target.clone();
        let task = tokio::spawn(async move {
            while let Ok((mut downstream, _)) = listener.accept().await {
                let Some(target) = *current.lock().expect("target") else {
                    continue;
                };
                tokio::spawn(async move {
                    if let Ok(mut upstream) = TcpStream::connect(target).await {
                        let _ = tokio::io::copy_bidirectional(&mut downstream, &mut upstream).await;
                    }
                });
            }
        });
        (link, addr, task)
    }

    /// Every later connection is dropped: a relay outage.
    pub(super) fn cut(&self) {
        *self.target.lock().expect("target") = None;
    }

    /// Later connections reach `target`.
    pub(super) fn restore(&self, target: SocketAddr) {
        *self.target.lock().expect("target") = Some(target);
    }
}

/// A backend, its database and the relay behind it.
pub(super) struct Lab {
    pub(super) relay: Relay,
    pub(super) link: RelayLink,
    pub(super) front: Front,
    pub(super) base: String,
    pub(super) pairing: Arc<Pairing>,
    _tasks: Vec<JoinHandle<()>>,
    _dir: tempfile::TempDir,
}

impl Lab {
    pub(super) async fn start() -> Self {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let relay = Relay::start("pocox-pairing-client").await;
        let (link, link_addr, link_task) = RelayLink::start(relay.addr()).await;
        let dir = tempfile::tempdir().expect("database directory");
        let store =
            Store::connect(&format!("sqlite://{}", dir.path().join("backend.db").display()))
                .await
                .expect("store");
        let auth = Arc::new(
            Auth::new(store.clone(), pocox_auth::Config {
                github_client_id: "test-client".to_string(),
                github_client_secret: None,
                github_scope: "read:user".to_string(),
                jwt_secret: JWT_SECRET.to_string(),
                jwt_ttl_secs: 3600,
                refresh_ttl_secs: 1000,
                web_callback_url: None,
                pairing_secret: Some(PAIRING_SECRET.to_string()),
            })
            .expect("auth"),
        );
        auth.verify_pairing_key().await.expect("pairing key");
        let session = RelaySession::new(link_addr.to_string(), TEST_ADMIN_KEY);
        let settings = PairingSettings {
            linked_key_ttl: std::time::Duration::from_secs(1800),
            single_key_ttl: std::time::Duration::from_secs(900),
            services_snapshot_ttl: std::time::Duration::ZERO,
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
        let addr = listener.local_addr().expect("http addr");
        let server = tokio::spawn(pocox_backend::serve_plain(
            listener,
            app,
            Some(pocox_backend::ConnectionLimits::default()),
            trusted,
        ));
        let (front, base, front_task) = Front::start(addr).await;
        Self {
            relay,
            link,
            front,
            base,
            pairing,
            _tasks: vec![link_task, server, front_task],
            _dir: dir,
        }
    }

    /// An installation on a device of its own.
    pub(super) fn device(&self) -> Install {
        let store = Arc::new(tempfile::tempdir().expect("device store"));
        Install::on(&self.base, store, None)
    }

    /// A device that went through Get started, with its code.
    pub(super) async fn activated(&self) -> (Install, DeviceSession, CodeStatus) {
        let install = self.device();
        let identity = install.identity();
        flows::prepare(&identity, Some("first"))
            .await
            .expect("prepare");
        let session = flows::activate(&identity, None).await.expect("activate");
        let code = flows::code(&identity).await.expect("code");
        (install, session, code)
    }
}

/// One installation: its own support directory and `config.toml`, on a device's
/// store shared with any other installation of that device.
pub(super) struct Install {
    pub(super) support: PathBuf,
    pub(super) backend: String,
    pub(super) store: Arc<tempfile::TempDir>,
    pub(super) scope: Option<String>,
    _dir: tempfile::TempDir,
}

impl Install {
    fn on(backend: &str, store: Arc<tempfile::TempDir>, scope: Option<String>) -> Self {
        let dir = tempfile::tempdir().expect("support");
        let support = dir.path().to_path_buf();
        TEST_STORES
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .get_or_insert_with(Default::default)
            .insert(support.clone(), (store.path().to_path_buf(), scope.clone()));
        let mut config = Config::default();
        config.set_account_backend(backend);
        save_config(&support, &config).expect("save config");
        Self {
            support,
            backend: backend.to_string(),
            store,
            scope,
            _dir: dir,
        }
    }

    /// An installation whose backend is not this lab's.
    pub(super) fn for_backend(backend: &str, store: Arc<tempfile::TempDir>) -> Self {
        Self::on(backend, store, None)
    }

    /// Another installation of this same device, as the app is to the CLI.
    pub(super) fn sibling(&self) -> Self {
        Self::on(&self.backend, self.store.clone(), self.scope.clone())
    }

    /// An installation on this computer's store under another device scope.
    pub(super) fn scoped(&self, scope: &str) -> Self {
        Self::on(&self.backend, self.store.clone(), Some(scope.to_string()))
    }

    pub(super) fn identity(&self) -> Identity {
        Identity::open(&self.support, &self.backend).expect("identity")
    }

    pub(super) fn config(&self) -> Config {
        load_config(&self.support).expect("config")
    }

    pub(super) fn raw_config(&self) -> String {
        std::fs::read_to_string(self.support.join("config.toml")).expect("config file")
    }

    /// The device store's file for this installation.
    pub(super) fn store_file(&self) -> PathBuf {
        let identity = self.identity();
        self.store
            .path()
            .join(format!("{}.json", identity.store.key().slot()))
    }

    pub(super) fn secret(&self) -> String {
        self.identity()
            .read()
            .expect("store")
            .expect("record")
            .secret()
            .to_string()
    }
}

/// A hardware identifier as a platform adapter would hand it over.
pub(super) fn hint(raw: &str) -> Option<NativeHint> {
    Some(NativeHint {
        source: "android_id".to_string(),
        raw_id: raw.to_string(),
    })
}
