//! V2 frames, catalogs, history and prompts against the 2.0.32 wire shapes.

use std::sync::{Arc, Mutex};

use axum::{
    extract::{Path, State},
    http::StatusCode,
    routing::post,
    Json, Router,
};
use serde_json::{json, Value};

use super::{events, shape};
use crate::opencode::{
    client::{Client, ClientError},
    public,
    schema::{Model, Prompt},
    wire::Dialect,
};

fn decode(frame: Value) -> Option<(String, Value)> {
    events::decode(frame.to_string().as_bytes())
        .expect("valid frame")
        .map(|event| (event.kind, event.properties))
}

#[test]
fn frames_keep_status_and_step_boundaries_and_drop_token_deltas() {
    let connected = decode(json!({"id":"evt_1","type":"server.connected","data":{}}));
    assert_eq!(connected.map(|(kind, _)| kind).as_deref(), Some("server.connected"));
    for (kind, status) in [("started", "busy"), ("succeeded", "idle"), ("interrupted", "idle")] {
        let frame = json!({"id":"evt_9","type":format!("session.execution.{kind}"),
            "data":{"sessionID":"ses_a"}});
        assert_eq!(
            decode(frame),
            Some(("session.status".into(), json!({"sessionID":"ses_a","status":{"type":status}})))
        );
    }
    let (kind, status) = decode(json!({"id":"evt_2","type":"session.status",
        "data":{"sessionID":"ses_a","status":{"type":"busy"}}}))
    .expect("status");
    assert_eq!((kind.as_str(), &status["status"]["type"]), ("session.status", &json!("busy")));
    for frame in [
        json!({"id":"evt_3","type":"permission.asked","data":{"id":"per_1","sessionID":"ses_a",
            "action":"bash","resources":["ls"]}}),
        json!({"id":"evt_4","type":"form.created","data":{"form":{"id":"frm_1","sessionID":"ses_a"}}}),
        json!({"id":"evt_5","type":"session.tool.success","data":{"sessionID":"ses_a"}}),
    ] {
        assert_eq!(decode(frame), Some(("host.changed".into(), json!({"sessionID":"ses_a"}))));
    }
    assert!(decode(json!({"id":"evt_6","type":"form.created",
        "data":{"form":{"id":"frm_2","sessionID":"global"}}}))
    .is_none());
    assert!(decode(json!({"id":"evt_7","type":"session.text.delta",
        "data":{"sessionID":"ses_a","delta":"tok"}}))
    .is_none());
}

#[test]
fn catalog_keeps_usable_models_and_their_image_input() {
    let catalog = |default: Value| {
        shape::catalog(
            // Only configured providers are listed; `a` is not.
            serde_json::from_value(json!([
                {"id":"b","name":"Provider B","activation":"disabled"}
            ]))
            .expect("providers"),
            serde_json::from_value(json!([
                {"id":"m/1","providerID":"a","name":"One","variants":[{"id":"high"}],
                 "status":"active","enabled":true,"capabilities":{"input":["text","image"]}},
                {"id":"text","providerID":"a","name":"Text","variants":[],"status":"beta","enabled":true,
                 "capabilities":{"input":["text"]}},
                {"id":"old","providerID":"a","name":"Old","variants":[],"status":"deprecated","enabled":true},
                {"id":"off","providerID":"b","name":"Off","variants":[],"status":"active","enabled":true}
            ]))
            .expect("models"),
            serde_json::from_value(default).expect("default"),
            serde_json::from_value(json!([
                {"id":"build","name":"Build","mode":"primary","hidden":false},
                {"id":"title","name":"Title","mode":"primary","hidden":true},
                {"id":"explore","name":"Explore","mode":"subagent","hidden":false}
            ]))
            .expect("agents"),
            serde_json::from_value(json!([{"name":"review","description":"Review"}]))
                .expect("commands"),
        )
    };
    let without_default = catalog(json!({"location":{"directory":"/p"}}));
    let keys: Vec<_> = without_default.models.iter().map(|m| m.key()).collect();
    assert_eq!(keys, ["a/m/1", "a/text"]);
    assert_eq!(without_default.models[0].provider_name, "a");
    assert_eq!(without_default.models[0].variants, ["high"]);
    assert!(without_default.models[0].images && !without_default.models[1].images);
    assert!(without_default.defaults.is_empty());
    assert_eq!(without_default.agents.len(), 1);
    assert_eq!(without_default.agents[0].name, "build");
    assert_eq!(without_default.commands[0].name, "review");
    let with_default = catalog(json!({"data":{"id":"m/1","providerID":"a"}}));
    assert_eq!(with_default.defaults.get("a").map(String::as_str), Some("m/1"));
}

