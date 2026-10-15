use serde_json::json;

use super::*;

pub(super) fn snapshot() -> Snapshot {
    serde_json::from_value(json!({
        "session":{"id":"ses_fixture","title":"Fixture","directory":"/project","time":{"created":1,"updated":2}},
        "access":{"sessionId":"ses_fixture","hostId":"host","generation":1,"sourceGeneration":"source",
            "provider":"opencode","mode":"write","writer":"this_host","turn":"running","exclusion":"pocket",
            "reason":"owned","detail":null,"holder":null,"canRelease":false,"recheck":true},
        "window":{"messages":[
            {"info":{"id":"msg_user","role":"user"},"parts":[{"id":"prt_user","type":"text","text":"Question"}]},
            {"info":{"id":"msg_assistant","role":"assistant","parentID":"msg_user"},
             "parts":[{"id":"prt_answer","type":"text","text":"前缀"}]}
        ],"nextBefore":"native_cursor","sequence":4,"gaps":[],"connected":true},
        "permissions":[],"questions":[],"options":{"model":"provider/nested/model","agent":"build","variant":"careful"},
        "turnId":"msg_user","operationError":null
    })).expect("fixture")
}

fn identity() -> Identity {
    Identity {
        host_id: "host".into(),
        generation: 1,
        source_generation: "source".into(),
    }
}

pub(super) struct Fixture {
    pub(super) link: Link,
    _runtime: tokio::runtime::Runtime,
}

impl Fixture {
    fn new() -> Self {
        Self::with_client(Gateway::new("http://127.0.0.1:9/").expect("client"))
    }

    pub(super) fn with_client(client: Gateway) -> Self {
        let key = (uuid::Uuid::new_v4().to_string(), "pcx:fixture:opencode:test".into());
        let info = Info {
            api: 1,
            protocol: "opencode-http".into(),
            identity: identity(),
            version: "fixture".into(),
        };
        let shared = Arc::new(Mutex::new(Shared {
            info,
            image_input: false,
            healthy: true,
            sessions: HashMap::new(),
            bytes: HashMap::new(),
            cursors: HashMap::new(),
            turn_pages: HashMap::new(),
        }));
        let (tx, _) = broadcast::channel(64);
        let link = Link {
            key: key.clone(),
            client: client.clone(),
            shared: shared.clone(),
            tx: tx.clone(),
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("fixture runtime");
        let task = runtime.spawn(std::future::pending());
        lock(&CONNS).insert(key, Conn {
            client,
            shared,
            tx,
            task,
            subscription: "unused-native-test".into(),
        });
        Self {
            link,
            _runtime: runtime,
        }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        if let Some(conn) = lock(&CONNS).remove(&self.link.key) {
            conn.task.abort();
        }
    }
}

#[test]
fn stale_host_source_and_replaced_connections_cannot_commit() {
    let fixture = Fixture::new();
    let link = &fixture.link;
    let mut next = snapshot();
    next.access.source_generation = Some("replacement".into());
    assert!(link.accept(&identity(), next).is_err());
    let mut next = snapshot();
    next.access.host_id = "other".into();
    assert!(link.accept(&identity(), next).is_err());
    assert!(link.accept(&identity(), snapshot()).expect("current"));
    let removed = lock(&CONNS).remove(&link.key).expect("registered");
    removed.task.abort();
    assert!(link.commit(&identity(), |_| ()).is_err());
    let other = Fixture::new();
    assert_ne!(other.link.key.0, link.key.0);
    assert!(link.commit(&identity(), |_| ()).is_err());
}

#[test]
fn snapshots_never_roll_back_a_newer_live_prefix() {
    let fixture = Fixture::new();
    let link = &fixture.link;
    let mut current = snapshot();
    current.window.sequence = 9;
    current.window.messages[1].parts[0]["text"] = json!("前缀继续");
    assert!(link.accept(&identity(), current).expect("fresh"));
    assert!(!link
        .accept(&identity(), snapshot())
        .expect("old answer discarded"));
    assert_eq!(
        lock(&link.shared).sessions["ses_fixture"].window.messages[1].parts[0]["text"],
        "前缀继续"
    );
}

#[test]
fn full_snapshots_replace_prefixes_once_and_keep_native_boundaries() {
    let fixture = Fixture::new();
    let mut rx = fixture.link.tx.subscribe();
    let old = snapshot();
    let mut next = old.clone();
    next.window.sequence += 1;
    next.window.messages[1].parts[0]["text"] = json!("前缀继续");
    events::announce(&fixture.link, &identity(), Some(&old), &next);
    let mut items = vec![];
    while let Ok(event) = rx.try_recv() {
        if event.item_id.is_some() {
            items.push(event);
        }
    }
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].kind, "item/completed");
    assert_eq!(items[0].text.as_deref(), Some("前缀继续"));
    events::announce(&fixture.link, &identity(), Some(&next), &next);
    while let Ok(event) = rx.try_recv() {
        assert!(event.item_id.is_none(), "unchanged items are not resent");
    }
    let history = projection::history(&next);
    assert!(history.has_older);
    assert!(history.first_turn_id.is_none());
    assert_eq!(history.items[1].turn_id, "msg_user");
    assert_eq!(history.active_turn_id.as_deref(), Some("msg_user"));
}

