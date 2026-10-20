//! A scripted ACP v1 agent for tests. It is a Cargo example, so it is built
//! by `cargo test` but never installed or packaged.
//!
//! Flags select one of three deliberately different capability sets:
//! `--profile alpha` (core only), `--profile beta` (load, list, resume,
//! close, images, config options and modes) and `--profile gamma` (list and
//! resume, no load). Other flags:
//!
//! - `--version N` answers `initialize` with another protocol version;
//! - `--auth-required` refuses `session/new`, `--auth-prompt` refuses
//!   `session/prompt`, both with ACP `auth_required`;
//! - `--list-cwd PATH` lists the earlier session under `PATH`;
//! - `--open-delay-ms N` delays the `session/load` / `session/resume` answer,
//!   and `--fail-open` then fails it;
//! - `--init-delay-ms N` delays the `initialize` answer;
//! - `--close-delay-ms N` delays close; `--fail-close` rejects it;
//! - `--pid-file PATH` writes the agent's process id to `PATH` at start;
//! - `--clear-title` makes `session/load` clear the title (`title: null`)
//!   instead of naming the session;
//! - `--steering MODE` advertises the `_session/steering` extension in the
//!   top-level `_meta`: `ok` injects into a running prompt (and streams
//!   `steered:<text>`) or answers `promptRequired` when none runs, `odd`
//!   answers `startedNewTurn`, `silent` never answers.
//! - `--grok` speaks like Grok Build 1.0.62 (`_meta.grokShell`): its queue
//!   names the running `_meta.promptId`, every turn ends with `turn_completed`,
//!   `_x.ai/interject` streams ` still` and, in the next model response,
//!   `interjected:<text>` into a running prompt or runs the text as a turn of
//!   its own (`interject-fallback-1`, streaming `fallback:<text>`) when idle,
//!   updates carry `_meta.totalTokens` and the model response's
//!   `_meta.streamStartMs`, `_x.ai/session/rename` succeeds, `_x.ai/billing`
//!   reports a weekly window, and the prompts `ask` and `plan` send
//!   `_x.ai/ask_user_question` / `_x.ai/exit_plan_mode` and report the answer
//!   (`asked:<json>` / `plan:<outcome>`); `perm` reports the permission mode
//!   (`perm:<mode>`, from `session/new` `_meta` or `_x.ai/yolo_mode_changed`);
//!   `chain` names its next prompt before answering; `strand` ends at once and
//!   then runs `interject-fallback-2` (`fallback:late`), which asks for a
//!   permission and reports `chosen:<option>`.
//!
//! The agent title echoes the raw argument vector so tests can verify it
//! arrived verbatim.
//!
//! Prompts are scripts: `hello` streams two chunks; `permission` asks for a
//! permission and reports the chosen option; `slow` streams until cancelled
//! and then sends a trailing update; `stream` sends forty chunks over about
//! a second; `flood` sends 5000 chunks at once and then waits for a cancel;
//! `count` reports how many prompts reached the agent; `fs` asks the client
//! to read a file and reports the error code it got; `crash` exits
//! immediately; `orphan` leaves a child holding the output open and exits;
//! `linger` ends by itself after 400 ms whatever happens; `settle` stops
//! accepting steering at once but answers only after 400 ms; `probe` waits
//! 300 ms and reports whether a cancel reached it (`probe:cancelled` /
//! `probe:clean`); `deaf` asks for a permission and then never reads its
//! input again (the process stays alive), so the client's writes stall.

use std::{
    collections::{HashMap, HashSet},
    io::Write,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};

use serde_json::{json, Value};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    sync::{oneshot, Notify},
};

