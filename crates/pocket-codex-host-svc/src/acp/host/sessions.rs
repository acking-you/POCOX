//! Session operations: create, reopen, list, history, configuration and
//! the working directory each session is authorized for.

use super::*;

impl AgentHost {
    /// `params` with this host's session `_meta`, if it has one.
    pub(super) fn session_params(&self, mut params: Value) -> Value {
        if let Some(meta) = &self.inner.session_meta {
            params["_meta"] = Value::Object(meta.clone());
        }
        params
    }

    /// Give each session of this host the owner's MCP servers, when the
    /// agent accepts HTTP ones.
    pub fn set_session_mcp(&self, mcp: Arc<dyn crate::acp::SessionMcp>) {
        *lock(&self.inner.session_mcp) = Some(mcp);
    }

    /// A session request: `params` with this host's `_meta` and the MCP
    /// servers for `session` (`None`: being created), and what to tell the
    /// servers' owner once the agent accepted it.
    fn session_request(
        &self,
        params: Value,
        session: Option<&str>,
        caps: &AgentCapabilities,
    ) -> (Value, Option<crate::acp::mcp::Adopt>) {
        let mut params = self.session_params(params);
        let mcp = lock(&self.inner.session_mcp).clone();
        let grant = mcp
            .filter(|_| caps.mcp_http)
            .and_then(|mcp| mcp.grant(session));
        let Some(grant) = grant else {
            params["mcpServers"] = json!([]);
            return (params, None);
        };
        params["mcpServers"] = Value::Array(grant.servers);
        if let Some(meta) = grant.meta {
            crate::acp::mcp::merge(&mut params["_meta"], Value::Object(meta));
        }
        (params, grant.adopt)
    }

    fn close_session(&self, session: Option<String>, peer: &Peer, caps: &AgentCapabilities) {
        let Some(session) = session else { return };
        let mcp = lock(&self.inner.session_mcp).clone();
        if let Some(mcp) = mcp {
            mcp.closed(&session);
        }
        if !caps.close_session {
            return;
        }
        let peer = peer.clone();
        tokio::spawn(async move {
            let _ = peer
                .request("session/close", json!({"sessionId": session}), Some(CLOSE_TIMEOUT))
                .await;
        });
    }

    /// Create a session in host-validated absolute `cwd`.
    pub async fn new_session(
        &self,
        cwd: &str,
        expected: Option<&Identity>,
    ) -> Result<Value, HostError> {
        let cwd = validate_cwd(cwd).await?;
        let (generation, peer, caps) = self.ready_for(expected)?;
        if self.inner.native_history.is_some()
            && lock(&self.inner.native_claims).len() >= crate::acp::state::MAX_SESSIONS
        {
            return Err(HostError::Capacity);
        }
        let (params, adopt) = self.session_request(json!({"cwd": cwd}), None, &caps);
        let result = peer
            .request("session/new", params, Some(SESSION_TIMEOUT))
            .await
            .map_err(|error| self.call_error(generation, error))?;
        let id = result["sessionId"]
            .as_str()
            .filter(|id| !id.is_empty() && id.len() <= MAX_ID)
            .ok_or_else(|| HostError::Agent("the agent returned no session id".into()))?
            .to_string();
        self.claim_native_session(&id, generation)
            .inspect_err(|_| {
                self.close_session(Some(id.clone()), &peer, &caps);
            })?;
        let settings = SessionSettings::from_response(&result);
        let evicted = {
            let mut state = self.state();
            if state.generation != generation {
                return Err(HostError::NotReady);
            }
            if state.auth_required {
                state.auth_required = false;
                state.host_event();
            }
            if !state.transcript_room(&id)
                || (self.inner.native_history.is_some()
                    && state.sessions.len() >= crate::acp::state::MAX_SESSIONS)
            {
                drop(state);
                // Created at the agent but not admitted here: release it.
                self.close_session(Some(id), &peer, &caps);
                return Err(HostError::Capacity);
            }
            let evicted = state.admit(&id, &cwd, settings, false, false);
            state.reset_transcript(&id);
            state.session_event(&id);
            self.inner
                .persist
                .submit(|pending| pending.record(&id, &cwd, None));
            evicted
        };
        // Granted only once admitted here: dropped uncalled on any failure
        // above, the grant withdraws what it handed the agent.
        if let Some(adopt) = adopt {
            adopt(&id);
        }
        self.close_session(evicted, &peer, &caps);
        Ok(self.opened(&id, "new"))
    }

