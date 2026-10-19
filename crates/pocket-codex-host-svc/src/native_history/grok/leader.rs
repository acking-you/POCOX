//! Read-only live following of a session that one of Grok's terminal
//! clients runs through Grok's leader (`xai-grok-shell/src/leader/`).
//!
//! A terminal client in leader mode is a stdio client of the leader process
//! that hosts the agent, on `$GROK_HOME/leader.sock`. The leader subscribes
//! any client that sends a message naming a session, fans that session's
//! notifications out to every subscriber, and sends its interaction requests
//! (tool permission, question, plan approval, MCP elicitation) to every
//! subscriber, first answer wins (`leader/server.rs`).
//!
//! A follower only connects to a leader that already runs (never
//! `connect_or_spawn`), and only while a verified terminal client registers
//! the session in `active_sessions.json`. It registers as a stdio client
//! with no capabilities and sends exactly two read-only requests:
//! `_x.ai/session/info` naming the session, which subscribes it (an empty
//! answer means the leader does not hold the session), then
//! `_x.ai/sessions/list` for its activity. It never sends `initialize`,
//! `session/load` or a prompt: a load re-applies the loading client's MCP
//! servers, model, status line and echo flags to the shared session. It
//! never answers a request, so the user's own client answers every
//! interaction; a request only the session's driver receives means the
//! terminal client has gone, and the follower leaves at once.
//!
//! While a follower stays subscribed after the terminal client leaves, the
//! leader keeps the session loaded; the follower checks the registration
//! every second and leaves when it ends, which lets the leader unload the
//! session as it would have when the client left. Being the last stdio
//! client to send a message also makes the follower the leader's fallback
//! for notifications that name no session until the terminal client sends
//! its next one.
//!
//! Only Unix sockets are followed; on Windows (named pipes) nothing
//! connects and views keep polling the log.
#![cfg_attr(not(unix), allow(dead_code))]

use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, Mutex, Weak},
};

use serde_json::Value;
use tokio::sync::{oneshot, watch};

use super::{owners::Probe, transcript::LiveTail};

#[cfg(unix)]
mod connection;
#[cfg(unix)]
mod wire;

/// Most live updates kept for one session.
const MAX_TAIL_UPDATES: usize = 4096;
/// Most live update bytes kept for one session.
const MAX_TAIL_BYTES: usize = 16 * 1024 * 1024;
/// A larger single update is not kept; the overlay waits for the log.
const MAX_UPDATE_BYTES: usize = 4 * 1024 * 1024;

/// Interest in one session's live changes. Dropping the last one for a
/// session leaves the leader.
pub struct NativeFollow {
    _interest: Arc<Interest>,
    changes: watch::Receiver<u64>,
}

impl NativeFollow {
    /// Wait for the next change: live content, running state, or the live
    /// follow starting or ending. `false` once nothing follows any more.
    pub async fn changed(&mut self) -> bool {
        self.changes.changed().await.is_ok()
    }

    /// The next change of an optional follow; pending forever without one,
    /// so a poll beside it decides. A follow that ended is dropped.
    pub async fn next(follow: &mut Option<Self>) -> bool {
        if let Some(live) = follow {
            if live.changed().await {
                return true;
            }
        }
        *follow = None;
        std::future::pending().await
    }
}

/// What the live follow of a session knows now.
pub(super) struct Snapshot {
    /// Changes with every live update and state change.
    pub version: u64,
    /// Whether a turn runs there; `None` when the leader has not said.
    pub running: Option<bool>,
    pub tail: LiveTail,
}

/// The live follows of one Grok home.
pub(super) struct Follows {
    socket: PathBuf,
    probe: Arc<Probe>,
    sessions: Mutex<HashMap<String, Weak<Interest>>>,
}

struct Interest {
    state: Arc<State>,
    /// Dropped with the last [`NativeFollow`], which stops the follow.
    _stop: oneshot::Sender<()>,
}

struct State {
    session: String,
    live: Mutex<Live>,
    changes: watch::Sender<u64>,
}

#[derive(Default)]
struct Live {
    /// Subscribed, with the session resident in the leader.
    connected: bool,
    running: Option<bool>,
    /// The log sequence the overlay waits for ([`LiveTail::through`]);
    /// unknown until the roster answered and, mid-turn, an update arrived.
    through: Option<u64>,
    /// Whether the roster answered, and the first sequence received.
    settled: bool,
    first: Option<u64>,
    updates: std::collections::VecDeque<(u64, Value, usize)>,
    bytes: usize,
}

impl Follows {
    pub(super) fn new(home: &std::path::Path, probe: Arc<Probe>) -> Self {
        Self {
            // The default leader of this home. A leader started for another
            // relay URL (`leader-<hash>.sock`) or at `GROK_LEADER_SOCKET`
            // serves another environment and is not followed.
            socket: home.join("leader.sock"),
            probe,
            sessions: Mutex::new(HashMap::new()),
        }
    }

