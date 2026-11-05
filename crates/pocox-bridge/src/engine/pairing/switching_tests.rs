//! GitHub, self-hosted and pairing live side by side and never merge.

use pocox_core::config::{AccountProvider, Mode};

use super::test_lab::Lab;
use super::{flows, parked_github, resume_github, session, status, watch};
use crate::engine::config::update_config;
use crate::engine::{account, transport};

#[allow(
    clippy::await_holding_lock,
    reason = "it only serializes whole tests, each on its own runtime"
)]
#[tokio::test(flavor = "multi_thread")]
async fn preparing_a_code_changes_no_account_hosting_or_sign_in() {
    let _serial = transport::test_serial();
    let lab = Lab::start().await;
    let (_, _, invitation) = lab.activated().await;
    let github = lab.device();
    update_config(&github.support, |config| {
        config.set_account_session("github-jwt", "github-refresh", "alice", Some("1".into()));
        config.set_relay("relay.example:7666");
        Ok(())
    })
    .expect("sign in");
    let selfhost = lab.device();
    update_config(&selfhost.support, |config| {
        config.set_relay("relay.example:7666");
        config.set_relay_key("0123456789abcdef0123456789abcdef");
        Ok(())
    })
    .expect("self-host");
    for install in [&github, &selfhost] {
        let before = install.raw_config();
        let epoch = transport::epoch();
        let identity = install.identity();
        let prepared = flows::prepare(&identity, Some("laptop"))
            .await
            .expect("prepare");
        assert!(!prepared.session.activated);
        flows::code(&identity).await.expect("code");
        flows::preview(&identity, &invitation.code)
            .await
            .expect("preview");
        flows::devices(&identity, None).await.expect("devices");
        let reading = status::status(&identity).await.expect("status");
        assert!(!reading.active_here);
        assert_eq!(install.raw_config(), before, "config.toml is not touched");
        assert_eq!(transport::epoch(), epoch, "nothing owned by the current context moved");
        assert!(session::relay_credential(&install.support, &install.backend)
            .await
            .is_err());
    }
    // A GitHub device flow in progress finishes as it would have.
    let config = github.config();
    assert_eq!(config.account_provider(), AccountProvider::Github);
    assert_eq!(config.account_refresh_token(), Some("github-refresh"));
}

#[tokio::test(flavor = "multi_thread")]
async fn moving_to_pairing_sets_github_aside_and_gives_it_back_intact() {
    let lab = Lab::start().await;
    let install = lab.device();
    update_config(&install.support, |config| {
        config.set_account_session("github-jwt", "github-refresh", "alice", Some("1".into()));
        Ok(())
    })
    .expect("sign in");
    let identity = install.identity();
    let prepared = flows::prepare(&identity, None).await.expect("prepare");
    assert_eq!(parked_github(&install.support).expect("read"), None, "not until it is replaced");

    let activated = flows::activate(&identity, None).await.expect("activate");
    let config = install.config();
    assert_eq!(config.account_provider(), AccountProvider::DeviceCode);
    assert_ne!(config.account_id(), Some("1"), "users do not merge");
    assert_eq!(config.account_refresh_token(), None);
    assert!(!install.raw_config().contains("github-refresh"));
    assert_eq!(parked_github(&install.support).expect("read").as_deref(), Some("alice"));

    let secret = install.secret();
    assert_eq!(resume_github(&install.support).expect("resume").as_deref(), Some("alice"));
    let config = install.config();
    assert_eq!(config.account_provider(), AccountProvider::Github);
    assert_eq!(config.account_token(), Some("github-jwt"));
    assert_eq!(config.account_refresh_token(), Some("github-refresh"));
    assert_eq!(config.account_login(), Some("alice"));
    assert_eq!(config.account_id(), Some("1"));
    assert_eq!(install.secret(), secret, "the device store keeps the pairing identity");
    assert_eq!(parked_github(&install.support).expect("read"), None);
    assert_eq!(resume_github(&install.support).expect("nothing left"), None);

    // Back to pairing: the same device, not a new one.
    let again = flows::activate(&identity, None).await.expect("activate");
    assert_eq!(again.device_id, activated.device_id);
    assert_eq!(again.account_id, activated.account_id);
    assert_eq!(prepared.session.device_id, activated.device_id);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_chosen_self_host_setup_survives_pairing_and_wins_while_chosen() {
    let lab = Lab::start().await;
    let install = lab.device();
    let key = "0123456789abcdef0123456789abcdef";
    update_config(&install.support, |config| {
        config.set_relay("relay.example:7666");
        config.set_relay_key(key);
        Ok(())
    })
    .expect("self-host");
    assert_eq!(install.config().account_mode(), Mode::SelfHost);
    flows::activate(&install.identity(), None)
        .await
        .expect("activate");
    let config = install.config();
    assert_eq!(config.account_mode(), Mode::Account);
    assert_eq!(config.relay(), Some("relay.example:7666"), "its settings stay");
    assert_eq!(config.relay_key(), Some(key));

    update_config(&install.support, |config| {
        config.set_mode(Mode::SelfHost);
        Ok(())
    })
    .expect("advanced mode");
    let requests = lab.front.total();
    watch::tick(&install.support).await.expect("tick");
    assert_eq!(lab.front.total(), requests, "a self-hosted setup never talks to the backend");
}

#[tokio::test(flavor = "multi_thread")]
async fn signing_out_keeps_the_identity_and_its_group_and_calls_no_logout() {
    let lab = Lab::start().await;
    let (peer, _, code) = lab.activated().await;
    let (install, _, _) = lab.activated().await;
    let preview = flows::preview(&install.identity(), &code.code)
        .await
        .expect("preview");
    super::operations::link(&install.identity(), &preview.ticket, false, None)
        .await
        .expect("link");
    let secret = install.secret();

    account::logout(&install.support).await.expect("logout");
    assert_eq!(lab.front.count("/auth/logout"), 0, "a device has no refresh token to revoke");
    let config = install.config();
    assert_eq!(config.account_token(), None);
    assert_eq!(config.account_mode(), Mode::Unconfigured);
    assert_eq!(install.secret(), secret, "the store is not deleted");
    let group = flows::devices(&peer.identity(), None)
        .await
        .expect("devices");
    assert_eq!(group.devices.len(), 2, "logging out is not leaving");

    // Resuming from the retained store is an explicit choice, and the same device.
    let reading = status::status(&install.identity()).await.expect("status");
    assert!(!reading.active_here);
    let resumed = flows::activate(&install.identity(), None)
        .await
        .expect("resume");
    assert!(group
        .devices
        .iter()
        .any(|device| device.id == resumed.device_id));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_github_sign_in_over_pairing_leaves_the_store_alone() {
    let lab = Lab::start().await;
    let (install, activated, _) = lab.activated().await;
    let secret = install.secret();
    update_config(&install.support, |config| {
        config.set_account_session("github-jwt", "github-refresh", "alice", Some("1".into()));
        Ok(())
    })
    .expect("sign in");
    let config = install.config();
    assert_eq!(config.account_provider(), AccountProvider::Github);
    assert_eq!(install.secret(), secret);
    let staged = flows::prepare(&install.identity(), None)
        .await
        .expect("still usable");
    assert_eq!(staged.session.device_id, activated.device_id);
    assert_eq!(install.config().account_token(), Some("github-jwt"), "and staged only");
}
