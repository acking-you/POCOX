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
//! updates, permission requests and cancellation work the same way. Every
//! turn ends with its `turn_completed` (a prompt turn's answer can follow
//! later, after Grok already moved on), and a prompt the queue named while
//! the previous turn was still open is opened when that turn ends.
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
use crate::acp::state::{GrokPermission, HeldSupplement};

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

/// The option of Grok's permission mode, which this host sets for it.
pub(super) const PERMISSION_OPTION: &str = "x.ai/permission_mode";
/// The Grok account's credit usage and period.
const BILLING: &str = "_x.ai/billing";
/// Grok's permission mode change, applied to every session of its process.
const PERMISSION_CHANGED: &str = "_x.ai/yolo_mode_changed";

/// Grok's permission mode as a select option (`category` names it for the
/// UI, which labels its values).
pub(crate) fn grok_permission_option(mode: GrokPermission) -> Value {
    json!({
        "id": PERMISSION_OPTION,
        "name": "Permissions",
        "category": "x.ai/permission",
        "type": "select",
        "currentValue": mode.id(),
        "options": [
            {"value": "ask", "name": "Ask"},
            {"value": "auto", "name": "Auto"},
            {"value": "always-approve", "name": "Always approve"},
        ],
    })
}

/// Grok's plan mode as session modes: Grok accepts `default` and `plan` in
/// `session/set_mode` and reports `current_mode_update`, but does not
/// advertise them.
pub(super) fn grok_modes(settings: &mut SessionSettings) {
    if settings.modes.is_none() {
        settings.modes = Some(json!({
            "currentModeId": "default",
            "availableModes": [
                {"id": "default", "name": "Default"},
                {"id": "plan", "name": "Plan"},
            ],
        }));
    }
}

