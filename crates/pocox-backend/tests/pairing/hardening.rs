//! What a stolen or restored token can get out of the backend, a relay that
//! says nothing, and the contract a device's client builds on.

use std::time::{Duration, Instant};

use pocox_account_proto::pairing::{OperationView, PreviewResponse};
use pocox_auth::Claims;
use pocox_backend::pairing::PairingSettings;
use reqwest::{Method, StatusCode};
use serde_json::json;
use tokio::net::TcpListener;

use super::support::{hint, mint, op, test_settings, Device, Harness};

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_token_cannot_renew_itself_without_the_secret() {
    let harness = Harness::start().await;
    let mut lone = Device::activated(&harness, "lone").await;

    // A restored config.toml holds a live JWT and no secret. A no-op on a device
    // alone, fresh ids and all, must not hand it a new one, or it would never
    // expire.
    for _ in 0..3 {
        let view: OperationView = lone.leave(&op()).await.expect(StatusCode::OK).parse();
        assert!(view.session.is_none(), "a no-op moved nobody");
    }

    // The same for a no-op link, a replay, and removing a peer: none moved the
    // caller.
    let host = Device::activated(&harness, "host").await;
    lone.link_to(&host).await;
    let preview = lone.ticket_for(&host).await;
    assert!(preview.already_member);
    let view: OperationView = lone
        .link_with(&preview.ticket, &op(), false)
        .await
        .expect(StatusCode::OK)
        .parse();
    assert!(view.session.is_none());
    let peer = {
        let mut peer = Device::activated(&harness, "peer").await;
        peer.link_to(&host).await;
        peer
    };
    let view: OperationView = lone
        .remove(peer.id(), &op())
        .await
        .expect(StatusCode::OK)
        .parse();
    assert!(view.session.is_none());

    // A real move kills the old token, so its answer carries the next one once.
    // Asking again with the same id gets the result and no session.
    let id = op();
    let view: OperationView = lone.leave(&id).await.expect(StatusCode::OK).parse();
    let moved = view.session.expect("the request that moved it");
    lone.session = moved;
    let replay: OperationView = lone.leave(&id).await.expect(StatusCode::OK).parse();
    assert!(replay.session.is_none());

    // The secret is what gets a session whenever it likes.
    let read: OperationView = lone.operation(&id).await.expect(StatusCode::OK).parse();
    assert!(read.session.is_some());
}

