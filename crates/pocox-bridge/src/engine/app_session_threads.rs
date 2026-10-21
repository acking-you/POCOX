//! Thread inventory, reads, resumes, older pages and one-line summaries.

use super::*;

/// One page of older items, and whether older ones still remain.
#[derive(Clone, Debug)]
pub struct OlderPage {
    /// The older items, oldest first, to prepend to the transcript.
    pub items: Vec<ThreadItem>,
    /// Whether history continues before these.
    pub has_older: bool,
}

/// The cursor belongs to the sequential window, never to a selected turn.
pub(in crate::engine) fn history_continuation(
    service: &str,
    thread: &str,
) -> Option<Option<String>> {
    pagination_of(service, thread).map(|state| state.next_item_cursor)
}

/// Walk one page further back through a paginated thread's history.
///
/// Returns an empty page when the thread reads whole or is already at its
/// start, so the caller can treat "nothing older" and "not paginated" alike.
pub fn thread_older_page(service_key: &str, thread_id: &str) -> Result<OlderPage> {
    let client = client_for(service_key)?;
    let gate = ensure_pagination(service_key, thread_id).request_gate;
    let _request = gate
        .lock()
        .map_err(|_| anyhow!("history request lock poisoned"))?;
    let empty = || OlderPage {
        items: Vec::new(),
        has_older: false,
    };
    let Some(mut state) = pagination_of(service_key, thread_id) else {
        return Ok(empty());
    };
    let Some(cursor) = state.next_item_cursor.clone() else {
        return Ok(empty());
    };
    let page = fetch_older_item_page(service_key, &client, thread_id, &cursor, ITEM_PAGE_LIMIT)?;
    let entries = page
        .get("data")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    // Items arrive newest first within the page; the transcript reads the other
    // way, and these are prepended as a block.
    let mut items = Vec::new();
    for entry in entries.iter().rev() {
        let Some(item) = entry.get("item") else {
            continue;
        };
        let turn_id = entry
            .get("turnId")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let stamp = turn_stamp(&state.turn_stamps, turn_id);
        if parse_turn_item(item, &stamp).is_some() {
            if !state.loaded_turns.iter().any(|id| id == turn_id) {
                state.loaded_turns.insert(0, turn_id.to_string());
            }
            items.extend(parse_turn_items(item, &stamp));
        }
    }
    let next = page
        .get("nextCursor")
        .and_then(Value::as_str)
        .map(str::to_string);
    state.next_item_cursor = if entries.is_empty() {
        None
    } else {
        advancing_cursor(Some(cursor.as_str()), next, &mut state.seen_item_cursors)
    };
    let has_older = state.next_item_cursor.is_some();
    if let Some(cached) = state.cached.as_mut() {
        let history = Arc::make_mut(cached);
        let known: HashSet<_> = history.items.iter().map(|item| item.id.clone()).collect();
        let mut merged: Vec<_> = items
            .iter()
            .filter(|item| !known.contains(&item.id))
            .cloned()
            .collect();
        merged.append(&mut history.items);
        history.items = merged;
        history.has_older = has_older;
    }
    if !set_pagination(service_key, thread_id, state) {
        bail!("history changed while loading; retry the page");
    }
    Ok(OlderPage {
        items,
        has_older,
    })
}