#[derive(Clone)]
struct Agent {
    profile: String,
    args: Vec<String>,
    version: u64,
    auth_required: bool,
    auth_prompt: bool,
    list_cwd: Option<String>,
    open_delay: Duration,
    fail_open: bool,
    close_delay: Duration,
    fail_close: bool,
    init_delay: Duration,
    clear_title: bool,
    steering: Option<String>,
    grok: bool,
    /// Grok's permission mode, as `_meta` and `_x.ai/yolo_mode_changed` set it.
    permission: Arc<Mutex<String>>,
    /// Sessions whose prompt is still unanswered.
    running: Arc<Mutex<HashSet<String>>>,
    next_id: Arc<Mutex<i64>>,
    waiting: Arc<Mutex<HashMap<i64, oneshot::Sender<Value>>>>,
    cancels: Arc<Mutex<HashMap<String, Arc<Notify>>>>,
    sessions: Arc<Mutex<u64>>,
    prompts: Arc<AtomicU64>,
}

fn emit(value: &Value) {
    let mut out = std::io::stdout().lock();
    let _ = serde_json::to_writer(&mut out, value);
    let _ = out.write_all(b"\n");
    let _ = out.flush();
}

fn respond(id: &Value, result: Value) {
    emit(&json!({"jsonrpc": "2.0", "id": id, "result": result}));
}

fn fail(id: &Value, code: i64, message: &str) {
    emit(&json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}));
}

/// The model response the next updates belong to (Grok's
/// `_meta.streamStartMs`).
static STREAM: AtomicU64 = AtomicU64::new(1);

fn update(session: &str, update: Value) {
    let stream = STREAM.load(Ordering::SeqCst);
    emit(&json!({"jsonrpc": "2.0", "method": "session/update",
        "params": {"sessionId": session, "update": update,
            "_meta": {"streamStartMs": stream}}}));
}

fn text(kind: &str, text: &str) -> Value {
    json!({"sessionUpdate": kind, "content": {"type": "text", "text": text}})
}

/// Grok's queue state: `running` is the prompt it runs, if any.
fn queue_changed(session: &str, running: Option<(&str, &str)>) {
    let mut params = json!({"sessionId": session, "entries": []});
    if let Some((prompt, text)) = running {
        params["runningPromptId"] = json!(prompt);
        params["runningText"] = json!(text);
        params["runningKind"] = json!("prompt");
    }
    emit(&json!({"jsonrpc": "2.0", "method": "_x.ai/queue/changed", "params": params}));
}

/// Grok's end of a turn.
fn turn_completed(session: &str, prompt: &str, stop: &str) {
    emit(&json!({"jsonrpc": "2.0", "method": "_x.ai/session_notification", "params": {
        "sessionId": session,
        "update": {"sessionUpdate": "turn_completed", "prompt_id": prompt, "stop_reason": stop},
    }}));
}

impl Agent {
    fn has_load(&self) -> bool {
        self.profile == "beta"
    }

    fn has_list_and_resume(&self) -> bool {
        matches!(self.profile.as_str(), "beta" | "gamma")
    }

