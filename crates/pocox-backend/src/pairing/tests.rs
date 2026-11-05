//! What only this crate can set up: races that hold a device's lock from
//! outside a request, a relay's status seeded rather than read, and a key
//! answered by hand.

use std::sync::Arc;
use std::time::{Duration, Instant};

use pb_mapper_testkit::{Relay, TEST_ADMIN_KEY};
use pocox_account_proto::pairing::PairingErrorCode;
use pocox_auth::pairing::hash_device_secret;
use pocox_auth::Auth;
use pocox_pb::{RelaySession, RelayStatus};
use pocox_store::pairing::{
    DeviceAccess, KeyAnswer, KeyState, NewDevice, NewDeviceOutcome, NewGrant,
};
use pocox_store::Store;

use super::relay::RelayFailure;
use super::relay_keys::grant_label;
use super::service::{unix_now, CachedStatus, ClientBucket, Pairing};
use super::settings::PairingSettings;

struct Fixture {
    relay: Relay,
    store: Store,
    auth: Arc<Auth>,
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
        Pairing::new(Arc::clone(&auth), store.clone(), session, PairingSettings::default())
            .expect("pairing");
    Fixture {
        relay,
        store,
        auth,
        pairing,
        _dir: dir,
    }
}

/// An activated device with a namespace, ready for a grant.
struct Keyless {
    access: DeviceAccess,
    namespace: u64,
    instance: String,
    admin: RelaySession,
}

async fn keyless_device(fixture: &Fixture) -> Keyless {
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
    fixture
        .store
        .activate_device(&access.device.id, 1, None, now)
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
    Keyless {
        access: *access,
        namespace,
        instance,
        admin,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_renewal_landing_past_a_new_cutoff_owes_that_cutoff() {
    let fixture = fixture().await;
    let keyless = keyless_device(&fixture).await;
    let device = &keyless.access.device;
    let now = unix_now();
    fixture
        .store
        .open_grant(NewGrant {
            grant_id: "fedcba9876543210",
            device_id: &device.id,
            generation: 1,
            user_id: &keyless.access.user.id,
            namespace: &keyless.namespace.to_string(),
            relay_instance: &keyless.instance,
            label: "pcxd:label",
            slot_limit: 100,
            now,
        })
        .await
        .expect("grant");
    // A restore set this key's cutoff while its renewal was on the way, and found
    // nothing owed then.
    sqlx::query("UPDATE device_relay_keys SET hard_cutoff = ?1, cutoff_pending = 0")
        .bind(now + 600)
        .execute(fixture.store.pool())
        .await
        .expect("cutoff");
    let answer = |local_end| KeyAnswer {
        key_id: "7",
        expires_at: local_end,
        local_end,
        now,
    };
    fixture
        .store
        .record_key("fedcba9876543210", answer(now + 300))
        .await
        .expect("within it");
    let row = fixture
        .store
        .grant("fedcba9876543210")
        .await
        .expect("row")
        .expect("row");
    assert!(!row.cutoff_pending, "a key ending in time owes nothing");
    fixture
        .store
        .record_key("fedcba9876543210", answer(now + 3600))
        .await
        .expect("past it");
    let row = fixture
        .store
        .grant("fedcba9876543210")
        .await
        .expect("row")
        .expect("row");
    assert!(row.cutoff_pending, "the worker reapplies it");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_request_does_not_queue_on_its_own_devices_lock() {
    let fixture = fixture().await;
    let keyless = keyless_device(&fixture).await;
    let device = &keyless.access.device;
    let session = fixture
        .auth
        .issue_device_session(&keyless.access, unix_now())
        .expect("session");
    let claims = fixture.auth.verify(&session.token).expect("token");
    let caller = fixture
        .auth
        .authenticate_device(&claims, unix_now())
        .await
        .expect("caller");

    let _busy = fixture.pairing.device_locks.acquire(&device.id).await;
    let started = Instant::now();
    let refused = fixture
        .pairing
        .relay_credential(Box::new(caller), ClientBucket([1; 16]))
        .await
        .expect_err("someone else is working on this device");
    assert_eq!(refused.refusal_code(), Some(PairingErrorCode::RateLimited));
    assert!(started.elapsed() < Duration::from_secs(2), "it did not wait");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_old_relay_is_refused_before_side_effects_and_a_silent_one_is_not() {
    let fixture = fixture().await;
    let unreachable = Pairing::new(
        Arc::clone(&fixture.auth),
        fixture.store.clone(),
        RelaySession::for_test("127.0.0.1:1"),
        PairingSettings::default(),
    )
    .expect("pairing");
    unreachable
        .require_capable_relay()
        .await
        .expect("unknown is not too old");

    let known = |supports_key_namespaces| CachedStatus {
        status: RelayStatus {
            instance_id: "instance".to_string(),
            supports_key_namespaces,
            key_capacity: 16,
        },
        fetched: Instant::now(),
    };
    *fixture.pairing.status.lock().expect("status") = Some(known(false));
    let refused = fixture
        .pairing
        .require_capable_relay()
        .await
        .expect_err("too old");
    assert_eq!(refused.refusal_code(), Some(PairingErrorCode::RelayTooOld));
    *fixture.pairing.status.lock().expect("status") = Some(known(true));
    fixture
        .pairing
        .require_capable_relay()
        .await
        .expect("capable");
}

#[test]
fn the_relays_word_that_a_key_is_dead_is_not_a_transport_failure() {
    for code in
        ["temporary_key_not_active", "temporary_key_not_found", "temporary_key_not_renewable"]
    {
        let error = anyhow::Error::new(pb_mapper::Error::Remote {
            code: code.to_string(),
            message: String::new(),
            retryable: false,
        });
        assert!(matches!(RelayFailure::classify(&error), RelayFailure::KeyDead));
    }
    let timeout = anyhow::anyhow!("administrator request timed out");
    assert!(matches!(RelayFailure::classify(&timeout), RelayFailure::Unavailable(_)));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_grant_finishing_while_the_sweep_waits_stays_open() {
    let fixture = fixture().await;
    let keyless = keyless_device(&fixture).await;
    let (access, namespace, instance, admin) =
        (&keyless.access, keyless.namespace, &keyless.instance, &keyless.admin);
    let device = &access.device;
    let now = unix_now();
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
            relay_instance: instance,
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
        admin,
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
