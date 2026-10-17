//! App-server remote-control sessions.
//!
//! One [`Session`] per subscribed `pcx:*:app:*` service: it owns the
//! WebSocket JSON-RPC [`AppClient`] (already `initialize`d) and a broadcast
//! channel carrying mapped [`AppEvent`]s so multiple UI listeners (or a
//! reconnecting stream) can observe the same notification feed. The raw
//! pb-mapper subscription that materialises the local ws endpoint is owned by
//! [`crate::engine::runtime`]; we layer the JSON-RPC client on top of it.
//!
//! This file owns the session registry and the shared wire types; the
//! operations live in child modules (`connection`, `threads`, `history`,
//! `turns`, `config`, `account`, `items`) and are re-exported here, so the
//! `app_session::*` paths are unchanged.

use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use anyhow::{anyhow, bail, Context, Result};
use once_cell::sync::OnceCell;
use pocket_codex_codex::client::{AppClient, Inbound};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::{sync::broadcast, task::JoinHandle};

use crate::engine::{runtime, transport::Transport};

#[path = "app_session_live.rs"]
mod live;
use live::LiveTranscript;

#[path = "app_session_account.rs"]
mod account;
#[path = "app_session_config.rs"]
mod config;
#[path = "app_session_connection.rs"]
mod connection;
#[path = "app_session_history.rs"]
mod history;
#[path = "app_session_items.rs"]
mod items;
#[path = "app_session_threads.rs"]
mod threads;
#[path = "app_session_turns.rs"]
mod turns;

// Read by the live hosting tests only (the connection keeps its own uses).
#[cfg(test)]
pub use self::connection::probe_endpoint_error;
#[cfg(test)]
use self::{
    account::auth_status_from_response,
    config::{
        parse_approval_policy, parse_sandbox_mode, parse_service_tiers, parse_supported_efforts,
        runtime_config_from_response, runtime_config_from_settings,
    },
    connection::establish,
    history::flatten_turns,
    items::{item_images, parse_item, summarize_item},
    threads::{first_sentence, parse_thread_meta},
    turns::{approval_result, build_turn_input, validate_realtime_request},
};
pub use self::{
    account::{
        auth_status, codex_logout, login_cancel, login_chatgpt_start, parse_token_usage,
        rate_limits, ChatgptLoginStart,
    },
    config::{model_list, thread_runtime_config, ThreadRuntimeConfig},
    connection::{
        connect, connect_local, disconnect, is_connected, probe_api, probe_endpoint,
        probe_http_endpoint, probe_reason,
    },
    history::{ThreadHistory, TurnSummary},
    threads::{
        thread_list, thread_metadata, thread_older_page, thread_read, thread_read_with_pages,
        thread_resume, thread_summary, thread_turn_items, OlderPage,
    },
    turns::{
        compact, git_diff, realtime_request, respond_approval, respond_user_input, set_thread_name,
        thread_start, turn_interrupt, turn_start, turn_steer,
    },
};
use self::{
    config::{
        insert_execution_options, nonempty_str, normalize_approval_policy,
        parse_collaboration_mode, record_runtime_config, runtime_config_with_thread,
        track_runtime_config,
    },
    history::{
        fetch_item_page, fetch_older_item_page, fetch_turn_page, is_unknown_method,
        load_paginated_window, load_whole_history, LoadedHistory, INITIAL_TURN_LIMIT,
        ITEM_PAGE_LIMIT, MAX_TURN_ITEM_PAGES,
    },
    items::{buffer_item, map_event, parse_turn_item, parse_turn_items, turn_stamp, TurnStamp},
    turns::{extract_turn_id, record_active_turn, track_active_turn, track_pending_approval},
};
pub(super) use self::{
    items::{encode_plan, format_content_diff},
    threads::{
        external_history_changed, history_continuation, parse_prefetched_items,
        reset_synced_history,
    },
};