/// A listener that accepts connections and never says anything.
async fn silent_relay() -> (std::net::SocketAddr, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("listener");
    let addr = listener.local_addr().expect("addr");
    let task = tokio::spawn(async move {
        let mut held = Vec::new();
        while let Ok((stream, _)) = listener.accept().await {
            held.push(stream);
        }
    });
    (addr, task)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_silent_relay_holds_no_request_and_still_ends_an_intruders_session_at_once() {
    let harness = Harness::with_settings(PairingSettings {
        foreground_wait: Duration::from_secs(2),
        relay_probe_wait: Duration::from_millis(300),
        ..test_settings()
    })
    .await;
    let host = Device::activated(&harness, "host").await;
    let mut intruder = Device::activated(&harness, "intruder").await;
    intruder.link_to(&host).await;
    intruder.relay_key().await;
    let host_key_relay = host.get("/v1/relay").await.expect(StatusCode::OK);

    let (silent, _task) = silent_relay().await;
    harness.link.point_at(silent);
    // Wait out the cached status, so these requests really do face the silent
    // relay.
    tokio::time::sleep(Duration::from_millis(50)).await;
    harness.settings.lock().expect("settings").relay_status_ttl = Duration::ZERO;
    harness.relaunch().await;

    // The removal is durable and its subject's session is dead before any relay
    // answer, and the request comes back within the bounds, not the SDK's 30
    // seconds.
    let started = Instant::now();
    let id = op();
    host.remove(intruder.id(), &id)
        .await
        .expect(StatusCode::ACCEPTED);
    assert!(started.elapsed() < Duration::from_secs(5), "took {:?}", started.elapsed());
    assert!(harness.store.operation(&id).await.expect("row").is_some());
    intruder
        .get("/v1/me")
        .await
        .expect_error(StatusCode::UNAUTHORIZED, "session_stale");

    // Nothing else waits on it either.
    let started = Instant::now();
    Device::new(&harness, "new here").await;
    assert!(host_key_relay.body["credential"].is_string());
    let reply = Device::activated(&harness, "first key")
        .await
        .get("/v1/relay")
        .await;
    assert_eq!(reply.status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(reply.error(), "relay_unavailable");
    assert!(started.elapsed() < Duration::from_secs(7), "took {:?}", started.elapsed());
    harness.link.point_at(harness.relay.addr());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_no_op_link_still_activates_because_the_user_confirmed_it() {
    let harness = Harness::start().await;
    let first_screen = Device::new(&harness, "first screen").await;
    let mut joiner = Device::activated(&harness, "joiner").await;
    joiner.link_to(&first_screen).await;
    first_screen
        .get("/v1/relay")
        .await
        .expect_error(StatusCode::FORBIDDEN, "device_not_activated");

    // The first screen enters the code of the device that joined it, and confirms.
    let preview = first_screen.ticket_for(&joiner).await;
    assert!(preview.already_member);
    let body = json!({
        "ticket": preview.ticket,
        "operation_id": op(),
        "hint": hint(40),
    });
    first_screen
        .post("/v1/pair/link", body)
        .await
        .expect(StatusCode::OK);
    let key = first_screen.relay_key().await;
    assert!(harness.credential_works(&key.credential).await);

    // It bound the hint too.
    let device = harness
        .store
        .pairing_device(first_screen.id())
        .await
        .expect("row")
        .expect("device");
    assert!(device.hardware_lookup.is_some());
    assert!(device.activated_at.is_some());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_requesters_own_group_also_has_to_be_still() {
    let harness = Harness::start().await;
    let target = Device::activated(&harness, "target").await;
    let code = target.code().await;
    let requester = Device::new(&harness, "requester").await;
    let preview: PreviewResponse = requester
        .preview(&code)
        .await
        .expect(StatusCode::OK)
        .parse();

    // Someone is on the way into the requester's group, waiting on the relay.
    let joiner = Device::activated(&harness, "joiner").await;
    joiner.relay_key().await;
    let ticket = joiner.ticket_for(&requester).await;
    harness.link.cut();
    joiner
        .link_with(&ticket.ticket, &op(), false)
        .await
        .expect(StatusCode::ACCEPTED);

    requester
        .post(
            "/v1/pair/restore",
            json!({
                "ticket": preview.ticket,
                "target_device_id": target.id(),
                "operation_id": op(),
            }),
        )
        .await
        .expect_error(StatusCode::CONFLICT, "transition_pending");

    // Retention holds that group still as well: a purge moving its revision would
    // fail the operation in flight.
    let revision = |harness: &'_ Harness, device: String| {
        let store = harness.store.clone();
        async move {
            let device = store
                .pairing_device(&device)
                .await
                .expect("row")
                .expect("device");
            store
                .device_access(&device.id, device.session_generation)
                .await
                .expect("access")
                .expect("access")
                .user
                .membership_revision
        }
    };
    let before = revision(&harness, requester.id().to_string()).await;
    let later = time::OffsetDateTime::now_utc().unix_timestamp() + 31 * 24 * 3600;
    harness.store.purge_pairing(later).await.expect("purge");
    assert!(harness
        .store
        .pairing_device(requester.id())
        .await
        .expect("row")
        .is_some());
    assert_eq!(revision(&harness, requester.id().to_string()).await, before);
    harness.link.point_at(harness.relay.addr());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_removed_device_keeps_its_use_based_retention_and_says_removed() {
    let harness = Harness::start().await;
    let host = Device::activated(&harness, "host").await;
    let mut removed = Device::activated(&harness, "removed").await;
    removed.link_to(&host).await;
    host.remove(removed.id(), &op())
        .await
        .expect(StatusCode::OK);
    let id = removed.id().to_string();
    let now = time::OffsetDateTime::now_utc().unix_timestamp();

    // A first-screen device goes at 30 days. This one was in use, so 31 days on it
    // is still there to say what happened, rather than `device_unknown`.
    harness
        .store
        .purge_pairing(now + 31 * 24 * 3600)
        .await
        .expect("purge");
    assert!(harness
        .store
        .pairing_device(&id)
        .await
        .expect("row")
        .is_some());
    removed.refresh().await.expect(StatusCode::OK);
    assert_eq!(
        serde_json::to_value(removed.session.membership_change.expect("reported").kind)
            .expect("kind"),
        "removed"
    );

    harness
        .store
        .purge_pairing(now + 181 * 24 * 3600)
        .await
        .expect("purge");
    assert!(harness
        .store
        .pairing_device(&id)
        .await
        .expect("row")
        .is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn one_process_serves_a_pairing_database() {
    let harness = Harness::start().await;
    let held = harness
        .store
        .lock_database()
        .expect("first")
        .expect("a file database");
    assert!(matches!(
        harness.store.lock_database(),
        Err(pocox_store::StoreError::DatabaseInUse { .. })
    ));
    drop(held);
    assert!(harness.store.lock_database().expect("free again").is_some());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn another_actors_operation_id_is_never_revealed() {
    let harness = Harness::start().await;
    let target = Device::activated(&harness, "target").await;
    target.relay_key().await;
    let code = target.code().await;
    let requester = Device::new(&harness, "requester").await;
    let preview: PreviewResponse = requester
        .preview(&code)
        .await
        .expect(StatusCode::OK)
        .parse();
    harness.link.cut();
    let id = op();
    requester
        .post(
            "/v1/pair/restore",
            json!({ "ticket": preview.ticket, "target_device_id": target.id(), "operation_id": id }),
        )
        .await
        .expect(StatusCode::ACCEPTED);

    // The device being replaced is told to wait and nothing more.
    let reply = target
        .refresh_raw()
        .await
        .expect_error(StatusCode::CONFLICT, "transition_pending");
    assert!(reply.body.get("operation_id").is_none());
    let reply = harness
        .call(
            Method::POST,
            "/v1/pair/device",
            None,
            Some(json!({ "device_secret": target.secret, "label": "again" })),
        )
        .await
        .expect_error(StatusCode::CONFLICT, "transition_pending");
    assert!(reply.body.get("operation_id").is_none());

    // The device that asked gets its own.
    let reply = requester
        .refresh_raw()
        .await
        .expect_error(StatusCode::CONFLICT, "transition_pending");
    assert_eq!(reply.body["operation_id"], id.as_str());
    harness.link.point_at(harness.relay.addr());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn resuming_a_paused_code_revives_no_earlier_ticket() {
    let harness = Harness::start().await;
    let target = Device::activated(&harness, "target").await;
    let joiner = Device::activated(&harness, "joiner").await;
    let requester = Device::new(&harness, "requester").await;
    let link_ticket = joiner.ticket_for(&target).await.ticket;
    let code = target.code().await;
    let restore_ticket: PreviewResponse = requester
        .preview(&code)
        .await
        .expect(StatusCode::OK)
        .parse();
    for paused in [true, false] {
        harness
            .call(
                Method::PATCH,
                "/v1/pair/code",
                Some(target.token()),
                Some(json!({ "paused": paused })),
            )
            .await
            .expect(StatusCode::OK);
    }
    joiner
        .link_with(&link_ticket, &op(), false)
        .await
        .expect_error(StatusCode::CONFLICT, "preview_stale");
    requester
        .post(
            "/v1/pair/restore",
            json!({
                "ticket": restore_ticket.ticket,
                "target_device_id": target.id(),
                "operation_id": op(),
            }),
        )
        .await
        .expect_error(StatusCode::CONFLICT, "preview_stale");
    // A new preview of the same code works.
    joiner.ticket_for(&target).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_device_token_gets_no_leeway_past_its_expiry() {
    let harness = Harness::start().await;
    let device = Device::new(&harness, "device").await;
    let now = time::OffsetDateTime::now_utc().unix_timestamp();
    // Inside the library's minute of leeway, and past its own expiry.
    let expired = mint(&Claims {
        sub: device.user().to_string(),
        ns: format!("pcxu:{}", device.user()),
        login: "device".to_string(),
        gh_id: None,
        did: Some(device.id().to_string()),
        dgen: Some(device.session.generation),
        iat: now - 3600,
        exp: now - 20,
        jti: "expired".to_string(),
    });
    harness
        .call(Method::GET, "/v1/pair/code", Some(&expired), None)
        .await
        .expect_error(StatusCode::UNAUTHORIZED, "session_stale");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn shared_routes_follow_the_pairing_contract_for_a_device() {
    let harness = Harness::start().await;
    let device = Device::activated(&harness, "device").await;
    device.relay_key().await;

    // Nothing per-device may be cached.
    for path in ["/v1/me", "/v1/services", "/v1/relay"] {
        let reply = device.get(path).await.expect(StatusCode::OK);
        assert_eq!(reply.cache.as_deref(), Some("no-store"), "{path}");
    }
    let refreshed = device.refresh_raw().await.expect(StatusCode::OK);
    assert_eq!(refreshed.cache.as_deref(), Some("no-store"));

    // Deregistration refuses an old client too.
    let response = harness
        .http
        .delete(format!("{}/v1/services/mac/app/default", harness.base()))
        .bearer_auth(device.token())
        .send()
        .await
        .expect("request");
    assert_eq!(response.status(), StatusCode::UPGRADE_REQUIRED);

    // A malformed removal is a coded refusal, not plain text before any check.
    let reply = harness
        .call(Method::DELETE, &format!("/v1/devices/{}", device.id()), Some(device.token()), None)
        .await
        .expect_error(StatusCode::BAD_REQUEST, "invalid_request");
    assert_eq!(reply.cache.as_deref(), Some("no-store"));

    // An oversized refresh is refused at the door.
    let oversized = harness
        .call(
            Method::POST,
            "/auth/refresh",
            None,
            Some(json!({ "device_secret": "x".repeat(9000) })),
        )
        .await;
    assert_eq!(oversized.status, StatusCode::PAYLOAD_TOO_LARGE);

    // A relay failure on a shared route is the same stable code as anywhere else.
    harness.link.cut();
    device
        .get("/v1/services")
        .await
        .expect_error(StatusCode::SERVICE_UNAVAILABLE, "relay_unavailable");
    harness.link.point_at(harness.relay.addr());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_key_is_never_shortened_by_a_group_shrinking() {
    let harness = Harness::start().await;
    let host = Device::activated(&harness, "host").await;
    let mut member = Device::activated(&harness, "member").await;
    let single = host.relay_key().await;
    member.link_to(&host).await;

    // Growing: on the next renewal the longer life applies.
    harness.relaunch().await;
    let linked = host.relay_key().await;
    assert_eq!(linked.credential, single.credential);
    assert!(linked.expires_at > single.expires_at + 300, "a linked group's keys last longer");

    // Shrinking: a key another installation may be asleep on keeps the life it has.
    member.leave(&op()).await.expect(StatusCode::OK);
    harness.relaunch().await;
    let shrunk = host.relay_key().await;
    assert!(
        shrunk.expires_at + 2 >= linked.expires_at,
        "{} vs {}",
        shrunk.expires_at,
        linked.expires_at
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_foreign_stored_key_id_is_left_alone_by_a_removal() {
    let harness = Harness::start().await;
    let host = Device::activated(&harness, "host").await;
    let mut member = Device::activated(&harness, "member").await;
    member.link_to(&host).await;
    let member_key = member.relay_key().await;
    let row = harness
        .store
        .generation_key(member.id(), member.session.generation)
        .await
        .expect("row")
        .expect("key");

    // The stored id now names another tenant's key on this same instance.
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

    host.remove(member.id(), &op()).await.expect(StatusCode::OK);
    let live = harness.live_keys().await;
    let still = live
        .iter()
        .find(|key| key.key_id == foreign.key_id)
        .expect("never revoked");
    assert_eq!(still.expires_at, foreign.expires_at, "nor renewed");
    let ended = harness
        .store
        .grant(&row.grant_id)
        .await
        .expect("row")
        .expect("row");
    assert_eq!(ended.state, pocox_store::pairing::KeyState::Dead);
    // That row said nothing about the key it used to name, which the sweep finds by
    // label.
    harness.restart().await;
    assert!(!harness.credential_works(&member_key.credential).await);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_operation_leaves_keys_newer_than_its_generation_alone() {
    let harness = Harness::start().await;
    let host = Device::activated(&harness, "host").await;
    let mut member = Device::activated(&harness, "member").await;
    member.link_to(&host).await;
    let key = member.relay_key().await;
    let row = harness
        .store
        .generation_key(member.id(), member.session.generation)
        .await
        .expect("row")
        .expect("key");

    // A pending removal, and a key from a later generation than it covers.
    harness.link.cut();
    host.remove(member.id(), &op())
        .await
        .expect(StatusCode::ACCEPTED);
    sqlx::query(
        "UPDATE device_relay_keys SET generation = generation + 1, hard_cutoff = NULL, \
         cutoff_pending = 0 WHERE grant_id = ?1",
    )
    .bind(&row.grant_id)
    .execute(harness.store.pool())
    .await
    .expect("edit");
    harness.link.point_at(harness.relay.addr());
    harness.pairing_resume().await;
    assert!(harness.credential_works(&key.credential).await);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn another_devices_ticket_or_approval_is_worth_nothing() {
    let harness = Harness::start().await;
    let holder = Device::new(&harness, "holder").await;
    holder
        .activate(Some(&hint(50)))
        .await
        .expect(StatusCode::OK);
    let code = holder.code().await;
    let first = Device::new(&harness, "first").await;
    let second = Device::new(&harness, "second").await;

    // A ticket is bound to the device that previewed.
    let ticket: PreviewResponse = first.preview(&code).await.expect(StatusCode::OK).parse();
    second
        .link_with(&ticket.ticket, &op(), false)
        .await
        .expect_error(StatusCode::CONFLICT, "preview_stale");
    second
        .post(
            "/v1/pair/restore",
            json!({
                "ticket": ticket.ticket,
                "target_device_id": holder.id(),
                "operation_id": op(),
            }),
        )
        .await
        .expect_error(StatusCode::CONFLICT, "preview_stale");

    // An approved request belongs to the device that asked.
    let created: pocox_account_proto::pairing::RestoreRequestView = first
        .post("/v1/pair/restore/requests", json!({ "hint": hint(50) }))
        .await
        .expect(StatusCode::OK)
        .parse();
    holder
        .post(
            &format!("/v1/devices/{}/restore", holder.id()),
            json!({ "request_id": created.request_id, "operation_id": op(), "allow": true }),
        )
        .await
        .expect(StatusCode::NO_CONTENT);
    second
        .get(&format!("/v1/pair/restore/{}", created.request_id))
        .await
        .expect_error(StatusCode::NOT_FOUND, "not_found");
    second
        .post("/v1/pair/restore", json!({ "request_id": created.request_id, "operation_id": op() }))
        .await
        .expect_error(StatusCode::NOT_FOUND, "not_found");
    // The holder never moved for any of that.
    holder.refresh_raw().await.expect(StatusCode::OK);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_group_change_after_approval_is_a_stale_preview_and_undecidable_requests_are_hidden() {
    let harness = Harness::start().await;
    let holder = Device::new(&harness, "holder").await;
    holder
        .activate(Some(&hint(51)))
        .await
        .expect(StatusCode::OK);
    let mut member = Device::activated(&harness, "member").await;
    member.link_to(&holder).await;

    let asker = Device::new(&harness, "asker").await;
    let approved: pocox_account_proto::pairing::RestoreRequestView = asker
        .post("/v1/pair/restore/requests", json!({ "hint": hint(51) }))
        .await
        .expect(StatusCode::OK)
        .parse();
    member
        .post(
            &format!("/v1/devices/{}/restore", holder.id()),
            json!({ "request_id": approved.request_id, "operation_id": op(), "allow": true }),
        )
        .await
        .expect(StatusCode::NO_CONTENT);
    let waiting = Device::new(&harness, "waiting").await;
    let pending: pocox_account_proto::pairing::RestoreRequestView = waiting
        .post("/v1/pair/restore/requests", json!({ "hint": hint(51) }))
        .await
        .expect(StatusCode::OK)
        .parse();
    let list = member.get("/v1/devices").await.expect(StatusCode::OK);
    assert_eq!(
        list.body["pending_requests"]
            .as_array()
            .expect("list")
            .len(),
        1
    );

    // The group changes: what the asker saw is out of date, and the other request
    // can no longer be answered, so it is not offered.
    let mut late = Device::activated(&harness, "late").await;
    late.link_to(&holder).await;
    asker
        .post(
            "/v1/pair/restore",
            json!({ "request_id": approved.request_id, "operation_id": op() }),
        )
        .await
        .expect_error(StatusCode::CONFLICT, "preview_stale");
    let list = member.get("/v1/devices").await.expect(StatusCode::OK);
    assert_eq!(list.body["pending_requests"], json!([]));
    let status = waiting
        .get(&format!("/v1/pair/restore/{}", pending.request_id))
        .await
        .expect(StatusCode::OK);
    assert_eq!(status.body["status"], "stale");
}
