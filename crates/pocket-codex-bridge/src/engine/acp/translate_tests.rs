use std::collections::HashMap;

use pocket_codex_host_svc::acp::fold::Transcript;

use super::*;

fn kinds(events: &[AppEvent]) -> Vec<&str> {
    events.iter().map(|e| e.kind.as_str()).collect()
}

/// What the session screen shows, applying events the way it does:
/// deltas append, anything else with text replaces.
#[derive(Default)]
struct Screen {
    items: HashMap<String, String>,
    order: Vec<String>,
}

impl Screen {
    fn apply(&mut self, events: &[AppEvent]) {
        for event in events {
            let (Some(id), Some(kind)) = (&event.item_id, &event.item_type) else { continue };
            let text = event.text.clone().unwrap_or_default();
            // As the session screen does: an empty notice removes it.
            if kind == CONTENT_OMITTED && text.is_empty() {
                self.items.remove(id);
                self.order.retain(|known| known != id);
                continue;
            }
            if !self.items.contains_key(id) {
                self.order.push(id.clone());
            }
            let entry = self.items.entry(id.clone()).or_default();
            if event.kind.contains("delta") {
                entry.push_str(&text);
            } else if !text.is_empty() {
                *entry = text;
            }
        }
    }

    fn agent_items(&self) -> Vec<(String, String)> {
        self.order
            .iter()
            .map(|id| (id.clone(), self.items[id].clone()))
            .collect()
    }
}

fn chunk(text: &str) -> Value {
    json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})
}

