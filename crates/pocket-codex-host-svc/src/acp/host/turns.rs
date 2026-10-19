//! Turns and control answers: prompt admission and dispatch, cancel and
//! permission answers, all ordered by the dispatch lane and bounded by the
//! delivery budgets (see the parent module docs).

use super::*;

/// Turn a `data:<mime>;base64,<data>` URL into an ACP image block.
fn image_block(url: &str) -> Result<Value, HostError> {
    let invalid = || HostError::InvalidInput("unsupported image attachment".into());
    if url.len() > MAX_IMAGE_BYTES {
        return Err(HostError::InvalidInput("an image attachment is too large".into()));
    }
    let rest = url.strip_prefix("data:").ok_or_else(invalid)?;
    let (mime, data) = rest.split_once(";base64,").ok_or_else(invalid)?;
    if !mime.starts_with("image/") || data.is_empty() {
        return Err(invalid());
    }
    Ok(json!({"type": "image", "mimeType": mime, "data": data}))
}

/// Size and emptiness limits shared by prompts and supplements.
pub(super) fn check_message(text: &str, images: &[String]) -> Result<(), HostError> {
    if text.len() > MAX_PROMPT_TEXT || images.len() > MAX_PROMPT_IMAGES {
        return Err(HostError::InvalidInput("the message is too large".into()));
    }
    if text.trim().is_empty() && images.is_empty() {
        return Err(HostError::InvalidInput("the message is empty".into()));
    }
    Ok(())
}

/// The ACP content blocks of a message, refusing images the agent did not
/// say it accepts.
pub(super) fn content_blocks(
    text: &str,
    images: &[String],
    caps: &AgentCapabilities,
) -> Result<Vec<Value>, HostError> {
    if !images.is_empty() && !caps.image {
        return Err(HostError::Unsupported("this agent does not accept images".into()));
    }
    let mut blocks = Vec::with_capacity(images.len() + 1);
    if !text.is_empty() {
        blocks.push(json!({"type": "text", "text": text}));
    }
    for image in images {
        blocks.push(image_block(image)?);
    }
    Ok(blocks)
}

impl AgentHost {
    /// Admit a prompt turn and return its id at once; a separate task sends
    /// it to the agent (unless it is cancelled first) and awaits the answer.
    pub async fn prompt(
        &self,
        session: &str,
        text: &str,
        images: &[String],
        expected: Option<&Identity>,
    ) -> Result<String, HostError> {
        self.prompt_as(session, text, images, None, expected).await
    }