/// Every item of one turn, oldest first — for jumping straight to a turn the
/// transcript hasn't scrolled back to yet.
pub fn thread_turn_items(
    service_key: &str,
    thread_id: &str,
    turn_id: &str,
) -> Result<Vec<ThreadItem>> {
    let client = client_for(service_key)?;
    let gate = ensure_pagination(service_key, thread_id).request_gate;
    let _request = gate
        .lock()
        .map_err(|_| anyhow!("history request lock poisoned"))?;
    let mut state = ensure_pagination(service_key, thread_id);
    let mut newest_first = Vec::new();
    let mut seen_items = HashSet::new();
    let mut cursor: Option<String> = None;
    let mut seen = HashSet::new();
    let stamp = turn_stamp(&state.turn_stamps, turn_id);
    // Bounded: a single turn can hold hundreds of items, and draining all of
    // them serially is what made opening the longest threads time out. Enough
    // pages to fill a screen; scrolling covers the rest.
    for _ in 0..MAX_TURN_ITEM_PAGES {
        let page = fetch_item_page(
            service_key,
            &client,
            thread_id,
            Some(turn_id),
            cursor.as_deref(),
            ITEM_PAGE_LIMIT,
        )?;
        let entries = page
            .get("data")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if entries.is_empty() {
            break;
        }
        for entry in &entries {
            if let Some(item) = entry.get("item") {
                newest_first.extend(
                    parse_turn_items(item, &stamp)
                        .into_iter()
                        .rev()
                        .filter(|item| seen_items.insert(item.id.clone())),
                );
            }
        }
        let next = page
            .get("nextCursor")
            .and_then(Value::as_str)
            .map(str::to_string);
        cursor = advancing_cursor(cursor.as_deref(), next, &mut seen);
        if cursor.is_none() {
            break;
        }
    }
    newest_first.reverse();
    if !state.loaded_turns.iter().any(|id| id == turn_id) {
        state.loaded_turns.push(turn_id.to_string());
    }
    if !set_pagination(service_key, thread_id, state) {
        bail!("history changed while loading; retry the turn");
    }
    Ok(newest_first)
}

/// The item snapshots this session has streamed for `thread_id`, in stream
/// order. Empty when the service has no live session.
fn buffered_items(service_key: &str, thread_id: &str) -> Vec<ThreadItem> {
    sessions()
        .lock()
        .expect("sessions poisoned")
        .get(service_key)
        .map(|s| {
            s.transcript
                .lock()
                .expect("transcript poisoned")
                .tail(thread_id, 100)
        })
        .unwrap_or_default()
}

/// List threads known to the app-server, most-recently-updated first.
///
/// The server defaults (`limit = 25`, `sortKey = created_at`) would hide older
/// threads once a user has more than 25 and would not float a recently-used but
/// older thread to the top, so request a generous page sorted by `updated_at`
/// and follow `nextCursor`. The page count and total are capped so a very large
/// history can't loop unboundedly.
pub fn thread_list(service_key: &str) -> Result<Vec<ThreadMeta>> {
    let result = thread_list_remote(service_key);
    let cached = || -> Result<Vec<ThreadMeta>> {
        let cache = crate::engine::session_cache::application_cache()?;
        let owner = crate::engine::session_cache::namespace(service_key)?;
        if let Ok(items) = &result {
            cache.write_json(&owner, "$inventory", "threads", items, false)?;
            Ok(items.clone())
        } else {
            cache
                .read_json(&owner, "$inventory", "threads")?
                .context("no cached session inventory")
        }
    };
    match (&result, cached()) {
        (Err(_), Ok(items)) => Ok(items),
        _ => result,
    }
}

fn thread_list_remote(service_key: &str) -> Result<Vec<ThreadMeta>> {
    const PAGE_LIMIT: u64 = 100;
    const MAX_THREADS: usize = 500;
    let client = client_for(service_key)?;
    let mut out = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let mut params = serde_json::Map::new();
        params.insert("limit".into(), json!(PAGE_LIMIT));
        params.insert("sortKey".into(), json!("updated_at"));
        params.insert(
            "sourceKinds".into(),
            json!(["cli", "vscode", "appServer", "exec", "subAgent", "unknown"]),
        );
        if let Some(c) = &cursor {
            params.insert("cursor".into(), json!(c));
        }
        let res =
            runtime::runtime().block_on(client.request("thread/list", Value::Object(params)))?;
        let data = res
            .get("data")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let page_len = data.len();
        out.extend(data.iter().filter_map(parse_thread_meta));
        cursor = res
            .get("nextCursor")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        if cursor.is_none() || page_len == 0 || out.len() >= MAX_THREADS {
            break;
        }
    }
    Ok(out)
}