#[test]
fn history_is_oldest_first_with_turns_and_their_selection() {
    let assistant = |id: &str, agent: &str| {
        json!({"type":"assistant","id":id,"agent":agent,"model":{"id":"m/1","providerID":"a"},
            "finish":"stop","time":{"created":2,"completed":3},
            "content":[{"type":"text","text":"Answer"},
                {"type":"tool","id":"call_1","name":"bash","time":{"created":2,"completed":3},
                 "state":{"status":"completed","input":{"command":"ls"},
                    "content":[{"type":"text","text":"file"}]}}]})
    };
    let failed = |id: &str, message: &str| {
        json!({"type":"idle","id":id,"outcome":"failed","time":{"created":9},
            "error":{"type":"unknown","message":message}})
    };
    let mut page: shape::Page<shape::Message> = serde_json::from_value(json!({
        "data":[
            failed("msg_8", "resume limit"),
            {"type":"user","id":"msg_7","text":"Third","time":{"created":7}},
            failed("msg_6", "boom"),
            assistant("msg_5", "plan"),
            {"type":"user","id":"msg_4","text":"Second","time":{"created":4}},
            {"type":"agent-switched","id":"msg_3","agent":"plan","time":{"created":3}},
            assistant("msg_2", "build"),
            {"type":"user","id":"msg_1","text":"First","time":{"created":1},"files":[
                {"data":"AA==","mime":"image/png","source":{"type":"inline"},"name":"a.png"},
                {"data":"eA==","mime":"text/plain","source":{"type":"uri","uri":"file:///p/x.txt"}}]}
        ],
        "cursor":{"next":"older"}
    }))
    .expect("page");
    assert_eq!(page.next(20).expect("cursor"), None, "a short page is the end");
    let history: Vec<_> = shape::history("ses_a", page.data)
        .into_iter()
        .map(public::message)
        .collect();
    let ids: Vec<_> = history.iter().map(|m| m.info["id"].as_str()).collect();
    assert_eq!(ids, ["msg_1", "msg_2", "msg_4", "msg_5", "msg_7", "msg_8"].map(Some));
    // A failed run's error reaches its reply, or is one when nothing answered.
    assert!(history[1].info["error"].is_null() && !history[3].info["error"].is_null());
    assert_eq!(
        (&history[5].info["role"], &history[5].info["parentID"]),
        (&json!("assistant"), &json!("msg_7"))
    );
    assert!(!history[5].info["error"].is_null());
    assert_eq!(history[1].info["parentID"], "msg_1");
    assert_eq!(history[3].info["parentID"], "msg_4");
    assert_eq!(history[0].info["agent"], "build");
    assert_eq!(history[2].info["agent"], "plan");
    assert_eq!(history[2].info["model"]["modelID"], "m/1");
    assert_eq!(history[0].parts[0]["text"], "First");
    let urls: Vec<_> = history[0].parts[1..].iter().map(|p| &p["url"]).collect();
    assert_eq!(urls, [&json!("data:image/png;base64,AA=="), &json!("file:///p/x.txt")]);
    let tool = &history[1].parts[1];
    assert_eq!((&tool["tool"], &tool["state"]["output"]), (&json!("bash"), &json!("file")));
}