    /// [`AgentHost::prompt`] for a caller that named its message with
    /// `client_id`: the turn's `turn_started` event carries it (`null` when
    /// none), so the controller that sent it knows the message as its own and
    /// every other one shows it. It identifies the message to its sender
    /// only, never as an idempotency key.
    pub async fn prompt_as(
        &self,
        session: &str,
        text: &str,
        images: &[String],
        client_id: Option<&str>,
        expected: Option<&Identity>,
    ) -> Result<String, HostError> {
        valid_id(session)?;
        if let Some(client_id) = client_id {
            valid_id(client_id)?;
        }
        check_message(text, images)?;
        let (generation, peer, caps) = self.ready_for(expected)?;
        {
            let state = self.state();
            let entry = state
                .sessions
                .get(session)
                .ok_or(HostError::UnknownSession)?;
            if entry.pending {
                return Err(HostError::Loading);
            }
            if entry.active.is_some() {
                return Err(HostError::Busy);
            }
        }
        self.recheck_native_writer(session, generation).await?;
        let blocks = content_blocks(text, images, &caps)?;
        let turn = uuid::Uuid::new_v4().to_string();
        {
            let mut state = self.state();
            if state.generation != generation {
                return Err(HostError::NotReady);
            }
            let Some(entry) = state.sessions.get(session) else {
                return Err(HostError::UnknownSession);
            };
            if entry.pending {
                return Err(HostError::Loading);
            }
            if entry.active.is_some() {
                return Err(HostError::Busy);
            }
            // A running turn holds its transcript; get one first or refuse.
            if !state.reserve_transcript(session, false) {
                return Err(HostError::Capacity);
            }
            if let Some(entry) = state.sessions.get_mut(session) {
                entry.active = Some(ActiveTurn::new(turn.clone()));
            }
            state.touch(session);
            if let Some(transcript) = state.transcript_mut(session) {
                transcript.begin_turn(&turn, text, images);
            }
            let body = json!({
                "type": "turn_started", "sessionId": session, "turnId": turn,
                "userText": clip(text, MAX_PROMPT_TEXT), "imageCount": images.len(),
                "clientId": client_id,
            });
            state.event(body);
        }
        // The dispatch budget starts now, before the lane (see the module
        // docs).
        let deadline = Instant::now() + self.budgets().dispatch;
        let host = self.clone();
        let (session_id, turn_id) = (session.to_string(), turn.clone());
        let grok = caps.grok;
        tokio::spawn(async move {
            let call = {
                let Ok(_lane) = tokio::time::timeout_at(deadline, host.inner.dispatch.lock()).await
                else {
                    // Nothing was queued: the agent never sees this turn.
                    host.finish_turn(generation, &session_id, &turn_id, TurnOutcome::Failed {
                        message: "the agent is not accepting input; the message was not sent"
                            .to_string(),
                    });
                    return;
                };
                let checked = tokio::time::timeout_at(
                    deadline,
                    host.recheck_native_writer(&session_id, generation),
                )
                .await;
                if !matches!(checked, Ok(Ok(()))) {
                    host.finish_turn(generation, &session_id, &turn_id, TurnOutcome::Failed {
                        message: "Writer ownership could not be confirmed; the message was not \
                                  sent"
                            .into(),
                    });
                    return;
                }
                if !host.mark_dispatched(generation, &session_id, &turn_id) {
                    // Cancelled before it was sent (or the generation is
                    // gone): the agent never sees this turn.
                    host.finish_turn(generation, &session_id, &turn_id, TurnOutcome::Cancelled);
                    return;
                }
                let mut params = json!({"sessionId": session_id, "prompt": blocks});
                if grok {
                    // Grok's queue and turn events then name this turn.
                    params["_meta"] = json!({"promptId": turn_id});
                }
                peer.send_request("session/prompt", params, Some(deadline))
                    .await
            };
            // Only a prompt the agent received in full waits for its answer
            // without limit.
            let answer = match call {
                Ok(call) => call.wait(None).await,
                Err(error) => Err(error),
            };
            let outcome = match answer {
                Ok(result) => TurnOutcome::from_prompt_result(&result),
                Err(CallError::Closed) => TurnOutcome::AgentExited,
                Err(CallError::Rpc(error)) if error.code == RpcError::AUTH_REQUIRED => {
                    host.note_auth_required(generation);
                    TurnOutcome::Failed {
                        message: HostError::AuthRequired.to_string(),
                    }
                },
                Err(CallError::Rpc(error)) => TurnOutcome::Failed {
                    message: clip(&error.message, 300),
                },
                // Possibly half-written: the peer closed the connection.
                Err(CallError::Timeout) if peer.is_closed() => TurnOutcome::Failed {
                    message: "the agent stopped reading its input; the connection was closed"
                        .to_string(),
                },
                Err(CallError::Timeout) => TurnOutcome::Failed {
                    message: "the agent is not reading its input; the message was not sent"
                        .to_string(),
                },
                Err(error) => TurnOutcome::Failed {
                    message: error.to_string(),
                },
            };
            host.finish_turn(generation, &session_id, &turn_id, outcome);
        });
        Ok(turn)
    }

    /// Mark `turn` as dispatched unless it was cancelled or ended. Called
    /// with the dispatch lane held.
    fn mark_dispatched(&self, generation: u64, session: &str, turn: &str) -> bool {
        let mut state = self.state();
        if state.generation != generation {
            return false;
        }
        let Some(active) = state
            .sessions
            .get_mut(session)
            .and_then(|entry| entry.active.as_mut())
            .filter(|active| active.id == turn)
        else {
            return false;
        };
        if active.cancel_requested {
            return false;
        }
        active.dispatched = true;
        state.session_event(session);
        true
    }

    pub(super) fn finish_turn(
        &self,
        generation: u64,
        session: &str,
        turn: &str,
        outcome: TurnOutcome,
    ) {
        let (leftovers, peer) = {
            let mut state = self.state();
            if state.generation != generation {
                return;
            }
            let Some(leftovers) = state.end_turn(session, turn, outcome) else {
                return;
            };
            // Controllers cache the session state, which named this turn as
            // running: tell them it no longer does.
            state.session_event(session);
            if state
                .negotiated
                .as_ref()
                .is_some_and(|negotiated| negotiated.capabilities.grok)
            {
                super::grok::adopt_native_turn(&mut state, session);
            }
            (leftovers, state.peer.clone())
        };
        if let Some(peer) = peer {
            for permission in leftovers {
                let answer = permission.withdrawn();
                peer.respond_now_until(
                    permission.acp_id,
                    Ok(answer),
                    Instant::now() + self.budgets().control,
                );
            }
        }
    }

