//! What the agent sends: session updates and permission requests, routed to
//! the generation they belong to.

use super::*;

impl AgentHost {
    fn on_update(&self, generation: u64, params: Option<Value>) {
        let Some(params) = params else { return };
        let Some(session) = params["sessionId"].as_str().map(str::to_string) else { return };
        let update = &params["update"];
        let mut state = self.state();
        if state.generation != generation {
            return;
        }
        let signal = session_signal(update);
        if let Some(SessionSignal::Commands(commands)) = &signal {
            // The agent's commands, even for a session not admitted here
            // yet: a new session's list can arrive before its answer.
            if let Some(negotiated) = state.negotiated.as_mut() {
                if negotiated.commands != *commands {
                    negotiated.commands.clone_from(commands);
                    state.host_event();
                }
            }
        }
        let grok = state
            .negotiated
            .as_ref()
            .is_some_and(|negotiated| negotiated.capabilities.grok);
        if grok {
            super::grok::merge_held_supplements(
                &mut state,
                &session,
                params["_meta"]["streamStartMs"].as_u64(),
            );
        }
        if grok && super::grok::note_usage(&mut state, &session, &params) {
            state.session_event(&session);
        }
        let Some(entry) = state.sessions.get_mut(&session) else { return };
        let (pending, replaying) = (entry.pending, entry.replaying);
        let turn = if pending { None } else { entry.active.as_ref().map(|t| t.id.clone()) };
        if let Some(signal) = signal {
            match signal {
                SessionSignal::ConfigOptions(options) => {
                    entry.settings.config_options = options;
                },
                SessionSignal::Mode(mode) => entry.settings.set_current_mode(&mode),
                SessionSignal::Commands(commands) => entry.settings.commands = commands,
                SessionSignal::Title(Some(title)) => {
                    entry.title.clone_from(&title);
                    entry.title_reported = true;
                    // Queued under the state lock, after the admission's
                    // own record; a reopen still pending records its
                    // title — or its explicit clear — when it is confirmed.
                    if !pending {
                        self.inner
                            .persist
                            .submit(|queue| queue.title(&session, title));
                    }
                },
                SessionSignal::Title(None) => return,
                SessionSignal::Usage {
                    used,
                    size,
                } => entry.usage = Some((used, size)),
            }
            if !pending {
                state.session_event(&session);
            }
            return;
        }
        // A resume restores context without history: content that arrives
        // before it is confirmed is not part of this view.
        if pending && !replaying {
            return;
        }
        // Content outside a turn with no transcript room is dropped, and the
        // transcript then says its history is incomplete.
        if !state.reserve_transcript(&session, false) {
            return;
        }
        let changes = match state.transcript_mut(&session) {
            Some(transcript) => transcript.apply(turn.as_deref(), update),
            None => return,
        };
        if changes.is_empty() || pending {
            return;
        }
        let body = json!({
            "type": "update", "sessionId": session, "turnId": turn, "update": update,
        });
        state.event(body);
    }

    pub(super) fn on_permission(
        &self,
        generation: u64,
        peer: &Peer,
        id: RequestId,
        params: Option<Value>,
    ) {
        let Some((session, tool_call, options)) =
            params.as_ref().and_then(schema::permission_request)
        else {
            peer.respond_now(
                id,
                Err(RpcError::new(RpcError::INVALID_PARAMS, "malformed permission request")),
            );
            return;
        };
        self.admit_request(generation, peer, id, Permission {
            session,
            turn: String::new(),
            acp_id: RequestId::Number(0),
            options,
            tool_call,
            kind: RequestKind::Permission,
        });
    }

    /// Hold `request` (of the agent's request `id`) for the turn it arrived
    /// during; outside a live turn, or past the bound, it is answered
    /// withdrawn at once.
    pub(super) fn admit_request(
        &self,
        generation: u64,
        peer: &Peer,
        id: RequestId,
        request: Permission,
    ) {
        let session = request.session.clone();
        let refused = request.withdrawn();
        let mut state = self.state();
        if state.generation != generation {
            drop(state);
            peer.respond_now_until(id, Ok(refused), Instant::now() + self.budgets().control);
            return;
        }
        let known = state
            .sessions
            .get(&session)
            .map(|entry| entry.active.clone());
        let Some(turn) = known else {
            drop(state);
            peer.respond_now(id, Err(RpcError::new(RpcError::INVALID_PARAMS, "unknown session")));
            return;
        };
        let Some(turn) = turn.filter(|turn| !turn.cancel_requested) else {
            drop(state);
            // Outside a live turn, or after cancellation: the spec requires
            // `cancelled` for a cancelled turn.
            peer.respond_now_until(id, Ok(refused), Instant::now() + self.budgets().control);
            return;
        };
        if state.permissions.len() >= MAX_PERMISSIONS {
            drop(state);
            peer.respond_now_until(id, Ok(refused), Instant::now() + self.budgets().control);
            return;
        }
        let handle = uuid::Uuid::new_v4().to_string();
        let permission = Permission {
            turn: turn.id,
            acp_id: id,
            ..request
        };
        let body = State::permission_body(&handle, &permission);
        state.permissions.insert(handle, permission);
        state.event(body);
    }
}

/// Routes the agent's requests and notifications into the host. Holds the
/// generation it was created for; anything arriving for another one is
/// ignored (or answered `cancelled`).
pub(super) struct AgentInbound {
    pub(super) host: Weak<Inner>,
    pub(super) generation: u64,
}

impl AgentInbound {
    pub(super) fn host(&self) -> Option<AgentHost> {
        self.host.upgrade().map(|inner| AgentHost {
            inner,
        })
    }
}

impl Inbound for AgentInbound {
    fn notification(&self, _peer: &Peer, method: &str, params: Option<Value>) {
        let Some(host) = self.host() else { return };
        match method {
            "session/update" => host.on_update(self.generation, params),
            super::grok::QUEUE_CHANGED if host.negotiated_grok() => {
                host.on_grok_queue(self.generation, params);
            },
            super::grok::SESSION_NOTIFICATION if host.negotiated_grok() => {
                host.on_grok_notification(self.generation, params);
            },
            _ => {},
        }
    }

    fn request(&self, peer: &Peer, id: RequestId, method: &str, params: Option<Value>) {
        match (method, self.host()) {
            ("session/request_permission", Some(host)) => {
                host.on_permission(self.generation, peer, id, params);
            },
            (super::grok::PLAN_APPROVAL | super::grok::QUESTION, Some(host))
                if host.negotiated_grok() =>
            {
                host.on_grok_request(self.generation, peer, id, method, params);
            },
            // File system, terminal and elicitation methods are not
            // advertised and not implemented; nothing is read or run.
            _ => peer.respond_now(
                id,
                Err(RpcError::new(
                    RpcError::METHOD_NOT_FOUND,
                    "method not supported by this client",
                )),
            ),
        }
    }
}

#[async_trait::async_trait]
impl crate::file_links::SessionDirResolver for AgentHost {
    async fn session_dir(&self, session: &str) -> anyhow::Result<Option<String>> {
        Ok(AgentHost::session_dir(self, session))
    }
}
