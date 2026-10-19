use std::collections::HashSet;

use serde_json::json;

use super::*;

fn chunk(kind: &str, text: &str) -> Value {
    json!({"sessionUpdate": kind, "content": {"type": "text", "text": text}})
}

/// The counted length is the actual serialization's, including
/// multi-byte UTF-8, escapes and nesting.
#[test]
fn serialized_len_counts_the_actual_serialization() {
    let values = [
        json!(null),
        json!(""),
        json!("naïve ✓ \u{1F600} 漢字"),
        json!("\"quoted\"\\ \n\t\r \u{0001} \u{001f} </script>"),
        json!(-1.5e300),
        json!(u64::MAX),
        json!([[], {}, [{"a": [1, "b", {"c": null, "d": [true, false]}]}]]),
        json!({"é": {"\u{2028}": "x".repeat(10_000), "k\"": ["\u{fffd}", "\u{7f}"]}}),
    ];
    for value in values {
        assert_eq!(
            serialized_len(&value),
            serde_json::to_vec(&value).expect("serializes").len(),
            "{value}"
        );
    }
}

fn exact_bytes(transcript: &Transcript) -> usize {
    transcript
        .turns
        .iter()
        .flat_map(|t| &t.items)
        .map(weight)
        .sum()
}

#[test]
fn live_chunks_append_and_echoed_prompts_are_ignored() {
    let mut transcript = Transcript::default();
    transcript.begin_turn("t1", "hello", &[]);
    assert!(transcript
        .apply(Some("t1"), &chunk("user_message_chunk", "hello"))
        .is_empty());
    let first = transcript.apply(Some("t1"), &chunk("agent_message_chunk", "Hi"));
    assert!(matches!(&first[0], Change::Started(item) if item.text == "Hi" && item.id == "t1:m1"));
    let second = transcript.apply(Some("t1"), &chunk("agent_message_chunk", " there"));
    assert!(matches!(&second[0], Change::Delta { delta, .. } if delta == " there"));
    let thought = transcript.apply(Some("t1"), &chunk("agent_thought_chunk", "hmm"));
    assert!(matches!(&thought[0], Change::Started(item) if item.kind == ItemKind::Thought));
    let turn = &transcript.turns[0];
    assert_eq!(turn.items.len(), 3);
    assert_eq!(turn.items[1].text, "Hi there");
}

#[test]
fn message_ids_split_messages() {
    let mut transcript = Transcript::default();
    let mut a = chunk("agent_message_chunk", "a");
    a["messageId"] = json!("m1");
    let mut b = chunk("agent_message_chunk", "b");
    b["messageId"] = json!("m2");
    transcript.apply(Some("t"), &a);
    transcript.apply(Some("t"), &b);
    assert_eq!(transcript.turns[0].items.len(), 2);
}

#[test]
fn tool_updates_replace_supplied_collections() {
    let mut transcript = Transcript::default();
    transcript.apply(
        Some("t"),
        &json!({
            "sessionUpdate": "tool_call", "toolCallId": "c1", "title": "Edit a", "kind": "edit",
            "status": "pending",
            "content": [{"type": "content", "content": {"type": "text", "text": "one"}}],
            "locations": [{"path": "/w/a"}],
        }),
    );
    let changes = transcript.apply(
        Some("t"),
        &json!({
            "sessionUpdate": "tool_call_update", "toolCallId": "c1", "status": "completed",
            "content": [{"type": "diff", "path": "/w/a", "oldText": "x", "newText": "y"}],
        }),
    );
    let Change::Updated(item) = &changes[0] else { panic!("update expected") };
    let tool = item.tool.as_ref().expect("tool");
    assert_eq!(tool.status, "completed");
    assert_eq!(item.text, "", "replaced content drops the old text");
    assert_eq!(tool.diffs.len(), 1);
    assert_eq!(tool.locations, vec!["/w/a".to_string()], "absent locations stay");
    assert_eq!(item.title, "Edit a");
}

#[test]
fn replay_groups_by_user_message_and_plans_replace() {
    let mut transcript = Transcript::default();
    transcript.apply(None, &chunk("user_message_chunk", "q1"));
    transcript.apply(None, &chunk("agent_message_chunk", "a1"));
    transcript.apply(
        None,
        &json!({"sessionUpdate": "plan", "entries": [{"content": "x", "status": "pending"}]}),
    );
    transcript.apply(
        None,
        &json!({"sessionUpdate": "plan", "entries": [{"content": "x", "status": "completed"}]}),
    );
    transcript.apply(None, &chunk("user_message_chunk", "q2"));
    transcript.apply(None, &chunk("agent_message_chunk", "a2"));
    assert_eq!(transcript.turns.len(), 2);
    assert!(transcript
        .turns
        .iter()
        .all(|turn| turn.replayed && turn.outcome.is_none()));
    let plan = transcript.turns[0]
        .items
        .iter()
        .find(|i| i.kind == ItemKind::Plan)
        .expect("plan");
    assert_eq!(plan.plan.as_ref().expect("entries")[0].status, "completed");
    assert_eq!(transcript.len(), 5);
}

