//! A backend's commit is authoritative even when its answer is lost.

use std::time::Duration;

use pocox_account_proto::pairing::{OperationStatus, PairingErrorCode};
use pocox_core::pairing::{ActiveAccount, OperationKind, OperationState, StoredOperation};

use super::error::code_of;
use super::flows;
use super::operations::{self, OperationOutcome, RestoreTarget};
use super::test_lab::{Install, Lab};
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
