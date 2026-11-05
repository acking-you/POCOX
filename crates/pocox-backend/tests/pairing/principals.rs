//! Who a token speaks for: closed forms, no conversion, and fail-closed when
//! pairing is off.

use pocox_account_proto::pairing::{PAIRING_PROTOCOL_HEADER, PAIRING_PROTOCOL_VERSION};
use pocox_auth::Claims;
use reqwest::{Method, StatusCode};
use serde_json::json;

use super::support::{
    disabled_backend, github_claims, hint, mint, new_secret, op, Device, Harness, PAIRING_SECRET,
};

fn claims_of(device: &Device<'_>) -> Claims {
    Claims {
        sub: device.user().to_string(),
        ns: format!("pcxu:{}", device.user()),
        login: "forged".to_string(),
        gh_id: None,
        did: Some(device.id().to_string()),
        dgen: Some(device.session.generation),
        iat: 0,
        exp: 9_999_999_999,
        jti: "forged".to_string(),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn mixed_incomplete_and_foreign_tokens_authorize_nothing() {
    let harness = Harness::start().await;
    let victim = Device::activated(&harness, "victim").await;

    let forms = [
        // Both principals at once.
        Claims {
            gh_id: Some(1),
            ..claims_of(&victim)
        },
        // A device with no generation, and a generation with no device.
        Claims {
            dgen: None,
            ..claims_of(&victim)
        },
        Claims {
            did: None,
            ..claims_of(&victim)
        },
        // Neither.
        Claims {
            did: None,
            dgen: None,
            ..claims_of(&victim)
        },
    ];
    for form in &forms {
        let token = mint(form);
        for path in ["/v1/me", "/v1/services", "/v1/relay"] {
            let reply = harness.call(Method::GET, path, Some(&token), None).await;
            assert_eq!(reply.status, StatusCode::UNAUTHORIZED, "{path} with {form:?}");
        }
        harness
            .call(Method::GET, "/v1/pair/code", Some(&token), None)
            .await
            .expect_error(StatusCode::UNAUTHORIZED, "session_stale");
    }

    // A well-formed token for a generation that never existed, or under another
    // user.
    let future_generation = mint(&Claims {
        dgen: Some(victim.session.generation + 5),
        ..claims_of(&victim)
    });
    harness
        .call(Method::GET, "/v1/pair/code", Some(&future_generation), None)
        .await
        .expect_error(StatusCode::UNAUTHORIZED, "session_stale");
    let other_user = mint(&Claims {
        sub: "someone-else".to_string(),
        ..claims_of(&victim)
    });
    harness
        .call(Method::GET, "/v1/me", Some(&other_user), None)
        .await
        .expect_error(StatusCode::UNAUTHORIZED, "session_stale");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_github_session_is_never_converted_into_a_device() {
    let harness = Harness::start().await;
    let github = mint(&github_claims("u1234", 7));
    let me = harness
        .call(Method::GET, "/v1/me", Some(&github), None)
        .await
        .expect(StatusCode::OK);
    assert_eq!(me.body["account_id"], "7");
    for path in ["/v1/pair/code", "/v1/devices"] {
        harness
            .call(Method::GET, path, Some(&github), None)
            .await
            .expect_error(StatusCode::FORBIDDEN, "device_session_required");
    }
    harness
        .call(Method::POST, "/v1/pair/leave", Some(&github), Some(json!({ "operation_id": op() })))
        .await
        .expect_error(StatusCode::FORBIDDEN, "device_session_required");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_old_client_is_refused_before_any_side_effect() {
    let harness = Harness::start().await;
    let device = Device::activated(&harness, "device").await;
    // An old client presents a device JWT for up to its hour. A key from a
    // namespace would fail every direct session on its SDK.
    for version in [None, Some("0"), Some("999")] {
        let mut request = harness
            .http
            .get(format!("{}/v1/relay", harness.base()))
            .bearer_auth(device.token());
        if let Some(version) = version {
            request = request.header(PAIRING_PROTOCOL_HEADER, version);
        }
        let response = request.send().await.expect("request");
        assert_eq!(response.status(), StatusCode::UPGRADE_REQUIRED, "{version:?}");
        let body: serde_json::Value = response.json().await.expect("json");
        assert_eq!(body["error"], "pairing_client_upgrade_required");
    }
    assert!(
        harness
            .store
            .generation_key(device.id(), device.session.generation)
            .await
            .expect("row")
            .is_none(),
        "no grant was opened"
    );
    let secret = new_secret();
    let unversioned = harness
        .http
        .post(format!("{}/v1/pair/device", harness.base()))
        .json(&json!({ "device_secret": secret, "label": "old" }))
        .send()
        .await
        .expect("request");
    assert_eq!(unversioned.status(), StatusCode::UPGRADE_REQUIRED);
    assert!(harness
        .store
        .device_by_secret(&pocox_auth::pairing::hash_device_secret(&secret))
        .await
        .expect("lookup")
        .is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_request_body_grants_nothing_and_a_first_open_looks_nothing_up() {
    let harness = Harness::start().await;
    let owner = Device::new(&harness, "owner").await;
    owner.activate(Some(&hint(9))).await.expect(StatusCode::OK);

    // A hint, a platform and a scope in the creation body are ignored: a first open
    // looks nothing up.
    let secret = new_secret();
    let stranger: pocox_account_proto::pairing::DeviceSession = harness
        .call(
            Method::POST,
            "/v1/pair/device",
            None,
            Some(json!({
                "device_secret": secret,
                "label": "stranger",
                "platform": "app",
                "scope": "app",
                "hint": hint(9),
                "user_id": owner.user(),
            })),
        )
        .await
        .expect(StatusCode::OK)
        .parse();
    assert_ne!(stranger.account_id, owner.user());
    assert!(!stranger.activated);
    // Starting as new sends the old group nothing.
    let list = owner.get("/v1/devices").await.expect(StatusCode::OK);
    assert_eq!(list.body["pending_requests"], json!([]));

    // Knowing the hint finds a row and reveals nothing; it authorizes no restore.
    let stranger = Device {
        harness: &harness,
        secret,
        session: stranger,
    };
    let request = stranger
        .post("/v1/pair/restore/requests", json!({ "hint": hint(9) }))
        .await
        .expect(StatusCode::OK);
    assert_eq!(request.body["status"], "pending");
    assert!(request.body.get("devices").is_none());
    assert!(request.body.get("target_device_id").is_none());
    let id = request.body["request_id"].as_str().expect("id").to_string();
    stranger
        .post("/v1/pair/restore", json!({ "request_id": id, "operation_id": op() }))
        .await
        .expect_error(StatusCode::CONFLICT, "stale");
    stranger
        .post("/v1/pair/restore", json!({ "target_device_id": owner.id(), "operation_id": op() }))
        .await
        .expect_error(StatusCode::BAD_REQUEST, "invalid_request");

    // A hint moves only the binding: activating with it takes the row over, nothing
    // more. The old owner keeps its access and its group.
    stranger
        .activate(Some(&hint(9)))
        .await
        .expect(StatusCode::OK);
    owner.get("/v1/me").await.expect(StatusCode::OK);
    let late = Device::new(&harness, "late").await;
    let located = late
        .post("/v1/pair/restore/requests", json!({ "hint": hint(9) }))
        .await
        .expect(StatusCode::OK);
    let request = harness
        .store
        .restore_request_for(
            located.body["request_id"].as_str().expect("id"),
            late.id(),
            time::OffsetDateTime::now_utc().unix_timestamp(),
        )
        .await
        .expect("request")
        .expect("exists");
    assert_eq!(request.target_device_id, stranger.id(), "the latest device holds the hint");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn with_no_pairing_secret_routes_are_off_and_device_tokens_fail_closed() {
    let backend = disabled_backend().await;
    let http = reqwest::Client::new();
    let version = PAIRING_PROTOCOL_VERSION.to_string();
    let response = http
        .post(format!("{}/v1/pair/device", backend.base))
        .header(PAIRING_PROTOCOL_HEADER, &version)
        .json(&json!({ "device_secret": new_secret(), "label": "x" }))
        .send()
        .await
        .expect("request");
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body: serde_json::Value = response.json().await.expect("json");
    assert_eq!(body["error"], "pairing_disabled");

    let response = http
        .post(format!("{}/auth/refresh", backend.base))
        .header(PAIRING_PROTOCOL_HEADER, &version)
        .json(&json!({ "device_secret": new_secret() }))
        .send()
        .await
        .expect("request");
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);

    // A device JWT signed with the right key still authorizes nothing.
    let device_token = mint(&Claims {
        gh_id: None,
        did: Some("device".to_string()),
        dgen: Some(1),
        ..github_claims("du0", 0)
    });
    let response = http
        .get(format!("{}/v1/me", backend.base))
        .bearer_auth(&device_token)
        .send()
        .await
        .expect("request");
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

    // GitHub is untouched: same statuses, same shape.
    let response = http
        .get(format!("{}/v1/me", backend.base))
        .bearer_auth(mint(&github_claims("u1", 42)))
        .send()
        .await
        .expect("request");
    assert_eq!(response.status(), StatusCode::OK);
    let body: serde_json::Value = response.json().await.expect("json");
    assert_eq!(body["account_id"], "42");
    let response = http
        .post(format!("{}/auth/refresh", backend.base))
        .json(&json!({ "refresh_token": "unknown" }))
        .send()
        .await
        .expect("request");
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let _ = backend.auth.pairing_keys();

    // Refresh carries exactly one principal.
    let response = http
        .post(format!("{}/auth/refresh", backend.base))
        .json(&json!({ "refresh_token": "x", "device_secret": new_secret() }))
        .send()
        .await
        .expect("request");
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_changed_pairing_secret_is_refused_on_a_populated_database() {
    let harness = Harness::start().await;
    let _device = Device::new(&harness, "device").await;
    let changed = pocox_auth::Auth::new(harness.store.clone(), pocox_auth::Config {
        github_client_id: "test-client".to_string(),
        github_client_secret: None,
        github_scope: "read:user".to_string(),
        jwt_secret: super::support::JWT_SECRET.to_string(),
        jwt_ttl_secs: 3600,
        refresh_ttl_secs: 1000,
        web_callback_url: None,
        pairing_secret: Some(format!("{PAIRING_SECRET}-changed")),
    })
    .expect("auth");
    assert!(matches!(
        changed.verify_pairing_key().await,
        Err(pocox_auth::AuthError::PairingKeyMismatch)
    ));
    harness
        .auth
        .verify_pairing_key()
        .await
        .expect("the same key is fine");
}
