//! One user's devices, each with its own relay credential in one namespace, as
//! a backend holding the administrator key would set them up.
use std::time::Duration;

use pb_mapper_testkit::{Relay, TEST_ADMIN_KEY};
use pocox_pb::{RegisterOptions, RelaySession, SubscribeOptions};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const LONG_TTL: Duration = Duration::from_secs(600);

async fn echo() -> String {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("echo fixture");
    let addr = listener.local_addr().expect("echo fixture").to_string();
    tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                let (mut read, mut write) = stream.split();
                let _ = tokio::io::copy(&mut read, &mut write).await;
            });
        }
    });
    addr
}

async fn round_trip(address: std::net::SocketAddr) {
    tokio::time::timeout(Duration::from_secs(10), async {
        let mut stream = TcpStream::connect(address).await.expect("tunnel listener");
        stream.write_all(b"ping").await.expect("tunnel write");
        let mut reply = [0; 4];
        stream.read_exact(&mut reply).await.expect("tunnel read");
        assert_eq!(&reply, b"ping");
    })
    .await
    .expect("bounded round trip");
}

#[tokio::test]
async fn devices_with_their_own_keys_share_one_namespace_and_are_removed_alone() {
    let relay = Relay::start("pocox-namespaces").await;
    let addr = relay.addr().to_string();
    let admin = RelaySession::new(addr.clone(), TEST_ADMIN_KEY);
    assert!(pocox_pb::relay_supports_key_namespaces(&admin)
        .await
        .expect("capability check"));

    let namespace = pocox_pb::allocate_namespace(&admin)
        .await
        .expect("allocate");
    let issue = |label: &'static str| {
        pocox_pb::issue_credential_in_namespace(&admin, namespace, LONG_TTL, Some(label.into()))
    };
    let host_key = issue("host").await.expect("host credential");
    let phone_key = issue("phone").await.expect("phone credential");
    let removed_key = issue("removed").await.expect("removed credential");
    assert_eq!(host_key.namespace, namespace);
    assert_eq!(host_key.label.as_deref(), Some("host"));
    assert!(!pocox_pb::relay_instance_id(&admin)
        .await
        .expect("instance id")
        .is_empty());
    assert_ne!(host_key.key_id, phone_key.key_id);
    assert_ne!(host_key.key_id, namespace);

    let host = RelaySession::new(addr.clone(), host_key.credential.clone());
    let phone = RelaySession::new(addr.clone(), phone_key.credential.clone());
    let removed = RelaySession::new(addr.clone(), removed_key.credential.clone());

    let backend = echo().await;
    let key = "pcxu:test-user:mac:app:default";
    let _registration = pocox_pb::register(&host, RegisterOptions {
        key: key.into(),
        local_addr: backend,
        codec: true,
    })
    .await
    .expect("registration");

    // A key issued the old way owns its own namespace and sees none of this.
    let outsider_key = pocox_pb::issue_credential(&admin, LONG_TTL, None)
        .await
        .expect("outsider credential");
    assert_eq!(outsider_key.namespace, outsider_key.key_id);
    let outsider = RelaySession::new(addr, outsider_key.credential);
    assert!(pocox_pb::keys(&outsider)
        .await
        .expect("outsider keys")
        .is_empty());
    assert_eq!(pocox_pb::keys(&phone).await.expect("phone keys"), [key]);

    // Removing a device costs its peers nothing.
    pocox_pb::revoke_credential(&admin, removed_key.key_id)
        .await
        .expect("revoke");
    assert!(pocox_pb::keys(&removed).await.is_err(), "a revoked key must be refused");
    let reservation = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("reserve a port");
    let local = reservation.local_addr().expect("reserved port");
    drop(reservation);
    let _connection = pocox_pb::subscribe(&phone, SubscribeOptions {
        key: key.into(),
        local_addr: local.to_string(),
    })
    .await
    .expect("subscription");
    round_trip(local).await;

    // A retiring key gets a shorter life with the same text, and says so in a
    // listing.
    let renewed = pocox_pb::renew_credential(&admin, phone_key.key_id, Duration::from_secs(30))
        .await
        .expect("shorten");
    assert_eq!(renewed.credential, phone_key.credential);
    assert!(renewed.expires_at < phone_key.expires_at);
    let live = pocox_pb::live_credentials(&admin).await.expect("listing");
    let listed = live
        .iter()
        .find(|key| key.key_id == phone_key.key_id)
        .expect("phone is live");
    assert_eq!(listed.namespace, namespace);
    assert_eq!(listed.expires_at, renewed.expires_at);
    assert!(!live.iter().any(|key| key.key_id == removed_key.key_id), "a revoked key is not live");

    // Only an allocated namespace can be issued into.
    assert!(pocox_pb::issue_credential_in_namespace(&admin, outsider_key.key_id, LONG_TTL, None)
        .await
        .is_err());
}