    /// Join or start the live follow of `session`, within a Tokio runtime.
    pub(super) fn follow(&self, session: &str) -> NativeFollow {
        let mut sessions = self.sessions.lock().unwrap_or_else(|p| p.into_inner());
        sessions.retain(|_, interest| interest.strong_count() > 0);
        if let Some(interest) = sessions.get(session).and_then(Weak::upgrade) {
            let changes = interest.state.changes.subscribe();
            return NativeFollow {
                _interest: interest,
                changes,
            };
        }
        let (changes, receiver) = watch::channel(0);
        let state = Arc::new(State {
            session: session.to_owned(),
            live: Mutex::new(Live::default()),
            changes,
        });
        let (stop, stopped) = oneshot::channel();
        let interest = Arc::new(Interest {
            state: state.clone(),
            _stop: stop,
        });
        sessions.insert(session.to_owned(), Arc::downgrade(&interest));
        self.spawn(state, stopped);
        NativeFollow {
            _interest: interest,
            changes: receiver,
        }
    }

    #[cfg(unix)]
    fn spawn(&self, state: Arc<State>, stopped: oneshot::Receiver<()>) {
        tokio::spawn(connection::run(state, self.socket.clone(), self.probe.clone(), stopped));
    }

    #[cfg(not(unix))]
    fn spawn(&self, _state: Arc<State>, _stopped: oneshot::Receiver<()>) {}

    fn state(&self, session: &str) -> Option<Arc<State>> {
        let sessions = self.sessions.lock().unwrap_or_else(|p| p.into_inner());
        sessions
            .get(session)
            .and_then(Weak::upgrade)
            .map(|interest| interest.state.clone())
    }

    /// The live state of `session`, while a follow is connected to it.
    pub(super) fn snapshot(&self, session: &str) -> Option<Snapshot> {
        let state = self.state(session)?;
        let version = *state.changes.borrow();
        let live = state.live.lock().unwrap_or_else(|p| p.into_inner());
        live.connected.then(|| Snapshot {
            version,
            running: live.running,
            tail: LiveTail {
                through: live.through.unwrap_or(u64::MAX),
                updates: live
                    .updates
                    .iter()
                    .map(|(seq, update, _)| (*seq, update.clone()))
                    .collect(),
            },
        })
    }

    /// Drop the live updates the log now holds (through `disk`).
    pub(super) fn prune(&self, session: &str, disk: u64) {
        let Some(state) = self.state(session) else { return };
        let mut live = state.live.lock().unwrap_or_else(|p| p.into_inner());
        while live.updates.front().is_some_and(|(seq, _, _)| *seq <= disk) {
            if let Some((_, _, size)) = live.updates.pop_front() {
                live.bytes -= size;
            }
        }
    }
}

impl State {
    fn changed(&self) {
        self.changes.send_modify(|version| *version += 1);
    }

    fn update(&self, change: impl FnOnce(&mut Live) -> bool) {
        let changed = change(&mut self.live.lock().unwrap_or_else(|p| p.into_inner()));
        if changed {
            self.changed();
        }
    }

    /// The follow ended: nothing live is shown any more.
    fn reset(&self) {
        self.update(|live| {
            let was = live.connected || !live.updates.is_empty();
            *live = Live::default();
            was
        });
    }
}

impl Live {
    /// The roster answered. Subscribed while idle, every update the log
    /// lacks was received: Grok writes a turn's buffered text before its end.
    /// Mid-turn, a text run begun before subscribing may still be buffered,
    /// so the overlay waits until the log reaches the first update received.
    fn settle(&mut self, idle: bool) {
        self.settled = true;
        let start = if idle { Some(0) } else { self.first.map(|seq| seq - 1) };
        if let Some(start) = start {
            self.wait_for_log(start);
        }
    }

    /// No overlay until the log holds sequence `seq`.
    fn wait_for_log(&mut self, seq: u64) {
        self.through = Some(self.through.map_or(seq, |through| through.max(seq)));
    }

    /// Keep one live update of the session, bounded.
    fn push(&mut self, seq: u64, update: Value, size: usize) {
        if self.first.is_none() {
            self.first = Some(seq);
            if self.settled && self.through.is_none() {
                self.wait_for_log(seq - 1);
            }
        }
        if size > MAX_UPDATE_BYTES {
            self.wait_for_log(seq);
            return;
        }
        self.updates.push_back((seq, update, size));
        self.bytes += size;
        while self.updates.len() > MAX_TAIL_UPDATES || self.bytes > MAX_TAIL_BYTES {
            let Some((dropped, _, size)) = self.updates.pop_front() else { break };
            self.bytes -= size;
            // What was dropped must come from the log now.
            self.wait_for_log(dropped);
        }
    }
}

#[cfg(all(test, unix))]
mod tests;