/// Inspect a thread's classification and parent without attaching a writer.
pub fn thread_metadata(service_key: &str, thread_id: &str) -> Result<ThreadMeta> {
    let client = client_for(service_key)?;
    read_thread_metadata(&client, thread_id)
}

fn read_thread_metadata(client: &Arc<AppClient>, thread_id: &str) -> Result<ThreadMeta> {
    let response = runtime::runtime().block_on(
        client.request("thread/read", json!({"threadId": thread_id, "includeTurns": false})),
    )?;
    response
        .get("thread")
        .and_then(parse_thread_meta)
        .context("missing thread metadata")
}

/// Parse one `thread/list` entry into [`ThreadMeta`]; skips entries with no id.
pub(super) fn parse_thread_meta(t: &Value) -> Option<ThreadMeta> {
    let id = t.get("id")?.as_str()?.to_string();
    Some(ThreadMeta {
        id,
        thread_source: pocox_codex::rollout::thread_source(t),
        parent_thread_id: pocox_codex::rollout::parent_thread_id(t),
        preview: t
            .get("preview")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        // Absent on older app-servers, and null until the thread is renamed.
        name: t
            .get("name")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string),
        cwd: t
            .get("cwd")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        origin_url: t
            .get("gitInfo")
            .and_then(|g| g.get("originUrl"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string),
        updated_at: t.get("updatedAt").and_then(Value::as_i64).unwrap_or(0),
    })
}

/// Resume an existing thread, loading it from disk into the live session.
///
/// Required before `turn/start`: sending into an unresumed thread fails, since
/// the server can only run a turn on a thread in its live thread manager. Call
/// this first when opening an existing conversation.
///
/// `thread/read` no longer needs it. This doc used to say reads of an unresumed
/// thread fail with "thread not found", and that is stale — verified against
/// codex 0.146 by listing on a freshly-spawned server and reading 15 threads it
/// had never resumed: all 15 returned their turns. [`thread_summary`] relies on
/// that, so if a future upstream ever reinstates the restriction, the activity
/// view's gists are what break first.
pub fn thread_resume(service_key: &str, thread_id: &str) -> Result<()> {
    let client = client_for(service_key)?;
    let metadata = read_thread_metadata(&client, thread_id)?;
    anyhow::ensure!(
        metadata.thread_source.as_deref() != Some("guardian_review"),
        "Guardian approval sessions are read-only; open their parent session"
    );
    let res = runtime::runtime().block_on(
        client.request("thread/resume", json!({ "threadId": thread_id, "excludeTurns": true })),
    )?;
    // The resume response carries the thread's effective runtime config —
    // model, modelProvider, reasoningEffort, approvalPolicy, sandbox — none of
    // which `thread/read` exposes. Refresh the cache unconditionally: the
    // server sends `reasoningEffort: null` when no effort is set, which must
    // clear any prior cached value (e.g. after another client cleared it)
    // rather than leave it stale.
    record_runtime_config(service_key, thread_id, &res);
    Ok(())
}

pub(in crate::engine) fn external_history_changed(service_key: &str, thread_id: &str) {
    let pages = sessions().lock().ok().and_then(|sessions| {
        sessions
            .get(service_key)
            .map(|session| Arc::clone(&session.pagination))
    });
    if let Some(pages) = pages {
        invalidate_history(&pages, &Inbound {
            method: "item/completed".into(),
            params: Some(json!({"threadId": thread_id})),
            request_id: None,
        });
    }
}

