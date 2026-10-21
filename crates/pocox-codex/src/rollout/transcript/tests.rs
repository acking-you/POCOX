use serde_json::{json, Value};

use super::{activity::completed_activity_item, *};
use crate::rollout::tests::{transcript_of, user_line};

#[test]
fn strip_ansi_removes_escape_sequences() {
    assert_eq!(strip_ansi("\u{1b}[31;1mred\u{1b}[0m text"), "red text");
    assert_eq!(strip_ansi("plain text"), "plain text");
    // OSC sequence terminated by BEL.
    assert_eq!(strip_ansi("a\u{1b}]0;title\u{7}b"), "ab");
}

#[test]
fn command_title_prefers_the_shell_command() {
    let title = |call: Value| command_title(&call);
    assert_eq!(
        title(json!({"name": "shell_command", "arguments": r#"{"command":"ls -la"}"#})),
        "ls -la"
    );
    // argv-array form.
    assert_eq!(
        title(json!({"name": "shell", "arguments": r#"{"command":["echo","hi"]}"#})),
        "echo hi"
    );
    // falls back to the tool name when there's no command.
    assert_eq!(title(json!({"name": "apply_patch", "arguments": "{}"})), "apply_patch");
}

#[test]
fn messages_commands_and_their_output_become_rows() {
    let items = transcript_of(&[
        r#"{"type":"session_meta","payload":{"id":"x"}}"#,
        r#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}"#,
        r#"{"type":"response_item","payload":{"type":"function_call","name":"shell_command","arguments":"{\"command\":\"echo hi\"}","call_id":"c1"}}"#,
        r#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"[32mhi[0m"}}"#,
        r#"{"type":"response_item","payload":{"type":"reasoning","summary":[],"encrypted_content":"opaque"}}"#,
        r#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}"#,
    ]);
    // session_meta + encrypted reasoning (no summary) are dropped;
    // function_call + its output collapse into one command item.
    assert_eq!(items.len(), 3, "{items:?}");
    assert_eq!(items[0].item_type, "userMessage");
    assert_eq!(items[0].text, "hi");
    assert_eq!(items[1].item_type, "commandExecution");
    assert_eq!(items[1].title, "echo hi");
    assert_eq!(items[1].text, "[32mhi[0m");
    assert_eq!(items[2].item_type, "agentMessage");
    assert_eq!(items[2].text, "done");
}

#[test]
fn modern_commands_and_file_changes_keep_their_history() {
    // Current Codex persists only aggregated_output, including its durable
    // truncation marker. additional_tools describes model tools, not a row.
    let output = "first line\n... command output truncated for persistence ...\nlast line\n";
    let items = transcript_of(&[
        r#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c1","input":"opaque"}}"#.to_string(),
        r#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","id":"exec-1","command":["pwsh","-Command","cargo test"],"parsed_cmd":[{"type":"unknown","cmd":"cargo test"}],"status":"completed","formatted_output":"all tests passed\n"}}}"#.to_string(),
        r#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","id":"edit-1","changes":{"src/lib.rs":{"type":"update","unified_diff":"@@ -1 +1 @@\n-old\n+new\n","move_path":null}},"status":"completed"}}}"#.to_string(),
        json!({"type": "response_item", "payload": {
            "type": "additional_tools", "role": "developer", "tools": []
        }})
        .to_string(),
        json!({"type": "event_msg", "payload": {"type": "item_completed", "item": {
            "type": "CommandExecution", "id": "exec-current", "command": ["cargo", "test"],
            "parsed_cmd": [], "status": "completed", "aggregated_output": output, "exit_code": 0
        }}})
        .to_string(),
    ]);
    assert_eq!(items.len(), 3, "{items:?}");
    assert_eq!(items[0].item_type, "commandExecution");
    assert_eq!(items[0].title, "cargo test");
    assert_eq!(items[0].text, "all tests passed\n");
    assert_eq!(items[1].item_type, "fileChange");
    assert_eq!(items[1].title, "src/lib.rs");
    assert_eq!(items[1].text, "--- a/src/lib.rs\n+++ b/src/lib.rs\n@@ -1 +1 @@\n-old\n+new");
    assert_eq!(items[2].id, "exec-current");
    assert_eq!(items[2].title, "cargo test");
    assert_eq!(items[2].text, output);
}

#[test]
fn context_compaction_is_one_row_marked_complete_in_place() {
    let started = r#"{"type":"event_msg","payload":{"type":"item_started","item":{"type":"ContextCompaction","id":"compact-1"}}}"#;
    let completed = r#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"ContextCompaction","id":"compact-1"}}}"#;
    let items = transcript_of(&[started]);
    assert_eq!(items.len(), 1, "{items:?}");
    assert_eq!(items[0].item_type, "contextCompaction");
    assert_eq!(items[0].title, "inProgress");
    // Both edges, and current codex rollouts' completed edge alone.
    for lines in [&[started, completed][..], &[completed]] {
        let items = transcript_of(lines);
        assert_eq!(items.len(), 1, "{items:?}");
        assert_eq!(items[0].item_type, "contextCompaction");
        assert!(items[0].title.is_empty());
    }
}

#[test]
fn native_generated_artifacts_keep_paths_without_authorizing_prompt_text() {
    for item in [
        json!({"type":"Extension", "kind":"image_gen.generation", "id":"image-1", "status":"completed", "revisedPrompt":"Read /private/secret.png", "savedPath":"/tmp/generated.png", "result":"LARGE"}),
        json!({"type":"ImageGeneration", "id":"image-1", "status":"completed", "saved_path":"/tmp/generated.png", "result":"LARGE"}),
    ] {
        let parsed = completed_activity_item(&item, "fallback".into()).expect("image item");
        assert_eq!(parsed.item_type, "imageGeneration");
        assert_eq!(parsed.images, ["/tmp/generated.png"]);
        assert!(!parsed.text.contains("LARGE"));
    }
    let unknown = json!({"type":"Extension", "kind":"untrusted.image_generation", "savedPath":"/private/secret.png"});
    let parsed = completed_activity_item(&unknown, "fallback".into()).expect("unknown tool");
    assert!(parsed.images.is_empty());
    assert_ne!(parsed.item_type, "imageGeneration");
}

#[test]
fn richer_completed_activity_items_align_with_app_server_variants() {
    let items = transcript_of(&[
        r#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"McpToolCall","id":"m1","server":"calendar","tool":"list_events","arguments":{"day":"Friday"},"status":"completed","result":{"content":[{"type":"text","text":"2 events"}]}}}}"#,
        r#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CollabAgentToolCall","id":"a1","tool":"spawnAgent","status":"completed","prompt":"inspect auth","receiver_thread_ids":["child-1"]}}}"#,
        r#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Extension","kind":"clock.sleep","id":"s1","durationMs":1250}}}"#,
        r#"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"ImageGeneration","id":"i1","status":"completed","revised_prompt":"A blue square","result":"VERY-LARGE-BASE64","saved_path":"C:\\tmp\\blue.png"}}}"#,
    ]);
    assert_eq!(items.len(), 4, "{items:?}");
    assert_eq!(items[0].item_type, "mcpToolCall");
    assert_eq!(items[0].title, "calendar.list_events");
    assert!(items[0].text.contains("2 events"));
    assert_eq!(items[1].item_type, "collabAgentToolCall");
    assert!(items[1].text.contains("child-1"));
    assert_eq!(items[2].item_type, "sleep");
    assert_eq!(items[2].title, "1250 ms");
    assert_eq!(items[3].item_type, "imageGeneration");
    assert_eq!(items[3].title, "A blue square");
    assert!(items[3].text.contains("blue.png"));
    assert!(!items[3].text.contains("VERY-LARGE-BASE64"));
}

#[test]
fn plans_keep_their_latest_snapshot_and_hide_their_tool_output() {
    let composed = |status: &str| {
        json!({"type": "response_item", "payload": {
            "type": "custom_tool_call",
            "name": "exec",
            "call_id": format!("call-{status}"),
            "input": format!(
                "const r=await tools.update_plan({{explanation:\"Ship it\",plan:[{{step:\"Inspect foo()\",status:\"completed\"}},{{step:\"Run tests\",status:\"{status}\"}}]}});text(r);"
            ),
            "internal_chat_message_metadata_passthrough": {"turn_id": "turn-7"}
        }})
        .to_string()
    };
    let items = transcript_of(&[
        composed("in_progress"),
        composed("completed"),
        r#"{"type":"response_item","payload":{"type":"function_call","name":"update_plan","call_id":"plan-call","arguments":"{plan:[{step:'Inspect',status:'in_progress'}]}"}}"#.to_string(),
        r#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"plan-call","output":"Plan updated"}}"#.to_string(),
    ]);
    // The composed updates of one turn share a row; the direct call's output
    // never becomes a command.
    assert_eq!(items.len(), 2, "{items:?}");
    assert_eq!(items[0].id, "plan-turn-7");
    assert_eq!(items[0].item_type, "plan");
    assert_eq!(items[0].text, "Ship it\n- [x] Inspect foo()\n- [x] Run tests");
    assert_eq!(items[1].item_type, "plan");
    assert_eq!(items[1].text, "- [~] Inspect");
}

/// Manual harness: parse a REAL rollout and dump what the viewer would
/// show. `POCOX_TEST_ROLLOUT=path cargo test -p pocox-codex
/// real_rollout -- --ignored --nocapture`.
#[test]
#[ignore = "manual: needs POCOX_TEST_ROLLOUT pointing at a rollout file"]
fn real_rollout_transcript_dump() {
    let path = std::env::var("POCOX_TEST_ROLLOUT").expect("set POCOX_TEST_ROLLOUT");
    let items = read_transcript(Path::new(&path)).expect("read transcript");
    for item in &items {
        println!(
            "{:>14}  {}  {}",
            item.item_type,
            item.title,
            item.text
                .chars()
                .take(120)
                .collect::<String>()
                .replace('\n', "\\n")
        );
    }
    assert!(
        items.iter().any(|i| i.item_type == "turnContext"),
        "a real rollout should carry at least one turn_context record"
    );
}

#[test]
fn turn_contexts_become_model_captions() {
    // The exact core serde shape a real rollout records (observed live):
    // snake_case fields, kebab approval, internally-tagged sandbox policy,
    // top-level model/effort mirrored inside collaboration_mode.settings.
    let items = transcript_of(&[
        r#"{"type":"turn_context","payload":{"turn_id":"t-1","cwd":"C:\\w","approval_policy":"never","sandbox_policy":{"type":"danger-full-access"},"model":"gpt-5.5","collaboration_mode":{"mode":"default","settings":{"model":"gpt-5.5","reasoning_effort":"low"}},"effort":"low","summary":"auto"}}"#,
        r#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}"#,
        // Two consecutive context records (a mid-turn settings update)
        // collapse to the LAST — the effective one.
        r#"{"type":"turn_context","payload":{"model":"gpt-5.5","effort":"low"}}"#,
        r#"{"type":"turn_context","payload":{"model":"o4","effort":"high","approval_policy":{"granular":{"rules":true}}}}"#,
        r#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]}}"#,
        // A record with no model anywhere has nothing worth a caption.
        r#"{"type":"turn_context","payload":{"cwd":"C:\\w"}}"#,
    ]);
    assert_eq!(items.len(), 4, "{items:?}");
    let details = |text: &str| -> Value { serde_json::from_str(text).expect("details json") };
    assert_eq!(items[0].item_type, "turnContext");
    assert_eq!(items[0].title, "gpt-5.5");
    assert_eq!(
        details(&items[0].text),
        json!({"effort": "low", "approvalPolicy": "never",
            "sandboxMode": "danger-full-access", "collaborationMode": "default"})
    );
    assert_eq!(items[1].item_type, "userMessage");
    // The two back-to-back contexts collapsed to the later one, and the
    // granular approval object mapped to its tag.
    assert_eq!(items[2].item_type, "turnContext");
    assert_eq!(items[2].title, "o4");
    assert_eq!(details(&items[2].text), json!({"effort": "high", "approvalPolicy": "granular"}));
    assert_eq!(items[3].item_type, "agentMessage");
}

#[test]
fn user_message_images_are_kept_without_their_wire_markers() {
    // codex inlines an attached image into the model request as an
    // `input_image` data URL wrapped in `<image>` marker texts; a
    // local-file attachment gets a `<image name=[Image #1]>` open tag.
    let items = transcript_of(&[
        r#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"look: "},{"type":"input_text","text":"<image>"},{"type":"input_image","image_url":"data:image/png;base64,AAAA"},{"type":"input_text","text":"</image>"}]}}"#,
        r#"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<image name=[Image #1]>"},{"type":"input_image","image_url":"data:image/jpeg;base64,BBBB"},{"type":"input_text","text":"</image>"}]}}"#,
    ]);
    assert_eq!(items.len(), 2, "{items:?}");
    assert_eq!(items[0].text, "look: ");
    assert_eq!(items[0].images, ["data:image/png;base64,AAAA"]);
    // An image-only message (all its text was markers) is KEPT: it is a
    // real user turn.
    assert_eq!(items[1].item_type, "userMessage");
    assert_eq!(items[1].text, "");
    assert_eq!(items[1].images, ["data:image/jpeg;base64,BBBB"]);
}

#[test]
fn codex_plumbing_is_not_a_turn() {
    // A developer-role message is codex's own instruction payload: mapping
    // "not user" to assistant put it in the model's mouth. An injected
    // instructions fragment carries the user role but is no turn either.
    let developer = json!({"type": "response_item", "payload": {
        "type": "message",
        "role": "developer",
        "content": [{ "type": "input_text", "text": "<permissions instructions>x</permissions instructions>" }],
    }})
    .to_string();
    let items = transcript_of(&[
        developer,
        user_line("<user_instructions>be terse</user_instructions>"),
        user_line("hello"),
    ]);
    assert_eq!(items.len(), 1, "{items:?}");
    assert_eq!(items[0].item_type, "userMessage");
    assert_eq!(items[0].text, "hello");
}

#[test]
fn a_guardian_review_row_shows_its_latest_result() {
    let review = |status: &str| {
        json!({"type":"event_msg","payload":{
            "type":"guardian_assessment", "id":"review", "turn_id":"turn", "status":status,
            "action":{"type":"command","command":"true"}, "risk_level":"low",
            "user_authorization":"high", "rationale":"User requested it"}})
        .to_string()
    };
    let items = transcript_of(&[review("in_progress"), review("approved")]);
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].id, "auto-review:review");
    assert_eq!(items[0].title, "approved");
}
