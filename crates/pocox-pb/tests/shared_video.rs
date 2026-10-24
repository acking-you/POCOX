//! A saved service's stable relay key supports browsing and seeking after
//! the publishing host reconnects, through the other device's local port.
use std::time::Duration;

use pb_mapper_testkit::{Relay, TEST_ADMIN_KEY};
use pocox_pb::{RegisterOptions, RelaySession, SubscribeOptions};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

async fn request(address: std::net::SocketAddr, path: &str, range: bool) -> String {
    tokio::time::timeout(Duration::from_secs(10), async {
        let mut stream = TcpStream::connect(address)
            .await
            .expect("isolated video fixture");
        let extra = if range { "Range: bytes=4-7\r\n" } else { "" };
        stream
            .write_all(
                format!(
                    "GET {path} HTTP/1.1\r\nHost: localhost\r\n{extra}Connection: close\r\n\r\n"
                )
                .as_bytes(),
            )
            .await
            .expect("isolated video fixture");
        let mut response = String::new();
        stream
            .read_to_string(&mut response)
            .await
            .expect("isolated video fixture");
        response
    })
    .await
    .expect("bounded HTTP request")
}

#[tokio::test]
async fn another_device_browses_and_seeks_videos_again_after_host_republishes() {
    let relay = Relay::start("saved-video").await;
    let admin = RelaySession::new(relay.addr().to_string(), TEST_ADMIN_KEY);
    let issued = pocox_pb::issue_credential(&admin, Duration::from_secs(600), None)
        .await
        .expect("isolated video fixture");
    // The account backend hands its devices the same scoped relay credential.
    let host = RelaySession::new(relay.addr().to_string(), issued.credential.clone());
    let phone = RelaySession::new(relay.addr().to_string(), issued.credential);
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("isolated video fixture");
    let backend = listener.local_addr().expect("isolated video fixture");
    let server = tokio::spawn(async move {
        for _ in 0..4 {
            let (mut stream, _) = listener.accept().await.expect("isolated video fixture");
            let mut headers = Vec::new();
            while !headers.ends_with(b"\r\n\r\n") {
                headers.push(stream.read_u8().await.expect("isolated video fixture"));
                assert!(headers.len() < 4096);
            }
            let headers = String::from_utf8(headers).expect("isolated video fixture");
            let (status, extra, body) = if headers.starts_with("GET /static/clip.mp4 ") {
                assert!(headers.contains("Range: bytes=4-7"));
                (
                    "206 Partial Content",
                    "Content-Range: bytes 4-7/16\r\nAccept-Ranges: bytes\r\n",
                    "4567",
                )
            } else {
                assert!(headers.starts_with("GET /static/?sort=name "));
                ("200 OK", "", "<video src=\"clip.mp4\" controls></video>")
            };
            stream
                .write_all(
                    format!(
                        "HTTP/1.1 {status}\r\n{extra}Content-Length: {}\r\nConnection: \
                         close\r\n\r\n{body}",
                        body.len()
                    )
                    .as_bytes(),
                )
                .await
                .expect("isolated video fixture");
            stream.shutdown().await.expect("isolated video fixture");
        }
    });
    let key = "pcxu:test-account:studio:port:5555";
    let options = RegisterOptions {
        key: key.into(),
        local_addr: backend.to_string(),
        codec: true,
    };
    let mut registration = pocox_pb::register(&host, options.clone())
        .await
        .expect("isolated video fixture");
    let reservation = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("isolated video fixture");
    let local = reservation.local_addr().expect("isolated video fixture");
    drop(reservation);
    let connection = pocox_pb::subscribe(&phone, SubscribeOptions {
        key: key.into(),
        local_addr: local.to_string(),
    })
    .await
    .expect("isolated video fixture");
    assert!(
        pocox_pb::keys(&admin)
            .await
            .expect("isolated video fixture")
            .is_empty(),
        "private service is outside the admin namespace"
    );
    for attempt in 0..2 {
        if attempt == 1 {
            registration.stop().await.expect("isolated video fixture");
            registration = pocox_pb::register(&host, options.clone())
                .await
                .expect("isolated video fixture");
        }
        let page = request(local, "/static/?sort=name", false).await;
        assert!(page.starts_with("HTTP/1.1 200 OK"));
        assert!(page.ends_with("<video src=\"clip.mp4\" controls></video>"));
        let seek = request(local, "/static/clip.mp4", true).await;
        assert!(seek.starts_with("HTTP/1.1 206 Partial Content"));
        assert!(seek.contains("Content-Range: bytes 4-7/16"));
        assert!(seek.ends_with("4567"));
    }
    server.await.expect("isolated video fixture");
    connection.stop().await.expect("isolated video fixture");
    registration.stop().await.expect("isolated video fixture");
}
