//! Races only this crate can set up: they hold a device's lock from outside a
//! request.

use std::sync::Arc;
use std::time::Duration;

use pb_mapper_testkit::{Relay, TEST_ADMIN_KEY};
use pocox_auth::pairing::hash_device_secret;
use pocox_auth::Auth;
use pocox_pb::RelaySession;
use pocox_store::pairing::{KeyAnswer, KeyState, NewDevice, NewDeviceOutcome, NewGrant};
use pocox_store::Store;

use super::relay_keys::grant_label;
use super::service::{unix_now, Pairing};
use super::settings::PairingSettings;

struct Fixture {
    relay: Relay,
    store: Store,
    pairing: Arc<Pairing>,
    _dir: tempfile::TempDir,
}

async fn fixture() -> Fixture {
    let relay = Relay::start("pocox-pairing-unit").await;
    let dir = tempfile::tempdir().expect("database directory");
    let store = Store::connect(&format!("sqlite://{}", dir.path().join("backend.db").display()))
        .await
        .expect("store");
    let auth = Arc::new(
        Auth::new(store.clone(), pocox_auth::Config {
            github_client_id: "client".to_string(),
            github_client_secret: None,
            github_scope: "read:user".to_string(),
            jwt_secret: "j".repeat(32),
            jwt_ttl_secs: 3600,
            refresh_ttl_secs: 1000,
            web_callback_url: None,
            pairing_secret: Some("p".repeat(32)),
        })
        .expect("auth"),
    );
    let session = RelaySession::new(relay.addr().to_string(), TEST_ADMIN_KEY);
    let pairing =
        Pairing::new(auth, store.clone(), session, PairingSettings::default()).expect("pairing");
    Fixture {
        relay,
        store,
        pairing,
        _dir: dir,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_grant_finishing_while_the_sweep_waits_stays_open() {
    let fixture = fixture().await;
    let admin = RelaySession::new(fixture.relay.addr().to_string(), TEST_ADMIN_KEY);
    let now = unix_now();
    let secret = format!("pcxd1_{}", "B".repeat(43));
    let derive = |device: &str, generation: i64| format!("{device}:{generation}").into_bytes();
    let outcome = fixture
        .store
        .create_device(
            NewDevice {
                secret_hash: &hash_device_secret(&secret),
                label: "device",
                platform: None,
                now,
            },
            &derive,
        )
        .await
        .expect("device");
    let NewDeviceOutcome::Created(access) = outcome else {
        panic!("a new secret creates a device");
    };
    let device = &access.device;
    fixture
        .store
        .activate_device(&device.id, 1, None, now)
        .await
        .expect("activate");
    let namespace = pocox_pb::allocate_namespace(&admin)
        .await
        .expect("namespace");
    fixture
        .store
        .claim_namespace(&access.user.id, &namespace.to_string())
        .await
        .expect("claim");
    let instance = pocox_pb::relay_instance_id(&admin).await.expect("instance");
    let label = grant_label(&device.id, 1, "0123456789abcdef");

    // A grant is in flight: it holds the device's lock and has not reached the
    // relay.
    let guard = fixture.pairing.device_locks.acquire(&device.id).await;
    fixture
        .store
        .open_grant(NewGrant {
            grant_id: "0123456789abcdef",
            device_id: &device.id,
            generation: 1,
            user_id: &access.user.id,
            namespace: &namespace.to_string(),
            relay_instance: &instance,
            label: &label,
            slot_limit: 100,
            now,
        })
        .await
        .expect("grant");

    // The sweep walks the table twice, finds nothing and waits for that lock.
    let sweeping = {
        let pairing = Arc::clone(&fixture.pairing);
        tokio::spawn(async move { pairing.sweep_keys().await })
    };
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(!sweeping.is_finished(), "the sweep waits for the grant in flight");

    // The grant finishes within the same second it opened.
    let issued = pocox_pb::issue_credential_in_namespace(
        &admin,
        namespace,
        Duration::from_secs(600),
        Some(label),
    )
    .await
    .expect("issue");
    fixture
        .store
        .record_key("0123456789abcdef", KeyAnswer {
            key_id: &issued.key_id.to_string(),
            expires_at: issued.expires_at as i64,
            local_end: now + 600,
            now,
        })
        .await
        .expect("record");
    drop(guard);
    sweeping.await.expect("sweep task").expect("sweep");

    // An exposed key must stay visible, or a later removal would miss it and report
    // complete while it still works.
    let row = fixture
        .store
        .generation_key(&device.id, 1)
        .await
        .expect("row")
        .expect("still open");
    assert_eq!(row.state, KeyState::Active);
    assert_eq!(row.key_id, Some(issued.key_id.to_string()));
}