    pub(super) fn opened(&self, id: &str, mode: &str) -> Value {
        let state = self.state();
        let mut body = state.session_body(id);
        body["hostId"] = json!(self.host_id());
        body["generation"] = json!(state.generation);
        body["mode"] = json!(mode);
        body
    }

    /// The live answer for an already admitted session, if any.
    fn live_session(&self, id: &str) -> Option<Result<Value, HostError>> {
        let pending = {
            let mut state = self.state();
            let pending = state.sessions.get(id)?.pending;
            if !pending {
                state.touch(id);
            }
            pending
        };
        Some(if pending { Err(HostError::Loading) } else { Ok(self.opened(id, "live")) })
    }

    /// Reopen `id`: already admitted → live; otherwise `session/load`
    /// (history replay) when advertised, else `session/resume` (no replay).
    ///
    /// The working directory is this host's persisted one when it has one —
    /// that always wins — else the agent's own listing, canonicalized; never
    /// the caller's. The session stays pending (no prompts, no new file
    /// authority) until the agent confirms, and is revoked when it fails.
    pub async fn open_session(
        &self,
        id: &str,
        expected: Option<&Identity>,
    ) -> Result<Value, HostError> {
        valid_id(id)?;
        if !self.is_current(expected, self.state().generation) {
            return Err(HostError::Stale);
        }
        if self.inner.native_history.is_some() && !self.state().sessions.contains_key(id) {
            return Err(HostError::ReadOnly);
        }
        self.ready_for(expected)?;
        if let Some(live) = self.live_session(id) {
            return live;
        }
        let cwd = match self.inner.store.lookup(id) {
            Some(entry) => entry.cwd,
            None => {
                let listed = self.state().listed.get(id).cloned();
                let listed = listed.ok_or(HostError::UnknownSession)?;
                validate_cwd(&listed).await?
            },
        };
        if !Path::new(&cwd).is_dir() {
            return Err(HostError::InvalidInput(
                "the session's working directory no longer exists".into(),
            ));
        }
        self.reopen_session(id, &cwd, expected, None).await
    }

