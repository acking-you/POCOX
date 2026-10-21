use serde_json::{json, Value};

use super::{
    message::{extract_preview, split_message_content, truncate_chars},
    meta::parse_session_meta,
    turn_state::classify_lines,
    *,
};

/// The transcript of a rollout made of `lines`.
pub(super) fn transcript_of(lines: &[impl AsRef<str>]) -> Vec<TranscriptItem> {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("rollout.jsonl");
    let text = lines
        .iter()
        .map(AsRef::as_ref)
        .collect::<Vec<_>>()
        .join("\n");
    std::fs::write(&path, text).expect("write rollout");
    read_transcript(&path).expect("read transcript")
}

/// A user message record carrying `text`.
pub(super) fn user_line(text: &str) -> String {
    json!({"type": "response_item", "payload": {
        "type": "message",
        "role": "user",
        "content": [{ "type": "input_text", "text": text }],
    }})
    .to_string()
}

fn event(payload: Value) -> String {
    json!({"timestamp": "t", "type": "event_msg", "payload": payload}).to_string()
}

#[test]
fn the_last_lifecycle_event_decides_the_turn_state() {
    let started = |turn: &str| event(json!({"type": "task_started", "turn_id": turn}));
    let completed = |turn: &str| {
        event(json!({"type": "task_complete", "turn_id": turn, "last_agent_message": "done"}))
    };
    let aborted = |turn: &str, reason: &str| {
        event(json!({"type": "turn_aborted", "turn_id": turn, "reason": reason}))
    };
    let noise = user_line("task_started is only text here");
    for (lines, expected) in [
        (vec![noise.clone()], TurnState::Empty),
        (vec![started("a"), completed("a"), started("b"), noise.clone()], TurnState::Incomplete),
        (vec![started("a"), aborted("a", "interrupted")], TurnState::Aborted("interrupted".into())),
        // completed → aborted → completed: the final completed is the verdict.
        (
            vec![completed("a"), aborted("b", "replaced"), started("c"), noise, completed("c")],
            TurnState::Completed,
        ),
    ] {
        assert_eq!(classify_lines(lines.iter().map(String::as_str)), expected, "{lines:?}");
    }
    // Nothing is in flight unless a started turn has not ended.
    assert!(TurnState::Empty.is_finished() && TurnState::Aborted("x".into()).is_finished());
    assert!(!TurnState::Incomplete.is_finished());
}

#[test]
fn session_headers_name_the_session_and_its_origin() {
    let line = r#"{"timestamp":"t","type":"session_meta","payload":{"id":"thr-1","cwd":"/repo","source":"vscode","originator":"codex_cli"}}"#;
    let meta = parse_session_meta(line).expect("meta");
    assert_eq!(meta.id, "thr-1");
    assert_eq!(meta.cwd.as_deref(), Some("/repo"));
    assert_eq!(meta.source.as_deref(), Some("vscode"));
    assert_eq!(meta.originator.as_deref(), Some("codex_cli"));
    let line = r#"{"type":"session_meta","payload":{"id":"x","source":{"kind":"cli"}}}"#;
    assert_eq!(parse_session_meta(line).expect("meta").source.as_deref(), Some("cli"));
    let line = r#"{"type":"event_msg","payload":{"type":"task_started"}}"#;
    assert!(parse_session_meta(line).is_none(), "not a header");
    let path = Path::new("rollout-2026-06-17T06-20-52-019ed285-eb3f-7010-b4f9-2ad9389c8e99.jsonl");
    assert_eq!(thread_id_from_path(path).as_deref(), Some("019ed285-eb3f-7010-b4f9-2ad9389c8e99"));
}

