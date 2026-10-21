use super::*;

#[test]
fn summary_takes_the_first_sentence_and_drops_markdown_scaffolding() {
    // A heading / fence opener says nothing in a two-line list row.
    let md = "## 结论\n\n判断为 GitHub 解封后粉丝关系已恢复，但主页计数尚未同步。后续建议等待。";
    assert_eq!(
        first_sentence(md).as_deref(),
        Some("判断为 GitHub 解封后粉丝关系已恢复，但主页计数尚未同步。")
    );
    // Bullets are flattened onto one line rather than kept as markers.
    assert_eq!(first_sentence("- 已完成提交\n- 已推送").as_deref(), Some("已完成提交 已推送"));
    // Nothing usable stays None instead of an empty row.
    assert!(first_sentence("```\n\n#\n").is_none());
}

#[test]
fn summary_splits_english_but_not_abbreviations_or_versions() {
    // A period followed by space + capital is a real boundary.
    assert_eq!(first_sentence("Pushed the fix. Docs follow.").as_deref(), Some("Pushed the fix."));
    // A version or decimal is not, even though it contains a period.
    assert_eq!(
        first_sentence("Bumped to 0.1.9 and tagged it").as_deref(),
        Some("Bumped to 0.1.9 and tagged it")
    );
    // Trailing period with nothing after it still ends the sentence.
    assert_eq!(first_sentence("Done.").as_deref(), Some("Done."));
}

#[test]
fn summary_keeps_going_past_an_abbreviation() {
    // A capitalised word after an abbreviation is ordinary English, not a
    // boundary. Looking only at the FOLLOWING character cut these to
    // "Dr." / "U.S." / "E.g.", which told the reader nothing.
    assert_eq!(
        first_sentence("Dr. Smith fixed the issue.").as_deref(),
        Some("Dr. Smith fixed the issue.")
    );
    assert_eq!(
        first_sentence("U.S. Government policy changed.").as_deref(),
        Some("U.S. Government policy changed.")
    );
    assert_eq!(first_sentence("E.g. Use the builder.").as_deref(), Some("E.g. Use the builder."));
    // An initial in a name is the same shape as an abbreviation.
    assert_eq!(
        first_sentence("See A. Smith for details. That is all.").as_deref(),
        Some("See A. Smith for details.")
    );
    // Mid-sentence abbreviations too, not just leading ones.
    assert_eq!(
        first_sentence("Added etc. handling. Shipped.").as_deref(),
        Some("Added etc. handling.")
    );
    // …and a real boundary right after an abbreviation still splits: the
    // abbreviation is the word before THIS period, not somewhere earlier.
    assert_eq!(
        first_sentence("Talked to Dr. Smith. Then shipped.").as_deref(),
        Some("Talked to Dr. Smith.")
    );
}

#[test]
fn summary_caps_a_runaway_sentence() {
    // No sentence end for a long stretch: cut with an ellipsis rather than
    // letting an entire paragraph into the row.
    let long = "字".repeat(400);
    let out = first_sentence(&long).expect("some text");
    assert!(out.ends_with('…'), "{out}");
    assert!(out.chars().count() <= 161, "{}", out.chars().count());
    // An early period is NOT a sentence end (e.g. "v1.2"), so a short
    // fragment keeps reading to something meaningful.
    let out = first_sentence("v1.2 已发布。细节见文档。").expect("some text");
    assert_eq!(out, "v1.2 已发布。");
}

#[test]
fn maps_agent_delta_text() {
    let inbound = Inbound {
        method: "item/agentMessage/delta".into(),
        params: Some(json!({"threadId":"t1","itemId":"i1","delta":"hel"})),
        request_id: None,
    };
    let ev = map_event(inbound);
    assert_eq!(ev.kind, "item/agentMessage/delta");
    assert_eq!(ev.thread_id.as_deref(), Some("t1"));
    assert_eq!(ev.item_type.as_deref(), Some("agentMessage"));
    assert_eq!(ev.text.as_deref(), Some("hel"));
}

