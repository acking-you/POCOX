//! A dead identity stays dead, and a copy of a credential gains nothing.

use pocox_account_proto::pairing::{OperationStatus, PairingErrorCode};

use super::error::{code_of, SignedOut};
use super::operations::{self, RestoreTarget};
use super::test_lab::{Install, Lab};
use super::{flows, session, status, PairingState};
use crate::engine::config::save_config;

/// `old`'s code restored onto a new installation, which replaces `old`'s
/// secret.
async fn restored_elsewhere(lab: &Lab, old: &Install, device_id: &str, code: &str) -> Install {
    let reinstalled = lab.device();
    flows::prepare(&reinstalled.identity(), None)
        .await
        .expect("prepare");
    let preview = flows::preview(&reinstalled.identity(), code)
        .await
        .expect("preview");
    let target = RestoreTarget::Ticket {
        ticket: preview.ticket,
        device_id: device_id.to_string(),
    };
    let outcome = operations::restore(&reinstalled.identity(), &target, false, None)
        .await
        .expect("restore");
    assert_eq!(outcome.status, OperationStatus::Completed);
    let _ = old;
    reinstalled
}

#[tokio::test(flavor = "multi_thread")]
async fn a_superseded_identity_cannot_revive_itself_and_a_copy_gains_nothing() {
    let lab = Lab::start().await;
    let (old, old_session, code) = lab.activated().await;
    let dead = old.secret();
    let restored = restored_elsewhere(&lab, &old, &old_session.device_id, &code.code).await;

    // It shows recovery, with the overlap's fixed deadline, and repeats nothing.
    let reading = status::status(&old.identity()).await.expect("status");
    assert_eq!(reading.state, PairingState::Superseded);
    assert!(reading.grace_deadline.is_some());
    let again = status::status(&old.identity()).await.expect("status");
    assert_eq!(again.grace_deadline, reading.grace_deadline, "no retry restarts the clock");
    assert_eq!(old.secret(), dead, "nothing was discarded or reclaimed on its own");
    let error = flows::prepare(&old.identity(), None)
        .await
        .expect_err("no new session");
    assert_eq!(code_of(&error), Some(PairingErrorCode::DeviceSuperseded));

    // Copying the store elsewhere copies a dead credential.
    let copy = lab.device();
    std::fs::create_dir_all(copy.store.path()).expect("store directory");
    std::fs::copy(old.store_file(), copy.store_file()).expect("copy the store");
    let reading = status::status(&copy.identity()).await.expect("status");
    assert_eq!(reading.state, PairingState::Superseded);

    // Starting over is an explicit choice that leaves a new, separate device.
    let fresh = flows::start_over(&old.identity(), Some("new"))
        .await
        .expect("start over");
    assert_ne!(old.secret(), dead);
    assert_ne!(fresh.session.device_id, old_session.device_id);
    assert!(!fresh.session.activated);
    assert_ne!(fresh.code.code, code.code);
    let current = flows::prepare(&restored.identity(), None)
        .await
        .expect("the restored device");
    assert_eq!(current.session.device_id, old_session.device_id, "untouched");

    // Starting over never throws away an identity that works.
    let error = flows::start_over(&restored.identity(), None)
        .await
        .expect_err("still works");
    assert!(format!("{error:#}").contains("still works"), "{error:#}");
    let current = flows::prepare(&restored.identity(), None)
        .await
        .expect("still there");
    assert_eq!(current.session.device_id, old_session.device_id);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_removed_device_gets_no_key_until_continue_and_its_old_token_nothing() {
    let lab = Lab::start().await;
    let (peer, peer_session, code) = lab.activated().await;
    let (removed, _, _) = lab.activated().await;
    let preview = flows::preview(&removed.identity(), &code.code)
        .await
        .expect("preview");
    operations::link(&removed.identity(), &preview.ticket, false, None)
        .await
        .expect("link");
    let linked = removed.config();
    assert_eq!(linked.account_id(), Some(peer_session.account_id.as_str()));
    let old_token = linked.account_token().expect("token").to_string();
    let removed_id = flows::prepare(&removed.identity(), None)
        .await
        .expect("id")
        .session
        .device_id;

    let outcome = operations::remove(&peer.identity(), &removed_id)
        .await
        .expect("remove");
    assert_eq!(outcome.status, OperationStatus::Completed);

    // Its old session gets nothing, whatever it still holds.
    let refused = removed
        .identity()
        .client
        .accepted(
            removed
                .identity()
                .client
                .request(reqwest::Method::GET, "/v1/relay")
                .bearer_auth(&old_token),
            "/v1/relay",
        )
        .await
        .expect_err("revoked");
    assert_eq!(code_of(&refused), Some(PairingErrorCode::SessionStale));

    // Its secret still identifies it, as a device of its own that must continue.
    let reading = status::status(&removed.identity()).await.expect("status");
    assert_eq!(reading.state, PairingState::Removed);
    let moved = removed.config();
    assert_ne!(moved.account_id(), Some(peer_session.account_id.as_str()));
    let error = session::relay_credential(&removed.support, &removed.backend)
        .await
        .expect_err("no key");
    assert_eq!(code_of(&error), Some(PairingErrorCode::DeviceNotActivated));

    flows::activate(&removed.identity(), None)
        .await
        .expect("Continue");
    session::relay_credential(&removed.support, &removed.backend)
        .await
        .expect("a key again");
    let group = flows::devices(&peer.identity(), None)
        .await
        .expect("devices");
    assert_eq!(group.devices.len(), 1, "still not in the group it was removed from");
}

#[tokio::test(flavor = "multi_thread")]
async fn an_unknown_secret_stays_unknown_and_nothing_is_recreated() {
    let lab = Lab::start().await;
    let install = lab.device();
    let identity = install.identity();
    // A secret the backend once acknowledged and has since purged.
    identity.store.ensure_secret().expect("secret");
    identity
        .store
        .update(|record| record.registered = true)
        .expect("mark");
    let secret = install.secret();
    let reading = status::status(&identity).await.expect("status");
    assert_eq!(reading.state, PairingState::Unknown);
    let error = flows::prepare(&identity, None)
        .await
        .expect_err("no silent new device");
    assert_eq!(code_of(&error), Some(PairingErrorCode::DeviceUnknown));
    assert_eq!(install.secret(), secret);
    assert_eq!(lab.front.count("POST /v1/pair/device"), 0, "creation was never tried");

    let fresh = flows::start_over(&identity, None)
        .await
        .expect("on the user's choice");
    assert!(!fresh.session.activated);
    assert_ne!(install.secret(), secret);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_expired_or_copied_token_gains_nothing_without_the_secret() {
    let lab = Lab::start().await;
    let (install, _, _) = lab.activated().await;
    // Expired, with its store: a refresh is what renews it.
    let mut expired = install.config();
    let label = expired.account_login().expect("label").to_string();
    let user = expired.account_id().expect("user").to_string();
    expired.set_device_session(expired_token(), label, user);
    save_config(&install.support, &expired).expect("save");
    let mut config = install.config();
    let token = session::valid_token(&install.support, &mut config, &install.backend)
        .await
        .expect("refreshed");
    assert_ne!(token, expired_token());

    // The same configuration anywhere without the store is signed out.
    let elsewhere = lab.device();
    save_config(&elsewhere.support, &expired).expect("copy");
    let mut config = elsewhere.config();
    let error = session::valid_token(&elsewhere.support, &mut config, &elsewhere.backend)
        .await
        .expect_err("no identity");
    assert!(error.is::<SignedOut>());
    assert!(session::relay_credential(&elsewhere.support, &elsewhere.backend)
        .await
        .is_err());
}

fn expired_token() -> String {
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use base64::Engine as _;
    format!("header.{}.signature", URL_SAFE_NO_PAD.encode(r#"{"exp":1,"did":"d","dgen":1}"#))
}
