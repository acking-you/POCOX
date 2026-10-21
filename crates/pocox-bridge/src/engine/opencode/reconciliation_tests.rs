//! Controller reconciliation uses a bounded loopback gateway, no user host.
use serde_json::{json, Value};

use super::*;

struct Server(tokio::task::JoinHandle<()>);
impl Drop for Server {
    fn drop(&mut self) {
        self.0.abort();
    }
}

fn server(handler: impl Fn(&str) -> (u16, Value) + Send + Sync + 'static) -> (Gateway, Server) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    runtime::init(std::env::temp_dir()).expect("test runtime");
    runtime::runtime().block_on(async {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("valid test fixture");
        let client = Gateway::new(&format!(
            "http://{}/",
            listener.local_addr().expect("valid test fixture")
        ))
        .expect("valid test fixture");
        let task = tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.expect("valid test fixture");
                let mut bytes = vec![0; 8192];
                let count = socket.read(&mut bytes).await.expect("valid test fixture");
                let request = String::from_utf8_lossy(&bytes[..count]);
                let path = request
                    .split_whitespace()
                    .nth(1)
                    .expect("valid test fixture");
                let (status, body) = handler(path);
                let body = body.to_string();
                let response = format!(
                    "HTTP/1.1 {status} Reply\r\nContent-Type: application/json\r\nContent-Length: \
                     {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                socket
                    .write_all(response.as_bytes())
                    .await
                    .expect("valid test fixture");
            }
        });
        (client, Server(task))
    })
}

fn info() -> Value {
    json!({"api":1,"protocol":"opencode-http","hostId":"host","generation":1,"sourceGeneration":"source","version":"fixture"})
}

#[test]
fn deleted_session_is_removed_without_blocking_other_session_updates() {
    let (client, _server) = server(|path| {
        if path.ends_with("/info") {
            return (200, info());
        }
        if path.contains("ses_deleted") {
            return (404, json!({"code":"session_not_found"}));
        }
        let mut snapshot = tests::snapshot();
        snapshot.window.sequence = 9;
        (200, serde_json::to_value(snapshot).expect("valid test fixture"))
    });
    let fixture = tests::Fixture::with_client(client);
    let link = &fixture.link;
    let mut events = link.tx.subscribe();
    let mut deleted = tests::snapshot();
    deleted.session.id = "ses_deleted".into();
    deleted.access.session_id = deleted.session.id.clone();
    link.accept(&link.identity(), deleted)
        .expect("valid test fixture");
    link.accept(&link.identity(), tests::snapshot())
        .expect("valid test fixture");
    lock(&link.shared)
        .cursors
        .insert("ses_deleted".into(), Some("cursor".into()));
    runtime::runtime()
        .block_on(events::refresh(link, &link.identity()))
        .expect("valid test fixture");
    runtime::runtime()
        .block_on(events::refresh(link, &link.identity()))
        .expect("valid test fixture");
    let view = lock(&link.shared);
    assert!(!view.sessions.contains_key("ses_deleted"));
    assert!(!view.bytes.contains_key("ses_deleted"));
    assert!(!view.cursors.contains_key("ses_deleted"));
    assert_eq!(view.sessions["ses_fixture"].window.sequence, 9);
    assert!(view.healthy);
    let mut deleted_event = false;
    let mut withdrawn = false;
    while let Ok(event) = events.try_recv() {
        deleted_event |=
            event.kind == "thread/deleted" && event.thread_id.as_deref() == Some("ses_deleted");
        withdrawn |= event.kind == "acp/session/updated" && event.raw.contains("false");
    }
    assert!(deleted_event && withdrawn);
}

#[test]
fn failed_settings_refresh_preserves_errors_and_cached_session() {
    for cached in [false, true] {
        let (client, _server) = server(|_| (503, json!({"code":"not_ready"})));
        let fixture = tests::Fixture::with_client(client);
        let link = &fixture.link;
        if cached {
            link.accept(&link.identity(), tests::snapshot())
                .expect("valid test fixture");
        }
        let error = settings::settings_for_link(link, "ses_fixture")
            .expect_err("a failed snapshot or catalog read is not empty settings");
        assert!(error.downcast_ref::<ClientError>().is_some());
        assert_eq!(lock(&link.shared).sessions.contains_key("ses_fixture"), cached);
        assert!(catalog_for_link(link, Some("/project")).is_err());
    }
}

