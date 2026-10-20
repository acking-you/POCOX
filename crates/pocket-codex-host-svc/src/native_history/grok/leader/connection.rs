//! One follower's connections to the leader, for as long as a view follows.

use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use tokio::{
    net::{unix::OwnedWriteHalf, UnixStream},
    sync::oneshot,
    time::{timeout, Instant},
};

use super::{
    super::{owners::Probe, transcript::event_seq},
    wire::{self, Frames, Payload, Server},
    State,
};

/// Pause between attempts while the session is not followed live.
const RETRY: Duration = Duration::from_millis(if cfg!(test) { 200 } else { 3000 });
/// How often a connected follower checks the terminal client's registration.
const OWNER_CHECK: Duration = Duration::from_secs(1);
/// Bound on connecting, registering and the two read-only requests.
const HANDSHAKE: Duration = Duration::from_secs(10);

/// Why a connection ended.
#[derive(Debug)]
enum End {
    /// Every view stopped following.
    Stopped,
    /// The leader does not hold the session (or no longer does).
    NotResident,
    /// No verified terminal client registers the session any more.
    OwnerGone,
    /// The leader made this follower the session's driver: its terminal
    /// client left.
    Driver,
    /// The leader shuts down.
    LeaderGone,
}

/// Follow `state`'s session until `stopped` resolves (its last view left).
pub(super) async fn run(
    state: Arc<State>,
    socket: PathBuf,
    probe: Arc<Probe>,
    mut stopped: oneshot::Receiver<()>,
) {
    loop {
        if held(&probe, &state.session).await {
            let end = follow(&state, &socket, &probe, &mut stopped).await;
            state.reset();
            match end {
                Ok(End::Stopped) => return,
                Ok(end) => tracing::debug!(?end, "Grok leader follow ended"),
                Err(error) => tracing::debug!(%error, "Grok leader follow unavailable"),
            }
        }
        tokio::select! {
            _ = &mut stopped => return,
            () = tokio::time::sleep(RETRY) => {},
        }
    }
}

/// Whether a verified Grok terminal client registers the session; an
/// unreadable registry or an unverifiable entry is no.
async fn held(probe: &Probe, session: &str) -> bool {
    probe
        .owners(session)
        .await
        .is_ok_and(|owners| !owners.is_empty())
}

async fn follow(
    state: &State,
    socket: &Path,
    probe: &Probe,
    stopped: &mut oneshot::Receiver<()>,
) -> Result<End> {
    // Connect only: a missing socket or a refused one means no leader runs,
    // and none is started here.
    let stream = timeout(HANDSHAKE, UnixStream::connect(socket))
        .await
        .context("connecting to the Grok leader timed out")?
        .context("no Grok leader is running")?;
    let (reader, mut writer) = stream.into_split();
    let mut frames = Frames::new(reader);
    let end = session(state, probe, &mut frames, &mut writer, stopped).await;
    // A clean leave; the leader also treats a closed socket as one.
    let _ = timeout(Duration::from_secs(1), wire::disconnect(&mut writer)).await;
    end
}

async fn session(
    state: &State,
    probe: &Probe,
    frames: &mut Frames<tokio::net::unix::OwnedReadHalf>,
    writer: &mut OwnedWriteHalf,
    stopped: &mut oneshot::Receiver<()>,
) -> Result<End> {
    let deadline = Instant::now() + HANDSHAKE;
    wire::register(writer).await?;
    loop {
        match timeout_at(deadline, frames.next()).await?? {
            Server::Registered {
                ready,
                leader_protocol_version,
                leader_binary_version,
            } => {
                wire::accept_registration(
                    leader_protocol_version,
                    leader_binary_version.as_deref(),
                )?;
                if ready {
                    break;
                }
            },
            Server::LeaderReady => break,
            Server::Error {
                code,
                message,
            } => bail!("the Grok leader refused ({code}): {message}"),
            Server::ShuttingDown {} | Server::Shutdown => return Ok(End::LeaderGone),
            _ => {},
        }
    }
    // Naming the session subscribes this client to it.
    wire::request(writer, wire::INFO_ID, "_x.ai/session/info", json!({"sessionId": state.session}))
        .await?;
    let mut owner_check = tokio::time::interval(OWNER_CHECK);
    loop {
        tokio::select! {
            biased;
            _ = &mut *stopped => return Ok(End::Stopped),
            // Before frames: a streaming turn keeps frames ready, and the
            // follower must still leave within a check of the registration
            // ending.
            _ = owner_check.tick() => {
                if !connected(state) && Instant::now() >= deadline {
                    bail!("the Grok leader did not answer in time");
                }
                if !held(probe, &state.session).await {
                    return Ok(End::OwnerGone);
                }
            },
            message = frames.next() => {
                let message = message?;
                if let Some(end) = on_message(state, writer, message).await? {
                    return Ok(end);
                }
            },
        }
    }
}

