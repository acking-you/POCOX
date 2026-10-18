//! Connecting a session to its app-server, probing endpoints and disconnecting.

use super::*;

/// Subscribe to `service_key` (materialising the local ws endpoint), open a
/// JSON-RPC client over it and run the `initialize` handshake. Idempotent: a
/// live session for the same key is reused.
pub fn connect(service_key: String, local_port: u16, transport: &Transport) -> Result<()> {
    let lifecycle = lifecycle(&service_key);
    let _guard = lifecycle.lock().unwrap_or_else(|e| e.into_inner());
    if reuse_live(&service_key) {
        return Ok(());
    }
    // No live session: drop any stale one (and its subscription) so we reconnect
    // cleanly rather than reusing a closed socket.
    disconnect_inner(&service_key);
    if let Some((addr, _)) = crate::engine::serve::local_endpoints(&service_key) {
        return establish(service_key, &addr);
    }
    // Materialise the local ws endpoint via pb-mapper (kind-agnostic subscribe).
    let sub = runtime::subscribe_service(service_key.clone(), local_port, transport)?;
    establish(service_key, &sub.local_addr)
}

/// Whether a live session already exists for `service_key`. The forwarder task
/// ends when the websocket closes (`is_finished()`), and the client's watchdog
/// clears `is_alive()` when the socket goes silent/half-open before it has even
/// closed — either means the link is dead (the service may still show
/// registered/online on the relay), so reconnect.
fn reuse_live(service_key: &str) -> bool {
    let map = sessions().lock().expect("sessions poisoned");
    map.get(service_key)
        .is_some_and(|s| !s.forwarder.is_finished() && s.client.is_alive())
}

/// Open the JSON-RPC client over `ws://<local_addr>`, run the `initialize`
/// handshake, wire the event forwarder, and record the session. Transport-
/// agnostic: the local endpoint is materialised by the caller's subscribe.
pub(super) fn establish(service_key: String, local_addr: &str) -> Result<()> {
    let ws_url = format!("ws://{local_addr}");

    let (client, mut notify_rx) = runtime::runtime().block_on(async {
        tokio::time::timeout(CONNECT_TIMEOUT, AppClient::connect(&ws_url))
            .await
            .context("app-server connect timed out")?
            .context("connecting app-server")
    })?;
    let client = Arc::new(client);

    // Handshake. The app-server rejects every other method until initialized.
    // Bounded by CONNECT_TIMEOUT so a registered-but-dead backend (relay
    // registrant alive, codex app-server gone) fails fast instead of hanging
    // the connecting UI forever.
    runtime::runtime().block_on(async {
        tokio::time::timeout(CONNECT_TIMEOUT, client.initialize("pocket-codex", true))
            .await
            .context("app-server initialize timed out")?
            .context("app-server initialize")
    })?;

    let (events_tx, _) = broadcast::channel::<AppEvent>(512);
    let forward_tx = events_tx.clone();
    let active_turns: Arc<Mutex<HashMap<String, Value>>> = Arc::new(Mutex::new(HashMap::new()));
    let turns_for_forwarder = Arc::clone(&active_turns);
    let pending_approvals: Arc<Mutex<HashMap<String, Value>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let approvals_for_forwarder = Arc::clone(&pending_approvals);
    let transcript: Arc<Mutex<LiveTranscript>> = Arc::new(Mutex::new(LiveTranscript::default()));
    let transcript_for_forwarder = Arc::clone(&transcript);
    let runtime_config: Arc<Mutex<HashMap<String, ThreadRuntimeConfig>>> =
        Arc::new(Mutex::new(HashMap::new()));
    let config_for_forwarder = Arc::clone(&runtime_config);
    let pagination = Arc::new(Mutex::new(HashMap::new()));
    let pagination_for_forwarder = Arc::clone(&pagination);
    let checkpoint_service = service_key.clone();
    let checkpoint_owner = crate::engine::session_cache::namespace(&service_key).ok();
    let forwarder = runtime::runtime().spawn(async move {
        let mut checkpoints: HashMap<String, Instant> = HashMap::new();
        let checkpoint_slots = Arc::new(tokio::sync::Semaphore::new(2));
        while let Some(inbound) = notify_rx.recv().await {
            // Learn the active turnId per thread before mapping, so interrupt
            // works even when the UI never saw the turn/started event.
            track_active_turn(&turns_for_forwarder, &inbound);
            // Capture the effective thread settings the server reports, so the
            // UI can show the runtime config even when no screen was attached
            // when the notification streamed by.
            track_runtime_config(&config_for_forwarder, &inbound);
            // Remember a permissions request's grant so its protocol-specific
            // response can be built when the user answers.
            track_pending_approval(&approvals_for_forwarder, &inbound);
            // Buffer item snapshots so a re-opened conversation can restore an
            // in-progress turn's items even though the broadcast below is
            // dropped while no UI is attached.
            let replaces_history = history_cache::replaces_history(&inbound);
            if replaces_history {
                if let Some(thread) = inbound.params.as_ref().and_then(|p| p["threadId"].as_str()) {
                    if let Ok(mut transcript) = transcript_for_forwarder.lock() {
                        transcript.remove(thread);
                    }
                }
            } else {
                buffer_item(&transcript_for_forwarder, &inbound);
            }
            invalidate_history(&pagination_for_forwarder, &inbound);
            if let Some(thread) = inbound
                .params
                .as_ref()
                .and_then(|p| p.get("threadId"))
                .and_then(Value::as_str)
            {
                let due = checkpoints
                    .get(thread)
                    .is_none_or(|at| at.elapsed() >= Duration::from_secs(1));
                if due
                    || replaces_history
                    || matches!(
                        inbound.method.as_str(),
                        "turn/completed" | "turn/failed" | "item/autoApprovalReview/completed"
                    )
                {
                    if checkpoints.len() >= 128 {
                        checkpoints.clear();
                    }
                    checkpoints.insert(thread.to_owned(), Instant::now());
                    let items = transcript_for_forwarder.lock().ok().and_then(|t| {
                        let items = t.tail(thread, 20);
                        (!items.is_empty()).then_some(items)
                    });
                    let permit = Arc::clone(&checkpoint_slots).try_acquire_owned().ok();
                    if let Some(owner) = &checkpoint_owner {
                        if (permit.is_some() && items.is_some()) || replaces_history {
                            let token = crate::engine::session_sync::live_checkpoint(
                                owner,
                                thread,
                                replaces_history,
                            );
                            let items = items.unwrap_or_default();
                            let service = checkpoint_service.clone();
                            let thread = thread.to_owned();
                            let running = turns_for_forwarder
                                .lock()
                                .is_ok_and(|t| t.contains_key(&thread));
                            tokio::task::spawn_blocking(move || {
                                let _permit = permit;
                                crate::engine::session_sync::checkpoint_live(
                                    &service, &thread, token, items, running,
                                )
                            });
                        }
                    }
                }
            }

            // Ignore send errors: no current subscribers is fine, the event
            // is simply dropped (the UI re-reads thread state on attach).
            let _ = forward_tx.send(map_event(inbound));
        }
    });

    sessions()
        .lock()
        .expect("sessions poisoned")
        .insert(service_key, Session {
            client,
            events: events_tx,
            forwarder,
            active_turns,
            runtime_config,
            pending_approvals,
            transcript,
            pagination,
        });
    Ok(())
}