#[test]
fn live_checkpoints_retain_text_before_item_completion() {
    let transcript = Mutex::new(LiveTranscript::default());
    for (method, id) in
        [("item/agentMessage/delta", "message"), ("item/commandExecution/outputDelta", "command")]
    {
        for text in ["partial ", "中文"] {
            buffer_item(&transcript, &Inbound {
                method: method.into(),
                params: Some(
                    json!({"threadId": "thread", "turnId": "turn", "itemId": id, "delta": text}),
                ),
                request_id: None,
            });
        }
    }
    {
        let items = transcript.lock().expect("test transcript");
        assert_eq!(items.tail("thread", 100).len(), 2);
        assert!(items
            .tail("thread", 100)
            .iter()
            .all(|item| item.text == "partial 中文" && item.turn_id == "turn"));
    }
    buffer_item(&transcript, &Inbound {
        method: "item/completed".into(),
        params: Some(json!({"threadId": "thread", "turnId": "turn", "item": {
            "id": "message", "type": "agentMessage", "text": "partial 中文 completed"
        }})),
        request_id: None,
    });
    let items = transcript.lock().expect("test transcript");
    assert_eq!(items.tail("thread", 100)[0].text, "partial 中文 completed");
    assert_eq!(items.tail("thread", 100).len(), 2);
}

#[test]
fn buffers_synthesized_plan_item_for_resume() {
    // A `turn/plan/updated` notification (params.plan, no params.item) must be
    // buffered as a `plan` item so a resumed thread restores the plan card at
    // the tail. Otherwise the card is lost on re-open and the proposal message
    // re-reads as a misplaced plan (the plan-jumps-earlier-on-switch bug).
    let transcript = Mutex::new(LiveTranscript::default());
    let plan = |status: &str| Inbound {
        method: "turn/plan/updated".into(),
        params: Some(json!({
            "threadId": "t1",
            "turnId": "turn-9",
            "plan": [{"step": "do the thing", "status": status}],
        })),
        request_id: None,
    };
    buffer_item(&transcript, &plan("pending"));
    // A later snapshot of the same turn's plan upserts in place — one card.
    buffer_item(&transcript, &plan("completed"));
    {
        let items = transcript.lock().unwrap();
        let t1 = items.tail("t1", 100);
        assert_eq!(t1.len(), 1, "plan updates upsert into a single item");
        assert_eq!(t1[0].item_type, "plan");
        assert_eq!(t1[0].id, "plan-turn-9");
        assert!(t1[0].text.contains("[x] do the thing"), "latest snapshot wins");
    }
    // The buffered id matches what map_event synthesizes live, so a resumed
    // thread reconciles the two by id (no duplicate plan card).
    let ev = map_event(plan("completed"));
    assert_eq!(ev.item_id.as_deref(), Some("plan-turn-9"));
    assert_eq!(ev.item_type.as_deref(), Some("plan"));
}

#[test]
fn builds_turn_input_from_text_and_images() {
    // Text-only: the single text item, exactly as before images existed.
    let v = build_turn_input("hi", &[]).expect("text only");
    assert_eq!(v, json!([{ "type": "text", "text": "hi" }]));

    // Text + images: text leads, each image follows as a v2 `image` item
    // whose `url` carries the data URL (works local AND tunneled-remote).
    let img = "data:image/jpeg;base64,AAAA".to_string();
    let v = build_turn_input("look", std::slice::from_ref(&img)).expect("text+image");
    assert_eq!(
        v,
        json!([
            { "type": "text", "text": "look" },
            { "type": "image", "url": img },
        ])
    );

    // Image-only: a legal turn (no empty text item is emitted).
    let v = build_turn_input("", std::slice::from_ref(&img)).expect("image only");
    assert_eq!(v, json!([{ "type": "image", "url": img }]));

    // A non-data URL is refused: a host filesystem path would silently
    // resolve on the wrong machine for a tunneled remote app-server.
    assert!(build_turn_input("x", &["C:/pic.png".to_string()]).is_err());
    // Fully empty input is refused.
    assert!(build_turn_input("", &[]).is_err());
}

#[test]
fn extracts_user_message_images() {
    // thread/read echoes a user message's full content array; `image`
    // items carry the renderable url, `localImage` only a host path.
    let item = json!({"type":"userMessage","id":"u1","content":[
        {"type":"text","text":"see: "},
        {"type":"image","url":"data:image/png;base64,BBBB"},
        {"type":"localImage","path":"/home/u/shot.png"},
    ]});
    let (ty, _, text) = summarize_item(&item);
    assert_eq!(ty, "userMessage");
    assert_eq!(text, "see: ");
    assert_eq!(item_images(&item), vec![
        "data:image/png;base64,BBBB".to_string(),
        "/home/u/shot.png".to_string()
    ]);
    let parsed = parse_item(&item).expect("parses");
    assert_eq!(parsed.images.len(), 2);

    // Image-only user message: empty text, images intact.
    let item = json!({"type":"userMessage","id":"u2","content":[
        {"type":"image","url":"data:image/jpeg;base64,CCCC"},
    ]});
    let parsed = parse_item(&item).expect("parses");
    assert_eq!(parsed.text, "");
    assert_eq!(parsed.images, vec!["data:image/jpeg;base64,CCCC".to_string()]);

    // Non-userMessage items never report images.
    let cmd = json!({"type":"commandExecution","id":"c1","command":"ls"});
    assert!(item_images(&cmd).is_empty());
}