    /// Whether `turn` of `session` is still running and was dispatched in
    /// `generation`.
    pub(super) fn dispatched(&self, generation: u64, session: &str, turn: &str) -> bool {
        let state = self.state();
        state.generation == generation
            && state
                .sessions
                .get(session)
                .and_then(|entry| entry.active.as_ref())
                .is_some_and(|active| active.id == turn && active.dispatched)
    }

    /// Cancel the running turn of `session`. With `expected_turn` (and
    /// `expected`) only that turn is cancelled; a different or finished turn
    /// — or another host or generation — is left alone. Pending permissions
    /// of that turn are answered `cancelled`; `session/cancel` is written
    /// under the dispatch lane only while that turn still runs, so it can
    /// never follow a newer turn's prompt (see the module docs). The turn
    /// ends when the agent answers. `true` when a turn was (or already is)
    /// being cancelled.
    ///
    /// One control budget covers the lane and every write. If it runs out
    /// the generation is closed (see the module docs) and this fails; the
    /// turn then ends with the generation, so a retry reports `false`.
    pub async fn cancel(
        &self,
        session: &str,
        expected_turn: Option<&str>,
        expected: Option<&Identity>,
    ) -> Result<bool, HostError> {
        valid_id(session)?;
        let deadline = Instant::now() + self.budgets().control;
        let (generation, peer, _) = self.ready()?;
        if !self.is_current(expected, generation) {
            return Ok(false);
        }
        let turn = {
            let mut state = self.state();
            if state.generation != generation {
                return Ok(false);
            }
            let Some(entry) = state.sessions.get_mut(session) else {
                return Err(HostError::UnknownSession);
            };
            let Some(active) = entry.active.as_mut() else { return Ok(false) };
            if expected_turn.is_some_and(|expected| expected != active.id) {
                return Ok(false);
            }
            if active.cancel_requested {
                return Ok(true);
            }
            // Set before the lane: a dispatch that has not checked yet then
            // never sends the prompt.
            active.cancel_requested = true;
            let turn = active.id.clone();
            state.session_event(session);
            turn
        };
        let mut incomplete = peer.abandon_on_drop();
        let Ok(_lane) = tokio::time::timeout_at(deadline, self.inner.dispatch.lock()).await else {
            // The lane is held by a write the agent is not reading: the
            // cancel cannot be delivered, and the turn may not be left
            // looking cancelled on a live connection.
            peer.abandon();
            return Err(HostError::Timeout);
        };
        // This turn's pending permission requests are answered `cancelled`
        // (the spec requires it), within the same budget.
        let withdrawn: Vec<Permission> = {
            let mut state = self.state();
            if state.generation != generation {
                incomplete.disarm();
                return Ok(true);
            }
            let handles: Vec<String> = state
                .permissions
                .iter()
                .filter(|(_, p)| p.session == session && p.turn == turn)
                .map(|(handle, _)| handle.clone())
                .collect();
            handles
                .iter()
                .filter_map(|handle| state.resolve(handle, "cancelled"))
                .collect()
        };
        for permission in withdrawn {
            let delivered = peer
                .respond(permission.acp_id.clone(), Ok(permission.withdrawn()), deadline)
                .await;
            self.control_outcome(generation, &peer, delivered)?;
        }
        if !self.dispatched(generation, session, &turn) {
            // Never sent (it ends as cancelled when its dispatch runs), or
            // already over: nothing for the agent to cancel.
            incomplete.disarm();
            return Ok(true);
        }
        #[cfg(test)]
        self.pause_before_cancel().await;
        let delivered = peer
            .notify("session/cancel", json!({"sessionId": session}), deadline)
            .await;
        self.control_outcome(generation, &peer, delivered)?;
        incomplete.disarm();
        Ok(true)
    }

    #[cfg(test)]
    async fn pause_before_cancel(&self) {
        let pause = lock(&self.inner.cancel_pause).clone();
        if let Some((reached, resume)) = pause {
            reached.wait().await;
            resume.wait().await;
        }
    }

