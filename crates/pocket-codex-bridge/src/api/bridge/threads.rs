//! App-server remote control: threads, turns, history pages and the persistent
//! history cache.

use super::*;

/// Thread summary mirrored for Dart.
pub struct ThreadMetaDto {
    /// Thread id.
    pub id: String,
    /// Preview (usually the first user message).
    pub preview: String,
    /// User-set title, or `None` when the thread was never renamed (the UI
    /// falls back to `preview`).
    pub name: Option<String>,
    /// App-owned classification, including `pocket-codex-voice`.
    pub thread_source: Option<String>,
    /// Parent thread for a spawned child.
    pub parent_thread_id: Option<String>,
    /// Working directory (the project the thread controls).
    pub cwd: String,
    /// The repository's remote, when the agent reports one.
    pub origin_url: Option<String>,
    /// Unix seconds of last update.
    pub updated_at: i64,
}

/// One model offered by the app-server, mirrored for Dart.
pub struct ModelInfoDto {
    /// Model id (used as the `model` param).
    pub id: String,
    /// Human-readable name.
    pub display_name: String,
    /// Short description.
    pub description: String,
    /// Reasoning efforts this model supports (so the UI offers only valid
    /// levels).
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

/// One materialised conversation item mirrored for Dart.
pub struct ThreadItemDto {
    /// Item id.
    pub id: String,
    /// Item type tag (`userMessage` / `agentMessage` / `commandExecution` /
    /// `webSearch` / `mcpToolCall` / `fileChange` / `reasoning` / …).
    pub item_type: String,
    /// One-line summary for tool/activity items.
    pub title: String,
    /// Body / detail text.
    pub text: String,
    /// Structured asynchronous questions on an agent message, as JSON.
    pub questions_json: Option<String>,
    /// User attachments or generated artifacts, as data URLs or host paths.
    pub images: Vec<String>,
    /// Id of the turn this item belongs to — the server's own turn boundary
    /// (`thread/read` nests items under their turn), so the UI can render one
    /// turn's reply as one block instead of inferring boundaries from the item
    /// sequence. Empty when the item came from the live stream buffer.
    pub turn_id: String,
    /// Unix seconds when this item's turn completed; `None` while it runs.
    pub turn_completed_at: Option<i64>,
    /// This item's turn duration in milliseconds, when the server reports it.
    pub turn_duration_ms: Option<i64>,
}

/// A thread's recovered history + whether a turn is still running, plus the
/// metadata the status bar / git chip seed from on open.
pub struct ThreadHistoryDto {
    /// Source generation used to invalidate replaced historical UI windows.
    pub history_epoch: Option<String>,
    /// Conversation items, oldest first.
    pub items: Vec<ThreadItemDto>,
    /// Whether the most recent turn is still in progress.
    pub running: bool,
    /// Identity from the same turn snapshot that established `running`.
    pub active_turn_id: Option<String>,
    /// Current git branch of the thread's cwd, if it's a repo.
    pub branch: Option<String>,
    /// The thread's resolved working directory (for git diff / status).
    pub cwd: Option<String>,
    /// Tokens currently occupying the model context window.
    pub tokens_used: Option<i64>,
    /// The model's context-window size in tokens.
    pub context_window: Option<i64>,
    /// Sticky collaboration mode (`"plan"` / `"default"`) so the UI plan toggle
    /// reflects the server's real state.
    pub collaboration_mode: Option<String>,
    /// Current reasoning effort (`"low"`/`"medium"`/`"high"`) so the UI can
    /// show the "thinking level" the thread runs with (from the resume
    /// response).
    pub reasoning_effort: Option<String>,
    /// The effective model id the thread runs with, per the server. `None`
    /// when the server never reported it (older servers).
    pub model: Option<String>,
    /// Provider of the effective model (e.g. `openai`), when reported.
    pub model_provider: Option<String>,
    /// The effective approval policy (`untrusted`/`on-failure`/`on-request`/
    /// `never`/`granular`), when reported.
    pub approval_policy: Option<String>,
    /// Approval reviewer (`user` or `auto_review`), when reported.
    pub approvals_reviewer: Option<String>,
    /// Effective service tier, when reported.
    pub service_tier: Option<String>,
    /// The effective sandbox mode (`read-only`/`workspace-write`/
    /// `danger-full-access`/`external-sandbox`), when reported.
    pub sandbox_mode: Option<String>,
    /// Whether a live `thread/settings/updated` notification has confirmed
    /// this config (vs only a start/resume snapshot).
    pub config_confirmed: bool,
    /// Whether earlier items remain unread — [`app_thread_older_page`] fetches
    /// them. False for a thread whose history arrives whole.
    pub has_older: bool,
    /// One entry per turn in the WHOLE thread, oldest first, including turns
    /// whose items aren't loaded yet. The turn rail shows a conversation's
    /// shape, so it needs every turn even before their bodies are read.
    pub turns: Vec<TurnSummaryDto>,
    /// Actual first turn when the server's summary cursor was exhausted.
    pub first_turn_id: Option<String>,
    /// Cached pages of independently selected turns.
    pub turn_pages: Vec<TurnItemsPageDto>,
}

/// A selected turn's bounded, ascending history window.
pub struct TurnItemsPageDto {
    /// Turn owning the window.
    pub turn_id: String,
    /// Loaded items in chronological order.
    pub items: Vec<ThreadItemDto>,
    /// Whether this turn still has a continuation page.
    pub has_more: bool,
}

fn turn_page_dto(page: app_session::TurnItemsPage) -> TurnItemsPageDto {
    TurnItemsPageDto {
        turn_id: page.turn_id,
        items: page.items.into_iter().map(item_dto).collect(),
        has_more: page.has_more,
    }
}

/// Read or continue a selected turn, reusing its previously loaded pages.
/// `delta_only` opts into new items only on continuation; omission preserves
/// cumulative windows for older callers. Opening always returns the cached
/// prefix.
pub fn app_thread_turn_page(
    service_key: String,
    thread_id: String,
    turn_id: String,
    load_more: bool,
    delta_only: Option<bool>,
) -> Result<TurnItemsPageDto> {
    engine(&service_key)
        .thread_turn_page(
            &service_key,
            &thread_id,
            &turn_id,
            load_more,
            delta_only.unwrap_or(false),
        )
        .map(turn_page_dto)
}

/// A turn reduced to what the rail shows.
pub struct TurnSummaryDto {
    /// Id of the turn, for fetching its items on demand.
    pub turn_id: String,
    /// The user's message that opened the turn; empty when it had none.
    pub user_text: String,
    /// The turn's final agent message; empty when it produced no prose.
    pub assistant_text: String,
    /// Whether this turn's items are already in the transcript.
    pub loaded: bool,
}

/// One page of older items, and whether history continues before them.
pub struct OlderPageDto {
    /// Older items, oldest first, to prepend to the transcript.
    pub items: Vec<ThreadItemDto>,
    /// Whether older items still remain.
    pub has_older: bool,
}

/// The server-reported runtime configuration of a thread — what its turns
/// actually run with. Mirrors the engine cache fed by `thread/start` /
/// `thread/resume` responses and live `thread/settings/updated` notifications;
/// every field is `None` when the server hasn't said (never a guess).
pub struct ThreadRuntimeConfigDto {
    /// Effective model id.
    pub model: Option<String>,
    /// Provider of the effective model.
    pub model_provider: Option<String>,
    /// Effective reasoning effort.
    pub reasoning_effort: Option<String>,
    /// Effective approval policy.
    pub approval_policy: Option<String>,
    /// Approval reviewer (`user` or `auto_review`), when reported.
    pub approvals_reviewer: Option<String>,
    /// Effective service tier, when reported.
    pub service_tier: Option<String>,
    /// Effective sandbox mode (kebab wire string).
    pub sandbox_mode: Option<String>,
    /// Effective collaboration mode (`plan`/`default`), when reported.
    pub collaboration_mode: Option<String>,
    /// True once a live settings update confirmed this config.
    pub confirmed_by_update: bool,
}

/// List threads known to the app-server.
pub fn app_thread_list(service_key: String) -> Result<Vec<ThreadMetaDto>> {
    let threads = engine(&service_key).thread_list(&service_key)?;
    Ok(threads.into_iter().map(thread_meta_dto).collect())
}

/// Inspect one thread without resuming it or taking ownership. Native Codex
/// only (callers gate on `native_metadata`); other protocols are refused
/// before any network call.
pub fn app_thread_metadata(service_key: String, thread_id: String) -> Result<ThreadMetaDto> {
    require_native(&service_key, "thread metadata")?;
    app_session::thread_metadata(&service_key, &thread_id).map(thread_meta_dto)
}

fn thread_meta_dto(t: app_session::ThreadMeta) -> ThreadMetaDto {
    ThreadMetaDto {
        id: t.id,
        preview: t.preview,
        name: t.name,
        thread_source: t.thread_source,
        parent_thread_id: t.parent_thread_id,
        cwd: t.cwd,
        origin_url: t.origin_url,
        updated_at: t.updated_at,
    }
}

/// List the models the app-server offers.
pub fn app_model_list(service_key: String) -> Result<Vec<ModelInfoDto>> {
    app_model_list_for_project(service_key, None)
}

/// List native project models; other engines retain their existing catalog.
pub fn app_model_list_for_project(
    service_key: String,
    directory: Option<String>,
) -> Result<Vec<ModelInfoDto>> {
    let models = if session_engine::protocol_of(&service_key) == session_engine::Protocol::OpenCode
    {
        crate::engine::opencode::models_for_project(&service_key, directory.as_deref())?
    } else {
        engine(&service_key).model_list(&service_key)?
    };
    Ok(models
        .into_iter()
        .map(|m| ModelInfoDto {
            id: m.id,
            display_name: m.display_name,
            description: m.description,
            supported_reasoning_efforts: m.supported_reasoning_efforts,
            default_reasoning_effort: m.default_reasoning_effort,
            supported_service_tiers: m.supported_service_tiers,
            default_service_tier: m.default_service_tier,
            is_default: m.is_default,
        })
        .collect())
}

/// Send a thread realtime control request; returns the upstream JSON result.
/// Accepts the six `thread/realtime/*` methods, `thread/timeline/list`,
/// marked voice `thread/start` (and ephemeral dictation `thread/start`), and
/// `thread/unsubscribe`.
pub fn app_realtime_request(
    service_key: String,
    method: String,
    params_json: String,
) -> Result<String> {
    // Live voice and dictation are native Codex realtime features. An ACP
    // agent's audio prompt support is a different thing and is not routed here.
    require_native(&service_key, "realtime voice")?;
    app_session::realtime_request(&service_key, &method, &params_json)
}

/// Start a new thread / project. `approval_policy` is one of
/// `untrusted` / `on-failure` / `on-request` / `never`; `sandbox` is one of
/// `read-only` / `workspace-write` / `danger-full-access`. Returns the id.
pub fn app_thread_start(
    service_key: String,
    model: Option<String>,
    cwd: Option<String>,
    approval_policy: Option<String>,
    approvals_reviewer: Option<String>,
    service_tier: Option<String>,
    sandbox: Option<String>,
) -> Result<String> {
    let epoch = crate::engine::transport::epoch();
    let cwd = match cwd.filter(|path| !path.trim().is_empty()) {
        Some(explicit) => Some(explicit),
        None => host_sessions::meta_ensure_default_project(service_key.clone())?,
    };
    if !crate::engine::transport::is_current(epoch) {
        anyhow::bail!("connection changed before the conversation was created; try again");
    }
    engine(&service_key).thread_start(&service_key, StartOptions {
        model,
        cwd,
        approval_policy,
        approvals_reviewer,
        service_tier,
        sandbox,
    })
}

/// Append an asynchronous answer and return the accepted active turn ID.
pub fn app_turn_steer(
    service_key: String,
    thread_id: String,
    turn_id: Option<String>,
    text: String,
    images: Option<Vec<String>>,
) -> Result<String> {
    engine(&service_key).turn_steer(
        &service_key,
        &thread_id,
        turn_id.as_deref(),
        &text,
        &images.unwrap_or_default(),
    )
}

/// What became of [`app_turn_supplement`].
pub struct AppTurnSupplementDto {
    /// `injected`: the running turn took it. `promptRequired`: no turn was
    /// running and nothing was consumed; send it as an ordinary prompt.
    pub outcome: String,
    /// The turn that took it (`injected` only).
    pub turn_id: Option<String>,
}

/// Add input to the running turn `turn_id` (Codex `turn/steer`, or the ACP
/// agent's negotiated steering). An ACP agent that finds no turn running
/// answers `promptRequired` (nothing consumed); Codex answers `injected` or
/// fails, as [`app_turn_steer`] does. An error means the input was refused
/// or its fate is unknown, and it is never retried.
pub fn app_turn_supplement(
    service_key: String,
    thread_id: String,
    turn_id: Option<String>,
    text: String,
    images: Option<Vec<String>>,
) -> Result<AppTurnSupplementDto> {
    let outcome = engine(&service_key).turn_supplement(
        &service_key,
        &thread_id,
        turn_id.as_deref(),
        &text,
        &images.unwrap_or_default(),
    )?;
    Ok(match outcome {
        session_engine::Supplement::Injected(turn) => AppTurnSupplementDto {
            outcome: "injected".into(),
            turn_id: Some(turn),
        },
        session_engine::Supplement::PromptRequired => AppTurnSupplementDto {
            outcome: "promptRequired".into(),
            turn_id: None,
        },
    })
}

/// Answer a server approval request. For Codex `decision` is
/// the wire value the session layer recognises: `accept` or
/// `acceptForSession` to grant, any other value (e.g. `decline`) to decline.
/// For an ACP permission (`acp/permission/requested`) `decision` is the
/// agent's own option id, passed verbatim; an option the request did not
/// offer is refused and the request stays pending.
pub fn app_respond_approval(
    service_key: String,
    request_id: String,
    decision: String,
) -> Result<()> {
    engine(&service_key).respond_approval(&service_key, &request_id, &decision)
}

/// Answer an `item/tool/requestUserInput` elicitation (the model asking the
/// user structured questions, NOT a command/file approval). `answers_json` is a
/// JSON object mapping each question id to its chosen answer string(s) (option
/// labels and/or free-text), e.g. `{"theme":["山水抒怀"]}`; an empty object
/// `{}` cancels. The session layer wraps it into the protocol's
/// `ToolRequestUserInputResponse` so the model actually receives the user's
/// selections.
pub fn app_respond_user_input(
    service_key: String,
    request_id: String,
    answers_json: String,
) -> Result<()> {
    engine(&service_key).respond_user_input(&service_key, &request_id, &answers_json)
}

/// Resume an existing thread (load it into the session) before reading it or
/// sending turns; otherwise the server reports "thread not found".
pub fn app_thread_resume(service_key: String, thread_id: String) -> Result<()> {
    engine(&service_key).thread_resume(&service_key, &thread_id)
}

pub(super) fn item_dto(i: app_session::ThreadItem) -> ThreadItemDto {
    ThreadItemDto {
        id: i.id,
        item_type: i.item_type,
        title: i.title,
        text: i.text,
        images: i.images,
        turn_id: i.turn_id,
        turn_completed_at: i.turn_completed_at,
        turn_duration_ms: i.turn_duration_ms,
        questions_json: i.questions_json,
    }
}

/// Read a thread's conversation items (oldest first) and whether a turn is
/// still running, so re-opening an in-flight thread restores live state.
///
/// A paginated thread returns only its newest turns' items — walk further back
/// with [`app_thread_older_page`] — plus a summary of every turn in `turns`.
/// Monitoring clients set `include_turn_pages` to false to omit cached windows
/// they already hold. Omission retains the full reopening response.
pub fn app_thread_read(
    service_key: String,
    thread_id: String,
    include_turn_pages: Option<bool>,
) -> Result<ThreadHistoryDto> {
    let h = engine(&service_key).thread_read(
        &service_key,
        &thread_id,
        include_turn_pages.unwrap_or(true),
    )?;
    Ok(history_dto(h))
}

fn history_dto(h: app_session::ThreadHistory) -> ThreadHistoryDto {
    ThreadHistoryDto {
        history_epoch: h.history_epoch,
        items: h.items.into_iter().map(item_dto).collect(),
        running: h.running,
        active_turn_id: h.active_turn_id,
        branch: h.branch,
        cwd: h.cwd,
        tokens_used: h.tokens_used,
        context_window: h.context_window,
        collaboration_mode: h.collaboration_mode,
        reasoning_effort: h.reasoning_effort,
        model: h.model,
        model_provider: h.model_provider,
        approval_policy: h.approval_policy,
        approvals_reviewer: h.approvals_reviewer,
        service_tier: h.service_tier,
        sandbox_mode: h.sandbox_mode,
        config_confirmed: h.config_confirmed,
        has_older: h.has_older,
        first_turn_id: h.first_turn_id,
        turn_pages: h.turn_pages.into_iter().map(turn_page_dto).collect(),
        turns: h
            .turns
            .into_iter()
            .map(|t| TurnSummaryDto {
                turn_id: t.turn_id,
                user_text: t.user_text,
                assistant_text: t.assistant_text,
                loaded: t.loaded,
            })
            .collect(),
    }
}

/// One page further back through a paginated thread's history.
///
/// Returns an empty page when the thread reads whole or is already at its
/// start.
pub fn app_thread_older_page(service_key: String, thread_id: String) -> Result<OlderPageDto> {
    let page = engine(&service_key).thread_older_page(&service_key, &thread_id)?;
    Ok(OlderPageDto {
        items: page.items.into_iter().map(item_dto).collect(),
        has_older: page.has_older,
    })
}

/// Every item of one turn, oldest first — for jumping to a turn the transcript
/// hasn't scrolled back to yet.
pub fn app_thread_turn_items(
    service_key: String,
    thread_id: String,
    turn_id: String,
) -> Result<Vec<ThreadItemDto>> {
    Ok(engine(&service_key)
        .thread_turn_items(&service_key, &thread_id, &turn_id)?
        .into_iter()
        .map(item_dto)
        .collect())
}

/// The latest server-reported runtime config for a thread (from its
/// start/resume response, kept fresh by live `thread/settings/updated`
/// notifications), or `None` when the server hasn't reported any. Reads the
/// engine cache only — no RPC — so the UI can poll it cheaply after a send.
#[frb(sync)]
pub fn app_thread_runtime_config(
    service_key: String,
    thread_id: String,
) -> Option<ThreadRuntimeConfigDto> {
    let config = engine(&service_key).thread_runtime_config(&service_key, &thread_id);
    config.map(|c| ThreadRuntimeConfigDto {
        model: c.model,
        model_provider: c.model_provider,
        reasoning_effort: c.reasoning_effort,
        approval_policy: c.approval_policy,
        approvals_reviewer: c.approvals_reviewer,
        service_tier: c.service_tier,
        sandbox_mode: c.sandbox_mode,
        collaboration_mode: c.collaboration_mode,
        confirmed_by_update: c.confirmed_by_update,
    })
}

/// Read the account rate-limit / quota snapshot as raw JSON (5h + weekly
/// windows). Parsed on the Dart side since the shape is nested and volatile.
pub fn app_rate_limits(service_key: String) -> Result<String> {
    require_native(&service_key, "rate limits")?;
    app_session::rate_limits(&service_key)
}

/// Unified diff of the repo at `cwd` vs its remote default branch. Empty when
/// the cwd isn't a git repo or there are no changes.
pub fn app_git_diff(service_key: String, cwd: String) -> Result<String> {
    engine(&service_key).git_diff(&service_key, &cwd)
}

/// Start a manual conversation compaction; the server emits `thread/compacted`
/// when done.
pub fn app_compact(service_key: String, thread_id: String) -> Result<()> {
    engine(&service_key).compact(&service_key, &thread_id)
}

/// A one-line gist of where a thread got to (the opening sentence of its most
/// recent agent message), or `None` when it has produced none.
///
/// Its own call rather than a field on [`app_thread_list`] because the upstream
/// `thread/list` carries no summary: the only source is a full `thread/read`,
/// so the UI fetches these lazily for the rows it actually shows instead of
/// paying for every conversation up front.
pub async fn app_thread_summary(service_key: String, thread_id: String) -> Result<Option<String>> {
    // Engines without a summary source answer `None` without any I/O.
    if !matches!(session_engine::protocol_of(&service_key), Protocol::CodexAppServer) {
        return engine(&service_key).thread_summary(&service_key, &thread_id);
    }
    // Summary RPCs must not occupy the CPU-sized FRB pool, even on one-core
    // devices. The UI separately bounds how many background requests run.
    runtime::runtime()
        .spawn_blocking(move || engine(&service_key).thread_summary(&service_key, &thread_id))
        .await?
}

/// Rename a conversation. The title is persisted by the app-server (so it
/// follows the thread across devices); an empty `name` clears it, and the UI
/// falls back to the thread preview.
pub fn app_set_thread_name(service_key: String, thread_id: String, name: String) -> Result<()> {
    engine(&service_key).set_thread_name(&service_key, &thread_id, &name)
}

/// Send a user message (text and/or attached images), starting a model turn.
/// `images` are `data:image/...;base64,...` URLs — the wire form that reaches
/// BOTH local and relay-tunneled remote app-servers (a host filesystem path
/// would not); pass an empty list for a text-only turn, and text may be empty
/// when at least one image is attached. `model` / `approval_policy` /
/// `sandbox` are optional per-turn overrides (apply to this and subsequent
/// turns) so model and permission can change mid-conversation.
/// `collaboration_mode` ("plan" / "default", or null to leave unchanged) is
/// sticky on the thread, so pass "default" to leave plan mode.
/// `reasoning_effort` ("low"/"medium"/"high", or null for the model default) is
/// the "thinking level" for this turn. The reply streams via [`app_events`];
/// this returns once the turn is accepted.
#[allow(clippy::too_many_arguments)]
pub fn app_turn_start(
    service_key: String,
    thread_id: String,
    text: String,
    images: Vec<String>,
    model: Option<String>,
    approval_policy: Option<String>,
    approvals_reviewer: Option<String>,
    service_tier: Option<String>,
    sandbox: Option<String>,
    collaboration_mode: Option<String>,
    reasoning_effort: Option<String>,
) -> Result<()> {
    engine(&service_key).turn_start(&service_key, &thread_id, TurnOptions {
        text,
        images,
        model,
        approval_policy,
        approvals_reviewer,
        service_tier,
        sandbox,
        collaboration_mode,
        reasoning_effort,
    })
}

/// Interrupt the running turn. `turn_id` (from the latest `turn/started`) is
/// required by the server; pass null only if unknown.
pub fn app_turn_interrupt(
    service_key: String,
    thread_id: String,
    turn_id: Option<String>,
) -> Result<()> {
    engine(&service_key).turn_interrupt(&service_key, &thread_id, turn_id)
}

/// Load a display-only persisted history without contacting a host.
pub fn app_history_cached(
    service_key: String,
    thread_id: String,
) -> Result<Option<ThreadHistoryDto>> {
    Ok(crate::engine::session_sync::cached_history(&service_key, &thread_id)?.map(history_dto))
}

/// Negotiate the independent meta history protocol before remote reads.
pub fn app_history_sync_prepare(service_key: String) -> Result<bool> {
    // The meta history protocol reads Codex rollouts; ACP history is the
    // host's retained window.
    if session_engine::protocol_of(&service_key) != Protocol::CodexAppServer {
        return Ok(false);
    }
    crate::engine::session_sync::prepare(&service_key)
}

/// Prefetch only a bounded running-session tail without resuming it.
pub fn app_history_prefetch(service_key: String, thread_id: String) -> Result<()> {
    if session_engine::protocol_of(&service_key) != Protocol::CodexAppServer {
        return Ok(());
    }
    crate::engine::session_sync::prefetch(&service_key, &thread_id)
}

/// Prioritize the current reader over background prefetch in the disk cache.
pub fn app_history_focus(service_key: String, thread_id: Option<String>) -> Result<()> {
    crate::engine::session_cache::set_focus(&service_key, thread_id.as_deref())
}

/// Controller-wide persistent cache capacity and actual disk usage.
pub struct HistoryCacheStatusDto {
    /// Shared capacity in decimal MB; zero disables persistence.
    pub limit_mb: u32,
    /// Bytes currently allocated to cache entries, including metadata.
    pub used_bytes: u64,
}

/// Inspect and enforce the shared disk quota without contacting any host.
pub fn history_cache_status() -> Result<HistoryCacheStatusDto> {
    let cfg = config::load_config(&runtime::support_dir()?)?;
    Ok(HistoryCacheStatusDto {
        limit_mb: cfg.history_cache.disk_limit_mb,
        used_bytes: crate::engine::session_cache::application_cache()?.usage()?,
    })
}

/// Set the shared cache quota, immediately evicting cold disposable windows.
pub fn history_cache_set_limit(limit_mb: u32) -> Result<()> {
    crate::engine::session_cache::set_limit(&runtime::support_dir()?, limit_mb)
}
