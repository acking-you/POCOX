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
            return (404, json!({"code":"native_request_failed"}));
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
    link.accept(&link.identity(), deleted, true)
        .expect("valid test fixture");
    link.accept(&link.identity(), tests::snapshot(), true)
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
fn unavailable_or_replaced_host_never_looks_like_a_deleted_session() {
    for status in [404, 503] {
        let (client, _server) = server(move |path| {
            if path.ends_with("/info") {
                let mut info = info();
                info["hostId"] = json!("replacement");
                return (200, info);
            }
            (status, json!({"code":"native_request_failed"}))
        });
        let fixture = tests::Fixture::with_client(client);
        let link = &fixture.link;
        link.accept(&link.identity(), tests::snapshot(), true)
            .expect("valid test fixture");
        assert!(runtime::runtime()
            .block_on(events::refresh(link, &link.identity()))
            .is_err());
        assert!(lock(&link.shared).sessions.contains_key("ses_fixture"));
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
    assert!(lock(&fixture.link.shared).catalog.models.is_empty());
}