    async fn call(&self, method: &str, params: Value) -> Value {
        let id = {
            let mut next = self.next_id.lock().expect("lock");
            *next += 1;
            *next
        };
        let (tx, rx) = oneshot::channel();
        self.waiting.lock().expect("lock").insert(id, tx);
        emit(&json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
        rx.await.unwrap_or(Value::Null)
    }

    fn cancel_signal(&self, session: &str) -> Arc<Notify> {
        self.cancels
            .lock()
            .expect("lock")
            .entry(session.to_string())
            .or_insert_with(|| Arc::new(Notify::new()))
            .clone()
    }

    fn settings(&self) -> Value {
        if self.grok {
            return json!({
                "configOptions": [{
                    "id": "model", "name": "Model", "category": "model", "type": "select",
                    "currentValue": "grok-m", "options": [{"value": "grok-m", "name": "Grok M"}],
                }],
                "models": {"currentModelId": "grok-m", "availableModels": [
                    {"modelId": "grok-m", "name": "Grok M", "_meta": {"totalContextTokens": 1000}},
                ]},
            });
        }
        if self.profile != "beta" {
            return json!({});
        }
        json!({
            "configOptions": [{
                "id": "model", "name": "Model", "category": "model", "type": "select",
                "currentValue": "fast-1",
                "options": [
                    {"value": "fast-1", "name": "Fast"},
                    {"group": "big", "name": "Large", "options": [{"value": "large-2", "name": "Large 2"}]},
                ],
            }],
            "modes": {"currentModeId": "ask", "availableModes": [
                {"id": "ask", "name": "Ask"}, {"id": "code", "name": "Code"},
            ]},
        })
    }

    async fn handle(
        self,
        id: Value,
        method: String,
        params: Value,
        cancelled: Option<Arc<Notify>>,
    ) {
        match method.as_str() {
            "initialize" => {
                tokio::time::sleep(self.init_delay).await;
                let mut capabilities = json!({});
                if self.has_load() {
                    capabilities = json!({
                        "loadSession": true,
                        "promptCapabilities": {"image": true},
                        "sessionCapabilities": {"list": {}, "resume": {}, "close": {}},
                    });
                } else if self.has_list_and_resume() {
                    capabilities = json!({"sessionCapabilities": {"list": {}, "resume": {}}});
                }
                respond(
                    &id,
                    json!({
                        "protocolVersion": self.version,
                        "agentCapabilities": capabilities,
                        "agentInfo": {
                            "name": format!("{}-agent", self.profile),
                            "title": serde_json::to_string(&self.args).unwrap_or_default(),
                            "version": "0.0.1",
                        },
                        "authMethods": [{"id": "agent-login", "name": "Agent login"}],
                        "_meta": if self.grok {
                            json!({"grokShell": true, "agentVersion": "1.0.62",
                                   "availableCommands": [
                                       {"name": "compact", "description": "Compress", "input": null},
                                   ]})
                        } else if self.steering.is_some() {
                            json!({"ignored": true, "steering": {"supported": true}})
                        } else {
                            json!({"ignored": true})
                        },
                    }),
                );
            },
            "session/new" => {
                if self.auth_required {
                    fail(&id, -32000, "Authentication required");
                    return;
                }
                let n = {
                    let mut sessions = self.sessions.lock().expect("lock");
                    *sessions += 1;
                    *sessions
                };
                if self.grok {
                    let meta = &params["_meta"];
                    let mode = if meta["yoloMode"] == true {
                        "always-approve"
                    } else if meta["autoMode"] == true {
                        "auto"
                    } else {
                        "ask"
                    };
                    *self.permission.lock().expect("lock") = mode.into();
                }
                let mut result = self.settings();
                result["sessionId"] = json!(format!("{}-s{n}", self.profile));
                respond(&id, result);
            },
            "session/list" => {
                let cwd = self
                    .list_cwd
                    .clone()
                    .unwrap_or_else(|| std::env::temp_dir().to_string_lossy().into_owned());
                respond(
                    &id,
                    json!({"sessions": [{
                        "sessionId": "old-1", "cwd": cwd, "title": "Earlier work",
                        "updatedAt": "2026-10-01T00:00:00Z",
                    }]}),
                );
            },
            "session/load" | "session/resume" => {
                let session = params["sessionId"].as_str().unwrap_or("").to_string();
                if method == "session/load" {
                    for (question, answer) in
                        [("first question", "first answer"), ("second question", "second answer")]
                    {
                        update(&session, text("user_message_chunk", question));
                        update(&session, text("agent_message_chunk", answer));
                    }
                    // Reported while the reopen is still pending.
                    let title = if self.clear_title { Value::Null } else { json!("Loaded title") };
                    update(
                        &session,
                        json!({"sessionUpdate": "session_info_update", "title": title}),
                    );
                }
                tokio::time::sleep(self.open_delay).await;
                if self.fail_open {
                    fail(&id, -32603, "the session could not be restored");
                } else {
                    respond(&id, self.settings());
                }
            },
            "session/close" => {
                tokio::time::sleep(self.close_delay).await;
                if self.fail_close {
                    fail(&id, -32603, "session release failed");
                } else {
                    respond(&id, json!({}));
                }
            },
            "session/set_mode" => respond(&id, json!({})),
            "session/set_config_option" => {
                let mut settings = self.settings();
                settings["configOptions"][0]["currentValue"] = params["value"].clone();
                respond(&id, json!({"configOptions": settings["configOptions"]}));
            },
            "session/prompt" => {
                let cancelled = cancelled.unwrap_or_else(|| Arc::new(Notify::new()));
                let session = params["sessionId"].as_str().unwrap_or("").to_string();
                let prompt = params["_meta"]["promptId"]
                    .as_str()
                    .unwrap_or("")
                    .to_string();
                let text = params["prompt"][0]["text"]
                    .as_str()
                    .unwrap_or("")
                    .to_string();
                if self.grok {
                    queue_changed(&session, Some((&prompt, &text)));
                }
                let (running, grok) = (self.running.clone(), self.grok);
                self.prompt(id, params, cancelled).await;
                running.lock().expect("lock").remove(&session);
                if grok {
                    queue_changed(&session, None);
                    turn_completed(&session, &prompt, "end_turn");
                }
            },
            "_session/steering" if self.steering.is_some() => self.steer(&id, &params),
            "_x.ai/interject" if self.grok => self.interject(&id, &params).await,
            "_x.ai/session/rename" if self.grok => respond(&id, json!({"success": true})),
            "_x.ai/billing" if self.grok => respond(
                &id,
                json!({
                    "config": {"creditUsagePercent": 12.0, "currentPeriod": {
                        "type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-10-25T17:33:23Z"}},
                    "subscription_tier": "SuperGrok Heavy",
                }),
            ),
            _ => fail(&id, -32601, "unknown method"),
        }
    }

    /// Grok's interjection: into the running prompt, or a turn of its own.
    async fn interject(&self, id: &Value, params: &Value) {
        let session = params["sessionId"].as_str().unwrap_or("").to_string();
        let added = params["text"].as_str().unwrap_or("").to_string();
        respond(id, json!({"result": {"status": "queued"}}));
        if self.running.lock().expect("lock").contains(&session) {
            // Grok merges it into its next model response.
            update(&session, text("agent_message_chunk", " still"));
            STREAM.fetch_add(1, Ordering::SeqCst);
            update(&session, text("agent_message_chunk", &format!("interjected:{added}")));
            return;
        }
        let fallback = "interject-fallback-1";
        queue_changed(&session, Some((fallback, &added)));
        update(&session, text("agent_message_chunk", &format!("fallback:{added}")));
        tokio::time::sleep(Duration::from_millis(50)).await;
        queue_changed(&session, None);
        turn_completed(&session, fallback, "end_turn");
    }

    fn steer(&self, id: &Value, params: &Value) {
        let session = params["sessionId"].as_str().unwrap_or("");
        if params["_meta"]["steering"]["idleBehavior"] != "promptRequired" {
            fail(id, -32602, "unsupported steering idleBehavior");
            return;
        }
        match self.steering.as_deref() {
            Some("silent") => {},
            Some("odd") => respond(id, json!({"outcome": "startedNewTurn"})),
            _ if self.running.lock().expect("lock").contains(session) => {
                let added = params["prompt"][0]["text"].as_str().unwrap_or("");
                update(session, text("agent_message_chunk", &format!("steered:{added}")));
                respond(id, json!({"outcome": "injected"}));
            },
            _ => respond(id, json!({"outcome": "promptRequired", "reason": "noRunningTurn"})),
        }
    }

    async fn prompt(self, id: Value, params: Value, cancelled: Arc<Notify>) {
        let session = params["sessionId"].as_str().unwrap_or("").to_string();
        let script = params["prompt"][0]["text"]
            .as_str()
            .unwrap_or("")
            .to_string();
        if self.auth_prompt {
            fail(&id, -32000, "Authentication required");
            return;
        }
        match script.as_str() {
            "crash" => std::process::exit(3),
            "orphan" => {
                // The child inherits stdout and keeps it open after we exit.
                let child = std::process::Command::new("/bin/sleep")
                    .arg("30")
                    .stdin(std::process::Stdio::null())
                    .spawn();
                let pid = child.as_ref().map_or(0, std::process::Child::id);
                update(&session, text("agent_message_chunk", &format!("orphan:{pid}")));
                // Let the host read the report before the exit is noticed.
                std::thread::sleep(Duration::from_millis(300));
                std::process::exit(0);
            },
            "permission" => {
                update(
                    &session,
                    json!({"sessionUpdate": "tool_call", "toolCallId": "call-1",
                    "title": "Run ls", "kind": "execute", "status": "pending"}),
                );
                let answer = self
                    .call("session/request_permission", json!({
                        "sessionId": session,
                        "toolCall": {"toolCallId": "call-1", "title": "Run ls"},
                        "options": [
                            {"optionId": "opt:allow ✓", "name": "Allow once", "kind": "allow_once"},
                            {"optionId": "opt:deny", "name": "Deny", "kind": "reject_once"},
                        ],
                    }))
                    .await;
                let outcome = &answer["result"]["outcome"];
                let report = match outcome["outcome"].as_str() {
                    Some("selected") => {
                        format!("selected:{}", outcome["optionId"].as_str().unwrap_or(""))
                    },
                    Some("cancelled") => "cancelled".to_string(),
                    _ => format!("unexpected:{answer}"),
                };
                update(
                    &session,
                    json!({"sessionUpdate": "tool_call_update", "toolCallId": "call-1",
                    "status": "completed"}),
                );
                update(&session, text("agent_message_chunk", &report));
                let stop = if report == "cancelled" { "cancelled" } else { "end_turn" };
                respond(&id, json!({"stopReason": stop}));
            },
            "deaf" => {
                // `main` stops reading once this prompt arrived; the answer
                // to this request can never be read.
                let _ = self
                    .call(
                        "session/request_permission",
                        json!({
                            "sessionId": session,
                            "toolCall": {"toolCallId": "call-deaf", "title": "Run ls"},
                            "options": [
                                {"optionId": "allow", "name": "Allow once", "kind": "allow_once"},
                            ],
                        }),
                    )
                    .await;
            },
            "slow" => {
                update(&session, text("agent_message_chunk", "working"));
                cancelled.notified().await;
                // Finishing takes a while, as real tool aborts do.
                tokio::time::sleep(Duration::from_millis(400)).await;
                update(
                    &session,
                    json!({"sessionUpdate": "tool_call", "toolCallId": "late",
                    "title": "Trailing update", "status": "failed"}),
                );
                respond(&id, json!({"stopReason": "cancelled"}));
            },
            "stream" => {
                for n in 0..40 {
                    update(&session, text("agent_message_chunk", &format!("part-{n} ")));
                    if n == 20 {
                        update(
                            &session,
                            json!({"sessionUpdate": "tool_call", "toolCallId": "mid",
                            "title": "Look around", "kind": "read", "status": "completed"}),
                        );
                    }
                    tokio::time::sleep(Duration::from_millis(25)).await;
                }
                respond(&id, json!({"stopReason": "end_turn"}));
            },
            "flood" => {
                for _ in 0..5000 {
                    update(&session, text("agent_message_chunk", "x"));
                }
                cancelled.notified().await;
                update(&session, text("agent_message_chunk", "tail"));
                respond(&id, json!({"stopReason": "cancelled"}));
            },
            "settle" => {
                // The agent considers the turn over (a steer now finds none)
                // before the host has its answer.
                self.running.lock().expect("lock").remove(&session);
                tokio::time::sleep(Duration::from_millis(400)).await;
                respond(&id, json!({"stopReason": "end_turn"}));
            },
            "linger" => {
                tokio::time::sleep(Duration::from_millis(400)).await;
                update(&session, text("agent_message_chunk", "lingered"));
                respond(&id, json!({"stopReason": "end_turn"}));
            },
            "probe" => {
                let hit = tokio::time::timeout(Duration::from_millis(300), cancelled.notified())
                    .await
                    .is_ok();
                let report = if hit { "probe:cancelled" } else { "probe:clean" };
                update(&session, text("agent_message_chunk", report));
                let stop = if hit { "cancelled" } else { "end_turn" };
                respond(&id, json!({"stopReason": stop}));
            },
            "ask" if self.grok => {
                let answer = self
                    .call("_x.ai/ask_user_question", json!({
                        "sessionId": session, "toolCallId": "q1", "mode": "default",
                        "questions": [{"question": "Pick one", "multiSelect": false, "options": [
                            {"label": "A", "description": "first"},
                            {"label": "B", "description": "second"},
                        ]}],
                    }))
                    .await;
                update(
                    &session,
                    text("agent_message_chunk", &format!("asked:{}", answer["result"])),
                );
                respond(&id, json!({"stopReason": "end_turn"}));
            },
            "strand" if self.grok => {
                // The turn ends, then Grok runs a stranded interjection as a
                // turn of its own, which asks for a permission.
                respond(&id, json!({"stopReason": "end_turn"}));
                let agent = self.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(30)).await;
                    let fallback = "interject-fallback-2";
                    queue_changed(&session, Some((fallback, "late")));
                    update(&session, text("agent_message_chunk", "fallback:late"));
                    let answer = agent
                        .call("session/request_permission", json!({
                            "sessionId": session,
                            "toolCall": {"toolCallId": "call-9", "title": "Run ls"},
                            "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"}],
                        }))
                        .await;
                    let chosen = answer["result"]["outcome"]["optionId"]
                        .as_str()
                        .unwrap_or("none");
                    update(&session, text("agent_message_chunk", &format!("chosen:{chosen}")));
                    queue_changed(&session, None);
                    turn_completed(&session, fallback, "end_turn");
                });
            },
            "chain" if self.grok => {
                // Grok moves on to its own next prompt before this one's
                // answer: the queue names it first, then this turn ends.
                let prompt = params["_meta"]["promptId"]
                    .as_str()
                    .unwrap_or("")
                    .to_string();
                let next = "interject-fallback-3";
                queue_changed(&session, Some((next, "next")));
                turn_completed(&session, &prompt, "end_turn");
                update(&session, text("agent_message_chunk", "chained:next"));
                tokio::time::sleep(Duration::from_millis(80)).await;
                respond(&id, json!({"stopReason": "end_turn"}));
                tokio::time::sleep(Duration::from_millis(30)).await;
                turn_completed(&session, next, "end_turn");
            },
            "plan" if self.grok => {
                let answer = self
                    .call(
                        "_x.ai/exit_plan_mode",
                        json!({
                            "sessionId": session, "toolCallId": "p1", "planContent": "1. do it",
                        }),
                    )
                    .await;
                let outcome = answer["result"]["outcome"]
                    .as_str()
                    .unwrap_or("?")
                    .to_string();
                update(&session, text("agent_message_chunk", &format!("plan:{outcome}")));
                respond(&id, json!({"stopReason": "end_turn"}));
            },
            "perm" if self.grok => {
                let mode = self.permission.lock().expect("lock").clone();
                update(&session, text("agent_message_chunk", &format!("perm:{mode}")));
                respond(&id, json!({"stopReason": "end_turn"}));
            },
            "count" => {
                let count = self.prompts.load(Ordering::SeqCst);
                update(&session, text("agent_message_chunk", &format!("prompts:{count}")));
                respond(&id, json!({"stopReason": "end_turn"}));
            },
            "fs" => {
                let answer = self
                    .call("fs/read_text_file", json!({"sessionId": session, "path": "/etc/hosts"}))
                    .await;
                let code = answer["error"]["code"].as_i64().unwrap_or(0);
                update(&session, text("agent_message_chunk", &format!("fs:{code}")));
                respond(&id, json!({"stopReason": "end_turn"}));
            },
            _ => {
                if self.grok {
                    emit(&json!({"jsonrpc": "2.0", "method": "session/update", "params": {
                        "sessionId": session, "update": text("agent_message_chunk", "Hello"),
                        "_meta": {"totalTokens": 250},
                    }}));
                }
                update(&session, text("agent_message_chunk", "Hi"));
                update(&session, text("agent_message_chunk", " there"));
                if !self.grok {
                    update(
                        &session,
                        json!({"sessionUpdate": "usage_update", "used": 10, "size": 100}),
                    );
                }
                update(&session, json!({"sessionUpdate": "future_update_kind", "x": 1}));
                respond(&id, json!({"stopReason": "end_turn"}));
            },
        }
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let flag = |name: &str| {
        args.iter()
            .position(|arg| arg == name)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    let has = |name: &str| args.iter().any(|arg| arg == name);
    let agent = Agent {
        profile: flag("--profile").unwrap_or_else(|| "alpha".into()),
        version: flag("--version").and_then(|v| v.parse().ok()).unwrap_or(1),
        auth_required: has("--auth-required"),
        auth_prompt: has("--auth-prompt"),
        list_cwd: flag("--list-cwd"),
        open_delay: Duration::from_millis(
            flag("--open-delay-ms")
                .and_then(|v| v.parse().ok())
                .unwrap_or(0),
        ),
        fail_open: has("--fail-open"),
        close_delay: Duration::from_millis(
            flag("--close-delay-ms")
                .and_then(|v| v.parse().ok())
                .unwrap_or(0),
        ),
        fail_close: has("--fail-close"),
        init_delay: Duration::from_millis(
            flag("--init-delay-ms")
                .and_then(|v| v.parse().ok())
                .unwrap_or(0),
        ),
        clear_title: has("--clear-title"),
        steering: flag("--steering"),
        grok: has("--grok"),
        permission: Arc::new(Mutex::new("ask".into())),
        running: Arc::new(Mutex::new(HashSet::new())),
        args: args.clone(),
        next_id: Arc::new(Mutex::new(0)),
        waiting: Arc::new(Mutex::new(HashMap::new())),
        cancels: Arc::new(Mutex::new(HashMap::new())),
        sessions: Arc::new(Mutex::new(0)),
        prompts: Arc::new(AtomicU64::new(0)),
    };
    if let Some(path) = flag("--pid-file") {
        let _ = std::fs::write(path, std::process::id().to_string());
    }
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(frame) = serde_json::from_str::<Value>(&line) else { continue };
        match (frame.get("id").cloned(), frame["method"].as_str()) {
            (Some(id), Some(method)) => {
                // A turn's cancel signal is installed here, in line order,
                // so a `session/cancel` that follows the prompt always
                // reaches this turn and never an earlier or later one.
                let cancelled = (method == "session/prompt").then(|| {
                    agent.prompts.fetch_add(1, Ordering::SeqCst);
                    let session = frame["params"]["sessionId"].as_str().unwrap_or("");
                    agent
                        .running
                        .lock()
                        .expect("lock")
                        .insert(session.to_string());
                    let signal = Arc::new(Notify::new());
                    agent
                        .cancels
                        .lock()
                        .expect("lock")
                        .insert(session.to_string(), signal.clone());
                    signal
                });
                tokio::spawn(agent.clone().handle(
                    id,
                    method.to_string(),
                    frame["params"].clone(),
                    cancelled,
                ));
                if method == "session/prompt" && frame["params"]["prompt"][0]["text"] == "deaf" {
                    // Alive, but never reading again.
                    std::future::pending::<()>().await;
                }
            },
            (None, Some("_x.ai/yolo_mode_changed")) if agent.grok => {
                if let Some(mode) = frame["params"]["permission_mode"].as_str() {
                    *agent.permission.lock().expect("lock") = mode.into();
                }
            },
            (None, Some("session/cancel")) => {
                let session = frame["params"]["sessionId"].as_str().unwrap_or("");
                agent.cancel_signal(session).notify_one();
            },
            (Some(id), None) => {
                if let Some(waiter) = id
                    .as_i64()
                    .and_then(|id| agent.waiting.lock().expect("lock").remove(&id))
                {
                    let _ = waiter.send(frame);
                }
            },
            _ => {},
        }
    }
}
