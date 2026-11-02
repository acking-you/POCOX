//! Branch a session with the agent's own fork. Both forks only read the
//! source's stored files, so nothing here loads, closes or signals whoever
//! holds it; the new session goes through ordinary admission when it is opened.
//!
//! A fork of a changing source is what its files hold at that moment. The agent
//! repairs the cut when the new session loads: an unanswered prompt or tool
//! call stays unanswered and never runs, and the source's later output never
//! arrives. `docs/session-fork.md` says what was verified on which version.

use super::*;
use crate::native_history::{GrokHistory, NativeHistory, NativePage, PromptMark};

/// Grok's fork: it copies the session's files and takes a prompt boundary.
const GROK_FORK: &str = "_x.ai/session/fork";
/// How long an agent gets to copy a session.
const FORK_TIMEOUT: Duration = Duration::from_secs(60);

impl AgentHost {
    /// What this host offers, for its `info`. Only agents whose fork was
    /// verified, on the stored sessions this host reads: another agent's
    /// `session/fork` might load or write its source. The Claude adapter's only
    /// boundary is a private extension of another client, so it has no turn.
    pub(super) fn fork_support(&self, caps: Option<&AgentCapabilities>) -> Value {
        let (supported, through_turn) = match (&self.inner.native_history, caps) {
            (Some(NativeHistory::Grok(_)), Some(caps)) if caps.grok => (true, true),
            (Some(NativeHistory::Claude(_)), Some(caps)) if caps.fork => (true, false),
            _ => (false, false),
        };
        json!({"supported": supported, "throughTurn": through_turn})
    }

    /// Branch `source` into a new session, through `through_turn` (inclusive)
    /// or from what it has saved now. A refusal is an `Err`: nothing was
    /// created. An answer that leaves that open is `{"outcome": "unknown"}`,
    /// never retried. The source's writer, drafts and queue are not touched.
    pub async fn fork_session(
        &self,
        source: &str,
        through_turn: Option<&str>,
        expected: &Identity,
    ) -> Result<Value, HostError> {
        valid_id(source)?;
        if expected.host_id.is_none() || expected.generation.is_none() {
            return Err(HostError::Stale);
        }
        let (generation, peer, caps) = self.ready_for(Some(expected))?;
        if self.fork_support(Some(&caps))["supported"] != true {
            return Err(HostError::Unsupported(
                "this agent's sessions cannot be forked here".into(),
            ));
        }
        let reader = self
            .inner
            .native_history
            .as_ref()
            .ok_or(HostError::NotReady)?;
        // Grok's fork leaves an empty directory behind for a source it cannot
        // find, and the new session needs a folder to run in.
        let page = reader
            .read_page(source, None, 1)
            .await
            .map_err(|error| HostError::Agent(clip(&error.to_string(), 300)))?;
        validate_cwd(&page.cwd).await?;
        let (method, params, boundary) = match (reader, through_turn) {
            (NativeHistory::Grok(grok), turn) => {
                let boundary = match turn {
                    Some(turn) => Some(self.grok_boundary(grok, source, turn).await?),
                    None => None,
                };
                let mut params =
                    json!({"sourceSessionId": source, "sourceCwd": page.cwd, "newCwd": page.cwd});
                if let Some(index) = boundary {
                    params["targetPromptIndex"] = json!(index);
                }
                (GROK_FORK, params, boundary)
            },
            (_, None) => {
                let params = json!({"sessionId": source, "cwd": page.cwd, "mcpServers": []});
                ("session/fork", params, None)
            },
            (_, Some(_)) => {
                return Err(HostError::Unsupported(
                    "this agent forks only from the latest saved state".into(),
                ));
            },
        };
        let running = self
            .state()
            .sessions
            .get(source)
            .is_some_and(|entry| entry.active.is_some())
            || reader.handoff_liveness(source).await.turn_state == "running";
        let answer = match peer.request(method, params, Some(FORK_TIMEOUT)).await {
            Ok(answer) => answer,
            Err(CallError::Rpc(error)) if error.code == RpcError::METHOD_NOT_FOUND => {
                return Err(HostError::Unsupported(
                    "this version of the agent cannot fork conversations; update it on the host"
                        .into(),
                ));
            },
            Err(CallError::Rpc(error)) if error.code == RpcError::INVALID_PARAMS => {
                return Err(HostError::Agent(clip(&error.message, 300)));
            },
            Err(
                error @ (CallError::Busy
                | CallError::TooLarge
                | CallError::Rpc(RpcError {
                    code: RpcError::AUTH_REQUIRED, ..
                })),
            ) => return Err(self.call_error(generation, error)),
            // Anything else can follow the copy, and a retry could add another.
            Err(error) => return Ok(unknown(&error.to_string())),
        };
        let fork = answer["newSessionId"]
            .as_str()
            .or_else(|| answer["sessionId"].as_str())
            .filter(|id| !id.is_empty() && id.len() <= MAX_ID && *id != source);
        let Some(fork) = fork else {
            return Ok(unknown("the agent answered without a new session"));
        };
        Ok(self
            .created_fork(reader, source, fork, &page, boundary, running)
            .await)
    }

