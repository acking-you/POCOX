//! Where the secret lives, and who shares it.

use pocox_account_proto::pairing::PairingErrorCode;

use super::error::{code_of, SignedOut};
use super::test_lab::{hint, Lab};
use super::{flows, session, status, PairingState};
use crate::engine::config::save_config;

#[tokio::test(flavor = "multi_thread")]
async fn the_secret_stays_in_the_store_and_the_configuration_holds_only_a_session() {
    let lab = Lab::start().await;
    let (install, activated, _) = lab.activated().await;
    let secret = install.secret();
    let raw = install.raw_config();
    assert!(!raw.contains(&secret), "the secret is not in config.toml");
    assert!(!raw.contains("pcxd1_"));
    assert!(!raw.contains("refresh_token"), "no field for a copy to go stale in");
    assert!(raw.contains("device_code"));
    assert!(raw.contains(&activated.account_id));
    assert!(raw.contains(&activated.token), "the short-lived JWT is what is kept");

    // Neither a status a screen reads nor its debug form carries it.
    let reading = status::status(&install.identity()).await.expect("status");
    assert_eq!(reading.state, PairingState::Active);
    let shown = format!("{reading:?} {:?}", install.identity().read().expect("store"));
    assert!(!shown.contains(&secret));
    assert!(!shown.contains("pcxd1_"));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_configuration_restored_without_its_store_is_signed_out() {
    let lab = Lab::start().await;
    let (install, _, _) = lab.activated().await;
    // A backup brings back config.toml, whose JWT is still alive, and not the
    // store.
    let restored = lab.device();
    let mut copied = install.config();
    copied.set_relay("relay.example:7666");
    save_config(&restored.support, &copied).expect("restore");
    let mut config = restored.config();
    let error = session::valid_token(&restored.support, &mut config, &restored.backend)
        .await
        .expect_err("a JWT with no identity behind it is not a session");
    assert!(error.is::<SignedOut>(), "{error:#}");
    let after = restored.config();
    assert_eq!(after.account_token(), None, "it does not linger as if it could be refreshed");
    assert_eq!(after.relay(), Some("relay.example:7666"), "a self-host setup is left alone");
    assert_eq!(restored.identity().read().expect("store").map(|_| ()), None, "and no new device");
    let reading = status::status(&restored.identity()).await.expect("status");
    assert_eq!(reading.state, PairingState::NoDevice);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_present_but_unreadable_store_is_an_error_never_a_new_device() {
    let lab = Lab::start().await;
    let (install, _, _) = lab.activated().await;
    let file = install.store_file();
    std::fs::write(&file, b"{ damaged").expect("damage");
    let before = install.raw_config();
    let mut config = install.config();
    let error = session::valid_token(&install.support, &mut config, &install.backend)
        .await
        .expect_err("unreadable");
    assert!(!error.is::<SignedOut>(), "not the same as having no store: {error:#}");
    assert!(flows::prepare(&install.identity(), None).await.is_err());
    assert!(status::status(&install.identity()).await.is_err());
    assert_eq!(install.raw_config(), before, "the session stays for a repair");
    assert_eq!(std::fs::read(&file).expect("kept"), b"{ damaged", "nothing replaced it");
}

#[tokio::test(flavor = "multi_thread")]
async fn installations_of_a_device_share_one_identity_and_scopes_never_do() {
    let lab = Lab::start().await;
    let app = lab.device();
    let cli = app.sibling();
    // Racing on an empty store: one secret, one device.
    let (app_identity, cli_identity) = (app.identity(), cli.identity());
    let (first, second) = tokio::join!(
        flows::prepare(&app_identity, Some("laptop")),
        flows::prepare(&cli_identity, Some("laptop"))
    );
    let (first, second) = (first.expect("app"), second.expect("cli"));
    assert_eq!(first.session.device_id, second.session.device_id);
    assert_eq!(first.code.code, second.code.code);
    assert_eq!(app.secret(), cli.secret());

    let one = app.scoped("one");
    let two = app.scoped("two");
    let (scoped_one, scoped_two) = (
        flows::prepare(&one.identity(), None).await.expect("one"),
        flows::prepare(&two.identity(), None).await.expect("two"),
    );
    assert_ne!(one.secret(), two.secret());
    assert_ne!(one.secret(), app.secret());
    assert_ne!(scoped_one.session.device_id, scoped_two.session.device_id);
    assert_ne!(scoped_one.session.device_id, first.session.device_id);
}

#[tokio::test(flavor = "multi_thread")]
async fn only_activation_binds_a_hint_and_it_only_locates() {
    let lab = Lab::start().await;
    let hardware = "564d1234-aaaa-bbbb-cccc-0123456789ab";
    let first = lab.device();
    flows::prepare(&first.identity(), None)
        .await
        .expect("prepare");

    // Opening sign-in sent no hint, so a reinstall that asks finds nothing.
    let reinstall = lab.device();
    flows::prepare(&reinstall.identity(), None)
        .await
        .expect("prepare");
    let error = flows::request_restore(&reinstall.identity(), hint(hardware))
        .await
        .expect_err("nothing holds this hint yet");
    assert_eq!(code_of(&error), Some(PairingErrorCode::NotFound));

    flows::activate(&first.identity(), hint(hardware))
        .await
        .expect("activate");
    let request = flows::request_restore(&reinstall.identity(), hint(hardware))
        .await
        .expect("the hint now finds a device to ask");
    assert!(request.devices.is_empty(), "and reveals nothing about it");

    // Another device scope derives another key from the same hardware.
    let scoped = lab.device().scoped("test-device");
    flows::prepare(&scoped.identity(), None)
        .await
        .expect("prepare");
    let error = flows::request_restore(&scoped.identity(), hint(hardware))
        .await
        .expect_err("a scope has its own hardware key");
    assert_eq!(code_of(&error), Some(PairingErrorCode::NotFound));

    // A source this build does not know, or a placeholder, gives no hint at all.
    let error =
        flows::request_restore(&reinstall.identity(), hint("00000000-0000-0000-0000-000000000000"))
            .await
            .expect_err("a placeholder identifies nothing");
    assert_eq!(code_of(&error), Some(PairingErrorCode::NotFound));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_redirect_carries_nothing_onward() {
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    use tokio::net::TcpListener;

    let elsewhere = TcpListener::bind("127.0.0.1:0").await.expect("elsewhere");
    let elsewhere_addr = elsewhere.local_addr().expect("addr");
    let redirector = TcpListener::bind("127.0.0.1:0").await.expect("redirector");
    let base = format!("http://{}", redirector.local_addr().expect("addr"));
    let server = tokio::spawn(async move {
        let (mut socket, _) = redirector.accept().await.expect("accept");
        let mut request = [0u8; 4096];
        let _ = socket.read(&mut request).await;
        let answer = format!(
            "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://{elsewhere_addr}/steal\r\n\
             Content-Length: 0\r\nConnection: close\r\n\r\n"
        );
        socket.write_all(answer.as_bytes()).await.expect("answer");
    });
    let lab_install = {
        let store = std::sync::Arc::new(tempfile::tempdir().expect("store"));
        super::test_lab::Install::for_backend(&base, store)
    };
    let error = flows::prepare(&lab_install.identity(), None)
        .await
        .expect_err("a redirect is a failure");
    assert!(format!("{error:#}").contains("redirect"), "{error:#}");
    server.await.expect("redirector");
    let reached = tokio::time::timeout(std::time::Duration::from_millis(300), elsewhere.accept());
    assert!(reached.await.is_err(), "nothing reached where it pointed");
}

#[test]
fn an_invitation_is_exactly_a_code_for_this_backend() {
    assert_eq!(
        flows::parse_invitation("pocox://pair?c=K7M2F9QX3RTB").as_deref(),
        Some("K7M2F9QX3RTB")
    );
    for uri in [
        "pocox://auth?c=K7M2F9QX3RTB",
        "https://pair?c=K7M2F9QX3RTB",
        "pocox://pair?c=K7M2F9QX3RTB&backend=https://evil.example",
        "pocox://pair?c=short",
        "pocox://pair",
    ] {
        assert_eq!(flows::parse_invitation(uri), None, "{uri}");
    }
    assert_eq!(flows::parse_invitation(&format!("pocox://pair?c={}", "A".repeat(4096))), None);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_members_approval_changes_nothing_until_the_requester_confirms() {
    use pocox_account_proto::pairing::{OperationStatus, RestoreRequestStatus};

    use super::operations::{self, RestoreTarget};

    let lab = Lab::start().await;
    let hardware = "564d1234-aaaa-bbbb-cccc-0123456789ab";
    let member = lab.device();
    let member_identity = member.identity();
    flows::prepare(&member_identity, Some("member"))
        .await
        .expect("prepare");
    let member_session = flows::activate(&member_identity, hint(hardware))
        .await
        .expect("activate");

    let denied = lab.device();
    flows::prepare(&denied.identity(), Some("stranger"))
        .await
        .expect("prepare");
    let request = flows::request_restore(&denied.identity(), hint(hardware))
        .await
        .expect("ask");
    let asked = flows::devices(&member_identity, None)
        .await
        .expect("devices");
    let shown = asked
        .pending_requests
        .first()
        .expect("a member sees the request");
    assert_eq!(shown.request_id, request.request_id);
    assert_eq!(Some(shown.matching_id.as_str()), request.matching_id.as_deref());
    flows::decide(&member_identity, &shown.target_device_id, &shown.request_id, false)
        .await
        .expect("deny");
    let answered = flows::poll_restore(&denied.identity(), &request.request_id)
        .await
        .expect("poll");
    assert_eq!(answered.status, RestoreRequestStatus::Denied);
    assert!(answered.devices.is_empty(), "a denial reveals nothing");

    let wanted = lab.device();
    flows::prepare(&wanted.identity(), Some("reinstalled"))
        .await
        .expect("prepare");
    let request = flows::request_restore(&wanted.identity(), hint(hardware))
        .await
        .expect("ask");
    flows::decide(&member_identity, &member_session.device_id, &request.request_id, true)
        .await
        .expect("allow");
    let approved = flows::poll_restore(&wanted.identity(), &request.request_id)
        .await
        .expect("poll");
    assert_eq!(approved.status, RestoreRequestStatus::Approved);
    assert_eq!(approved.devices.len(), 1, "the requester sees the group before anything changes");
    let current = flows::prepare(&member_identity, None)
        .await
        .expect("nothing changed yet");
    assert_eq!(current.session.device_id, member_session.device_id);

    let target = RestoreTarget::Approved {
        request_id: request.request_id,
    };
    let bound = flows::hardware_hint(&wanted.identity(), hint(hardware)).await;
    assert!(bound.is_some());
    let outcome = operations::restore(&wanted.identity(), &target, false, bound)
        .await
        .expect("restore");
    assert_eq!(outcome.status, OperationStatus::Completed);
    let config = wanted.config();
    assert_eq!(config.account_id(), Some(member_session.account_id.as_str()));
    let error = flows::prepare(&member_identity, None)
        .await
        .expect_err("replaced");
    assert_eq!(code_of(&error), Some(PairingErrorCode::DeviceSuperseded));
}