#[test]
fn a_live_turn_maps_to_shared_item_events() {
    let mut shared = Shared::default();
    let started = gateway_event(
        &mut shared,
        &json!({"type": "turn_started", "sessionId": "s", "turnId": "t", "userText": "q", "seq": 1}),
    );
    assert_eq!(kinds(&started), vec!["turn/started"]);
    let first = gateway_event(
        &mut shared,
        &json!({"type": "update", "sessionId": "s", "turnId": "t", "seq": 2,
        "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "He"}}}),
    );
    assert_eq!(kinds(&first), vec!["item/started", "item/agentMessage/delta"]);
    assert_eq!(first[0].item_id.as_deref(), Some("t:m1"), "the host's id");
    let tool = gateway_event(
        &mut shared,
        &json!({"type": "update", "sessionId": "s", "turnId": "t", "seq": 3,
        "update": {"sessionUpdate": "tool_call", "toolCallId": "c", "title": "ls", "kind": "execute", "status": "in_progress"}}),
    );
    // The reply the tool call follows has ended.
    assert_eq!(kinds(&tool), vec!["item/completed", "item/started"]);
    assert_eq!(tool[0].item_id.as_deref(), Some("t:m1"));
    assert_eq!(tool[1].item_type.as_deref(), Some("commandExecution"));
    let done = gateway_event(
        &mut shared,
        &json!({"type": "update", "sessionId": "s", "turnId": "t", "seq": 4,
        "update": {"sessionUpdate": "tool_call_update", "toolCallId": "c", "status": "completed"}}),
    );
    assert_eq!(done[0].kind, "item/completed");
    let ended = gateway_event(
        &mut shared,
        &json!({"type": "turn_ended", "sessionId": "s", "turnId": "t", "seq": 5,
        "outcome": {"kind": "stopped", "stopReason": "end_turn"}}),
    );
    assert_eq!(kinds(&ended), vec!["item/completed", "item/completed", "turn/completed"]);
    assert!(ended[2].raw.contains("\"completed\""));
    assert!(shared.running.is_empty());
}

#[test]
fn outcomes_are_never_upgraded_to_success() {
    for (outcome, status) in [
        (json!({"kind": "stopped", "stopReason": "cancelled"}), "interrupted"),
        (json!({"kind": "cancelled"}), "interrupted"),
        (json!({"kind": "stopped", "stopReason": "refusal"}), "failed"),
        (json!({"kind": "agentExited"}), "failed"),
        (json!({"kind": "failed", "message": "boom"}), "failed"),
    ] {
        let event = turn_completed("s", "t", Some(&outcome));
        let raw: Value = serde_json::from_str(&event.raw).expect("json");
        assert_eq!(raw["turn"]["status"], status, "{outcome}");
    }
    let unknown: Value = serde_json::from_str(&turn_completed("s", "t", None).raw).expect("json");
    assert_eq!(unknown["turn"]["status"], "failed");
}

#[test]
fn permissions_carry_the_handle_and_exact_options() {
    let mut shared = Shared::default();
    let asked = gateway_event(
        &mut shared,
        &json!({"type": "permission", "handle": "h1", "sessionId": "s",
        "turnId": "t", "toolCall": {"title": "Run"}, "options": [{"optionId": "opt:1 ✓", "name": "Allow", "kind": "allow_once"}]}),
    );
    assert_eq!(asked[0].kind, PERMISSION_REQUESTED);
    assert_eq!(asked[0].request_id.as_deref(), Some("h1"));
    assert!(asked[0].raw.contains("opt:1 ✓"));
    let gone = gateway_event(
        &mut shared,
        &json!({"type": "permission_resolved", "handle": "h1", "sessionId": "s"}),
    );
    assert_eq!(gone[0].kind, "serverRequest/resolved");
    assert!(shared.permissions.is_empty());
}

#[test]
fn reconcile_plans_recorded_outcomes_and_restores_pending_requests() {
    let mut shared = Shared {
        generation: 3,
        ..Shared::default()
    };
    shared.running.insert("s".into(), "t".into());
    shared.running.insert("u".into(), "lost".into());
    shared
        .permissions
        .insert("old".into(), json!({"handle": "old", "sessionId": "s"}));
    let plan = reconcile(
        &mut shared,
        &json!({
            "generation": 4, "seq": 9, "info": {"phase": {"state": "ready"}, "hostId": "h"},
            "sessions": [{"sessionId": "v", "runningTurnId": "n"}],
            "permissions": [{"handle": "new", "sessionId": "v", "toolCall": {}, "options": []}],
            "recentTurns": [{"sessionId": "s", "turnId": "t", "outcome": {"kind": "agentExited"}}],
        }),
    );
    let mut ended = plan.ended.clone();
    ended.sort_by(|a, b| a.0.cmp(&b.0));
    assert_eq!(ended.len(), 2);
    assert_eq!(ended[0].2, Some(json!({"kind": "agentExited"})));
    assert_eq!(ended[1].2, None, "an unknown outcome is not assumed");
    assert_eq!(plan.running, vec![("v".to_string(), "n".to_string())]);
    assert_eq!(plan.started, vec![("v".to_string(), "n".to_string(), false)]);
    let events = &plan.events;
    assert!(
        events.iter().all(|e| e.kind != "turn/started"),
        "successors are announced by the caller, after completions"
    );
    assert!(events.iter().any(|e| e.kind == "serverRequest/resolved"));
    assert!(events
        .iter()
        .any(|e| e.kind == PERMISSION_REQUESTED && e.request_id.as_deref() == Some("new")));
    assert_eq!(shared.generation, 4);
    assert!(!shared.healthy, "a snapshot is not an open event stream");
}

/// The host folds every update; a controller joins after `joined`
/// updates, recovers through history at that watermark, then applies
/// the stream from an older watermark. The screen must end up exactly
/// with the host's items, ids and text.
#[test]
fn joining_mid_turn_shows_exactly_the_hosts_items() {
    let updates = [
        chunk("He"),
        chunk("llo"),
        json!({"sessionUpdate": "tool_call", "toolCallId": "c", "title": "ls", "kind": "execute", "status": "completed"}),
        chunk("Done"),
        chunk(" now"),
    ];
    let joined = 2;
    let mut host = Transcript::default();
    host.begin_turn("t", "q", &[]);
    let mut events = vec![json!({"type": "turn_started", "sessionId": "s", "turnId": "t",
        "userText": "q", "seq": 1})];
    let mut at_join = None;
    for (n, update) in updates.iter().enumerate() {
        host.apply(Some("t"), update);
        events.push(json!({"type": "update", "sessionId": "s", "turnId": "t",
            "update": update, "seq": n as u64 + 2}));
        if n + 1 == joined {
            at_join = Some(host.turns[0].clone());
        }
    }
    let history = json!({"window": [at_join.expect("joined")], "truncated": false,
        "seq": joined as u64 + 1, "generation": 1,
        "session": {"runningTurnId": "t"}});

    let mut shared = Shared::default();
    let mut screen = Screen::default();
    screen.apply(&install(&mut shared, "s", "t", &history));
    for event in &events {
        screen.apply(&gateway_event(&mut shared, event));
    }
    screen.apply(&gateway_event(
        &mut shared,
        &json!({"type": "turn_ended", "sessionId": "s", "turnId": "t", "seq": 99,
            "outcome": {"kind": "stopped", "stopReason": "end_turn"}}),
    ));
    let expected: Vec<(String, String)> = host.turns[0]
        .items
        .iter()
        .filter(|item| item.kind != ItemKind::UserMessage)
        .map(|item| {
            let mapped = app_item(item, "t");
            (mapped.id, mapped.text)
        })
        .collect();
    assert_eq!(screen.agent_items(), expected);
    assert_eq!(screen.items["t:m1"], "Hello", "no missing or duplicated prefix");
}

#[test]
fn a_turn_that_ended_during_a_gap_completes_with_its_final_text() {
    let mut host = Transcript::default();
    host.begin_turn("t", "q", &[]);
    host.apply(Some("t"), &chunk("full answer"));
    let history = json!({"window": [host.turns[0]], "generation": 2});
    let events = finished(
        "s",
        "t",
        Some(&history),
        Some(&json!({"kind": "stopped", "stopReason": "end_turn"})),
    );
    assert_eq!(kinds(&events), vec!["item/completed", "turn/completed"]);
    assert_eq!(events[0].text.as_deref(), Some("full answer"));
    assert_eq!(events[0].item_id.as_deref(), Some("t:m1"));
    // Without history the outcome is still reported, not invented, and
    // the missing items are said to be missing.
    let unread = finished("s", "t", None, None);
    assert_eq!(kinds(&unread), vec!["item/completed", "turn/completed"]);
    assert_eq!(unread[0].item_type.as_deref(), Some(CONTENT_OMITTED));
    assert_eq!(unread[0].text.as_deref(), Some(UNAVAILABLE));
}

#[test]
fn item_events_name_their_turn_and_dropped_content_gets_a_notice() {
    let mut shared = Shared::default();
    gateway_event(
        &mut shared,
        &json!({"type": "turn_started", "sessionId": "s", "turnId": "t", "userText": "q", "seq": 1}),
    );
    let oversized = "A".repeat(pocket_codex_host_svc::acp::fold::MAX_ITEM_IMAGE_BYTES + 1);
    let image = gateway_event(
        &mut shared,
        &json!({"type": "update", "sessionId": "s", "turnId": "t", "seq": 2,
            "update": {"sessionUpdate": "agent_message_chunk",
                "content": {"type": "image", "mimeType": "image/png", "data": oversized}}}),
    );
    let notice = image
        .iter()
        .find(|e| e.item_type.as_deref() == Some(CONTENT_OMITTED))
        .expect("a visible notice for the dropped image");
    assert_eq!(notice.text.as_deref(), Some("images"));
    assert_eq!(notice.item_id.as_deref(), Some("#omitted:t:m1"));
    let text = gateway_event(
        &mut shared,
        &json!({"type": "update", "sessionId": "s", "turnId": "t", "seq": 3,
            "update": chunk("caption")}),
    );
    assert_eq!(kinds(&text), vec!["item/agentMessage/delta"], "text keeps streaming");
    assert_eq!(text[0].text.as_deref(), Some("caption"));
    for event in image.iter().chain(&text) {
        let raw: Value = serde_json::from_str(&event.raw).expect("json");
        assert_eq!(raw["turnId"], "t", "{} names its turn", event.kind);
    }
    // A reload shows the same notice in place.
    let fold = shared.live.turn("s", "t").expect("fold").clone();
    let types: Vec<String> = turn_items(&fold).into_iter().map(|i| i.item_type).collect();
    assert_eq!(types, vec!["userMessage", "agentMessage", CONTENT_OMITTED]);
}

/// The borrowed detail is byte-for-byte the JSON object it replaced,
/// for named, unnamed and missing tool state.
#[test]
fn generic_tool_detail_text_is_unchanged() {
    let input = json!({"q": "naïve \"quote\" \u{1F600}", "n": [1, {"deep": null}]});
    let tool = |name: Option<&str>, raw_input: Option<Value>| Tool {
        call_id: "c".into(),
        kind: "think".into(),
        status: "completed".into(),
        name: name.map(str::to_string),
        raw_input,
        ..Tool::default()
    };
    let item = |tool: Option<Tool>| Item {
        id: "tool:c".into(),
        kind: ItemKind::ToolCall,
        title: "Think".into(),
        text: "out\tput ✓".into(),
        images: Vec::new(),
        tool,
        plan: None,
        message_id: None,
        truncated: false,
        text_full: false,
        omitted: Vec::new(),
    };
    for (item, name, raw) in [
        (item(Some(tool(Some("grep"), Some(input.clone())))), "grep", input.clone()),
        (item(Some(tool(None, None))), "think", Value::Null),
        (item(None), "", Value::Null),
    ] {
        let (kind, title, text) = tool_parts(&item);
        assert_eq!((kind, title.as_str()), ("dynamicToolCall", "Think"));
        let old = json!({"tool": name, "input": raw, "output": "out\tput ✓"});
        assert_eq!(text, old.to_string());
    }
}

/// Tool `x` drops an oversized diff while another tool is legally named
/// `x:omitted`. Every row stays separately addressable; when `x`'s diff
/// is replaced by one that fits, its notice is re-sent empty (which the
/// UI removes), and the other tool is never touched by it.
#[test]
fn notices_never_collide_with_agent_ids_and_clear_when_content_fits() {
    let mut shared = Shared::default();
    gateway_event(
        &mut shared,
        &json!({"type": "turn_started", "sessionId": "s", "turnId": "t", "userText": "q", "seq": 1}),
    );
    let diff = |text: String| json!([{"type": "diff", "path": "/w/a.txt", "newText": text}]);
    let mut seq = 1;
    let mut update = |shared: &mut Shared, update: Value| {
        seq += 1;
        gateway_event(
            shared,
            &json!({"type": "update", "sessionId": "s", "turnId": "t", "seq": seq,
                "update": update}),
        )
    };
    let oversized = pocket_codex_host_svc::acp::fold::MAX_ITEM_TEXT + 1;
    let x = update(
        &mut shared,
        json!({"sessionUpdate": "tool_call", "toolCallId": "x", "title": "Edit", "kind": "edit",
            "status": "in_progress", "content": diff("n".repeat(oversized))}),
    );
    let other = update(
        &mut shared,
        json!({"sessionUpdate": "tool_call", "toolCallId": "x:omitted", "title": "List",
            "kind": "read", "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": "listing"}}]}),
    );
    let mut screen = Screen::default();
    screen.apply(&x);
    screen.apply(&other);
    let typed = |events: &[AppEvent], id: &str| {
        events
            .iter()
            .filter(|e| e.item_id.as_deref() == Some(id))
            .map(|e| e.item_type.clone().unwrap_or_default())
            .collect::<Vec<_>>()
    };
    assert_eq!(typed(&x, "#omitted:tool:x"), vec![CONTENT_OMITTED]);
    assert_eq!(screen.items["#omitted:tool:x"], "diffs");
    assert_eq!(typed(&other, "tool:x:omitted"), vec!["fileRead"]);
    assert!(other
        .iter()
        .all(|e| e.item_id.as_deref() != Some("#omitted:tool:x")));
    assert!(screen.items["tool:x:omitted"].contains("listing"));

    // The replacement fits: the fold clears the omission, and so does
    // the notice — without a reconnect or a history read.
    let small = update(
        &mut shared,
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "x", "status": "completed",
            "content": diff("small".into())}),
    );
    let cleared = small
        .iter()
        .find(|e| e.item_id.as_deref() == Some("#omitted:tool:x"))
        .expect("the notice is re-stated");
    assert_eq!(cleared.item_type.as_deref(), Some(CONTENT_OMITTED));
    assert_eq!(cleared.text.as_deref(), Some(""), "empty: the notice is removed");
    assert!(small
        .iter()
        .all(|e| e.item_id.as_deref() != Some("tool:x:omitted")));
    let fold = shared.live.turn("s", "t").expect("fold").clone();
    assert!(
        turn_items(&fold)
            .iter()
            .all(|i| i.item_type != CONTENT_OMITTED),
        "a reload shows no notice either"
    );

    // Updating the other tool restates only its own (empty) notice.
    let touched = update(
        &mut shared,
        json!({"sessionUpdate": "tool_call_update", "toolCallId": "x:omitted",
            "title": "List again"}),
    );
    assert!(touched
        .iter()
        .all(|e| e.item_id.as_deref() != Some("tool:x")
            && e.item_id.as_deref() != Some("#omitted:tool:x")));
    assert_eq!(typed(&touched, "tool:x:omitted"), vec!["fileRead"]);
}

