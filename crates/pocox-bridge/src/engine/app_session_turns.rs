//! Starting, steering and interrupting turns, answering approval and input
//! requests, and other per-thread requests.

use super::*;

/// Record the active `turnId` for `thread_id` on `service_key` (no-op if the
/// session is gone). Lets [`thread_read`] seed the turn id on a cold open.
pub(super) fn record_active_turn(service_key: &str, thread_id: &str, turn_id: Value) {
    if let Some(s) = sessions()
        .lock()
        .expect("sessions poisoned")
        .get(service_key)
    {
        s.active_turns
            .lock()
            .expect("active_turns poisoned")
            .insert(thread_id.to_string(), turn_id);
    }
}

/// Start a new thread with optional model / working dir / approval policy /
/// sandbox mode. `approval_policy` and `sandbox` are the wire strings
/// (`untrusted`/`on-failure`/`on-request`/`never` and
/// `read-only`/`workspace-write`/`danger-full-access`). Returns the thread id.
pub fn thread_start(
    service_key: &str,
    model: Option<String>,
    cwd: Option<String>,
    approval_policy: Option<String>,
    approvals_reviewer: Option<String>,
    service_tier: Option<String>,
    sandbox: Option<String>,
) -> Result<String> {
    let client = client_for(service_key)?;
    let mut params = serde_json::Map::new();
    insert_execution_options(&mut params, approvals_reviewer, service_tier)?;
    if let Some(m) = model {
        params.insert("model".into(), json!(m));
    }
    if let Some(c) = cwd.filter(|c| !c.trim().is_empty()) {
        params.insert("cwd".into(), json!(c));
    }
    if let Some(a) = approval_policy {
        params.insert("approvalPolicy".into(), json!(normalize_approval_policy(&a)));
    }
    if let Some(s) = sandbox {
        params.insert("sandbox".into(), json!(s));
    }
    let res = runtime::runtime().block_on(client.request("thread/start", Value::Object(params)))?;
    let thread_id = res
        .get("thread")
        .and_then(|t| t.get("id"))
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| anyhow!("thread/start: missing thread id in response"))?;
    // The response reports the effective model / effort / permissions the new
    // thread actually starts with — cache it so the UI can show server truth
    // from the very first turn.
    record_runtime_config(service_key, &thread_id, &res);
    Ok(thread_id)
}

/// Answer a server approval request (token from an [`AppEvent::request_id`]).
///
/// `decision` is the wire value the UI sends: `accept` / `acceptForSession` /
/// `decline`. Command-execution and file-change approvals take a plain
/// `{decision}` ([`CommandExecutionApprovalDecision`] / [`FileChangeApproval`-
/// `Decision`]). A `item/permissions/requestApproval` is different: it expects
/// a `PermissionsRequestApprovalResponse` (`{permissions, scope}`) — we echo
/// the requested grant on accept (scope `turn`, or `session` for
/// `acceptForSession`) and grant nothing on decline. Sending `{decision}` there
/// fails upstream deserialization and silently grants no permissions, so branch
/// on whether the request was a tracked permissions prompt.
pub fn respond_approval(service_key: &str, request_id: &str, decision: &str) -> Result<()> {
    let (client, pending) = {
        let map = sessions().lock().expect("sessions poisoned");
        let session = map
            .get(service_key)
            .ok_or_else(|| anyhow!("not connected to {service_key}"))?;
        let pending = session
            .pending_approvals
            .lock()
            .expect("pending_approvals poisoned")
            .remove(request_id);
        (Arc::clone(&session.client), pending)
    };
    let result = approval_result(pending, decision);
    runtime::runtime().block_on(client.respond(request_id, result))?;
    Ok(())
}

/// Answer an `item/tool/requestUserInput` elicitation (the model asking the
/// user structured questions — distinct from a command/file approval).
/// `answers_json` is a JSON object mapping each question id to the list of
/// chosen answer strings (option labels and/or free-text), e.g.
/// `{"theme":["山水抒怀"],"style":["雅正含蓄"]}`. An empty object `{}` cancels
/// — the server treats absent answers as "no input" and the turn continues.
/// This sends the protocol's `ToolRequestUserInputResponse` shape
/// `{"answers":{<id>:{"answers":[...]}}}`; sending a plain `{decision}` here
/// (the approval shape) would fail to deserialize upstream and silently drop
/// the user's choice, so this is a dedicated path.
pub fn respond_user_input(service_key: &str, request_id: &str, answers_json: &str) -> Result<()> {
    let client = client_for(service_key)?;
    // Parse into the concrete shape so a malformed value (anything that isn't a
    // JSON array of strings) is rejected here, rather than passed through to
    // break the upstream deserialize of the whole `ToolRequestUserInputResponse`.
    let by_question: HashMap<String, Vec<String>> = serde_json::from_str(answers_json)
        .map_err(|e| anyhow!("parsing user-input answers `{answers_json}`: {e}"))?;
    let mut answers = serde_json::Map::new();
    for (qid, list) in by_question {
        answers.insert(qid, json!({ "answers": list }));
    }
    runtime::runtime().block_on(client.respond(request_id, json!({ "answers": answers })))?;
    Ok(())
}

