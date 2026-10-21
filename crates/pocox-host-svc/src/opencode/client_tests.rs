//! Loopback transport bounds, using no installed engine or user history.

use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use axum::{
    extract::{Query, State},
    routing::get,
    Json, Router,
};
use serde_json::json;

use super::*;
use crate::opencode::schema::Message;

#[derive(Clone)]
struct Fixture {
    messages: Vec<Message>,
    requests: Arc<Mutex<Vec<HashMap<String, String>>>>,
}

struct Server(tokio::task::JoinHandle<()>);

impl Drop for Server {
    fn drop(&mut self) {
        self.0.abort();
    }
}

async fn page(
    State(state): State<Fixture>,
    Query(query): Query<HashMap<String, String>>,
) -> impl axum::response::IntoResponse {
    let limit: usize = query["limit"].parse().expect("numeric page limit");
    state.requests.lock().expect("request log").push(query);
    let messages: Vec<_> = state.messages.into_iter().take(limit).collect();
    ([("x-next-cursor", "opaque-next")], Json(messages))
}

async fn fixture(messages: Vec<Message>) -> (Client, Fixture, Server) {
    let state = Fixture {
        messages,
        requests: Default::default(),
    };
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("loopback fixture");
    let client = Client::new(
        &format!("http://{}/", listener.local_addr().expect("bound listener")),
        None,
        Dialect::V1,
    )
    .expect("local client");
    let router = Router::new()
        .route("/session/ses_fixture/message", get(page))
        .with_state(state.clone());
    let server = Server(tokio::spawn(async move {
        axum::serve(listener, router)
            .await
            .expect("loopback fixture");
    }));
    (client, state, server)
}

fn message(parts: Value) -> Message {
    Message {
        info: json!({"id":"msg_fixture","role":"user"}),
        parts: serde_json::from_value(parts).expect("message parts"),
    }
}

#[tokio::test]
async fn large_input_images_remain_readable_without_relaying_the_original_bytes() {
    let image = format!("data:image/png;base64,{}", "A".repeat(9 * 1024 * 1024));
    let (client, _, _server) = fixture(vec![message(json!([
        {"id":"prt_text","type":"text","text":"Original question"},
        {"id":"prt_image","type":"file","mime":"image/png","url":image}
    ]))])
    .await;
    assert!(
        matches!(
            client
                .http
                .get::<Value>(&["session", "ses_fixture", "message"], None, &[("limit", "1")])
                .await,
            Err(ClientError::TooLarge)
        ),
        "ordinary native reads retain their smaller bound"
    );
    let page = client
        .messages("ses_fixture", "/project", None)
        .await
        .expect("bounded history page");
    assert_eq!(page.messages.len(), 1);
    assert_eq!(page.messages[0].parts[0]["text"], "Original question");
    assert_eq!(page.messages[0].parts[1]["type"], "file");
    assert_eq!(page.messages[0].parts[1]["url"], "");
    assert_eq!(page.next_before.as_deref(), Some("opaque-next"));
    assert!(
        serde_json::to_vec(&page.messages)
            .expect("public window")
            .len()
            < 1024
    );
}

#[tokio::test]
async fn oversized_pages_shrink_without_losing_the_native_history_cursor() {
    let row =
        message(json!([{"id":"prt_text","type":"text","text":"x".repeat(MAX_BODY / 2 + 128)}]));
    let (client, state, _server) = fixture(vec![row.clone(), row]).await;
    let page = client
        .messages("ses_fixture", "/中文 project", Some("opaque-before"))
        .await
        .expect("bounded history page");
    assert_eq!(page.messages.len(), 1);
    assert_eq!(page.next_before.as_deref(), Some("opaque-next"));
    let requests = state.requests.lock().expect("request log");
    assert_eq!(
        requests
            .iter()
            .map(|q| q["limit"].as_str())
            .collect::<Vec<_>>(),
        ["20", "10", "5", "2", "1"]
    );
    assert!(requests
        .iter()
        .all(|q| q["before"] == "opaque-before" && q["directory"] == "/中文 project"));
}

#[tokio::test]
async fn one_oversized_public_message_is_an_error_never_an_empty_history() {
    let row = message(json!([{"id":"prt_text","type":"text","text":"x".repeat(MAX_BODY)}]));
    let (client, _, _server) = fixture(vec![row]).await;
    assert!(matches!(
        client.messages("ses_fixture", "/project", None).await,
        Err(ClientError::TooLarge)
    ));
}
