//! What one device or address can make the backend and relay do: every write to
//! the relay's replay window, every slot and every row has to be paid for by
//! someone.

use std::net::SocketAddr;
use std::time::Duration;

use pocox_backend::pairing::{PairingLimits, PairingSettings, Rate, TrustedProxies};
use pocox_backend::ConnectionLimits;
use pocox_pb::RegisterOptions;
use reqwest::{Method, StatusCode};
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use super::support::{op, test_settings, Device, Harness};

fn limited(limits: PairingLimits) -> PairingSettings {
    PairingSettings {
        limits,
        ..test_settings()
    }
}

fn rate(count: i64, window_secs: i64) -> Rate {
    Rate {
        count,
        window_secs,
    }
}

async fn register(harness: &Harness, credential: &str, key: &str) -> impl Sized {
    let backend = TcpListener::bind("127.0.0.1:0").await.expect("backend");
    let addr = backend.local_addr().expect("addr").to_string();
    let session =
        pocox_pb::RelaySession::new(harness.relay.addr().to_string(), credential.to_string());
    let registration = pocox_pb::register(&session, RegisterOptions {
        key: key.to_string(),
        local_addr: addr,
        codec: true,
    })
    .await
    .expect("registration");
    (registration, backend)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn deregistration_is_metered_and_a_service_nobody_registered_costs_the_relay_no_write() {
    let harness = Harness::with_settings(limited(PairingLimits {
        deregistrations_per_device: rate(3, 600),
        ..PairingLimits::default()
    }))
    .await;
    let device = Device::activated(&harness, "device").await;
    let key = device.relay_key().await;
    let delete = |name: &'static str| {
        let (harness, token) = (&harness, device.token().to_string());
        async move {
            harness
                .call(Method::DELETE, &format!("/v1/services/mac/app/{name}"), Some(&token), None)
                .await
        }
    };

    // No such service: one listing, and no administrator write takes a replay slot.
    let before = harness.link.connections();
    let reply = delete("nothing").await.expect(StatusCode::NO_CONTENT);
    assert_eq!(reply.cache.as_deref(), Some("no-store"));
    assert_eq!(harness.link.connections(), before + 1, "a listing and nothing else");

    // A real one is retired, which is what the route is for.
    let service = format!("pcxu:{}:mac:app:real", key.namespace);
    let _registration = register(&harness, &key.credential, &service).await;
    let listed = device.get("/v1/services").await.expect(StatusCode::OK);
    assert_eq!(listed.body["services"][0]["name"], "real");
    assert_eq!(listed.cache.as_deref(), Some("no-store"));
    let before = harness.link.connections();
    delete("real").await.expect(StatusCode::NO_CONTENT);
    assert_eq!(harness.link.connections(), before + 2, "a listing and a retirement");

    // And the third call in this window is the last.
    delete("nothing").await.expect(StatusCode::NO_CONTENT);
    let refused = delete("nothing")
        .await
        .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    assert!(refused.retry_after.is_some());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_service_listing_is_shared_between_devices() {
    let harness = Harness::with_settings(PairingSettings {
        services_snapshot_ttl: Duration::from_secs(60),
        ..test_settings()
    })
    .await;
    let first = Device::activated(&harness, "first").await;
    let second = Device::activated(&harness, "second").await;
    first.relay_key().await;
    second.relay_key().await;
    let before = harness.link.connections();
    for _ in 0..5 {
        first.get("/v1/services").await.expect(StatusCode::OK);
        second.get("/v1/services").await.expect(StatusCode::OK);
    }
    assert_eq!(harness.link.connections(), before + 1, "one listing however many devices ask");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn membership_moves_are_metered_and_a_refused_one_costs_nothing() {
    let harness = Harness::with_settings(limited(PairingLimits {
        moves_per_device: rate(2, 3600),
        ..PairingLimits::default()
    }))
    .await;
    let host = Device::activated(&harness, "host").await;
    let device = Device::activated(&harness, "device").await;
    let paused_target = Device::activated(&harness, "paused").await;

    // A link the store refuses did no work, so a client may retry it freely.
    let preview = device.ticket_for(&paused_target).await;
    harness
        .call(
            Method::PATCH,
            "/v1/pair/code",
            Some(paused_target.token()),
            Some(json!({ "paused": true })),
        )
        .await
        .expect(StatusCode::OK);
    for _ in 0..4 {
        device
            .link_with(&preview.ticket, &op(), false)
            .await
            .expect_error(StatusCode::CONFLICT, "preview_stale");
    }

    // A no-op does count: it is free to repeat, and each one used to write a row.
    let id = op();
    device.leave(&id).await.expect(StatusCode::OK);
    // A replay of it is free.
    for _ in 0..3 {
        device.leave(&id).await.expect(StatusCode::OK);
    }
    device.leave(&op()).await.expect(StatusCode::OK);
    let refused = device
        .leave(&op())
        .await
        .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    assert!(refused.retry_after.is_some());
    assert_eq!(harness.store.group_size(host.user()).await.expect("size"), 1);
    let (spent,): (i64,) =
        sqlx::query_as("SELECT COUNT(*) FROM pairing_budgets WHERE name = 'membership_moves'")
            .fetch_one(harness.store.pool())
            .await
            .expect("budget");
    assert_eq!(spent, 0, "a no-op owes the relay nothing, so it spends no shared budget");

    // No-ops keep one row per device and kind, however many there were.
    let (rows,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM pair_operations WHERE actor_device_id = ?1 AND kind = 'leave'",
    )
    .bind(device.id())
    .fetch_one(harness.store.pool())
    .await
    .expect("rows");
    assert_eq!(rows, 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn namespace_allocations_are_capped_and_renewing_an_existing_key_is_free() {
    let harness = Harness::with_settings(limited(PairingLimits {
        namespace_allocations_backend: rate(1, 3600),
        key_regrants_backend: rate(0, 3600),
        ..PairingLimits::default()
    }))
    .await;
    let first = Device::activated(&harness, "first").await;
    let second = Device::activated(&harness, "second").await;
    let key = first.relay_key().await;

    second
        .get("/v1/relay")
        .await
        .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    assert_eq!(
        harness
            .store
            .user_namespace(second.user())
            .await
            .expect("namespace"),
        None
    );

    // Renewal needs no slot and no budget, even with every budget above spent.
    harness.relaunch().await;
    let renewed = first.relay_key().await;
    assert_eq!(renewed.credential, key.credential);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_spent_backend_budget_stops_no_removal_leave_or_retake() {
    let harness = Harness::start().await;
    let host = Device::activated(&harness, "host").await;
    let mut intruder = Device::activated(&harness, "intruder").await;
    let mut leaver = Device::activated(&harness, "leaver").await;
    intruder.link_to(&host).await;
    leaver.link_to(&host).await;
    let intruder_key = intruder.relay_key().await;
    leaver.relay_key().await;

    // A fleet has spent the backend's budget for this hour.
    let now = time::OffsetDateTime::now_utc().unix_timestamp();
    sqlx::query(
        "INSERT OR REPLACE INTO pairing_budgets (name, window_start, used) VALUES \
         ('membership_moves', ?1, 1001)",
    )
    .bind(now - now.rem_euclid(3600))
    .execute(harness.store.pool())
    .await
    .expect("spend");

    host.remove(intruder.id(), &op())
        .await
        .expect(StatusCode::OK);
    assert!(!harness.credential_works(&intruder_key.credential).await);
    leaver.leave(&op()).await.expect(StatusCode::OK);
    let code = host.code().await;
    let retaker = Device::new(&harness, "retaker").await;
    retaker
        .restore_by_code(&code, host.id(), "retake")
        .await
        .expect(StatusCode::OK);

    // What it does stop is a link owing the relay work. One that owes none still
    // goes through.
    let mut retaker = retaker;
    retaker.refresh().await.expect(StatusCode::OK);
    let keyed = Device::activated(&harness, "keyed").await;
    keyed.relay_key().await;
    let ticket = keyed.ticket_for(&retaker).await;
    keyed
        .link_with(&ticket.ticket, &op(), false)
        .await
        .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    let keyless = Device::new(&harness, "keyless").await;
    let ticket = keyless.ticket_for(&retaker).await;
    keyless
        .link_with(&ticket.ticket, &op(), false)
        .await
        .expect(StatusCode::OK);
}

/// End a device's key behind the backend's back, and forget what it cached.
async fn end_key_at_the_relay(harness: &Harness, device: &Device<'_>) {
    let row = harness
        .store
        .generation_key(device.id(), device.session.generation)
        .await
        .expect("row")
        .expect("key");
    pocox_pb::revoke_credential(
        &harness.admin(),
        row.key_id.as_deref().expect("id").parse().expect("id"),
    )
    .await
    .expect("revoke");
    harness.relaunch().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_device_whose_own_key_ended_needs_no_budget_a_fleet_could_spend() {
    let harness = Harness::with_settings(limited(PairingLimits {
        key_regrants_backend: rate(0, 3600),
        ..PairingLimits::default()
    }))
    .await;
    let laptop = Device::activated(&harness, "laptop").await;
    laptop.relay_key().await;

    // It slept past its one-hour key. Replacing that is free.
    end_key_at_the_relay(&harness, &laptop).await;
    let key = laptop.relay_key().await;
    assert!(harness.credential_works(&key.credential).await);

    // A device that moved is what this budget is for.
    let host = Device::activated(&harness, "host").await;
    let mut moved = Device::activated(&harness, "moved").await;
    moved.relay_key().await;
    moved.link_to(&host).await;
    moved
        .get("/v1/relay")
        .await
        .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn keys_after_a_move_are_limited_per_address() {
    let harness = Harness::with_settings(limited(PairingLimits {
        key_regrants_per_address: rate(1, 3600),
        ..PairingLimits::default()
    }))
    .await;
    let host = Device::activated(&harness, "host").await;
    let mut first = Device::activated(&harness, "first").await;
    let mut second = Device::activated(&harness, "second").await;
    first.relay_key().await;
    second.relay_key().await;
    first.link_to(&host).await;
    second.link_to(&host).await;
    first.relay_key().await;
    second
        .get("/v1/relay")
        .await
        .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_refused_keyless_device_costs_the_relay_nothing_per_request() {
    let harness = Harness::with_settings(PairingSettings {
        capacity_share_percent: 0,
        limits: PairingLimits {
            key_grants_per_device: rate(2, 3600),
            ..PairingLimits::default()
        },
        ..test_settings()
    })
    .await;
    let device = Device::activated(&harness, "device").await;
    for _ in 0..2 {
        device
            .get("/v1/relay")
            .await
            .expect_error(StatusCode::SERVICE_UNAVAILABLE, "relay_capacity");
    }
    let before = harness.link.connections();
    for _ in 0..3 {
        device
            .get("/v1/relay")
            .await
            .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    }
    assert_eq!(harness.link.connections(), before, "not even a status read");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_client_closing_mid_request_does_not_cost_the_next_one_a_relay_write() {
    let harness = Harness::start().await;
    let device = Device::activated(&harness, "device").await;

    // The client goes away as soon as the relay is being asked, which is when its
    // request has work under way that a relay write may already have paid for.
    let host = harness.base().replace("http://", "");
    let mut stream = TcpStream::connect(&host).await.expect("connect");
    let request = format!(
        "GET /v1/relay HTTP/1.1\r\nhost: {host}\r\nauthorization: Bearer \
         {}\r\nx-pocox-pairing-protocol: 1\r\n\r\n",
        device.token()
    );
    let before = harness.link.connections();
    stream.write_all(request.as_bytes()).await.expect("write");
    for _ in 0..200 {
        if harness.link.connections() > before {
            break;
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
    assert!(harness.link.connections() > before, "the request reached the relay");
    drop(stream);

    // The work finishes regardless, as far as remembering the credential.
    let mut finished = false;
    for _ in 0..100 {
        tokio::time::sleep(Duration::from_millis(50)).await;
        let row = harness
            .store
            .generation_key(device.id(), device.session.generation)
            .await
            .expect("row");
        if row.is_some_and(|row| row.key_id.is_some()) {
            finished = true;
            break;
        }
    }
    assert!(finished, "the grant ran to its end without the client");
    tokio::time::sleep(Duration::from_millis(200)).await;

    let before = harness.link.connections();
    let key = device.relay_key().await;
    assert!(harness.credential_works(&key.credential).await);
    assert_eq!(harness.link.connections(), before, "the next request is served from memory");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_full_relay_table_refunds_what_the_key_was_charged() {
    let harness = Harness::with_settings(limited(PairingLimits {
        first_keys_per_address: rate(1, 3600),
        ..PairingLimits::default()
    }))
    .await;
    let device = Device::activated(&harness, "device").await;
    // The test relay's table holds 64.
    for index in 0..64 {
        pocox_pb::issue_credential(
            &harness.admin(),
            Duration::from_secs(600),
            Some(format!("github-{index}")),
        )
        .await
        .expect("fill");
    }
    for _ in 0..2 {
        device
            .get("/v1/relay")
            .await
            .expect_error(StatusCode::SERVICE_UNAVAILABLE, "relay_capacity");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_slow_upload_holds_no_request_slot() {
    let harness = Harness::with_settings(PairingSettings {
        body_read_timeout: Duration::from_millis(500),
        limits: PairingLimits {
            concurrent_requests: 1,
            ..PairingLimits::default()
        },
        ..test_settings()
    })
    .await;
    let device = Device::new(&harness, "device").await;

    // Headers promising a body that never arrives, more of them than there are
    // slots.
    let host = harness.base().replace("http://", "");
    let mut stalled = Vec::new();
    for _ in 0..4 {
        let mut stream = TcpStream::connect(&host).await.expect("connect");
        let request = format!(
            "POST /v1/pair/preview HTTP/1.1\r\nhost: {host}\r\ncontent-length: \
             100\r\ncontent-type: application/json\r\n\r\n"
        );
        stream.write_all(request.as_bytes()).await.expect("write");
        stalled.push(stream);
    }
    tokio::time::sleep(Duration::from_millis(100)).await;
    device.get("/v1/pair/code").await.expect(StatusCode::OK);

    // The stalled requests get a timeout, not a slot held forever.
    let mut answer = vec![0u8; 256];
    let read = tokio::time::timeout(Duration::from_secs(3), stalled[0].read(&mut answer))
        .await
        .expect("answered within the bound")
        .expect("read");
    assert!(String::from_utf8_lossy(&answer[..read]).contains("408"));
}

/// The real accept loop on a port of its own, with these limits.
async fn listen(
    harness: &Harness,
    limits: Option<ConnectionLimits>,
    trusted: TrustedProxies,
) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("listener");
    let addr = listener.local_addr().expect("addr");
    let app = pocox_backend::router(pocox_backend::AppState {
        auth: harness.auth.clone(),
        credentials: pocox_backend::Credentials::new(harness.admin()),
        relay: harness.admin(),
        pairing: None,
    });
    tokio::spawn(pocox_backend::serve_plain(listener, app, limits, trusted));
    addr
}

async fn closes_within(mut stream: TcpStream, within: Duration) -> bool {
    let mut byte = [0u8; 1];
    matches!(tokio::time::timeout(within, stream.read(&mut byte)).await, Ok(Ok(0) | Err(_)))
}

async fn healthz(stream: &mut TcpStream) -> bool {
    stream
        .write_all(b"GET /healthz HTTP/1.1\r\nhost: x\r\n\r\n")
        .await
        .expect("write");
    let mut answer = vec![0u8; 256];
    let read = stream.read(&mut answer).await.expect("read");
    String::from_utf8_lossy(&answer[..read]).contains("200")
}

const STRICT: ConnectionLimits = ConnectionLimits {
    total: 16,
    per_address: 2,
    header_read_timeout: Duration::from_millis(500),
};

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn connections_are_capped_per_address_and_an_idle_one_is_closed() {
    let harness = Harness::start().await;
    let addr = listen(&harness, Some(STRICT), TrustedProxies::default()).await;

    let first = TcpStream::connect(addr).await.expect("connect");
    let second = TcpStream::connect(addr).await.expect("connect");
    let third = TcpStream::connect(addr)
        .await
        .expect("the socket connects, then closes");
    assert!(
        closes_within(third, Duration::from_millis(200)).await,
        "a third connection from one address is dropped"
    );
    // Nothing was sent, so the two it did admit are closed as well.
    assert!(closes_within(first, Duration::from_secs(3)).await, "a silent connection is closed");
    drop(second);
    tokio::time::sleep(Duration::from_millis(100)).await;

    // And that gave their slots back. A connection gone idle after a request closes
    // too.
    let mut fourth = TcpStream::connect(addr).await.expect("connect");
    assert!(healthz(&mut fourth).await);
    assert!(closes_within(fourth, Duration::from_secs(3)).await, "an idle connection is closed");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_trusted_proxy_passes_the_per_address_cap() {
    let harness = Harness::start().await;
    let trusted = TrustedProxies::parse(&["127.0.0.1".to_string()]).expect("proxies");
    let addr = listen(&harness, Some(STRICT), trusted).await;
    let mut held = Vec::new();
    for _ in 0..4 {
        let mut stream = TcpStream::connect(addr).await.expect("connect");
        assert!(healthz(&mut stream).await, "all its clients share this one address");
        held.push(stream);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn with_pairing_off_connections_are_served_as_they_always_were() {
    let harness = Harness::start().await;
    let addr = listen(&harness, None, TrustedProxies::default()).await;
    let mut held = Vec::new();
    for _ in 0..4 {
        let mut stream = TcpStream::connect(addr).await.expect("connect");
        assert!(healthz(&mut stream).await, "no cap per address");
        held.push(stream);
    }
    let silent = TcpStream::connect(addr).await.expect("connect");
    assert!(!closes_within(silent, Duration::from_secs(1)).await, "no timer on a silent one");
    let idle = held.pop().expect("a connection");
    assert!(!closes_within(idle, Duration::from_secs(1)).await, "no timer on an idle one");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_burst_cannot_pass_the_capacity_share() {
    // The test relay holds 64 keys; 5% is 3.
    let harness = Harness::with_settings(PairingSettings {
        capacity_share_percent: 5,
        ..test_settings()
    })
    .await;
    let mut devices = Vec::new();
    for index in 0..8 {
        devices.push(Device::activated(&harness, &format!("device {index}")).await);
    }
    let mut attempts = tokio::task::JoinSet::new();
    let tokens: Vec<String> = devices
        .iter()
        .map(|device| device.token().to_string())
        .collect();
    let base = harness.base();
    for token in tokens {
        let http = harness.http.clone();
        let base = base.clone();
        attempts.spawn(async move {
            http.get(format!("{base}/v1/relay"))
                .bearer_auth(token)
                .header("x-pocox-pairing-protocol", "1")
                .send()
                .await
                .expect("answer")
                .status()
        });
    }
    let mut granted = 0;
    while let Some(status) = attempts.join_next().await {
        match status.expect("task") {
            StatusCode::OK => granted += 1,
            StatusCode::SERVICE_UNAVAILABLE => {},
            other => panic!("unexpected {other}"),
        }
    }
    assert_eq!(granted, 3);
    assert_eq!(harness.live_keys().await.len(), 3);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_valid_code_is_not_a_free_way_to_spend_the_backends_budget() {
    let harness = Harness::with_settings(PairingSettings {
        trusted_proxies: vec!["127.0.0.1".to_string()],
        limits: PairingLimits {
            code_checks_per_address: rate(2, 600),
            valid_codes_per_address: rate(2, 600),
            ..PairingLimits::default()
        },
        ..test_settings()
    })
    .await;
    let device = Device::new(&harness, "device").await;
    let target = Device::new(&harness, "target").await;
    let own = device.code().await;
    let code = target.code().await;
    let from = |address: &'static str, code: String| {
        let token = device.token().to_string();
        let harness = &harness;
        async move {
            harness
                .request(
                    Method::POST,
                    "/v1/pair/preview",
                    Some(&token),
                    Some(json!({ "code": code })),
                    |request| request.header("x-forwarded-for", address),
                )
                .await
        }
    };

    // A device's own code proves nothing and refunds nothing.
    for _ in 0..2 {
        from("198.51.100.1", own.clone())
            .await
            .expect_error(StatusCode::CONFLICT, "own_code");
    }
    from("198.51.100.1", own.clone())
        .await
        .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");

    // A valid code refunds its charge, up to a limit of its own. Past that it stays
    // on the meter, so one address soon stops reaching the backend's budget at
    // all.
    for _ in 0..2 {
        from("198.51.100.2", code.clone())
            .await
            .expect(StatusCode::OK);
    }
    for _ in 0..2 {
        from("198.51.100.2", code.clone())
            .await
            .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    }
    let spent = || async {
        let (used,): (i64,) =
            sqlx::query_as("SELECT used FROM pairing_budgets WHERE name = 'code_checks'")
                .fetch_one(harness.store.pool())
                .await
                .expect("budget");
        used
    };
    let before = spent().await;
    for _ in 0..3 {
        from("198.51.100.2", code.clone())
            .await
            .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    }
    // A new one-second window may have begun, which only makes the count smaller.
    assert!(spent().await <= before, "refused attempts stopped spending the budget");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_full_backend_budget_does_not_lock_an_address_out() {
    let harness = Harness::with_settings(PairingSettings {
        trusted_proxies: vec!["127.0.0.1".to_string()],
        limits: PairingLimits {
            code_checks_per_address: rate(2, 600),
            code_checks_backend: rate(1, 3600),
            ..PairingLimits::default()
        },
        ..test_settings()
    })
    .await;
    let device = Device::new(&harness, "device").await;
    let attempt = |address: &'static str| {
        let token = device.token().to_string();
        let harness = &harness;
        async move {
            harness
                .request(
                    Method::POST,
                    "/v1/pair/preview",
                    Some(&token),
                    Some(json!({ "code": "0000-0000-0000" })),
                    |request| request.header("x-forwarded-for", address),
                )
                .await
        }
    };
    // Someone else's flood spends the backend's budget.
    attempt("198.51.100.1")
        .await
        .expect_error(StatusCode::NOT_FOUND, "code_unknown");
    for _ in 0..4 {
        attempt("198.51.100.2")
            .await
            .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    }
    // The next window: this address's own two attempts are all still there.
    sqlx::query("DELETE FROM pairing_budgets WHERE name = 'code_checks'")
        .execute(harness.store.pool())
        .await
        .expect("a new window");
    attempt("198.51.100.2")
        .await
        .expect_error(StatusCode::NOT_FOUND, "code_unknown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_purge_gets_through_more_rows_than_one_batch() {
    let harness = Harness::start().await;
    let old = time::OffsetDateTime::now_utc().unix_timestamp() - 30 * 24 * 3600;
    for index in 0..1203_i64 {
        sqlx::query("INSERT INTO retired_codes (code_lookup, retired_at) VALUES (?1, ?2)")
            .bind(index.to_be_bytes().to_vec())
            .bind(old)
            .execute(harness.store.pool())
            .await
            .expect("row");
    }
    harness
        .store
        .purge_pairing(time::OffsetDateTime::now_utc().unix_timestamp())
        .await
        .expect("purge");
    let (left,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM retired_codes")
        .fetch_one(harness.store.pool())
        .await
        .expect("count");
    assert_eq!(left, 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_retiring_session_asking_again_costs_the_relay_nothing() {
    let harness = Harness::start().await;
    let old = Device::activated(&harness, "old").await;
    old.relay_key().await;
    let code = old.code().await;
    let new = Device::new(&harness, "new").await;
    new.restore_by_code(&code, old.id(), "restore")
        .await
        .expect(StatusCode::OK);

    let first = old.relay_key().await;
    let before = harness.link.connections();
    for _ in 0..5 {
        let again = old.relay_key().await;
        assert_eq!(again.credential, first.credential);
        assert_eq!(again.expires_at, first.expires_at);
    }
    assert_eq!(harness.link.connections(), before, "one renewal, however often it asks");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_failed_allocation_burns_no_first_key_budget() {
    let harness = Harness::with_settings(PairingSettings {
        relay_status_ttl: Duration::ZERO,
        limits: PairingLimits {
            first_keys_per_address: rate(1, 3600),
            key_grants_per_device: rate(1, 3600),
            ..PairingLimits::default()
        },
        ..test_settings()
    })
    .await;
    let device = Device::activated(&harness, "device").await;
    let real = harness.relay.addr();

    // Two status reads reach the relay, and the allocation does not.
    harness.link.then(&[real, real]);
    harness.link.cut();
    device
        .get("/v1/relay")
        .await
        .expect_error(StatusCode::SERVICE_UNAVAILABLE, "relay_unavailable");
    harness.link.point_at(real);
    device.relay_key().await;
}