#[test]
fn a_failed_stream_withdraws_pending_permissions_and_says_so_once() {
    let mut shared = Shared {
        healthy: true,
        ..Shared::default()
    };
    shared
        .permissions
        .insert("h".into(), json!({"handle": "h", "sessionId": "s"}));
    let events = disconnected(&mut shared);
    assert_eq!(kinds(&events), vec!["serverRequest/resolved", HOST_STATE]);
    assert!(!shared.healthy);
    assert!(shared.permissions.is_empty());
    assert!(disconnected(&mut shared).is_empty(), "reported once");
}

#[test]
fn a_replaced_host_is_a_fresh_view() {
    let mut shared = Shared::default();
    reconcile(
        &mut shared,
        &json!({"generation": 1, "seq": 5, "info": {"hostId": "a"},
        "sessions": [{"sessionId": "s", "runningTurnId": "t"}]}),
    );
    shared.oldest.insert("s".into(), "t".into());
    let plan = reconcile(
        &mut shared,
        &json!({"generation": 1, "seq": 2, "info": {"hostId": "b"},
        "sessions": []}),
    );
    assert_eq!(plan.ended.len(), 1, "the old host's turn is reported, not kept");
    assert_eq!(plan.ended[0].2, None);
    assert!(shared.oldest.is_empty());
    let raw: Value = serde_json::from_str(&plan.host_state.raw).expect("json");
    assert_eq!(raw["replaced"], true);
}

