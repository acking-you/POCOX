//! Grok Build's own extensions, for an agent that negotiated them
//! ([`AgentCapabilities::grok`]); every name here is on Grok's wire.
//!
//! # Turns
//!
//! Grok's queue reports which prompt runs (`_x.ai/queue/changed`,
//! `runningPromptId`) and every turn's end (`_x.ai/session_notification`,
//! `turn_completed`). This host sends each prompt with `_meta.promptId` set
//! to its own turn id, so a running id it did not send belongs to a turn
//! Grok started by itself: an interjection that arrived after the turn it
//! was meant for had ended (`interject-fallback-…`), or a looped, scheduled
//! or goal turn. Such a turn is opened here like a prompt turn — its
//! updates, permission requests and cancellation work the same way — and it
//! ends with its `turn_completed`, since it has no prompt answer.
//!
//! # Supplements
//!
//! `_x.ai/interject` hands the message to the running turn; Grok merges it
//! at the turn's next safe point (after a tool batch, or before the turn
//! would return, when it asks the model again). When the turn ends first,
//! Grok runs it as a turn of its own, opened as above, and a stop discards
//! a message not merged yet — as Codex treats its own steering input. A
//! supplement is sent only while Grok reports this host's turn running.

use super::*;

/// Grok's queue state, with the prompt it runs.
pub(super) const QUEUE_CHANGED: &str = "_x.ai/queue/changed";
/// Grok's session notifications (`turn_completed`, among others).
pub(super) const SESSION_NOTIFICATION: &str = "_x.ai/session_notification";
/// Add a message to the running turn.
pub(super) const INTERJECT: &str = "_x.ai/interject";
const RENAME: &str = "_x.ai/session/rename";
/// Grok asks to leave plan mode with its plan.
pub(super) const PLAN_APPROVAL: &str = "_x.ai/exit_plan_mode";
/// Grok asks the user questions with offered answers.
pub(super) const QUESTION: &str = "_x.ai/ask_user_question";

/// Most questions, and options per question, taken from one request.
const MAX_QUESTIONS: usize = 8;
const MAX_QUESTION_OPTIONS: usize = 16;

/// Longest prompt id taken from the agent.
const MAX_PROMPT_ID: usize = 256;

/// Grok wraps most extension answers as `{"result": …, "error"?: …}`.
fn unwrap_ext(answer: &Value) -> Result<&Value, HostError> {
    match answer.get("error") {
        Some(Value::Null) | None => Ok(answer.get("result").unwrap_or(answer)),
        Some(error) => Err(HostError::Agent(clip(
            error
                .as_str()
                .or_else(|| error["message"].as_str())
                .unwrap_or("the agent refused"),
            300,
        ))),
    }
}

/// Whether an `_x.ai/interject` answer says the message was taken.
pub(super) fn interject_accepted(answer: &Value) -> bool {
    unwrap_ext(answer).is_ok_and(|result| result["status"] == "queued")
}

impl AgentHost {
    /// Whether the running generation negotiated Grok's extensions.
    pub(super) fn negotiated_grok(&self) -> bool {
        self.state()
            .negotiated
            .as_ref()
            .is_some_and(|negotiated| negotiated.capabilities.grok)
    }

    /// Grok's queue changed: remember what it runs, and open a turn Grok
    /// started by itself.
    pub(super) fn on_grok_queue(&self, generation: u64, params: Option<Value>) {
        let Some(params) = params else { return };
        let Some(session) = params["sessionId"].as_str() else { return };
        let running = params["runningPromptId"]
            .as_str()
            .filter(|id| !id.is_empty() && id.len() <= MAX_PROMPT_ID)
            .map(str::to_string);
        let mut state = self.state();
        if state.generation != generation {
            return;
        }
        let Some(entry) = state.sessions.get_mut(session) else { return };
        if entry.native_running == running {
            return;
        }
        entry.native_running.clone_from(&running);
        // A turn already open here is this host's prompt (or one opened
        // before); a reopening session is not live yet.
        let Some(prompt) = running else { return };
        if entry.pending || entry.active.is_some() {
            return;
        }
        entry.active = Some(ActiveTurn::agent_started(prompt.clone()));
        let text = clip(params["runningText"].as_str().unwrap_or_default(), MAX_PROMPT_TEXT);
        state.touch(session);
        // Without transcript room the turn still runs (and is shown
        // running), its content is dropped like any other.
        if state.reserve_transcript(session, false) {
            if let Some(transcript) = state.transcript_mut(session) {
                transcript.begin_turn(&prompt, &text, &[]);
            }
        }
        state.event(json!({
            "type": "turn_started", "sessionId": session, "turnId": prompt,
            "userText": text, "imageCount": 0, "agentStarted": true,
        }));
        state.session_event(session);
    }

    /// A Grok session notification: `turn_completed` ends a turn Grok
    /// started (a prompt turn ends with its answer instead).
    pub(super) fn on_grok_notification(&self, generation: u64, params: Option<Value>) {
        let Some(params) = params else { return };
        let update = &params["update"];
        if update["sessionUpdate"] != "turn_completed" {
            return;
        }
        let (Some(session), Some(prompt)) = (
            params["sessionId"].as_str(),
            update["prompt_id"]
                .as_str()
                .or_else(|| update["promptId"].as_str()),
        ) else {
            return;
        };
        let agent_started = {
            let mut state = self.state();
            if state.generation != generation {
                return;
            }
            let Some(entry) = state.sessions.get_mut(session) else { return };
            if entry.native_running.as_deref() == Some(prompt) {
                entry.native_running = None;
            }
            entry
                .active
                .as_ref()
                .is_some_and(|active| active.agent_started && active.id == prompt)
        };
        if agent_started {
            let stop = update["stop_reason"]
                .as_str()
                .or_else(|| update["stopReason"].as_str());
            let outcome = TurnOutcome::from_prompt_result(&json!({"stopReason": stop}));
            self.finish_turn(generation, session, prompt, outcome);
        }
    }