#[test]
fn maps_user_message_event_images() {
    let inbound = Inbound {
        method: "item/completed".into(),
        params: Some(json!({"threadId":"t1","item":{
        "type":"userMessage","id":"u1","content":[
            {"type":"text","text":"hi"},
            {"type":"image","url":"data:image/png;base64,DDDD"},
        ]}})),
        request_id: None,
    };
    let ev = map_event(inbound);
    assert_eq!(ev.item_type.as_deref(), Some("userMessage"));
    assert_eq!(ev.images, vec!["data:image/png;base64,DDDD".to_string()]);
}

#[test]
fn summarizes_tool_items() {
    let cmd = json!({"type":"commandExecution","id":"c1","command":"ls -la",
        "aggregatedOutput":"a\nb","exitCode":0});
    let (ty, title, text) = summarize_item(&cmd);
    assert_eq!(ty, "commandExecution");
    assert_eq!(title, "ls -la");
    assert!(text.contains("exit 0"));

    let search = json!({"type":"webSearch","id":"w1","query":"rust tokio"});
    let (ty, title, _) = summarize_item(&search);
    assert_eq!(ty, "webSearch");
    assert_eq!(title, "rust tokio");

    let mcp =
        json!({"type":"mcpToolCall","id":"m1","server":"skills","tool":"run","arguments":{"x":1}});
    let (ty, title, detail) = summarize_item(&mcp);
    assert_eq!(ty, "mcpToolCall");
    assert_eq!(title, "skills.run");
    assert!(detail.contains("\"x\""));

    // A file change with a single path titles itself with that path and
    // adds the file markers app-server omits so the UI can parse the hunks.
    let edit = json!({"type":"fileChange","id":"e1","changes":[
        {"path":"lib/x.dart","kind":{"type":"update","movePath":null},
         "diff":"@@ -1 +1 @@\n-old\n+new\n","status":"completed"}]});
    let (ty, title, detail) = summarize_item(&edit);
    assert_eq!(ty, "fileChange");
    assert_eq!(title, "lib/x.dart");
    assert!(detail.starts_with("--- a/lib/x.dart\n+++ b/lib/x.dart\n@@"));
    assert!(detail.contains("+new"));

    // Multiple changes: title summarises the count; diffs are concatenated.
    let edits = json!({"type":"fileChange","id":"e2","changes":[
        {"path":"a.rs","diff":"@@\n+a\n"},{"path":"b.rs","diff":"@@\n+b\n"}]});
    let (_, title, detail) = summarize_item(&edits);
    assert_eq!(title, "2 files");
    assert!(detail.contains("+a") && detail.contains("+b"));

    // Added/deleted files carry raw contents rather than hunks; synthesize
    // real additions/removals so the same UI renders counts and line colors.
    let contents = json!({"type":"fileChange","id":"e4","changes":[
        {"path":"new.txt","kind":{"type":"add"},"diff":"one\ntwo\n"},
        {"path":"old.txt","kind":{"type":"delete"},"diff":"gone\n"} ]});
    let (_, _, detail) = summarize_item(&contents);
    assert!(detail.contains("--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,2 @@\n+one\n+two"));
    assert!(detail.contains("--- a/old.txt\n+++ /dev/null\n@@ -1,1 +0,0 @@\n-gone"));

    // Already-normalized callers remain byte-for-byte intact.
    let normalized = json!({"type":"fileChange","id":"e5","changes":[{
        "path":"ready.rs","kind":{"type":"update"},
        "diff":"--- a/ready.rs\n+++ b/ready.rs\n@@ -1 +1 @@\n-old\n+new\n"
    }]});
    let (_, _, detail) = summarize_item(&normalized);
    assert_eq!(detail, "--- a/ready.rs\n+++ b/ready.rs\n@@ -1 +1 @@\n-old\n+new\n");

    // No diff present (not-yet-applied): fall back to the path list.
    let pending = json!({"type":"fileChange","id":"e3","changes":[{"path":"c.rs"}]});
    let (_, _, detail) = summarize_item(&pending);
    assert_eq!(detail, "c.rs");

    // A tool item flows through map_event with item_type + title set.
    let ev = map_event(Inbound {
        method: "item/completed".into(),
        params: Some(json!({"threadId":"t1","item":search})),
        request_id: None,
    });
    assert_eq!(ev.item_type.as_deref(), Some("webSearch"));
    assert_eq!(ev.title.as_deref(), Some("rust tokio"));
    assert_eq!(ev.item_id.as_deref(), Some("w1"));
}