    pub(super) async fn reopen_session(
        &self,
        id: &str,
        cwd: &str,
        expected: Option<&Identity>,
        native_root: Option<(u32, u64)>,
    ) -> Result<Value, HostError> {
        let (generation, peer, caps) = self.ready_for(expected)?;
        let (method, mode) = if caps.load_session {
            ("session/load", "load")
        } else if caps.resume_session {
            ("session/resume", "resume")
        } else {
            return Err(HostError::NotReopenable);
        };
        let replaying = mode == "load";
        let evicted = {
            let mut state = self.state();
            if state.generation != generation {
                return Err(HostError::NotReady);
            }
            if let Some(session) = state.sessions.get(id) {
                // Admitted concurrently by another open.
                let pending = session.pending;
                drop(state);
                return if pending { Err(HostError::Loading) } else { Ok(self.opened(id, "live")) };
            }
            // The reopen holds a transcript slot from now on: refuse before
            // the agent does any work rather than exceed the pool.
            if !state.transcript_room(id)
                || (native_root.is_some()
                    && state.sessions.len() >= crate::acp::state::MAX_SESSIONS)
            {
                return Err(HostError::Capacity);
            }
            let evicted = state.admit(id, cwd, SessionSettings::default(), true, replaying);
            if replaying {
                state.reset_transcript(id);
            } else {
                // Resume restores context without replay: keep whatever
                // this host retained, and say earlier history is missing.
                state.reserve_transcript(id, true);
            }
            state.session_event(id);
            evicted
        };
        self.close_session(evicted, &peer, &caps);
        let (params, adopt) =
            self.session_request(json!({"sessionId": id, "cwd": cwd}), Some(id), &caps);
        let result = peer.request(method, params, Some(LOAD_TIMEOUT)).await;
        let result = match result {
            Ok(result) => result,
            Err(error) => {
                {
                    let mut state = self.state();
                    if state.generation == generation {
                        if native_root.is_some() {
                            if let Some(entry) = state.sessions.get_mut(id) {
                                entry.releasing = true;
                                entry.replaying = false;
                            }
                        } else {
                            state.revoke(id);
                        }
                        state.session_event(id);
                    }
                }
                return Err(self.call_error(generation, error));
            },
        };
        if native_root.is_some() && result.get("sessionId").is_some_and(|value| value != id) {
            // A different native id would be a fork, not this admission. End
            // the connection so an untracked writer cannot remain usable.
            peer.abandon();
            return Err(HostError::Agent("the agent restored a different session".into()));
        }
        if let Some(root) = native_root {
            if let Err(error) = self.verify_native_writer(id, generation, root).await {
                let mut state = self.state();
                if state.generation == generation {
                    if let Some(entry) = state.sessions.get_mut(id) {
                        entry.releasing = true;
                        entry.replaying = false;
                    }
                    state.session_event(id);
                }
                return Err(error);
            }
        }
        {
            let mut state = self.state();
            if state.generation != generation
                || !state.confirm(id, SessionSettings::from_response(&result))
            {
                return Err(HostError::NotReady);
            }
            state.session_event(id);
            // Only a title signal seen while pending changes the stored
            // title (a clear included); without one the stored title stays.
            let title = state
                .sessions
                .get(id)
                .filter(|s| s.title_reported)
                .map(|s| s.title.clone());
            self.inner
                .persist
                .submit(|pending| pending.record(id, cwd, title));
        }
        if let Some(adopt) = adopt {
            adopt(id);
        }
        Ok(self.opened(id, mode))
    }

    /// Sessions: the agent's `session/list` when advertised (paged by its
    /// opaque cursor), otherwise this host's record. Currently admitted
    /// sessions are always included on the first page.
    pub async fn list_sessions(&self, cursor: Option<String>) -> Result<Value, HostError> {
        let ready = self.ready().ok();
        let reopen = match &ready {
            Some((_, _, caps)) if caps.load_session => "load",
            Some((_, _, caps)) if caps.resume_session => "resume",
            Some(_) => "none",
            None => "unknown",
        };
        let mut listed = None;
        let mut list_error = None;
        if let Some(native) = &self.inner.native_history {
            let generation = self.state().generation;
            let result = native
                .list_sessions(cursor.as_deref(), 100)
                .await
                .map_err(|_| {
                    HostError::Agent("native session inventory is unavailable; retry".into())
                })?;
            if self.state().generation != generation {
                return Err(HostError::Stale);
            }
            listed = Some(self.accept_listing(generation, &result));
        } else if let Some((generation, peer, caps)) = &ready {
            if caps.list_sessions {
                let mut params = json!({});
                if let Some(cursor) = &cursor {
                    params["cursor"] = json!(cursor);
                }
                match peer
                    .request("session/list", params, Some(LIST_TIMEOUT))
                    .await
                {
                    Ok(result) => listed = Some(self.accept_listing(*generation, &result)),
                    Err(error) => {
                        list_error = Some(self.call_error(*generation, error).to_string());
                    },
                }
            }
        }
        let first_page = cursor.is_none();
        let (mut sessions, next_cursor, source) = match listed {
            Some((sessions, next)) => (
                sessions,
                next,
                if self.inner.native_history.is_some() { "native" } else { "agent" },
            ),
            None if !first_page => (Vec::new(), None, "host"),
            None => {
                let sessions = self
                    .inner
                    .store
                    .entries()
                    .into_iter()
                    .map(|entry| {
                        json!({
                            "sessionId": entry.session_id,
                            "cwd": entry.cwd,
                            "title": entry.title,
                            "updatedAt": entry.updated_at,
                        })
                    })
                    .collect();
                (sessions, None, "host")
            },
        };
        if first_page {
            let state = self.state();
            let mut admitted: Vec<(&String, &crate::acp::state::Session)> =
                state.sessions.iter().collect();
            admitted.sort_by(|a, b| a.0.cmp(b.0));
            for (id, session) in admitted {
                if !sessions.iter().any(|s| s["sessionId"] == **id) {
                    sessions.push(json!({
                        "sessionId": id, "cwd": session.cwd, "title": session.title,
                        "updatedAt": Value::Null,
                    }));
                }
            }
            for entry in &mut sessions {
                let id = entry["sessionId"].as_str().unwrap_or("").to_string();
                let session = state.sessions.get(&id);
                entry["live"] = json!(session.is_some_and(|s| !s.pending));
                entry["running"] = json!(session.is_some_and(|s| s.active.is_some()));
            }
        }
        Ok(json!({
            "sessions": sessions,
            "nextCursor": next_cursor,
            "source": source,
            "reopen": reopen,
            "listError": list_error,
        }))
    }

