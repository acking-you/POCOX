//! The host's Codex session inventory, asked of the colocated app-server first.
//!
//! `thread/list` names every session the app-server lists, compressed
//! rollouts, renames and archive state included, and each `Thread.status`
//! says whether *this* app-server has the thread loaded and whether a turn
//! runs in it (`notLoaded` / `idle` / `active` / `systemError`). That answer is
//! authoritative for a loaded thread: another controller joins it with a plain
//! `thread/resume`, so nothing is evicted, even while a turn runs.
//!
//! The API cannot see a thread another process writes (Codex Desktop, the
//! TUI): it reports one as `notLoaded`. Only there do the rollout and `lsof`
//! probes of [`crate::sessions`] decide. An unfinished last turn nobody runs is
//! reported the way the app-server reads it, as interrupted, never as a turn in
//! progress. When the app-server does not answer, the file-only inventory
//! stands in.

use std::{
    cmp::Reverse,
    collections::HashSet,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use futures::StreamExt;
use pocket_codex_codex::{
    liveness::held_open_paths,
    rollout::{self, TurnState},
    takeover::{self, ResumeSafety},
};
use serde_json::{json, Value};

use crate::{
    app_server::CodexReader,
    resume,
    sessions::{self, LocalSession, SessionLiveness},
};

/// Source kinds listed: the same set as the controller's conversation list.
const SOURCE_KINDS: [&str; 6] = ["cli", "vscode", "appServer", "exec", "subAgent", "unknown"];
const PAGE_LIMIT: u64 = 100;
/// Bounds a listing against a server that keeps returning cursors.
const MAX_THREADS: usize = 5000;
const GUARDIAN: &str = "guardian_review";
/// `thread/read` requests one running-session poll keeps in flight.
const CONCURRENT_READS: usize = 8;

/// Every session, newest first.
pub(crate) async fn list(reader: &CodexReader) -> Result<Vec<LocalSession>> {
    match list_threads(reader).await {
        Ok(threads) => blocking(move || Ok(annotate(&threads))).await,
        Err(error) => {
            tracing::debug!(%error, "app-server listing unavailable; scanning rollouts");
            blocking(sessions::list).await
        },
    }
}

/// Sessions with a turn running now: the app-server's active threads, plus
/// rollouts another process holds with an unfinished turn.
pub(crate) async fn running(reader: &CodexReader) -> Result<Vec<LocalSession>> {
    let loaded = match loaded_threads(reader).await {
        Ok(loaded) => loaded,
        Err(error) => {
            tracing::debug!(%error, "app-server loaded threads unavailable; probing rollouts");
            return blocking(sessions::running).await;
        },
    };
    let reported: HashSet<String> = loaded.iter().filter_map(id_of).collect();
    blocking(move || {
        let mut out: Vec<LocalSession> = loaded
            .iter()
            .filter(|thread| status_of(thread) == "active")
            .map(|thread| session(thread, Ownership::loaded(thread, None)))
            .collect();
        out.extend(sessions::running_except(&reported)?);
        out.sort_by_key(|session| Reverse(session.updated_at));
        Ok(out)
    })
    .await
}

/// One session's ownership, with the processes a takeover would stop.
pub(crate) async fn liveness(reader: &CodexReader, thread_id: &str) -> Result<SessionLiveness> {
    if let Some(thread) = loaded_thread(reader, thread_id).await {
        let id = thread_id.to_owned();
        return blocking(move || {
            let own = Ownership::loaded(&thread, rollout_of(&thread).as_deref());
            let guardian = rollout::thread_source(&thread).as_deref() == Some(GUARDIAN);
            Ok(SessionLiveness {
                thread_id: id,
                turn_state: own.turn_state.tag().into(),
                held_open: own.held_open,
                safety: own.safety.tag().into(),
                allows_resume: own.allows_resume(guardian),
                requires_takeover: own.requires_takeover(guardian),
                holders: Vec::new(),
            })
        })
        .await;
    }
    let id = thread_id.to_owned();
    let address = reader.address();
    blocking(move || {
        let mut view = sessions::liveness(&id, &resume::protected_pids(address))?;
        if !view.held_open && view.turn_state == TurnState::Incomplete.tag() {
            view.turn_state = settle(TurnState::Incomplete).tag().into();
        }
        Ok(view)
    })
    .await
}

/// The thread, when this app-server has it loaded.
pub(crate) async fn loaded_thread(reader: &CodexReader, thread_id: &str) -> Option<Value> {
    let mut response = reader
        .request("thread/read", json!({"threadId": thread_id, "includeTurns": false}))
        .await
        .ok()?;
    let thread = response.get_mut("thread")?.take();
    (thread.is_object() && status_of(&thread) != "notLoaded").then_some(thread)
}

async fn list_threads(reader: &CodexReader) -> Result<Vec<Value>> {
    let mut out = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let mut params = json!({
            "limit": PAGE_LIMIT,
            "sortKey": "updated_at",
            // The host's inventory, not one provider profile's.
            "modelProviders": [],
            "sourceKinds": SOURCE_KINDS,
        });
        if let Some(cursor) = &cursor {
            params["cursor"] = json!(cursor);
        }
        let mut page = reader.request("thread/list", params).await?;
        let data = page
            .get_mut("data")
            .and_then(Value::as_array_mut)
            .map(std::mem::take)
            .context("thread/list answered without data")?;
        let empty = data.is_empty();
        out.extend(data);
        cursor = page["nextCursor"]
            .as_str()
            .filter(|cursor| !cursor.is_empty())
            .map(str::to_owned);
        if cursor.is_none() || empty || out.len() >= MAX_THREADS {
            return Ok(out);
        }
    }
}