#[test]
fn summarizes_extended_activity_items() {
    let collab = json!({
        "type": "collabAgentToolCall",
        "id": "a1",
        "tool": "spawnAgent",
        "status": "completed",
        "prompt": "inspect auth",
        "receiverThreadIds": ["child-1"],
    });
    let (ty, title, detail) = summarize_item(&collab);
    assert_eq!(ty, "collabAgentToolCall");
    assert_eq!(title, "spawnAgent");
    assert!(detail.contains("child-1"));

    let dynamic = json!({
        "type": "dynamicToolCall",
        "id": "d1",
        "namespace": "calendar",
        "tool": "create",
        "arguments": {"day": "Friday"},
        "contentItems": [{"type": "inputText", "text": "created"}],
        "success": true,
    });
    let (_, title, detail) = summarize_item(&dynamic);
    assert_eq!(title, "calendar.create");
    assert!(detail.contains("contentItems"));

    let image = json!({
        "type": "imageGeneration",
        "id": "i1",
        "status": "completed",
        "revisedPrompt": "A blue square",
        "result": "VERY-LARGE-BASE64",
        "savedPath": "/tmp/blue.png",
    });
    let (_, title, detail) = summarize_item(&image);
    assert_eq!(title, "A blue square");
    assert!(detail.contains("blue.png"));
    assert!(!detail.contains("VERY-LARGE-BASE64"));
    let event = map_event(Inbound {
        method: "item/completed".into(),
        params: Some(json!({"threadId": "t1", "turnId": "turn1", "item": image})),
        request_id: None,
    });
    assert_eq!(event.images, ["/tmp/blue.png"]);
    assert!(!event.raw.contains("VERY-LARGE-BASE64"));
    assert!(event.raw.contains("turn1"));

    let hook = json!({
        "type": "hookPrompt",
        "id": "h1",
        "fragments": [{"hookRunId": "run-1", "text": "Check generated files"}],
    });
    let (_, title, detail) = summarize_item(&hook);
    assert_eq!(title, "run-1");
    assert_eq!(detail, "Check generated files");
}

#[test]
fn maps_item_progress_notifications_without_full_snapshots() {
    let notification = |method: &str, params: Value| {
        map_event(Inbound {
            method: method.to_string(),
            params: Some(params),
            request_id: None,
        })
    };

    let command = notification(
        "item/commandExecution/outputDelta",
        json!({"threadId":"t1","itemId":"c1","delta":"building..."}),
    );
    assert_eq!(command.item_type.as_deref(), Some("commandExecution"));
    assert_eq!(command.text.as_deref(), Some("building..."));

    let reasoning = notification(
        "item/reasoning/summaryTextDelta",
        json!({"threadId":"t1","itemId":"r1","delta":"Inspecting"}),
    );
    assert_eq!(reasoning.item_type.as_deref(), Some("reasoning"));
    assert_eq!(reasoning.text.as_deref(), Some("Inspecting"));

    let mcp = notification(
        "item/mcpToolCall/progress",
        json!({"threadId":"t1","itemId":"m1","message":"Fetched 20 records"}),
    );
    assert_eq!(mcp.item_type.as_deref(), Some("mcpToolCall"));
    assert_eq!(mcp.text.as_deref(), Some("Fetched 20 records"));

    let patch = notification(
        "item/fileChange/patchUpdated",
        json!({"threadId":"t1","itemId":"f1","changes":[{
            "path":"src/lib.rs","kind":{"type":"update"},
            "diff":"@@ -1 +1 @@\n-old\n+new\n"
        }]}),
    );
    assert_eq!(patch.item_type.as_deref(), Some("fileChange"));
    assert_eq!(patch.title.as_deref(), Some("src/lib.rs"));
    assert!(patch
        .text
        .as_deref()
        .is_some_and(|text| text.contains("+new")));
}