#[test]
fn gaps_attachments_and_large_tool_content_are_explicit_and_bounded() {
    let mut next = snapshot();
    next.window.gaps.push("prt_answer".into());
    next.window.messages[1].parts.push(json!({"id":"prt_file","type":"file","url":"file:///private/secret.png","mime":"image/png"}));
    next.window.messages[1].parts.push(json!({"id":"prt_tool","type":"tool","tool":"read",
        "state":{"status":"completed","input":{"huge":"x".repeat(100_000)},"output":"汉".repeat(100_000)}}));
    let items = projection::items(&next);
    assert!(items.iter().all(|item| item.images.is_empty()));
    assert!(items
        .iter()
        .any(|item| item.id == "#stream-gap:prt_answer" && item.text == "unavailable"));
    let tool = items
        .iter()
        .find(|item| item.id == "prt_tool")
        .expect("tool");
    let value: serde_json::Value =
        serde_json::from_str(&tool.text).expect("tool JSON remains intact");
    assert!(value["input"].is_null());
    assert!(value["output"].as_str().expect("output").len() < 132_000);
    assert!(items.iter().any(|item| item.id == "#input:prt_tool"));
}

#[test]
fn pending_handles_bind_host_and_session_and_retain_multiple_choices() {
    let mut next = snapshot();
    next.permissions
        .push(json!({"id":"req_1","permission":"bash","patterns":["pwd"],"always":[]}));
    next.questions.push(json!({"id":"req_2","questions":[{"header":"Choice","question":"Pick two","multiple":true,"custom":false,
        "options":[{"label":"A","description":"first"},{"label":"B","description":"second"}]}]}));
    let pending = events::pending(&next, &identity());
    assert_eq!(pending.len(), 2);
    let question = pending
        .values()
        .find(|e| e.kind == "item/tool/requestUserInput")
        .expect("question");
    let body: serde_json::Value = serde_json::from_str(&question.raw).expect("question wire");
    assert_eq!(body["questions"][0]["multiple"], true);
    assert_eq!(body["questions"][0]["isOther"], false);
    assert_eq!(body["questions"][0]["id"], "q0");
    let mut other = identity();
    other.host_id = "replacement".into();
    assert!(events::pending(&next, &other)
        .keys()
        .all(|id| !pending.contains_key(id)));
    let history = projection::history(&next);
    assert!(
        history
            .items
            .iter()
            .all(|item| item.questions_json.is_none()),
        "historical messages do not recreate live question requests"
    );
}

#[test]
fn inactive_windows_are_evicted_before_running_windows() {
    let fixture = Fixture::new();
    fixture
        .link
        .accept(&identity(), snapshot())
        .expect("active");
    for n in 0..12 {
        let mut next = snapshot();
        next.session.id = format!("ses_{n}");
        next.access.session_id = next.session.id.clone();
        next.turn_id = None;
        next.window.sequence = n + 10;
        fixture.link.accept(&identity(), next).expect("window");
    }
    let view = lock(&fixture.link.shared);
    assert_eq!(view.sessions.len(), 8);
    assert!(view.sessions.contains_key("ses_fixture"));
    assert_eq!(view.bytes.len(), 8);
}