/// A UI-facing app-server event, flattened from a JSON-RPC notification.
///
/// `kind` is the raw JSON-RPC method (e.g. `turn/started`,
/// `item/agentMessage/delta`, `turn/completed`); `raw` is the full params JSON
/// so the UI can stay resilient to fields we don't model explicitly.
#[derive(Clone, Debug)]
pub struct AppEvent {
    /// JSON-RPC method name of the originating notification.
    pub kind: String,
    /// Thread id the event belongs to, when present.
    pub thread_id: Option<String>,
    /// Item id the event refers to, when present.
    pub item_id: Option<String>,
    /// Item type tag when this event carries an item (`agentMessage`,
    /// `commandExecution`, `webSearch`, `mcpToolCall`, `fileChange`,
    /// `reasoning`, …); `None` for turn-level events.
    pub item_type: Option<String>,
    /// One-line human summary for tool/activity items (command, query, tool
    /// name, file count, …).
    pub title: Option<String>,
    /// Text payload: a streaming delta or an item's body/detail.
    pub text: Option<String>,
    /// User attachments or generated artifacts, as data URLs or host paths.
    pub images: Vec<String>,
    /// Opaque token to answer a server request (e.g. an approval prompt) via
    /// [`respond_approval`]; `None` for ordinary notifications.
    pub request_id: Option<String>,
    /// Full params JSON for fields not modelled above.
    pub raw: String,
}

/// One thread's summary metadata.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ThreadMeta {
    /// Thread id.
    pub id: String,
    /// Preview (usually the first user message).
    pub preview: String,
    /// User-set title, or `None` when the thread was never renamed (callers
    /// fall back to [`Self::preview`]).
    pub name: Option<String>,
    /// App-owned classification persisted by Codex, independent of the title.
    #[serde(default)]
    pub thread_source: Option<String>,
    /// Parent thread, when this is a spawned child.
    #[serde(default)]
    pub parent_thread_id: Option<String>,
    /// Working directory (the "project" the thread controls).
    pub cwd: String,
    /// The repository's remote (`gitInfo.originUrl`), when the agent reports
    /// one: what ties a managed worktree to the checkout it came from.
    #[serde(default)]
    pub origin_url: Option<String>,
    /// Unix seconds of last update.
    pub updated_at: i64,
}

/// One model offered by the app-server.
#[derive(Clone, Debug)]
pub struct ModelInfo {
    /// Model id used as the `model` param.
    pub id: String,
    /// Human-readable name.
    pub display_name: String,
    /// Short description.
    pub description: String,
    /// Reasoning efforts this model supports (`none`/`minimal`/`low`/`medium`/
    /// `high`/`xhigh`), so the UI offers only the levels the model accepts.
    pub supported_reasoning_efforts: Vec<String>,
    /// The model's default reasoning effort, if any.
    pub default_reasoning_effort: Option<String>,
    /// Service tier ids advertised by the model catalog.
    pub supported_service_tiers: Vec<String>,
    /// Catalog default service tier.
    pub default_service_tier: Option<String>,
    /// Whether this is the server default model.
    pub is_default: bool,
}

/// One materialised conversation item (from `thread/read`).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ThreadItem {
    /// Item id.
    pub id: String,
    /// Item type tag: `userMessage` / `agentMessage` / `commandExecution` /
    /// `webSearch` / `mcpToolCall` / `fileChange` / `reasoning` / `plan` / ….
    pub item_type: String,
    /// One-line summary for tool/activity items (command, query, tool name…).
    pub title: String,
    /// Body / detail text (message content, command output, tool result…).
    pub text: String,
    /// Live asynchronous questions retained for reconnects, as JSON.
    /// Historical items alone must not introduce pending questions.
    pub questions_json: Option<String>,
    /// User attachments or generated images: data URLs or host artifact paths.
    pub images: Vec<String>,
    /// Id of the turn this item belongs to.
    ///
    /// `thread/read` returns items nested under their turn, so this is the
    /// server's own turn boundary rather than something inferred from the item
    /// sequence — the UI groups one turn's reply into one block with it. Empty
    /// for an item recovered from the live stream buffer, which arrives outside
    /// any turn payload.
    pub turn_id: String,
    /// Unix seconds when this item's turn completed; `None` while it is still
    /// running (or for a buffered item with no turn).
    pub turn_completed_at: Option<i64>,
    /// How long this item's turn took, in milliseconds, when the server knows.
    pub turn_duration_ms: Option<i64>,
}