#[test]
fn tracks_active_turn_per_thread() {
    let turns = Mutex::new(HashMap::new());
    let inbound = |method: &str, params: Value| Inbound {
        method: method.into(),
        params: Some(params),
        request_id: None,
    };
    // turn/started records the turn id from any of the shapes the server
    // uses (turnId | id | turn.id), preserving its JSON type.
    track_active_turn(&turns, &inbound("turn/started", json!({"threadId":"t1","turnId":"turn-9"})));
    track_active_turn(&turns, &inbound("turn/started", json!({"threadId":"t2","id":"turn-7"})));
    track_active_turn(
        &turns,
        &inbound("turn/started", json!({"threadId":"t3","turn":{"id":"turn-3"}})),
    );
    track_active_turn(&turns, &inbound("turn/started", json!({"threadId":"t4","turnId":42})));
    assert_eq!(turns.lock().unwrap().get("t1"), Some(&json!("turn-9")));
    assert_eq!(turns.lock().unwrap().get("t2"), Some(&json!("turn-7")));
    assert_eq!(turns.lock().unwrap().get("t3"), Some(&json!("turn-3")));
    assert_eq!(turns.lock().unwrap().get("t4"), Some(&json!(42)));
    // Unrelated events don't touch the map.
    track_active_turn(&turns, &inbound("item/completed", json!({"threadId":"t1","item":{}})));
    assert_eq!(turns.lock().unwrap().get("t1"), Some(&json!("turn-9")));
    // Completion / failure clears the entry for that thread only.
    track_active_turn(&turns, &inbound("turn/completed", json!({"threadId":"t1"})));
    assert!(!turns.lock().unwrap().contains_key("t1"));
    assert_eq!(turns.lock().unwrap().get("t2"), Some(&json!("turn-7")));
    track_active_turn(&turns, &inbound("turn/failed", json!({"threadId":"t2"})));
    assert!(!turns.lock().unwrap().contains_key("t2"));
    // Other threads remain tracked.
    assert_eq!(turns.lock().unwrap().get("t3"), Some(&json!("turn-3")));
    assert_eq!(turns.lock().unwrap().get("t4"), Some(&json!(42)));
}

#[test]
fn parses_runtime_config_from_a_start_or_resume_response() {
    let res = json!({
        "thread": {"id": "t1"},
        "model": "gpt-5.5-codex",
        "modelProvider": "openai",
        "reasoningEffort": "high",
        "approvalPolicy": "on-request",
        "sandbox": {"type": "workspaceWrite", "networkAccess": false},
    });
    let cfg = runtime_config_from_response(&res);
    assert_eq!(cfg.model.as_deref(), Some("gpt-5.5-codex"));
    assert_eq!(cfg.model_provider.as_deref(), Some("openai"));
    assert_eq!(cfg.reasoning_effort.as_deref(), Some("high"));
    assert_eq!(cfg.approval_policy.as_deref(), Some("on-request"));
    assert_eq!(cfg.sandbox_mode.as_deref(), Some("workspace-write"));
    assert_eq!(cfg.collaboration_mode, None);
    assert!(!cfg.confirmed_by_update);
    // Absent / null fields stay None (older servers say less; never guess).
    let sparse =
        runtime_config_from_response(&json!({"thread": {"id": "t"}, "reasoningEffort": null}));
    assert_eq!(sparse, ThreadRuntimeConfig::default());
}

#[test]
fn tracks_runtime_config_from_settings_updates() {
    let configs = Mutex::new(HashMap::new());
    track_runtime_config(&configs, &Inbound {
        method: "thread/settings/updated".into(),
        params: Some(json!({
            "threadId": "t1",
            "threadSettings": {
                "model": "gpt-5.5",
                "modelProvider": "openai",
                "effort": "xhigh",
                "approvalPolicy": "never",
                "sandboxPolicy": {"type": "dangerFullAccess"},
                "collaborationMode": {"mode": "plan", "settings": {"model": "gpt-5.5"}},
            },
        })),
        request_id: None,
    });
    let cfg = configs.lock().unwrap().get("t1").cloned().expect("tracked");
    assert_eq!(cfg.model.as_deref(), Some("gpt-5.5"));
    assert_eq!(cfg.reasoning_effort.as_deref(), Some("xhigh"));
    assert_eq!(cfg.approval_policy.as_deref(), Some("never"));
    assert_eq!(cfg.sandbox_mode.as_deref(), Some("danger-full-access"));
    assert_eq!(cfg.collaboration_mode.as_deref(), Some("plan"));
    assert!(cfg.confirmed_by_update);
    // Unrelated notifications don't touch the map.
    track_runtime_config(&configs, &Inbound {
        method: "turn/started".into(),
        params: Some(json!({"threadId": "t1", "turnId": "x"})),
        request_id: None,
    });
    assert!(configs.lock().unwrap().contains_key("t1"));
}

