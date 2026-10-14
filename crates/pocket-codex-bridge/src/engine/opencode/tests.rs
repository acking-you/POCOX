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

struct Fixture {
    link: Link,
    _runtime: tokio::runtime::Runtime,
}

impl Fixture {
    fn new() -> Self {
        let key = (uuid::Uuid::new_v4().to_string(), "pcx:fixture:opencode:test".into());
        let client = Gateway::new("http://127.0.0.1:9/").expect("client");
        let info = Info {
            api: 1,
            protocol: "opencode-http".into(),
            identity: identity(),
            version: "fixture".into(),
        };
        let catalog = serde_json::from_value(
            json!({"models":[],"agents":[],"commands":[],"defaults":{},"providersConnected":0}),
        )
        .expect("catalog");
        let shared = Arc::new(Mutex::new(Shared {
            info,
            catalog,
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
    assert!(link.accept(&identity(), next, true).is_err());
    let mut next = snapshot();
    next.access.host_id = "other".into();
    assert!(link.accept(&identity(), next, true).is_err());
    assert!(link.accept(&identity(), snapshot(), true).expect("current"));
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
    assert!(link.accept(&identity(), current, true).expect("fresh"));
    assert!(!link
        .accept(&identity(), snapshot(), true)
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
fn vanished_turn_without_native_completion_never_claims_success() {
    let mut next = snapshot();
    next.turn_id = None;
    let event = projection::ended(&next, "msg_user");
    let body: serde_json::Value = serde_json::from_str(&event.raw).expect("event");
    assert_eq!(body["turn"]["status"], "failed");
    next.window.messages[1].info["error"] = json!({"name":"MessageAbortedError"});
    let body: serde_json::Value =
        serde_json::from_str(&projection::ended(&next, "msg_user").raw).expect("event");
    assert_eq!(body["turn"]["status"], "interrupted");
}

#[test]
fn inactive_windows_are_evicted_before_running_windows() {
    let fixture = Fixture::new();
    fixture
        .link
        .accept(&identity(), snapshot(), true)
        .expect("active");
    for n in 0..12 {
        let mut next = snapshot();
        next.session.id = format!("ses_{n}");
        next.access.session_id = next.session.id.clone();
        next.turn_id = None;
        next.window.sequence = n + 10;
        fixture
            .link
            .accept(&identity(), next, true)
            .expect("window");
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
fn truncated_native_completion_does_not_claim_success() {
    let mut snapshot = snapshot();
    snapshot.turn_id = None;
    snapshot.window.messages[1].info["time"] = json!({"completed":123});
    snapshot.window.messages[1].info["finish"] = json!("length");
    let wire: serde_json::Value =
        serde_json::from_str(&projection::ended(&snapshot, "msg_user").raw).expect("event");
    assert_eq!(wire["turn"]["status"], "failed");
    snapshot.window.messages[1].info["finish"] = json!("stop");
    let wire: serde_json::Value =
        serde_json::from_str(&projection::ended(&snapshot, "msg_user").raw).expect("event");
    assert_eq!(wire["turn"]["status"], "completed");
}