    /// Answer permission `handle` with `option_id`. An option the request did
    /// not offer is rejected and the request stays pending; the first valid
    /// answer wins and later ones see [`HostError::AlreadyResolved`]. An
    /// answer that cannot be delivered within the control budget closes the
    /// generation (see the module docs): a consumed request is never left
    /// unanswered on a live connection.
    pub async fn answer_permission(&self, handle: &str, option_id: &str) -> Result<(), HostError> {
        valid_id(handle)?;
        let deadline = Instant::now() + self.budgets().control;
        let (permission, peer, generation) = {
            let mut state = self.state();
            let Some(pending) = state.permissions.get(handle) else {
                return Err(if state.was_resolved(handle) {
                    HostError::AlreadyResolved
                } else {
                    HostError::UnknownPermission
                });
            };
            if !pending
                .options
                .iter()
                .any(|option| option.option_id == option_id)
            {
                return Err(HostError::InvalidOption);
            }
            let peer = state.peer.clone().ok_or(HostError::NotReady)?;
            let generation = state.generation;
            let permission = state
                .resolve(handle, "selected")
                .ok_or(HostError::AlreadyResolved)?;
            (permission, peer, generation)
        };
        let answer = match permission.kind {
            RequestKind::PlanApproval => json!({"outcome": option_id}),
            _ => json!({"outcome": {"outcome": "selected", "optionId": option_id}}),
        };
        self.deliver_answer(generation, &peer, permission, answer, deadline)
            .await
    }

    /// Answer Grok question `handle` with `answers`: `{"q<i>": [labels]}`
    /// for every question in order, each label one of its options; an
    /// empty object skips them all. The first valid answer wins, as for a
    /// permission.
    pub async fn answer_question(&self, handle: &str, answers: &Value) -> Result<(), HostError> {
        valid_id(handle)?;
        let deadline = Instant::now() + self.budgets().control;
        let (permission, peer, generation, answer) = {
            let mut state = self.state();
            let Some(pending) = state.permissions.get(handle) else {
                return Err(if state.was_resolved(handle) {
                    HostError::AlreadyResolved
                } else {
                    HostError::UnknownPermission
                });
            };
            let RequestKind::Question(questions) = &pending.kind else {
                return Err(HostError::InvalidOption);
            };
            let answer = question_answer(questions, answers)?;
            let peer = state.peer.clone().ok_or(HostError::NotReady)?;
            let generation = state.generation;
            let permission = state
                .resolve(handle, "selected")
                .ok_or(HostError::AlreadyResolved)?;
            (permission, peer, generation, answer)
        };
        self.deliver_answer(generation, &peer, permission, answer, deadline)
            .await
    }

    /// Deliver the answer of a request already resolved here.
    async fn deliver_answer(
        &self,
        generation: u64,
        peer: &Peer,
        permission: Permission,
        answer: Value,
        deadline: Instant,
    ) -> Result<(), HostError> {
        let mut incomplete = peer.abandon_on_drop();
        let delivered = peer.respond(permission.acp_id, Ok(answer), deadline).await;
        let result = self.control_outcome(generation, peer, delivered);
        incomplete.disarm();
        result
    }
}

/// Grok's `ask_user_question` answer for `answers` (see
/// [`AgentHost::answer_question`]).
fn question_answer(questions: &[Value], answers: &Value) -> Result<Value, HostError> {
    let invalid =
        || HostError::InvalidInput("answer every question with its offered options".into());
    let given = answers.as_object().ok_or_else(invalid)?;
    if given.is_empty() {
        return Ok(json!({"outcome": "cancelled"}));
    }
    if given.len() != questions.len() {
        return Err(invalid());
    }
    let mut chosen = serde_json::Map::new();
    for (index, question) in questions.iter().enumerate() {
        let labels = given
            .get(&format!("q{index}"))
            .and_then(Value::as_array)
            .ok_or_else(invalid)?;
        let offered = |label: &str| {
            question["options"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|option| option["label"] == label)
        };
        let multiple = question["multiSelect"] == true;
        if labels.is_empty() || (!multiple && labels.len() > 1) {
            return Err(invalid());
        }
        let mut picked = Vec::with_capacity(labels.len());
        for label in labels {
            let label = label
                .as_str()
                .filter(|label| offered(label))
                .ok_or_else(invalid)?;
            picked.push(Value::from(label));
        }
        let text = question["question"].as_str().ok_or_else(invalid)?;
        chosen.insert(text.to_string(), Value::Array(picked));
    }
    Ok(json!({"outcome": "accepted", "answers": chosen}))
}
