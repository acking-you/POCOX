use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

use serde_json::{json, Value};
use tempfile::TempDir;

use super::*;
use crate::acp::{fold::ItemKind, schema::TurnOutcome};

const ID: &str = "01a15501-b678-7db0-b062-a1f5b1edc8d1";

fn session(home: &Path, bucket: &str, id: &str, summary: Value) -> PathBuf {
    let dir = home.join("sessions").join(bucket).join(id);
    fs::create_dir_all(&dir).expect("session dir");
    fs::write(dir.join("summary.json"), summary.to_string()).expect("summary");
    dir
}

fn summary(id: &str, title: &str, active: &str) -> Value {
    json!({
        "info": {"id": id, "cwd": "/work/project"},
        "session_summary": "fallback summary",
        "generated_title": title,
        "created_at": "2026-10-19T16:32:18.147991Z",
        "updated_at": "2026-10-19T16:32:19.422614Z",
        "last_active_at": active,
        "num_messages": 2,
    })
}

fn acp(update: Value) -> String {
    json!({"timestamp": 1, "method": "session/update", "params": {"sessionId": ID, "update": update}})
        .to_string()
}

fn xai(update: Value) -> String {
    json!({"timestamp": 1, "method": "_x.ai/session/update", "params": {"sessionId": ID, "update": update}})
        .to_string()
}

fn prompt(index: u64, text: &str) -> String {
    acp(json!({"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": text},
        "_meta": {"promptIndex": index}}))
}

fn reply(text: &str) -> String {
    acp(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}))
}

fn done() -> String {
    xai(json!({"sessionUpdate": "turn_completed", "prompt_id": "p", "stop_reason": "end_turn"}))
}

fn append(dir: &Path, lines: &[String]) {
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("updates.jsonl"))
        .expect("log");
    for line in lines {
        writeln!(file, "{line}").expect("append");
    }
}

fn texts(page: &NativePage) -> Vec<Vec<String>> {
    page.turns
        .iter()
        .map(|turn| turn.items.iter().map(|item| item.text.clone()).collect())
        .collect()
}

#[tokio::test]
async fn listing_follows_groks_own_recent_session_rules() {
    let home = TempDir::new().expect("home");
    let older = "01a15501-0000-7000-8000-000000000001";
    let newer = "01a15501-0000-7000-8000-000000000002";
    session(
        home.path(),
        "%2Fwork%2Fproject",
        older,
        summary(older, "Older", "2026-10-18T10:00:00Z"),
    );
    session(home.path(), "%2Fwork%2Fproject", newer, summary(newer, "", "2026-10-19T10:00:00Z"));
    // Left out like Grok's own list: a subagent child, a one-shot run, an
    // unused husk, and an id stored under two buckets.
    let mut hidden =
        summary("01a15501-0000-7000-8000-000000000003", "Child", "2026-10-19T11:00:00Z");
    hidden["session_kind"] = json!("subagent_task");
    session(home.path(), "%2Fa", "01a15501-0000-7000-8000-000000000003", hidden);
    let mut headless =
        summary("01a15501-0000-7000-8000-000000000004", "One shot", "2026-10-19T11:00:00Z");
    headless["session_kind"] = json!("headless");
    session(home.path(), "%2Fa", "01a15501-0000-7000-8000-000000000004", headless);
    let mut husk = summary("01a15501-0000-7000-8000-000000000005", "", "2026-10-19T11:00:00Z");
    husk["session_summary"] = json!("");
    husk["num_messages"] = json!(0);
    session(home.path(), "%2Fa", "01a15501-0000-7000-8000-000000000005", husk);
    let twice = "01a15501-0000-7000-8000-000000000006";
    session(home.path(), "%2Fa", twice, summary(twice, "Twice", "2026-10-19T11:00:00Z"));
    session(home.path(), "%2Fb", twice, summary(twice, "Twice", "2026-10-19T11:00:00Z"));

    let reader = GrokHistory::new(home.path().into()).expect("reader");
    let listed = reader.list_sessions(None, 10).await.expect("list");
    let rows = listed["sessions"].as_array().expect("rows");
    let ids: Vec<&str> = rows
        .iter()
        .map(|r| r["sessionId"].as_str().expect("id"))
        .collect();
    assert_eq!(ids, [newer, older], "newest first, unlisted kinds and ambiguity left out");
    assert_eq!(rows[0]["title"], "fallback summary", "an empty title falls back to the summary");
    assert_eq!(rows[1]["cwd"], "/work/project");
    assert!(listed["nextCursor"].is_null());
    assert!(reader.read_page(twice, None, 1).await.is_err(), "Grok cannot open it either");
}