/// The `_meta` starting or reopening a session in `mode`.
pub(super) fn permission_meta(mode: GrokPermission) -> Value {
    json!({
        "yoloMode": mode == GrokPermission::AlwaysApprove,
        "autoMode": mode == GrokPermission::Auto,
    })
}

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
            .map(|id| {
                let text = params["runningText"].as_str().unwrap_or_default();
                (id.to_string(), clip(text, MAX_PROMPT_TEXT))
            });
        let mut state = self.state();
        if state.generation != generation {
            return;
        }
        let Some(entry) = state.sessions.get_mut(session) else { return };
        if entry.native_running.as_ref().map(|(id, _)| id) == running.as_ref().map(|(id, _)| id) {
            return;
        }
        entry.native_running = running;
        adopt_native_turn(&mut state, session);
    }

    /// A Grok session notification: `turn_completed` ends the turn it
    /// names, a prompt turn too (its answer may follow later, and Grok may
    /// already run the next prompt meanwhile).
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
        let ends = {
            let mut state = self.state();
            if state.generation != generation {
                return;
            }
            let Some(entry) = state.sessions.get_mut(session) else { return };
            if entry
                .native_running
                .as_ref()
                .is_some_and(|(id, _)| id == prompt)
            {
                entry.native_running = None;
            }
            entry
                .active
                .as_ref()
                .is_some_and(|active| active.id == prompt)
        };
        if ends {
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
            let refusal = if method == PLAN_APPROVAL {
                "malformed plan approval"
            } else {
                "malformed questions, or more than this client shows at once"
            };
            peer.respond_now(id, Err(RpcError::new(RpcError::INVALID_PARAMS, refusal)));
            return;
        };
        self.admit_request(generation, peer, id, request);
    }

    /// Set Grok's permission mode. It applies to every session of the agent
    /// process, so every session's state changes; later sessions start in it.
    pub(super) async fn set_grok_permission(
        &self,
        generation: u64,
        peer: &Peer,
        session: &str,
        value: &str,
    ) -> Result<Value, HostError> {
        let mode = GrokPermission::from_id(value)
            .ok_or_else(|| HostError::InvalidInput("that value is not offered".into()))?;
        let deadline = Instant::now() + self.budgets().control;
        let delivered = peer
            .notify(
                PERMISSION_CHANGED,
                json!({
                    "yolo_mode": mode == GrokPermission::AlwaysApprove,
                    "auto_mode": mode == GrokPermission::Auto,
                    "permission_mode": mode.id(),
                }),
                deadline,
            )
            .await;
        self.control_outcome(generation, peer, delivered)?;
        let mut state = self.state();
        if state.generation != generation {
            return Err(HostError::NotReady);
        }
        state.grok_permission = mode;
        let sessions: Vec<String> = state.sessions.keys().cloned().collect();
        for id in sessions {
            state.session_event(&id);
        }
        Ok(state.session_body(session))
    }

    /// The Grok account's usage window (`_x.ai/billing`), in the app's
    /// rate-limit shape: the period's used share and its reset, with the
    /// subscription tier. Needs a Grok account (a custom provider has none).
    pub async fn rate_limits(&self) -> Result<Value, HostError> {
        let (generation, peer, caps) = self.ready()?;
        if !caps.grok {
            return Err(HostError::Unsupported("this agent reports no usage limits".into()));
        }
        let answer = peer
            .request(BILLING, json!({}), Some(CONFIG_TIMEOUT))
            .await
            .map_err(|error| self.call_error(generation, error))?;
        let billing = unwrap_ext(&answer)?;
        let config = &billing["config"];
        let used = config["creditUsagePercent"]
            .as_f64()
            .ok_or_else(|| HostError::Agent("no usage reported for this account".into()))?;
        let period = &config["currentPeriod"];
        let minutes = match period["type"].as_str() {
            Some("USAGE_PERIOD_TYPE_WEEKLY") => Some(7 * 24 * 60),
            Some("USAGE_PERIOD_TYPE_MONTHLY") => Some(30 * 24 * 60),
            _ => None,
        };
        let resets = period["end"]
            .as_str()
            .or_else(|| config["billingPeriodEnd"].as_str());
        Ok(json!({
            "rateLimits": {"secondary": {
                "usedPercent": used,
                "windowDurationMins": minutes,
                "resetsAt": resets,
            }},
            "planType": billing["subscription_tier"]
                .as_str()
                .or_else(|| billing["subscriptionTier"].as_str()),
        }))
    }

    /// Hold a supplement sent to Grok until its next model response, where
    /// Grok merges it ([`merge_held_supplements`]); `held.stream` is the
    /// response running now.
    pub(super) fn hold_supplement(&self, generation: u64, session: &str, mut held: HeldSupplement) {
        let mut state = self.state();
        if state.generation != generation {
            return;
        }
        if let Some(entry) = state.sessions.get_mut(session) {
            held.stream = entry.native_stream;
            entry.held_supplements.push(held);
        }
    }

    /// Withdraw held interjection `id`, which Grok did not take (or whose
    /// answer is unknown); one already merged stays recorded.
    pub(super) fn withdraw_supplement(&self, generation: u64, session: &str, id: &str) {
        let mut state = self.state();
        if state.generation != generation {
            return;
        }
        if let Some(entry) = state.sessions.get_mut(session) {
            entry.held_supplements.retain(|held| held.id != id);
        }
    }

    /// Whether Grok reports `turn` of `session` running (a supplement goes
    /// only to that turn).
    pub(super) fn grok_runs(&self, generation: u64, session: &str, turn: &str) -> bool {
        let state = self.state();
        state.generation == generation
            && state.sessions.get(session).is_some_and(|entry| {
                entry
                    .native_running
                    .as_ref()
                    .is_some_and(|(id, _)| id == turn)
            })
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
/// options: [{label, description}], multiSelect?}]}`. The set is answered
/// as a whole, so one that is malformed anywhere or exceeds the bounds is
/// refused, never shown in part.
pub(super) fn question(params: &Value) -> Option<Permission> {
    let asked = params["questions"].as_array()?;
    if asked.is_empty() || asked.len() > MAX_QUESTIONS {
        return None;
    }
    let questions = asked
        .iter()
        .map(|question| {
            let offered = question["options"].as_array()?;
            if offered.is_empty() || offered.len() > MAX_QUESTION_OPTIONS {
                return None;
            }
            let options = offered
                .iter()
                .map(|option| {
                    Some(json!({
                        "label": option["label"].as_str()?,
                        "description": text(&option["description"], 1024),
                    }))
                })
                .collect::<Option<Vec<_>>>()?;
            Some(json!({
                "question": question["question"].as_str()?,
                "multiSelect": question["multiSelect"] == true,
                "options": options,
            }))
        })
        .collect::<Option<Vec<_>>>()?;
    let tool_call = json!({
        "toolCallId": text(&params["toolCallId"], MAX_ID),
        "title": "Question",
        "kind": "think",
    });
    pending(params, tool_call, RequestKind::Question(questions))
}

/// Open the prompt Grok's queue reports running in `session` as a turn Grok
/// started by itself, unless a turn is already open here (this host's
/// prompt, or one opened before), the session is reopening, or that prompt
/// already ended here. Called when the queue moves and when a turn ends:
/// Grok can run its next prompt before the previous one's answer arrives.
pub(super) fn adopt_native_turn(state: &mut State, session: &str) {
    let Some(entry) = state.sessions.get(session) else { return };
    let Some((prompt, text)) = entry.native_running.clone() else { return };
    if entry.pending || entry.active.is_some() || !state.outcomes_of(session, &prompt).is_empty() {
        return;
    }
    if let Some(entry) = state.sessions.get_mut(session) {
        entry.active = Some(ActiveTurn::agent_started(prompt.clone()));
    }
    state.touch(session);
    // Without transcript room the turn still runs (and is shown running);
    // its content is dropped like any other.
    if state.reserve_transcript(session, false) {
        if let Some(transcript) = state.transcript_mut(session) {
            transcript.begin_turn(&prompt, &text, &[]);
        }
    }
    state.event(json!({
        "type": "turn_started", "sessionId": session, "turnId": prompt,
        "userText": text, "imageCount": 0, "agentStarted": true, "clientId": null,
    }));
    state.session_event(session);
}

/// An update of `session` from model response `stream` (Grok's
/// `_meta.streamStartMs`): a response other than the one a held supplement
/// arrived during is where Grok merged it, so it is folded before this
/// update's content.
pub(super) fn merge_held_supplements(state: &mut State, session: &str, stream: Option<u64>) {
    let Some(stream) = stream else { return };
    let Some(entry) = state.sessions.get_mut(session) else { return };
    if entry.native_stream == Some(stream) {
        return;
    }
    entry.native_stream = Some(stream);
    let Some(turn) = entry.active.as_ref().map(|active| active.id.clone()) else { return };
    let (merged, held): (Vec<_>, Vec<_>) = std::mem::take(&mut entry.held_supplements)
        .into_iter()
        .partition(|supplement| supplement.turn == turn && supplement.stream != Some(stream));
    entry.held_supplements = held;
    for supplement in merged {
        super::steer::record_supplement(
            state,
            session,
            &supplement.turn,
            &supplement.text,
            supplement.images,
            supplement.client_id.as_deref(),
        );
    }
}

/// Grok names the context in use on every update (`_meta.totalTokens`);
/// `true` when the share of the model's window moved by a whole percent,
/// so controllers are told without an event per streamed chunk. A replay
/// arrives before the reopen's answer names the window, which
/// `State::confirm` fills in.
pub(super) fn note_usage(state: &mut State, session: &str, params: &Value) -> bool {
    let Some(used) = params["_meta"]["totalTokens"].as_u64() else { return false };
    let Some(entry) = state.sessions.get_mut(session) else { return false };
    let size = entry.settings.context_window().unwrap_or_default();
    let percent = |usage: Option<(u64, u64)>| {
        usage
            .filter(|(_, size)| *size > 0)
            .map(|(used, size)| used.saturating_mul(100) / size)
    };
    let before = percent(entry.usage);
    entry.usage = Some((used, size));
    !entry.pending && percent(entry.usage) != before
}
