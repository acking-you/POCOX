//! What the backend must not assume about the relay's answers: lost state, a
//! changed instance, credential identity, namespace drift and absence in a
//! listing.

use std::time::Duration;

use pb_mapper_testkit::{Relay, TEST_ADMIN_KEY};
use pocox_account_proto::http::RelayCredentialResponse;
use pocox_backend::pairing::PairingSettings;
use pocox_pb::RelaySession;
use pocox_store::pairing::{KeyState, NewGrant};
use reqwest::StatusCode;

use super::support::{op, test_settings, Device, Harness};

/// No cached relay facts, so a changed relay is seen on the very next request.
fn fresh_relay_facts() -> PairingSettings {
    PairingSettings {
        relay_status_ttl: Duration::ZERO,
        ..test_settings()
    }
}

fn unix_now() -> i64 {
    time::OffsetDateTime::now_utc().unix_timestamp()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_first_keys_in_a_group_allocate_one_namespace() {
    let harness = Harness::start().await;
    let first = Device::new(&harness, "first").await;
    let mut second = Device::new(&harness, "second").await;
    second.link_to(&first).await;
    first.activate(None).await.expect(StatusCode::OK);
    let (first_key, second_key) = tokio::join!(first.relay_key(), second.relay_key());
    assert_ne!(first_key.credential, second_key.credential);
    assert_eq!(first_key.namespace, second_key.namespace);
    let live = harness.live_keys().await;
    let stored: u64 = harness
        .store
        .user_namespace(first.user())
        .await
        .expect("namespace")
        .expect("set")
        .parse()
        .expect("canonical decimal");
    assert_eq!(live.len(), 2);
    assert!(live.iter().all(|key| key.namespace == stored));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_repeated_namespace_allocates_again_and_two_users_never_share_one() {
    let harness = Harness::with_settings(fresh_relay_facts()).await;
    let first = Device::activated(&harness, "first").await;
    first.relay_key().await;
    let first_namespace = harness
        .store
        .user_namespace(first.user())
        .await
        .expect("namespace")
        .expect("set");

    // The relay lost its state directory and starts numbering again.
    let reborn = Relay::start("pocox-reborn").await;
    harness.link.point_at(reborn.addr());
    let second = Device::activated(&harness, "second").await;
    second.relay_key().await;
    let second_namespace = harness
        .store
        .user_namespace(second.user())
        .await
        .expect("namespace")
        .expect("set");
    assert_ne!(first_namespace, second_namespace, "the repeat was refused and asked again");
    assert_eq!(
        harness
            .store
            .user_namespace(first.user())
            .await
            .expect("namespace"),
        Some(first_namespace),
        "the first user did not move"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn lost_relay_state_leaves_the_grant_pending_and_allocates_no_replacement() {
    let harness = Harness::with_settings(fresh_relay_facts()).await;
    let device = Device::activated(&harness, "device").await;
    device.relay_key().await;
    let namespace = harness
        .store
        .user_namespace(device.user())
        .await
        .expect("namespace")
        .expect("set");

    let reborn = Relay::start("pocox-amnesia").await;
    harness.link.point_at(reborn.addr());
    for _ in 0..2 {
        device
            .get("/v1/relay")
            .await
            .expect_error(StatusCode::SERVICE_UNAVAILABLE, "relay_state_lost");
    }
    assert_eq!(
        harness
            .store
            .user_namespace(device.user())
            .await
            .expect("namespace"),
        Some(namespace.clone()),
        "moving a user's namespace would split its group"
    );
    let open = harness
        .store
        .generation_key(device.id(), device.session.generation)
        .await
        .expect("row")
        .expect("the grant stays open");
    assert_eq!(open.state, KeyState::Granting);

    // Operators restore the relay's state: the same number, and work resumes.
    harness.link.point_at(harness.relay.addr());
    let key = device.relay_key().await;
    assert!(harness.credential_works(&key.credential).await);
    assert_eq!(
        harness
            .store
            .user_namespace(device.user())
            .await
            .expect("namespace"),
        Some(namespace)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_changed_instance_kills_stored_keys_and_keeps_the_namespace() {
    let harness = Harness::with_settings(fresh_relay_facts()).await;
    let device = Device::activated(&harness, "device").await;
    let old = device.relay_key().await;
    let namespace = harness
        .store
        .user_namespace(device.user())
        .await
        .expect("namespace");

    harness
        .relay
        .auth()
        .reset(harness.relay.admin_context())
        .await
        .expect("a reset changes the instance id");

    let new: RelayCredentialResponse = device.relay_key().await;
    assert_ne!(new.credential, old.credential);
    assert!(harness.credential_works(&new.credential).await);
    assert_eq!(
        harness
            .store
            .user_namespace(device.user())
            .await
            .expect("namespace"),
        namespace
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stored_key_id_never_touches_whichever_key_holds_it_after_an_instance_change() {
    let harness = Harness::with_settings(fresh_relay_facts()).await;
    let host = Device::activated(&harness, "host").await;
    let mut member = Device::activated(&harness, "member").await;
    member.link_to(&host).await;
    member.relay_key().await;
    let row = harness
        .store
        .generation_key(member.id(), member.session.generation)
        .await
        .expect("row")
        .expect("key");
    let stored_id: u64 = row.key_id.as_deref().expect("id").parse().expect("number");

    // A relay whose key ids started over, where another tenant now holds that id.
    let reborn = Relay::start("pocox-reused-ids").await;
    let reborn_admin = RelaySession::new(reborn.addr().to_string(), TEST_ADMIN_KEY);
    let mut tenant = None;
    for _ in 0..64 {
        let issued = pocox_pb::issue_credential(
            &reborn_admin,
            Duration::from_secs(600),
            Some("another-tenant".to_string()),
        )
        .await
        .expect("tenant key");
        if issued.key_id == stored_id {
            tenant = Some(issued);
            break;
        }
    }
    let tenant = tenant.expect("the fresh table hands out the stored id again");
    harness.link.point_at(reborn.addr());

    // The removal completes: the old key is dead with its instance.
    host.remove(member.id(), &op()).await.expect(StatusCode::OK);
    let live = pocox_pb::live_credentials(&reborn_admin)
        .await
        .expect("listing");
    let still = live
        .iter()
        .find(|key| key.key_id == tenant.key_id)
        .expect("the other tenant's key was never revoked");
    assert_eq!(still.expires_at, tenant.expires_at, "nor renewed");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_recovered_credential_with_an_unexpected_identity_is_never_exposed() {
    let harness = Harness::start().await;
    let device = Device::activated(&harness, "device").await;
    device.relay_key().await;
    let row = harness
        .store
        .generation_key(device.id(), device.session.generation)
        .await
        .expect("row")
        .expect("key");

    // A stored id that now names another tenant's key, on the same instance.
    let foreign = pocox_pb::issue_credential(
        &harness.admin(),
        Duration::from_secs(600),
        Some("another-tenant".to_string()),
    )
    .await
    .expect("foreign key");
    sqlx::query("UPDATE device_relay_keys SET key_id = ?1 WHERE grant_id = ?2")
        .bind(foreign.key_id.to_string())
        .bind(&row.grant_id)
        .execute(harness.store.pool())
        .await
        .expect("edit");
    harness.relaunch().await;

    let got: RelayCredentialResponse = device.relay_key().await;
    assert_ne!(got.credential, foreign.credential, "another tenant's credential never leaves");
    let original = harness
        .store
        .grant(&row.grant_id)
        .await
        .expect("row")
        .expect("row");
    assert_eq!(original.state, KeyState::Dead);
    let live = harness.live_keys().await;
    assert!(live.iter().any(|key| key.key_id == foreign.key_id), "and it is not revoked either");
    assert!(harness.credential_works(&got.credential).await);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn namespace_drift_on_a_renewal_revokes_and_reissues_into_the_stored_namespace() {
    let harness = Harness::start().await;
    let device = Device::activated(&harness, "device").await;
    device.relay_key().await;
    let row = harness
        .store
        .generation_key(device.id(), device.session.generation)
        .await
        .expect("row")
        .expect("key");
    let admin = harness.admin();
    let stored: u64 = row.namespace.parse().expect("namespace");

    // The key on record turns out to live in another namespace.
    pocox_pb::revoke_credential(&admin, row.key_id.as_deref().expect("id").parse().expect("id"))
        .await
        .expect("revoke");
    let other = pocox_pb::allocate_namespace(&admin)
        .await
        .expect("namespace");
    let drifted = pocox_pb::issue_credential_in_namespace(
        &admin,
        other,
        Duration::from_secs(600),
        Some(row.label.clone()),
    )
    .await
    .expect("key");
    sqlx::query("UPDATE device_relay_keys SET key_id = ?1 WHERE grant_id = ?2")
        .bind(drifted.key_id.to_string())
        .bind(&row.grant_id)
        .execute(harness.store.pool())
        .await
        .expect("edit");
    harness.relaunch().await;

    let got = device.relay_key().await;
    assert_ne!(got.credential, drifted.credential);
    assert!(!harness.credential_works(&drifted.credential).await, "the drifted key was revoked");
    let live = harness.live_keys().await;
    let current = live
        .iter()
        .find(|key| {
            key.label
                .as_deref()
                .is_some_and(|label| label.starts_with("pcxd:"))
                && key.key_id != drifted.key_id
        })
        .expect("a reissued key");
    assert_eq!(current.namespace, stored, "reissued where the user lives");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn namespace_drift_in_a_listing_revokes_the_key() {
    let harness = Harness::start().await;
    let device = Device::activated(&harness, "device").await;
    device.relay_key().await;
    let row = harness
        .store
        .generation_key(device.id(), device.session.generation)
        .await
        .expect("row")
        .expect("key");
    let admin = harness.admin();
    pocox_pb::revoke_credential(&admin, row.key_id.as_deref().expect("id").parse().expect("id"))
        .await
        .expect("revoke");
    let other = pocox_pb::allocate_namespace(&admin)
        .await
        .expect("namespace");
    let drifted = pocox_pb::issue_credential_in_namespace(
        &admin,
        other,
        Duration::from_secs(600),
        Some(row.label.clone()),
    )
    .await
    .expect("key");
    sqlx::query("UPDATE device_relay_keys SET key_id = ?1 WHERE grant_id = ?2")
        .bind(drifted.key_id.to_string())
        .bind(&row.grant_id)
        .execute(harness.store.pool())
        .await
        .expect("edit");

    harness.restart().await;
    assert!(!harness.credential_works(&drifted.credential).await);
    let ended = harness
        .store
        .grant(&row.grant_id)
        .await
        .expect("row")
        .expect("row");
    assert_eq!(ended.state, KeyState::Revoked);
    let next = device.relay_key().await;
    assert!(harness.credential_works(&next.credential).await);
}

/// The state a crash leaves: a grant on record, and a key the relay issued for
/// it whose answer never reached the database.
async fn crashed_grant(
    harness: &Harness,
    device: &Device<'_>,
) -> (String, pocox_pb::IssuedCredential) {
    let namespace = pocox_pb::allocate_namespace(&harness.admin())
        .await
        .expect("namespace");
    let namespace_text = namespace.to_string();
    let claimed = harness
        .store
        .claim_namespace(device.user(), &namespace_text)
        .await
        .expect("claim");
    assert_eq!(claimed, pocox_store::pairing::NamespaceClaim::Fixed(namespace_text.clone()));
    let grant_id = "0123456789abcdef".to_string();
    let label = format!("pcxd:{}:{}:{grant_id}", device.id(), device.session.generation);
    let instance = pocox_pb::relay_instance_id(&harness.admin())
        .await
        .expect("instance");
    harness
        .store
        .open_grant(NewGrant {
            grant_id: &grant_id,
            device_id: device.id(),
            generation: device.session.generation,
            user_id: device.user(),
            namespace: &namespace_text,
            relay_instance: &instance,
            label: &label,
            slot_limit: 1000,
            now: unix_now(),
        })
        .await
        .expect("grant");
    let issued = pocox_pb::issue_credential_in_namespace(
        &harness.admin(),
        namespace,
        Duration::from_secs(600),
        Some(label),
    )
    .await
    .expect("the relay applied it");
    (grant_id, issued)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_lost_issue_response_is_found_by_label_and_never_minted_twice() {
    let harness = Harness::with_settings(fresh_relay_facts()).await;
    let device = Device::activated(&harness, "device").await;
    let (_, issued) = crashed_grant(&harness, &device).await;

    let got = device.relay_key().await;
    assert_eq!(got.credential, issued.credential, "the same key, recovered by renewing it");
    assert!(
        harness
            .live_keys()
            .await
            .iter()
            .filter(|key| key
                .label
                .as_deref()
                .is_some_and(|label| label.starts_with("pcxd:")))
            .count()
            == 1
    );
    let row = harness
        .store
        .generation_key(device.id(), device.session.generation)
        .await
        .expect("row")
        .expect("key");
    assert_eq!(row.state, KeyState::Active);
    assert_eq!(row.key_id, Some(issued.key_id.to_string()), "on record before it was exposed");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_walk_that_misses_a_key_is_not_proof_it_is_absent() {
    let harness = Harness::with_settings(fresh_relay_facts()).await;
    let device = Device::activated(&harness, "device").await;
    let (_, issued) = crashed_grant(&harness, &device).await;

    // The relay's listing pages by position, so one walk can skip a row. Here the
    // first walk reports nothing at all: two status reads, then one empty
    // listing.
    let empty = Relay::start("pocox-skipped-row").await;
    let real = harness.relay.addr();
    harness.link.then(&[real, real, empty.addr()]);

    let got = device.relay_key().await;
    assert_eq!(got.credential, issued.credential, "repeated the walk rather than minting");
    let ours = harness
        .live_keys()
        .await
        .into_iter()
        .filter(|key| {
            key.label
                .as_deref()
                .is_some_and(|label| label.starts_with("pcxd:"))
        })
        .count();
    assert_eq!(ours, 1, "no second key was minted");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_restart_adopts_or_revokes_what_a_crash_left_behind() {
    let harness = Harness::with_settings(fresh_relay_facts()).await;

    // Adopted: the generation still stands, so the key goes on record. No client
    // saw it.
    let standing = Device::activated(&harness, "standing").await;
    let (grant, issued) = crashed_grant(&harness, &standing).await;
    harness.restart().await;
    let row = harness
        .store
        .grant(&grant)
        .await
        .expect("row")
        .expect("row");
    assert_eq!(row.state, KeyState::Active);
    assert_eq!(row.key_id, Some(issued.key_id.to_string()));

    // Revoked: the device moved on while the grant was in doubt. Its leave deals
    // with the unknown key by label before reporting anything.
    let host = Device::activated(&harness, "host").await;
    let mut moved = Device::activated(&harness, "moved").await;
    moved.link_to(&host).await;
    let row = {
        let key = moved.relay_key().await;
        assert!(harness.credential_works(&key.credential).await);
        harness
            .store
            .generation_key(moved.id(), moved.session.generation)
            .await
            .expect("row")
            .expect("key")
    };
    let extra_label = format!("pcxd:{}:{}:ffffffffffffffff", moved.id(), moved.session.generation);
    let orphan = pocox_pb::issue_credential_in_namespace(
        &harness.admin(),
        row.namespace.parse().expect("number"),
        Duration::from_secs(600),
        Some(extra_label),
    )
    .await
    .expect("a key no grant on record names");
    harness.restart().await;
    assert!(!harness.credential_works(&orphan.credential).await, "no owner, so no client gets it");
    assert!(
        harness
            .store
            .grant(&row.grant_id)
            .await
            .expect("row")
            .expect("row")
            .state
            == KeyState::Active
    );

    // A GitHub account's key shares the table and is none of this worker's
    // business.
    let github = pocox_pb::issue_credential(
        &harness.admin(),
        Duration::from_secs(600),
        Some("pcx-account:someone".to_string()),
    )
    .await
    .expect("key");
    harness.restart().await;
    assert!(harness.credential_works(&github.credential).await);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_key_gone_from_two_walks_is_recorded_as_gone() {
    let harness = Harness::with_settings(fresh_relay_facts()).await;
    let device = Device::activated(&harness, "device").await;
    device.relay_key().await;
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
    harness.restart().await;
    let ended = harness
        .store
        .grant(&row.grant_id)
        .await
        .expect("row")
        .expect("row");
    assert_eq!(ended.state, KeyState::Expired);
    let next = device.relay_key().await;
    assert!(harness.credential_works(&next.credential).await);
}
