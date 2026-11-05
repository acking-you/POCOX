//! An answer arriving after the user moved on changes nothing they did.

use std::time::Duration;

use pocox_account_proto::pairing::PairingErrorCode;

use super::error::code_of;
use super::lifecycle::{self, TEST_ENGINE, TEST_STOPPED_UNDER};
use super::operations::{self, RestoreTarget};
use super::test_lab::{Install, Lab};
use super::{flows, session, status};
use crate::engine::config::update_config;
use crate::engine::{account, runtime, serve, transport};

fn sign_in_with_github(install: &Install) {
    update_config(&install.support, |config| {
        config.set_account_session("github-jwt", "github-refresh", "bob", Some("7".into()));
        Ok(())
    })
    .expect("sign in");
}

async fn until_seen(lab: &Lab, route: &str, already: usize) {
    for _ in 0..200 {
        if lab.front.count(route) > already {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("{route} was never sent");
}

async fn engine_on(install: &Install) {
    tokio::task::spawn_blocking(|| runtime::init(std::env::temp_dir()))
        .await
        .expect("join")
        .expect("runtime");
    lifecycle::forget_everything();
    *TEST_STOPPED_UNDER.lock().unwrap_or_else(|p| p.into_inner()) = None;
    *TEST_ENGINE.lock().unwrap_or_else(|p| p.into_inner()) = Some(install.support.clone());
}

fn engine_off() {
    *TEST_ENGINE.lock().unwrap_or_else(|p| p.into_inner()) = None;
    lifecycle::forget_everything();
}

fn stopped_anything() -> bool {
    TEST_STOPPED_UNDER
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .is_some()
}

#[allow(
    clippy::await_holding_lock,
    reason = "it only serializes whole tests, each on its own runtime"
)]
#[tokio::test(flavor = "multi_thread")]
async fn a_refresh_in_flight_never_replaces_a_newer_sign_in_or_stops_its_hosts() {
    let _serial = transport::test_serial();
    let lab = Lab::start().await;
    let name = "pairing-test-late-refresh";
    let (install, _, _) = lab.activated().await;
    engine_on(&install).await;
    tokio::task::spawn_blocking(move || serve::insert_test_host(name, None))
        .await
        .expect("join");
    let epoch = transport::epoch();

    let sent = lab.front.count("/auth/refresh");
    let gate = lab.front.hold_answer_to("/auth/refresh");
    let refresh = {
        let support = install.support.clone();
        let backend = install.backend.clone();
        let mut config = install.config();
        tokio::spawn(async move { session::refresh_now(&support, &mut config, &backend).await })
    };
    until_seen(&lab, "/auth/refresh", sent).await;
    sign_in_with_github(&install);
    let before = install.raw_config();
    gate.notify_one();
    refresh
        .await
        .expect("join")
        .expect_err("that token is for an account no longer here");

    assert_eq!(install.raw_config(), before, "bob's session is untouched");
    assert!(serve::owned_host_names().contains(&name.to_string()), "and so are its hosts");
    assert!(!stopped_anything());
    assert_eq!(transport::epoch(), epoch);
    serve::remove_test_host(name);
    engine_off();
}

#[tokio::test(flavor = "multi_thread")]
async fn an_activation_in_flight_leaves_a_newer_sign_in_alone() {
    let lab = Lab::start().await;
    let install = lab.device();
    flows::prepare(&install.identity(), None)
        .await
        .expect("prepare");
    // The refresh that follows activating is the session it would adopt.
    let sent = lab.front.count("/auth/refresh");
    let gate = lab.front.hold_answer_to("/auth/refresh");
    let activation = {
        let identity = install.identity();
        tokio::spawn(async move { flows::activate(&identity, None).await })
    };
    until_seen(&lab, "/auth/refresh", sent).await;
    sign_in_with_github(&install);
    let before = install.raw_config();
    gate.notify_one();
    activation
        .await
        .expect("join")
        .expect_err("the account changed underneath it");
    assert_eq!(install.raw_config(), before);
    assert_eq!(
        super::parked_github(&install.support).expect("read"),
        None,
        "and nothing was set aside"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reading_in_flight_does_not_bring_back_a_session_signed_out_of() {
    let lab = Lab::start().await;
    let (install, _, _) = lab.activated().await;
    for read_in_flight in [true, false] {
        flows::activate(&install.identity(), None)
            .await
            .expect("signed in");
        let sent = lab.front.count("/auth/refresh");
        let gate = lab.front.hold_answer_to("/auth/refresh");
        let identity = install.identity();
        let reading = tokio::spawn(async move {
            if read_in_flight {
                status::status(&identity).await.map(drop)
            } else {
                flows::prepare(&identity, None).await.map(drop)
            }
        });
        until_seen(&lab, "/auth/refresh", sent).await;
        account::logout(&install.support).await.expect("logout");
        gate.notify_one();
        reading.await.expect("join").expect("it still reads");
        assert_eq!(install.config().account_token(), None, "signed out stays signed out");
    }
}

#[allow(
    clippy::await_holding_lock,
    reason = "it only serializes whole tests, each on its own runtime"
)]
#[tokio::test(flavor = "multi_thread")]
async fn a_late_word_that_an_identity_died_stops_nothing_of_a_newer_sign_in() {
    let _serial = transport::test_serial();
    let lab = Lab::start().await;
    let name = "pairing-test-late-death";
    let (old, old_session, code) = lab.activated().await;
    let reinstalled = lab.device();
    flows::prepare(&reinstalled.identity(), None)
        .await
        .expect("prepare");
    let preview = flows::preview(&reinstalled.identity(), &code.code)
        .await
        .expect("preview");
    let target = RestoreTarget::Ticket {
        ticket: preview.ticket,
        device_id: old_session.device_id.clone(),
    };
    operations::restore(&reinstalled.identity(), &target, false, None)
        .await
        .expect("restore");

    engine_on(&old).await;
    tokio::task::spawn_blocking(move || serve::insert_test_host(name, None))
        .await
        .expect("join");
    let sent = lab.front.count("/auth/refresh");
    let gate = lab.front.hold_answer_to("/auth/refresh");
    let refresh = {
        let support = old.support.clone();
        let backend = old.backend.clone();
        let mut config = old.config();
        tokio::spawn(async move { session::refresh_now(&support, &mut config, &backend).await })
    };
    until_seen(&lab, "/auth/refresh", sent).await;
    sign_in_with_github(&old);
    gate.notify_one();
    let error = refresh.await.expect("join").expect_err("dead");
    assert_eq!(code_of(&error), Some(PairingErrorCode::DeviceSuperseded));
    assert!(!lifecycle::holding(), "this no longer concerns what runs here");
    assert!(serve::owned_host_names().contains(&name.to_string()));
    serve::remove_test_host(name);
    engine_off();
}
