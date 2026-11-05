//! A backend's commit is authoritative even when its answer is lost.

use std::time::Duration;

use pocox_account_proto::pairing::{OperationStatus, PairingErrorCode};
use pocox_core::pairing::{ActiveAccount, OperationKind, OperationState, StoredOperation};

use super::error::code_of;
use super::operations::{self, OperationOutcome, RestoreTarget};
use super::test_lab::{Install, Lab};
use super::{flows, status, watch};
use crate::engine::config::update_config;

/// Read results until the operation stops pending, never repeating it.
async fn until_settled(install: &Install, id: &str) -> OperationOutcome {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        let outcomes = operations::settle(&install.identity())
            .await
            .expect("settle");
        let current = outcomes.into_iter().find(|outcome| outcome.id == id);
        match current {
            Some(outcome) if outcome.status == OperationStatus::Pending => {},
            Some(outcome) => return outcome,
            None => {
                return OperationOutcome {
                    id: id.to_string(),
                    kind: OperationKind::Link,
                    status: OperationStatus::Completed,
                    error: None,
                    caught_up: true,
                }
            },
        }
        assert!(tokio::time::Instant::now() < deadline, "still pending");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

fn open_operations(install: &Install) -> usize {
    install
        .identity()
        .read()
        .expect("store")
        .expect("record")
        .operations
        .len()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_lost_answer_to_creating_a_device_is_retried_with_the_same_secret() {
    let lab = Lab::start().await;
    let install = lab.device();
    lab.front.lose_answer_to("/v1/pair/device");
    flows::prepare(&install.identity(), Some("laptop"))
        .await
        .expect_err("the answer was lost");
    let secret = install.secret();
    assert!(
        !install
            .identity()
            .read()
            .expect("store")
            .expect("record")
            .registered,
        "the backend's acknowledgment never arrived"
    );

    let prepared = flows::prepare(&install.identity(), Some("laptop"))
        .await
        .expect("the retry");
    assert_eq!(install.secret(), secret, "the same saved secret");
    assert_eq!(lab.front.count("/v1/pair/device"), 2);
    let group = flows::devices(&install.identity(), None)
        .await
        .expect("devices");
    assert_eq!(group.devices.len(), 1);
    assert_eq!(group.devices[0].id, prepared.session.device_id, "one device, not two");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_lost_answer_to_a_link_is_read_back_and_never_sent_twice() {
    let lab = Lab::start().await;
    let (inviter, inviter_session, code) = lab.activated().await;
    let joiner = lab.device();
    flows::prepare(&joiner.identity(), Some("second"))
        .await
        .expect("prepare");
    let preview = flows::preview(&joiner.identity(), &code.code)
        .await
        .expect("preview");
    assert_eq!(preview.devices.len(), 1);

    lab.front.lose_answer_to("/v1/pair/link");
    let outcome = operations::link(&joiner.identity(), &preview.ticket, false, None)
        .await
        .expect("the secret reads the result");
    let outcome = until_settled(&joiner, &outcome.id).await;
    assert_eq!(outcome.status, OperationStatus::Completed);
    assert_eq!(lab.front.count("POST /v1/pair/link"), 1, "read, not replayed");
    assert_eq!(open_operations(&joiner), 0, "local configuration caught up");

    let config = joiner.config();
    assert_eq!(config.account_id(), Some(inviter_session.account_id.as_str()));
    let group = flows::devices(&inviter.identity(), None)
        .await
        .expect("devices");
    assert_eq!(group.devices.len(), 2);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_lost_answer_to_leaving_is_read_back_and_never_sent_twice() {
    let lab = Lab::start().await;
    let (inviter, inviter_session, code) = lab.activated().await;
    let joiner = lab.device();
    flows::prepare(&joiner.identity(), None)
        .await
        .expect("prepare");
    let preview = flows::preview(&joiner.identity(), &code.code)
        .await
        .expect("preview");
    let linked = operations::link(&joiner.identity(), &preview.ticket, false, None)
        .await
        .expect("link");
    assert_eq!(until_settled(&joiner, &linked.id).await.status, OperationStatus::Completed);

    lab.front.lose_answer_to("/v1/pair/leave");
    let outcome = operations::leave(&joiner.identity()).await.expect("leave");
    let outcome = until_settled(&joiner, &outcome.id).await;
    assert_eq!(outcome.status, OperationStatus::Completed);
    assert_eq!(lab.front.count("POST /v1/pair/leave"), 1);
    let config = joiner.config();
    assert_ne!(config.account_id(), Some(inviter_session.account_id.as_str()), "it moved out");
    let group = flows::devices(&inviter.identity(), None)
        .await
        .expect("devices");
    assert_eq!(group.devices.len(), 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_lost_answer_to_a_restore_recovers_with_the_saved_secret() {
    let lab = Lab::start().await;
    let (old, old_session, code) = lab.activated().await;
    let old_secret = old.secret();
    let reinstalled = lab.device();
    flows::prepare(&reinstalled.identity(), Some("reinstalled"))
        .await
        .expect("prepare");
    let new_secret = reinstalled.secret();
    let preview = flows::preview(&reinstalled.identity(), &code.code)
        .await
        .expect("preview");

    lab.front.lose_answer_to("POST /v1/pair/restore");
    let target = RestoreTarget::Ticket {
        ticket: preview.ticket,
        device_id: old_session.device_id.clone(),
    };
    let outcome = operations::restore(&reinstalled.identity(), &target, false, None)
        .await
        .expect("the secret reads the result");
    let outcome = until_settled(&reinstalled, &outcome.id).await;
    assert_eq!(outcome.status, OperationStatus::Completed);
    assert_eq!(lab.front.count("POST /v1/pair/restore HTTP"), 1, "not replayed");

    assert_eq!(reinstalled.secret(), new_secret, "the same secret moved onto the device");
    assert_ne!(new_secret, old_secret);
    let config = reinstalled.config();
    assert_eq!(config.account_id(), Some(old_session.account_id.as_str()));
    let session = flows::prepare(&reinstalled.identity(), None)
        .await
        .expect("again")
        .session;
    assert_eq!(session.device_id, old_session.device_id, "it is that device now");
    assert_eq!(
        flows::code(&reinstalled.identity())
            .await
            .expect("code")
            .code,
        code.code
    );
}

/// A process that sent a link and died: the operation is saved, its answer
/// gone.
async fn link_sent_and_crashed(install: &Install, ticket: &str, active: ActiveAccount) -> String {
    let identity = install.identity();
    let id = uuid::Uuid::new_v4().simple().to_string();
    let initiator =
        pocox_core::history_sync::digest_bytes(install.support.to_string_lossy().as_bytes())[..16]
            .to_string();
    identity
        .store
        .update(|record| {
            record.operations.push(StoredOperation {
                id: id.clone(),
                kind: OperationKind::Link,
                initiator,
                active_before: active,
                started_at: chrono::Utc::now().timestamp(),
                state: OperationState::Pending,
                error: None,
            });
        })
        .expect("save the operation");
    let token = identity.token().await.expect("token");
    identity
        .client
        .accepted(
            identity
                .client
                .request(reqwest::Method::POST, "/v1/pair/link")
                .bearer_auth(token)
                .json(&pocox_account_proto::pairing::LinkRequest {
                    ticket: ticket.to_string(),
                    operation_id: id.clone(),
                    leave_current: false,
                    hint: None,
                }),
            "/v1/pair/link",
        )
        .await
        .expect("the backend took it");
    id
}

#[tokio::test(flavor = "multi_thread")]
async fn a_result_arriving_later_is_never_applied_over_a_different_active_account() {
    let lab = Lab::start().await;
    let (inviter, _, code) = lab.activated().await;
    let joiner = lab.device();
    flows::prepare(&joiner.identity(), None)
        .await
        .expect("prepare");
    let preview = flows::preview(&joiner.identity(), &code.code)
        .await
        .expect("preview");
    let id = link_sent_and_crashed(&joiner, &preview.ticket, ActiveAccount::default()).await;

    // Restarted, the user signs in with GitHub before the result is read.
    update_config(&joiner.support, |config| {
        config.set_account_session("github-jwt", "github-refresh", "bob", Some("7".into()));
        Ok(())
    })
    .expect("sign in");
    let before = joiner.raw_config();

    let outcome = until_settled(&joiner, &id).await;
    assert_eq!(outcome.status, OperationStatus::Completed, "the backend's commit stands");
    assert_eq!(joiner.raw_config(), before, "bob's session is untouched");
    assert_eq!(lab.front.count("POST /v1/pair/link"), 1, "and nothing was replayed");
    assert_eq!(open_operations(&joiner), 0);
    let group = flows::devices(&inviter.identity(), None)
        .await
        .expect("devices");
    assert_eq!(group.devices.len(), 2);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_result_arriving_later_moves_an_installation_still_on_its_account() {
    let lab = Lab::start().await;
    let (_, inviter_session, code) = lab.activated().await;
    let joiner = lab.device();
    flows::prepare(&joiner.identity(), None)
        .await
        .expect("prepare");
    let preview = flows::preview(&joiner.identity(), &code.code)
        .await
        .expect("preview");
    let id = link_sent_and_crashed(&joiner, &preview.ticket, ActiveAccount::default()).await;

    let outcome = until_settled(&joiner, &id).await;
    assert_eq!(outcome.status, OperationStatus::Completed);
    let config = joiner.config();
    assert_eq!(config.account_id(), Some(inviter_session.account_id.as_str()));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_server_failure_is_not_a_refusal_and_the_commit_behind_it_stands() {
    let lab = Lab::start().await;
    let (_, inviter_session, code) = lab.activated().await;
    let joiner = lab.device();
    flows::prepare(&joiner.identity(), None)
        .await
        .expect("prepare");
    let preview = flows::preview(&joiner.identity(), &code.code)
        .await
        .expect("preview");

    lab.front.fail_answer_to("POST /v1/pair/link");
    let outcome = operations::link(&joiner.identity(), &preview.ticket, false, None)
        .await
        .expect("a server failure is not a refusal");
    let outcome = until_settled(&joiner, &outcome.id).await;
    assert_eq!(outcome.status, OperationStatus::Completed);
    assert_eq!(lab.front.count("POST /v1/pair/link"), 1, "read, not replayed");
    assert_eq!(joiner.config().account_id(), Some(inviter_session.account_id.as_str()));
}

#[tokio::test(flavor = "multi_thread")]
async fn another_installations_operation_is_read_and_left_for_it_to_adopt() {
    let lab = Lab::start().await;
    let (_, inviter_session, code) = lab.activated().await;
    let joiner = lab.device();
    flows::prepare(&joiner.identity(), None)
        .await
        .expect("prepare");
    let sibling = joiner.sibling();
    let preview = flows::preview(&joiner.identity(), &code.code)
        .await
        .expect("preview");
    let id = link_sent_and_crashed(&joiner, &preview.ticket, ActiveAccount::default()).await;

    // The other installation hears how it ended, moves nothing and is not held up.
    let outcomes = operations::settle(&sibling.identity())
        .await
        .expect("settle");
    assert_eq!(outcomes[0].status, OperationStatus::Completed);
    assert_eq!(sibling.config().account_token(), None, "not its move to adopt");
    let requests = lab.front.total();
    operations::settle(&sibling.identity())
        .await
        .expect("settle");
    assert_eq!(lab.front.total(), requests, "and once read it asks no more");
    let record = sibling.identity().read().expect("store").expect("record");
    assert!(
        !record
            .operations
            .iter()
            .any(|operation| operation.state == OperationState::Pending),
        "nothing blocks a removal now"
    );

    // The installation that started it still adopts it.
    until_settled(&joiner, &id).await;
    assert_eq!(joiner.config().account_id(), Some(inviter_session.account_id.as_str()));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_change_that_did_not_happen_stays_to_be_heard_about_and_blocks_nothing() {
    let lab = Lab::start().await;
    let (install, _, _) = lab.activated().await;
    let identity = install.identity();
    // Never received, long enough ago to say so, by another installation.
    identity
        .store
        .update(|record| {
            record.operations.push(StoredOperation {
                id: uuid::Uuid::new_v4().simple().to_string(),
                kind: OperationKind::Link,
                initiator: "elsewhere".to_string(),
                active_before: ActiveAccount::default(),
                started_at: chrono::Utc::now().timestamp() - 600,
                state: OperationState::Pending,
                error: None,
            });
        })
        .expect("saved");
    let outcomes = operations::settle(&identity).await.expect("settle");
    assert_eq!(outcomes[0].status, OperationStatus::Failed);
    assert_eq!(outcomes[0].error.as_deref(), Some("operation_unknown"));
    let reading = status::status(&identity).await.expect("status");
    assert_eq!(reading.failed.len(), 1, "whoever started it can still learn why");
    assert!(reading.pending.is_empty());
    operations::leave(&identity)
        .await
        .expect("it blocks nothing");
}

#[tokio::test(flavor = "multi_thread")]
async fn the_watcher_finishes_a_move_started_from_a_github_session() {
    let lab = Lab::start().await;
    let (_, inviter_session, code) = lab.activated().await;
    let joiner = lab.device();
    update_config(&joiner.support, |config| {
        config.set_account_session("github-jwt", "github-refresh", "bob", Some("7".into()));
        Ok(())
    })
    .expect("sign in");
    flows::prepare(&joiner.identity(), None)
        .await
        .expect("prepare");
    let preview = flows::preview(&joiner.identity(), &code.code)
        .await
        .expect("preview");
    let active = crate::engine::pairing::session::active_account(&joiner.config());
    let id = link_sent_and_crashed(&joiner, &preview.ticket, active).await;

    watch::tick(&joiner.support).await.expect("tick");
    assert_eq!(joiner.config().account_id(), Some(inviter_session.account_id.as_str()));
    assert!(until_settled(&joiner, &id).await.caught_up);

    // With nothing saved it costs a GitHub setup no request at all.
    let github = lab.device();
    update_config(&github.support, |config| {
        config.set_account_session("github-jwt", "github-refresh", "bob", Some("7".into()));
        Ok(())
    })
    .expect("sign in");
    let requests = lab.front.total();
    watch::tick(&github.support).await.expect("tick");
    assert_eq!(lab.front.total(), requests);
    assert_eq!(github.identity().read().expect("store").map(|_| ()), None);
}

#[cfg(unix)]
#[tokio::test(flavor = "multi_thread")]
async fn a_commit_says_when_this_installation_has_yet_to_catch_up() {
    use std::os::unix::fs::PermissionsExt as _;

    let lab = Lab::start().await;
    let (_, inviter_session, code) = lab.activated().await;
    let joiner = lab.device();
    flows::prepare(&joiner.identity(), None)
        .await
        .expect("prepare");
    let preview = flows::preview(&joiner.identity(), &code.code)
        .await
        .expect("preview");
    let permissions = |mode| std::fs::Permissions::from_mode(mode);
    std::fs::set_permissions(&joiner.support, permissions(0o500)).expect("read-only");
    let outcome = operations::link(&joiner.identity(), &preview.ticket, false, None).await;
    std::fs::set_permissions(&joiner.support, permissions(0o700)).expect("writable");
    let outcome = outcome.expect("the backend committed it");
    assert_eq!(outcome.status, OperationStatus::Completed);
    assert!(!outcome.caught_up, "and says so rather than claiming all is done");
    assert_eq!(joiner.config().account_token(), None);

    // The saved operation brings it along on the next pass.
    let later = operations::settle(&joiner.identity())
        .await
        .expect("settle");
    assert!(later[0].caught_up);
    assert_eq!(joiner.config().account_id(), Some(inviter_session.account_id.as_str()));
    assert_eq!(open_operations(&joiner), 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_lost_answer_to_a_decision_or_a_rotation_reads_as_what_happened() {
    let lab = Lab::start().await;
    let hardware = "564d1234-aaaa-bbbb-cccc-0123456789ab";
    let member = lab.device();
    flows::prepare(&member.identity(), None)
        .await
        .expect("prepare");
    let session = flows::activate(&member.identity(), super::test_lab::hint(hardware))
        .await
        .expect("activate");
    let asking = lab.device();
    flows::prepare(&asking.identity(), None)
        .await
        .expect("prepare");
    let request = flows::request_restore(&asking.identity(), super::test_lab::hint(hardware))
        .await
        .expect("ask");

    lab.front.lose_answer_to("/restore HTTP");
    flows::decide(&member.identity(), &session.device_id, &request.request_id, true)
        .await
        .expect("asking again replays it instead of hearing it is stale");
    // A later run, having heard nothing, gets the same.
    flows::decide(&member.identity(), &session.device_id, &request.request_id, true)
        .await
        .expect("still the same answer");
    let approved = flows::poll_restore(&asking.identity(), &request.request_id)
        .await
        .expect("poll");
    assert_eq!(approved.status, pocox_account_proto::pairing::RestoreRequestStatus::Approved);

    // A day on from its last code, a rotation whose answer never arrives still
    // shows the new code.
    let before = flows::code(&member.identity()).await.expect("code");
    sqlx::query("UPDATE devices SET code_issued_at = 0")
        .execute(lab.store.pool())
        .await
        .expect("a day passes");
    lab.front.lose_answer_to("/v1/pair/code/rotate");
    let rotated = flows::rotate(&member.identity())
        .await
        .expect("the code route says");
    assert_ne!(rotated.code, before.code);
    assert_eq!(lab.front.count("/v1/pair/code/rotate"), 1, "and it was sent once");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_pending_change_survives_an_outage_and_blocks_a_second_one() {
    let lab = Lab::start().await;
    let (_, inviter_session, code) = lab.activated().await;
    // A device with a relay key owes the relay work before it can move.
    let (joiner, _, _) = lab.activated().await;
    crate::engine::pairing::session::relay_credential(&joiner.support, &joiner.backend)
        .await
        .expect("a key to revoke");
    let preview = flows::preview(&joiner.identity(), &code.code)
        .await
        .expect("preview");

    lab.link.cut();
    let outcome = operations::link(&joiner.identity(), &preview.ticket, false, None)
        .await
        .expect("accepted");
    assert_eq!(outcome.status, OperationStatus::Pending);

    // A restart finds it, and nothing repeats it or starts another.
    let restarted = joiner.identity();
    let error = operations::leave(&restarted)
        .await
        .expect_err("one at a time");
    assert_eq!(code_of(&error), Some(PairingErrorCode::TransitionPending));
    let settled = operations::settle(&restarted).await.expect("settle");
    assert_eq!(settled[0].id, outcome.id);
    assert_eq!(settled[0].status, OperationStatus::Pending);
    assert_eq!(lab.front.count("POST /v1/pair/link"), 1);

    lab.link.restore(lab.relay.addr());
    lab.pairing
        .reconcile_once()
        .await
        .expect("the worker's pass");
    let finished = until_settled(&joiner, &outcome.id).await;
    assert_eq!(finished.status, OperationStatus::Completed);
    assert_eq!(joiner.config().account_id(), Some(inviter_session.account_id.as_str()));
}
