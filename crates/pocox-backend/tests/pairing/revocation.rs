//! Leave, removal and retake: no overlap for new authorization, nothing
//! reported until the relay confirms, and an outage leaves a pending operation
//! that a restart completes with no destination credential exposed meanwhile.

use pocox_account_proto::pairing::{
    DeviceSession, MembershipChangeKind, OperationStatus, OperationView,
};
use reqwest::StatusCode;

use super::support::{op, Device, Harness};

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn removal_and_leave_end_a_device_at_once_and_cost_peers_nothing() {
    let harness = Harness::start().await;
    let mut host = Device::activated(&harness, "host").await;
    let mut removed = Device::activated(&harness, "removed").await;
    let mut leaver = Device::activated(&harness, "leaver").await;
    removed.link_to(&host).await;
    leaver.link_to(&host).await;
    host.refresh().await.expect(StatusCode::OK);
    let host_key = host.relay_key().await;
    let removed_key = removed.relay_key().await;
    let leaver_key = leaver.relay_key().await;
    let old_removed_token = removed.token().to_string();
    let old_leaver_token = leaver.token().to_string();
    let shared_user = host.user().to_string();

    let done: OperationView = host
        .remove(removed.id(), &op())
        .await
        .expect(StatusCode::OK)
        .parse();
    assert_eq!(done.status, OperationStatus::Completed);
    // By the time that answered, the relay had already refused the key.
    assert!(!harness.credential_works(&removed_key.credential).await);
    assert!(harness.credential_works(&host_key.credential).await, "peers keep their keys");
    assert!(harness.credential_works(&leaver_key.credential).await);

    let done: OperationView = leaver.leave(&op()).await.expect(StatusCode::OK).parse();
    assert_eq!(done.status, OperationStatus::Completed);
    assert!(!harness.credential_works(&leaver_key.credential).await);

    // No overlap for the old sessions, on any route.
    for token in [&old_removed_token, &old_leaver_token] {
        for path in ["/v1/me", "/v1/services", "/v1/relay", "/v1/devices"] {
            harness
                .call(reqwest::Method::GET, path, Some(token), None)
                .await
                .expect_error(StatusCode::UNAUTHORIZED, "session_stale");
        }
    }

    // The removed device's secret survives into a new user, which it learns from
    // its next refresh, and it hosts nothing until an explicit Continue.
    removed.refresh().await.expect(StatusCode::OK);
    assert_ne!(removed.user(), shared_user);
    assert!(!removed.session.activated);
    let change = removed.session.membership_change.expect("reported");
    assert_eq!(change.kind, MembershipChangeKind::Removed);
    removed
        .get("/v1/relay")
        .await
        .expect_error(StatusCode::FORBIDDEN, "device_not_activated");
    removed.activate(None).await.expect(StatusCode::OK);
    let republished = removed.relay_key().await;
    assert_ne!(republished.namespace, host_key.namespace, "a new user, a new namespace");

    // A user who left confirmed it, so its activation stands.
    leaver.refresh().await.expect(StatusCode::OK);
    assert!(leaver.session.activated);
    assert_eq!(
        leaver.session.membership_change.expect("reported").kind,
        MembershipChangeKind::Left
    );

    // Coming back to the same user later cannot make an old token valid again.
    leaver.link_to(&host).await;
    assert_eq!(leaver.user(), shared_user);
    harness
        .call(reqwest::Method::GET, "/v1/me", Some(&old_leaver_token), None)
        .await
        .expect_error(StatusCode::UNAUTHORIZED, "session_stale");
    assert_eq!(
        leaver.session.membership_change.expect("reported").kind,
        MembershipChangeKind::Linked
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn removal_racing_renewal_leaves_no_credential_that_works() {
    let harness = Harness::start().await;
    let host = Device::activated(&harness, "host").await;
    let mut member = Device::activated(&harness, "member").await;
    member.link_to(&host).await;

    // Requests for the key are in flight on both sides of the removal: first keys,
    // renewals and refusals. Whatever any of them got must be dead when it
    // completes.
    let token = member.token().to_string();
    let racing = async {
        let mut credentials = Vec::new();
        for _ in 0..30 {
            let reply = harness
                .call(reqwest::Method::GET, "/v1/relay", Some(&token), None)
                .await;
            if reply.status == StatusCode::OK {
                let key: pocox_account_proto::http::RelayCredentialResponse = reply.parse();
                credentials.push(key.credential);
            }
        }
        credentials
    };
    let operation = op();
    let (credentials, removal) = tokio::join!(racing, host.remove(member.id(), &operation));
    removal.expect(StatusCode::OK);
    for credential in credentials {
        assert!(!harness.credential_works(&credential).await);
    }
    let member_label = format!("pcxd:{}:", member.id());
    assert!(
        !harness.live_keys().await.iter().any(|key| key
            .label
            .as_deref()
            .is_some_and(|label| label.starts_with(&member_label))),
        "no key of the removed device is left at the relay"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_answer_that_a_key_is_already_dead_counts_as_revoked() {
    let harness = Harness::start().await;
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

    // The relay applied the revocation and its answer was lost; or the key ran out.
    pocox_pb::revoke_credential(
        &harness.admin(),
        row.key_id.as_deref().expect("id").parse().expect("id"),
    )
    .await
    .expect("revoke");
    let done: OperationView = host
        .remove(member.id(), &op())
        .await
        .expect(StatusCode::OK)
        .parse();
    assert_eq!(done.status, OperationStatus::Completed);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_destination_that_changes_during_relay_work_leaves_the_source_intact() {
    let harness = Harness::start().await;
    let target = Device::activated(&harness, "target").await;
    let mut source_peer = Device::activated(&harness, "peer").await;
    let mut mover = Device::activated(&harness, "mover").await;
    mover.link_to(&source_peer).await;
    source_peer.refresh().await.expect(StatusCode::OK);
    let old_key = mover.relay_key().await;
    let preview = mover.ticket_for(&target).await;

    // The relay is down, so the link waits after it was prepared. Meanwhile the
    // target's code stops being valid.
    harness.link.cut();
    let id = op();
    mover
        .link_with(&preview.ticket, &id, true)
        .await
        .expect(StatusCode::ACCEPTED);
    harness
        .call(
            reqwest::Method::PATCH,
            "/v1/pair/code",
            Some(target.token()),
            Some(serde_json::json!({ "paused": true })),
        )
        .await
        .expect(StatusCode::OK);
    harness.link.point_at(harness.relay.addr());
    harness.restart().await;

    // Nothing moved. The relay work may have started, so the old generation cannot
    // come back: the device keeps its secret and group under a fresh generation.
    let failed: OperationView = mover.operation(&id).await.expect(StatusCode::OK).parse();
    assert_eq!(failed.status, OperationStatus::Failed);
    assert_eq!(failed.error, Some(pocox_account_proto::pairing::PairingErrorCode::PreviewStale));
    let generation = mover.session.generation;
    let source_user = mover.user().to_string();
    mover.refresh().await.expect(StatusCode::OK);
    assert_eq!(mover.user(), source_user, "still in its source group");
    assert!(mover.session.generation > generation);
    assert_eq!(harness.store.group_size(&source_user).await.expect("size"), 2);
    let new_key = mover.relay_key().await;
    assert_eq!(new_key.namespace, old_key.namespace);
    assert!(harness.credential_works(&new_key.credential).await);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_repeated_leave_is_a_no_op_and_never_another_new_group() {
    let harness = Harness::start().await;
    let host = Device::activated(&harness, "host").await;
    let mut member = Device::activated(&harness, "member").await;
    member.link_to(&host).await;

    let id = op();
    let first: OperationView = member.leave(&id).await.expect(StatusCode::OK).parse();
    let session = first.session.expect("session");
    let read: OperationView = member.operation(&id).await.expect(StatusCode::OK).parse();
    assert_eq!(read.session.expect("session").account_id, session.account_id);

    // A device already alone: with a new id it is still a no-op, not another group.
    member.session = session.clone();
    let again: OperationView = member.leave(&op()).await.expect(StatusCode::OK).parse();
    assert_eq!(again.status, OperationStatus::Completed);
    member.refresh().await.expect(StatusCode::OK);
    assert_eq!(member.user(), session.account_id);
    assert_eq!(member.session.generation, session.generation, "nothing was applied");

    // Removing yourself is what leave is for, and removing a stranger finds
    // nothing.
    host.remove(host.id(), &op())
        .await
        .expect_error(StatusCode::NOT_FOUND, "not_found");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_relay_outage_leaves_removal_pending_and_a_restart_completes_it() {
    let harness = Harness::start().await;
    let mut host = Device::activated(&harness, "host").await;
    let mut member = Device::activated(&harness, "member").await;
    member.link_to(&host).await;
    host.refresh().await.expect(StatusCode::OK);
    let host_key = host.relay_key().await;
    let member_key = member.relay_key().await;
    let namespace = harness
        .store
        .user_namespace(host.user())
        .await
        .expect("namespace");
    let source_user = host.user().to_string();

    harness.link.cut();
    let id = op();
    let accepted: OperationView = host
        .remove(member.id(), &id)
        .await
        .expect(StatusCode::ACCEPTED)
        .parse();
    assert_eq!(accepted.status, OperationStatus::Pending);
    assert!(accepted.session.is_none(), "not reported as removed");

    // Pending means blocked, not done.
    assert!(
        harness.credential_works(&member_key.credential).await,
        "the relay never got the revocation"
    );
    member
        .get("/v1/relay")
        .await
        .expect_error(StatusCode::UNAUTHORIZED, "session_stale");
    member
        .refresh_raw()
        .await
        .expect_error(StatusCode::CONFLICT, "transition_pending");
    let actor_view: OperationView = host
        .operation(&id)
        .await
        .expect(StatusCode::ACCEPTED)
        .parse();
    assert_eq!(actor_view.status, OperationStatus::Pending);

    // The group is held still rather than racing the pending change.
    let late = Device::activated(&harness, "late").await;
    let code = host.code().await;
    let ticket: pocox_account_proto::pairing::PreviewResponse =
        late.preview(&code).await.expect(StatusCode::OK).parse();
    late.link_with(&ticket.ticket, &op(), false)
        .await
        .expect_error(StatusCode::CONFLICT, "transition_pending");

    // The outage ends and this process goes away before noticing. The next process
    // finishes the job with no client asking.
    harness.link.point_at(harness.relay.addr());
    harness.restart().await;
    assert!(!harness.credential_works(&member_key.credential).await);
    assert!(harness.credential_works(&host_key.credential).await);
    let finished: OperationView = host.operation(&id).await.expect(StatusCode::OK).parse();
    assert_eq!(finished.status, OperationStatus::Completed);

    member.refresh().await.expect(StatusCode::OK);
    assert_ne!(member.user(), source_user);
    assert_eq!(
        member.session.membership_change.expect("reported").kind,
        MembershipChangeKind::Removed
    );
    assert_eq!(
        harness
            .store
            .user_namespace(&source_user)
            .await
            .expect("namespace"),
        namespace,
        "peers keep their namespace"
    );
    // The stale ticket is now stale; the group's revision moved.
    late.link_with(&ticket.ticket, &op(), false)
        .await
        .expect_error(StatusCode::CONFLICT, "preview_stale");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_link_during_an_outage_exposes_no_destination_credential() {
    let harness = Harness::start().await;
    let host = Device::activated(&harness, "host").await;
    let host_key = host.relay_key().await;
    let joiner = Device::activated(&harness, "joiner").await;
    let old_key = joiner.relay_key().await;
    let preview = joiner.ticket_for(&host).await;

    harness.link.cut();
    let id = op();
    joiner
        .link_with(&preview.ticket, &id, false)
        .await
        .expect(StatusCode::ACCEPTED);

    // The joiner's secret cannot get a session or a key for either side.
    joiner
        .refresh_raw()
        .await
        .expect_error(StatusCode::CONFLICT, "transition_pending");
    joiner
        .get("/v1/relay")
        .await
        .expect_error(StatusCode::UNAUTHORIZED, "session_stale");
    let pending: OperationView = joiner
        .operation(&id)
        .await
        .expect(StatusCode::ACCEPTED)
        .parse();
    assert!(pending.session.is_none());
    let opened = harness
        .store
        .device_open_keys(joiner.id())
        .await
        .expect("keys");
    assert_eq!(opened.len(), 1, "only the old generation's key exists");
    assert_ne!(opened[0].user_id, host.user());

    harness.link.point_at(harness.relay.addr());
    harness.restart().await;
    assert!(!harness.credential_works(&old_key.credential).await);
    let finished: OperationView = joiner.operation(&id).await.expect(StatusCode::OK).parse();
    let session = finished.session.expect("a session for the current secret");
    assert_eq!(session.account_id, host.user());
    let joiner = Device {
        session,
        ..joiner
    };
    let new_key = joiner.relay_key().await;
    assert_eq!(new_key.namespace, host_key.namespace);
    assert!(harness.credential_works(&new_key.credential).await);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_retake_revokes_every_generation_and_rotates_the_code() {
    let harness = Harness::start().await;
    let stolen = Device::activated(&harness, "stolen").await;
    let stolen_key = stolen.relay_key().await;
    let code = stolen.code().await;

    // First a normal restore, so a retiring generation with a live key exists too.
    let mut restored = Device::new(&harness, "restored").await;
    let view: OperationView = restored
        .restore_by_code(&code, stolen.id(), "restore")
        .await
        .expect(StatusCode::OK)
        .parse();
    restored.session = view.session.expect("session");
    let restored_key = restored.relay_key().await;
    assert!(harness.credential_works(&stolen_key.credential).await, "inside its overlap");

    let mut retaker = Device::new(&harness, "retaker").await;
    let view: OperationView = retaker
        .restore_by_code(&code, stolen.id(), "retake")
        .await
        .expect(StatusCode::OK)
        .parse();
    retaker.session = view.session.expect("session");

    // Every old key is gone with no overlap, including the earlier retiring one.
    assert!(!harness.credential_works(&stolen_key.credential).await);
    assert!(!harness.credential_works(&restored_key.credential).await);
    stolen
        .get("/v1/me")
        .await
        .expect_error(StatusCode::UNAUTHORIZED, "session_stale");
    restored
        .get("/v1/me")
        .await
        .expect_error(StatusCode::UNAUTHORIZED, "session_stale");
    restored
        .refresh_raw()
        .await
        .expect_error(StatusCode::UNAUTHORIZED, "device_superseded");

    // The leaked code dies at once and says so.
    let fresh = Device::new(&harness, "fresh").await;
    fresh
        .preview(&code)
        .await
        .expect_error(StatusCode::GONE, "code_retired");
    let rotated = retaker.code().await;
    assert_ne!(rotated, code);
    fresh.preview(&rotated).await.expect(StatusCode::OK);

    let _: DeviceSession = retaker.refresh_raw().await.expect(StatusCode::OK).parse();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn retakes_are_bounded_per_device() {
    let harness = Harness::start().await;
    let target = Device::activated(&harness, "target").await;
    let mut code = target.code().await;
    let device_id = target.id().to_string();
    for _ in 0..3 {
        let mut retaker = Device::new(&harness, "retaker").await;
        let view: OperationView = retaker
            .restore_by_code(&code, &device_id, "retake")
            .await
            .expect(StatusCode::OK)
            .parse();
        retaker.session = view.session.expect("session");
        code = retaker.code().await;
    }
    let late = Device::new(&harness, "late").await;
    let reply = late
        .restore_by_code(&code, &device_id, "retake")
        .await
        .expect_error(StatusCode::TOO_MANY_REQUESTS, "rate_limited");
    assert!(reply.retry_after.is_some());
}
