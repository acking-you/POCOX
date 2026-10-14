//! Local deterministic model transport, never a real provider or account.

use std::{convert::Infallible, sync::Arc};

use axum::{
    extract::State,
    response::{sse::Event, Sse},
    routing::post,
    Json, Router,
};
use serde_json::{json, Value};
use tokio::{
    sync::{mpsc, Notify},
    task::JoinHandle,
};
use tokio_stream::wrappers::ReceiverStream;

pub struct Fixture {
    pub address: String,
    pub gate: Arc<Notify>,
    task: JoinHandle<()>,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.gate.notify_waiters();
        self.task.abort();
    }
}

pub async fn start() -> Fixture {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("model fixture listener");
    let address = format!("http://{}/v1", listener.local_addr().expect("fixture address"));
    let gate = Arc::new(Notify::new());
    let router = Router::new()
        .route("/v1/chat/completions", post(answer))
        .with_state(gate.clone());
    let task = tokio::spawn(async move {
        let _ = axum::serve(listener, router).await;
    });
    Fixture {
        address,
        gate,
        task,
    }
}

async fn answer(
    State(gate): State<Arc<Notify>>,
    Json(body): Json<Value>,
) -> Sse<ReceiverStream<Result<Event, Infallible>>> {
    let messages = body["messages"].as_array().cloned().unwrap_or_default();
    let user = messages
        .iter()
        .rev()
        .find(|m| m["role"] == "user")
        .map(|m| m["content"].to_string())
        .unwrap_or_default();
    let tool_done = messages.last().is_some_and(|m| m["role"] == "tool");
    let tool = if user.contains("PERMISSION_FIXTURE") && !tool_done {
        Some(json!({"id":"call_fixture_bash","type":"function","index":0,"function":{
            "name":"bash","arguments":json!({"command":"printf PCX_PERMISSION_OK","description":"Isolated permission fixture"}).to_string()}}))
    } else if user.contains("QUESTION_FIXTURE") && !tool_done {
        Some(json!({"id":"call_fixture_question","type":"function","index":0,"function":{
            "name":"question","arguments":json!({"questions":[{"question":"Choose fixture values","header":"Fixture",
                "multiple":true,"options":[{"label":"A","description":"first"},{"label":"B","description":"second"}]}]}).to_string()}}))
    } else {
        None
    };
    let (sender, stream) = mpsc::channel(8);
    tokio::spawn(async move {
        let held = user.contains("HOLD_FIXTURE");
        let delta = match &tool {
            Some(tool) => json!({"role":"assistant","tool_calls":[tool]}),
            None => json!({"role":"assistant","content":"NATIVE_PREFIX "}),
        };
        if sender.send(Ok(chunk(delta, None))).await.is_err() {
            return;
        }
        if held {
            tokio::select! { _ = sender.closed() => return, _ = gate.notified() => {} }
        }
        if tool.is_none()
            && sender
                .send(Ok(chunk(json!({"content":"COMPLETE"}), None)))
                .await
                .is_err()
        {
            return;
        }
        let reason = if tool.is_some() { "tool_calls" } else { "stop" };
        let _ = sender.send(Ok(chunk(json!({}), Some(reason)))).await;
        let _ = sender.send(Ok(Event::default().data("[DONE]"))).await;
    });
    Sse::new(ReceiverStream::new(stream))
}

fn chunk(delta: Value, reason: Option<&str>) -> Event {
    Event::default().data(
        json!({"id":"chatcmpl_fixture","object":"chat.completion.chunk",
        "created":1,"model":"test","choices":[{"index":0,"delta":delta,"finish_reason":reason}]})
        .to_string(),
    )
}