#[test]
fn evicted_items_show_a_gap_inside_their_turn() {
    let mut turn: Turn = serde_json::from_value(json!({
        "id": "t", "replayed": false, "outcome": null, "omitted": 3, "nextItem": 9,
        "items": [
            {"id": "t:u", "kind": "user_message", "title": "", "text": "q"},
            {"id": "t:m8", "kind": "agent_message", "title": "", "text": "last"},
        ],
    }))
    .expect("turn");
    let items = turn_items(&turn);
    let types: Vec<&str> = items.iter().map(|i| i.item_type.as_str()).collect();
    assert_eq!(types, vec!["userMessage", "historyGap", "agentMessage"]);
    turn.omitted = 0;
    assert_eq!(turn_items(&turn).len(), 2);
}

#[test]
fn a_supplement_shows_as_a_user_message_of_its_turn() {
    let mut shared = Shared::default();
    gateway_event(
        &mut shared,
        &json!({"type": "turn_started", "sessionId": "s", "turnId": "t", "userText": "q", "seq": 1}),
    );
    let added = gateway_event(
        &mut shared,
        &json!({"type": "supplement", "sessionId": "s", "turnId": "t", "text": "also this",
        "imageCount": 0, "seq": 2}),
    );
    assert_eq!(kinds(&added), vec!["item/completed"]);
    assert_eq!(added[0].item_type.as_deref(), Some("userMessage"));
    assert_eq!(added[0].text.as_deref(), Some("also this"));
    assert!(added[0]
        .item_id
        .as_deref()
        .is_some_and(|id| id.starts_with("t:s")));
    // A supplement of a turn this view never saw begin adds nothing.
    let unseen = gateway_event(
        &mut shared,
        &json!({"type": "supplement", "sessionId": "s", "turnId": "other", "text": "x",
        "imageCount": 0, "seq": 3}),
    );
    assert!(unseen.is_empty());
}

