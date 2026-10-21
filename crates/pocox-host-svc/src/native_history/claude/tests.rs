use super::*;

#[test]
fn reader_requires_host_absolute_paths() {
    assert!(ClaudeHistory::new("node".into(), "/sdk.mjs".into(), "/config".into()).is_err());
    assert!(ClaudeHistory::new("/node".into(), "sdk.mjs".into(), "/config".into()).is_err());
    assert!(ClaudeHistory::new("/node".into(), "/sdk.mjs".into(), "config".into()).is_err());
}

#[tokio::test]
async fn invalid_session_and_cursor_are_rejected_before_executing_a_reader() {
    let reader = ClaudeHistory::new("/no-node".into(), "/sdk.mjs".into(), "/config".into())
        .expect("configuration");
    assert!(reader
        .read_page("../../private", None, 20)
        .await
        .expect_err("invalid reader input")
        .to_string()
        .contains("session id"));
    let id = "00000000-0000-4000-8000-000000000001";
    assert!(reader
        .read_page(id, None, 101)
        .await
        .expect_err("invalid reader input")
        .to_string()
        .contains("limit"));
    assert!(reader
        .read_page(id, Some(&"x".repeat(129)), 20)
        .await
        .expect_err("invalid reader input")
        .to_string()
        .contains("cursor"));
}

// The Rust suite does not require a JavaScript runtime. This integration test
// is also run explicitly with the same compatible Node used by the product.
#[cfg(unix)]
#[tokio::test]
#[ignore = "requires POCOX_TEST_NODE pointing to Node.js 22+"]
async fn sdk_read_is_cached_and_invalidated_without_resuming() {
    let node = PathBuf::from(std::env::var_os("POCOX_TEST_NODE").expect("POCOX_TEST_NODE"));
    let temp = tempfile::tempdir().expect("fixture");
    let root = temp.path().join("claude");
    let project = root.join("projects/fixture");
    std::fs::create_dir_all(&project).expect("projects");
    let session = "00000000-0000-4000-8000-000000000001";
    let transcript = project.join(format!("{session}.jsonl"));
    std::fs::write(&transcript, "header\nfixture\n").expect("source");
    let sdk = temp.path().join("sdk.mjs");
    let calls = temp.path().join("calls");
    std::fs::write(
        &sdk,
        format!(
            r#"
        import fs from 'node:fs';
        export async function getSessionInfo(id) {{
            return {{sessionId:id, cwd:'/fixture', summary:'Fixture', lastModified:1}};
        }}
        export async function getSessionMessages(id) {{
            fs.appendFileSync({}, 'read\n');
            return [{{type:'user',uuid:id,message:{{content:'fixture prompt'}}}}];
        }}
        export function query() {{throw new Error('must never query');}}
    "#,
            serde_json::to_string(&calls).expect("path")
        ),
    )
    .expect("mock SDK");
    let reader = ClaudeHistory::new(node, sdk, root).expect("reader");
    let first = reader.read_page(session, None, 20).await.expect("page");
    let cached = reader
        .read_page(session, None, 20)
        .await
        .expect("cached page");
    assert_eq!(first.turns, cached.turns);
    assert_eq!(std::fs::read_to_string(&calls).expect("calls"), "read\n");
    std::fs::write(&transcript, "header\nfixture\nappended\n").expect("change");
    let changed = reader
        .read_page(session, None, 20)
        .await
        .expect("changed page");
    assert_ne!(changed.revision, first.revision);
    assert_eq!(changed.generation, first.generation, "append keeps source identity");
    assert_eq!(std::fs::read_to_string(&calls).expect("calls"), "read\nread\n");
    std::fs::write(&transcript, "header\n").expect("truncate");
    let truncated = reader
        .read_page(session, None, 20)
        .await
        .expect("truncated source");
    assert_ne!(truncated.generation, changed.generation);
    std::fs::write(&transcript, "header\nnew content\n").expect("append after truncation");
    let appended = reader
        .read_page(session, None, 20)
        .await
        .expect("append after truncation");
    assert_eq!(appended.generation, truncated.generation);
    assert_eq!(std::fs::read_to_string(&calls).expect("calls"), "read\nread\nread\nread\n");
    std::fs::remove_file(&transcript).expect("remove source");
    assert!(
        reader.read_page(session, None, 20).await.is_err(),
        "removed source must not return stale authoritative cache"
    );
}