struct Session {
    client: Arc<AppClient>,
    events: broadcast::Sender<AppEvent>,
    forwarder: JoinHandle<()>,
    /// Latest in-flight `turnId` per `threadId`, learned from the live
    /// `turn/started` / `turn/completed` / `turn/failed` notifications the
    /// forwarder sees. `turn/interrupt` needs the turnId, and the UI can't
    /// always supply it (e.g. opening a thread that was already running, or
    /// switching sessions), so the engine tracks it authoritatively here.
    active_turns: Arc<Mutex<HashMap<String, Value>>>,
    /// Latest server-reported runtime configuration per `threadId` — the
    /// ground truth for what model / effort / permissions the thread actually
    /// runs with. Seeded from `thread/start` / `thread/resume` responses
    /// (`thread/read` exposes none of it) and kept fresh by the forwarder from
    /// `thread/settings/updated` notifications, which newer servers emit with
    /// the full effective snapshot whenever a turn's overrides change the
    /// thread's settings. Lets the UI *verify* a model switch took effect
    /// instead of guessing from what it sent.
    runtime_config: Arc<Mutex<HashMap<String, ThreadRuntimeConfig>>>,
    /// Requested `permissions` of any in-flight
    /// `item/permissions/requestApproval` request, keyed by its
    /// `request_id`. A permissions approval answers with a
    /// `PermissionsRequestApprovalResponse` (`{permissions, scope}`), not the
    /// plain `{decision}` a command/file approval takes, so
    /// [`respond_approval`] needs the original grant to echo back on
    /// accept. See [`track_pending_approval`].
    pending_approvals: Arc<Mutex<HashMap<String, Value>>>,
    /// Per-thread buffer of the item snapshots this session has streamed
    /// (`item/*` notifications), upserted by id in stream order.
    /// [`thread_read`] merges these in so an in-progress turn's
    /// already-streamed thinking/tool items survive re-opening the
    /// conversation: the forwarder drops events when no UI is attached, and
    /// the server's `thread/read` doesn't return the in-progress turn's
    /// items.
    transcript: Arc<Mutex<LiveTranscript>>,
    /// Where each paginated thread's history reading got to, keyed by
    /// `threadId`. Paginated threads reject a whole-history read, so
    /// [`thread_read`] loads a bounded window and the UI asks for more; the
    /// cursors to continue from live here because they are server-opaque and
    /// only meaningful in sequence.
    pagination: Arc<Mutex<HashMap<String, ThreadPagination>>>,
}

/// How far back a paginated thread has been read, and where to continue.
///
/// Cursors are opaque server tokens. A server that repeats one would spin us
/// forever, so every cursor is remembered and a repeat is treated as the end of
/// the history (see [`advancing_cursor`]).
#[derive(Clone, Debug, Default)]
struct ThreadPagination {
    /// Cursor for the next (older) page of items, `None` at the start of the
    /// thread.
    next_item_cursor: Option<String>,
    /// Cursors already followed, so a repeat ends the walk instead of looping.
    seen_item_cursors: HashSet<String>,
    /// Turn ids whose items have been loaded, oldest first. The UI jumps by
    /// turn, so it needs to know which turns it can already show.
    loaded_turns: Vec<String>,
    /// Timing from every enumerated turn, reused by later item pages.
    turn_stamps: HashMap<String, TurnStamp>,
    /// Serializes reads for this thread without holding the session map lock.
    request_gate: Arc<Mutex<()>>,
    /// Invalidated by destructive history changes such as compaction.
    generation: u64,
    /// Any live item/turn update invalidates snapshot reuse, but immutable
    /// older pages remain valid unless generation changes
    /// (rollback/compaction).
    source_revision: u64,
    /// Metadata verified by thread/read before reusing an idle snapshot.
    metadata: Option<Value>,
    cached: Option<Arc<LoadedHistory>>,
    cached_at: Option<Instant>,
    /// Actual oldest turn, set only after exhausting the summary cursor.
    first_turn_id: Option<String>,
    /// Independently paged turns selected through the timeline.
    turn_pages: HashMap<String, TurnWindow>,
}