#[test]
fn forms_map_labels_to_values_and_unanswerable_forms_only_reject() {
    let form = |fields: Value| -> shape::Form {
        serde_json::from_value(json!({"id":"frm_1","sessionID":"ses_a","title":"Setup",
            "fields":fields}))
        .expect("form")
    };
    let choices = json!([
        {"type":"string","key":"mode","title":"Mode","options":[{"value":"y","label":"Yes"}]},
        {"type":"multiselect","key":"tags","options":[{"value":"a","label":"A"},
            {"value":"b","label":"B"}]},
        {"type":"string","key":"name"}
    ]);
    let card = form(choices.clone()).into_native();
    assert_eq!(card["questions"].as_array().map(Vec::len), Some(3));
    assert_eq!(card["questions"][2]["custom"], true, "a field without options is free text");
    let answer = form(choices.clone())
        .answer(&[vec!["Yes".into()], vec!["A".into(), "B".into()], vec!["Ada".into()]])
        .expect("answer");
    assert_eq!(Value::Object(answer), json!({"mode":"y","tags":["a","b"],"name":"Ada"}));
    assert!(matches!(
        form(choices).answer(&[vec!["No".into()], vec![], vec!["Ada".into()]]),
        Err(ClientError::UnsupportedForm)
    ));
    let card = form(json!([{"type":"number","key":"count"}])).into_native();
    assert_eq!(card["questions"][0]["custom"], false);
    assert_eq!(card["questions"][0]["options"], json!([]));
}

type Log = Arc<Mutex<Vec<(String, Value)>>>;

async fn record(
    State((log, agent)): State<(Log, StatusCode)>,
    Path((_, action)): Path<(String, String)>,
    Json(body): Json<Value>,
) -> (StatusCode, Json<Value>) {
    log.lock().expect("log").push((action.clone(), body));
    match action.as_str() {
        "agent" => (agent, Json(Value::Null)),
        "prompt" => (StatusCode::OK, Json(json!({"data":{"id":"msg_x"}}))),
        _ => (StatusCode::NO_CONTENT, Json(Value::Null)),
    }
}

async fn prompt(
    agent: StatusCode,
    prompt: &Prompt,
    select: bool,
) -> (Result<(), ClientError>, Log) {
    let log = Log::default();
    let router = Router::new()
        .route("/api/session/{session}/{action}", post(record))
        .with_state((log.clone(), agent));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("loopback fixture");
    let origin = format!("http://{}/", listener.local_addr().expect("bound listener"));
    let server = tokio::spawn(async move {
        axum::serve(listener, router)
            .await
            .expect("loopback fixture");
    });
    let client = Client::new(&origin, None, Dialect::V2).expect("client");
    let result = client.prompt("ses_a", "/p", prompt, select).await;
    server.abort();
    (result, log)
}

#[tokio::test]
async fn a_changed_selection_precedes_the_prompt_and_a_refusal_sends_nothing() {
    let mut input = Prompt {
        message_id: Some("msg_x".into()),
        model: Some(Model {
            provider_id: "a".into(),
            model_id: "m/1".into(),
        }),
        agent: Some("build".into()),
        variant: None,
        parts: vec![json!({"type":"text","text":"Hello"})],
    };
    let actions = |log: &Log| -> Vec<String> {
        log.lock()
            .expect("log")
            .iter()
            .map(|(action, _)| action.clone())
            .collect()
    };
    let (result, log) = prompt(StatusCode::NO_CONTENT, &input, true).await;
    result.expect("prompt");
    assert_eq!(actions(&log), ["model", "agent", "prompt"]);
    assert_eq!(log.lock().expect("log")[0].1, json!({"model":{"id":"m/1","providerID":"a"}}));
    assert_eq!(log.lock().expect("log")[2].1, json!({"text":"Hello","id":"msg_x"}));

    let (result, log) = prompt(StatusCode::NO_CONTENT, &input, false).await;
    result.expect("unchanged selection");
    assert_eq!(actions(&log), ["prompt"]);

    let (result, log) = prompt(StatusCode::BAD_REQUEST, &input, true).await;
    let error = result.expect_err("refused agent");
    assert!(
        matches!(error, ClientError::Preflight {
            selection: "agent"
        }) && error.not_sent()
    );
    assert_eq!(actions(&log), ["model", "agent"]);

    input
        .parts
        .push(json!({"type":"file","mime":"image/png","url":"data:image/png;base64,AA=="}));
    let (result, log) = prompt(StatusCode::NO_CONTENT, &input, false).await;
    result.expect("image prompt");
    assert_eq!(
        log.lock().expect("log")[0].1,
        json!({"text":"Hello","files":[{"uri":"data:image/png;base64,AA=="}],"id":"msg_x"})
    );
}
