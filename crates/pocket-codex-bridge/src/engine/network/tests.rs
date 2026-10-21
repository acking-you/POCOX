use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};

use super::*;

#[test]
fn settings_preserve_credentials_privately_and_reject_invalid_edits() {
    let dir = tempfile::tempdir().expect("directory");
    assert_eq!(proxy(dir.path()).expect("old config"), None);
    let value = "socks5://alice:private-password@127.0.0.1:1080";
    set_proxy(dir.path(), value).expect("save");
    assert_eq!(proxy(dir.path()).expect("load").as_deref(), Some(value));
    let config = load_config(dir.path()).expect("config");
    assert!(!format!("{config:?}").contains("private-password"));
    for invalid in [
        "file:///tmp/private-password",
        "http://alice:private-password@localhost:0",
        "http://proxy:80/path",
    ] {
        let error = set_proxy(dir.path(), invalid).expect_err("invalid");
        assert!(!format!("{error:#}").contains("private-password"));
        assert_eq!(proxy(dir.path()).expect("unchanged").as_deref(), Some(value));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let permissions = std::fs::metadata(dir.path().join("config.toml"))
            .expect("file")
            .permissions();
        assert_eq!(permissions.mode() & 0o777, 0o600);
    }
    set_proxy(dir.path(), " ").expect("clear");
    assert_eq!(proxy(dir.path()).expect("load"), None);
}

#[tokio::test]
async fn http_proxy_authenticates_and_loopback_stays_direct() {
    let dir = tempfile::tempdir().expect("directory");
    let proxy = TcpListener::bind("127.0.0.1:0").await.expect("proxy");
    let address = proxy.local_addr().expect("address");
    set_proxy(dir.path(), &format!("http://alice:secret@{address}")).expect("setting");
    let server = tokio::spawn(async move {
        let (mut socket, _) = proxy.accept().await.expect("accept");
        let mut bytes = Vec::new();
        while !bytes.ends_with(b"\r\n\r\n") {
            bytes.push(socket.read_u8().await.expect("header"));
        }
        let request = String::from_utf8(bytes).expect("request");
        assert!(request.starts_with("GET http://release.invalid/manifest HTTP/1.1"));
        assert!(request
            .to_lowercase()
            .contains("proxy-authorization: basic ywxpy2u6c2vjcmv0"));
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
            .await
            .expect("response");
    });
    let http = client(dir.path())
        .expect("builder")
        .timeout(Duration::from_secs(3))
        .build()
        .expect("client");
    assert_eq!(
        http.get("http://release.invalid/manifest")
            .send()
            .await
            .expect("proxied")
            .text()
            .await
            .expect("body"),
        "ok"
    );
    server.await.expect("proxy completed");

    // A dead configured proxy must not intercept a loopback account backend.
    let local = TcpListener::bind("127.0.0.1:0").await.expect("local");
    let address = local.local_addr().expect("address");
    let server = tokio::spawn(async move {
        let (mut socket, _) = local.accept().await.expect("accept");
        let mut bytes = [0; 4096];
        let size = socket.read(&mut bytes).await.expect("request");
        assert!(!String::from_utf8_lossy(&bytes[..size]).contains("proxy-authorization"));
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            .await
            .expect("response");
    });
    http.get(format!("http://{address}"))
        .send()
        .await
        .expect("direct");
    server.await.expect("local completed");
    // A failed proxy never silently sends the request directly instead.
    assert!(http.get("http://release.invalid/").send().await.is_err());
}

#[tokio::test]
async fn socks5_uses_password_auth_and_remote_dns() {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("proxy");
    let address = listener.local_addr().expect("address");
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.expect("accept");
        assert_eq!(socket.read_u8().await.expect("version"), 5);
        let count = socket.read_u8().await.expect("methods");
        let mut methods = vec![0; count.into()];
        socket.read_exact(&mut methods).await.expect("methods");
        assert!(methods.contains(&2));
        socket.write_all(&[5, 2]).await.expect("select auth");
        assert_eq!(socket.read_u8().await.expect("auth version"), 1);
        let length = socket.read_u8().await.expect("username length");
        let mut user = vec![0; length.into()];
        socket.read_exact(&mut user).await.expect("username");
        let length = socket.read_u8().await.expect("password length");
        let mut password = vec![0; length.into()];
        socket.read_exact(&mut password).await.expect("password");
        assert_eq!(user, b"alice");
        assert_eq!(password, b"secret");
        socket.write_all(&[1, 0]).await.expect("auth accepted");
        let mut connect = [0; 4];
        socket.read_exact(&mut connect).await.expect("connect");
        assert_eq!(connect, [5, 1, 0, 3]);
        let length = socket.read_u8().await.expect("domain length");
        let mut domain = vec![0; length.into()];
        socket.read_exact(&mut domain).await.expect("domain");
        assert_eq!(domain, b"release.invalid");
        assert_eq!(socket.read_u16().await.expect("port"), 80);
        socket
            .write_all(&[5, 0, 0, 1, 127, 0, 0, 1, 0, 80])
            .await
            .expect("connected");
        let mut request = [0; 4096];
        assert!(socket.read(&mut request).await.expect("request") > 0);
        socket
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
            .await
            .expect("response");
    });
    let http = builder(Some(&format!("socks5://alice:secret@{address}")))
        .expect("builder")
        .timeout(Duration::from_secs(3))
        .build()
        .expect("client");
    assert_eq!(
        http.get("http://release.invalid/")
            .send()
            .await
            .expect("proxy")
            .text()
            .await
            .expect("body"),
        "ok"
    );
    server.await.expect("proxy completed");
}

#[tokio::test]
async fn redirects_keep_the_proxy_and_https_uses_connect() {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("proxy");
    let address = listener.local_addr().expect("address");
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.expect("first request");
        let mut bytes = Vec::new();
        while !bytes.ends_with(b"\r\n\r\n") {
            bytes.push(socket.read_u8().await.expect("header"));
        }
        assert!(String::from_utf8_lossy(&bytes).starts_with("GET http://release.invalid/"));
        socket.write_all(b"HTTP/1.1 302 Found\r\nLocation: https://cdn.invalid/file\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await.expect("redirect");
        let (mut socket, _) = listener.accept().await.expect("redirected request");
        let mut bytes = Vec::new();
        while !bytes.ends_with(b"\r\n\r\n") {
            bytes.push(socket.read_u8().await.expect("header"));
        }
        let request = String::from_utf8(bytes).expect("request");
        assert!(request.starts_with("CONNECT cdn.invalid:443 HTTP/1.1"));
        assert!(request
            .to_lowercase()
            .contains("proxy-authorization: basic ywxpy2u6c2vjcmv0"));
        socket
            .write_all(
                b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            )
            .await
            .expect("unavailable CDN");
    });
    let http = builder(Some(&format!("http://alice:secret@{address}")))
        .expect("builder")
        .timeout(Duration::from_secs(3))
        .build()
        .expect("client");
    assert!(http.get("http://release.invalid/").send().await.is_err());
    server.await.expect("proxy completed");
}