/// Build the JSON-RPC result for an approval response. `pending` is the cached
/// requested `permissions` when this was a `item/permissions/requestApproval`
/// (`None` for command / file-change approvals, which just carry the decision).
pub(super) fn approval_result(pending: Option<Value>, decision: &str) -> Value {
    match pending {
        Some(permissions) => {
            // Permissions prompt → PermissionsRequestApprovalResponse. Echo the
            // requested grant on accept; an empty grant ({}) means "denied".
            let (granted, scope) = match decision {
                "accept" => (permissions, "turn"),
                "acceptForSession" => (permissions, "session"),
                _ => (json!({}), "turn"),
            };
            json!({ "permissions": granted, "scope": scope })
        },
        // Command / file-change approval → plain decision.
        None => json!({ "decision": decision }),
    }
}

/// Cache the requested `permissions` of a permissions approval request, keyed
/// by its `request_id`, so [`respond_approval`] can answer with the protocol's
/// `PermissionsRequestApprovalResponse` instead of a plain `{decision}`. Other
/// inbound messages (notifications, command/file approvals) are ignored.
pub(super) fn track_pending_approval(pending: &Mutex<HashMap<String, Value>>, inbound: &Inbound) {
    if inbound.method != "item/permissions/requestApproval" {
        return;
    }
    let (Some(request_id), Some(params)) = (inbound.request_id.as_deref(), inbound.params.as_ref())
    else {
        return;
    };
    let permissions = params
        .get("permissions")
        .cloned()
        .unwrap_or_else(|| json!({}));
    pending
        .lock()
        .expect("pending_approvals poisoned")
        .insert(request_id.to_string(), permissions);
}

/// Unified diff of the repo at `cwd` vs its remote default branch
/// (`gitDiffToRemote`). Returns the diff text, or an empty string when the cwd
/// isn't a git repo / there are no changes.
pub fn git_diff(service_key: &str, cwd: &str) -> Result<String> {
    let client = client_for(service_key)?;
    let res =
        runtime::runtime().block_on(client.request("gitDiffToRemote", json!({ "cwd": cwd })))?;
    // The diff string lives under `diff`; also accept a bare string response.
    if let Some(s) = res.as_str() {
        return Ok(s.to_string());
    }
    Ok(res
        .get("diff")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string())
}

/// Start a manual conversation compaction (`thread/compact/start`). The server
/// emits `thread/compacted` when done; the UI reloads history on that event.
pub fn compact(service_key: &str, thread_id: &str) -> Result<()> {
    let client = client_for(service_key)?;
    runtime::runtime()
        .block_on(client.request("thread/compact/start", json!({ "threadId": thread_id })))?;
    Ok(())
}

/// Set a thread's user-facing title. The server persists it and echoes
/// `thread/name/updated`; an empty `name` clears it back to the preview.
pub fn set_thread_name(service_key: &str, thread_id: &str, name: &str) -> Result<()> {
    let client = client_for(service_key)?;
    runtime::runtime().block_on(
        client.request("thread/name/set", json!({ "threadId": thread_id, "name": name })),
    )?;
    Ok(())
}

/// Forward a realtime control request over the existing initialized connection.
/// Audio media uses client-owned WebRTC; only signaling crosses the bridge.
pub fn realtime_request(service_key: &str, method: &str, params_json: &str) -> Result<String> {
    let params: Value = serde_json::from_str(params_json)?;
    validate_realtime_request(method, &params)?;
    let client = client_for(service_key)?;
    let res = runtime::runtime().block_on(client.request(method, params))?;
    if method == "thread/start" {
        if let Some(id) = res.pointer("/thread/id").and_then(Value::as_str) {
            record_runtime_config(service_key, id, &res);
        }
    }
    Ok(res.to_string())
}

