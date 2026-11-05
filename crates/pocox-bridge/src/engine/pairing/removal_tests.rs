//! A peer's removal, and every other change of user, reaching what runs here.

use std::net::SocketAddr;

use pocox_account_proto::pairing::{OperationStatus, PairingErrorCode};
use pocox_core::service::ServiceKind;

use super::error::code_of;
use super::lifecycle::{
    self, TEST_ENGINE, TEST_LEDGER, TEST_PINNED, TEST_RESTARTED, TEST_STOPPED_UNDER,
};
use super::test_lab::{Install, Lab};
use super::{flows, operations, session, watch};
use crate::engine::config::update_config;
use crate::engine::host_lease::{self, Op};
use crate::engine::{account, host_services, runtime, serve, transport};

/// Pretend this process's engine runs on `install`. Initializing again builds
/// and drops a runtime, which only a blocking thread may do.
async fn engine_on(install: &Install) {
    tokio::task::spawn_blocking(|| runtime::init(std::env::temp_dir()))
        .await
        .expect("join")
        .expect("runtime");
    lifecycle::forget_everything();
    watch::forget_having_looked();
    *TEST_STOPPED_UNDER.lock().unwrap_or_else(|p| p.into_inner()) = None;
    *TEST_ENGINE.lock().unwrap_or_else(|p| p.into_inner()) = Some(install.support.clone());
    TEST_RESTARTED
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .clear();
    // What a process notes as it starts.
    lifecycle::follow(&install.support).await.expect("config");
}

/// Run `work` as a command in another terminal: not this process's engine.
async fn in_another_process<T>(work: impl std::future::Future<Output = T>) -> T {
    let engine = TEST_ENGINE.lock().unwrap_or_else(|p| p.into_inner()).take();
    let answer = work.await;
    *TEST_ENGINE.lock().unwrap_or_else(|p| p.into_inner()) = engine;
    answer
}

fn engine_off() {
    *TEST_ENGINE.lock().unwrap_or_else(|p| p.into_inner()) = None;
    lifecycle::forget_everything();
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
    // still says no. What it refused, and what its ledger says should run, starts
    // on Continue though it stopped nothing itself.
    lifecycle::forget_everything();
    watch::forget_having_looked();
    let saved = "pairing-test-saved-while-removed";
    TEST_LEDGER
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .push(saved.to_string());
    assert!(!may_start(name).await, "a new process starts nothing either");
    assert!(lifecycle::holding(), "and now knows why");
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
    let names = until_restarted().await;
    assert!(names.contains(&name.to_string()), "what was refused starts: {names:?}");
    assert!(names.contains(&saved.to_string()), "and what the ledger holds: {names:?}");
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

    // It stops asking, and stops failing whatever a user kept open each time.
    let (requests, epoch) = (lab.front.total(), transport::epoch());
    watch::tick(&old.support)
        .await
        .expect("a held process keeps checking, quietly");
    let mut config = old.config();
    let error = session::refresh_now(&old.support, &mut config, &old.backend)
        .await
        .expect_err("still dead");
    assert_eq!(code_of(&error), Some(PairingErrorCode::DeviceSuperseded));
    assert_eq!(lab.front.total(), requests, "no more requests on a dead secret");
    assert_eq!(transport::epoch(), epoch, "and no more dropped connections");
    assert!(restarted().is_empty(), "nothing reclaims this device");
    assert_eq!(old.secret(), dead, "and only the user's choice replaces its secret");

    // A new secret is a new question: signed out of the old session, nothing held,
    // and a Continue of its own works.
    flows::start_over(&old.identity(), None)
        .await
        .expect("the user's choice");
    assert_eq!(old.config().account_token(), None);
    assert!(!lifecycle::holding());
    flows::activate(&old.identity(), None)
        .await
        .expect("Continue");
    assert_ne!(old.config().account_id(), Some(old_session.account_id.as_str()));
    engine_off();
}

