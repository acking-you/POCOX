//! Thread history loading: whole-history reads and bounded paginated windows.

use super::*;

/// A thread's recovered history plus whether a turn is still running, so the
/// UI can restore the "thinking" state when re-opening an in-flight thread.
/// Also carries the thread metadata the status bar / git chip seed from.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ThreadHistory {
    /// Source replacement generation; changed values invalidate retained UI
    /// gaps.
    #[serde(default)]
    pub history_epoch: Option<String>,
    /// Conversation items, oldest first.
    pub items: Vec<ThreadItem>,
    /// Whether the most recent turn is still in progress.
    pub running: bool,
    /// Identity from the same turn snapshot that established `running`.
    #[serde(default)]
    pub active_turn_id: Option<String>,
    /// Current git branch of the thread's cwd, if it's a repo.
    pub branch: Option<String>,
    /// The thread's resolved working directory (for git diff / status).
    pub cwd: Option<String>,
    /// Tokens currently occupying the model context window (latest turn).
    pub tokens_used: Option<i64>,
    /// The model's context-window size in tokens.
    pub context_window: Option<i64>,
    /// The thread's sticky collaboration mode (`"plan"` / `"default"`), so the
    /// UI's plan-mode state reflects the server truth rather than guessing from
    /// the last item.
    pub collaboration_mode: Option<String>,
    /// The thread's current reasoning effort (`"low"`/`"medium"`/`"high"`), so
    /// the UI can display the "thinking level" a re-opened thread runs with.
    /// Sourced from the cached `thread/resume` response (see
    /// [`thread_resume`]).
    pub reasoning_effort: Option<String>,
    /// The effective model id the thread runs with, per the server (from the
    /// cached start/resume response or a live settings update). `None` when
    /// the server never said.
    pub model: Option<String>,
    /// Provider of the effective model (e.g. `openai`), when reported.
    pub model_provider: Option<String>,
    /// The effective approval policy, when reported.
    pub approval_policy: Option<String>,
    /// Approval reviewer (`user` or `auto_review`), when reported.
    #[serde(default)]
    pub approvals_reviewer: Option<String>,
    /// Effective service tier, when reported.
    #[serde(default)]
    pub service_tier: Option<String>,
    /// The effective sandbox mode (kebab wire string), when reported.
    pub sandbox_mode: Option<String>,
    /// Whether a live `thread/settings/updated` has confirmed this config (vs
    /// only a start/resume snapshot).
    pub config_confirmed: bool,
    /// Whether earlier items remain unread — [`thread_older_page`] can fetch
    /// them. Always false for a legacy thread, whose history arrives whole.
    pub has_older: bool,
    /// One entry per turn in the WHOLE thread, oldest first, even for turns
    /// whose items aren't loaded. The turn rail shows a conversation's shape,
    /// so it needs every turn — but only a summary of each, not its items.
    pub turns: Vec<TurnSummary>,
    /// Actual first turn, when the server's summary cursor was exhausted.
    pub first_turn_id: Option<String>,
    /// Cached independently loaded turns, including their continuation state.
    pub turn_pages: Vec<TurnItemsPage>,
}

/// A turn reduced to what the rail shows: the question, and how it was
/// answered.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TurnSummary {
    pub turn_id: String,
    /// The user's message that opened the turn, empty when it had none.
    pub user_text: String,
    /// The turn's final agent message, empty when it produced no prose.
    pub assistant_text: String,
    /// Whether this turn's items are already in `ThreadHistory::items`.
    pub loaded: bool,
}

/// How many of the newest turns get their items loaded when a thread opens.
/// Enough to fill a window; the rest arrive as the user scrolls back.
pub(super) const INITIAL_TURN_LIMIT: u32 = 5;

/// Items per page when walking back through history. The server caps a page at
/// 100, so asking for more would just be silently clamped.
pub(super) const ITEM_PAGE_LIMIT: u32 = 100;

