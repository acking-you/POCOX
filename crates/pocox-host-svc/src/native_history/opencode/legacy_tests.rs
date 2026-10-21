use tempfile::TempDir;

use super::*;
const SESSION: &str = "ses_legacy";

async fn fixture(path: &std::path::Path) -> SqliteConnection {
    let mut db = SqliteConnection::connect_with(
        &SqliteConnectOptions::new()
            .filename(path)
            .create_if_missing(true),
    )
    .await
    .expect("db");
    for query in [
        "CREATE TABLE session(id TEXT,directory TEXT,title TEXT,parent_id TEXT,time_created \
         INTEGER,time_updated INTEGER,revert TEXT)",
        "CREATE TABLE message(id TEXT,session_id TEXT,time_created INTEGER,data TEXT)",
        "CREATE INDEX message_session_time_created_id_idx ON message(session_id,time_created,id)",
        "CREATE TABLE part(id TEXT,message_id TEXT,session_id TEXT,data TEXT)",
        "CREATE INDEX part_message_id_id_idx ON part(message_id,id)",
        "INSERT INTO session VALUES('ses_legacy','/project','Legacy',NULL,1,1000,NULL)",
    ] {
        sqlx::query(query).execute(&mut db).await.expect("schema");
    }
    // Same timestamp exercises the stable ID tiebreaker, not time alone.
    for i in 1..=6 {
        let id = format!("msg_{i}");
        let role = if i % 2 == 1 { "user" } else { "assistant" };
        sqlx::query("INSERT INTO message VALUES(?,?,10,?)")
            .bind(&id)
            .bind(SESSION)
            .bind(json!({"role":role,"providerMetadata":{"secret":"not-public"}}).to_string())
            .execute(&mut db)
            .await
            .expect("message");
        let parts = if role == "user" {
            vec![
                json!({"type":"text","text":format!("prompt {i}")}),
                json!({"type":"text","text":"private-synthetic","synthetic":true}),
            ]
        } else {
            vec![
                json!({"type":"text","text":format!("reply {i}")}),
                json!({"type":"reasoning","text":"private-thought"}),
                json!({"type":"tool","callID":"call","tool":"read","state":{"status":"completed","input":{"path":"demo"},"output":"tool result","metadata":{"private":"not-public"}}}),
            ]
        };
        for (j, part) in parts.into_iter().enumerate() {
            sqlx::query("INSERT INTO part VALUES(?,?,?,?)")
                .bind(format!("prt_{i}_{j}"))
                .bind(&id)
                .bind(SESSION)
                .bind(part.to_string())
                .execute(&mut db)
                .await
                .expect("part");
        }
    }
    db
}

#[tokio::test]
async fn legacy_pages_preserve_order_public_tools_and_disk_bytes() {
    let temp = TempDir::new().expect("temp");
    let path = temp.path().join("opencode.db");
    fixture(&path).await.close().await.expect("close");
    let original = std::fs::read(&path).expect("bytes");
    let source = OpenCodeHistory::new(path.clone()).expect("source");
    let page = source.read_page(SESSION, None, 2).await.expect("tail");
    assert_eq!(page.turns.iter().map(|v| v.id.as_str()).collect::<Vec<_>>(), vec![
        "native:msg_3",
        "native:msg_5"
    ]);
    assert_eq!(page.turns[0].items[2].text, "tool result");
    assert_eq!(
        page.turns[0].items[2]
            .tool
            .as_ref()
            .expect("tool")
            .raw_input,
        Some(json!({"path":"demo"}))
    );
    assert_eq!(page.total_turns, None);
    assert!(page.has_older);
    let encoded = serde_json::to_string(&page).expect("json");
    for private in ["private-thought", "private-synthetic", "not-public"] {
        assert!(!encoded.contains(private));
    }
    let older = source
        .read_page(SESSION, page.next_before.as_deref(), 2)
        .await
        .expect("older");
    assert_eq!(older.turns.len(), 1);
    assert_eq!(older.turns[0].id, "native:msg_1");
    assert!(!older.has_older);
    let selected = source
        .read_turn(SESSION, "native:msg_3")
        .await
        .expect("selected");
    assert_eq!(selected.turns.len(), 1);
    assert_eq!(selected.turns[0].items[0].text, "prompt 3");
    assert!(source
        .read_page(SESSION, Some("native:msg_missing"), 2)
        .await
        .is_err());
    assert_eq!(std::fs::read(&path).expect("bytes"), original);
    assert_eq!(
        source.list_sessions(None, 20).await.expect("list")["sessions"][0]["updatedAt"],
        "1970-01-01T00:00:01.000Z"
    );
}

#[tokio::test]
async fn v2_empty_table_uses_legacy_but_partial_revert_and_limits_remain_visible() {
    let temp = TempDir::new().expect("temp");
    let path = temp.path().join("opencode.db");
    let mut db = fixture(&path).await;
    sqlx::query(
        "CREATE TABLE session_message(id TEXT,session_id TEXT,type TEXT,seq INTEGER,data TEXT)",
    )
    .execute(&mut db)
    .await
    .expect("v2 schema");
    sqlx::query("UPDATE session SET revert=?")
        .bind(json!({"messageID":"msg_5","partID":"prt_5_1"}).to_string())
        .execute(&mut db)
        .await
        .expect("revert");
    sqlx::query("UPDATE part SET data=? WHERE id='prt_4_0'")
        .bind(json!({"type":"text","text":"x".repeat(MAX_ROW_BYTES+1)}).to_string())
        .execute(&mut db)
        .await
        .expect("large part");
    let source = OpenCodeHistory::new(path).expect("source");
    let page = source.read_page(SESSION, None, 20).await.expect("page");
    assert_eq!(page.total_turns, None);
    assert_eq!(page.turns.len(), 2);
    assert!(page.truncated);
    assert!(page.turns.last().expect("last").omitted > 0);
    assert!(!serde_json::to_string(&page)
        .expect("json")
        .contains("prompt 5"));
    assert!(source.read_turn(SESSION, "native:msg_5").await.is_err());
}
