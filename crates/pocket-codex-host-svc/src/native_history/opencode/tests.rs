use tempfile::TempDir;

use super::*;

const SESSION: &str = "ses_native_fixture";

async fn database(path: &std::path::Path) -> SqliteConnection {
    let mut connection = SqliteConnection::connect_with(
        &SqliteConnectOptions::new()
            .filename(path)
            .create_if_missing(true),
    )
    .await
    .expect("fixture database");
    for sql in [
        "CREATE TABLE session (id TEXT PRIMARY KEY,directory TEXT,title TEXT,parent_id \
         TEXT,time_created INTEGER,time_updated INTEGER,revert TEXT)",
        "CREATE TABLE session_message (id TEXT PRIMARY KEY,session_id TEXT,type TEXT,seq \
         INTEGER,data TEXT)",
        "CREATE INDEX fixture_session_seq ON session_message(session_id,seq)",
        "CREATE TABLE message (id TEXT PRIMARY KEY,session_id TEXT)",
    ] {
        sqlx::query(sql)
            .execute(&mut connection)
            .await
            .expect("schema");
    }
    sqlx::query("INSERT INTO session VALUES (?,?,?,NULL,1,2,NULL)")
        .bind(SESSION)
        .bind("/project")
        .bind("Native fixture")
        .execute(&mut connection)
        .await
        .expect("session");
    connection
}

async fn message(db: &mut SqliteConnection, seq: i64, kind: &str, data: Value) {
    sqlx::query("INSERT INTO session_message VALUES (?,?,?,?,?)")
        .bind(format!("msg_{seq}"))
        .bind(SESSION)
        .bind(kind)
        .bind(seq)
        .bind(data.to_string())
        .execute(db)
        .await
        .expect("fixture message");
}

#[tokio::test]
async fn v2_pagination_and_public_projection_are_read_only() {
    let temp = TempDir::new().expect("temp");
    let path = temp.path().join("opencode.db");
    let mut db = database(&path).await;
    for n in 0..3 {
        message(&mut db, n * 2 + 1, "user", json!({"text":format!("prompt {n}")})).await;
        message(&mut db,n*2+2,"assistant",json!({"content":[
            {"type":"text","text":format!("reply {n}")},
            {"type":"reasoning","text":"private-thought","providerMetadata":{"signature":"private-signature"}},
            {"type":"tool","id":"call","name":"read","provider":{"metadata":"private-provider"},
             "state":{"status":"completed","input":{"path":"demo"},"content":[{"type":"text","text":"tool text"}]}}
        ]})).await;
    }
    db.close().await.expect("close");
    let original = std::fs::read(&path).expect("bytes");
    let source = OpenCodeHistory::new(path.clone()).expect("source");
    let list = source.list_sessions(None, 1).await.expect("list");
    assert_eq!(list["sessions"][0]["sessionId"], SESSION);
    let tail = source.read_page(SESSION, None, 2).await.expect("tail");
    assert_eq!(tail.total_turns, None);
    let explicit = source
        .read_turn(SESSION, "native:msg_3")
        .await
        .expect("explicit turn");
    assert_eq!(explicit.turns.len(), 1);
    assert_eq!(explicit.turns[0].id, "native:msg_3");
    let by_id = source
        .read_page(SESSION, Some("native:msg_3"), 2)
        .await
        .expect("turn boundary");
    assert_eq!(by_id.turns[0].id, "native:msg_1");
    assert!(tail.has_older);
    assert_eq!(
        tail.turns
            .iter()
            .map(|turn| turn.id.as_str())
            .collect::<Vec<_>>(),
        vec!["native:msg_3", "native:msg_5"]
    );
    assert_eq!(tail.turns[0].items[2].text, "tool text");
    let encoded = serde_json::to_string(&tail).expect("json");
    for private in ["private-thought", "private-signature", "private-provider"] {
        assert!(!encoded.contains(private));
    }
    let older = source
        .read_page(SESSION, tail.next_before.as_deref(), 2)
        .await
        .expect("older");
    assert_eq!(older.turns.len(), 1);
    assert_eq!(older.turns[0].id, "native:msg_1");
    assert!(!older.has_older);
    assert_eq!(std::fs::read(&path).expect("bytes"), original);
    let (mut reader, _) = source.connect().await.expect("reader");
    assert!(sqlx::query("DELETE FROM session")
        .execute(&mut reader)
        .await
        .is_err());
}