/// Every thread this app-server has loaded, read without attaching to any.
/// A thread unloaded between the two requests is left out. Reads run a few
/// at a time, so a server holding many loaded threads never receives one
/// poll's reads all at once.
async fn loaded_threads(reader: &CodexReader) -> Result<Vec<Value>> {
    let mut ids = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let mut params = json!({"limit": PAGE_LIMIT});
        if let Some(cursor) = &cursor {
            params["cursor"] = json!(cursor);
        }
        let page = reader.request("thread/loaded/list", params).await?;
        let data = page["data"]
            .as_array()
            .context("thread/loaded/list answered without data")?;
        ids.extend(data.iter().filter_map(Value::as_str).map(str::to_owned));
        cursor = page["nextCursor"]
            .as_str()
            .filter(|cursor| !cursor.is_empty())
            .map(str::to_owned);
        if cursor.is_none() || data.is_empty() || ids.len() >= MAX_THREADS {
            break;
        }
    }
    let requests = ids
        .into_iter()
        .map(|id| json!({"threadId": id, "includeTurns": false}));
    let reads: Vec<_> = futures::stream::iter(requests)
        .map(|params| reader.request("thread/read", params))
        .buffer_unordered(CONCURRENT_READS)
        .collect()
        .await;
    Ok(reads
        .into_iter()
        .filter_map(|read| Some(read.ok()?.get_mut("thread")?.take()))
        .filter(Value::is_object)
        .collect())
}

/// Ownership of every listed thread. Threads the app-server reports loaded
/// are its own; only the others' plain rollouts are probed for a holder.
fn annotate(threads: &[Value]) -> Vec<LocalSession> {
    let paths: Vec<Option<PathBuf>> = threads.iter().map(rollout_of).collect();
    let probe: Vec<PathBuf> = threads
        .iter()
        .zip(&paths)
        .filter(|(thread, _)| status_of(thread) == "notLoaded")
        .filter_map(|(_, path)| path.clone())
        .filter(|path| !rollout::is_compressed(path))
        .collect();
    let held = held_open_paths(&probe);
    threads
        .iter()
        .zip(paths)
        .map(|(thread, path)| {
            let own = if status_of(thread) == "notLoaded" {
                let held = path.as_ref().is_some_and(|path| held.contains(path));
                Ownership::unloaded(path.as_deref(), held)
            } else {
                Ownership::loaded(thread, path.as_deref())
            };
            session(thread, own)
        })
        .collect()
}