/// A small tail keeps first paint and live monitoring responsive on a relay.
/// Older pages remain available at the normal page size.
const INITIAL_ITEM_LIMIT: u32 = 20;

/// Turns per page when fetching the rail's skeleton. Same server cap as items.
const TURN_PAGE_LIMIT: u32 = 100;

/// Ceiling on item pages drained for ONE turn. A turn with hundreds of items
/// would otherwise hold the socket for as many serial round trips as it takes.
pub(super) const MAX_TURN_ITEM_PAGES: usize = 3;

/// Ceiling on skeleton pages fetched while a thread opens.
///
/// Every page is a serial round trip on the same socket, so this bounds how
/// long the rail's full length can delay the requests queued behind the open —
/// notably `thread/resume`, which timed out at 60s when this walked far enough.
/// At 100 turns a page, five pages already covers a 500-turn conversation; a
/// longer one gets a rail over its most recent 500 turns rather than a stall.
const MAX_TURN_PAGES: usize = 5;

/// One thread's loaded history, plus how much of it there is.
#[derive(Clone, Debug)]
pub(super) struct LoadedHistory {
    /// Items to show, oldest first.
    pub(super) items: Vec<ThreadItem>,
    /// The raw turn objects the items came from, newest last. Used for the
    /// running/active-turn checks, which only concern the newest turn.
    pub(super) turns: Vec<Value>,
    /// Every turn in the thread, oldest first.
    pub(super) skeletons: Vec<TurnSummary>,
    pub(super) has_older: bool,
}

/// Whether an error is the server saying it doesn't know a method — the signal
/// to fall back to an older API rather than surface a failure.
pub(super) fn is_unknown_method(err: &anyhow::Error) -> bool {
    let text = err.to_string().to_lowercase();
    text.contains("method not found")
        || text.contains("unknown method")
        || text.contains("unsupported method")
}