#[test]
fn question_answers_keep_native_order_multiple_labels_and_explicit_skip() {
    use pocket_codex_host_svc::opencode::host::Answer;
    match ops::question_answer(r#"{"q1":["free text"],"q0":["A","B"]}"#, 2).expect("answers") {
        Answer::Question {
            answers,
        } => assert_eq!(answers, vec![vec!["A", "B"], vec!["free text"]]),
        _ => panic!("expected answers"),
    }
    assert!(matches!(ops::question_answer("{}", 2).expect("skip"), Answer::RejectQuestion));
    assert!(ops::question_answer(r#"{"q0":{"answers":["A"]}}"#, 1).is_err());
    assert!(ops::question_answer(r#"{"q0":["A"]}"#, 2).is_err());
}

#[test]
fn turn_outcomes_require_positive_native_completion() {
    for (error, completed, finish, expected) in [
        (None, false, None, "failed"),
        (Some("MessageAbortedError"), false, None, "interrupted"),
        (None, true, Some("length"), "failed"),
        (None, true, Some("stop"), "completed"),
    ] {
        let mut snapshot = snapshot();
        snapshot.turn_id = None;
        let info = &mut snapshot.window.messages[1].info;
        if let Some(error) = error {
            info["error"] = json!({"name":error});
        }
        if completed {
            info["time"] = json!({"completed":123});
        }
        info["finish"] = json!(finish);
        let wire: serde_json::Value =
            serde_json::from_str(&projection::ended(&snapshot, "msg_user").raw).expect("event");
        assert_eq!(wire["turn"]["status"], expected);
    }
}

#[test]
fn failed_models_are_not_answers_and_live_history_share_safe_recovery_data() {
    let mut next = snapshot();
    next.turn_id = None;
    next.window.messages[1].parts.clear();
    let info = &mut next.window.messages[1].info;
    info["modelID"] = json!("unavailable-model");
    info["providerID"] = json!("provider");
    info["error"] = json!({"name":"APIError","data":{"statusCode":403,"isRetryable":false,
        "message":"SECRET", "responseBody":r#"{"error":{"type":"RegionError"}}"#,
        "responseHeaders":{"authorization":"SECRET"}}});
    let history = projection::history(&next);
    assert!(history.turns[0].assistant_text.is_empty());
    let failure = history.items.last().expect("failure row");
    assert_eq!(failure.item_type, "modelError");
    assert_eq!(failure.turn_id, "msg_user");
    let body: serde_json::Value = serde_json::from_str(&failure.text).expect("safe data");
    assert_eq!(body["code"], "region_unavailable");
    assert_eq!(body["model"], "unavailable-model");
    assert!(!failure.text.contains("SECRET"));
    assert_eq!(projection::item_event("ses_fixture", failure).text, Some(failure.text.clone()));
    let ended: serde_json::Value =
        serde_json::from_str(&projection::ended(&next, "msg_user").raw).expect("terminal");
    assert_eq!(ended["turn"]["status"], "failed");
    assert_eq!(ended["turn"]["error"], body);
    assert!(ended["turn"].get("interruption").is_none());
    assert_eq!(body["itemId"], failure.id);
    assert_eq!(body["turnId"], failure.turn_id);
    // A native supplement's failure belongs to its prompt, while the
    // completed event still ends the original admitted turn.
    next.window.messages[1].info["parentID"] = json!("msg_user_supplement");
    let ended: serde_json::Value = serde_json::from_str(&projection::ended(&next, "msg_user").raw)
        .expect("supplement terminal");
    assert_eq!(ended["turn"]["id"], "msg_user");
    assert_eq!(ended["turn"]["error"]["turnId"], "msg_user_supplement");
    assert_eq!(ended["turn"]["error"]["itemId"], failure.id);
    next.window.messages[1].info["error"] = json!({"name":"MessageAbortedError"});
    let stopped = projection::items(&next).pop().expect("stopped");
    assert_eq!(stopped.item_type, "interrupted");
    let ended: serde_json::Value = serde_json::from_str(&projection::ended(&next, "msg_user").raw)
        .expect("stopped supplement terminal");
    assert_eq!(ended["turn"]["id"], "msg_user");
    assert_eq!(ended["turn"]["status"], "interrupted");
    assert!(ended["turn"]["error"].is_null());
    assert_eq!(
        ended["turn"]["interruption"],
        json!({
            "itemId": stopped.id, "turnId": stopped.turn_id,
        })
    );
}

#[test]
fn incomplete_prompt_history_is_marked_instead_of_becoming_retry_input() {
    let mut next = snapshot();
    next.window.messages[0].parts[0]["text"] = json!("汉".repeat(50_000));
    next.window.messages[0]
        .parts
        .push(json!({"id":"prt_input_image","type":"file","url":"file:///host/image.png"}));
    let items = projection::items(&next);
    assert!(items[0].text.len() < 132_000);
    for id in ["#input:msg_user", "#attachments:msg_user"] {
        assert!(items.iter().any(|item| item.id == id
            && item.item_type == "contentOmitted"
            && item.turn_id == "msg_user"));
    }
}

#[test]
fn completed_reasoning_only_output_keeps_provenance_and_original_part_identity() {
    let fixture = Fixture::new();
    let mut rx = fixture.link.tx.subscribe();
    let mut running = snapshot();
    running.window.messages[1].parts = vec![json!({"id":"prt_reasoning", "type":"reasoning",
        "text":"Thinking. 最终内容也在这里。"})];
    let mut done = running.clone();
    done.turn_id = None;
    done.window.messages[1].info["time"] = json!({"completed":123000});
    done.window.messages[1].info["finish"] = json!("stop");
    events::announce(&fixture.link, &identity(), Some(&running), &done);
    let output = rx.try_recv().expect("completed part before turn end");
    assert_eq!(output.item_id.as_deref(), Some("prt_reasoning"));
    assert_eq!(output.item_type.as_deref(), Some("reasoningOutput"));
    assert_eq!(output.text.as_deref(), Some("Thinking. 最终内容也在这里。"));
    let item = projection::items(&done).pop().expect("history output");
    assert_eq!(item.item_type, "reasoningOutput");
    assert_eq!(item.text, output.text.expect("text"));
    assert_eq!(projection::items(&running)[1].item_type, "reasoning");
    for finish in ["tool-calls", "length"] {
        done.window.messages[1].info["finish"] = json!(finish);
        assert_eq!(projection::items(&done)[1].item_type, "reasoning");
    }
    done.window.messages[1].info["finish"] = json!("stop");
    done.window.messages[1]
        .parts
        .push(json!({"id":"prt_final","type":"text","text":"Separate answer"}));
    let mixed = projection::items(&done);
    assert_eq!(mixed[1].item_type, "reasoning");
    assert_eq!(mixed[2].item_type, "agentMessage");
}