    fn accept_listing(&self, generation: u64, result: &Value) -> (Vec<Value>, Option<String>) {
        let mut out = Vec::new();
        let mut state = self.state();
        for session in result["sessions"]
            .as_array()
            .into_iter()
            .flatten()
            .take(200)
        {
            let (Some(id), Some(cwd)) = (session["sessionId"].as_str(), session["cwd"].as_str())
            else {
                continue;
            };
            if id.is_empty() || id.len() > MAX_ID || !Path::new(cwd).is_absolute() {
                continue;
            }
            if state.generation == generation {
                state.remember_listed(id, cwd);
            }
            out.push(json!({
                "sessionId": id,
                "cwd": cwd,
                "title": session["title"].as_str().map(|t| clip(t, 512)),
                "updatedAt": session["updatedAt"].as_str().map(|t| clip(t, 64)),
            }));
        }
        let next = result["nextCursor"]
            .as_str()
            .filter(|c| c.len() <= 4096)
            .map(str::to_string);
        (out, next)
    }

    /// Retained history of `session`: the turn index plus a window of turns
    /// (`turn` selects one; otherwise the newest `limit` before `before`).
    /// The answer carries the event watermark it is consistent with, so a
    /// controller can apply exactly the events that follow it.
    pub fn history(
        &self,
        session: &str,
        before: Option<&str>,
        turn: Option<&str>,
        limit: Option<usize>,
    ) -> Result<Value, HostError> {
        valid_id(session)?;
        let state = self.state();
        let Some(transcript) = state.transcript_ref(session) else {
            return Ok(json!({
                "available": false, "sessionId": session,
                "seq": state.log.last(), "generation": state.generation,
                "hostId": self.inner.host_id,
            }));
        };
        let index: Vec<Value> = transcript
            .turns
            .iter()
            .map(|t| {
                let user = t
                    .items
                    .iter()
                    .find(|i| i.kind == crate::acp::fold::ItemKind::UserMessage)
                    .map(|i| clip(&i.text, 200))
                    .unwrap_or_default();
                json!({
                    "turnId": t.id, "userText": user, "replayed": t.replayed,
                    "outcome": t.outcome, "omitted": t.omitted,
                })
            })
            .collect();
        let turns: Vec<&crate::acp::fold::Turn> = transcript.turns.iter().collect();
        let window: Vec<&crate::acp::fold::Turn> = match turn {
            Some(id) => turns.iter().copied().filter(|t| t.id == id).collect(),
            None => {
                let end = before
                    .and_then(|before| turns.iter().position(|t| t.id == before))
                    .unwrap_or(turns.len());
                let take = limit
                    .unwrap_or(DEFAULT_WINDOW_TURNS)
                    .clamp(1, MAX_WINDOW_TURNS);
                turns[end.saturating_sub(take)..end].to_vec()
            },
        };
        let has_older = window
            .first()
            .and_then(|first| turns.iter().position(|t| t.id == first.id))
            .is_some_and(|start| start > 0);
        let session_state = state.session_body(session);
        Ok(json!({
            "available": true,
            "sessionId": session,
            "truncated": transcript.truncated,
            "turns": index,
            "window": window,
            "hasOlder": has_older,
            "session": session_state,
            "seq": state.log.last(),
            "generation": state.generation,
            "hostId": self.inner.host_id,
        }))
    }