#[test]
fn a_turn_end_releases_the_cached_running_state_of_that_turn_only() {
    let mut shared = Shared::default();
    let state = |running: &str| {
        json!({"type": "session_state", "sessionId": "s", "admitted": true,
        "runningTurnId": running, "turnDispatched": true, "cancelRequested": false})
    };
    gateway_event(&mut shared, &state("t"));
    gateway_event(
        &mut shared,
        &json!({"type": "turn_started", "sessionId": "s", "turnId": "t", "userText": "q", "seq": 1}),
    );
    let ended = gateway_event(
        &mut shared,
        &json!({"type": "turn_ended", "sessionId": "s", "turnId": "t", "seq": 2,
        "outcome": {"kind": "stopped", "stopReason": "end_turn"}}),
    );
    let updated = ended
        .iter()
        .find(|e| e.kind == SESSION_UPDATED)
        .expect("the controls' state is refreshed");
    assert!(updated.raw.contains("\"runningTurnId\":null"));
    assert!(shared.sessions["s"]["runningTurnId"].is_null());

    // A late end of an older turn leaves a newer running turn alone.
    gateway_event(&mut shared, &state("n"));
    let late = gateway_event(
        &mut shared,
        &json!({"type": "turn_ended", "sessionId": "s", "turnId": "t", "seq": 3,
        "outcome": {"kind": "stopped", "stopReason": "end_turn"}}),
    );
    assert!(late.iter().all(|e| e.kind != SESSION_UPDATED));
    assert_eq!(shared.sessions["s"]["runningTurnId"], "n");
}