async fn timeout_at<F: std::future::Future>(deadline: Instant, future: F) -> Result<F::Output> {
    tokio::time::timeout_at(deadline, future)
        .await
        .context("the Grok leader did not answer in time")
}

fn connected(state: &State) -> bool {
    state
        .live
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .connected
}

async fn on_message(
    state: &State,
    writer: &mut OwnedWriteHalf,
    message: Server,
) -> Result<Option<End>> {
    let payload = match message {
        Server::Acp {
            payload,
        } => payload,
        Server::Error {
            code,
            message,
        } => bail!("the Grok leader reported ({code}): {message}"),
        Server::ShuttingDown {} | Server::Shutdown => return Ok(Some(End::LeaderGone)),
        _ => return Ok(None),
    };
    let size = payload.len();
    match wire::classify(&payload) {
        Payload::Answer {
            id,
            result,
            error,
        } if id == wire::INFO_ID => {
            // `{}` (or nothing) when the leader holds no such session.
            let resident = !error
                && result
                    .as_ref()
                    .and_then(wire::ext_result)
                    .is_some_and(|info| info.as_object().is_some_and(|o| !o.is_empty()));
            if !resident {
                return Ok(Some(End::NotResident));
            }
            wire::request(writer, wire::ROSTER_ID, "_x.ai/sessions/list", json!({})).await?;
        },
        Payload::Answer {
            id,
            result,
            ..
        } if id == wire::ROSTER_ID => {
            let entry = result
                .as_ref()
                .and_then(wire::ext_result)
                .and_then(|roster| roster["sessions"].as_array())
                .and_then(|rows| rows.iter().find(|row| row["sessionId"] == state.session))
                .filter(|row| row["resident"] == true);
            let Some(entry) = entry else { return Ok(Some(End::NotResident)) };
            let running = activity_running(&entry["activity"]);
            state.update(|live| {
                live.connected = true;
                live.running = running.or(live.running);
                live.settle(running == Some(false));
                true
            });
        },
        Payload::Answer {
            ..
        }
        | Payload::Ignored => {},
        // Never answered: the user's own client answers it.
        Payload::Interaction => state.update(|live| {
            let changed = live.running != Some(true);
            live.running = Some(true);
            changed
        }),
        Payload::DriverRequest => return Ok(Some(End::Driver)),
        Payload::Notification {
            method,
            params,
        } => {
            return Ok(on_notification(state, &method, params, size));
        },
    }
    Ok(None)
}

/// Roster activity (`agent/roster.rs` `RosterActivity`): a running turn or
/// one waiting on its user runs; idle does not; anything else is unknown.
fn activity_running(activity: &Value) -> Option<bool> {
    match activity.as_str()? {
        "working" | "needs_input" => Some(true),
        "idle" => Some(false),
        _ => None,
    }
}

fn on_notification(state: &State, method: &str, params: Value, size: usize) -> Option<End> {
    if method == "x.ai/sessions/changed" {
        if params["removed"]
            .as_array()
            .is_some_and(|ids| ids.iter().any(|id| *id == state.session))
        {
            return Some(End::NotResident);
        }
        let row = params["upserted"]
            .as_array()
            .and_then(|rows| rows.iter().find(|row| row["sessionId"] == state.session));
        if let Some(running) = row.and_then(|row| activity_running(&row["activity"])) {
            set_running(state, running);
        }
        return None;
    }
    if params["sessionId"] != state.session.as_str() {
        return None;
    }
    let update = &params["update"];
    let seq = params["_meta"]["eventId"].as_str().and_then(event_seq);
    match method {
        "session/update" => {
            // A replay belongs to another client's load, never to this one.
            let seq = seq.filter(|_| params["_meta"]["isReplay"] != true)?;
            let update = params.get("update").cloned().unwrap_or(Value::Null);
            state.update(|live| {
                live.push(seq, update, size);
                true
            });
        },
        "x.ai/queue/changed" => {
            let running = params["runningPromptId"]
                .as_str()
                .is_some_and(|id| !id.is_empty());
            set_running(state, running);
        },
        "x.ai/session_notification" | "x.ai/session/update" => {
            match update["sessionUpdate"].as_str() {
                Some("turn_completed") => set_running(state, false),
                // The log drops a rewound branch; until it holds the
                // marker, nothing live is shown.
                Some("rewind_marker") => state.update(|live| {
                    live.wait_for_log(seq.unwrap_or(u64::MAX));
                    true
                }),
                _ => {},
            }
        },
        _ => {},
    }
    None
}

fn set_running(state: &State, running: bool) {
    state.update(|live| {
        let changed = live.running != Some(running);
        live.running = Some(running);
        changed
    });
}