#[test]
fn bounds_evict_whole_turns_and_mark_truncation() {
    let mut transcript = Transcript::default();
    let big = "x".repeat(MAX_ITEM_TEXT);
    for turn in 0..40 {
        let id = format!("t{turn}");
        transcript.begin_turn(&id, "q", &[]);
        transcript.apply(Some(&id), &chunk("agent_message_chunk", &big));
    }
    assert!(transcript.truncated);
    assert!(transcript.bytes <= MAX_TRANSCRIPT_BYTES);
    assert_eq!(transcript.turns.back().expect("newest").id, "t39");
    let mut copy = transcript.clone();
    copy.recount();
    assert_eq!(copy.bytes, transcript.bytes);
}

#[test]
fn one_long_turn_of_tool_calls_with_large_input_stays_bounded() {
    let mut transcript = Transcript::default();
    transcript.begin_turn("t", "start", &[]);
    let input = json!({"blob": "i".repeat(16 * 1024)});
    let huge = json!({"blob": "h".repeat(MAX_RAW_INPUT * 2)});
    for n in 0..6000 {
        let raw = if n % 100 == 0 { &huge } else { &input };
        transcript.apply(
            Some("t"),
            &json!({"sessionUpdate": "tool_call", "toolCallId": format!("call-{n}"),
                "title": "Run", "kind": "execute", "status": "completed", "rawInput": raw}),
        );
    }
    assert_eq!(transcript.turns.len(), 1, "a single turn");
    assert!(transcript.len() <= MAX_ITEMS);
    assert!(transcript.retained_bytes() <= MAX_TRANSCRIPT_BYTES);
    assert_eq!(transcript.retained_bytes(), exact_bytes(&transcript), "every byte is charged");
    let turn = &transcript.turns[0];
    assert!(turn.omitted > 0, "evicted items are counted");
    assert!(transcript.truncated, "and the transcript says it is incomplete");
    assert_eq!(turn.items[0].id, "t:u", "the prompt stays");
    assert_eq!(turn.items.last().expect("newest").id, "tool:call-5999");
    let huge_kept = turn.items.iter().filter(|item| item.truncated).all(|item| {
        item.tool
            .as_ref()
            .is_some_and(|t| t.raw_input.as_ref().is_some_and(Value::is_string))
    });
    assert!(huge_kept, "oversized input is replaced by a note");
}

#[test]
fn ids_are_never_reused_after_in_turn_eviction() {
    let mut transcript = Transcript::default();
    transcript.begin_turn("t", "q", &[]);
    let text = "y".repeat(MAX_ITEM_TEXT / 2);
    let mut ids = HashSet::new();
    for n in 0..200 {
        let mut update = chunk("agent_message_chunk", &text);
        update["messageId"] = json!(format!("msg-{n}"));
        for change in transcript.apply(Some("t"), &update) {
            if let Change::Started(item) = change {
                assert!(ids.insert(item.id.clone()), "id {} reused", item.id);
            }
        }
    }
    assert!(transcript.turns[0].omitted > 0);
    assert!(transcript.retained_bytes() <= MAX_TRANSCRIPT_BYTES);
}

#[test]
fn repeated_images_on_one_message_are_capped_and_flagged() {
    let mut transcript = Transcript::default();
    transcript.begin_turn("t", "q", &[]);
    let data = "A".repeat(512 * 1024);
    let image = json!({"sessionUpdate": "agent_message_chunk",
        "content": {"type": "image", "mimeType": "image/png", "data": data}});
    for _ in 0..50 {
        transcript.apply(Some("t"), &image);
    }
    let item = &transcript.turns[0].items[1];
    assert!(item.images.len() <= MAX_ITEM_IMAGES);
    assert!(item.images.iter().map(String::len).sum::<usize>() <= MAX_ITEM_IMAGE_BYTES);
    assert!(item.truncated);
    assert_eq!(transcript.retained_bytes(), exact_bytes(&transcript));
}