/// Who writes a thread, and what resuming it takes.
struct Ownership {
    turn_state: TurnState,
    held_open: bool,
    safety: ResumeSafety,
    /// Loaded by the colocated app-server: resuming joins it.
    joined: bool,
}

impl Ownership {
    /// A thread the app-server has loaded. Its status says whether a turn
    /// runs; otherwise the rollout's last turn is reported when `path` is
    /// given.
    fn loaded(thread: &Value, path: Option<&Path>) -> Self {
        if status_of(thread) == "active" {
            return Self {
                turn_state: TurnState::Incomplete,
                held_open: true,
                safety: ResumeSafety::OwnedRunning,
                joined: true,
            };
        }
        let last = last_turn(path);
        Self {
            safety: takeover::classify(&last, false),
            turn_state: settle(last),
            held_open: true,
            joined: true,
        }
    }

    /// A thread the app-server has not loaded: a holder is another process.
    fn unloaded(path: Option<&Path>, held: bool) -> Self {
        let last = last_turn(path);
        Self {
            safety: takeover::classify(&last, held),
            turn_state: if held { last } else { settle(last) },
            held_open: held,
            joined: false,
        }
    }

    fn allows_resume(&self, guardian: bool) -> bool {
        !guardian && (self.joined || self.safety.allows_resume())
    }

    fn requires_takeover(&self, guardian: bool) -> bool {
        !guardian && !self.joined && self.safety.requires_takeover()
    }
}

fn last_turn(path: Option<&Path>) -> TurnState {
    path.and_then(|path| rollout::classify_turn_state(path).ok())
        .unwrap_or(TurnState::Unknown)
}

/// The last turn of a thread nobody runs, as the app-server reads it: an
/// unfinished turn was interrupted.
fn settle(last: TurnState) -> TurnState {
    match last {
        TurnState::Incomplete => TurnState::Aborted("interrupted".into()),
        state => state,
    }
}

fn session(thread: &Value, own: Ownership) -> LocalSession {
    let thread_source = rollout::thread_source(thread);
    let guardian = thread_source.as_deref() == Some(GUARDIAN);
    LocalSession {
        thread_id: id_of(thread).unwrap_or_default(),
        cwd: text(thread, "cwd"),
        preview: text(thread, "preview").unwrap_or_default(),
        name: text(thread, "name"),
        status: Some(status_of(thread).to_owned()),
        source: source_label(&thread["source"]),
        parent_thread_id: rollout::parent_thread_id(thread),
        thread_source,
        updated_at: thread["updatedAt"].as_i64().unwrap_or(0),
        turn_state: own.turn_state.tag().into(),
        held_open: own.held_open,
        safety: own.safety.tag().into(),
        allows_resume: own.allows_resume(guardian),
        requires_takeover: own.requires_takeover(guardian),
    }
}

/// The rollout behind a thread, in whichever representation exists. The
/// listing names the plain path even after Codex compressed the file.
fn rollout_of(thread: &Value) -> Option<PathBuf> {
    let plain = PathBuf::from(thread["path"].as_str().filter(|path| !path.is_empty())?);
    if plain.is_file() {
        return Some(plain);
    }
    let mut compressed = plain.into_os_string();
    compressed.push(".zst");
    let compressed = PathBuf::from(compressed);
    compressed.is_file().then_some(compressed)
}

fn status_of(thread: &Value) -> &str {
    thread["status"]["type"].as_str().unwrap_or("notLoaded")
}

fn id_of(thread: &Value) -> Option<String> {
    text(thread, "id")
}

fn text(thread: &Value, field: &str) -> Option<String> {
    thread[field]
        .as_str()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

/// `"cli"` stays itself; a tagged source (`{"subAgent": …}`) is its tag.
fn source_label(source: &Value) -> Option<String> {
    match source {
        Value::String(source) if !source.is_empty() => Some(source.clone()),
        Value::Object(map) => map.keys().next().cloned(),
        _ => None,
    }
}

async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T> + Send + 'static,
) -> Result<T> {
    tokio::task::spawn_blocking(work)
        .await
        .context("session inventory task panicked")?
}

#[cfg(test)]
#[path = "codex_inventory_tests.rs"]
mod tests;