#[tokio::test]
async fn revert_partial_records_and_oversized_content_never_look_complete() {
    let temp = TempDir::new().expect("temp");
    let path = temp.path().join("opencode.db");
    let mut db = database(&path).await;
    message(&mut db, 1, "user", json!({"text":"keep"})).await;
    message(
        &mut db,
        2,
        "assistant",
        json!({"content":[{"type":"text","text":"large".repeat(MAX_ROW_BYTES)}]}),
    )
    .await;
    message(&mut db, 3, "user", json!({"text":"reverted"})).await;
    sqlx::query("UPDATE session SET revert=?")
        .bind(json!({"messageID":"msg_3","partID":"partial"}).to_string())
        .execute(&mut db)
        .await
        .expect("revert");
    let source = OpenCodeHistory::new(path).expect("source");
    let page = source.read_page(SESSION, None, 20).await.expect("page");
    assert!(page.truncated);
    assert!(page.turns[0].omitted > 0);
    assert_eq!(page.total_turns, None);
    assert!(!serde_json::to_string(&page)
        .expect("json")
        .contains("reverted"));
    assert!(source.read_page("../invalid", None, 20).await.is_err());
    assert!(source.read_page(SESSION, Some("oc2:-1"), 20).await.is_err());
}

#[tokio::test]
async fn missing_or_unsupported_sources_fail_without_creating_empty_history() {
    let temp = TempDir::new().expect("temp");
    let path = temp.path().join("missing.db");
    let source = OpenCodeHistory::new(path.clone()).expect("source");
    assert!(source.list_sessions(None, 20).await.is_err());
    assert!(!path.exists());
    let mut db = database(&path).await;
    sqlx::query("INSERT INTO message VALUES ('old',?)")
        .bind(SESSION)
        .execute(&mut db)
        .await
        .expect("legacy row");
    assert!(source
        .read_page(SESSION, None, 20)
        .await
        .expect_err("unsupported legacy")
        .to_string()
        .contains("legacy"));
}

#[tokio::test]
async fn replacing_a_database_invalidates_the_source_generation() {
    let temp = TempDir::new().expect("temp");
    let path = temp.path().join("opencode.db");
    let db = database(&path).await;
    db.close().await.expect("close");
    let source = OpenCodeHistory::new(path.clone()).expect("source");
    let before = source.revision(SESSION).await.expect("revision");
    let replacement = temp.path().join("replacement.db");
    let db = database(&replacement).await;
    db.close().await.expect("close");
    std::fs::remove_file(&path).expect("remove fixture");
    std::fs::rename(replacement, &path).expect("replace fixture");
    let after = source.revision(SESSION).await.expect("revision");
    assert_ne!(before["generation"], after["generation"]);
}

#[tokio::test]
async fn orphan_prefix_remains_pageable_and_revert_invalidates_windows() {
    let temp = TempDir::new().expect("temp");
    let path = temp.path().join("opencode.db");
    let mut db = database(&path).await;
    message(&mut db, 0, "assistant", json!({"content":[{"type":"text","text":"orphan"}]})).await;
    message(&mut db, 1, "user", json!({"text":"one"})).await;
    message(&mut db, 2, "assistant", json!({"content":[{"type":"text","text":"reply"}]})).await;
    let source = OpenCodeHistory::new(path).expect("source");
    let tail = source.read_page(SESSION, None, 1).await.expect("tail");
    assert_eq!(tail.turns.len(), 1);
    assert_eq!(tail.turns[0].id, "native:msg_1");
    assert!(tail.has_older);
    let prefix = source
        .read_page(SESSION, tail.next_before.as_deref(), 1)
        .await
        .expect("prefix");
    assert_eq!(prefix.turns.len(), 1);
    assert_eq!(prefix.turns[0].items[0].text, "orphan");
    assert!(!prefix.has_older);
    assert_eq!(tail.total_turns, None);
    assert_eq!(prefix.total_turns, None);
    let full = source
        .read_page(SESSION, None, 20)
        .await
        .expect("full public view");
    assert_eq!(full.turns.len(), 2);
    assert_eq!(full.turns[0].id, prefix.turns[0].id);
    assert_eq!(full.turns[1].id, tail.turns[0].id);
    sqlx::query("UPDATE session SET revert=?")
        .bind(json!({"messageID":"msg_1"}).to_string())
        .execute(&mut db)
        .await
        .expect("revert");
    let after = source.revision(SESSION).await.expect("after");
    assert_ne!(tail.generation, after["generation"].as_str().expect("generation"));
}