/// A's end arriving after B started leaves B running everywhere this view
/// keeps it: the running map (Stop, capabilities, the running inventory),
/// the cached session state and B's live fold.
#[test]
fn an_older_turns_end_after_a_newer_start_leaves_the_newer_turn_running() {
    let mut shared = Shared::default();
    let start = |turn: &str, seq: u64| json!({"type": "turn_started", "sessionId": "s", "turnId": turn, "userText": "q", "seq": seq});
    gateway_event(&mut shared, &start("A", 1));
    gateway_event(&mut shared, &start("B", 2));
    gateway_event(
        &mut shared,
        &json!({"type": "session_state", "sessionId": "s", "admitted": true,
        "runningTurnId": "B", "turnDispatched": true, "cancelRequested": false}),
    );
    gateway_event(
        &mut shared,
        &json!({"type": "update", "sessionId": "s", "turnId": "B", "seq": 3,
        "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "b"}}}),
    );
    let late = gateway_event(
        &mut shared,
        &json!({"type": "turn_ended", "sessionId": "s", "turnId": "A", "seq": 4,
        "outcome": {"kind": "stopped", "stopReason": "end_turn"}}),
    );
    assert!(late.iter().all(|e| e.kind != SESSION_UPDATED));
    assert_eq!(shared.running.get("s").map(String::as_str), Some("B"));
    assert_eq!(shared.sessions["s"]["runningTurnId"], "B");
    assert!(shared.live.turn("s", "B").is_some(), "B's live fold is kept");

    // B's own end releases it.
    gateway_event(
        &mut shared,
        &json!({"type": "turn_ended", "sessionId": "s", "turnId": "B", "seq": 5,
        "outcome": {"kind": "stopped", "stopReason": "end_turn"}}),
    );
    assert!(shared.running.is_empty());
    assert!(shared.sessions["s"]["runningTurnId"].is_null());
}

#[test]
fn release_events_withdraw_admission_without_erasing_the_title() {
    let mut shared = Shared::default();
    shared
        .sessions
        .insert("s".into(), json!({"sessionId":"s","title":"Keep this title"}));
    let closing = gateway_event(
        &mut shared,
        &json!({
            "type":"session_state","sessionId":"s","admitted":true,
            "pending":true,"releasing":true,"title":"Keep this title"
        }),
    );
    assert_eq!(kinds(&closing), vec![SESSION_UPDATED]);
    assert!(shared.sessions["s"]["pending"].as_bool().expect("pending"));
    let released = gateway_event(
        &mut shared,
        &json!({
            "type":"session_state","sessionId":"s","admitted":false
        }),
    );
    assert_eq!(kinds(&released), vec![SESSION_UPDATED]);
    assert!(shared.sessions.is_empty());
    let body: Value = serde_json::from_str(&released[0].raw).expect("event");
    assert_eq!(body["admitted"], false);
}

#[test]
fn reconnect_reports_admission_released_while_the_controller_was_away() {
    let mut shared = Shared {
        host_id: "h".into(),
        generation: 1,
        ..Shared::default()
    };
    shared
        .sessions
        .insert("s".into(), json!({"sessionId":"s","admitted":true}));
    let plan = reconcile(
        &mut shared,
        &json!({
            "info":{"hostId":"h"},"generation":1,"sessions":[],"permissions":[],"recentTurns":[]
        }),
    );
    let event = plan
        .events
        .iter()
        .find(|e| e.kind == SESSION_UPDATED)
        .expect("withdrawal");
    assert_eq!(event.thread_id.as_deref(), Some("s"));
    let body: Value = serde_json::from_str(&event.raw).expect("event");
    assert_eq!(body["admitted"], false);
    assert!(shared.sessions.is_empty());
}

/// A turn the agent started that a recovery finds running keeps its
/// message, sent by no view (`clientId: null`, so every view shows it); a
/// prompt turn's message, whose sender a recovery does not know, is left to
/// the history read.
#[test]
fn a_recovered_agent_started_turn_keeps_its_mark_and_message() {
    let mut host = Transcript::default();
    host.begin_turn("F", "late", &[]);
    host.apply(Some("F"), &chunk("ok"));
    let recover = |agent_started: bool| {
        let mut shared = Shared::default();
        let session = json!({"sessionId": "s", "runningTurnId": "F",
            "runningAgentStarted": agent_started});
        let plan = reconcile(
            &mut shared,
            &json!({"generation": 1, "info": {"hostId": "h"}, "sessions": [session.clone()],
                "permissions": [], "recentTurns": []}),
        );
        let history = json!({"window": [host.turns[0].clone()], "truncated": false,
            "seq": 3, "generation": 1, "session": session});
        (plan.started, install(&mut shared, "s", "F", &history))
    };
    let (started, events) = recover(true);
    assert_eq!(started, vec![("s".to_string(), "F".to_string(), true)]);
    let message = events
        .iter()
        .find(|e| e.item_type.as_deref() == Some("userMessage"))
        .expect("its message");
    assert_eq!(message.text.as_deref(), Some("late"));
    let raw: Value = serde_json::from_str(&message.raw).expect("raw");
    assert_eq!(raw.get("clientId"), Some(&Value::Null), "no view sent it");
    let start: Value = serde_json::from_str(&super::started("s", "F", true).raw).expect("raw");
    assert_eq!(start.get("clientId"), Some(&Value::Null));
    let (_, events) = recover(false);
    assert!(events
        .iter()
        .all(|e| e.item_type.as_deref() != Some("userMessage")));
}

/// Each tool call takes the native row its kind names: the agent's own
/// finer kind first (Grok's `x.ai/tool`), then ACP's; Grok's MCP calls
/// through `use_tool` read as `<server>.<tool>`.
#[test]
fn tool_calls_take_the_native_row_their_kind_names() {
    let call = |id: &str, kind: &str, canonical: Option<&str>, input: Value| {
        let mut update = json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": id,
            "kind": kind, "status": "completed", "rawInput": input});
        if let Some(canonical) = canonical {
            update["_meta"] = json!({"x.ai/tool": {"kind": canonical, "name": id}});
        }
        update
    };
    let mut host = Transcript::default();
    host.begin_turn("t", "q", &[]);
    for update in [
        call("list", "other", Some("list_dir"), json!({})),
        call("read", "read", None, json!({})),
        call("grep", "search", None, json!({})),
        call("web", "search", Some("web_search"), json!({})),
        call("run", "execute", None, json!({})),
        call("todo", "think", Some("plan"), json!({})),
        call("use", "other", Some("use_tool"), json!({"tool_name": "pocox__connect"})),
        call("other", "other", None, json!({})),
    ] {
        host.apply(Some("t"), &update);
    }
    let rows: Vec<(String, String)> = host.turns[0]
        .items
        .iter()
        .filter(|item| item.kind == ItemKind::ToolCall)
        .map(|item| {
            let mapped = app_item(item, "t");
            (mapped.item_type, mapped.title)
        })
        .collect();
    let types: Vec<&str> = rows.iter().map(|(t, _)| t.as_str()).collect();
    assert_eq!(types, [
        "fileList",
        "fileRead",
        "fileSearch",
        "webSearch",
        "commandExecution",
        "planUpdate",
        "mcpToolCall",
        "dynamicToolCall"
    ]);
    assert_eq!(rows[6].1, "pocox.connect");
}

