use serde_json::json;

use super::*;

fn event(kind: &str, properties: Value) -> Event {
    Event {
        directory: None,
        kind: kind.into(),
        properties,
    }
}

fn info(fold: &mut Fold) {
    fold.apply(event(
        "message.updated",
        json!({"info":{"id":"msg_1","sessionID":"ses_1","role":"assistant"}}),
    ));
}

fn part(fold: &mut Fold, text: &str, end: Option<u64>) {
    fold.apply(event("message.part.updated", json!({"part":{
        "id":"prt_1","messageID":"msg_1","sessionID":"ses_1","type":"text","text":text,"time":{"end":end}}})));
}

fn append(fold: &mut Fold, text: &str) {
    fold.apply(event(
        "message.part.delta",
        json!({"partID":"prt_1","messageID":"msg_1",
        "sessionID":"ses_1","field":"text","delta":text}),
    ));
}

fn window(fold: &Fold) -> Window {
    fold.window(
        "ses_1",
        MessagePage {
            messages: vec![],
            next_before: None,
        },
        true,
    )
}

#[test]
fn unpersisted_prefix_survives_controller_refresh_without_double_appending() {
    let mut fold = Fold::default();
    info(&mut fold);
    part(&mut fold, "", None);
    append(&mut fold, "中文");
    append(&mut fold, " stream");
    assert_eq!(window(&fold).messages[0].parts[0]["text"], "中文 stream");
    part(&mut fold, "中文 stream", Some(99));
    assert_eq!(window(&fold).messages[0].parts[0]["text"], "中文 stream");
    assert!(window(&fold).gaps.is_empty());
}

#[test]
fn upstream_gap_never_fabricates_a_missing_prefix() {
    let mut fold = Fold::default();
    info(&mut fold);
    part(&mut fold, "", None);
    append(&mut fold, "known");
    fold.disconnect();
    append(&mut fold, "after gap");
    let snapshot = window(&fold);
    assert_eq!(snapshot.messages[0].parts[0]["text"], "known");
    assert_eq!(snapshot.gaps, ["prt_1"]);
    part(&mut fold, "known missing after gap", Some(100));
    assert_eq!(window(&fold).messages[0].parts[0]["text"], "known missing after gap");
    assert!(window(&fold).gaps.is_empty());
}

#[test]
fn completed_http_part_wins_over_a_lagging_stream() {
    let mut fold = Fold::default();
    info(&mut fold);
    part(&mut fold, "prefix", None);
    let snapshot = fold.window(
        "ses_1",
        MessagePage {
            messages: vec![Message {
                info: json!({"id":"msg_1"}),
                parts: vec![json!({"id":"prt_1","type":"text",
            "text":"prefix completed","time":{"end":100}})],
            }],
            next_before: None,
        },
        true,
    );
    assert_eq!(snapshot.messages[0].parts[0]["text"], "prefix completed");
}

#[test]
fn removal_events_win_over_http_reads_started_before_the_removal() {
    let mut fold = Fold::default();
    info(&mut fold);
    part(&mut fold, "old", Some(10));
    let stale_page = || MessagePage {
        messages: vec![Message {
            info: json!({"id":"msg_1"}),
            parts: vec![json!({"id":"prt_1","type":"text","text":"old"})],
        }],
        next_before: None,
    };
    fold.apply(event(
        "message.part.removed",
        json!({"sessionID":"ses_1","messageID":"msg_1","partID":"prt_1"}),
    ));
    assert!(fold.window("ses_1", stale_page(), true).messages[0]
        .parts
        .is_empty());
    fold.apply(event("message.removed", json!({"sessionID":"ses_1","messageID":"msg_1"})));
    assert!(fold.window("ses_1", stale_page(), true).messages.is_empty());
}

#[test]
fn an_idle_transition_retains_the_busy_sequence_it_completes() {
    let mut fold = Fold::default();
    fold.apply(event("session.status", json!({"sessionID":"ses_1","status":{"type":"idle"}})));
    assert_eq!(fold.status("ses_1").expect("old idle").2, 0);
    let dispatched = fold.sequence();
    fold.apply(event("session.status", json!({"sessionID":"ses_1","status":{"type":"busy"}})));
    fold.apply(event("session.status", json!({"sessionID":"ses_1","status":{"type":"idle"}})));
    let (seq, status, busy) = fold.status("ses_1").expect("completed");
    assert!(busy > dispatched && seq > busy && matches!(status, Status::Idle));
}