#[test]
fn compressed_rollouts_are_found_read_and_superseded_by_a_plain_copy() {
    let dir = tempfile::tempdir().expect("tempdir");
    let day = dir.path().join("2025/11/17");
    std::fs::create_dir_all(&day).expect("day");
    let id = "019a9209-e42f-78f2-a98c-e1ba9e0e79a1";
    let name = format!("rollout-2025-11-17T21-38-33-{id}.jsonl");
    let header = json!({"type":"session_meta","payload":{"id":id,"cwd":"/repo"}}).to_string();
    let started = event(json!({"type": "task_started", "turn_id": "t"}));
    let text = format!("{header}\n{}\n{started}\n", user_line("hello from last week"));
    let compressed = day.join(format!("{name}.zst"));
    std::fs::write(&compressed, zstd::encode_all(text.as_bytes(), 0).expect("encode"))
        .expect("write");

    assert_eq!(thread_id_from_path(&compressed).as_deref(), Some(id));
    assert_eq!(rollout_path_in(dir.path(), id).expect("lookup"), Some(compressed.clone()));
    let info = read_session_info(&compressed).expect("info");
    assert_eq!(
        (info.cwd.as_deref(), info.preview.as_str()),
        (Some("/repo"), "hello from last week")
    );
    // Lifecycle markers of a compressed file are not decoded.
    assert_eq!(info.turn_state, TurnState::Unknown);
    assert_eq!(read_transcript(&compressed).expect("transcript")[0].text, "hello from last week");

    // A path listed before a representation change still reads the session.
    let plain = day.join(&name);
    assert_eq!(
        read_session_info(&plain)
            .expect("listed plain")
            .rollout_path,
        compressed
    );
    assert_eq!(read_transcript(&plain).expect("listed plain").len(), 1);

    // Decompressed before an append, the plain copy is the session.
    std::fs::write(&plain, &text).expect("plain");
    assert_eq!(rollout_paths_in(dir.path()).expect("paths"), vec![plain.clone()]);
    assert_eq!(rollout_path_in(dir.path(), id).expect("lookup"), Some(plain.clone()));
    assert_eq!(read_session_info(&plain).expect("info").turn_state, TurnState::Incomplete);
}

#[test]
fn guardian_sessions_keep_their_parent_and_classification() {
    let header = json!({"type":"session_meta","payload":{
        "id":"child", "parent_thread_id":"parent", "thread_source":"guardian_review",
        "source":{"subagent":{"other":"guardian"}}}});
    let meta = parse_session_meta(&header.to_string()).expect("metadata");
    assert_eq!(meta.parent_thread_id.as_deref(), Some("parent"));
    assert_eq!(meta.thread_source.as_deref(), Some("guardian_review"));
    assert_eq!(
        thread_source(&json!({"threadSource":null,"source":{"subAgent":{"other":"guardian"}}}))
            .as_deref(),
        Some("guardian_review")
    );
    assert_eq!(
        parent_thread_id(&json!({"source":{"subagent":{"thread_spawn":{
            "parent_thread_id":"older-parent", "depth":1}}}}))
        .as_deref(),
        Some("older-parent")
    );
}

#[test]
fn preview_is_the_first_user_text_in_any_content_shape() {
    let meta = r#"{"type":"session_meta","payload":{"id":"x"}}"#;
    let event = r#"{"type":"event_msg","payload":{"type":"user_message","content":[{"type":"text","text":"hello there"}]}}"#;
    assert_eq!(extract_preview(&format!("{meta}\n{event}\n")), "hello there");
    // `content` as a plain string rather than the structured parts array.
    let plain = r#"{"type":"response_item","payload":{"type":"message","role":"user","content":"hi from a string"}}"#;
    assert_eq!(extract_preview(&format!("{meta}\n{plain}\n")), "hi from a string");
    // A first message that carried an attachment leaks no `<image>` framing.
    let image = r#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"look: "},{"type":"input_text","text":"<image>"},{"type":"input_image","image_url":"data:image/png;base64,AA"},{"type":"input_text","text":"</image>"}]}}"#;
    assert_eq!(extract_preview(image), "look:");
}

#[test]
fn truncate_is_char_boundary_safe() {
    let s = "héllo wörld and then some more text past the limit boundary here";
    let out = truncate_chars(s, 10);
    assert_eq!(out.chars().count(), 10);
    assert!(out.ends_with('…'));
}

