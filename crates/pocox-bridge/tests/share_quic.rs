//! A refused carrier must not leave a shared port or a persisted link behind.
#![cfg(not(any(target_os = "ios", target_os = "android")))]

use std::fs;
use std::net::TcpListener;

use pb_mapper_testkit::{Relay, TEST_ADMIN_KEY};
use pocox_bridge::agent_tools::shares::{self, Caller, ShareRequest};
use pocox_bridge::{agent_tools, headless};
use pocox_core::config::{PbMapperConfig, RelayTransport};
use pocox_pb::RelaySession;

#[test]
fn sharing_over_an_unavailable_carrier_releases_the_reservation_without_saving_it() {
    let runtime = tokio::runtime::Runtime::new().expect("test runtime");
    let relay = runtime.block_on(Relay::start_with_direct("share-no-quic", None));
    let root = tempfile::tempdir().expect("isolated host");
    let state = root.path().join("state");
    let hosting = state.join("hosting");
    fs::create_dir_all(&hosting).expect("hosting directory");
    // No external agent needs to start for a port share.
    fs::write(
        hosting.join("lifecycle.json"),
        r#"{"version":1,"revision":1,"entries":{"default":{"revision":1,"runtime":null}}}"#,
    )
    .expect("stopped default host");
    let mut manager = headless::Manager::start(headless::Options {
        config_dir: root.path().join("config"),
        state_dir: state,
        device: "share-quic-test".into(),
        name: "default".into(),
        binary: None,
        port: 0,
        proxy: None,
        relay: Some(RelaySession::new(relay.addr().to_string(), TEST_ADMIN_KEY).with_preferences(
            &PbMapperConfig {
                relay_transport: RelayTransport::Quic,
                ..Default::default()
            },
        )),
    })
    .expect("headless host");
    let service = TcpListener::bind("127.0.0.1:0").expect("local service");
    let result = runtime.block_on(shares::share(&Caller::user("You"), ShareRequest {
        ports: vec![service.local_addr().expect("service address").port()],
        ..Default::default()
    }));
    let error = result.expect_err("the share cannot be reached over this carrier");
    assert_eq!(error.code(), "relay_quic_unavailable");
    assert!(
        agent_tools::catalog::local()
            .expect("local catalog")
            .shares
            .is_empty(),
        "a refused share must release its reserved port"
    );
    let saved: Vec<serde_json::Value> = serde_json::from_slice(
        &fs::read(hosting.join("agent-tools/shares.json")).expect("saved shares"),
    )
    .expect("saved shares array");
    assert!(saved.is_empty(), "a failed share must not return after restart");
    manager.stop().expect("stop isolated host");
}
