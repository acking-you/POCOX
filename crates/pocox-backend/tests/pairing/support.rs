//! A real backend through the real accept loop, on a real relay.
//!
//! The backend dials the relay through [`RelayLink`], a TCP proxy this test
//! controls. An admin request is one connection, so refusing connections is a
//! relay outage, and pointing the link elsewhere is a relay that lost its state
//! or changed instance.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use pb_mapper_testkit::{Relay, TEST_ADMIN_KEY};
use pocox_account_proto::http::RelayCredentialResponse;
use pocox_account_proto::pairing::{
    DeviceSession, HardwareHint, OperationView, PreviewResponse, PAIRING_PROTOCOL_HEADER,
    PAIRING_PROTOCOL_VERSION,
};
use pocox_auth::Auth;
use pocox_backend::pairing::{Pairing, PairingSettings, TrustedProxies};
use pocox_backend::{router, AppState, Credentials};
use pocox_pb::RelaySession;
use pocox_store::Store;
use reqwest::{Method, StatusCode};
use serde::Serialize;
use serde_json::{json, Value};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

pub const JWT_SECRET: &str = "test-jwt-secret-of-at-least-32-bytes!";
pub const PAIRING_SECRET: &str = "test-pairing-secret-of-at-least-32-bytes";

/// Which relay the next connection reaches, if any.
#[derive(Clone, Default)]
pub struct RelayLink {
    plan: Arc<Mutex<LinkPlan>>,
}

#[derive(Default)]
struct LinkPlan {
    target: Option<SocketAddr>,
    /// One-shot targets for the next connections, ahead of `target`.
    next: Vec<SocketAddr>,
    connections: u64,
}

