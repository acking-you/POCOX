//! Process lifecycle: create, launch, supervise, recover, restart and stop
//! a generation, all under the one lifecycle lock (see the parent module
//! docs).

use super::*;

/// Close the connection and clean up the owned process (see the module
/// docs for the order).
async fn dispose(peer: Peer, process: AgentProcess) {
    peer.shutdown(WRITER_GRACE).await;
    peer.wait_output_closed(OUTPUT_GRACE).await;
    process.terminate(TERM_GRACE).await;
    peer.abort_reader();
}

/// The host's single exit handler: one generation at a time, in order.
async fn supervise(host: Weak<Inner>, mut closures: mpsc::UnboundedReceiver<(u64, &'static str)>) {
    while let Some((generation, reason)) = closures.recv().await {
        let Some(inner) = host.upgrade() else { return };
        AgentHost {
            inner,
        }
        .recover(generation, reason)
        .await;
    }
}

/// Why a generation ended on its own, for its phase.
fn end_reason(closed: Option<CloseReason>) -> &'static str {
    match closed {
        Some(CloseReason::Stalled) => "the agent stopped reading its input",
        Some(CloseReason::Protocol) => "the agent broke the ACP protocol",
        _ => "the agent exited",
    }
}

/// Resolves once the leader `pid` exited (without reaping it).
async fn leader_exit(pid: Option<u32>) {
    let Some(pid) = pid else { return std::future::pending().await };
    loop {
        tokio::time::sleep(EXIT_POLL).await;
        if process::leader_exited(pid) {
            return;
        }
    }
}
impl AgentHost {
    /// Create the host and launch its first generation. The host exists even
    /// when the launch fails, so its status can explain the failure and a
    /// restart can be requested.
    pub async fn start(options: HostOptions) -> (Self, Result<(), HostError>) {
        let host = Self::create(options);
        let launched = host.launch().await;
        (host, launched)
    }

    /// Create the host without launching the agent (see [`AgentHost::launch`]),
    /// so an owner can register it — and stop it — before the launch begins.
    /// Must run inside a Tokio runtime.
    pub fn create(options: HostOptions) -> Self {
        Self::create_parts(options, None, None, None)
    }

    /// [`AgentHost::create`], launching `program` with `args` instead of the
    /// spec's arguments: e.g. an interpreter running the agent's script
    /// before the spec's own arguments (see [`super::super::claude`]). The
    /// spec stays what the user chose.
    pub fn create_launching(options: HostOptions, args: Vec<String>) -> Self {
        Self::create_parts(options, Some(args), None, None)
    }

    /// [`AgentHost::create`] (or [`AgentHost::create_launching`] with
    /// `launch_args`), adding `session_meta` as the `_meta` of every
    /// `session/new`, `session/load` and `session/resume` request: an
    /// instance's provider route for agents that read one there (see
    /// [`super::super::provider`]).
    pub fn create_configured(
        options: HostOptions,
        launch_args: Option<Vec<String>>,
        session_meta: Option<serde_json::Map<String, Value>>,
    ) -> Self {
        Self::create_parts(options, launch_args, session_meta, None)
    }

    /// Create a host with an independent native reader (Claude or Grok).
    /// Unadmitted sessions are browsed read-only rather than implicitly
    /// loaded into the agent.
    pub fn create_with_native_history(
        options: HostOptions,
        launch_args: Option<Vec<String>>,
        session_meta: Option<serde_json::Map<String, Value>>,
        history: Option<crate::native_history::NativeHistory>,
    ) -> Self {
        Self::create_parts(options, launch_args, session_meta, history)
    }