/// Read a thread's entire history in one call (the legacy shape).
pub(super) fn load_whole_history(
    client: &Arc<AppClient>,
    thread_id: &str,
) -> Result<LoadedHistory> {
    let res = runtime::runtime().block_on(
        client.request("thread/read", json!({ "threadId": thread_id, "includeTurns": true })),
    )?;
    let turns = res
        .get("thread")
        .and_then(|t| t.get("turns"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let skeletons = turns
        .iter()
        .map(|turn| summarize_turn(turn, true))
        .collect();
    Ok(LoadedHistory {
        items: flatten_turns(&turns),
        turns,
        skeletons,
        // The whole history is here, so there is nothing older to ask for.
        has_older: false,
    })
}

/// Reduce a turn object to its rail summary.
fn summarize_turn(turn: &Value, loaded: bool) -> TurnSummary {
    let items = turn
        .get("items")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    // A summary view carries the turn's first user message and its final agent
    // message; a full view carries everything, so pick those two out of it.
    let text_of = |want_user: bool| -> String {
        let mut found = String::new();
        for item in items {
            let kind = item
                .get("type")
                .or_else(|| item.get("itemType"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            let is_user = kind.contains("userMessage");
            let is_agent = kind.contains("agentMessage");
            if want_user && is_user {
                // The turn's FIRST user message opens it.
                return item_plain_text(item);
            }
            if !want_user && is_agent {
                // The turn's LAST agent message concludes it, so keep looking.
                found = item_plain_text(item);
            }
        }
        found
    };
    TurnSummary {
        turn_id: turn
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        user_text: text_of(true),
        assistant_text: text_of(false),
        loaded,
    }
}

/// Plain text of a message item, for a rail preview.
fn item_plain_text(item: &Value) -> String {
    if let Some(text) = ["text", "message", "content"]
        .iter()
        .find_map(|key| item.get(*key).and_then(Value::as_str))
    {
        return text.to_string();
    }
    item.get("content")
        .and_then(Value::as_array)
        .map(|parts| {
            parts
                .iter()
                .filter_map(|part| part.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n")
        })
        .unwrap_or_default()
}

/// Flatten server turns into UI items, oldest first.
///
/// Each item keeps its turn's id and timing: the nesting IS the server's turn
/// boundary, and dropping it forced the UI to re-infer turns from the item
/// sequence and to invent its own timestamps.
pub(super) fn flatten_turns(turns: &[Value]) -> Vec<ThreadItem> {
    let mut items = Vec::new();
    for turn in turns {
        let Some(turn_items) = turn.get("items").and_then(Value::as_array) else {
            continue;
        };
        let stamp = TurnStamp::of(turn);
        for item in turn_items {
            items.extend(parse_turn_items(item, &stamp));
        }
    }
    items
}

/// Fetch one page of turns. `items_view` decides how much of each turn comes
/// back: `"notLoaded"` for bare metadata, `"summary"` for the opening question
/// and final answer, `"full"` for every item.
pub(super) fn fetch_turn_page(
    service_key: &str,
    client: &Arc<AppClient>,
    thread_id: &str,
    cursor: Option<&str>,
    limit: u32,
    items_view: &str,
) -> Result<Value> {
    let mut params = json!({
        "threadId": thread_id,
        "limit": limit,
        "sortDirection": "desc",
        "itemsView": items_view,
    });
    if let Some(cursor) = cursor {
        params["cursor"] = json!(cursor);
    }
    crate::engine::session_sync::request(service_key, client, "thread/turns/list", params)
}

/// Fetch one page of items, newest first. `turn_id` narrows it to a single
/// turn.
pub(super) fn fetch_item_page(
    service_key: &str,
    client: &Arc<AppClient>,
    thread_id: &str,
    turn_id: Option<&str>,
    cursor: Option<&str>,
    limit: u32,
) -> Result<Value> {
    let mut params = json!({
        "threadId": thread_id,
        "limit": limit,
        "sortDirection": "desc",
    });
    if let Some(turn_id) = turn_id {
        params["turnId"] = json!(turn_id);
    }
    if let Some(cursor) = cursor {
        params["cursor"] = json!(cursor);
    }
    crate::engine::session_sync::request(service_key, client, "thread/items/list", params)
}

/// [`fetch_item_page`] for a page behind the live tail: such a page is fixed
/// within a source generation, so a retained copy answers it from disk.
pub(super) fn fetch_older_item_page(
    service_key: &str,
    client: &Arc<AppClient>,
    thread_id: &str,
    cursor: &str,
    limit: u32,
) -> Result<Value> {
    let params = json!({
        "threadId": thread_id,
        "limit": limit,
        "sortDirection": "desc",
        "cursor": cursor,
    });
    if let Some(page) =
        crate::engine::session_sync::retained(service_key, "thread/items/list", &params)
    {
        return Ok(page);
    }
    fetch_item_page(service_key, client, thread_id, None, Some(cursor), limit)
}

/// Every turn in the thread, oldest first, as rail summaries.
///
/// Walks `thread/turns/list` backwards with a summary view, which the store
/// answers from indexed columns rather than by replaying items — cheap enough
/// to do for the whole thread so the rail can show its true length immediately.
fn fetch_all_turn_summaries(
    service_key: &str,
    client: &Arc<AppClient>,
    thread_id: &str,
    stamps: &mut HashMap<String, TurnStamp>,
    first_turn_id: &mut Option<String>,
) -> Result<Vec<TurnSummary>> {
    let mut newest_first = Vec::new();
    let mut cursor: Option<String> = None;
    let mut seen = HashSet::new();
    for _ in 0..MAX_TURN_PAGES {
        let page = fetch_turn_page(
            service_key,
            client,
            thread_id,
            cursor.as_deref(),
            TURN_PAGE_LIMIT,
            "summary",
        )?;
        let turns = page
            .get("data")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if turns.is_empty() {
            *first_turn_id = newest_first
                .last()
                .map(|turn: &TurnSummary| turn.turn_id.clone());
            break;
        }
        for turn in &turns {
            let stamp = TurnStamp::of(turn);
            stamps.insert(stamp.id.clone(), stamp);
            newest_first.push(summarize_turn(turn, false));
        }
        let next = page
            .get("nextCursor")
            .and_then(Value::as_str)
            .map(str::to_string);
        let exhausted = next.as_ref().is_none_or(String::is_empty);
        cursor = advancing_cursor(cursor.as_deref(), next, &mut seen);
        if cursor.is_none() {
            if exhausted {
                *first_turn_id = newest_first.last().map(|turn| turn.turn_id.clone());
            }
            break;
        }
    }
    newest_first.reverse();
    Ok(newest_first)
}

/// Load the newest slice of a paginated thread, plus a full turn skeleton.
///
/// The transcript's content comes from ONE bounded item page, never from
/// `itemsView: "full"`. A full view makes the server walk each returned turn's
/// items in nested loops inside a single JSON-RPC call, so one turn with
/// hundreds of items blows past the request timeout and the socket is judged
/// dead — which read as "connection closed" on exactly the longest threads.
pub(super) fn load_paginated_window(
    client: &Arc<AppClient>,
    service_key: &str,
    thread_id: &str,
) -> Result<LoadedHistory> {
    let previous = ensure_pagination(service_key, thread_id);
    let phase = std::time::Instant::now();
    // Turn shells for timing and status. `notLoaded` keeps this a single indexed
    // query per page regardless of how much the turns contain.
    let page =
        fetch_turn_page(service_key, client, thread_id, None, INITIAL_TURN_LIMIT, "notLoaded")?;
    tracing::debug!(
        target: "pocox_bridge::history",
        "  turn shells in {:?}", phase.elapsed()
    );
    let mut turns = page
        .get("data")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    // The wire order is newest first; the transcript reads oldest first.
    turns.reverse();

    // The newest items, bounded. This is what the view opens on.
    let phase = std::time::Instant::now();
    let items_page =
        fetch_item_page(service_key, client, thread_id, None, None, INITIAL_ITEM_LIMIT)?;
    tracing::debug!(
        target: "pocox_bridge::history",
        "  newest items in {:?}", phase.elapsed()
    );
    let entries = items_page
        .get("data")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    // Timing lives on the turn shells, so items pick their turn's stamp up here
    // rather than losing the duration footnote the transcript renders.
    let mut stamps: HashMap<String, TurnStamp> = turns
        .iter()
        .map(|turn| {
            let stamp = TurnStamp::of(turn);
            (stamp.id.clone(), stamp)
        })
        .collect();
    let mut items = Vec::new();
    let mut loaded_turns: Vec<String> = Vec::new();
    // Entries arrive newest first; the transcript reads the other way.
    for entry in entries.iter().rev() {
        let Some(item) = entry.get("item") else {
            continue;
        };
        let turn_id = entry
            .get("turnId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let stamp = turn_stamp(&stamps, turn_id);
        if let Some(parsed) = parse_turn_item(item, &stamp) {
            if parsed.item_type == "userMessage" && !loaded_turns.iter().any(|id| id == turn_id) {
                loaded_turns.push(turn_id.to_string());
            }
            items.extend(parse_turn_items(item, &stamp));
        }
    }

    // Every turn, so the rail is full-length from the start. A thread whose
    // skeleton can't be read still opens — the rail just falls back to the
    // loaded turns.
    let phase = std::time::Instant::now();
    let mut first_turn_id = None;
    let mut skeletons =
        fetch_all_turn_summaries(service_key, client, thread_id, &mut stamps, &mut first_turn_id)
            .unwrap_or_else(|_| Vec::new());
    tracing::debug!(
        target: "pocox_bridge::history",
        "  {} turn summaries in {:?}", skeletons.len(), phase.elapsed()
    );
    if skeletons.is_empty() {
        skeletons = turns
            .iter()
            .map(|turn| summarize_turn(turn, false))
            .collect();
    }
    // Where older history continues: this page's own continuation cursor.
    let mut item_cursor = items_page
        .get("nextCursor")
        .and_then(Value::as_str)
        .filter(|cursor| !cursor.is_empty())
        .map(str::to_string);
    // A refreshed tail that overlaps the cached window proves continuity.
    // Keep the immutable prefix and its exhausted/older cursor, while the new
    // tail replaces any live snapshots. Disjoint tails start a fresh window.
    let mut seen_item_cursors = HashSet::new();
    let mut restored_turns = Vec::new();
    if let Some(cached) = previous.cached.as_ref() {
        if let Some(first) = items.first() {
            if let Some(at) = cached.items.iter().position(|item| item.id == first.id) {
                let mut prefix = cached.items[..at].to_vec();
                prefix.append(&mut items);
                items = prefix;
                item_cursor = previous.next_item_cursor.clone();
                seen_item_cursors = previous.seen_item_cursors.clone();
            }
        }
    } else {
        match crate::engine::session_sync::restore_cached_prefix(
            service_key,
            thread_id,
            &mut items,
            &mut item_cursor,
            &skeletons,
        ) {
            Ok(turns) => restored_turns = turns,
            Err(error) => {
                tracing::debug!(%error, "cached prefix unavailable; keeping the fresh tail")
            },
        }
    }
    // Restored pages arrive locally without another RPC. Apply current turn
    // metadata after stitching, including to the restored opening messages.
    let mut loaded = HashSet::new();
    loaded_turns.clear();
    for item in &mut items {
        if let Some(stamp) = stamps.get(&item.turn_id) {
            item.turn_completed_at = stamp.completed_at;
            item.turn_duration_ms = stamp.duration_ms;
        }
        if item.item_type == "userMessage" && loaded.insert(item.turn_id.clone()) {
            loaded_turns.push(item.turn_id.clone());
        }
    }
    for skeleton in &mut skeletons {
        skeleton.loaded = loaded.contains(&skeleton.turn_id);
    }
    let mut turn_pages = previous.turn_pages.clone();
    let fresh: HashMap<_, _> = items.iter().map(|item| (item.id.as_str(), item)).collect();
    for mut retained in restored_turns {
        // An exhausted cached turn may have grown while offline. Without an
        // overlap, its old end cannot prove continuity with the current tail.
        let tail_turn = items
            .last()
            .is_some_and(|item| item.turn_id == retained.page.turn_id);
        if tail_turn
            && retained.cursor.is_none()
            && !retained
                .page
                .items
                .iter()
                .any(|item| fresh.contains_key(item.id.as_str()))
        {
            continue;
        }
        for item in &mut retained.page.items {
            if let Some(current) = fresh.get(item.id.as_str()) {
                *item = (*current).clone();
            }
            item.questions_json = None;
            if let Some(stamp) = stamps.get(&item.turn_id) {
                item.turn_completed_at = stamp.completed_at;
                item.turn_duration_ms = stamp.duration_ms;
            }
        }
        turn_pages
            .entry(retained.page.turn_id)
            .or_insert_with(|| TurnWindow::restored(retained.page.items, retained.cursor));
    }
    // Seeing one item from every turn does not mean every item was loaded:
    // even a single turn can fill several pages. The item cursor is authoritative.
    let has_older = item_cursor.is_some();
    if !set_pagination(service_key, thread_id, ThreadPagination {
        turn_pages,
        next_item_cursor: item_cursor,
        seen_item_cursors,
        loaded_turns,
        turn_stamps: stamps,
        metadata: None,
        cached: None,
        first_turn_id,
        ..previous
    }) {
        bail!("history changed while loading; reopen the thread");
    }

    Ok(LoadedHistory {
        items,
        turns,
        skeletons,
        has_older,
    })
}
