//! Recovery: a code, or a member's approval, and always the requester's
//! confirmation.

use pocox_account_proto::pairing::{OperationStatus, OperationView, RestoreRequestView};
use reqwest::StatusCode;
use serde_json::json;

use super::support::{hint, op, Device, Harness};

async fn ask(device: &Device<'_>, seed: u8) -> RestoreRequestView {
    device
        .post("/v1/pair/restore/requests", json!({ "hint": hint(seed) }))
        .await
        .expect(StatusCode::OK)
        .parse()
}

async fn answer(
    member: &Device<'_>,
    target: &str,
    request: &str,
    allow: bool,
) -> super::support::Reply {
    member
        .post(
            &format!("/v1/devices/{target}/restore"),
            json!({ "request_id": request, "operation_id": op(), "allow": allow }),
        )
        .await
}

async fn request_status(device: &Device<'_>, request: &str) -> RestoreRequestView {
    device
        .get(&format!("/v1/pair/restore/{request}"))
        .await
        .expect(StatusCode::OK)
        .parse()
}

/// A group of two whose first device holds hint `seed`.
async fn group<'h>(harness: &'h Harness, seed: u8) -> (Device<'h>, Device<'h>) {
    let holder = Device::new(harness, "holder").await;
    holder
        .activate(Some(&hint(seed)))
        .await
        .expect(StatusCode::OK);
    let mut member = Device::activated(harness, "member").await;
    member.link_to(&holder).await;
    (holder, member)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_members_approval_changes_nothing_until_the_requester_confirms() {
    let harness = Harness::start().await;
    let (holder, member) = group(&harness, 1).await;
    let holder_key = holder.relay_key().await;
    let generation = holder.session.generation;

    let mut reinstalled = Device::new(&harness, "reinstalled").await;
    let created = ask(&reinstalled, 1).await;
    let matching = created.matching_id.clone().expect("matching id");
    assert!(created.devices.is_empty(), "a request reveals no devices");
    assert!(created.target_device_id.is_none());

    // The peer sees the exact request with the same identifier.
    let listed = member.get("/v1/devices").await.expect(StatusCode::OK);
    let pending = listed.body["pending_requests"].as_array().expect("pending");
    assert_eq!(pending[0]["matching_id"], matching.as_str());
    assert_eq!(pending[0]["request_id"], created.request_id.as_str());

    answer(&member, holder.id(), &created.request_id, true)
        .await
        .expect(StatusCode::NO_CONTENT);

    // Approved, and still nothing has changed for anyone.
    holder.get("/v1/me").await.expect(StatusCode::OK);
    let mut same = holder.refresh_raw().await.expect(StatusCode::OK);
    assert_eq!(same.body["generation"].take(), json!(generation));
    assert!(harness.credential_works(&holder_key.credential).await);

    let approved = request_status(&reinstalled, &created.request_id).await;
    assert_eq!(approved.matching_id.as_deref(), Some(matching.as_str()));
    assert_eq!(approved.target_device_id.as_deref(), Some(holder.id()));
    let names: Vec<&str> = approved
        .devices
        .iter()
        .map(|device| device.name.as_str())
        .collect();
    assert!(names.contains(&"holder") && names.contains(&"member"));

    // Only this replaces a secret.
    let view: OperationView = reinstalled
        .post("/v1/pair/restore", json!({ "request_id": created.request_id, "operation_id": op() }))
        .await
        .expect(StatusCode::OK)
        .parse();
    assert_eq!(view.status, OperationStatus::Completed);
    assert!(view.session.is_none());
    reinstalled.refresh().await.expect(StatusCode::OK);
    assert_eq!(reinstalled.id(), holder.id());
    assert_eq!(reinstalled.user(), holder.user());
    assert!(reinstalled.session.generation > generation);
    holder
        .refresh_raw()
        .await
        .expect_error(StatusCode::UNAUTHORIZED, "device_superseded");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn declining_or_denial_leaves_a_new_device_and_the_target_untouched() {
    let harness = Harness::start().await;
    let (holder, member) = group(&harness, 2).await;
    let holder_key = holder.relay_key().await;

    // Denied: terminal, and the requester continues as new.
    let denied_by = Device::new(&harness, "denied").await;
    let request = ask(&denied_by, 2).await;
    answer(&member, holder.id(), &request.request_id, false)
        .await
        .expect(StatusCode::NO_CONTENT);
    let status = request_status(&denied_by, &request.request_id).await;
    assert_eq!(serde_json::to_value(status.status).expect("status"), "denied");
    assert!(status.devices.is_empty());
    denied_by
        .post("/v1/pair/restore", json!({ "request_id": request.request_id, "operation_id": op() }))
        .await
        .expect_error(StatusCode::CONFLICT, "stale");

    // Approved, then declined by continuing as new: activating cancels its
    // requests.
    let declining = Device::new(&harness, "declining").await;
    let request = ask(&declining, 2).await;
    answer(&member, holder.id(), &request.request_id, true)
        .await
        .expect(StatusCode::NO_CONTENT);
    declining.activate(None).await.expect(StatusCode::OK);
    let status = request_status(&declining, &request.request_id).await;
    assert_eq!(serde_json::to_value(status.status).expect("status"), "stale");
    assert_ne!(declining.user(), holder.user());
    assert!(harness.credential_works(&holder_key.credential).await);

    // An activated device has nothing to restore from.
    declining
        .post("/v1/pair/restore/requests", json!({ "hint": hint(2) }))
        .await
        .expect_error(StatusCode::CONFLICT, "stale");

    // No row holds this hint: nothing is found, and the path says so.
    let lost = Device::new(&harness, "lost").await;
    lost.post("/v1/pair/restore/requests", json!({ "hint": hint(77) }))
        .await
        .expect_error(StatusCode::NOT_FOUND, "not_found");
    assert_ne!(lost.user(), holder.user());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_code_restores_with_no_hint_even_when_approval_slots_are_full() {
    let harness = Harness::start().await;
    let (holder, _member) = group(&harness, 3).await;
    let code = holder.code().await;

    // Three requests fill the slots. A fourth is refused, and no earlier one is
    // overwritten: each keeps its own id and remains pending.
    let mut waiting = Vec::new();
    for name in ["one", "two", "three"] {
        let device = Device::new(&harness, name).await;
        let request = ask(&device, 3).await;
        waiting.push((device, request.request_id));
    }
    let fourth = Device::new(&harness, "fourth").await;
    fourth
        .post("/v1/pair/restore/requests", json!({ "hint": hint(3) }))
        .await
        .expect_error(StatusCode::TOO_MANY_REQUESTS, "restore_slots_full");
    for (device, request) in &waiting {
        let status = request_status(device, request).await;
        assert_eq!(serde_json::to_value(status.status).expect("status"), "pending");
    }

    // A code needs no hint and no slot. It works from a device that never had one,
    // and it keeps the code.
    let mut restored = Device::new(&harness, "no hint here").await;
    let preview: pocox_account_proto::pairing::PreviewResponse =
        restored.preview(&code).await.expect(StatusCode::OK).parse();
    assert_eq!(preview.devices.len(), 2, "the group's devices, to pick one");
    assert!(preview
        .devices
        .iter()
        .any(|device| device.id == holder.id()));
    let view: OperationView = restored
        .post(
            "/v1/pair/restore",
            json!({
                "ticket": preview.ticket,
                "target_device_id": holder.id(),
                "operation_id": op(),
            }),
        )
        .await
        .expect(StatusCode::OK)
        .parse();
    assert_eq!(view.status, OperationStatus::Completed);
    restored.refresh().await.expect(StatusCode::OK);
    assert_eq!(restored.id(), holder.id());
    assert_eq!(restored.code().await, code, "the same code");

    // Competing requests died with it.
    for (device, request) in &waiting {
        let status = request_status(device, request).await;
        assert_eq!(serde_json::to_value(status.status).expect("status"), "stale");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn pending_requests_cannot_approve_each_other_and_a_removed_member_cannot_approve() {
    let harness = Harness::start().await;
    let (holder, mut member) = group(&harness, 4).await;
    let first = Device::new(&harness, "first").await;
    let second = Device::new(&harness, "second").await;
    let first_request = ask(&first, 4).await;
    let second_request = ask(&second, 4).await;

    answer(&second, holder.id(), &first_request.request_id, true)
        .await
        .expect_error(StatusCode::NOT_FOUND, "not_found");
    answer(&first, holder.id(), &second_request.request_id, true)
        .await
        .expect_error(StatusCode::NOT_FOUND, "not_found");

    // Naming the wrong device is not an answer either, even for a real member.
    answer(&member, member.id(), &first_request.request_id, true)
        .await
        .expect_error(StatusCode::NOT_FOUND, "not_found");

    // A member removed before answering has no authority left: its old token is
    // dead and its new one is in another user.
    let old_member_token = member.token().to_string();
    holder
        .remove(member.id(), &op())
        .await
        .expect(StatusCode::OK);
    let reply = harness
        .call(
            reqwest::Method::POST,
            &format!("/v1/devices/{}/restore", holder.id()),
            Some(&old_member_token),
            Some(json!({
                "request_id": first_request.request_id,
                "operation_id": op(),
                "allow": true,
            })),
        )
        .await;
    assert_eq!(reply.status, StatusCode::UNAUTHORIZED);
    member.refresh().await.expect(StatusCode::OK);
    answer(&member, holder.id(), &first_request.request_id, true)
        .await
        .expect_error(StatusCode::NOT_FOUND, "not_found");

    // That removal changed the group's revision, so what was asked no longer
    // applies.
    let status = request_status(&first, &first_request.request_id).await;
    assert_eq!(serde_json::to_value(status.status).expect("status"), "stale");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_removed_device_loses_its_old_groups_recovery_routes() {
    let harness = Harness::start().await;
    let (holder, removed) = group(&harness, 5).await;
    let asking = Device::new(&harness, "asking").await;
    let about_removed = holder.code().await;

    // A request about the removed device, by a hint it holds.
    removed
        .activate(Some(&hint(6)))
        .await
        .expect(StatusCode::OK);
    let request = ask(&asking, 6).await;
    holder
        .remove(removed.id(), &op())
        .await
        .expect(StatusCode::OK);

    // Its pending requests were cancelled in the same transition, and an old-group
    // approval cannot bring it back.
    answer(&holder, removed.id(), &request.request_id, true)
        .await
        .expect_error(StatusCode::NOT_FOUND, "not_found");
    let status = request_status(&asking, &request.request_id).await;
    assert_eq!(serde_json::to_value(status.status).expect("status"), "stale");

    // Returning takes a new link: the device keeps its row but not its group.
    let mut removed = removed;
    removed.refresh().await.expect(StatusCode::OK);
    assert_ne!(removed.user(), holder.user());
    let preview: pocox_account_proto::pairing::PreviewResponse = removed
        .preview(&about_removed)
        .await
        .expect(StatusCode::OK)
        .parse();
    assert!(!preview.already_member);
    removed
        .link_with(&preview.ticket, &op(), false)
        .await
        .expect(StatusCode::OK);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_lost_restore_response_is_recovered_with_the_saved_secret() {
    let harness = Harness::start().await;
    let target = Device::activated(&harness, "target").await;
    let code = target.code().await;
    let requester = Device::new(&harness, "requester").await;
    let requester_row = requester.id().to_string();
    let preview: pocox_account_proto::pairing::PreviewResponse = requester
        .preview(&code)
        .await
        .expect(StatusCode::OK)
        .parse();
    let id = op();

    // The request commits and the client never hears back.
    requester
        .post(
            "/v1/pair/restore",
            json!({
                "ticket": preview.ticket,
                "target_device_id": target.id(),
                "operation_id": id,
            }),
        )
        .await
        .expect(StatusCode::OK);

    // The saved secret reads the result, gets a current session, and creating again
    // returns the existing status rather than a new device.
    let read: OperationView = requester
        .operation(&id)
        .await
        .expect(StatusCode::OK)
        .parse();
    assert_eq!(read.session.expect("session").device_id, target.id());
    let existing: pocox_account_proto::pairing::DeviceSession = harness
        .call(
            reqwest::Method::POST,
            "/v1/pair/device",
            None,
            Some(json!({ "device_secret": requester.secret, "label": "again" })),
        )
        .await
        .expect(StatusCode::OK)
        .parse();
    assert_eq!(existing.device_id, target.id());
    assert!(
        harness
            .store
            .pairing_device(&requester_row)
            .await
            .expect("lookup")
            .is_none(),
        "the store always holds one secret: the inactive row is gone"
    );

    // The replaced secret is never recreated, and no deadline restarts.
    let before = target.refresh_raw().await;
    let superseded = harness
        .call(
            reqwest::Method::POST,
            "/v1/pair/device",
            None,
            Some(json!({ "device_secret": target.secret, "label": "again" })),
        )
        .await
        .expect_error(StatusCode::UNAUTHORIZED, "device_superseded");
    assert_eq!(superseded.body["grace_deadline"], before.body["grace_deadline"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_requester_that_gained_peers_can_no_longer_restore() {
    let harness = Harness::start().await;
    let target = Device::activated(&harness, "target").await;
    let code = target.code().await;
    let requester = Device::new(&harness, "requester").await;
    let preview: pocox_account_proto::pairing::PreviewResponse = requester
        .preview(&code)
        .await
        .expect(StatusCode::OK)
        .parse();

    // Someone links into the requester while its screen shows the choice.
    let mut joiner = Device::activated(&harness, "joiner").await;
    joiner.link_to(&requester).await;
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
        .expect_error(StatusCode::CONFLICT, "stale");

    // A group that changed after preview is a stale preview.
    let alone = Device::new(&harness, "alone").await;
    let preview: pocox_account_proto::pairing::PreviewResponse =
        alone.preview(&code).await.expect(StatusCode::OK).parse();
    let mut late = Device::activated(&harness, "late").await;
    late.link_to(&target).await;
    alone
        .post(
            "/v1/pair/restore",
            json!({
                "ticket": preview.ticket,
                "target_device_id": target.id(),
                "operation_id": op(),
            }),
        )
        .await
        .expect_error(StatusCode::CONFLICT, "preview_stale");
}