#[tokio::test]
async fn opencode_2_rows_and_sessions_beside_the_frozen_1x_table() {
    let temp = TempDir::new().expect("temp");
    let path = temp.path().join("opencode.db");
    // An upgraded database: 2.x copied what it found into `session_v2`; the
    // fixture's session in the 1.x table was written by 1.x afterwards.
    let mut db = database(&path).await;
    sqlx::query(
        "CREATE TABLE session_v2 (id TEXT PRIMARY KEY,directory TEXT,title TEXT,parent_id \
         TEXT,time_created INTEGER,time_updated INTEGER,revert TEXT)",
    )
    .execute(&mut db)
    .await
    .expect("2.x schema");
    sqlx::query("INSERT INTO session_v2 VALUES ('ses_new','/new','New session',NULL,3,4,NULL)")
        .execute(&mut db)
        .await
        .expect("2.x session");
    let inline = json!({"data":"AA==","mime":"image/png","source":{"type":"inline"}});
    let path_file = json!({"data":"AA==","mime":"image/png",
        "source":{"type":"uri","uri":"file:///private.png"}});
    let output = json!({"output":"listing","cursor":7,"size":7,"truncated":false});
    let failed = |message: &str| json!({"outcome":"failed","error":{"message":message}});
    for (seq, kind, data) in [
        (1, "user", json!({"text":"look","files":[inline, path_file]})),
        (2, "location-switched", json!({"location":{"directory":"/new"}})),
        (3, "shell", json!({"shellID":"sh_1","command":"ls","status":"exited","output":output})),
        (4, "assistant", json!({"content":[],"error":{"message":"refused"}})),
        (5, "idle", failed("refused")),
        (6, "user", json!({"text":"again"})),
        (7, "idle", failed("resume limit")),
    ] {
        sqlx::query("INSERT INTO session_message VALUES (?,'ses_new',?,?,?)")
            .bind(format!("msg_new{seq}"))
            .bind(kind)
            .bind(seq)
            .bind(data.to_string())
            .execute(&mut db)
            .await
            .expect("2.x row");
    }
    db.close().await.expect("close");
    let source = OpenCodeHistory::new(path).expect("source");
    let list = source.list_sessions(None, 20).await.expect("list");
    let ids: Vec<_> = list["sessions"]
        .as_array()
        .expect("rows")
        .iter()
        .map(|row| row["sessionId"].as_str())
        .collect();
    assert_eq!(ids, [Some("ses_new"), Some(SESSION)]);
    assert!(source.read_page(SESSION, None, 20).await.is_ok(), "a 1.x-only session opens");
    let page = source.read_page("ses_new", None, 20).await.expect("page");
    let first = &page.turns[0].items;
    assert_eq!(first[0].images, ["data:image/png;base64,AA=="], "a path's bytes stay unread");
    assert!(first[0].omitted.contains(&"attachments".to_owned()));
    assert_eq!((first[1].title.as_str(), first[1].text.as_str()), ("ls", "listing"));
    assert_eq!(first[1].tool.as_ref().map(|t| t.status.as_str()), Some("completed"));
    let texts = |items: &[crate::acp::fold::Item]| -> Vec<String> {
        items[1..].iter().map(|item| item.text.clone()).collect()
    };
    assert_eq!(texts(first)[1..], ["refused"], "one error, not one per marker");
    assert_eq!(texts(&page.turns[1].items), ["resume limit"]);
}