#[tokio::test]
async fn a_missing_grok_home_is_unavailable_not_empty() {
    let parent = TempDir::new().expect("parent");
    let missing = GrokHistory::new(parent.path().join("never-used")).expect("reader");
    assert!(missing.list_sessions(None, 10).await.is_err());
    // A home without sessions yet is an empty history.
    let empty = GrokHistory::new(parent.path().into()).expect("reader");
    let listed = empty.list_sessions(None, 10).await.expect("empty");
    assert!(listed["sessions"].as_array().is_some_and(Vec::is_empty));
}

#[tokio::test]
async fn pages_fold_turns_with_stable_ids_and_outcomes() {
    let home = TempDir::new().expect("home");
    let dir = session(home.path(), "%2Fwork", ID, summary(ID, "Pages", "2026-10-19T10:00:00Z"));
    let reader = GrokHistory::new(home.path().into()).expect("reader");
    // A new session has no update log yet; its first write keeps the source.
    let created = reader.revision(ID).await.expect("revision")["generation"].clone();
    append(&dir, &[
        prompt(0, "one"),
        reply("first"),
        done(),
        prompt(1, "two"),
        reply("second"),
        done(),
    ]);
    append(&dir, &[prompt(2, "three"), reply("third")]);

    let tail = reader.read_page(ID, None, 2).await.expect("tail");
    assert_eq!(tail.generation, created.as_str().expect("generation"));
    assert_eq!(texts(&tail), [vec!["two", "second"], vec!["three", "third"]]);
    assert_eq!(tail.total_turns, Some(3));
    assert!(tail.has_older);
    assert_eq!(tail.turns[0].items[0].kind, ItemKind::UserMessage);
    assert_eq!(
        tail.turns[0].outcome,
        Some(TurnOutcome::Stopped {
            stop_reason: "end_turn".into()
        })
    );
    assert_eq!(tail.turns[1].outcome, None, "the last turn has not completed");
    let older = reader
        .read_page(ID, tail.next_before.as_deref(), 2)
        .await
        .expect("older");
    assert_eq!(texts(&older), [vec!["one", "first"]]);
    assert!(!older.has_older);

    // Appended turns extend the same source; earlier ids stay.
    append(&dir, &[done(), prompt(3, "four")]);
    let grown = reader.read_page(ID, None, 4).await.expect("grown");
    assert_eq!(grown.generation, tail.generation);
    assert_ne!(grown.revision, tail.revision);
    assert_eq!(grown.turns[1].id, tail.turns[0].id);
    assert_eq!(texts(&grown).last().expect("turn"), &vec!["four".to_string()]);
    let single = reader.read_turn(ID, &tail.turns[0].id).await.expect("turn");
    assert_eq!(texts(&single), [vec!["two", "second"]]);
}

#[tokio::test]
async fn rewound_branches_are_dropped_like_groks_replay() {
    let home = TempDir::new().expect("home");
    let dir = session(home.path(), "%2Fwork", ID, summary(ID, "Rewind", "2026-10-19T10:00:00Z"));
    append(&dir, &[prompt(0, "keep"), reply("kept"), done(), prompt(1, "drop"), reply("dropped")]);
    let reader = GrokHistory::new(home.path().into()).expect("reader");
    let before = reader.read_page(ID, None, 10).await.expect("before");
    assert_eq!(before.turns.len(), 2);
    append(&dir, &[
        done(),
        xai(
            json!({"sessionUpdate": "rewind_marker", "target_prompt_index": 1, "created_at": "now"}),
        ),
        prompt(1, "again"),
        reply("redone"),
    ]);
    let after = reader.read_page(ID, None, 10).await.expect("after");
    assert_eq!(texts(&after), [vec!["keep", "kept"], vec!["again", "redone"]]);
    assert_ne!(after.turns[1].id, before.turns[1].id, "a rewritten turn never reuses an id");
    // A fresh reader over the whole log agrees with the incremental one.
    let fresh = GrokHistory::new(home.path().into()).expect("reader");
    assert_eq!(texts(&fresh.read_page(ID, None, 10).await.expect("fresh")), texts(&after));
}