/// Bridge calls currently occupying an FRB worker thread. Diagnostic only.
static BRIDGE_BUSY: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Decrements [`BRIDGE_BUSY`] however its scope ends.
struct BusyGuard;

impl Drop for BusyGuard {
    fn drop(&mut self) {
        BRIDGE_BUSY.fetch_sub(1, std::sync::atomic::Ordering::Relaxed);
    }
}

/// The next cursor to follow, or `None` when the walk is done.
///
/// Ends the walk when the server repeats a cursor it already gave us —
/// otherwise a buggy or racing server turns pagination into an infinite loop.
fn advancing_cursor(
    current: Option<&str>,
    next: Option<String>,
    seen: &mut HashSet<String>,
) -> Option<String> {
    if let Some(current) = current {
        seen.insert(current.to_string());
    }
    next.filter(|next| !next.is_empty() && seen.insert(next.clone()))
}

impl Drop for Session {
    fn drop(&mut self) {
        self.forwarder.abort();
    }
}

static SESSIONS: OnceCell<Mutex<HashMap<String, Session>>> = OnceCell::new();

fn sessions() -> &'static Mutex<HashMap<String, Session>> {
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

// Weak entries serialize connect/disconnect for one service without keeping
// obsolete services alive or holding the session registry over network I/O.
fn lifecycle(service_key: &str) -> Arc<Mutex<()>> {
    type Locks = Mutex<HashMap<String, std::sync::Weak<Mutex<()>>>>;
    static LOCKS: OnceCell<Locks> = OnceCell::new();
    let mut locks = LOCKS
        .get_or_init(Mutex::default)
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if let Some(lock) = locks.get(service_key).and_then(std::sync::Weak::upgrade) {
        return lock;
    }
    locks.retain(|_, lock| lock.strong_count() > 0);
    let lock = Arc::new(Mutex::new(()));
    locks.insert(service_key.to_string(), Arc::downgrade(&lock));
    lock
}

#[path = "app_session_history_cache.rs"]
mod history_cache;
use history_cache::{
    cache_history, ensure_pagination, invalidate_history, pagination_of, reset_pagination,
    set_pagination,
};

#[path = "app_session_turn_pages.rs"]
mod turn_pages;
use turn_pages::{cached_turn_pages, TurnWindow};
pub use turn_pages::{thread_turn_page, thread_turn_page_delta, TurnItemsPage};

/// A fresh broadcast receiver for `service_key`'s event feed.
pub fn subscribe_events(service_key: &str) -> Result<broadcast::Receiver<AppEvent>> {
    let map = sessions().lock().expect("sessions poisoned");
    let s = map
        .get(service_key)
        .ok_or_else(|| anyhow!("not connected to {service_key}"))?;
    Ok(s.events.subscribe())
}

fn client_for(service_key: &str) -> Result<Arc<AppClient>> {
    let map = sessions().lock().expect("sessions poisoned");
    map.get(service_key)
        .map(|s| Arc::clone(&s.client))
        .ok_or_else(|| anyhow!("not connected to {service_key}"))
}

#[cfg(test)]
#[path = "app_session_pagination_tests.rs"]
mod pagination_tests;

#[cfg(test)]
#[path = "app_session_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "app_session_protocol_tests.rs"]
mod protocol_tests;