#[test]
fn streaming_past_the_item_limit_marks_the_truncation() {
    let mut transcript = Transcript::default();
    transcript.begin_turn("t", "q", &[]);
    let piece = "z".repeat(100 * 1024);
    let mut deltas = Vec::new();
    for _ in 0..8 {
        for change in transcript.apply(Some("t"), &chunk("agent_message_chunk", &piece)) {
            if let Change::Delta {
                delta, ..
            } = change
            {
                deltas.push(delta);
            }
        }
    }
    let item = &transcript.turns[0].items[1];
    assert!(item.truncated, "the item says it was cut");
    assert!(item.text.ends_with(TRUNCATED), "and the text shows it");
    assert!(item.text.len() <= MAX_ITEM_TEXT + TRUNCATED.len());
    assert!(
        deltas.last().is_some_and(|d| d.ends_with(TRUNCATED)),
        "the controller sees the marker"
    );
    // Nothing more is appended once cut.
    assert!(transcript
        .apply(Some("t"), &chunk("agent_message_chunk", "more"))
        .is_empty());
}

#[test]
fn long_protocol_ids_never_alias_and_one_long_message_stays_one_item() {
    let shared = "p".repeat(MAX_PROTOCOL_ID);
    let (first, second) = (format!("{shared}-one"), format!("{shared}-two"));
    let mut transcript = Transcript::default();
    transcript.begin_turn("t", "q", &[]);
    for id in [&first, &second] {
        transcript.apply(
            Some("t"),
            &json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": id}),
        );
    }
    let tools: Vec<&Item> = transcript.turns[0]
        .items
        .iter()
        .filter(|i| i.kind == ItemKind::ToolCall)
        .collect();
    assert_eq!(tools.len(), 2, "a shared prefix is not one tool");
    assert_ne!(tools[0].id, tools[1].id);
    // An update for the second reaches the second only.
    transcript.apply(
        Some("t"),
        &json!({"sessionUpdate": "tool_call_update", "toolCallId": second, "status": "completed"}),
    );
    let status = |n: usize| {
        transcript.turns[0]
            .items
            .iter()
            .filter(|i| i.kind == ItemKind::ToolCall)
            .nth(n)
            .and_then(|i| i.tool.as_ref())
            .map(|t| t.status.clone())
    };
    assert_eq!(status(0).as_deref(), Some("pending"));
    assert_eq!(status(1).as_deref(), Some("completed"));
    // A verbatim id can never equal an oversized id's key.
    assert!(protocol_key(&first).len() > MAX_PROTOCOL_ID);
    assert_eq!(protocol_key("short"), "short");

    let long_message = "m".repeat(MAX_PROTOCOL_ID * 4);
    for piece in ["a", "b", "c"] {
        let mut update = chunk("agent_message_chunk", piece);
        update["messageId"] = json!(long_message);
        transcript.apply(Some("t"), &update);
    }
    let messages: Vec<&Item> = transcript.turns[0]
        .items
        .iter()
        .filter(|i| i.kind == ItemKind::AgentMessage)
        .collect();
    assert_eq!(messages.len(), 1, "chunks of one long id are one message");
    assert_eq!(messages[0].text, "abc");
}

#[test]
fn a_dropped_image_or_diff_is_named_and_later_text_still_arrives() {
    let mut transcript = Transcript::default();
    transcript.begin_turn("t", "q", &[]);
    let oversized = "A".repeat(MAX_ITEM_IMAGE_BYTES + 1);
    let image = json!({"sessionUpdate": "agent_message_chunk",
        "content": {"type": "image", "mimeType": "image/png", "data": oversized}});
    transcript.apply(Some("t"), &image);
    let text = transcript.apply(Some("t"), &chunk("agent_message_chunk", "the caption"));
    assert!(
        matches!(&text[0], Change::Delta { delta, .. } if delta == "the caption"),
        "text after a dropped image is kept"
    );
    let message = &transcript.turns[0].items[1];
    assert_eq!(message.text, "the caption");
    assert!(message.images.is_empty());
    assert_eq!(message.omitted, vec![OMITTED_IMAGES.to_string()]);
    assert!(message.truncated && !message.text_full);

    let big = "d".repeat(MAX_ITEM_TEXT);
    transcript.apply(
        Some("t"),
        &json!({"sessionUpdate": "tool_call", "toolCallId": "edit", "kind": "edit",
        "content": [
            {"type": "diff", "path": "/w/a", "newText": "small"},
            {"type": "diff", "path": "/w/b", "newText": big},
        ]}),
    );
    let tool = transcript.turns[0]
        .items
        .iter()
        .find(|i| i.kind == ItemKind::ToolCall)
        .expect("tool");
    assert_eq!(tool.tool.as_ref().map(|t| t.diffs.len()), Some(1));
    assert_eq!(tool.omitted, vec![OMITTED_DIFFS.to_string()]);
    // A later update that fits replaces the content and the notice.
    transcript.apply(
        Some("t"),
        &json!({"sessionUpdate": "tool_call_update", "toolCallId": "edit",
            "content": [{"type": "diff", "path": "/w/a", "newText": "fits"}]}),
    );
    let tool = transcript.turns[0]
        .items
        .iter()
        .find(|i| i.kind == ItemKind::ToolCall)
        .expect("tool");
    assert!(tool.omitted.is_empty() && !tool.truncated);
    assert_eq!(transcript.retained_bytes(), exact_bytes(&transcript));
}

