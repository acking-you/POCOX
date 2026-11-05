//! Linking: groups share a namespace, stale confirmations are refused, and
//! retries and races converge without merging groups.

use pocox_account_proto::pairing::{OperationStatus, OperationView, PreviewResponse};
use pocox_pb::RegisterOptions;
use reqwest::StatusCode;
use serde_json::json;
use tokio::net::TcpListener;

use super::support::{op, Device, Harness};

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
async fn linked_devices_share_a_namespace_and_other_groups_see_nothing() {
    let harness = Harness::start().await;
    let host = Device::activated(&harness, "host").await;
    let mut phone = Device::new(&harness, "phone").await;
    let outsider = Device::activated(&harness, "outsider").await;

    let preview = phone.ticket_for(&host).await;
    assert_eq!(preview.devices.len(), 1);
    assert_eq!(preview.devices[0].name, "host");
    assert!(!preview.already_member);
    assert_eq!(phone.user(), phone.session.account_id);

    let view = phone.link_to(&host).await;
    assert_eq!(view.status, OperationStatus::Completed);
    assert_eq!(phone.user(), host.user(), "the linked device moved into the host's user");
    assert!(phone.session.activated, "confirming a link activates this device");

    let host_key = host.relay_key().await;
    let phone_key = phone.relay_key().await;
    assert_ne!(host_key.credential, phone_key.credential, "each device has its own key");
    assert_eq!(host_key.namespace, phone_key.namespace);

    let outsider_key = outsider.relay_key().await;
    assert_ne!(outsider_key.namespace, host_key.namespace);

    let key = format!("pcxu:{}:host:app:default", host_key.namespace);
    let _registration = register(&harness, &host_key.credential, &key).await;
    assert_eq!(harness.visible_services(&phone_key.credential).await, std::slice::from_ref(&key));
    assert!(
        harness
            .visible_services(&outsider_key.credential)
            .await
            .is_empty(),
        "another group's key sees nothing in this namespace"
    );

    // A peer reaches the service; another group's key cannot, by naming it
    // directly.
    let reach = |credential: String, key: String| {
        let harness = &harness;
        async move {
            let session = pocox_pb::RelaySession::new(harness.relay.addr().to_string(), credential);
            let reservation = TcpListener::bind("127.0.0.1:0").await.expect("reserve");
            let local_addr = reservation.local_addr().expect("addr").to_string();
            drop(reservation);
            tokio::time::timeout(
                std::time::Duration::from_secs(5),
                pocox_pb::subscribe(&session, pocox_pb::SubscribeOptions {
                    key,
                    local_addr,
                }),
            )
            .await
            .is_ok_and(|subscribed| subscribed.is_ok())
        }
    };
    assert!(reach(phone_key.credential.clone(), key.clone()).await);
    assert!(!reach(outsider_key.credential.clone(), key.clone()).await);

    let listed = phone.get("/v1/services").await.expect(StatusCode::OK);
    assert_eq!(listed.body["services"][0]["device"], "host");
    let listed = outsider.get("/v1/services").await.expect(StatusCode::OK);
    assert_eq!(listed.body["services"], json!([]));

    // A hostile key name inside its own namespace is attributed to no one else.
    let phantom = format!("pcxu:{}:phantom:app:default", host_key.namespace);
    let _phantom = register(&harness, &outsider_key.credential, &phantom).await;
    let listed = host.get("/v1/services").await.expect(StatusCode::OK);
    assert_eq!(listed.body["services"].as_array().expect("list").len(), 1);

    // The other group's devices stay out of reach by every route.
    let list = host.get("/v1/devices").await.expect(StatusCode::OK);
    let names: Vec<&str> = list.body["devices"]
        .as_array()
        .expect("devices")
        .iter()
        .map(|device| device["name"].as_str().expect("name"))
        .collect();
    assert!(names.contains(&"host") && names.contains(&"phone") && !names.contains(&"outsider"));
    outsider
        .remove(host.id(), &op())
        .await
        .expect_error(StatusCode::NOT_FOUND, "not_found");
    harness
        .call(
            reqwest::Method::PATCH,
            &format!("/v1/devices/{}", host.id()),
            Some(outsider.token()),
            Some(json!({ "name": "stolen" })),
        )
        .await
        .expect_error(StatusCode::NOT_FOUND, "not_found");
    outsider
        .post(
            &format!("/v1/devices/{}/restore", host.id()),
            json!({ "request_id": "x", "operation_id": op(), "allow": true }),
        )
        .await
        .expect_error(StatusCode::NOT_FOUND, "not_found");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_device_with_peers_leaves_only_by_explicit_confirmation_and_groups_never_merge() {
    let harness = Harness::start().await;
    let a = Device::activated(&harness, "a").await;
    let mut b = Device::activated(&harness, "b").await;
    b.link_to(&a).await;
    let c = Device::activated(&harness, "c").await;
    let mut d = Device::activated(&harness, "d").await;
    d.link_to(&c).await;

    // b has a peer and did not say it leaves it.
    let preview = b.ticket_for(&c).await;
    b.link_with(&preview.ticket, &op(), false)
        .await
        .expect_error(StatusCode::CONFLICT, "already_linked");

    let moved: OperationView = b
        .link_with(&preview.ticket, &op(), true)
        .await
        .expect(StatusCode::OK)
        .parse();
    assert_eq!(moved.status, OperationStatus::Completed);
    b.refresh().await.expect(StatusCode::OK);
    assert_eq!(b.user(), c.user());

    // Only b moved: its old peer stays where it was, and d's group gained only b.
    let list = a.get("/v1/devices").await.expect(StatusCode::OK);
    assert_eq!(list.body["devices"].as_array().expect("devices").len(), 1);
    let list = c.get("/v1/devices").await.expect(StatusCode::OK);
    assert_eq!(list.body["devices"].as_array().expect("devices").len(), 3);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_changed_target_requires_a_new_preview_before_anything_is_revoked() {
    let harness = Harness::start().await;
    let b = Device::activated(&harness, "b").await;
    let key = b.relay_key().await;
    let mut a = Device::activated(&harness, "a").await;
    let elsewhere = Device::activated(&harness, "elsewhere").await;

    let preview = b.ticket_for(&a).await;
    a.link_to(&elsewhere).await;
    b.link_with(&preview.ticket, &op(), false)
        .await
        .expect_error(StatusCode::CONFLICT, "preview_stale");
    assert!(harness.credential_works(&key.credential).await, "a refused link revokes nothing");

    // A pause and a rotation each kill the ticket and the code.
    let paused = Device::activated(&harness, "paused").await;
    let preview = b.ticket_for(&paused).await;
    let pause = json!({ "paused": true });
    harness
        .call(reqwest::Method::PATCH, "/v1/pair/code", Some(paused.token()), Some(pause))
        .await
        .expect(StatusCode::OK);
    b.link_with(&preview.ticket, &op(), false)
        .await
        .expect_error(StatusCode::CONFLICT, "preview_stale");
    let code = paused.code().await;
    b.preview(&code)
        .await
        .expect_error(StatusCode::FORBIDDEN, "linking_paused");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn opposite_direction_links_converge_and_a_repeat_is_a_no_op() {
    let harness = Harness::start().await;
    let mut a = Device::activated(&harness, "a").await;
    let mut b = Device::activated(&harness, "b").await;
    let a_ticket = a.ticket_for(&b).await;
    let b_ticket = b.ticket_for(&a).await;

    let (a_operation, b_operation) = (op(), op());
    let (a_reply, b_reply) = tokio::join!(
        a.link_with(&a_ticket.ticket, &a_operation, false),
        b.link_with(&b_ticket.ticket, &b_operation, false),
    );
    let settled = [&a_reply, &b_reply]
        .iter()
        .filter(|reply| reply.status == StatusCode::OK)
        .count();
    assert!(settled >= 1, "one of them commits: {} / {}", a_reply.body, b_reply.body);
    for reply in [&a_reply, &b_reply] {
        assert!(
            reply.status == StatusCode::OK
                || reply.error() == "transition_pending"
                || reply.error() == "session_stale"
                || reply.error() == "preview_stale",
            "the loser retries or re-previews: {}",
            reply.body
        );
    }
    a.refresh().await.expect(StatusCode::OK);
    b.refresh().await.expect(StatusCode::OK);
    assert_eq!(a.user(), b.user(), "they end up in one group, not swapped");

    // Linking again to a device already in this user changes nothing.
    let preview: PreviewResponse = a.ticket_for(&b).await;
    assert!(preview.already_member);
    let revision = harness.store.group_size(a.user()).await.expect("size");
    let again: OperationView = a
        .link_with(&preview.ticket, &op(), false)
        .await
        .expect(StatusCode::OK)
        .parse();
    assert_eq!(again.status, OperationStatus::Completed);
    assert_eq!(harness.store.group_size(a.user()).await.expect("size"), revision);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn concurrent_confirmed_links_never_lose_a_revision_check() {
    let harness = Harness::start().await;
    let target = Device::activated(&harness, "target").await;
    let mut joiners = Vec::new();
    for name in ["one", "two", "three", "four"] {
        joiners.push(Device::activated(&harness, name).await);
    }
    let mut tickets = Vec::new();
    for joiner in &joiners {
        tickets.push(joiner.ticket_for(&target).await.ticket);
    }
    let operations: Vec<String> = joiners.iter().map(|_| op()).collect();
    let mut attempts = Vec::new();
    for ((joiner, ticket), operation) in joiners.iter().zip(&tickets).zip(&operations) {
        attempts.push(joiner.link_with(ticket, operation, false));
    }
    let replies = futures_join_all(attempts).await;
    let mut winners = 0;
    for reply in &replies {
        match reply.status {
            StatusCode::OK => winners += 1,
            _ => assert!(
                matches!(reply.error(), "preview_stale" | "transition_pending"),
                "a loser must re-preview or wait: {}",
                reply.body
            ),
        }
    }
    assert_eq!(winners, 1, "each confirmed revision admits one link");
    let joined = harness.store.group_size(target.user()).await.expect("size");
    assert_eq!(joined, 2);

    // A loser that previews again gets in, with nothing lost.
    for joiner in joiners.iter_mut() {
        joiner.refresh().await.expect(StatusCode::OK);
        if joiner.user() != target.user() {
            joiner.link_to(&target).await;
        }
    }
    assert_eq!(harness.store.group_size(target.user()).await.expect("size"), 5);
}

async fn futures_join_all<F: std::future::Future>(futures: Vec<F>) -> Vec<F::Output> {
    let mut out = Vec::with_capacity(futures.len());
    let mut pinned: Vec<_> = futures.into_iter().map(Box::pin).collect();
    let mut done: Vec<Option<F::Output>> = pinned.iter().map(|_| None).collect();
    std::future::poll_fn(|context| {
        let mut pending = false;
        for (future, slot) in pinned.iter_mut().zip(done.iter_mut()) {
            if slot.is_none() {
                match future.as_mut().poll(context) {
                    std::task::Poll::Ready(value) => *slot = Some(value),
                    std::task::Poll::Pending => pending = true,
                }
            }
        }
        if pending {
            std::task::Poll::Pending
        } else {
            std::task::Poll::Ready(())
        }
    })
    .await;
    for slot in done {
        out.push(slot.expect("all ready"));
    }
    out
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_group_stops_at_its_size_limit() {
    let harness = Harness::with_settings(pocox_backend::pairing::PairingSettings {
        max_group_size: 2,
        ..super::support::test_settings()
    })
    .await;
    let host = Device::activated(&harness, "host").await;
    let mut second = Device::activated(&harness, "second").await;
    second.link_to(&host).await;
    let third = Device::activated(&harness, "third").await;
    let preview = third.ticket_for(&host).await;
    third
        .link_with(&preview.ticket, &op(), false)
        .await
        .expect_error(StatusCode::CONFLICT, "group_full");
    third.relay_key().await;
    assert_eq!(harness.store.group_size(host.user()).await.expect("size"), 2);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_operation_id_is_idempotent_and_bound_to_its_input() {
    let harness = Harness::start().await;
    let a = Device::activated(&harness, "a").await;
    let mut b = Device::activated(&harness, "b").await;
    let other = Device::activated(&harness, "other").await;
    let preview = b.ticket_for(&a).await;
    let id = op();

    let first: OperationView = b
        .link_with(&preview.ticket, &id, false)
        .await
        .expect(StatusCode::OK)
        .parse();
    assert_eq!(first.status, OperationStatus::Completed);
    assert!(first.session.is_none(), "a JWT never gets another JWT");

    // The old session is gone with its generation; the secret reads the result.
    b.link_with(&preview.ticket, &id, false)
        .await
        .expect_error(StatusCode::UNAUTHORIZED, "session_stale");
    let read: OperationView = b.operation(&id).await.expect(StatusCode::OK).parse();
    assert_eq!(read.status, OperationStatus::Completed);
    let session = read.session.expect("a current secret gets a fresh session");
    assert_eq!(session.account_id, a.user());

    // A duplicate after refreshing reads the result and applies nothing.
    b.refresh().await.expect(StatusCode::OK);
    assert_ne!(session.token, b.token(), "a result stores no bearer material");
    let generation = b.session.generation;
    let again: OperationView = b
        .link_with(&preview.ticket, &id, false)
        .await
        .expect(StatusCode::OK)
        .parse();
    assert_eq!(again.status, OperationStatus::Completed);
    b.refresh().await.expect(StatusCode::OK);
    assert_eq!(b.session.generation, generation, "the mutation was not applied twice");

    // The same id with other input fails instead of applying it.
    let elsewhere = b.ticket_for(&other).await;
    b.link_with(&elsewhere.ticket, &id, true)
        .await
        .expect_error(StatusCode::CONFLICT, "operation_conflict");

    // Knowing an operation id yields nothing to another device.
    other
        .operation(&id)
        .await
        .expect_error(StatusCode::NOT_FOUND, "operation_unknown");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn linking_into_an_inactive_device_leaves_it_inactive_and_its_purge_harms_no_one() {
    let harness = Harness::start().await;
    let first_screen = Device::new(&harness, "first screen").await;
    let mut joiner = Device::activated(&harness, "joiner").await;
    joiner.link_to(&first_screen).await;

    let list = joiner.get("/v1/devices").await.expect(StatusCode::OK);
    let inactive = list.body["devices"]
        .as_array()
        .expect("devices")
        .iter()
        .find(|device| device["name"] == "first screen")
        .expect("the inactive device is listed")
        .clone();
    assert_eq!(inactive["activated"], false, "peers see it as not set up");

    // It still has no authority of its own until someone presses Continue.
    first_screen
        .get("/v1/relay")
        .await
        .expect_error(StatusCode::FORBIDDEN, "device_not_activated");
    let key = joiner.relay_key().await;

    // Nobody activates it: retention removes it, and the joiner keeps user and
    // namespace.
    let (before_namespace, user) = (
        harness
            .store
            .user_namespace(joiner.user())
            .await
            .expect("namespace"),
        joiner.user(),
    );
    let thirty_one_days = 31 * 24 * 3600;
    let future = time::OffsetDateTime::now_utc().unix_timestamp() + thirty_one_days;
    let purged = harness.store.purge_pairing(future).await.expect("purge");
    assert_eq!(purged.devices, 1);
    assert_eq!(harness.store.group_size(user).await.expect("size"), 1);
    assert_eq!(harness.store.user_namespace(user).await.expect("namespace"), before_namespace);
    assert!(harness.credential_works(&key.credential).await);
}