#[test]
fn approval_and_sandbox_parsers_tolerate_wire_variants() {
    // Approval: plain strings pass through; the externally-tagged granular
    // object maps to its tag.
    assert_eq!(parse_approval_policy(Some(&json!("on-request"))).as_deref(), Some("on-request"));
    assert_eq!(
        parse_approval_policy(Some(&json!({"granular": {"rules": true}}))).as_deref(),
        Some("granular")
    );
    assert_eq!(parse_approval_policy(Some(&json!(""))), None);
    assert_eq!(parse_approval_policy(None), None);
    // Legacy `on-failure` is migrated to `on-request` before it reaches the
    // app-server (codex removed the variant); other values pass through.
    assert_eq!(normalize_approval_policy("on-failure"), "on-request");
    assert_eq!(normalize_approval_policy("on-request"), "on-request");
    assert_eq!(normalize_approval_policy("untrusted"), "untrusted");
    assert_eq!(normalize_approval_policy("granular"), "granular");
    assert_eq!(normalize_approval_policy("never"), "never");
    // Sandbox: v2 camelCase tags normalize to the kebab strings the UI
    // speaks; bare/kebab strings and unknown tags pass through.
    assert_eq!(
        parse_sandbox_mode(Some(&json!({"type": "readOnly"}))).as_deref(),
        Some("read-only")
    );
    assert_eq!(
        parse_sandbox_mode(Some(&json!({"type": "workspaceWrite", "writableRoots": []})))
            .as_deref(),
        Some("workspace-write")
    );
    assert_eq!(
        parse_sandbox_mode(Some(&json!("danger-full-access"))).as_deref(),
        Some("danger-full-access")
    );
    assert_eq!(
        parse_sandbox_mode(Some(&json!({"type": "futureMode"}))).as_deref(),
        Some("futureMode")
    );
    assert_eq!(parse_sandbox_mode(Some(&json!({}))), None);
    // Collaboration mode: `{mode}` object or bare string.
    assert_eq!(parse_collaboration_mode(Some(&json!({"mode": "plan"}))).as_deref(), Some("plan"));
    assert_eq!(parse_collaboration_mode(Some(&json!("default"))).as_deref(), Some("default"));
    assert_eq!(parse_collaboration_mode(Some(&json!({}))), None);
}

#[test]
fn extracts_turn_failed_error_and_request_id() {
    let failed = map_event(Inbound {
        method: "turn/failed".into(),
        params: Some(json!({"threadId":"t1","error":{"message":"model overloaded"}})),
        request_id: None,
    });
    assert_eq!(failed.text.as_deref(), Some("model overloaded"));

    let approval = map_event(Inbound {
        method: "execCommandApproval".into(),
        params: Some(json!({"approvalId":"a1","command":["ls"]})),
        request_id: Some("7".into()),
    });
    assert_eq!(approval.request_id.as_deref(), Some("7"));
}

#[test]
fn tracks_only_permissions_approval_requests() {
    let pending = Mutex::new(HashMap::new());
    // A permissions request caches its requested grant under the request id.
    track_pending_approval(&pending, &Inbound {
        method: "item/permissions/requestApproval".into(),
        params: Some(json!({"permissions":{"network":{"enabled":true}}})),
        request_id: Some("11".into()),
    });
    assert_eq!(pending.lock().unwrap().get("11"), Some(&json!({"network":{"enabled":true}})));
    // Command / file-change approvals and plain notifications are ignored —
    // they answer with a plain {decision}, no cached grant needed.
    track_pending_approval(&pending, &Inbound {
        method: "item/commandExecution/requestApproval".into(),
        params: Some(json!({"command":"ls"})),
        request_id: Some("12".into()),
    });
    assert!(!pending.lock().unwrap().contains_key("12"));
}