    /// Whether the settings of a usable (admitted, confirmed) session pass
    /// `check`, read in place under the state lock (released on return).
    fn settings_allow(
        &self,
        session: &str,
        check: impl FnOnce(&SessionSettings) -> bool,
    ) -> Result<bool, HostError> {
        let state = self.state();
        let entry = state
            .sessions
            .get(session)
            .ok_or(HostError::UnknownSession)?;
        if entry.pending {
            return Err(HostError::Loading);
        }
        Ok(check(&entry.settings))
    }

    /// Set a select configuration option to one of its advertised values.
    pub async fn set_config_option(
        &self,
        session: &str,
        config: &str,
        value: &str,
        expected: Option<&Identity>,
    ) -> Result<Value, HostError> {
        let _control = self.inner.session_control.lock().await;
        valid_id(session)?;
        let (generation, peer, _) = self.ready_for(expected)?;
        if !self.settings_allow(session, |settings| settings.allows_config_value(config, value))? {
            return Err(HostError::InvalidInput("that value is not offered".into()));
        }
        let result = peer
            .request(
                "session/set_config_option",
                json!({"sessionId": session, "configId": config, "value": value}),
                Some(CONFIG_TIMEOUT),
            )
            .await
            .map_err(|error| self.call_error(generation, error))?;
        let mut state = self.state();
        if state.generation != generation {
            return Err(HostError::NotReady);
        }
        if let Some(entry) = state.sessions.get_mut(session) {
            entry.settings.config_options = schema::select_options(&result["configOptions"]);
        }
        state.session_event(session);
        Ok(state.session_body(session))
    }

    /// Switch the legacy session mode to an advertised one.
    pub async fn set_mode(
        &self,
        session: &str,
        mode: &str,
        expected: Option<&Identity>,
    ) -> Result<Value, HostError> {
        let _control = self.inner.session_control.lock().await;
        valid_id(session)?;
        let (generation, peer, _) = self.ready_for(expected)?;
        if !self.settings_allow(session, |settings| settings.allows_mode(mode))? {
            return Err(HostError::InvalidInput("that mode is not offered".into()));
        }
        peer.request(
            "session/set_mode",
            json!({"sessionId": session, "modeId": mode}),
            Some(CONFIG_TIMEOUT),
        )
        .await
        .map_err(|error| self.call_error(generation, error))?;
        let mut state = self.state();
        if state.generation != generation {
            return Err(HostError::NotReady);
        }
        if let Some(entry) = state.sessions.get_mut(session) {
            entry.settings.set_current_mode(mode);
        }
        state.session_event(session);
        Ok(state.session_body(session))
    }

    /// The host-authorized working directory of `session`: one this source
    /// admitted before (persisted, never rebound — this earlier authority
    /// stays), or a confirmed admission of the current generation. A reopen
    /// still pending grants no *new* authority.
    pub fn session_dir(&self, session: &str) -> Option<String> {
        if let Some(entry) = self.inner.store.lookup(session) {
            return Some(entry.cwd);
        }
        self.state().authorized_cwd(session).map(str::to_string)
    }
}