#[test]
fn a_recovered_turn_continues_with_the_hosts_ids() {
    let mut host = Transcript::default();
    host.begin_turn("t", "q", &[]);
    host.apply(Some("t"), &chunk("agent_message_chunk", "He"));
    let mut replica = Transcript::from_turns([host.turns[0].clone()], false);
    for update in [
        chunk("agent_message_chunk", "llo"),
        json!({"sessionUpdate": "tool_call", "toolCallId": "c", "title": "ls"}),
        chunk("agent_message_chunk", "done"),
    ] {
        host.apply(Some("t"), &update);
        replica.apply(Some("t"), &update);
    }
    assert_eq!(replica.turns[0], host.turns[0]);
    assert_eq!(replica.retained_bytes(), host.retained_bytes());
}

#[test]
fn session_level_updates_are_signals_not_items() {
    let mut transcript = Transcript::default();
    for update in [
        json!({"sessionUpdate": "config_option_update", "configOptions": []}),
        json!({"sessionUpdate": "current_mode_update", "currentModeId": "code"}),
        json!({"sessionUpdate": "usage_update", "used": 1, "size": 2}),
        json!({"sessionUpdate": "session_info_update", "title": null}),
        json!({"sessionUpdate": "future_kind"}),
    ] {
        assert!(transcript.apply(Some("t"), &update).is_empty());
    }
    assert!(transcript.is_empty());
    assert_eq!(
        session_signal(&json!({"sessionUpdate": "session_info_update", "title": null})),
        Some(SessionSignal::Title(Some(None)))
    );
    assert_eq!(
        session_signal(&json!({"sessionUpdate": "session_info_update", "updatedAt": "x"})),
        Some(SessionSignal::Title(None))
    );
    assert_eq!(
        session_signal(&json!({"sessionUpdate": "usage_update", "used": 3, "size": 9})),
        Some(SessionSignal::Usage {
            used: 3,
            size: 9
        })
    );
}

#[test]
fn a_supplement_joins_its_live_turn_with_a_fresh_id() {
    let mut transcript = Transcript::default();
    transcript.begin_turn("t", "first", &[]);
    transcript.apply(Some("t"), &chunk("agent_message_chunk", "working"));
    let changes = transcript.supplement("t", "also this", 2);
    let [Change::Started(item)] = changes.as_slice() else { panic!("one new item: {changes:?}") };
    assert_eq!(item.kind, ItemKind::UserMessage);
    assert_eq!(item.text, "also this");
    assert_eq!(item.omitted, vec![OMITTED_IMAGES.to_string()], "images are named, not kept");
    assert!(item.images.is_empty());
    // The agent's next message continues the turn's own numbering.
    transcript.apply(Some("t"), &chunk("agent_message_chunk", "done"));
    let turn = transcript.turn("t").expect("turn");
    let ids: Vec<&str> = turn.items.iter().map(|i| i.id.as_str()).collect();
    assert_eq!(ids.len(), 4);
    assert_eq!(ids.iter().collect::<HashSet<_>>().len(), 4, "ids are unique: {ids:?}");
    assert_eq!(exact_bytes(&transcript), transcript.retained_bytes());
    // Another (or an evicted) turn is left alone.
    assert!(transcript.supplement("gone", "x", 0).is_empty());
}

/// A replayed interjection (Grok's `_meta.interjection`) is its own item of
/// the replayed turn, with the text the user typed, never part of the
/// prompt it followed.
#[test]
fn a_replayed_interjection_is_its_own_message_of_the_turn() {
    let mut transcript = Transcript::default();
    transcript.apply(None, &chunk("user_message_chunk", "run the tests"));
    transcript.apply(
        None,
        &json!({"sessionUpdate": "user_message_chunk",
        "content": {"type": "text", "text": "The user sent a message while you were working:\n\
            <user_query>\nalso lint\n</user_query>\nIf the user is asking …",
            "_meta": {"displayText": "also lint"}},
        "_meta": {"interjection": true}}),
    );
    transcript.apply(None, &chunk("agent_message_chunk", "done"));
    let turn = transcript.turns.back().expect("turn");
    assert_eq!(transcript.turns.len(), 1, "one replayed turn");
    let texts: Vec<&str> = turn.items.iter().map(|item| item.text.as_str()).collect();
    assert_eq!(texts, ["run the tests", "also lint", "done"]);
    assert!(turn.items[1].id.contains(":s"), "numbered like a supplement");
}