#[tokio::test]
async fn interjections_show_their_typed_text_and_partial_lines_wait() {
    let home = TempDir::new().expect("home");
    let dir = session(home.path(), "%2Fwork", ID, summary(ID, "Typed", "2026-10-19T10:00:00Z"));
    append(&dir, &[
        prompt(0, "<fork-context>parent notes</fork-context>\nreal prompt"),
        reply("working"),
        acp(json!({"sessionUpdate": "user_message_chunk", "content": {"type": "text",
            "text": "<system>frame</system>", "_meta": {"displayText": "also this"}},
            "_meta": {"interjection": true}})),
        reply("done"),
    ]);
    // An unfinished last line is not read until it ends.
    fs::OpenOptions::new()
        .append(true)
        .open(dir.join("updates.jsonl"))
        .expect("log")
        .write_all(br#"{"method":"session/update","params":{"upd"#)
        .expect("partial");
    let reader = GrokHistory::new(home.path().into()).expect("reader");
    let page = reader.read_page(ID, None, 10).await.expect("page");
    assert_eq!(texts(&page), [vec!["real prompt", "working", "also this", "done"]]);
    let ids: Vec<&str> = page.turns[0].items.iter().map(|i| i.id.as_str()).collect();
    assert_eq!(ids.len(), 4);
    assert!(ids.iter().all(|id| id.starts_with(&page.turns[0].id)));
    assert_eq!(ids.iter().collect::<std::collections::HashSet<_>>().len(), 4, "unique ids");
}

fn registry(home: &Path, pid: u32, opened_at: &str) {
    fs::write(
        home.join("active_sessions.json"),
        json!([{"session_id": ID, "pid": pid, "cwd": "/work", "opened_at": opened_at}]).to_string(),
    )
    .expect("registry");
}

#[cfg(unix)]
#[tokio::test]
async fn terminal_clients_are_owners_only_when_verified() {
    let home = TempDir::new().expect("home");
    session(home.path(), "%2Fwork", ID, summary(ID, "Owned", "2026-10-19T10:00:00Z"));
    let reader = GrokHistory::new(home.path().into())
        .expect("reader")
        .with_owner_probe();
    assert_eq!(reader.handoff_liveness(ID).await.safety, "nativeUnowned", "no registry");

    // A live process that is not a Grok client cannot be shown to hold it.
    registry(home.path(), std::process::id(), "2099-01-01T00:00:00Z");
    assert_eq!(reader.handoff_liveness(ID).await.safety, "nativeUnknown");
    assert!(reader.owners(ID).await.is_err());

    // A Grok client that registered after it started holds the session. The
    // test executable, linked under Grok's name, stands in for the client.
    let grok = home.path().join("grok");
    fs::hard_link(std::env::current_exe().expect("test executable"), &grok).expect("client");
    let mut client = std::process::Command::new(&grok)
        .args(["--exact", "native_history::grok::tests::grok_client_child", "--test-threads=1"])
        .env("PCX_GROK_CLIENT", "1")
        .stdout(std::process::Stdio::null())
        .spawn()
        .expect("client");
    std::thread::sleep(std::time::Duration::from_millis(300));
    let opened = chrono::Utc::now().to_rfc3339();
    registry(home.path(), client.id(), &opened);
    let live = reader.handoff_liveness(ID).await;
    assert_eq!(live.safety, "nativeOwned");
    assert!(live.held_open);
    assert_eq!(live.turn_state, "unknown", "Grok records no turn state");
    assert_eq!(reader.owners(ID).await.expect("owners").len(), 1);

    // Its crash leftover is not an owner.
    client.kill().expect("kill");
    client.wait().expect("reap");
    assert_eq!(reader.handoff_liveness(ID).await.safety, "nativeUnowned");
    assert!(reader.owners(ID).await.expect("owners").is_empty());

    fs::write(home.path().join("active_sessions.json"), "not json").expect("corrupt");
    assert_eq!(reader.handoff_liveness(ID).await.safety, "nativeUnknown");
}

#[test]
fn grok_client_child() {
    if std::env::var_os("PCX_GROK_CLIENT").is_some() {
        std::thread::sleep(std::time::Duration::from_secs(30));
    }
}
