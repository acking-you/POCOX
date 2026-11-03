//! Exercise the POCOX wrappers against the SDK's isolated authenticated relay.
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use pb_mapper_server::DirectServerConfig;
use pb_mapper_testkit::{Relay, TEST_ADMIN_KEY};
use pocox_core::config::{ConnectionPath, PbMapperConfig, PortMapping, RelayTransport};
use pocox_pb::{PortMappingStage, RegisterOptions, RelaySession, SubscribeOptions};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::{JoinHandle, JoinSet};

struct Echo(JoinHandle<()>);
impl Drop for Echo {
    fn drop(&mut self) {
        self.0.abort();
    }
}

async fn echo() -> (String, Arc<AtomicUsize>, Echo) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("echo listener");
    let address = listener.local_addr().expect("echo address").to_string();
    let accepted = Arc::new(AtomicUsize::new(0));
    let count = accepted.clone();
    let task = tokio::spawn(async move {
        let mut connections = JoinSet::new();
        loop {
            tokio::select! {
                result = listener.accept() => {
                    let (mut stream, _) = result.expect("echo accept");
                    count.fetch_add(1, Ordering::SeqCst);
                    connections.spawn(async move {
                        let (mut read, mut write) = stream.split();
                        let _ = tokio::io::copy(&mut read, &mut write).await;
                    });
                }
                Some(_) = connections.join_next() => {}
            }
        }
    });
    (address, accepted, Echo(task))
}

async fn roundtrip(stream: &mut TcpStream) {
    tokio::time::timeout(Duration::from_secs(15), async {
        let sent = vec![0x37; 32_000];
        stream.write_all(&sent).await.expect("send");
        let mut received = vec![0; sent.len()];
        stream.read_exact(&mut received).await.expect("receive");
        assert_eq!(sent, received, "tunnel must preserve bytes");
    })
    .await
    .expect("bounded data path");
}

#[tokio::test]
async fn wrapper_selects_direct_or_compatible_relay_without_duplicate_backend_dials() {
    for (relay_direct, publisher_direct, path) in [
        (true, true, ConnectionPath::Auto),
        (false, true, ConnectionPath::Auto),
        (true, false, ConnectionPath::Auto),
        (true, true, ConnectionPath::RelayOnly),
    ] {
        let mut relay = Relay::start_with_direct(
            "pocox-paths",
            relay_direct.then(|| DirectServerConfig {
                listen: "127.0.0.1:0".parse().expect("listen address"),
                advertise: "127.0.0.1:0".parse().expect("advertise address"),
            }),
        )
        .await;
        let admin = RelaySession::new(relay.addr().to_string(), TEST_ADMIN_KEY);
        let issued = pocox_pb::issue_credential(&admin, Duration::from_secs(600), None)
            .await
            .expect("scoped credential");
        let session = RelaySession::new(relay.addr().to_string(), issued.credential)
            .with_preferences(&PbMapperConfig {
                path,
                allow_direct: publisher_direct,
                ..Default::default()
            });
        let (backend, count, _echo) = echo().await;
        let key = "pcx:p2p-test:app:default";
        let registration = pocox_pb::register(&session, RegisterOptions {
            key: key.into(),
            local_addr: backend,
            codec: true,
        })
        .await
        .expect("registration");
        assert!(
            pocox_pb::keys(&admin)
                .await
                .expect("admin namespace")
                .is_empty(),
            "temporary services never leak into the admin namespace"
        );
        let reservation = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("reserve subscriber");
        let address = reservation.local_addr().expect("subscriber address");
        drop(reservation);
        let connection = pocox_pb::subscribe(&session, SubscribeOptions {
            key: key.into(),
            local_addr: address.to_string(),
        })
        .await
        .expect("subscription");
        let mut stream = TcpStream::connect(address).await.expect("local connection");
        roundtrip(&mut stream).await;
        assert_eq!(
            count.load(Ordering::SeqCst),
            1,
            "setup/fallback must dial the backend exactly once"
        );
        let diagnostics = connection.diagnostics();
        if relay_direct && publisher_direct && path == ConnectionPath::Auto {
            assert_eq!(
                diagnostics
                    .direct
                    .expect("direct diagnostics")
                    .active_direct,
                1
            );
            relay.stop_server().await;
            roundtrip(&mut stream).await;
        } else {
            assert_eq!(diagnostics.direct.as_ref().map_or(0, |d| d.active_direct), 0);
            if path == ConnectionPath::Auto {
                assert!(diagnostics.direct.expect("fallback diagnostics").fallbacks > 0);
            }
        }
        registration.stop().await.expect("stop publisher");
        assert!(tokio::time::timeout(Duration::from_secs(8), stream.read_u8())
            .await
            .expect("local stop closes data")
            .is_err());
        connection.stop().await.expect("stop subscriber");
    }
}