    fn create_parts(
        options: HostOptions,
        launch_args: Option<Vec<String>>,
        session_meta: Option<serde_json::Map<String, Value>>,
        native_history: Option<crate::native_history::NativeHistory>,
    ) -> Self {
        let (closed, closures) = mpsc::unbounded_channel();
        let store = Arc::new(options.store);
        let apply: Apply = {
            let store = store.clone();
            Arc::new(move |changes: Vec<Change>| store.apply(&changes))
        };
        let host = Self {
            inner: Arc::new(Inner {
                host_id: uuid::Uuid::new_v4().to_string(),
                spec: options.spec,
                program: options.program,
                launch_args,
                session_meta,
                session_mcp: Mutex::new(None),
                path: options.path,
                env: options.env,
                env_remove: options.env_remove,
                store,
                native_history,
                native_claims: Mutex::new(HashMap::new()),
                released_here: Mutex::new(HashMap::new()),
                persist: Persist::spawn(apply),
                state: Mutex::new(State::default()),
                lifecycle: tokio::sync::Mutex::new(None),
                dispatch: tokio::sync::Mutex::new(()),
                session_control: tokio::sync::Mutex::new(()),
                stopping: watch::channel(false).0,
                restarts: Mutex::new(VecDeque::new()),
                budgets: Mutex::new(Budgets::default()),
                closed,
                #[cfg(test)]
                cancel_pause: Mutex::new(None),
            }),
        };
        // Holds only a weak reference: the supervisor never keeps a host
        // alive, and ends once the host and every watcher are gone.
        tokio::spawn(supervise(Arc::downgrade(&host.inner), closures));
        host
    }

    /// Launch the first generation of a [created](AgentHost::create) host.
    pub async fn launch(&self) -> Result<(), HostError> {
        let mut slot = self.inner.lifecycle.lock().await;
        if slot.is_some() {
            return Ok(());
        }
        self.launch_locked(&mut slot).await
    }

    async fn launch_locked(&self, slot: &mut Option<Running>) -> Result<(), HostError> {
        if self.stopping() {
            return Err(HostError::NotReady);
        }
        let generation = self.state().begin_generation();
        let removed: Vec<&str> = self.inner.env_remove.iter().map(String::as_str).collect();
        let spawned = match process::spawn_without(
            &self.inner.program,
            self.inner
                .launch_args
                .as_deref()
                .unwrap_or(&self.inner.spec.args),
            self.inner.path.as_ref(),
            &self.inner.env,
            &removed,
        ) {
            Ok(spawned) => spawned,
            Err(error) => {
                let reason = error.to_string();
                self.fail(generation, &reason);
                return Err(HostError::Start(reason));
            },
        };
        let leader = spawned.process.id();
        let inbound = Arc::new(AgentInbound {
            host: Arc::downgrade(&self.inner),
            generation,
        });
        let peer = Peer::spawn(spawned.stdout, spawned.stdin, inbound);
        let handshake = peer.request("initialize", schema::initialize_params(), Some(INIT_TIMEOUT));
        let mut stopping = self.inner.stopping.subscribe();
        let negotiated = tokio::select! {
            answer = handshake => match answer {
                Ok(result) => schema::negotiate(&result).map_err(|error| error.to_string()),
                Err(CallError::Timeout) => {
                    Err("the agent did not complete the ACP handshake in time".to_string())
                },
                Err(CallError::Rpc(error)) => Err(format!(
                    "the agent refused the ACP handshake: {}",
                    clip(&error.message, 200)
                )),
                Err(_) => Err("the agent exited during the ACP handshake".to_string()),
            },
            () = leader_exit(leader) => Err("the agent exited during the ACP handshake".to_string()),
            // A stop never waits for a slow handshake.
            _ = stopping.wait_for(|stop| *stop) => Err("hosting was stopped".to_string()),
        };
        let negotiated = match negotiated {
            Ok(negotiated) => negotiated,
            Err(reason) => {
                dispose(peer, spawned.process).await;
                self.fail(generation, &reason);
                return Err(HostError::Start(reason));
            },
        };
        let published = {
            let mut state = self.state();
            if state.generation == generation && !self.stopping() {
                state.phase = Phase::Ready;
                state.negotiated = Some(negotiated);
                state.peer = Some(peer.clone());
                state.auth_required = false;
                state.host_event();
                true
            } else {
                false
            }
        };
        if !published {
            dispose(peer, spawned.process).await;
            return Err(HostError::NotReady);
        }
        // Report the end of this generation to the supervisor — the
        // connection closed, or the leader exited while something else keeps
        // its output open. Never handled here, so this task neither holds the
        // host alive nor re-enters the lifecycle. Aborted before any reap.
        let watcher = tokio::spawn({
            let closed = self.inner.closed.clone();
            let peer = peer.clone();
            async move {
                let reason = tokio::select! {
                    reason = peer.closed() => Some(reason),
                    () = leader_exit(leader) => None,
                };
                let _ = closed.send((generation, end_reason(reason)));
            }
        });
        *slot = Some(Running {
            generation,
            peer,
            process: spawned.process,
            watcher,
        });
        Ok(())
    }

