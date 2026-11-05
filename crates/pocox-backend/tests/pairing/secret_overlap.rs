//! A normal secret replacement's fixed overlap. These run in real time, because
//! the relay's own clock has to refuse the old key.

use std::time::Duration;

use pocox_account_proto::http::RelayCredentialResponse;
use pocox_account_proto::pairing::{DeviceSession, OperationView};
use pocox_backend::pairing::PairingSettings;
use reqwest::{Method, StatusCode};
use serde_json::json;

use super::support::{op, test_settings, Device, Harness};

fn overlapping(secs: i64) -> PairingSettings {
    PairingSettings {
        overlap_secs: secs,
        ..test_settings()
    }
}

/// Restore `target` onto a brand-new device through `target`'s code.
async fn replace<'h>(harness: &'h Harness, code: &str, target: &str) -> Device<'h> {
    let mut device = Device::new(harness, "reinstalled").await;
    let view: OperationView = device
        .restore_by_code(code, target, "restore")
        .await
        .expect(StatusCode::OK)
        .parse();
    assert!(view.session.is_none(), "a JWT never gets another JWT");
    device.refresh().await.expect(StatusCode::OK);
    device
}

async fn key_row_expiry(harness: &Harness, label: &str) -> u64 {
    harness
        .live_keys()
        .await
        .into_iter()
        .find(|key| key.label.as_deref() == Some(label))
        .expect("listed")
        .expires_at
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_retired_jwt_works_only_on_grace_routes_until_its_deadline() {
    let harness = Harness::with_settings(overlapping(12)).await;
    let old = Device::activated(&harness, "old install").await;
    let old_key = old.relay_key().await;
    let code = old.code().await;

    let new = replace(&harness, &code, old.id()).await;
    assert_eq!(new.id(), old.id(), "the same device");
    assert_eq!(new.user(), old.user());
    assert!(new.session.generation > old.session.generation);
    assert_eq!(new.code().await, code, "a normal restore keeps the code");
    let new_key = new.relay_key().await;
    assert_ne!(new_key.credential, old_key.credential);
    assert_eq!(new_key.namespace, old_key.namespace);

    // Grace-eligible: reads, and the same retiring generation's key.
    old.get("/v1/me").await.expect(StatusCode::OK);
    old.get("/v1/services").await.expect(StatusCode::OK);
    let retiring: RelayCredentialResponse = old.relay_key().await;
    assert_eq!(retiring.credential, old_key.credential, "never the current generation's key");
    assert!(retiring.expires_at <= old_key.expires_at);

    // Everything else is refused: no codes, no pairing state, no deregistration.
    for reply in [
        old.get("/v1/pair/code").await,
        old.get("/v1/devices").await,
        old.preview(&code).await,
        old.leave(&op()).await,
        old.post("/v1/pair/activate", json!({})).await,
        old.remove(new.id(), &op()).await,
        harness
            .call(
                Method::PATCH,
                &format!("/v1/devices/{}", old.id()),
                Some(old.token()),
                Some(json!({ "name": "renamed" })),
            )
            .await,
        harness
            .call(Method::DELETE, "/v1/services/mac/app/default", Some(old.token()), None)
            .await,
    ] {
        reply.expect_error(StatusCode::FORBIDDEN, "grace_restricted");
    }

    // The old secret cannot mint anything, and says when the overlap ends.
    let refused = old
        .refresh_raw()
        .await
        .expect_error(StatusCode::UNAUTHORIZED, "device_superseded");
    let deadline = refused.body["grace_deadline"].as_i64().expect("deadline");

    // The old key still sets things up during the overlap; afterwards it cannot.
    assert!(harness.credential_works(&old_key.credential).await);
    let until_deadline = deadline - time::OffsetDateTime::now_utc().unix_timestamp() + 2;
    tokio::time::sleep(Duration::from_secs(until_deadline.max(0) as u64)).await;

    old.get("/v1/me")
        .await
        .expect_error(StatusCode::UNAUTHORIZED, "session_stale");
    old.get("/v1/relay")
        .await
        .expect_error(StatusCode::UNAUTHORIZED, "session_stale");
    assert!(
        !harness.credential_works(&old_key.credential).await,
        "relay refuses it at the deadline"
    );

    // The replacement is unaffected.
    new.get("/v1/me").await.expect(StatusCode::OK);
    assert!(harness.credential_works(&new_key.credential).await);
    let mut new = new;
    new.refresh().await.expect(StatusCode::OK);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn retries_restarts_and_successive_replacements_never_extend_a_deadline() {
    let harness = Harness::with_settings(overlapping(120)).await;
    let first = Device::activated(&harness, "first").await;
    let first_key = first.relay_key().await;
    let code = first.code().await;
    let device_id = first.id().to_string();
    let first_generation = first.session.generation;
    let first_token = first.token().to_string();
    let first_secret = first.secret.clone();
    let label = harness
        .store
        .generation_key(&device_id, first_generation)
        .await
        .expect("row")
        .expect("key")
        .label;

    let second = replace(&harness, &code, &device_id).await;
    let deadline_of = |generation: i64| {
        let harness = &harness;
        let device_id = device_id.clone();
        async move {
            harness
                .store
                .device_access(&device_id, generation)
                .await
                .expect("access")
                .expect("row")
                .session
                .grace_deadline
                .expect("deadline")
        }
    };
    let first_deadline = deadline_of(first_generation).await;
    let shortened = key_row_expiry(&harness, &label).await;
    assert!(
        shortened + 5 < first_key.expires_at,
        "its key was shortened to the overlap, not left at its full life"
    );

    // Asking for the retiring key again lands on the same moment.
    let again = harness
        .call(Method::GET, "/v1/relay", Some(&first_token), None)
        .await
        .expect(StatusCode::OK);
    let again: RelayCredentialResponse = again.parse();
    assert!(again.expires_at <= shortened + 2, "{} vs {shortened}", again.expires_at);

    // A retry of the old secret's refresh changes nothing.
    harness
        .call(Method::POST, "/auth/refresh", None, Some(json!({ "device_secret": first_secret })))
        .await
        .expect_error(StatusCode::UNAUTHORIZED, "device_superseded");

    // A delayed earlier renewal moves the key past its deadline. The restart's pass
    // reads the expiry back and reapplies the deadline.
    pocox_pb::renew_credential(
        &harness.admin(),
        first_key_id(&harness, &label).await,
        Duration::from_secs(900),
    )
    .await
    .expect("a late renewal arrives");
    assert!(key_row_expiry(&harness, &label).await > shortened + 300);
    harness.restart().await;
    let reapplied = key_row_expiry(&harness, &label).await;
    assert!(reapplied <= shortened + 2, "{reapplied} vs {shortened}");
    assert_eq!(deadline_of(first_generation).await, first_deadline);

    // A second replacement has its own deadline and leaves the earlier one alone.
    let code_now = second.code().await;
    assert_eq!(code_now, code);
    let third = replace(&harness, &code, &device_id).await;
    assert_eq!(deadline_of(first_generation).await, first_deadline);
    let second_deadline = deadline_of(second.session.generation).await;
    assert!(second_deadline >= first_deadline);
    assert!(key_row_expiry(&harness, &label).await <= shortened + 2);

    // The retiring sessions reach only their own generation's key, if any: the
    // second session never had one and none is minted for it.
    second
        .get("/v1/relay")
        .await
        .expect_error(StatusCode::GONE, "retiring_key_gone");
    let current = third.relay_key().await;
    assert_ne!(current.credential, first_key.credential);
    let _: DeviceSession = third.refresh_raw().await.expect(StatusCode::OK).parse();
}

async fn first_key_id(harness: &Harness, label: &str) -> u64 {
    harness
        .live_keys()
        .await
        .into_iter()
        .find(|key| key.label.as_deref() == Some(label))
        .expect("listed")
        .key_id
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_key_with_less_left_than_the_overlap_is_not_lengthened() {
    // A single device's keys here last 900 seconds, and this overlap is longer.
    let harness = Harness::with_settings(overlapping(1200)).await;
    let old = Device::activated(&harness, "old").await;
    old.relay_key().await;
    let label = harness
        .store
        .generation_key(old.id(), old.session.generation)
        .await
        .expect("row")
        .expect("key")
        .label;
    let before = key_row_expiry(&harness, &label).await;
    let code = old.code().await;

    replace(&harness, &code, old.id()).await;
    assert_eq!(
        key_row_expiry(&harness, &label).await,
        before,
        "the relay was not asked to move it"
    );

    // Its session recovers the credential, and the renewal that takes stays within
    // the key's own end, not the longer overlap.
    let retiring = old.relay_key().await;
    assert!(retiring.expires_at <= before + 1, "{} vs {before}", retiring.expires_at);
    assert!(key_row_expiry(&harness, &label).await <= before + 1);
}