/// How long a [`probe`] waits for the tunnel + handshake before declaring the
/// backend unreachable.
const PROBE_TIMEOUT: Duration = Duration::from_secs(5);

/// How long the API probe waits for its HTTP response to come back. The full
/// round-trip is local-listener → relay → the api proxy's *register*
/// side → the proxy → all the way back, plus the cold transient tunnel's TLS
/// handshakes. For a proxy hosted on a remote server that easily exceeds
/// [`PROBE_TIMEOUT`], which made a perfectly reachable API service read as
/// "unreachable" until you actually subscribed. Give the read a generous
/// budget; a genuinely dead (hollow) registration still fails fast on
/// connection reset.
const API_PROBE_READ_TIMEOUT: Duration = Duration::from_secs(15);

/// How long [`connect`] waits for the tunnel + `initialize` handshake before
/// failing, so opening a registered-but-dead app-server errors fast instead of
/// hanging the UI on "connecting".
const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);

/// Probe whether the app-server behind `service_key` is actually REACHABLE —
/// not merely *registered* on the relay.
///
/// A `pb-register` worker stays registered (so the relay lists the key, and the
/// UI would call it "online") even when the codex app-server it forwards to has
/// died — the registration is a hollow shell. This verifies the real backend by
/// opening a transient pb-mapper tunnel and performing the `initialize`
/// handshake (bounded by [`PROBE_TIMEOUT`] so a dead backend can't hang it),
/// then tearing the tunnel down. A live session counts as reachable.
///
/// Returns the failure REASON (`None` when reachable) rather than a bare bool:
/// a far end that answered and refused the handshake needs a different remedy
/// from one that is simply down, and the UI can only say so if the transport's
/// own words survive this far.
pub fn probe_reason(service_key: String, local_port: u16, transport: &Transport) -> Option<String> {
    if is_connected(&service_key) {
        return None;
    }
    // Subscribe through a TRANSIENT tunnel that isn't in the shared registry,
    // so this probe can never reuse a real connection's tunnel nor abort it on
    // teardown — a `connect`/`appConnect` racing this probe for the same
    // service key keeps its own separate entry.
    let (local_addr, handle) =
        match runtime::subscribe_transient(service_key.clone(), local_port, transport) {
            Ok(v) => v,
            // The tunnel itself never came up: a relay problem, which is a
            // different failure from "the tunnel opened and the far end said no".
            Err(e) => return Some(format!("{e:#}")),
        };
    let reason = probe_endpoint_error(&local_addr);
    // Tear down ONLY this probe's own transient tunnel.
    handle.close();
    reason
}

