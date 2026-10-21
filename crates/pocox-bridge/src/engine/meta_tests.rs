#[test]
fn pending_upload_context_changes_with_credentials_but_not_ui_settings() {
    let dir = tempfile::tempdir().expect("support");
    let initial = super::upload_context_at(dir.path()).expect("context");
    crate::engine::config::update_config(dir.path(), |cfg| {
        cfg.set_locale("zh");
        Ok(())
    })
    .expect("locale");
    assert_eq!(super::upload_context_at(dir.path()).expect("context"), initial);
    crate::engine::config::update_config(dir.path(), |cfg| {
        cfg.set_account_session("fixture-token", "fixture-refresh", "alice", Some("a".into()));
        Ok(())
    })
    .expect("account");
    let account = super::upload_context_at(dir.path()).expect("context");
    assert_ne!(account, initial);
    assert!(!account.contains("fixture"), "credentials never leave in the grant");
    crate::engine::config::update_config(dir.path(), |cfg| {
        cfg.set_account_backend("https://other.invalid");
        Ok(())
    })
    .expect("backend");
    assert_ne!(super::upload_context_at(dir.path()).expect("context"), account);
}

use super::*;

async fn file_server(responses: Vec<String>) -> (Url, tokio::task::JoinHandle<Vec<String>>) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("listen");
    let url =
        Url::parse(&format!("http://{}/fs/thread-file", listener.local_addr().expect("address")))
            .expect("url");
    let server = tokio::spawn(async move {
        let mut requests = Vec::new();
        for response in responses {
            let (mut socket, _) = listener.accept().await.expect("accept");
            let mut bytes = [0; 4096];
            let count = socket.read(&mut bytes).await.expect("request");
            requests.push(String::from_utf8_lossy(&bytes[..count]).into_owned());
            socket
                .write_all(response.as_bytes())
                .await
                .expect("response");
        }
        requests
    });
    (url, server)
}

#[tokio::test]
async fn file_browser_falls_back_only_on_missing_route() {
    let dir = tempfile::tempdir().expect("tempdir");
    for (status, fallback) in [(404, true), (403, true), (500, true), (404, false)] {
        let legacy = status == 404 && fallback;
        let mut responses = vec![format!(
            "HTTP/1.1 {status} Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )];
        if legacy {
            responses.push(
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: \
                 close\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
                    .into(),
            );
        }
        let (url, server) = file_server(responses).await;
        let legacy_url =
            fallback.then(|| url.join("/fs/read?path=%2Froot%2Freport.txt").expect("url"));
        let destination = dir.path().join(format!("{status}-{fallback}"));
        let result = download_file(url, legacy_url, &destination).await;
        let requests = server.await.expect("server");
        assert_eq!(result.is_ok(), legacy);
        assert_eq!(destination.exists(), legacy);
        assert_eq!(requests.len(), if legacy { 2 } else { 1 });
        if legacy {
            assert!(requests[1].starts_with("GET /fs/read?path=%2Froot%2Freport.txt "));
            assert_eq!(std::fs::read(destination).expect("download"), b"hello");
        }
    }
}

#[tokio::test]
async fn error_bodies_have_size_and_time_limits() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let (url, server) = file_server(vec![format!(
        "HTTP/1.1 500 Error\r\nContent-Length: 70000\r\nConnection: close\r\n\r\n{}",
        "x".repeat(70000)
    )])
    .await;
    let response = stream_client().get(url).send().await.expect("response");
    let error = ensure_ok(response).await.expect_err("500").to_string();
    assert!(error.contains("truncated"));
    assert!(error.len() < 66000);
    server.await.expect("server");

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("listen");
    let url = format!("http://{}", listener.local_addr().expect("address"));
    let server = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.expect("accept");
        let mut bytes = [0; 4096];
        assert!(socket.read(&mut bytes).await.expect("request") > 0);
        socket
            .write_all(b"HTTP/1.1 500 Error\r\nContent-Length: 5\r\n\r\n")
            .await
            .expect("headers");
        std::future::pending::<()>().await;
    });
    let response = stream_client().get(url).send().await.expect("headers");
    let error = tokio::time::timeout(
        Duration::from_secs(2),
        ensure_ok_with_timeout(response, Duration::from_millis(20)),
    )
    .await
    .expect("bounded error read")
    .expect_err("500")
    .to_string();
    assert!(error.contains("500") && error.contains("timed out"));
    server.abort();
}

