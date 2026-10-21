//! Bounded local provider views, independent of ACP connections.
use anyhow::{Context, Result};
use pocox_host_svc::native_history::NativeFollow;

use super::{
    host_sessions::{meta_liveness_dto, LocalSessionDto, SessionLivenessDto},
    threads::{item_dto, ThreadItemDto},
    StreamSink,
};
use crate::engine::{native_sessions, runtime};

/// How often a followed view's revision is re-read without a live change.
const FOLLOW_POLL: std::time::Duration = std::time::Duration::from_secs(3);
/// How long a live change waits for the rest of its burst.
const FOLLOW_COALESCE: std::time::Duration = std::time::Duration::from_millis(200);

/// A provider-scoped inventory page on this computer.
pub struct NativeSessionListDto {
    /// Opaque root selection identity.
    pub source_id: String,
    /// Local source path, never a remote controller fallback.
    pub location: String,
    /// Newest-first persisted sessions; browsing grants no write permission.
    pub sessions: Vec<LocalSessionDto>,
    /// Opaque next inventory page cursor.
    pub next_cursor: Option<String>,
    /// Sessions of this source can be renamed and deleted here (Grok).
    pub manageable: bool,
}
/// One bounded oldest-first transcript window.
pub struct NativeSessionPageDto {
    /// Opaque local source selection.
    pub source_id: String,
    /// Source generation; changed identity invalidates all retained windows.
    pub generation: String,
    /// Content revision observed by this snapshot.
    pub revision: String,
    /// Public transcript rows, including the native turn IDs.
    pub items: Vec<ThreadItemDto>,
    /// An exclusive older-page boundary, absent at the oldest known edge.
    pub next_before: Option<String>,
    /// Content exceeded reader limits or includes unsupported public records.
    pub truncated: bool,
}
/// Lightweight ownership and revision refresh for the visible local view.
pub struct NativeSessionRevisionDto {
    /// Opaque local source selection.
    pub source_id: String,
    /// Persisted source generation.
    pub generation: String,
    /// Persisted content revision, independent of uncertain process ownership.
    pub revision: String,
    /// Verified ownership if available; no native source grants takeover.
    pub liveness: SessionLivenessDto,
}

/// Read a bounded native inventory, without connecting to or launching an
/// agent.
pub fn app_native_sessions(
    provider: String,
    cursor: Option<String>,
    source_id: Option<String>,
) -> Result<NativeSessionListDto> {
    let source = native_sessions::source(&provider, source_id.as_deref(), cursor.is_none())?;
    let value = runtime::runtime().block_on(source.reader.list_sessions(cursor.as_deref(), 100))?;
    let entries = value["sessions"]
        .as_array()
        .context("invalid native inventory")?;
    let sessions = entries
        .iter()
        .map(|entry| -> Result<_> {
            let id = entry["sessionId"]
                .as_str()
                .context("missing native session id")?;
            Ok(LocalSessionDto {
                thread_id: id.into(),
                cwd: entry["cwd"].as_str().map(str::to_owned),
                preview: entry["title"].as_str().unwrap_or_default().into(),
                name: None,
                status: None,
                source: Some(provider.clone()),
                parent_thread_id: entry["parentSessionId"].as_str().map(str::to_owned),
                thread_source: None,
                updated_at: entry["updatedAt"]
                    .as_str()
                    .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                    .map_or(0, |v| v.timestamp()),
                turn_state: "unknown".into(),
                held_open: false,
                safety: "unknown".into(),
                allows_resume: false,
                requires_takeover: false,
            })
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(NativeSessionListDto {
        source_id: source.id.clone(),
        location: source.location.clone(),
        sessions,
        next_cursor: value["nextCursor"].as_str().map(str::to_owned),
        manageable: provider == "grok",
    })
}
/// Read one bounded native transcript page. Never resumes an external session.
pub fn app_native_session_page(
    provider: String,
    thread_id: String,
    before: Option<String>,
    source_id: Option<String>,
) -> Result<NativeSessionPageDto> {
    let source = native_sessions::source(&provider, source_id.as_deref(), false)?;
    let page =
        runtime::runtime().block_on(source.reader.read_page(&thread_id, before.as_deref(), 20))?;
    let items = page
        .turns
        .iter()
        .flat_map(|turn| {
            turn.items
                .iter()
                .map(|item| item_dto(crate::engine::acp::native_item(item, &turn.id)))
        })
        .collect();
    Ok(NativeSessionPageDto {
        source_id: source.id.clone(),
        generation: page.generation,
        revision: page.revision,
        items,
        next_before: page.next_before,
        truncated: page.truncated,
    })
}
/// Refresh visible local history even if process ownership is unknown.
pub fn app_native_session_revision(
    provider: String,
    thread_id: String,
    source_id: Option<String>,
) -> Result<NativeSessionRevisionDto> {
    let source = native_sessions::source(&provider, source_id.as_deref(), false)?;
    runtime::runtime().block_on(revision(&source, &thread_id))
}

/// Follow a visible local view: its revision and ownership now, then on
/// every live change and at least every three seconds. A Grok session that
/// a Grok terminal client runs through Grok's leader changes live, read-only
/// (it is never loaded, prompted or answered); other sources are polled.
/// Cancelling the Dart stream ends the follow and any live subscription.
pub fn app_native_session_follow(
    provider: String,
    thread_id: String,
    source_id: Option<String>,
    sink: StreamSink<NativeSessionRevisionDto>,
) -> Result<()> {
    let source = native_sessions::source(&provider, source_id.as_deref(), false)?;
    runtime::runtime().spawn(async move {
        let mut live = source.reader.follow(&thread_id);
        loop {
            let delivered = match revision(&source, &thread_id).await {
                Ok(dto) => sink.add(dto).is_ok(),
                Err(error) => sink.add_error(error.to_string()).is_ok(),
            };
            if !delivered {
                return;
            }
            let woke = tokio::select! {
                () = tokio::time::sleep(FOLLOW_POLL) => false,
                changed = NativeFollow::next(&mut live) => changed,
            };
            if woke {
                tokio::time::sleep(FOLLOW_COALESCE).await;
            }
        }
    });
    Ok(())
}

async fn revision(
    source: &native_sessions::Selected,
    thread_id: &str,
) -> Result<NativeSessionRevisionDto> {
    let revision = source.reader.revision(thread_id).await?;
    let liveness = source.reader.liveness(thread_id).await;
    Ok(NativeSessionRevisionDto {
        source_id: source.id.clone(),
        generation: revision["generation"]
            .as_str()
            .context("missing native generation")?
            .into(),
        revision: revision["revision"]
            .as_str()
            .context("missing native revision")?
            .into(),
        liveness: meta_liveness_dto(liveness),
    })
}

/// Rename a session of this computer's Grok home through Grok itself.
/// Refused while a Grok terminal client or a POCOX host holds it.
pub fn app_native_session_rename(
    provider: String,
    thread_id: String,
    title: String,
    source_id: Option<String>,
) -> Result<()> {
    anyhow::ensure!(provider == "grok", "this provider's sessions cannot be renamed here");
    crate::engine::grok_account::manage_session(&thread_id, Some(&title), source_id.as_deref())
}

/// Delete a session of this computer's Grok home permanently, through Grok
/// itself. Refused while a Grok terminal client or a POCOX host holds it.
pub fn app_native_session_delete(
    provider: String,
    thread_id: String,
    source_id: Option<String>,
) -> Result<()> {
    anyhow::ensure!(provider == "grok", "this provider's sessions cannot be deleted here");
    crate::engine::grok_account::manage_session(&thread_id, None, source_id.as_deref())
}