#[test]
fn image_markers_are_stripped_only_next_to_an_image() {
    // A user who literally typed "<image>" (no adjacent input_image) keeps
    // their text — stripping is adjacency-gated like codex's own parser.
    let typed =
        json!({"type":"message","role":"user","content":[{"type":"input_text","text":"<image>"}]});
    assert_eq!(split_message_content(&typed), ("<image>".to_string(), Vec::new()));
    // …while a real wrapped attachment still strips its markers.
    let wrapped = json!({"type":"message","role":"user","content":[
        {"type":"input_text","text":"<image>"},
        {"type":"input_image","image_url":"data:image/png;base64,CC"},
        {"type":"input_text","text":"</image>"}]});
    assert_eq!(
        split_message_content(&wrapped),
        (String::new(), vec!["data:image/png;base64,CC".to_string()])
    );
}

#[test]
fn preview_skips_injected_context_fragments() {
    // An IDE-started session opens with codex's own plugin list, so the
    // first user-role message is not the user's. Every such session used
    // to be labelled "<recommended_plugins>".
    let head = format!(
        "{}\n{}",
        user_line("<recommended_plugins>\n- Google Drive (gd@openai)\n</recommended_plugins>"),
        user_line("为什么仍然黑屏"),
    );
    assert_eq!(extract_preview(&head), "为什么仍然黑屏");
    // The real shape from a VS Code session: one user message carrying the
    // plugin list AND the project's AGENTS.md, then the actual request in
    // the next message. Judging the joined text matched neither marker
    // pair, so the list showed a title made of wire.
    let machinery = json!({"type": "response_item", "payload": {
        "type": "message",
        "role": "user",
        "content": [
            { "type": "input_text",
              "text": "<recommended_plugins>\n- Box (box@openai)\n</recommended_plugins>" },
            { "type": "input_text",
              "text": "# AGENTS.md instructions for D:\\p\n\n<INSTRUCTIONS>\nbe terse\n</INSTRUCTIONS>" },
        ],
    }});
    let head = format!("{machinery}\n{}", user_line("帮忙把最新的代码同步过去"));
    assert_eq!(extract_preview(&head), "帮忙把最新的代码同步过去");
}

#[test]
fn context_fragments_are_recognised_only_when_they_are_the_whole_message() {
    assert!(is_context_fragment("<turn_aborted>stopped</turn_aborted>"));
    // Leading/trailing whitespace and tag case are upstream-tolerated.
    assert!(is_context_fragment("\n  <ENVIRONMENT_CONTEXT>cwd=/x</environment_context>  \n"));
    // A person quoting a marker is still writing their own message.
    assert!(!is_context_fragment("why does <turn_aborted> show up in my logs?"));
    assert!(!is_context_fragment("<recommended_plugins>"));
    assert!(!is_context_fragment("plain question"));
}

#[test]
fn context_fragment_check_survives_multibyte_text() {
    // Regression: the marker lengths land inside a Han glyph, so slicing by
    // byte offset panicked on any Chinese message long enough to reach the
    // comparison — which is most of them, and the session scan runs this on
    // every rollout.
    let long_chinese = "为什么仍然黑屏为什么仍然黑屏为什么仍然黑屏";
    assert!(long_chinese.len() > 39, "fixture must clear the length guard");
    assert!(!is_context_fragment(long_chinese));
    assert!(!is_context_fragment("🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂"));
    assert_eq!(extract_preview(&user_line(long_chinese)), long_chinese);
}

#[test]
fn voice_handoff_shows_what_the_user_said() {
    // The person really said this — it must be unwrapped, never hidden the
    // way a machine-written fragment is.
    let wrapped = "<realtime_delegation>\n  <input>run ls</input>\n  <transcript_delta>user: run \
                   ls</transcript_delta>\n</realtime_delegation>";
    assert!(!is_context_fragment(wrapped));
    assert_eq!(realtime_delegation_input(wrapped).as_deref(), Some("run ls"));
    // The list needs one line, so the preview unwraps…
    assert_eq!(extract_preview(&user_line(wrapped)), "run ls");
    assert_eq!(realtime_delegation_input("plain text"), None);

    // …but the transcript keeps it whole, because the spoken turns inside
    // are the conversation and the UI renders them as their own card.
    let items = transcript_of(&[user_line(wrapped)]);
    assert_eq!(items.len(), 1);
    assert!(items[0].text.contains("<transcript_delta>"));
}
