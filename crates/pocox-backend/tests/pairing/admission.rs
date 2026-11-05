//! Admission: activation gating, key shares, per-address and backend-wide
//! limits, and the peer address those limits rest on.

use pocox_account_proto::http::RelayCredentialResponse;
use pocox_backend::pairing::{PairingLimits, PairingSettings};
use reqwest::{Method, StatusCode};
use serde_json::json;

use super::support::{github_claims, mint, new_secret, test_settings, Device, Harness};

fn code_limit(count: i64) -> PairingSettings {
    PairingSettings {
        limits: PairingLimits {
            code_checks_per_address: pocox_backend::pairing::Rate {
                count,
                window_secs: 600,
            },
            ..PairingLimits::default()
        },
        ..test_settings()
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn opening_or_polling_never_activates_and_an_inactive_device_gets_no_key() {
    let harness = Harness::start().await;
    let device = Device::new(&harness, "first screen").await;
    assert!(!device.session.activated);
    // Prepare the code, poll it, refresh: still inactive.
    let code = device.code().await;
    assert_eq!(code.len(), 14, "K7M2-F9QX-3RTB");
    let _ = device.code().await;
    let mut device = device;
    device.refresh().await.expect(StatusCode::OK);
    assert!(!device.session.activated);
    device
        .get("/v1/relay")
        .await
        .expect_error(StatusCode::FORBIDDEN, "device_not_activated");
    assert!(harness.live_keys().await.is_empty(), "the relay never heard about it");
    assert_eq!(
        harness
            .store
            .user_namespace(device.user())
            .await
            .expect("namespace"),
        None
    );

    device.activate(None).await.expect(StatusCode::OK);
    device.activate(None).await.expect(StatusCode::OK);
    let key = device.relay_key().await;
    assert!(harness.credential_works(&key.credential).await);
    device.refresh().await.expect(StatusCode::OK);
    assert!(device.session.activated);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn pairing_keys_stop_at_their_share_of_capacity() {
    // The test relay holds 64 keys; 5% is 3.
    let harness = Harness::with_settings(PairingSettings {
        capacity_share_percent: 5,
        ..test_settings()
    })
    .await;
    let mut devices = Vec::new();
    for name in ["one", "two", "three", "four"] {
        devices.push(Device::activated(&harness, name).await);
    }
    for device in &devices[..3] {
        device.relay_key().await;
    }
    let refused = devices[3]
        .get("/v1/relay")
        .await
        .expect_error(StatusCode::SERVICE_UNAVAILABLE, "relay_capacity");
    assert!(refused.retry_after.is_some());
    // Refused before side effects: no namespace, no grant.
    assert_eq!(
        harness
            .store
            .user_namespace(devices[3].user())
            .await
            .expect("namespace"),
        None
    );
    assert!(harness
        .store
        .device_open_keys(devices[3].id(), devices[3].session.generation)
        .await
        .expect("keys")
        .is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn past_the_share_github_sign_in_and_renewal_of_issued_keys_keep_working() {
    let mut harness = Harness::start().await;
    // A relay restart picks up the real defaults: a 65,536-key table and 30-day
    // keys, which GitHub's 24-hour credential needs.
    harness.relay.restart_server(None).await;
    let harness = harness;
    let holder = Device::activated(&harness, "holder").await;
    let key = holder.relay_key().await;
    let newcomer = Device::activated(&harness, "newcomer").await;

    // Pairing's share is now full.
    harness
        .settings
        .lock()
        .expect("settings")
        .capacity_share_percent = 0;
    harness.relaunch().await;
    newcomer
        .get("/v1/relay")
        .await
        .expect_error(StatusCode::SERVICE_UNAVAILABLE, "relay_capacity");

    // An issued key renews: it needs no new slot, and the credential text is the
    // same.
    let renewed: RelayCredentialResponse = holder.relay_key().await;
    assert_eq!(renewed.credential, key.credential);

    // GitHub is outside the share altogether.
    let github = harness
        .call(Method::GET, "/v1/relay", Some(&mint(&github_claims("u9", 9))), None)
        .await
        .expect(StatusCode::OK);
    let github: RelayCredentialResponse = github.parse();
    assert!(github.credential.starts_with("pbmt1_"));
    assert!(harness.credential_works(&github.credential).await);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn first_keys_are_limited_per_address_and_a_reissue_does_not_count() {
    let harness = Harness::with_settings(PairingSettings {
        limits: PairingLimits {
            first_keys_per_address: pocox_backend::pairing::Rate {
                count: 1,
                window_secs: 3600,
            },
            ..PairingLimits::default()
        },
        ..test_settings()
    })
    .await;
    let first = Device::activated(&harness, "first").await;
    let second = Device::activated(&harness, "second").await;
    first.relay_key().await;
    let refused = second
        .get("/v1/relay")
        .await
        .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    assert!(refused.retry_after.is_some());
    // The next key of a device that has one is not a first key.
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
    let reissued = first.relay_key().await;
    assert!(harness.credential_works(&reissued.credential).await);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn code_checks_are_charged_first_and_a_valid_code_refunds() {
    let harness = Harness::with_settings(code_limit(3)).await;
    let guesser = Device::new(&harness, "guesser").await;
    let target = Device::new(&harness, "target").await;
    let code = target.code().await;

    // Malformed input never reaches a lookup or a budget.
    for _ in 0..5 {
        guesser
            .preview("not a code")
            .await
            .expect_error(StatusCode::BAD_REQUEST, "invalid_request");
    }
    // Valid codes refund their charge, however many there are.
    for _ in 0..5 {
        guesser.preview(&code).await.expect(StatusCode::OK);
    }
    // Guesses do not.
    for _ in 0..3 {
        guesser
            .preview("0000-0000-0000")
            .await
            .expect_error(StatusCode::NOT_FOUND, "code_unknown");
    }
    let refused = guesser
        .preview("0000-0000-0000")
        .await
        .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    assert!(refused.retry_after.expect("Retry-After") > 0);
    assert_eq!(refused.cache.as_deref(), Some("no-store"));
    // Even a right code waits now: the limit comes before the lookup.
    guesser
        .preview(&code)
        .await
        .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_refused_attempt_cannot_drain_the_backend_wide_budget() {
    let harness = Harness::with_settings(PairingSettings {
        limits: PairingLimits {
            code_checks_per_address: pocox_backend::pairing::Rate {
                count: 1,
                window_secs: 600,
            },
            code_checks_backend: pocox_backend::pairing::Rate {
                count: 2,
                window_secs: 3600,
            },
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
    // An untrusted peer's header means nothing: all of these are one address, and
    // only the first reached the backend-wide budget.
    attempt("198.51.100.1")
        .await
        .expect_error(StatusCode::NOT_FOUND, "code_unknown");
    for address in ["198.51.100.2", "198.51.100.3", "198.51.100.4"] {
        attempt(address)
            .await
            .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    }
    let (used,): (i64,) =
        sqlx::query_as("SELECT used FROM pairing_budgets WHERE name = 'code_checks'")
            .fetch_one(harness.store.pool())
            .await
            .expect("budget");
    assert_eq!(used, 1, "refused attempts did not touch it");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_trusted_proxy_names_the_client_and_nothing_else_does() {
    let harness = Harness::with_settings(PairingSettings {
        trusted_proxies: vec!["127.0.0.1".to_string()],
        ..code_limit(1)
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
    // The socket peer is this test, so the real accept loop passed it through; only
    // then does its header count. Each address has its own limit...
    attempt("198.51.100.1")
        .await
        .expect_error(StatusCode::NOT_FOUND, "code_unknown");
    attempt("198.51.100.1")
        .await
        .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    attempt("198.51.100.2")
        .await
        .expect_error(StatusCode::NOT_FOUND, "code_unknown");
    // ...and one IPv6 host is one address across its whole /64.
    attempt("2001:db8:1:2::1")
        .await
        .expect_error(StatusCode::NOT_FOUND, "code_unknown");
    attempt("2001:db8:1:2:ffff::9")
        .await
        .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    attempt("2001:db8:1:3::1")
        .await
        .expect_error(StatusCode::NOT_FOUND, "code_unknown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn creation_is_idempotent_and_only_new_secrets_pay_admission() {
    let harness = Harness::with_settings(PairingSettings {
        limits: PairingLimits {
            new_devices_per_address: pocox_backend::pairing::Rate {
                count: 1,
                window_secs: 3600,
            },
            ..PairingLimits::default()
        },
        ..test_settings()
    })
    .await;
    let secret = new_secret();
    let body = json!({ "device_secret": secret, "label": "device" });
    let first: pocox_account_proto::pairing::DeviceSession = harness
        .call(Method::POST, "/v1/pair/device", None, Some(body.clone()))
        .await
        .expect(StatusCode::OK)
        .parse();
    // A retry after a lost response returns the same device, as many times as it
    // likes.
    for _ in 0..3 {
        let again: pocox_account_proto::pairing::DeviceSession = harness
            .call(Method::POST, "/v1/pair/device", None, Some(body.clone()))
            .await
            .expect(StatusCode::OK)
            .parse();
        assert_eq!(again.device_id, first.device_id);
        assert_eq!(again.account_id, first.account_id);
    }
    // A new secret from this address pays, and the limit has spent itself.
    harness
        .call(
            Method::POST,
            "/v1/pair/device",
            None,
            Some(json!({ "device_secret": new_secret(), "label": "second" })),
        )
        .await
        .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    // Bodies are bounded and validated before anything happens.
    harness
        .call(
            Method::POST,
            "/v1/pair/device",
            None,
            Some(json!({ "device_secret": "pcxd1_short", "label": "bad" })),
        )
        .await
        .expect_error(StatusCode::BAD_REQUEST, "invalid_request");
    harness
        .call(
            Method::POST,
            "/v1/pair/device",
            None,
            Some(json!({ "device_secret": new_secret(), "label": "x".repeat(65) })),
        )
        .await
        .expect_error(StatusCode::BAD_REQUEST, "invalid_request");
    let oversized = harness
        .call(
            Method::POST,
            "/v1/pair/device",
            None,
            Some(json!({ "device_secret": new_secret(), "label": "x".repeat(9000) })),
        )
        .await;
    assert_eq!(oversized.status, StatusCode::PAYLOAD_TOO_LARGE);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn rotation_waits_out_server_time_and_retires_the_old_code() {
    let harness = Harness::start().await;
    let device = Device::new(&harness, "device").await;
    let joiner = Device::new(&harness, "joiner").await;
    let code = device.code().await;
    let id = super::support::op();
    let body = json!({ "operation_id": id });

    let refused = device
        .post("/v1/pair/code/rotate", body.clone())
        .await
        .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    assert!(refused.retry_after.expect("Retry-After") > 23 * 3600);

    // A day of server time passes.
    sqlx::query("UPDATE devices SET code_issued_at = code_issued_at - 86401 WHERE id = ?1")
        .bind(device.id())
        .execute(harness.store.pool())
        .await
        .expect("age");
    let rotated = device
        .post("/v1/pair/code/rotate", body.clone())
        .await
        .expect(StatusCode::OK);
    let new_code = rotated.body["code"].as_str().expect("code").to_string();
    assert_ne!(new_code, code);
    joiner
        .preview(&code)
        .await
        .expect_error(StatusCode::GONE, "code_retired");
    joiner.preview(&new_code).await.expect(StatusCode::OK);

    // A retry reads the same result rather than rotating again or being refused.
    let retried = device
        .post("/v1/pair/code/rotate", body)
        .await
        .expect(StatusCode::OK);
    assert_eq!(retried.body["code"], new_code.as_str());

    // Rotation left membership alone.
    let mut device = device;
    let generation = device.session.generation;
    device.refresh().await.expect(StatusCode::OK);
    assert_eq!(device.session.generation, generation);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn retention_keeps_what_a_transition_or_live_key_still_needs() {
    let harness = Harness::start().await;
    let live = Device::activated(&harness, "live").await;
    live.relay_key().await;
    let idle = Device::activated(&harness, "idle").await;
    let unactivated = Device::new(&harness, "unactivated").await;
    let now = time::OffsetDateTime::now_utc().unix_timestamp();

    // A month on: only the first-screen device goes, polling or no polling.
    let _ = unactivated.code().await;
    let purged = harness
        .store
        .purge_pairing(now + 31 * 24 * 3600)
        .await
        .expect("purge");
    assert_eq!(purged.devices, 1);
    assert!(harness
        .store
        .pairing_device(unactivated.id())
        .await
        .expect("row")
        .is_none());
    assert!(harness
        .store
        .pairing_device(idle.id())
        .await
        .expect("row")
        .is_some());

    // 181 days on: the idle device goes, but one whose key the backend still counts
    // as able to authenticate stays until that is resolved.
    let purged = harness
        .store
        .purge_pairing(now + 181 * 24 * 3600)
        .await
        .expect("purge");
    assert_eq!(purged.devices, 1);
    assert!(harness
        .store
        .pairing_device(idle.id())
        .await
        .expect("row")
        .is_none());
    assert!(harness
        .store
        .pairing_device(live.id())
        .await
        .expect("row")
        .is_some());
    live.get("/v1/me").await.expect(StatusCode::OK);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_unresolved_transition_survives_any_retention_and_ends_in_a_clean_slate() {
    let harness = Harness::start().await;
    let host = Device::activated(&harness, "host").await;
    let mut member = Device::activated(&harness, "member").await;
    member.link_to(&host).await;
    member.relay_key().await;
    let source_user = member.user().to_string();

    harness.link.cut();
    let id = super::support::op();
    host.remove(member.id(), &id)
        .await
        .expect(StatusCode::ACCEPTED);
    let year_on = time::OffsetDateTime::now_utc().unix_timestamp() + 365 * 24 * 3600;
    harness.store.purge_pairing(year_on).await.expect("purge");
    assert!(harness.store.operation(&id).await.expect("row").is_some(), "never deleted");
    assert!(harness
        .store
        .pairing_device(member.id())
        .await
        .expect("row")
        .is_some());
    assert!(harness
        .store
        .user_namespace(&source_user)
        .await
        .expect("namespace")
        .is_some());

    harness.link.point_at(harness.relay.addr());
    harness.restart().await;
    let done = harness
        .store
        .operation(&id)
        .await
        .expect("row")
        .expect("row");
    assert!(done.state.is_terminal());

    // Everything falls due: the finished operation, then every device with no live
    // key, and the users left empty, which no key or operation refers to any more.
    let host_row = harness
        .store
        .generation_key(host.id(), host.session.generation)
        .await
        .expect("row");
    assert!(host_row.is_none(), "the host never asked for a key");
    let two_years_on = year_on + 365 * 24 * 3600;
    let purged = harness
        .store
        .purge_pairing(two_years_on)
        .await
        .expect("purge");
    assert!(purged.operations >= 1);
    assert!(harness.store.operation(&id).await.expect("row").is_none());
    assert!(harness
        .store
        .pairing_device(host.id())
        .await
        .expect("row")
        .is_none());
    assert!(purged.users >= 1, "an empty user goes once nothing refers to it");
    assert_eq!(
        harness
            .store
            .user_namespace(&source_user)
            .await
            .expect("namespace"),
        None
    );
}