#[tokio::test]
async fn a_quic_session_carries_tunnels_and_a_relay_without_quic_says_so() {
    let relay = Relay::start_with_quic("pocox-quic").await;
    let tcp = RelaySession::new(relay.addr().to_string(), TEST_ADMIN_KEY);
    assert!(pocox_pb::relay_quic_port(&tcp)
        .await
        .expect("the relay answers")
        .is_some());
    let quic = tcp.clone().with_preferences(&PbMapperConfig {
        relay_transport: RelayTransport::Quic,
        ..Default::default()
    });
    let (backend, _, _echo) = echo().await;
    let key = "pcx:quic-test:app:default";
    let registration = pocox_pb::register(&quic, RegisterOptions {
        key: key.into(),
        local_addr: backend,
        codec: true,
    })
    .await
    .expect("registered over QUIC");
    let port = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("port")
        .local_addr()
        .expect("address")
        .to_string();
    let connection = pocox_pb::subscribe(&quic, SubscribeOptions {
        key: key.into(),
        local_addr: port.clone(),
    })
    .await
    .expect("subscribed over QUIC");
    roundtrip(&mut TcpStream::connect(&port).await.expect("dial")).await;
    assert_eq!(connection.diagnostics().relay_transport, pocox_pb::RelayTransport::Quic);
    assert_eq!(registration.diagnostics().relay_transport, pocox_pb::RelayTransport::Quic);
    connection.stop().await.expect("stop connection");
    registration.stop().await.expect("stop registration");

    // The preference never quietly falls back to TCP.
    let without = Relay::start_with_direct("pocox-no-quic", None).await;
    let tcp = RelaySession::new(without.addr().to_string(), TEST_ADMIN_KEY);
    assert_eq!(
        pocox_pb::relay_quic_port(&tcp)
            .await
            .expect("the relay answers"),
        None
    );
    let quic = tcp.with_preferences(&PbMapperConfig {
        relay_transport: RelayTransport::Quic,
        ..Default::default()
    });
    let refused = pocox_pb::keys(&quic)
        .await
        .expect_err("no QUIC to reach it over");
    assert!(pocox_pb::is_quic_refusal(&refused), "named as the carrier's fault: {refused:#}");
    let refused = pocox_pb::publish_pending(&quic, RegisterOptions {
        key: "pcx:quic-test:port:5173".into(),
        local_addr: "127.0.0.1:5173".into(),
        codec: true,
    })
    .await
    .expect_err("a permanently refused publication must not become a pending share");
    let pocox_pb::PublishError::Other(refused) = refused else {
        panic!("a missing carrier is not a service-name conflict");
    };
    assert!(
        pocox_pb::is_quic_refusal(&refused),
        "publication keeps the carrier's error: {refused:#}"
    );
}

#[tokio::test]
async fn a_port_mapping_follows_the_preference_and_waits_for_a_failed_punch() {
    let relay = Relay::start_with_direct(
        "pocox-mapping",
        Some(DirectServerConfig {
            listen: "127.0.0.1:0".parse().expect("listen address"),
            advertise: "127.0.0.1:0".parse().expect("advertise address"),
        }),
    )
    .await;
    let (backend, _, _echo) = echo().await;
    for (path, port_mapping, expected) in [
        (ConnectionPath::Auto, PortMapping::Auto, Some(PortMappingStage::Standby)),
        (ConnectionPath::Auto, PortMapping::Off, None),
        (ConnectionPath::RelayOnly, PortMapping::Auto, None),
    ] {
        let session = RelaySession::new(relay.addr().to_string(), TEST_ADMIN_KEY).with_preferences(
            &PbMapperConfig {
                path,
                allow_direct: path == ConnectionPath::Auto,
                port_mapping,
                ..Default::default()
            },
        );
        let key = "pcx:mapping-test:app:default";
        let registration = pocox_pb::register(&session, RegisterOptions {
            key: key.into(),
            local_addr: backend.clone(),
            codec: true,
        })
        .await
        .expect("registered");
        let port = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("port")
            .local_addr()
            .expect("address")
            .to_string();
        let connection = pocox_pb::subscribe(&session, SubscribeOptions {
            key: key.into(),
            local_addr: port,
        })
        .await
        .expect("subscribed");
        for mapping in
            [connection.diagnostics().port_mapping, registration.diagnostics().port_mapping]
        {
            assert_eq!(
                mapping.map(|mapping| mapping.current.stage),
                expected,
                "{path:?} {port_mapping:?}"
            );
        }
        connection.stop().await.expect("stop connection");
        registration.stop().await.expect("stop registration");
    }
}
