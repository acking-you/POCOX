//! A peer's removal, and every other change of user, reaching what runs here.

use std::net::SocketAddr;

use pocox_account_proto::pairing::{OperationStatus, PairingErrorCode};
use pocox_core::service::ServiceKind;

use super::error::code_of;
use super::lifecycle::{self, TEST_ENGINE, TEST_RESTARTED, TEST_STOPPED_UNDER};
use super::test_lab::{Install, Lab};
use super::{flows, operations, session, watch};
use crate::engine::host_lease::{self, Op};
use crate::engine::{account, host_services, runtime, serve, transport};

/// Pretend this process's engine runs on `install`. Initializing again builds
/// and drops a runtime, which only a blocking thread may do.
async fn engine_on(install: &Install) {
    tokio::task::spawn_blocking(|| runtime::init(std::env::temp_dir()))
        .await
        .expect("join")
        .expect("runtime");
    *TEST_ENGINE.lock().unwrap_or_else(|p| p.into_inner()) = Some(install.support.clone());
    TEST_RESTARTED
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .clear();
}

fn engine_off() {
    *TEST_ENGINE.lock().unwrap_or_else(|p| p.into_inner()) = None;
    lifecycle::release_hold();
}

/// Whether a host named `name` could start now, as a start would ask.
async fn may_start(name: &str) -> bool {
    let name = name.to_string();
    tokio::task::spawn_blocking(move || host_lease::acquire(&name, Op::Start).is_ok())
        .await
        .expect("join")
}

fn stopped_under() -> Option<String> {
    TEST_STOPPED_UNDER
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .clone()
}

fn restarted() -> Vec<String> {
    TEST_RESTARTED
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .clone()
}

/// Wait for the blocking task that restarts hosts.
async fn until_restarted() -> Vec<String> {
    for _ in 0..100 {
        let names = restarted();
        if !names.is_empty() {
            return names;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    Vec::new()
}

/// Publish a service for real under `install`'s key, recorded as a running
/// host.
async fn host_on_relay(install: &Install, name: &str) {
    let relay = session::relay_credential(&install.support, &install.backend)
        .await
        .expect("a key");
    let transport = pocox_pb::Transport {
        session: pocox_pb::RelaySession::new(relay.relay_addr, relay.credential),
        namespace: Some(relay.namespace),
    };
    let local: SocketAddr = "127.0.0.1:9".parse().expect("addr");
    let name = name.to_string();
    tokio::task::spawn_blocking(move || {
        let published = host_services::register_service(
            &transport,
            "host-device",
            ServiceKind::App,
            &name,
            local,
        )
        .expect("registered");
        serve::insert_test_host(&name, published);
    })
    .await
    .expect("join");
}

async fn services_seen_by(install: &Install) -> Vec<String> {
    session::services(&install.support, &install.backend)
        .await
        .expect("services")
        .into_iter()
        .map(|service| service.name)
        .collect()
}

#[allow(
    clippy::await_holding_lock,
    reason = "it only serializes whole tests, each on its own runtime"
)]
#[tokio::test(flavor = "multi_thread")]
async fn a_peers_removal_reaches_every_installation_and_a_running_host() {
    let _serial = transport::test_serial();
    let lab = Lab::start().await;
    let name = "pairing-test-removed";
    let (peer, peer_session, code) = lab.activated().await;
    let (owner, _, _) = lab.activated().await;
    let cli = owner.sibling();
    let preview = flows::preview(&owner.identity(), &code.code)
        .await
        .expect("preview");
    operations::link(&owner.identity(), &preview.ticket, false, None)
        .await
        .expect("link");
    flows::activate(&cli.identity(), None)
        .await
        .expect("the other installation is on it too");
    assert_eq!(cli.config().account_id(), Some(peer_session.account_id.as_str()));
    let device_id = flows::prepare(&owner.identity(), None)
        .await
        .expect("id")
        .session
        .device_id;

    engine_on(&owner).await;
    host_on_relay(&owner, name).await;
    assert!(services_seen_by(&peer).await.contains(&name.to_string()), "it is published");

    let outcome = operations::remove(&peer.identity(), &device_id)
        .await
        .expect("remove");
    assert_eq!(outcome.status, OperationStatus::Completed);

    // The long-running owner learns with no page polling, and stops hosting.
    watch::tick(&owner.support).await.expect("tick");
    assert!(lifecycle::holding(), "it hosts nothing until Continue");
    assert!(!serve::owned_host_names().contains(&name.to_string()), "the host stopped");
    assert_ne!(owner.config().account_id(), Some(peer_session.account_id.as_str()));
    assert!(!services_seen_by(&peer).await.contains(&name.to_string()), "and left the relay");
    assert_eq!(
        stopped_under().as_deref(),
        Some(peer_session.account_id.as_str()),
        "it stopped while config.toml still named the old user"
    );

    // Nothing can republish: a later tick stays held and the backend refuses a key.
    let error = account::relay_credential(&owner.support)
        .await
        .expect_err("no key");
    assert_eq!(code_of(&error), Some(PairingErrorCode::DeviceNotActivated));
    assert!(!may_start(name).await, "a held process starts nothing");
    // A process started after the removal holds nothing in memory, and the backend
    // still says no.
    lifecycle::release_hold();
    assert!(!may_start(name).await, "a new process starts nothing either");
    watch::tick(&owner.support).await.expect("tick");
    lifecycle::enforce_hold().await;
    watch::tick(&owner.support).await.expect("tick");
    assert!(restarted().is_empty(), "no restart before Continue");

    // Another installation learns from the shared store before its next request,
    // though its JWT has most of an hour left.
    let mut config = cli.config();
    session::valid_token(&cli.support, &mut config, &cli.backend)
        .await
        .expect("token");
    assert_ne!(config.account_id(), Some(peer_session.account_id.as_str()));
    assert_eq!(cli.config().account_id(), config.account_id());

    // Continue from that installation reaches the owner, which alone restarts.
    flows::activate(&cli.identity(), None)
        .await
        .expect("Continue");
    watch::tick(&owner.support).await.expect("tick");
    assert!(!lifecycle::holding());
    assert!(may_start(name).await, "Continue lets it host again");
    session::relay_credential(&owner.support, &owner.backend)
        .await
        .expect("a key again");
    engine_off();
}