#[allow(
    clippy::await_holding_lock,
    reason = "it only serializes whole tests, each on its own runtime"
)]
#[tokio::test(flavor = "multi_thread")]
async fn a_move_another_process_wrote_reaches_the_process_that_hosts() {
    let _serial = transport::test_serial();
    let lab = Lab::start().await;
    let name = "pairing-test-moved-elsewhere";
    let (_, inviter, code) = lab.activated().await;
    let (owner, own, _) = lab.activated().await;
    engine_on(&owner).await;
    host_on_relay(&owner, name).await;
    let epoch = transport::epoch();

    // `pocox pair join --yes` in another terminal, with its own one-shot process.
    in_another_process(async {
        let preview = flows::preview(&owner.identity(), &code.code)
            .await
            .expect("preview");
        operations::link(&owner.identity(), &preview.ticket, false, None)
            .await
            .expect("link");
    })
    .await;
    assert_eq!(owner.config().account_id(), Some(inviter.account_id.as_str()));
    assert!(serve::owned_host_names().contains(&name.to_string()), "nothing has noticed yet");

    watch::tick(&owner.support).await.expect("tick");
    assert!(!serve::owned_host_names().contains(&name.to_string()), "its hosts stopped");
    assert!(transport::epoch() > epoch, "and so did what it had open");
    assert_eq!(until_restarted().await, vec![name.to_string()], "and they started again");
    assert!(!lifecycle::holding(), "the user confirmed this move");

    // Back to its own group's account, by the same other process: leaving.
    TEST_RESTARTED
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .clear();
    host_on_relay(&owner, name).await;
    in_another_process(async { operations::leave(&owner.identity()).await.expect("leave") }).await;
    watch::tick(&owner.support).await.expect("tick");
    assert_eq!(until_restarted().await, vec![name.to_string()]);
    let _ = own;

    // GitHub from another terminal stops what runs in the group's namespace too.
    TEST_RESTARTED
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .clear();
    host_on_relay(&owner, name).await;
    update_config(&owner.support, |config| {
        config.set_account_session("github-jwt", "github-refresh", "bob", Some("7".into()));
        Ok(())
    })
    .expect("sign in");
    watch::tick(&owner.support).await.expect("tick");
    assert!(!serve::owned_host_names().contains(&name.to_string()));
    assert_eq!(until_restarted().await, vec![name.to_string()], "and under GitHub it comes back");
    engine_off();
}

#[allow(
    clippy::await_holding_lock,
    reason = "it only serializes whole tests, each on its own runtime"
)]
#[tokio::test(flavor = "multi_thread")]
async fn going_back_to_github_stops_first_and_restarts_under_it() {
    let _serial = transport::test_serial();
    let lab = Lab::start().await;
    let name = "pairing-test-back-to-github";
    let install = lab.device();
    update_config(&install.support, |config| {
        config.set_account_session("github-jwt", "github-refresh", "alice", Some("1".into()));
        Ok(())
    })
    .expect("sign in");
    let session = flows::activate(&install.identity(), None)
        .await
        .expect("activate");
    engine_on(&install).await;
    host_on_relay(&install, name).await;

    let resumed = super::resume_github(&install.support, None)
        .await
        .expect("resume");
    assert_eq!(resumed.as_deref(), Some("alice"));
    assert_eq!(stopped_under().as_deref(), Some(session.account_id.as_str()), "stopped first");
    assert_eq!(until_restarted().await, vec![name.to_string()], "then started again");
    let peer_view = services_seen_by(&install).await;
    assert!(!peer_view.contains(&name.to_string()), "and it left the group's namespace");
    engine_off();
}

#[allow(
    clippy::await_holding_lock,
    reason = "it only serializes whole tests, each on its own runtime"
)]
#[tokio::test(flavor = "multi_thread")]
async fn a_relay_of_its_own_does_not_depend_on_the_account() {
    let _serial = transport::test_serial();
    let lab = Lab::start().await;
    let name = "pairing-test-pinned";
    let (peer, _, code) = lab.activated().await;
    let (owner, _, _) = lab.activated().await;
    let preview = flows::preview(&owner.identity(), &code.code)
        .await
        .expect("preview");
    operations::link(&owner.identity(), &preview.ticket, false, None)
        .await
        .expect("link");
    let device_id = flows::prepare(&owner.identity(), None)
        .await
        .expect("id")
        .session
        .device_id;
    engine_on(&owner).await;
    TEST_PINNED.store(true, std::sync::atomic::Ordering::SeqCst);
    tokio::task::spawn_blocking(move || serve::insert_test_host(name, None))
        .await
        .expect("join");
    operations::remove(&peer.identity(), &device_id)
        .await
        .expect("remove");

    let requests = lab.front.total();
    watch::tick(&owner.support).await.expect("tick");
    assert_eq!(lab.front.total(), requests, "it has nothing to ask");
    assert!(serve::owned_host_names().contains(&name.to_string()), "and nothing to stop");
    assert!(!lifecycle::holding());
    TEST_PINNED.store(false, std::sync::atomic::Ordering::SeqCst);
    serve::remove_test_host(name);
    engine_off();
}