/// Open a transient JSON-RPC client over `ws://<local_addr>` and run the
/// `initialize` handshake, bounded by [`PROBE_TIMEOUT`]; `true` iff it
/// succeeds.
///
/// `local_addr` is a plain `host:port` this process can reach directly. For a
/// service THIS machine hosts itself, pass its loopback app-listen address to
/// health-check the backend with no relay hop — initialized thread RPCs, so a
/// wedged or half-open codex (port still `accept`ing but never answering RPC)
/// reads `false` where a bare TCP-connect check would falsely read "online".
pub fn probe_endpoint(local_addr: &str) -> bool {
    probe_endpoint_error(local_addr).is_none()
}

/// Why a probe failed, or `None` when it succeeded.
///
/// [`probe_endpoint`] collapses every failure to `false`, which left the UI
/// with nothing to say beyond "the app-server did not respond" — wrong, and
/// unhelpful, when the tunnel actually answered and REFUSED us (a relay that
/// rejects the handshake, e.g. a missing or stale authentication code, is the
/// common case).
pub fn probe_endpoint_error(local_addr: &str) -> Option<String> {
    runtime::runtime()
        .block_on(pocket_codex_codex::readiness::probe_rpc(
            &format!("ws://{local_addr}"),
            PROBE_TIMEOUT,
        ))
        .err()
        .map(|error| format!("{error:#}"))
}
/// Reachability of a remote API proxy: a transient tunnel plus a minimal HTTP
/// request. The HTTP counterpart of [`probe_reason`], as a bare bool because an
/// API proxy has no handshake whose failure would need explaining.
pub fn probe_api(service_key: String, transport: &Transport) -> bool {
    let Ok((local_addr, handle)) = runtime::subscribe_transient(service_key, 0, transport) else {
        return false;
    };
    let ok = probe_http_endpoint(&local_addr);
    handle.close();
    ok
}

/// Connect to a local TCP endpoint tunnelling to a remote API proxy and check
/// it answers a minimal HTTP request within [`PROBE_TIMEOUT`]. A request to a
/// non-`/v1/responses` path hits the proxy's local 403 fallback (no upstream
/// model call), so ANY HTTP response proves the proxy is reachable; a
/// connect/read timeout means the relay registration is hollow.
///
/// `local_addr` may be a loopback proxy address this machine hosts itself, to
/// health-check it directly with no relay hop.
pub fn probe_http_endpoint(local_addr: &str) -> bool {
    use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
    runtime::runtime().block_on(async {
        let Ok(Ok(mut stream)) =
            tokio::time::timeout(PROBE_TIMEOUT, tokio::net::TcpStream::connect(local_addr)).await
        else {
            return false;
        };
        let req =
            b"GET /pocket-codex-probe HTTP/1.0\r\nHost: localhost\r\nConnection: close\r\n\r\n";
        if stream.write_all(req).await.is_err() {
            return false;
        }
        let mut buf = [0u8; 16];
        matches!(
            tokio::time::timeout(API_PROBE_READ_TIMEOUT, stream.read(&mut buf)).await,
            Ok(Ok(n)) if n > 0
        )
    })
}

/// Whether a *live* session exists for `service_key` (the websocket forwarder
/// is still running AND the client's watchdog still considers the socket
/// alive). A session whose socket has closed OR gone silent/half-open reports
/// `false` so the UI reconnects instead of showing a dead connection as
/// "connected" (and hanging the next turn until it times out).
pub fn is_connected(service_key: &str) -> bool {
    sessions()
        .lock()
        .expect("sessions poisoned")
        .get(service_key)
        .map(|s| !s.forwarder.is_finished() && s.client.is_alive())
        .unwrap_or(false)
}

/// Connect `service_key` to an app-server this process started itself on
/// loopback `local_addr`, without the relay (the private login server of
/// `engine::codex_login`). Replaces any session under that key.
pub fn connect_local(service_key: String, local_addr: &str) -> Result<()> {
    let lifecycle = lifecycle(&service_key);
    let _guard = lifecycle.lock().unwrap_or_else(|e| e.into_inner());
    disconnect_inner(&service_key);
    establish(service_key, local_addr)
}

/// Drop the session for `service_key` and its pb-mapper subscription.
pub fn disconnect(service_key: &str) {
    let lifecycle = lifecycle(service_key);
    let _guard = lifecycle.lock().unwrap_or_else(|e| e.into_inner());
    disconnect_inner(service_key);
}

fn disconnect_inner(service_key: &str) {
    sessions()
        .lock()
        .expect("sessions poisoned")
        .remove(service_key);
    runtime::unsubscribe_service(service_key);
}