/// Read a thread's materialised conversation items (oldest first) and whether
/// a turn is currently running.
///
/// Paginated threads (the default for threads created by current servers)
/// reject a whole-history read, so this loads a bounded tail of the transcript
/// plus a skeleton of every turn, and [`thread_older_page`] walks further back
/// on demand. Legacy threads keep the whole-history read: it is the only shape
/// their rollout supports, and paging methods replay the entire file per call.
pub fn thread_read(service_key: &str, thread_id: &str) -> Result<ThreadHistory> {
    thread_read_with_pages(service_key, thread_id, true)
}

/// Read the current tail, optionally omitting cached selected-turn windows.
/// Monitoring clients already hold those windows and need only tail updates.
pub fn thread_read_with_pages(
    service_key: &str,
    thread_id: &str,
    include_turn_pages: bool,
) -> Result<ThreadHistory> {
    // Each call occupies one FRB worker thread for its whole duration (the RPCs
    // below block rather than yield), so concurrent reads are capped by the pool
    // size. Log entry/exit to make a pile-up visible.
    let started = std::time::Instant::now();
    let depth = BRIDGE_BUSY.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
    let _release = BusyGuard;
    tracing::info!(
        target: "pocox_bridge::history",
        "thread_read START thread={thread_id} in_flight={depth}"
    );
    let mut result = thread_read_inner(service_key, thread_id, include_turn_pages);
    if result
        .as_ref()
        .is_err_and(|e| e.to_string().contains("history changed"))
    {
        result = thread_read_inner(service_key, thread_id, include_turn_pages);
    }
    if let Ok(history) = &result {
        crate::engine::session_sync::save_history(
            service_key,
            thread_id,
            history,
            include_turn_pages,
        );
    }
    match &result {
        Ok(history) => tracing::info!(
            target: "pocox_bridge::history",
            "thread_read DONE thread={thread_id} in {:?} items={} turns={} has_older={}",
            started.elapsed(),
            history.items.len(),
            history.turns.len(),
            history.has_older
        ),
        Err(err) => tracing::error!(
            target: "pocox_bridge::history",
            "thread_read FAILED thread={thread_id} after {:?}: {err}", started.elapsed()
        ),
    }
    result
}