#[allow(
    clippy::await_holding_lock,
    reason = "it only serializes whole tests, each on its own runtime"
)]
#[tokio::test(flavor = "multi_thread")]
async fn a_host_too_busy_to_stop_is_owed_a_stop_and_token_work_does_not_wait() {
    let _serial = transport::test_serial();
    let lab = Lab::start().await;
    let name = "pairing-test-busy";
    let (_, inviter, code) = lab.activated().await;
    let (owner, _, _) = lab.activated().await;
    engine_on(&owner).await;
    host_on_relay(&owner, name).await;

    // A start holds this host's lease, as it does while it waits for a token.
    let lease = {
        let name = name.to_string();
        tokio::task::spawn_blocking(move || host_lease::acquire(&name, Op::Restart).expect("lease"))
            .await
            .expect("join")
    };
    let preview = flows::preview(&owner.identity(), &code.code)
        .await
        .expect("preview");
    let identity = owner.identity();
    let link =
        tokio::spawn(
            async move { operations::link(&identity, &preview.ticket, false, None).await },
        );
    for _ in 0..500 {
        if lifecycle::changing() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
    assert!(lifecycle::changing(), "the change is waiting for that lease");

    // The token the start wants is refused now, rather than after the change gave
    // up.
    let started = std::time::Instant::now();
    let mut config = owner.config();
    session::refresh_now(&owner.support, &mut config, &owner.backend)
        .await
        .expect_err("not while the account is changing");
    assert!(started.elapsed() < std::time::Duration::from_millis(500), "no wait for its lock");

    link.await.expect("join").expect("the move itself goes on");
    assert_eq!(owner.config().account_id(), Some(inviter.account_id.as_str()));
    assert!(serve::owned_host_names().contains(&name.to_string()), "that host is still up");

    drop(lease);
    watch::tick(&owner.support).await.expect("tick");
    assert!(
        !serve::owned_host_names().contains(&name.to_string()),
        "and the stop it was owed came"
    );
    assert_eq!(until_restarted().await, vec![name.to_string()], "and the start");
    engine_off();
}

#[cfg(unix)]
#[allow(
    clippy::await_holding_lock,
    reason = "it only serializes whole tests, each on its own runtime"
)]
#[tokio::test(flavor = "multi_thread")]
async fn a_change_that_could_not_be_written_starts_what_it_stopped() {
    use std::os::unix::fs::PermissionsExt as _;

    let _serial = transport::test_serial();
    let lab = Lab::start().await;
    let name = "pairing-test-unwritten";
    let (_, _, code) = lab.activated().await;
    let (owner, own, _) = lab.activated().await;
    engine_on(&owner).await;
    host_on_relay(&owner, name).await;
    let preview = flows::preview(&owner.identity(), &code.code)
        .await
        .expect("preview");

    let permissions = |mode| std::fs::Permissions::from_mode(mode);
    std::fs::set_permissions(&owner.support, permissions(0o500)).expect("read-only");
    let outcome = operations::link(&owner.identity(), &preview.ticket, false, None).await;
    std::fs::set_permissions(&owner.support, permissions(0o700)).expect("writable");
    let outcome = outcome.expect("the backend committed it");
    assert!(!outcome.caught_up);
    assert_eq!(owner.config().account_id(), Some(own.account_id.as_str()));
    assert!(
        until_restarted().await.contains(&name.to_string()),
        "hosts are not left stopped for a change that did not land"
    );
    engine_off();
}