pub(super) fn validate_realtime_request(method: &str, params: &Value) -> Result<()> {
    anyhow::ensure!(params.is_object(), "realtime params must be an object");
    match method {
        "thread/timeline/list"
        | "thread/realtime/start"
        | "thread/realtime/stop"
        | "thread/realtime/appendAudio"
        | "thread/realtime/appendText"
        | "thread/realtime/appendSpeech" => {
            anyhow::ensure!(
                params
                    .get("threadId")
                    .and_then(Value::as_str)
                    .is_some_and(|id| !id.is_empty()),
                "realtime request requires threadId"
            );
        },
        "thread/realtime/listVoices" => {},
        "thread/start" => match params.get("threadSource").and_then(Value::as_str) {
            Some("pocox-voice") => {},
            // The composer's dictation line: a realtime session that only
            // transcribes. It must never become a conversation of its own, so
            // only an ephemeral thread (no rollout, not listed) is allowed.
            Some("pocox-dictation") => anyhow::ensure!(
                params.get("ephemeral").and_then(Value::as_bool) == Some(true),
                "dictation thread must be ephemeral"
            ),
            _ => anyhow::bail!("voice thread requires its source marker"),
        },
        // Lets the dictation line release its ephemeral thread on close.
        "thread/unsubscribe" => {
            anyhow::ensure!(
                params
                    .get("threadId")
                    .and_then(Value::as_str)
                    .is_some_and(|id| !id.is_empty()),
                "unsubscribe requires threadId"
            );
        },
        _ => anyhow::bail!("unsupported realtime method: {method}"),
    }
    Ok(())
}

/// Build a `turn/start` `input` array from message text plus attached images.
/// The text (when non-empty) leads as a `text` item; each image follows as an
/// `image` item whose `url` must be a `data:image/...` base64 URL — the only
/// form that works for BOTH local and relay-tunneled remote app-servers (a
/// `localImage` path would resolve on the host's filesystem, which the
/// controlling device can't reach). At least one item must result.
pub(super) fn build_turn_input(text: &str, images: &[String]) -> Result<Value> {
    let mut input: Vec<Value> = Vec::with_capacity(images.len() + 1);
    if !text.is_empty() {
        input.push(json!({ "type": "text", "text": text }));
    }
    for url in images {
        if !url.starts_with("data:image/") {
            bail!("attached image must be a data:image/... URL (got `{}…`)", truncate(url, 32));
        }
        input.push(json!({ "type": "image", "url": url }));
    }
    if input.is_empty() {
        bail!("a turn needs text or at least one image");
    }
    Ok(Value::Array(input))
}

/// First `n` chars of `s` (for error messages; never splits a char).
fn truncate(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}

/// Send a user message (text and/or attached images), starting a model turn.
/// `model`, `approval_policy` and `sandbox` are optional per-turn overrides
/// (they apply to this turn *and subsequent turns*, so the UI can switch
/// model / permission mid-conversation). `images` are `data:image/...` URLs
/// (see [`build_turn_input`]). The reply streams back as events; this returns
/// once the turn is accepted.
#[allow(clippy::too_many_arguments)]
pub fn turn_start(
    service_key: &str,
    thread_id: &str,
    text: String,
    images: Vec<String>,
    model: Option<String>,
    approval_policy: Option<String>,
    approvals_reviewer: Option<String>,
    service_tier: Option<String>,
    sandbox: Option<String>,
    collaboration_mode: Option<String>,
    reasoning_effort: Option<String>,
) -> Result<()> {
    let client = client_for(service_key)?;
    let mut params = serde_json::Map::new();
    insert_execution_options(&mut params, approvals_reviewer, service_tier)?;
    params.insert("threadId".into(), json!(thread_id));
    params.insert("input".into(), build_turn_input(&text, &images)?);
    if let Some(m) = &model {
        params.insert("model".into(), json!(m));
    }
    // Reasoning effort ("thinking level") as the top-level `effort` field. This
    // applies when no collaborationMode is sent (the common case), letting the
    // user dial effort without selecting a concrete model. NOTE: the server
    // ignores this field when a collaborationMode IS sent and reads effort from
    // collaborationMode.settings.reasoning_effort instead — so the caller passes
    // the *effective* effort (current value re-asserted), and we mirror it into
    // the settings block below, ensuring a plan/permission turn never wipes it.
    // Values are the lowercase `ReasoningEffort` names (`low`/`medium`/`high`).
    if let Some(eff) = reasoning_effort.as_deref().filter(|e| !e.is_empty()) {
        params.insert("effort".into(), json!(eff));
    }
    if let Some(a) = approval_policy {
        params.insert("approvalPolicy".into(), json!(normalize_approval_policy(&a)));
    }
    // turn/start takes a structured `sandboxPolicy` (vs thread/start's plain
    // `sandbox` string); map the preset's mode to the tagged object.
    if let Some(p) = sandbox.and_then(|s| sandbox_policy(&s)) {
        params.insert("sandboxPolicy".into(), p);
    }
    // Collaboration mode ("plan" / "default") is sticky on the thread: once a
    // turn sets "plan", later turns stay in plan mode until one explicitly sends
    // "default". So the UI passes "default" to leave plan mode (implement the
    // plan), not just omits it. Either mode requires a concrete model in its
    // settings, so it's only sent when a model id is available.
    if let Some(mode) = collaboration_mode {
        if let Some(m) = model.filter(|m| !m.is_empty()) {
            params.insert(
                "collaborationMode".into(),
                json!({
                    "mode": mode,
                    "settings": {
                        "model": m,
                        "reasoning_effort": reasoning_effort,
                        "developer_instructions": null,
                    },
                }),
            );
        }
    }
    runtime::runtime().block_on(client.request("turn/start", Value::Object(params)))?;
    Ok(())
}