fn thread_read_inner(
    service_key: &str,
    thread_id: &str,
    include_turn_pages: bool,
) -> Result<ThreadHistory> {
    let client = client_for(service_key)?;
    let gate = ensure_pagination(service_key, thread_id).request_gate;
    let _request = gate
        .lock()
        .map_err(|_| anyhow!("history request lock poisoned"))?;
    let before = ensure_pagination(service_key, thread_id);
    // Metadata only. Asking for turns here would fail outright on a paginated
    // thread, and the response carries `historyMode`, which decides the path.
    let res = crate::engine::session_sync::request(
        service_key,
        &client,
        "thread/read",
        json!({ "threadId": thread_id, "includeTurns": false }),
    )?;
    let paginated = res
        .get("thread")
        .and_then(|t| t.get("historyMode"))
        .and_then(Value::as_str)
        .is_some_and(|mode| mode == "paginated")
        || crate::engine::session_sync::enabled(service_key);
    let metadata = res.get("thread").cloned();
    let cached = pagination_of(service_key, thread_id)
        .filter(|state| {
            state.generation == before.generation
                && state.source_revision == before.source_revision
                && state.metadata.is_some()
                && state.metadata == metadata
        })
        .and_then(|state| state.cached);
    let loaded = if let Some(cached) = cached {
        (*cached).clone()
    } else if paginated {
        match load_paginated_window(&client, service_key, thread_id) {
            Ok(loaded) => loaded,
            // A server too old to page can still answer the whole-history read.
            Err(err)
                if !crate::engine::session_sync::enabled(service_key)
                    && is_unknown_method(&err) =>
            {
                reset_pagination(service_key, thread_id);
                load_whole_history(&client, thread_id)?
            },
            Err(err) => return Err(err),
        }
    } else {
        reset_pagination(service_key, thread_id);
        load_whole_history(&client, thread_id)?
    };
    if paginated {
        cache_history(service_key, thread_id, before.source_revision, metadata, &loaded);
    }
    let LoadedHistory {
        mut items,
        turns,
        skeletons,
        has_older,
    } = loaded;
    let thread = res.get("thread");
    // Merge in any items this session streamed that `thread/read` didn't return
    // — an in-progress turn's thinking/tool items are buffered by the forwarder
    // but the server omits them here — preserving their stream order so a
    // re-opened conversation shows the live progress instead of a blank turn.
    {
        let positions: HashMap<String, usize> = items
            .iter()
            .enumerate()
            .map(|(index, item)| (item.id.clone(), index))
            .collect();
        for buffered in buffered_items(service_key, thread_id) {
            if let Some(index) = positions.get(&buffered.id) {
                if buffered.item_type == "autoApprovalReview"
                    && (items[*index].title == "inProgress" || buffered.title != "inProgress")
                {
                    items[*index] = buffered;
                } else {
                    items[*index].questions_json = buffered.questions_json;
                }
            } else {
                items.push(buffered);
            }
        }
    }
    // A turn is live if the last turn's status is still in progress.
    let running = turns
        .last()
        .and_then(|t| t.get("status"))
        .and_then(Value::as_str)
        .map(|s| s == "inProgress" || s == "in_progress")
        .unwrap_or(false);
    // On a cold open the forwarder may not have seen this turn's `turn/started`,
    // so seed the active turn id from the last (running) turn for interrupt.
    if running {
        if let Some(turn_id) = turns.last().and_then(extract_turn_id) {
            record_active_turn(service_key, thread_id, turn_id);
        }
    }
    let branch = thread
        .and_then(|t| t.get("gitInfo"))
        .and_then(|g| g.get("branch"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let usage = thread.and_then(|t| t.get("tokenUsage"));
    let (tokens_used, context_window) = parse_token_usage(usage);
    let cwd = thread
        .and_then(|t| t.get("cwd"))
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    // The runtime config (model / effort / permissions / collaboration mode)
    // comes from the cached start/resume response and live settings updates.
    // The Thread fields below refresh model and effort on current servers.
    let runtime = thread_runtime_config(service_key, thread_id).unwrap_or_default();
    // Current servers report collaboration mode in resume/settings responses.
    // Retain support for peers that also expose it in thread metadata.
    let collaboration_mode = runtime.collaboration_mode.clone().or_else(|| {
        thread
            .and_then(|t| {
                t.get("collaborationMode")
                    .or_else(|| t.get("status").and_then(|s| s.get("collaborationMode")))
                    .or_else(|| t.get("settings").and_then(|s| s.get("collaborationMode")))
            })
            .and_then(|mode| parse_collaboration_mode(Some(mode)))
    });
    let runtime = runtime_config_with_thread(runtime, thread);
    let reasoning_effort = runtime.reasoning_effort.clone();
    Ok(ThreadHistory {
        history_epoch: crate::engine::session_sync::source_generation(service_key, thread_id),
        items,
        running,
        active_turn_id: if running {
            turns
                .last()
                .and_then(extract_turn_id)
                .and_then(|id| id.as_str().map(str::to_string))
        } else {
            None
        },
        branch,
        cwd,
        tokens_used,
        context_window,
        collaboration_mode,
        reasoning_effort,
        model: runtime.model,
        model_provider: runtime.model_provider,
        approval_policy: runtime.approval_policy,
        approvals_reviewer: runtime.approvals_reviewer,
        service_tier: runtime.service_tier,
        sandbox_mode: runtime.sandbox_mode,
        config_confirmed: runtime.confirmed_by_update,
        has_older,
        turns: skeletons,
        first_turn_id: pagination_of(service_key, thread_id).and_then(|p| p.first_turn_id),
        turn_pages: if include_turn_pages {
            cached_turn_pages(service_key, thread_id)
        } else {
            Vec::new()
        },
    })
}

/// A one-line gist of where a thread got to: the opening sentence of its most
/// recent agent message, or `None` when it has produced none yet.
///
/// Exists as its own call rather than a field on `thread_list` because the
/// upstream `thread/list` doesn't carry a summary — the only source is
/// `thread/read`, which returns the WHOLE history. Doing that per row would be
/// far too expensive, so the UI fetches these lazily for the rows it actually
/// shows and this returns just the sentence rather than shipping a transcript
/// across the bridge for the caller to trim.
pub fn thread_summary(service_key: &str, thread_id: &str) -> Result<Option<String>> {
    // The async API runs these on the engine's blocking executor, separate from
    // interactive FRB workers. Count them with other history calls for diagnosis.
    let depth = BRIDGE_BUSY.fetch_add(1, std::sync::atomic::Ordering::Relaxed) + 1;
    let _release = BusyGuard;
    if depth > 4 {
        tracing::warn!(
            target: "pocox_bridge::history",
            "thread_summary thread={thread_id} with {depth} history calls in flight"
        );
    }
    let client = client_for(service_key)?;
    // A summary view of the newest turns carries each one's final agent message,
    // which is exactly the sentence wanted — no need to read the transcript.
    // Several turns, not one, because the newest may be a tool-only turn that
    // produced no prose.
    let turns =
        match fetch_turn_page(service_key, &client, thread_id, None, INITIAL_TURN_LIMIT, "summary")
        {
            Ok(page) => {
                let mut turns = page
                    .get("data")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                // The walk below reads oldest first and steps backwards.
                turns.reverse();
                turns
            },
            // Older servers have no paging methods; their history reads whole.
            Err(err) if is_unknown_method(&err) => {
                let res = runtime::runtime().block_on(client.request(
                    "thread/read",
                    json!({ "threadId": thread_id, "includeTurns": true }),
                ))?;
                res.get("thread")
                    .and_then(|t| t.get("turns"))
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default()
            },
            Err(err) => return Err(err),
        };
    // Walk backwards: the newest agent message is the interesting one, and
    // stopping at the first hit avoids parsing a long history twice over.
    for turn in turns.iter().rev() {
        let Some(items) = turn.get("items").and_then(Value::as_array) else {
            continue;
        };
        for item in items.iter().rev() {
            let is_agent = item
                .get("type")
                .or_else(|| item.get("itemType"))
                .and_then(Value::as_str)
                .is_some_and(|t| t.contains("agentMessage"));
            if !is_agent {
                continue;
            }
            if let Some(text) = agent_text_of(item) {
                if let Some(line) = first_sentence(&text) {
                    return Ok(Some(line));
                }
            }
        }
    }
    Ok(None)
}

/// The text of an `agentMessage` item, whichever shape the server used.
fn agent_text_of(item: &Value) -> Option<String> {
    for key in ["text", "message", "content"] {
        if let Some(s) = item.get(key).and_then(Value::as_str) {
            if !s.trim().is_empty() {
                return Some(s.to_string());
            }
        }
    }
    None
}

/// The first sentence of `text`, collapsed to one line and length-capped.
///
/// Markdown structure is stripped rather than rendered: this lands in a
/// two-line list row, where a heading marker or bullet would read as noise.
pub(super) fn first_sentence(text: &str) -> Option<String> {
    let flat = text
        .lines()
        .map(str::trim)
        // Skip fences, headings and blank lines — a summary that opens with
        // "```" or "##" tells the reader nothing.
        .filter(|l| !l.is_empty() && !l.starts_with("```") && !l.starts_with('#'))
        .map(|l| l.trim_start_matches(['-', '*', '>', ' ']).trim())
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    let flat = flat.trim();
    if flat.is_empty() {
        return None;
    }
    // Cut at the first sentence end (CJK punctuation included, since the app is
    // used in Chinese), else fall back to a hard cap.
    const MAX: usize = 160;
    let chars: Vec<char> = flat.chars().collect();
    let mut out = String::new();
    for (i, ch) in chars.iter().enumerate() {
        out.push(*ch);
        if is_sentence_end(&chars, i) {
            break;
        }
        if out.chars().count() >= MAX {
            out.push('…');
            break;
        }
    }
    Some(out.trim().to_string())
}

/// Whether `chars[i]` ends a sentence.
///
/// CJK terminators always do. An ASCII `.` needs BOTH sides to agree:
///
/// * what follows looks like a break — end of text, or a space then a
///   capital/CJK character. Keying on this (rather than on how much text came
///   before) is what keeps "v1.2 已发布。" from being cut at the version dot; a
///   length floor would also have swallowed the short sentence after it.
/// * the word it closes isn't a known abbreviation. Looking only forward made
///   "Dr. Smith fixed the issue." summarize to "Dr." — a capitalised proper
///   noun after an abbreviation is ordinary English, not a sentence boundary.
fn is_sentence_end(chars: &[char], i: usize) -> bool {
    match chars[i] {
        '。' | '！' | '？' => true,
        '.' | '!' | '?' => {
            let breaks_after = match chars.get(i + 1) {
                None => true,
                Some(' ') => chars
                    .get(i + 2)
                    .is_none_or(|c| c.is_uppercase() || !c.is_ascii()),
                _ => false,
            };
            // `!`/`?` are never part of an abbreviation, so only `.` looks back.
            breaks_after && (chars[i] != '.' || !closes_abbreviation(chars, i))
        },
        _ => false,
    }
}

/// Abbreviations whose trailing period is not a sentence end. Lowercase,
/// without the final dot; a multi-dot form like `u.s.` is matched whole.
const ABBREVIATIONS: &[&str] = &[
    "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "eg", "ie", "e.g", "i.e",
    "approx", "no", "fig", "al", "inc", "ltd", "co", "corp", "dept", "est", "min", "max", "u.s",
    "u.k", "a.m", "p.m", "cf", "resp", "ca",
];

/// Whether the `.` at `chars[i]` closes a token in [`ABBREVIATIONS`].
///
/// Walks back over the word, keeping interior dots so `U.S.` and `e.g.` match
/// as single tokens rather than as a bare trailing `s` / `g`. A single-letter
/// word counts too: `A. Smith` is an initial, not a sentence.
fn closes_abbreviation(chars: &[char], i: usize) -> bool {
    let mut start = i;
    while start > 0 {
        let prev = chars[start - 1];
        if prev.is_alphanumeric() || prev == '.' {
            start -= 1;
        } else {
            break;
        }
    }
    if start == i {
        return false; // a lone "." with no word before it
    }
    let word: String = chars[start..i].iter().collect::<String>().to_lowercase();
    // "A." / "J." — an initial in a name, never a sentence end.
    if word.chars().count() == 1 && word.chars().all(char::is_alphabetic) {
        return true;
    }
    ABBREVIATIONS.contains(&word.as_str())
}

/// Discard session-local windows when the source reports replacement.
pub(in crate::engine) fn reset_synced_history(service: &str, thread: &str) {
    history_cache::replace_history(service, thread);
    if let Ok(sessions) = sessions().lock() {
        if let Some(session) = sessions.get(service) {
            if let Ok(mut transcript) = session.transcript.lock() {
                transcript.remove(thread);
            }
        }
    }
}

/// Project a synchronized read-only tail without attaching a controller.
pub(in crate::engine) fn parse_prefetched_items(response: &Value) -> Vec<ThreadItem> {
    let stamps = HashMap::new();
    response
        .get("data")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .rev()
        .flat_map(|entry| {
            let stamp = turn_stamp(
                &stamps,
                entry
                    .get("turnId")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            );
            entry
                .get("item")
                .map(|item| parse_turn_items(item, &stamp))
                .unwrap_or_default()
        })
        .collect()
}
