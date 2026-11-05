//! What one device or address can make the backend and relay do: every write to
//! the relay's replay window, every slot and every row has to be paid for by
//! someone.

use std::time::Duration;

use pocox_backend::pairing::{PairingLimits, PairingSettings, Rate};
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

    // A key that has to be issued again does need one.
    let row = harness
        .store
        .generation_key(first.id(), first.session.generation)
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
    first
        .get("/v1/relay")
        .await
        .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
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

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn connections_are_capped_per_address_and_an_idle_one_is_closed() {
    let harness = Harness::start().await;
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("listener");
    let addr = listener.local_addr().expect("addr");
    let app = pocox_backend::router(pocox_backend::AppState {
        auth: harness.auth.clone(),
        credentials: pocox_backend::Credentials::new(harness.admin()),
        relay: harness.admin(),
        pairing: None,
    });
    let _server = tokio::spawn(pocox_backend::serve_plain(
        listener,
        app,
        pocox_backend::ConnectionLimits {
            total: 16,
            per_address: 2,
            header_read_timeout: Duration::from_millis(500),
        },
        pocox_backend::pairing::TrustedProxies::default(),
    ));

    let closes_soon = |mut stream: TcpStream, within: Duration| async move {
        let mut byte = [0u8; 1];
        matches!(tokio::time::timeout(within, stream.read(&mut byte)).await, Ok(Ok(0) | Err(_)))
    };
    let first = TcpStream::connect(addr).await.expect("connect");
    let second = TcpStream::connect(addr).await.expect("connect");
    let third = TcpStream::connect(addr)
        .await
        .expect("the socket connects, then closes");
    assert!(
        closes_soon(third, Duration::from_millis(200)).await,
        "a third connection from one address is dropped"
    );
    // Nothing was sent, so the two it did admit are closed as well.
    assert!(closes_soon(first, Duration::from_secs(3)).await, "an idle connection is closed");
    drop(second);
    tokio::time::sleep(Duration::from_millis(100)).await;
    // And that gave their slots back.
    let mut fourth = TcpStream::connect(addr).await.expect("connect");
    fourth
        .write_all(b"GET /healthz HTTP/1.1\r\nhost: x\r\n\r\n")
        .await
        .expect("write");
    let mut answer = vec![0u8; 64];
    let read = fourth.read(&mut answer).await.expect("read");
    assert!(String::from_utf8_lossy(&answer[..read]).contains("200"));
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