#[tokio::test]
async fn download_streams_exact_bytes_and_removes_partial_files() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let dir = tempfile::tempdir().expect("tempdir");
    for (name, body, declared) in
        [("complete", "hello", 5), ("partial", "abc", 5), ("oversized", "abcdef", 5)]
    {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("listen");
        let address = listener.local_addr().expect("address");
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept");
            let mut request = [0u8; 4096];
            let _ = socket.read(&mut request).await.expect("request");
            socket
                .write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nx-file-size: \
                         {declared}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    )
                    .as_bytes(),
                )
                .await
                .expect("response");
        });
        let response = reqwest::Client::new()
            .get(format!("http://{address}"))
            .send()
            .await
            .expect("response");
        let destination = dir.path().join(name);
        let result = download_response(response, &destination, false).await;
        server.await.expect("server");
        if name == "complete" {
            result.expect("download");
            assert_eq!(std::fs::read(destination).expect("saved bytes"), body.as_bytes());
        } else {
            assert!(result.is_err());
            assert!(!destination.exists());
        }
    }
}

#[test]
fn meta_key_derives_from_any_pocox_key() {
    // app / api / meta all map to the same-device, same-name meta key.
    assert_eq!(meta_key_of("pcx:dev:app:work").unwrap(), "pcx:dev:meta:work");
    assert_eq!(meta_key_of("pcx:dev:api:x").unwrap(), "pcx:dev:meta:x");
    assert_eq!(meta_key_of("pcx:dev:meta:y").unwrap(), "pcx:dev:meta:y");
    // A non-pocox key is rejected rather than silently mis-derived.
    assert!(meta_key_of("not-a-key").is_err());
}

#[test]
fn remote_follow_setup_returns_errors_without_panicking_the_stream_task() {
    super::super::runtime::init(std::env::temp_dir()).expect("test runtime");
    runtime::runtime().block_on(async {
        let task = tokio::spawn(async {
            follow_session("pcx:unconfigured:app:test", "test", |_| false).await
        });
        // Even an unconfigured remote must report an error through the stream,
        // instead of panicking while recursively entering the Tokio runtime.
        let outcome = tokio::time::timeout(Duration::from_secs(3), task)
            .await
            .expect("unconfigured transport should fail locally");
        assert!(outcome.is_ok(), "remote follow initialization panicked: {outcome:?}");
    });
}

#[test]
#[ignore = "manual: POCOX_SUPPORT_DIR, POCOX_FOLLOW_SERVICE and POCOX_FOLLOW_THREAD select a live \
            host"]
fn real_remote_follow_remains_open_and_receives_updates() {
    let support = std::env::var("POCOX_SUPPORT_DIR").expect("support dir");
    let service = std::env::var("POCOX_FOLLOW_SERVICE").expect("service");
    let thread = std::env::var("POCOX_FOLLOW_THREAD").expect("thread");
    runtime::init(support.into()).expect("init");
    runtime::runtime().block_on(async {
        let start = std::time::Instant::now();
        let mut updates = 0;
        tokio::time::timeout(
            Duration::from_secs(90),
            follow_session(&service, &thread, |event| {
                assert!(event.history_revision.is_some());
                assert!(event.items.is_empty());
                updates += 1;
                eprintln!("follow update={updates} elapsed_ms={}", start.elapsed().as_millis());
                start.elapsed() < Duration::from_secs(45)
            }),
        )
        .await
        .expect("follow kept delivering")
        .expect("follow completed without a disconnect");
        assert!(updates >= 4);
    });
}

#[test]
fn session_follow_parser_handles_chunked_events_and_keepalives() {
    let mut pending = b": session-follow\n\ndata: {\"liveness\":{\"thread_id\":\"t1\",\"turn_state\":\"incomplete\",\"held_open\":true,\"safety\":\"ownedRunning\",\"allows_resume\":false,\"requires_takeover\":false,\"holders\":[]},\"items\":[{\"id\":\"i1\",\"item_type\":\"agentMessage\",\"title\":\"\",\"text\":\"hel".to_vec();

    let keepalive = take_sse_event(&mut pending).expect("keepalive frame");
    assert!(decode_follow_event(&keepalive).expect("decode").is_none());
    assert!(take_sse_event(&mut pending).is_none());

    pending.extend_from_slice(b"lo\",\"images\":[]}]}\n\n");
    let event = take_sse_event(&mut pending).expect("completed data frame");
    let update = decode_follow_event(&event)
        .expect("valid snapshot")
        .expect("data event");
    assert_eq!(update.liveness.thread_id, "t1");
    assert_eq!(update.items[0].text, "hello");
    assert!(pending.is_empty());
}