    /// The `targetPromptIndex` of a finished turn this view named: a replayed
    /// turn knows its prompt, a live one ended under its own id, and an
    /// unadmitted session shows the reader's ids.
    async fn grok_boundary(
        &self,
        grok: &GrokHistory,
        source: &str,
        turn: &str,
    ) -> Result<usize, HostError> {
        let marks = grok
            .prompts(source)
            .await
            .map_err(|error| HostError::Agent(clip(&error.to_string(), 300)))?;
        let replayed = self.state().transcript_ref(source).and_then(|transcript| {
            transcript
                .turns
                .iter()
                .find(|known| known.id == turn)
                .and_then(|known| known.prompt_index)
        });
        let index = replayed
            .and_then(|index| usize::try_from(index).ok())
            .filter(|&index| index < marks.len())
            .or_else(|| prompt_position(&marks, turn))
            .ok_or_else(|| {
                HostError::InvalidInput("this turn cannot be a fork's last turn".into())
            })?;
        // A later prompt means this one is over, even if its end went unrecorded.
        if !marks[index].ended && index + 1 == marks.len() {
            return Err(HostError::Busy);
        }
        // Compaction rewrites what came before it into a summary, so a cut
        // before it would keep a summary of what the fork must not know.
        if marks[index + 1..].iter().any(|mark| mark.compacted) {
            return Err(HostError::Unsupported(
                "the conversation was compacted after this turn, so it can only be forked from \
                 its latest saved state"
                    .into(),
            ));
        }
        Ok(index)
    }

    /// What the agent answered, checked against what it stored: a fork that
    /// cannot be read here cannot be opened here either.
    async fn created_fork(
        &self,
        reader: &NativeHistory,
        source: &str,
        fork: &str,
        page: &NativePage,
        boundary: Option<usize>,
        running: bool,
    ) -> Value {
        let copied = reader.read_page(fork, None, 1).await.ok();
        let marks = match reader {
            NativeHistory::Grok(grok) => grok.prompts(fork).await.ok(),
            _ => None,
        };
        let boundary_confirmed = boundary
            .is_none_or(|index| marks.as_ref().is_some_and(|marks| marks.len() == index + 1));
        let unfinished = marks
            .as_ref()
            .and_then(|marks| marks.last())
            .is_some_and(|mark| !mark.ended);
        let shown = copied.as_ref().unwrap_or(page);
        json!({
            "outcome": "created",
            "sessionId": fork,
            "cwd": shown.cwd,
            "title": shown.title,
            "forkedFrom": source,
            "lastTurnInterrupted": boundary.is_none() && (running || unfinished),
            "boundaryConfirmed": boundary_confirmed,
            "hostId": self.host_id(),
            "generation": self.state().generation,
        })
    }
}

/// The request reached the agent and its answer does not say what became of it.
fn unknown(reason: &str) -> Value {
    json!({"outcome": "unknown", "reason": clip(reason, 300)})
}

/// The prompt shown as `turn`, or that ran under `turn` as its prompt id.
fn prompt_position(marks: &[PromptMark], turn: &str) -> Option<usize> {
    marks
        .iter()
        .position(|mark| mark.turn == turn || mark.prompt_ids.iter().any(|id| id == turn))
}