    /// Grok's plan approval or questions: held like a permission request
    /// of the running turn (withdrawn with it), answered through
    /// [`AgentHost::answer_permission`] (plan) or
    /// [`AgentHost::answer_question`].
    pub(super) fn on_grok_request(
        &self,
        generation: u64,
        peer: &Peer,
        id: RequestId,
        method: &str,
        params: Option<Value>,
    ) {
        let params = params.unwrap_or_default();
        let request = match method {
            PLAN_APPROVAL => plan_approval(&params),
            _ => question(&params),
        };
        let Some(request) = request else {
            peer.respond_now(id, Err(RpcError::new(RpcError::INVALID_PARAMS, "malformed request")));
            return;
        };
        self.admit_request(generation, peer, id, request);
    }

    /// Whether Grok reports `turn` of `session` running (a supplement goes
    /// only to that turn).
    pub(super) fn grok_runs(&self, generation: u64, session: &str, turn: &str) -> bool {
        let state = self.state();
        state.generation == generation
            && state
                .sessions
                .get(session)
                .is_some_and(|entry| entry.native_running.as_deref() == Some(turn))
    }

    /// Rename `session` through Grok (`_x.ai/session/rename`); the title is
    /// then this session's, as if the agent had reported it.
    pub async fn rename(
        &self,
        session: &str,
        title: &str,
        expected: Option<&Identity>,
    ) -> Result<Value, HostError> {
        let _control = self.inner.session_control.lock().await;
        valid_id(session)?;
        let title = title.trim();
        if title.is_empty() || title.chars().count() > 512 {
            return Err(HostError::InvalidInput("enter a title of at most 512 characters".into()));
        }
        let (generation, peer, caps) = self.ready_for(expected)?;
        if !caps.grok {
            return Err(HostError::Unsupported("this agent cannot rename sessions".into()));
        }
        {
            let state = self.state();
            let entry = state
                .sessions
                .get(session)
                .ok_or(HostError::UnknownSession)?;
            if entry.pending {
                return Err(HostError::Loading);
            }
        }
        let answer = peer
            .request(RENAME, json!({"sessionId": session, "title": title}), Some(CONFIG_TIMEOUT))
            .await
            .map_err(|error| self.call_error(generation, error))?;
        if unwrap_ext(&answer)?["success"] == false {
            return Err(HostError::Agent("the agent did not rename the session".into()));
        }
        let mut state = self.state();
        if state.generation != generation {
            return Err(HostError::NotReady);
        }
        if let Some(entry) = state.sessions.get_mut(session) {
            entry.title = Some(title.to_string());
            entry.title_reported = true;
            let title = title.to_string();
            self.inner
                .persist
                .submit(|queue| queue.title(session, Some(title)));
        }
        state.session_event(session);
        Ok(state.session_body(session))
    }
}

fn text(value: &Value, limit: usize) -> String {
    value
        .as_str()
        .map(|text| clip(text, limit))
        .unwrap_or_default()
}

/// A pending request of `params` (its turn is set on admission).
fn pending(params: &Value, tool_call: Value, kind: RequestKind) -> Option<Permission> {
    let session = params["sessionId"].as_str()?;
    Some(Permission {
        session: session.to_string(),
        turn: String::new(),
        acp_id: RequestId::Number(0),
        options: Vec::new(),
        tool_call,
        kind,
    })
}

/// `_x.ai/exit_plan_mode {sessionId, toolCallId, planContent?}`, offered as
/// approve (`approved`) or keep planning (`cancelled`), Grok's outcomes.
fn plan_approval(params: &Value) -> Option<Permission> {
    let mut tool_call = json!({
        "toolCallId": text(&params["toolCallId"], MAX_ID),
        "title": "Plan",
        "kind": "think",
    });
    if let Some(plan) = params["planContent"].as_str() {
        tool_call["content"] = json!([{"type": "content",
            "content": {"type": "text", "text": clip(plan, MAX_PROMPT_TEXT)}}]);
    }
    let mut request = pending(params, tool_call, RequestKind::PlanApproval)?;
    request.options = vec![
        schema::PermissionOption {
            option_id: "approved".into(),
            name: "Approve plan".into(),
            kind: "allow_once".into(),
        },
        schema::PermissionOption {
            option_id: "cancelled".into(),
            name: "Keep planning".into(),
            kind: "reject_once".into(),
        },
    ];
    Some(request)
}

/// `_x.ai/ask_user_question {sessionId, toolCallId, questions: [{question,
/// options: [{label, description}], multiSelect?}]}`, bounded.
fn question(params: &Value) -> Option<Permission> {
    let questions: Vec<Value> = params["questions"]
        .as_array()?
        .iter()
        .take(MAX_QUESTIONS)
        .filter_map(|question| {
            let options: Vec<Value> = question["options"]
                .as_array()?
                .iter()
                .take(MAX_QUESTION_OPTIONS)
                .filter_map(|option| {
                    Some(json!({
                        "label": option["label"].as_str()?,
                        "description": text(&option["description"], 1024),
                    }))
                })
                .collect();
            Some(json!({
                "question": question["question"].as_str()?,
                "multiSelect": question["multiSelect"] == true,
                "options": options,
            }))
        })
        .collect();
    if questions.is_empty() {
        return None;
    }
    let tool_call = json!({
        "toolCallId": text(&params["toolCallId"], MAX_ID),
        "title": "Question",
        "kind": "think",
    });
    pending(params, tool_call, RequestKind::Question(questions))
}