    fn fail(&self, generation: u64, reason: &str) {
        let mut state = self.state();
        if state.generation == generation {
            state.phase = if self.stopping() {
                Phase::Stopped
            } else {
                Phase::Failed {
                    reason: reason.to_string(),
                }
            };
            state.host_event();
        }
    }

    async fn teardown(&self, running: Running, phase: Phase) {
        self.state().invalidate(running.generation, phase);
        dispose(running.peer, running.process).await;
        self.release_stopped_claims(running.generation).await;
    }

    /// Generation `generation` ended on its own (exit, crash, protocol
    /// violation). Runs only on the supervisor task: tear the generation
    /// down unless a stop or restart already owns it, then relaunch while
    /// the bounded restart budget allows. A stop or manual restart during
    /// the delay wins: relaunching requires that nothing is running and the
    /// phase is still `Failed`.
    async fn recover(&self, generation: u64, reason: &str) {
        {
            let mut slot = self.inner.lifecycle.lock().await;
            let Some(running) = slot.take_if(|running| running.generation == generation) else {
                return;
            };
            self.teardown(running, Phase::Failed {
                reason: reason.into(),
            })
            .await;
        }
        while self.allow_restart() {
            tokio::time::sleep(RESTART_DELAY).await;
            let mut slot = self.inner.lifecycle.lock().await;
            let failed = matches!(self.state().phase, Phase::Failed { .. });
            if slot.is_some() || !failed || self.stopping() {
                return;
            }
            if self.launch_locked(&mut slot).await.is_ok() {
                return;
            }
        }
    }

    fn allow_restart(&self) -> bool {
        let mut restarts = lock(&self.inner.restarts);
        let now = std::time::Instant::now();
        while restarts
            .front()
            .is_some_and(|at| now.duration_since(*at) > RESTART_WINDOW)
        {
            restarts.pop_front();
        }
        if restarts.len() >= MAX_RESTARTS {
            return false;
        }
        restarts.push_back(now);
        true
    }

    /// Stop the agent and clean up its process tree, for good: a launch
    /// still negotiating is cut short and none starts afterwards. Bounded —
    /// pending session-record writes get [`FLUSH_GRACE`]. Idempotent.
    pub async fn stop(&self) {
        self.inner.stopping.send_replace(true);
        let mut slot = self.inner.lifecycle.lock().await;
        match slot.take() {
            Some(running) => {
                running.watcher.abort();
                self.teardown(running, Phase::Stopped).await;
            },
            None => {
                let mut state = self.state();
                if state.phase != Phase::Stopped {
                    state.phase = Phase::Stopped;
                    state.host_event();
                }
            },
        }
        drop(slot);
        if !self.inner.persist.flush(FLUSH_GRACE).await {
            tracing::warn!("saving the ACP session record did not finish while stopping");
        }
    }

    /// Stop (when running) and launch a fresh generation. Refused once the
    /// host was stopped.
    pub async fn restart(&self) -> Result<(), HostError> {
        if self.stopping() {
            return Err(HostError::NotReady);
        }
        let mut slot = self.inner.lifecycle.lock().await;
        if let Some(running) = slot.take() {
            running.watcher.abort();
            self.teardown(running, Phase::Starting).await;
        }
        lock(&self.inner.restarts).clear();
        self.launch_locked(&mut slot).await
    }
}