/// A connection dropped mid-request is exactly what a supervised service
/// restart looks like from the client's pool: the request went out and no
/// response came back. Retrying on a fresh connection is what recovers it —
/// the failure this whole path exists for.
#[tokio::test]
async fn idempotent_request_survives_a_dropped_connection() {
    use std::{
        io::{Read, Write},
        sync::{
            atomic::{AtomicU32, Ordering},
            Arc,
        },
    };

    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    let seen = Arc::new(AtomicU32::new(0));
    let seen_srv = seen.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let seen = seen_srv.clone();
            // One thread per connection: a peer that never finishes its
            // request must not stall the listener for the retry that follows.
            std::thread::spawn(move || {
                let mut stream = stream;
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf);
                let n = seen.fetch_add(1, Ordering::SeqCst);
                if n == 0 {
                    // First attempt: take the request, then hang up without
                    // answering — "connection closed before message
                    // completed", exactly what a restarting service does.
                    return;
                }
                let _ = stream.write_all(
                    b"HTTP/1.1 200 OK\r\ncontent-length: 11\r\nconnection: close\r\n\r\n{\"ok\":true}",
                );
                let _ = stream.flush();
            });
        }
    });

    let url: Url = format!("http://{addr}/sessions").parse().expect("url");
    let (status, _body) = retry_idempotent(url.clone(), || async {
        let resp = client().get(url.clone()).send().await?;
        let status = resp.status();
        Ok((status, resp.bytes().await?))
    })
    .await
    .expect("the retry should recover the dropped first attempt");
    assert!(status.is_success());
    assert_eq!(seen.load(Ordering::SeqCst), 2, "one failure, then one success");
}

/// A response whose headers arrive but whose BODY is cut off must spend the
/// retry budget too — reading the body outside the retried unit let this
/// escape entirely, and it is the likeliest shape on a large transcript.
#[tokio::test]
async fn a_truncated_body_is_retried_like_a_dropped_send() {
    use std::{
        io::{Read, Write},
        sync::{
            atomic::{AtomicU32, Ordering},
            Arc,
        },
    };

    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    let seen = Arc::new(AtomicU32::new(0));
    let seen_srv = seen.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let seen = seen_srv.clone();
            std::thread::spawn(move || {
                let mut stream = stream;
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf);
                let n = seen.fetch_add(1, Ordering::SeqCst);
                if n == 0 {
                    // Promise 200 bytes, hang up after 5: headers say 200 OK,
                    // so only draining the body reveals the failure.
                    let _ =
                        stream.write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 200\r\n\r\n{\"ok\"");
                    let _ = stream.flush();
                    return;
                }
                let _ = stream.write_all(
                    b"HTTP/1.1 200 OK\r\ncontent-length: 11\r\n\
                      connection: close\r\n\r\n{\"ok\":true}",
                );
                let _ = stream.flush();
            });
        }
    });

    #[derive(Deserialize)]
    struct Body {
        ok: bool,
    }
    let url: Url = format!("http://{addr}/sessions").parse().expect("url");
    let out: Body = get_json(url)
        .await
        .expect("the truncated body must be retried");
    assert!(out.ok);
    assert_eq!(seen.load(Ordering::SeqCst), 2, "truncated, then complete");
}

/// The progress the UI mirrors must name the attempt ABOUT TO RUN: a count
/// that lags by one never reaches the maximum, so "10/10" would be
/// unreachable and every number would understate what is happening.
#[tokio::test]
async fn retry_progress_names_the_upcoming_attempt() {
    use std::io::Read;

    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut stream = stream;
            let mut buf = [0u8; 512];
            let _ = stream.read(&mut buf);
            drop(stream); // never answers
        }
    });

    let mut rx = subscribe_retries();
    let url: Url = format!("http://{addr}/sessions").parse().expect("url");
    let out: Result<serde_json::Value> = get_json(url).await;
    assert!(out.is_err());

    let first = rx.try_recv().expect("a first retry tick");
    // The first attempt failed, so the NEXT one is #2 — not #1.
    assert_eq!(first.attempt, 2);
    assert_eq!(first.max_attempts, 10);
    let mut last = first;
    while let Ok(p) = rx.try_recv() {
        last = p;
    }
    // And the count reaches the cap rather than stopping at 9.
    assert_eq!(last.attempt, last.max_attempts);
}

/// The budget is finite: a service that never answers must eventually
/// surface an error rather than retrying behind a spinner forever.
#[tokio::test]
async fn a_persistently_dead_service_gives_up_and_reports_attempts() {
    use std::io::Read;

    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut stream = stream;
            let mut buf = [0u8; 512];
            let _ = stream.read(&mut buf);
            drop(stream); // never answers
        }
    });

    let url: Url = format!("http://{addr}/sessions").parse().expect("url");
    // Two attempts rather than the default ten, so the test doesn't sit
    // through the real backoff curve.
    let mut retry = BoundedRetry::with_bounds(2, Duration::from_millis(1));
    let mut attempts = 0;
    let err = loop {
        attempts += 1;
        match client().get(url.clone()).send().await {
            Ok(_) => panic!("the server must not answer"),
            Err(e) if is_transient(&e) => {
                if retry.fail().is_none() {
                    break e;
                }
            },
            Err(e) => break e,
        }
    };
    assert!(is_transient(&err));
    assert_eq!(attempts, 2);
    assert_eq!(retry.attempts(), 2);
}