#[test]
fn project_catalog_reads_never_reuse_the_connection_global_catalog() {
    let (client, _server) = server(|path| {
        let url =
            reqwest::Url::parse(&format!("http://localhost{path}")).expect("valid test fixture");
        let directory = url
            .query_pairs()
            .find(|(k, _)| k == "directory")
            .expect("valid test fixture")
            .1
            .into_owned();
        let project = directory
            .strip_prefix("/project-")
            .expect("valid test fixture");
        (
            200,
            json!({"identity": {"hostId":"host","generation":1,"sourceGeneration":"source"},"data":{
                "models":[{"provider":"native","providerName":"Native","id":project,"name":project,"variants":["careful"],"images":false}],
                "agents":[{"name":project}],"commands":[{"name":project,"source":"command","hints":[]}],
                "defaults":{},"providersConnected":1
            }}),
        )
    });
    let fixture = tests::Fixture::with_client(client);
    for project in ["A", "B", "A"] {
        let catalog = catalog_for_link(&fixture.link, Some(&format!("/project-{project}")))
            .expect("valid test fixture");
        assert_eq!(catalog.models[0].id, project);
        assert_eq!(catalog.commands[0].name, project);
        assert_eq!(catalog.agents[0].name, project);
    }
}

#[test]
fn access_detects_deletion_without_sse_including_uncached_sessions() {
    for cached in [false, true] {
        let (client, _server) = server(|path| {
            if path.ends_with("/info") {
                return (200, info());
            }
            (404, json!({"code":"session_not_found"}))
        });
        let fixture = tests::Fixture::with_client(client);
        let link = &fixture.link;
        let mut events = link.tx.subscribe();
        if cached {
            let mut released = tests::snapshot();
            released.access.reason = "released_here".into();
            link.accept(&link.identity(), released).expect("fixture");
        }
        let access = ops::access_for_link(link, "ses_fixture").expect("confirmed missing");
        assert_eq!(access.reason, "not_found");
        assert_eq!(access.mode, "blocked");
        assert!(!access.recheck && !access.can_release);
        assert!(!lock(&link.shared).sessions.contains_key("ses_fixture"));
        assert!(lock(&link.shared).healthy);
        let mut deleted = false;
        while let Ok(event) = events.try_recv() {
            deleted |=
                event.kind == "thread/deleted" && event.thread_id.as_deref() == Some("ses_fixture");
        }
        assert!(deleted, "even a never-cached displayed session must close");
    }
}

#[test]
fn failed_reads_preserve_sessions_and_emit_no_deletion() {
    for (status, code, replaced) in [
        (404, "native_request_failed", false),
        (503, "session_not_found", false),
        (404, "session_not_found", true),
        (503, "session_not_found", true),
    ] {
        let (client, _server) = server(move |path| {
            if path.ends_with("/info") {
                let mut info = info();
                if replaced {
                    info["hostId"] = json!("replacement");
                }
                return (200, info);
            }
            (status, json!({"code":code}))
        });
        let fixture = tests::Fixture::with_client(client);
        let link = &fixture.link;
        let mut events = link.tx.subscribe();
        link.accept(&link.identity(), tests::snapshot())
            .expect("fixture");
        for access in [false, true] {
            let result = if access {
                ops::access_for_link(link, "ses_fixture").map(|_| ())
            } else {
                runtime::runtime().block_on(events::refresh(link, &link.identity()))
            };
            assert!(result.is_err(), "HTTP {status}, {code}, replaced={replaced}, access={access}");
            assert!(lock(&link.shared).sessions.contains_key("ses_fixture"));
            assert!(events.try_recv().is_err());
        }
    }
}

#[test]
fn follow_detects_external_deletion_without_an_sse_invalidation() {
    let (client, _server) = server(|path| {
        if path.ends_with("/info") {
            return (200, info());
        }
        (404, json!({"code":"session_not_found"}))
    });
    let fixture = tests::Fixture::with_client(client);
    let link = &fixture.link;
    let mut events = link.tx.subscribe();
    link.accept(&link.identity(), tests::snapshot())
        .expect("fixture");
    runtime::runtime()
        .block_on(async {
            tokio::time::timeout(
                std::time::Duration::from_secs(5),
                follow::follow_link(link.clone(), "unused", "ses_fixture", |_| {
                    panic!("deleted history is never delivered")
                }),
            )
            .await
        })
        .expect("follow ends after the persisted read")
        .expect("confirmed deletion is not a failed stream");
    assert!(!lock(&link.shared).sessions.contains_key("ses_fixture"));
    let mut deleted = false;
    while let Ok(event) = events.try_recv() {
        deleted |= event.kind == "thread/deleted";
    }
    assert!(deleted);
}