/// Grok reports an MCP call's result only as `rawOutput` (its `ToolOutput`),
/// which becomes the call's output, so a share's link reaches its card.
#[test]
fn a_result_reported_only_as_raw_output_is_the_calls_output() {
    let mut host = Transcript::default();
    host.begin_turn("t", "q", &[]);
    host.apply(
        Some("t"),
        &json!({"sessionUpdate": "tool_call", "toolCallId": "c",
        "title": "use_tool", "kind": "other", "status": "pending",
        "rawInput": {"tool_name": "pocox__connect", "tool_input": {"action": "share"}},
        "_meta": {"x.ai/tool": {"kind": "use_tool", "name": "use_tool"}}}),
    );
    host.apply(
        Some("t"),
        &json!({"sessionUpdate": "tool_call_update", "toolCallId": "c",
        "status": "completed", "rawOutput": {"type": "MCP", "tool_name": "connect",
            "server_name": "pocox",
            "output": {"OkayOutput": "Shared: pocox://open?service=pcx:mac:port:8737&path=/"}}}),
    );
    let call = host.turns[0]
        .items
        .iter()
        .find(|item| item.kind == ItemKind::ToolCall)
        .expect("call");
    let mapped = app_item(call, "t");
    assert_eq!(mapped.title, "pocox.connect");
    let detail: Value = serde_json::from_str(&mapped.text).expect("detail");
    assert_eq!(detail["output"], "Shared: pocox://open?service=pcx:mac:port:8737&path=/");
}

/// A reasoning that the agent moved on from (a new item began) stops
/// showing as in progress: its completion comes with the new item.
#[test]
fn a_message_another_item_follows_is_completed() {
    let mut shared = Shared::default();
    gateway_event(
        &mut shared,
        &json!({"type": "turn_started", "sessionId": "s",
        "turnId": "t", "userText": "q", "seq": 1}),
    );
    let thought = json!({"sessionUpdate": "agent_thought_chunk",
        "content": {"type": "text", "text": "hmm"}});
    gateway_event(
        &mut shared,
        &json!({"type": "update", "sessionId": "s", "turnId": "t",
        "update": thought, "seq": 2}),
    );
    let events = gateway_event(
        &mut shared,
        &json!({"type": "update", "sessionId": "s",
        "turnId": "t", "seq": 3, "update": {"sessionUpdate": "tool_call",
        "toolCallId": "c", "title": "ls", "kind": "execute", "status": "pending"}}),
    );
    let completed = events
        .iter()
        .find(|e| e.kind == "item/completed")
        .expect("the thought's completion");
    assert_eq!(completed.item_type.as_deref(), Some("reasoning"));
    assert_eq!(completed.text.as_deref(), Some("hmm"));
}