#[test]
fn permissions_response_echoes_grant_with_scope() {
    let grant = json!({"network":{"enabled":true},"fileSystem":{"read":["/x"]}});
    // Accept → echo the requested grant, turn scope.
    assert_eq!(
        approval_result(Some(grant.clone()), "accept"),
        json!({"permissions": grant, "scope": "turn"})
    );
    // Accept for session → same grant, session scope.
    assert_eq!(
        approval_result(Some(grant.clone()), "acceptForSession"),
        json!({"permissions": grant, "scope": "session"})
    );
    // Decline → grant nothing (empty profile), turn scope.
    assert_eq!(
        approval_result(Some(grant), "decline"),
        json!({"permissions": {}, "scope": "turn"})
    );
}

#[test]
fn non_permissions_response_is_a_plain_decision() {
    // No cached grant ⇒ command / file-change approval ⇒ {decision}.
    assert_eq!(approval_result(None, "accept"), json!({"decision": "accept"}));
    assert_eq!(approval_result(None, "decline"), json!({"decision": "decline"}));
}

#[test]
fn parses_supported_reasoning_efforts() {
    // Real protocol shape: array of {reasoningEffort, description} objects.
    let model = json!({"supportedReasoningEfforts": [
        {"reasoningEffort": "low", "description": "fast"},
        {"reasoningEffort": "high", "description": "thorough"},
    ]});
    assert_eq!(parse_supported_efforts(&model), vec!["low", "high"]);
    // Legacy bare-string shape still parses (backward compatibility).
    let legacy = json!({"supportedReasoningEfforts": ["minimal", "xhigh"]});
    assert_eq!(parse_supported_efforts(&legacy), vec!["minimal", "xhigh"]);
    // Absent / empty → empty (the UI reads that as "offer all levels").
    assert!(parse_supported_efforts(&json!({})).is_empty());
}

#[test]
fn parses_thread_meta_and_skips_idless_entries() {
    let t = json!({"id":"t1","preview":"hi","cwd":"/repo","updatedAt":42});
    let meta = parse_thread_meta(&t).expect("entry has an id");
    assert_eq!(meta.id, "t1");
    assert_eq!(meta.preview, "hi");
    assert_eq!(meta.cwd, "/repo");
    assert_eq!(meta.updated_at, 42);
    // An entry with no id is skipped (filter_map drops it).
    assert!(parse_thread_meta(&json!({"preview":"x"})).is_none());
}

#[test]
fn parses_user_and_agent_items() {
    let user =
        json!({"type":"userMessage","id":"u1","content":[{"type":"text","text":"hi there"}]});
    let agent = json!({"type":"agentMessage","id":"a1","text":"hello"});
    assert_eq!(parse_item(&user).unwrap().item_type, "userMessage");
    assert_eq!(parse_item(&user).unwrap().text, "hi there");
    assert_eq!(parse_item(&agent).unwrap().item_type, "agentMessage");
    assert_eq!(parse_item(&agent).unwrap().text, "hello");
}

#[test]
fn items_inherit_their_turns_id_and_timing() {
    // `thread/read` nests items under their turn, and ONLY the turn carries
    // timing (`ThreadItem` has no time field in the protocol). Flattening
    // for the UI must therefore stamp each item, or the turn boundary and
    // every timestamp are lost — which is what forced the UI to re-infer
    // turns from item adjacency and to invent its own clock.
    let turn = json!({
        "id": "turn-7",
        "completedAt": 1_770_000_000_i64,
        "durationMs": 4_200_i64,
        "items": [{"type":"agentMessage","id":"a1","text":"part one"}],
    });
    let stamp = TurnStamp::of(&turn);
    let item = &turn["items"][0];
    let parsed = parse_turn_item(item, &stamp).expect("parses");
    assert_eq!(parsed.turn_id, "turn-7");
    assert_eq!(parsed.turn_completed_at, Some(1_770_000_000));
    assert_eq!(parsed.turn_duration_ms, Some(4_200));

    // A turn still running reports no completion time, and the UI has to be
    // able to tell that apart from "completed at epoch".
    let running = json!({"id":"turn-8","items":[]});
    let stamp = TurnStamp::of(&running);
    assert_eq!(stamp.id, "turn-8");
    assert_eq!(stamp.completed_at, None);
    assert_eq!(stamp.duration_ms, None);
}