/// Deliver an asynchronous answer to the expected running turn.
/// A stale turn id is reported to the caller instead of starting another turn.
pub fn turn_steer(
    service_key: &str,
    thread_id: &str,
    turn_id: Option<&str>,
    text: &str,
    images: &[String],
) -> Result<String> {
    let (client, expected_turn) = {
        let map = sessions().lock().unwrap_or_else(|e| e.into_inner());
        let session = map
            .get(service_key)
            .ok_or_else(|| anyhow!("not connected to {service_key}"))?;
        let tracked = session
            .active_turns
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(thread_id)
            .cloned();
        (Arc::clone(&session.client), turn_id.map(Value::from).or(tracked))
    };
    let expected_turn = expected_turn
        .and_then(|value| value.as_str().map(str::to_owned))
        .context("the active turn is not available; reload the thread")?;
    runtime::runtime().block_on(client.request(
        "turn/steer",
        json!({
            "threadId": thread_id,
            "expectedTurnId": expected_turn,
            "input": build_turn_input(text, images)?,
        }),
    ))?;
    Ok(expected_turn)
}

/// Map a kebab sandbox mode to a `turn/start` `sandboxPolicy` tagged object.
fn sandbox_policy(mode: &str) -> Option<Value> {
    match mode {
        "read-only" => Some(json!({ "type": "readOnly" })),
        "workspace-write" => Some(json!({ "type": "workspaceWrite" })),
        "danger-full-access" => Some(json!({ "type": "dangerFullAccess" })),
        _ => None,
    }
}

/// Pull the turn id out of an object, tolerating the shapes the codex server
/// uses: `turnId` or `id` at the top level, or a nested `turn.id`. Mirrors the
/// UI's `_parseTurnId`. Preserves the JSON type (string or number) so it's
/// re-sent as-is.
pub(super) fn extract_turn_id(obj: &Value) -> Option<Value> {
    let pick = |v: Option<&Value>| match v {
        Some(s @ Value::String(t)) if !t.is_empty() => Some(s.clone()),
        Some(n @ Value::Number(_)) => Some(n.clone()),
        _ => None,
    };
    pick(obj.get("turnId"))
        .or_else(|| pick(obj.get("id")))
        .or_else(|| pick(obj.get("turn").and_then(|t| t.get("id"))))
}

/// Update the per-thread active-turn map from a live notification: remember the
/// turn id on `turn/started`, forget it on `turn/completed` / `turn/failed`.
pub(super) fn track_active_turn(turns: &Mutex<HashMap<String, Value>>, inbound: &Inbound) {
    let Some(params) = inbound.params.as_ref() else {
        return;
    };
    let Some(thread_id) = params.get("threadId").and_then(Value::as_str) else {
        return;
    };
    match inbound.method.as_str() {
        "turn/started" => {
            if let Some(turn_id) = extract_turn_id(params) {
                turns
                    .lock()
                    .expect("active_turns poisoned")
                    .insert(thread_id.to_string(), turn_id);
            }
        },
        "turn/completed" | "turn/failed" => {
            turns
                .lock()
                .expect("active_turns poisoned")
                .remove(thread_id);
        },
        _ => {},
    }
}

/// Interrupt the running turn. `turn/interrupt` requires the `turnId`; the UI
/// passes the one it captured from `turn/started` when it has it, but falls
/// back to the engine-tracked turnId (see [`Session::active_turns`]) so
/// stopping works for a thread that was already running when its screen opened,
/// or after switching sessions. `threadId` alone is rejected by the server.
pub fn turn_interrupt(service_key: &str, thread_id: &str, turn_id: Option<String>) -> Result<()> {
    let (client, tracked) = {
        let map = sessions().lock().expect("sessions poisoned");
        let s = map
            .get(service_key)
            .ok_or_else(|| anyhow!("not connected to {service_key}"))?;
        let tracked = s
            .active_turns
            .lock()
            .expect("active_turns poisoned")
            .get(thread_id)
            .cloned();
        (Arc::clone(&s.client), tracked)
    };
    // Prefer the UI-supplied turnId; otherwise use the engine-tracked one.
    let turn_id_value = turn_id
        .filter(|t| !t.is_empty())
        .map(Value::from)
        .or(tracked);
    let mut params = serde_json::Map::new();
    params.insert("threadId".into(), json!(thread_id));
    if let Some(t) = turn_id_value {
        params.insert("turnId".into(), t);
    }
    runtime::runtime().block_on(client.request("turn/interrupt", Value::Object(params)))?;
    Ok(())
}