impl RelayLink {
    async fn start(target: SocketAddr) -> (Self, SocketAddr, JoinHandle<()>) {
        let link = Self::default();
        link.point_at(target);
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("link bind");
        let addr = listener.local_addr().expect("link addr");
        let plan = link.plan.clone();
        let task = tokio::spawn(async move {
            while let Ok((mut downstream, _)) = listener.accept().await {
                let target = {
                    let mut plan = plan.lock().expect("plan");
                    plan.connections += 1;
                    if plan.next.is_empty() {
                        plan.target
                    } else {
                        Some(plan.next.remove(0))
                    }
                };
                let Some(target) = target else {
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

    /// Every later connection reaches this relay.
    pub fn point_at(&self, target: SocketAddr) {
        self.plan.lock().expect("plan").target = Some(target);
    }

    /// Every later connection is dropped: a relay outage.
    pub fn cut(&self) {
        self.plan.lock().expect("plan").target = None;
    }

    /// The next connections go to these relays in order, then back to the usual
    /// one.
    pub fn then(&self, targets: &[SocketAddr]) {
        self.plan
            .lock()
            .expect("plan")
            .next
            .extend_from_slice(targets);
    }

    /// How many connections the backend has opened toward the relay.
    pub fn connections(&self) -> u64 {
        self.plan.lock().expect("plan").connections
    }
}

/// The running backend process, which a restart replaces.
struct Process {
    pairing: Arc<Pairing>,
    base: String,
    server: JoinHandle<()>,
}

/// A backend, its database and the relay behind it.
pub struct Harness {
    pub relay: Relay,
    pub link: RelayLink,
    pub link_addr: SocketAddr,
    pub store: Store,
    pub auth: Arc<Auth>,
    pub http: reqwest::Client,
    /// What the next [`Harness::relaunch`] starts with.
    pub settings: Mutex<PairingSettings>,
    process: Mutex<Process>,
    _link_task: JoinHandle<()>,
    _dir: tempfile::TempDir,
}

/// Settings a test relay can honor: its keys live at most an hour.
pub fn test_settings() -> PairingSettings {
    PairingSettings {
        linked_key_ttl: std::time::Duration::from_secs(1800),
        single_key_ttl: std::time::Duration::from_secs(900),
        services_snapshot_ttl: std::time::Duration::ZERO,
        ..PairingSettings::default()
    }
}

async fn build_auth(store: Store, pairing_secret: Option<&str>) -> Arc<Auth> {
    Arc::new(
        Auth::new(store, pocox_auth::Config {
            github_client_id: "test-client".to_string(),
            github_client_secret: None,
            github_scope: "read:user".to_string(),
            jwt_secret: JWT_SECRET.to_string(),
            jwt_ttl_secs: 3600,
            refresh_ttl_secs: 1000,
            web_callback_url: None,
            pairing_secret: pairing_secret.map(str::to_string),
        })
        .expect("auth"),
    )
}

async fn serve(
    auth: Arc<Auth>,
    relay: RelaySession,
    pairing: Option<Arc<Pairing>>,
    trusted: TrustedProxies,
) -> (String, JoinHandle<()>) {
    let app = router(AppState {
        auth,
        credentials: Credentials::new(relay.clone()),
        relay,
        pairing,
    });
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("http bind");
    let addr = listener.local_addr().expect("http addr");
    let server = tokio::spawn(pocox_backend::serve_plain(
        listener,
        app,
        pocox_backend::ConnectionLimits::default(),
        trusted,
    ));
    (format!("http://{addr}"), server)
}

impl Harness {
    pub async fn start() -> Self {
        Self::with_settings(test_settings()).await
    }

    pub async fn with_settings(settings: PairingSettings) -> Self {
        let relay = Relay::start("pocox-pairing").await;
        let (link, link_addr, link_task) = RelayLink::start(relay.addr()).await;
        let dir = tempfile::tempdir().expect("database directory");
        let store =
            Store::connect(&format!("sqlite://{}", dir.path().join("backend.db").display()))
                .await
                .expect("store");
        let auth = build_auth(store.clone(), Some(PAIRING_SECRET)).await;
        auth.verify_pairing_key().await.expect("pairing key");
        let session = RelaySession::new(link_addr.to_string(), TEST_ADMIN_KEY);
        let pairing =
            Pairing::new(Arc::clone(&auth), store.clone(), session.clone(), settings.clone())
                .expect("pairing");
        let trusted = TrustedProxies::parse(&settings.trusted_proxies).expect("proxies");
        let (base, server) =
            serve(Arc::clone(&auth), session, Some(Arc::clone(&pairing)), trusted).await;
        Self {
            relay,
            link,
            link_addr,
            store,
            auth,
            http: reqwest::Client::new(),
            settings: Mutex::new(settings),
            process: Mutex::new(Process {
                pairing,
                base,
                server,
            }),
            _link_task: link_task,
            _dir: dir,
        }
    }

    /// The administrator's direct line to the relay, past the link.
    pub fn admin(&self) -> RelaySession {
        RelaySession::new(self.relay.addr().to_string(), TEST_ADMIN_KEY)
    }

    /// Stop this backend process and start another over the same database,
    /// which runs the pass a restart runs.
    pub async fn restart(&self) {
        self.relaunch().await;
        let pairing = self.process.lock().expect("process").pairing.clone();
        pairing.reconcile_once().await.expect("reconcile");
    }

    /// Resume open operations with the running process, without its comparison
    /// of the relay's table: only the operation's own relay work runs.
    pub async fn pairing_resume(&self) {
        let pairing = self.process.lock().expect("process").pairing.clone();
        pairing.resume_open_operations().await.expect("resume");
    }

    /// The backend's base URL right now.
    pub fn base(&self) -> String {
        self.process.lock().expect("process").base.clone()
    }

    /// A new process over the same database, before its worker has run. Nothing
    /// is cached any more.
    pub async fn relaunch(&self) {
        let settings = self.settings.lock().expect("settings").clone();
        let session = RelaySession::new(self.link_addr.to_string(), TEST_ADMIN_KEY);
        let trusted = TrustedProxies::parse(&settings.trusted_proxies).expect("proxies");
        let pairing =
            Pairing::new(Arc::clone(&self.auth), self.store.clone(), session.clone(), settings)
                .expect("pairing");
        let (base, server) =
            serve(Arc::clone(&self.auth), session, Some(Arc::clone(&pairing)), trusted).await;
        let mut process = self.process.lock().expect("process");
        process.server.abort();
        *process = Process {
            pairing,
            base,
            server,
        };
    }

    /// Whether a credential can still authenticate to the relay.
    pub async fn credential_works(&self, credential: &str) -> bool {
        let session = RelaySession::new(self.relay.addr().to_string(), credential);
        pocox_pb::keys(&session).await.is_ok()
    }

    /// The service names a credential can see.
    pub async fn visible_services(&self, credential: &str) -> Vec<String> {
        let session = RelaySession::new(self.relay.addr().to_string(), credential);
        pocox_pb::keys(&session).await.expect("listing")
    }

    /// Live credentials as the relay reports them.
    pub async fn live_keys(&self) -> Vec<pocox_pb::CredentialRecord> {
        pocox_pb::live_credentials(&self.admin())
            .await
            .expect("listing")
    }

    /// A raw request to the backend, as a device would make it.
    pub async fn call(
        &self,
        method: Method,
        path: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> Reply {
        self.request(method, path, token, body, |request| request)
            .await
    }

    /// A raw request with extra headers.
    pub async fn request(
        &self,
        method: Method,
        path: &str,
        token: Option<&str>,
        body: Option<Value>,
        decorate: impl FnOnce(reqwest::RequestBuilder) -> reqwest::RequestBuilder,
    ) -> Reply {
        let mut request = self
            .http
            .request(method, format!("{}{path}", self.base()))
            .header(PAIRING_PROTOCOL_HEADER, PAIRING_PROTOCOL_VERSION.to_string());
        if let Some(token) = token {
            request = request.bearer_auth(token);
        }
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = decorate(request).send().await.expect("backend answers");
        let status = response.status();
        let retry_after = response
            .headers()
            .get("retry-after")
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse().ok());
        let cache = response
            .headers()
            .get("cache-control")
            .and_then(|value| value.to_str().ok())
            .map(str::to_string);
        let text = response.text().await.expect("backend body");
        Reply {
            status,
            retry_after,
            cache,
            body: serde_json::from_str(&text).unwrap_or(Value::String(text)),
        }
    }
}

/// What the backend answered.
#[derive(Debug, Clone)]
pub struct Reply {
    pub status: StatusCode,
    pub retry_after: Option<u64>,
    pub cache: Option<String>,
    pub body: Value,
}

impl Reply {
    /// The stable error code.
    pub fn error(&self) -> &str {
        self.body["error"].as_str().unwrap_or("")
    }

    pub fn parse<T: serde::de::DeserializeOwned>(&self) -> T {
        serde_json::from_value(self.body.clone())
            .unwrap_or_else(|error| panic!("{error}: {:?} {}", self.status, self.body))
    }

    #[track_caller]
    pub fn expect(self, status: StatusCode) -> Self {
        assert_eq!(self.status, status, "unexpected reply: {}", self.body);
        self
    }

    #[track_caller]
    pub fn expect_error(self, status: StatusCode, code: &str) -> Self {
        assert_eq!((self.status, self.error()), (status, code), "unexpected reply: {}", self.body);
        self
    }
}

static SEQUENCE: AtomicU64 = AtomicU64::new(1);

/// A fresh operation id.
pub fn op() -> String {
    format!("operation-{:016x}", SEQUENCE.fetch_add(1, Ordering::Relaxed))
}

/// A well-formed device secret that no other test shares.
pub fn new_secret() -> String {
    use base64::Engine as _;
    let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let mut bytes = [7u8; 32];
    bytes[..8].copy_from_slice(&sequence.to_be_bytes());
    bytes[8..16].copy_from_slice(&std::process::id().to_be_bytes().repeat(2));
    format!("pcxd1_{}", base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
}

/// A hardware hint from a seed.
pub fn hint(seed: u8) -> HardwareHint {
    use base64::Engine as _;
    HardwareHint {
        key: base64::engine::general_purpose::URL_SAFE_NO_PAD.encode([seed; 32]),
        source: Some("test".to_string()),
    }
}

/// A device: its secret and its latest session.
pub struct Device<'h> {
    pub harness: &'h Harness,
    pub secret: String,
    pub session: DeviceSession,
}

impl<'h> Device<'h> {
    /// First open: a new inactive device.
    pub async fn new(harness: &'h Harness, label: &str) -> Device<'h> {
        let secret = new_secret();
        let session = harness
            .call(
                Method::POST,
                "/v1/pair/device",
                None,
                Some(json!({ "device_secret": secret, "label": label })),
            )
            .await
            .expect(StatusCode::OK)
            .parse();
        Self {
            harness,
            secret,
            session,
        }
    }

    /// First open, then Get started.
    pub async fn activated(harness: &'h Harness, label: &str) -> Device<'h> {
        let device = Self::new(harness, label).await;
        device.activate(None).await.expect(StatusCode::OK);
        device
    }

    pub fn token(&self) -> &str {
        &self.session.token
    }

    pub fn id(&self) -> &str {
        &self.session.device_id
    }

    pub fn user(&self) -> &str {
        &self.session.account_id
    }

    pub async fn get(&self, path: &str) -> Reply {
        self.harness
            .call(Method::GET, path, Some(self.token()), None)
            .await
    }

    pub async fn post(&self, path: &str, body: impl Serialize) -> Reply {
        self.harness
            .call(
                Method::POST,
                path,
                Some(self.token()),
                Some(serde_json::to_value(body).expect("body")),
            )
            .await
    }

    /// Exchange the secret for a new session, updating this handle.
    pub async fn refresh(&mut self) -> Reply {
        let reply = self.refresh_raw().await;
        if reply.status == StatusCode::OK {
            self.session = reply.parse();
        }
        reply
    }

    /// Exchange the secret for a session, leaving this handle's old one in
    /// place.
    pub async fn refresh_raw(&self) -> Reply {
        self.harness
            .call(
                Method::POST,
                "/auth/refresh",
                None,
                Some(json!({ "device_secret": self.secret })),
            )
            .await
    }

    pub async fn activate(&self, hardware: Option<&HardwareHint>) -> Reply {
        self.post("/v1/pair/activate", json!({ "hint": hardware }))
            .await
    }

    /// The displayed code, with its dashes.
    pub async fn code(&self) -> String {
        let reply = self.get("/v1/pair/code").await.expect(StatusCode::OK);
        reply.body["code"].as_str().expect("code").to_string()
    }

    pub async fn preview(&self, code: &str) -> Reply {
        self.post("/v1/pair/preview", json!({ "code": code })).await
    }

    /// Preview `other`'s code and return its ticket.
    pub async fn ticket_for(&self, other: &Device<'_>) -> PreviewResponse {
        let code = other.code().await;
        self.preview(&code).await.expect(StatusCode::OK).parse()
    }

    pub async fn link_with(&self, ticket: &str, operation: &str, leave_current: bool) -> Reply {
        self.post(
            "/v1/pair/link",
            json!({ "ticket": ticket, "operation_id": operation, "leave_current": leave_current }),
        )
        .await
    }

    /// Link into `other`'s group, and pick up the new session.
    pub async fn link_to(&mut self, other: &Device<'_>) -> OperationView {
        let preview = self.ticket_for(other).await;
        let view: OperationView = self
            .link_with(&preview.ticket, &op(), true)
            .await
            .expect(StatusCode::OK)
            .parse();
        self.session = view
            .session
            .clone()
            .expect("a completed link carries a session");
        view
    }

    pub async fn relay_key(&self) -> RelayCredentialResponse {
        self.get("/v1/relay").await.expect(StatusCode::OK).parse()
    }

    pub async fn leave(&self, operation: &str) -> Reply {
        self.post("/v1/pair/leave", json!({ "operation_id": operation }))
            .await
    }

    pub async fn remove(&self, device_id: &str, operation: &str) -> Reply {
        self.harness
            .call(
                Method::DELETE,
                &format!("/v1/devices/{device_id}?operation_id={operation}"),
                Some(self.token()),
                None,
            )
            .await
    }

    /// Read an operation with this device's secret.
    pub async fn operation(&self, id: &str) -> Reply {
        self.harness
            .call(Method::GET, &format!("/v1/pair/operations/{id}"), Some(&self.secret), None)
            .await
    }

    /// A restore through a code: confirm that this is `target`.
    pub async fn restore_by_code(&self, code: &str, target: &str, intent: &str) -> Reply {
        let preview: PreviewResponse = self.preview(code).await.expect(StatusCode::OK).parse();
        self.post(
            "/v1/pair/restore",
            json!({
                "ticket": preview.ticket,
                "target_device_id": target,
                "operation_id": op(),
                "intent": intent,
            }),
        )
        .await
    }
}

/// A backend with no pairing secret.
pub struct DisabledBackend {
    pub base: String,
    pub auth: Arc<Auth>,
    _server: JoinHandle<()>,
    _dir: tempfile::TempDir,
}

/// Start a backend the way it runs with `POCOX_PAIRING_SECRET` unset.
pub async fn disabled_backend() -> DisabledBackend {
    let dir = tempfile::tempdir().expect("database directory");
    let store = Store::connect(&format!("sqlite://{}", dir.path().join("backend.db").display()))
        .await
        .expect("store");
    let auth = build_auth(store, None).await;
    auth.verify_pairing_key().await.expect("nothing to verify");
    let session = RelaySession::for_test("127.0.0.1:7666");
    let (base, server) = serve(Arc::clone(&auth), session, None, TrustedProxies::default()).await;
    DisabledBackend {
        base,
        auth,
        _server: server,
        _dir: dir,
    }
}

/// Mint a token under the backend's JWT key, for forms it would never issue
/// itself.
pub fn mint(claims: &pocox_auth::Claims) -> String {
    jsonwebtoken::encode(
        &jsonwebtoken::Header::new(jsonwebtoken::Algorithm::HS256),
        claims,
        &jsonwebtoken::EncodingKey::from_secret(JWT_SECRET.as_bytes()),
    )
    .expect("mint")
}

/// A GitHub session's claims.
pub fn github_claims(user: &str, gh_id: i64) -> pocox_auth::Claims {
    pocox_auth::Claims {
        sub: user.to_string(),
        ns: format!("pcxu:{user}"),
        login: user.to_string(),
        gh_id: Some(gh_id),
        did: None,
        dgen: None,
        iat: 0,
        exp: 9_999_999_999,
        jti: "test".to_string(),
    }
}