#[allow(
    clippy::await_holding_lock,
    reason = "it only serializes whole tests, each on its own runtime"
)]
#[tokio::test(flavor = "multi_thread")]
async fn a_move_the_user_confirmed_restarts_the_owner_under_the_new_user() {
    let _serial = transport::test_serial();
    let lab = Lab::start().await;
    let name = "pairing-test-moved";
    let (_, inviter, code) = lab.activated().await;
    let (owner, own, _) = lab.activated().await;
    engine_on(&owner).await;
    host_on_relay(&owner, name).await;
    let old_key = account::relay_credential(&owner.support)
        .await
        .expect("key");
    let epoch = transport::epoch();

    let preview = flows::preview(&owner.identity(), &code.code)
        .await
        .expect("preview");
    let outcome = operations::link(&owner.identity(), &preview.ticket, false, None)
        .await
        .expect("link");
    assert_eq!(outcome.status, OperationStatus::Completed);

    assert!(transport::epoch() > epoch, "tunnels of the old user were dropped");
    assert!(!serve::owned_host_names().contains(&name.to_string()), "its host stopped");
    assert_eq!(stopped_under().as_deref(), Some(own.account_id.as_str()), "before the new user");
    assert_eq!(until_restarted().await, vec![name.to_string()], "and restarted");
    assert!(!lifecycle::holding(), "the user confirmed this move");
    let config = owner.config();
    assert_eq!(config.account_id(), Some(inviter.account_id.as_str()));
    assert_ne!(config.account_id(), Some(own.account_id.as_str()));
    let new_key = account::relay_credential(&owner.support)
        .await
        .expect("key");
    assert_ne!(new_key.namespace, old_key.namespace, "no credential of the old user is reused");
    engine_off();
}

#[allow(
    clippy::await_holding_lock,
    reason = "it only serializes whole tests, each on its own runtime"
)]
#[tokio::test(flavor = "multi_thread")]
async fn a_dead_identity_stops_hosting_and_renewing_and_stays_held() {
    let _serial = transport::test_serial();
    let lab = Lab::start().await;
    let name = "pairing-test-superseded";
    let (old, old_session, code) = lab.activated().await;
    engine_on(&old).await;
    host_on_relay(&old, name).await;
    // Restored elsewhere: this secret is replaced.
    let reinstalled = lab.device();
    flows::prepare(&reinstalled.identity(), None)
        .await
        .expect("prepare");
    let preview = flows::preview(&reinstalled.identity(), &code.code)
        .await
        .expect("preview");
    let target = operations::RestoreTarget::Ticket {
        ticket: preview.ticket,
        device_id: old_session.device_id.clone(),
    };
    operations::restore(&reinstalled.identity(), &target, false, None)
        .await
        .expect("restore");

    let dead = old.secret();
    let mut config = old.config();
    let error = session::refresh_now(&old.support, &mut config, &old.backend)
        .await
        .expect_err("dead");
    assert_eq!(code_of(&error), Some(PairingErrorCode::DeviceSuperseded));
    assert!(lifecycle::holding());
    assert!(!serve::owned_host_names().contains(&name.to_string()));
    watch::tick(&old.support)
        .await
        .expect("a held process keeps checking, quietly");
    assert!(restarted().is_empty(), "nothing reclaims this device");
    assert_eq!(old.secret(), dead, "and only the user's choice replaces its secret");
    engine_off();
}
