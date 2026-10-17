//! Local session takeover (shared `CODEX_HOME`) and remote meta-service
//! sessions, per-thread config and host files.
//!
//! The meta functions serve the same session inventory / transcript /
//! force-resume as the `app_local_*` functions, but by the *host's* meta
//! service over its `meta:` tunnel — so a phone can view and resume a desktop
//! host's sessions, and so per-thread config persists on the host and is
//! shared across devices. Each takes the app-server `service_key` being
//! viewed; the matching meta key is derived internally. When the host is this
//! app, the meta service is reached over loopback; otherwise by subscribing to
//! it on the relay.

use super::{threads::ThreadItemDto, *};

/// A process holding a session's rollout open (a would-be takeover
/// target), mirrored for Dart.
pub struct HolderDto {
    /// Operating-system process id.
    pub pid: i64,
    /// Process image name (e.g. `codex.exe`).
    pub name: String,
}

/// A session discovered under `CODEX_HOME`, with the state the UI needs to
/// render it read-only or resumable, mirrored for Dart.
pub struct LocalSessionDto {
    /// Thread / conversation id.
    pub thread_id: String,
    /// Working directory the session controls, when recorded.
    pub cwd: Option<String>,
    /// Best-effort first-user-message preview.
    pub preview: String,
    /// User-set title, when the host's app-server listed one.
    pub name: Option<String>,
    /// The host app-server's `Thread.status` type (`notLoaded` / `idle` /
    /// `active` / `systemError`); `None` when no app-server answered.
    pub status: Option<String>,
    /// Originating client (`cli` / `vscode` / …), when recorded.
    pub source: Option<String>,
    /// Parent thread for a spawned child.
    pub parent_thread_id: Option<String>,
    /// Persisted thread classification.
    pub thread_source: Option<String>,
    /// Last-modified time of the rollout, unix seconds.
    pub updated_at: i64,
    /// Most-recent-turn state (`empty`/`completed`/`aborted`/`incomplete`/
    /// `unknown`).
    pub turn_state: String,
    /// Whether the rollout is currently held open by a live process.
    pub held_open: bool,
    /// Resume-safety tag (`resumable`/`resumableUnfinished`/`ownedRunning`/
    /// `ownedIdle`).
    pub safety: String,
    /// Whether the UI may offer a resume action: false while another process
    /// runs a turn; a thread the host's app-server runs is joined.
    pub allows_resume: bool,
    /// Whether resuming requires a force takeover (a live owner must be
    /// evicted first).
    pub requires_takeover: bool,
}

/// One session's liveness detail, including the would-be takeover targets,
/// mirrored for Dart.
pub struct SessionLivenessDto {
    /// Thread / conversation id.
    pub thread_id: String,
    /// Most-recent-turn state tag.
    pub turn_state: String,
    /// Whether the rollout is currently held open.
    pub held_open: bool,
    /// Resume-safety tag.
    pub safety: String,
    /// Whether the UI may offer a resume action.
    pub allows_resume: bool,
    /// Whether resuming requires a force takeover.
    pub requires_takeover: bool,
    /// Processes a force takeover would attempt to terminate (POCOX's
    /// own app-server already excluded).
    pub holders: Vec<HolderDto>,
}

/// One read-only history revision + ownership update from the host's live
/// session follow stream, mirrored for Dart.
pub struct SessionFollowUpdateDto {
    /// Current ownership and resume-safety state.
    pub liveness: SessionLivenessDto,
    /// Full transcript for legacy hosts; empty in metadata-only mode.
    pub items: Vec<ThreadItemDto>,
    /// Opaque revision for a metadata-only stream; read items via app-server.
    pub history_revision: Option<String>,
}

/// Outcome of a force-resume, mirrored for Dart.
pub struct ForceResumeReportDto {
    /// Holders that were successfully terminated.
    pub killed: Vec<HolderDto>,
    /// Holders the kill could not reach.
    pub survived: Vec<HolderDto>,
    /// Whether the rollout is still held open after the attempt. A true
    /// value blocks the subsequent resume.
    pub still_held: bool,
    /// Whether the subsequent `thread/resume` succeeded.
    pub resumed: bool,
    /// The resume error message, when `resumed` is false.
    pub resume_error: Option<String>,
}

fn holder_dto(h: pocket_codex_codex::liveness::Holder) -> HolderDto {
    HolderDto {
        pid: i64::from(h.pid),
        name: h.name,
    }
}

fn local_session_dto(s: sessions::LocalSession) -> LocalSessionDto {
    LocalSessionDto {
        thread_id: s.thread_id,
        cwd: s.cwd,
        preview: s.preview,
        name: s.name,
        status: s.status,
        source: s.source,
        parent_thread_id: s.parent_thread_id,
        thread_source: s.thread_source,
        updated_at: s.updated_at,
        turn_state: s.turn_state,
        held_open: s.held_open,
        safety: s.safety,
        allows_resume: s.allows_resume,
        requires_takeover: s.requires_takeover,
    }
}

/// List every codex session under the shared `CODEX_HOME`, newest first,
/// each annotated with whether it is safe to resume.
///
/// Works without any app-server connection — it reads the local rollout
/// files and process table directly, so it surfaces sessions created by
/// *other* codex clients (the desktop app, the CLI, the VS Code
/// extension) that share this `CODEX_HOME`. Meaningful only when the UI
/// runs on the same machine as those sessions.
pub fn app_local_sessions() -> Result<Vec<LocalSessionDto>> {
    Ok(sessions::list_local_sessions()?
        .into_iter()
        .map(local_session_dto)
        .collect())
}

/// Inspect one session's current resume-safety and the processes a force
/// takeover would evict. Poll this before showing a resume button so the
/// UI reflects live ownership (a session can flip between read-only and
/// resumable as the desktop app loads / releases it).
pub fn app_session_liveness(thread_id: String) -> Result<SessionLivenessDto> {
    let view = sessions::session_liveness(&thread_id)?;
    Ok(SessionLivenessDto {
        thread_id: view.thread_id,
        turn_state: view.turn_state,
        held_open: view.held_open,
        safety: view.safety,
        allows_resume: view.allows_resume,
        requires_takeover: view.requires_takeover,
        holders: view.holders.into_iter().map(holder_dto).collect(),
    })
}

/// Read a local session's transcript for READ-ONLY viewing. Parses the
/// on-disk rollout directly (no app-server connection, no resume, no write),
/// so it works even while another codex client still owns the session.
/// Items are in the same shape as [`app_thread_read`], so the read-only
/// viewer reuses the live-conversation rendering. Poll it alongside
/// [`app_session_liveness`] to follow a running session and notice when it
/// goes idle (resume-eligible).
pub fn app_local_session_transcript(thread_id: String) -> Result<Vec<ThreadItemDto>> {
    Ok(sessions::local_session_transcript(&thread_id)?
        .into_iter()
        .map(|i| ThreadItemDto {
            id: i.id,
            item_type: i.item_type,
            title: i.title,
            text: i.text,
            images: i.images,
            // A rollout file on disk has no turn envelope, so these read as
            // "unknown" rather than being reconstructed from the item order.
            turn_id: String::new(),
            turn_completed_at: None,
            turn_duration_ms: None,
            questions_json: None,
        })
        .collect())
}

/// Force-resume a session into the app-server behind `service_key`.
///
/// Terminates live processes holding the session's rollout open (never
/// POCOX's own app-server), then issues `thread/resume` only after
/// successful release. The UI must gate this on explicit
/// user confirmation and must not offer it while a turn is actively
/// running (`SessionLivenessDto::allows_resume == false`). The returned
/// report says exactly which processes were killed / survived and whether
/// the resume took.
pub fn app_force_resume(service_key: String, thread_id: String) -> Result<ForceResumeReportDto> {
    require_native(&service_key, "forced resume")?;
    let outcome = sessions::force_resume(&service_key, &thread_id)?;
    Ok(ForceResumeReportDto {
        killed: outcome.killed.into_iter().map(holder_dto).collect(),
        survived: outcome.survived.into_iter().map(holder_dto).collect(),
        still_held: outcome.still_held,
        resumed: outcome.resumed,
        resume_error: outcome.resume_error,
    })
}


fn meta_holder_dto(h: pocket_codex_host_svc::sessions::Holder) -> HolderDto {
    HolderDto {
        pid: i64::from(h.pid),
        name: h.name,
    }
}

pub(super) fn meta_liveness_dto(
    value: pocket_codex_host_svc::sessions::SessionLiveness,
) -> SessionLivenessDto {
    SessionLivenessDto {
        thread_id: value.thread_id,
        turn_state: value.turn_state,
        held_open: value.held_open,
        safety: value.safety,
        allows_resume: value.allows_resume,
        requires_takeover: value.requires_takeover,
        holders: value.holders.into_iter().map(meta_holder_dto).collect(),
    }
}

fn meta_thread_item_dto(value: pocket_codex_host_svc::sessions::TranscriptItem) -> ThreadItemDto {
    ThreadItemDto {
        id: value.id,
        item_type: value.item_type,
        title: value.title,
        text: value.text,
        images: value.images,
        // A rollout file on disk has no turn envelope, so these read as
        // "unknown" rather than being reconstructed from the item order.
        turn_id: String::new(),
        turn_completed_at: None,
        turn_duration_ms: None,
        questions_json: None,
    }
}

fn meta_follow_update_dto(
    value: pocket_codex_host_svc::sessions::SessionFollowUpdate,
) -> SessionFollowUpdateDto {
    SessionFollowUpdateDto {
        liveness: meta_liveness_dto(value.liveness),
        items: value.items.into_iter().map(meta_thread_item_dto).collect(),
        history_revision: value.history_revision,
    }
}

/// Per-thread session config persisted on the host (mirrored for Dart). Every
/// field is optional: `None`/null means "no stored preference", so the UI falls
/// back to its own default.
pub struct ThreadConfigDto {
    /// Selected model id, when pinned for this thread.
    pub model: Option<String>,
    /// Reasoning-effort tag (`minimal`/`low`/`medium`/`high`), when set.
    pub reasoning_effort: Option<String>,
    /// Permission / approval mode tag, when set.
    pub permission_mode: Option<String>,
    /// Requested service tier (`priority` for Fast, `default` for standard).
    pub service_tier: Option<String>,
    /// Whether plan mode is on for this thread, when set.
    pub plan_mode: Option<bool>,
}

fn thread_config_dto(c: pocket_codex_host_svc::store::ThreadConfig) -> ThreadConfigDto {
    ThreadConfigDto {
        model: c.model,
        reasoning_effort: c.reasoning_effort,
        permission_mode: c.permission_mode,
        service_tier: c.service_tier,
        plan_mode: c.plan_mode,
    }
}

fn thread_config_from_dto(c: ThreadConfigDto) -> pocket_codex_host_svc::store::ThreadConfig {
    pocket_codex_host_svc::store::ThreadConfig {
        model: c.model,
        reasoning_effort: c.reasoning_effort,
        permission_mode: c.permission_mode,
        service_tier: c.service_tier,
        plan_mode: c.plan_mode,
    }
}

/// Remote analogue of [`app_local_sessions`]: list the sessions of the host
/// behind `service_key` via its meta tunnel (loopback when this app is the
/// host, a relay subscription when remote). Lets a phone see a desktop host's
/// sessions — including those owned by another codex client.
pub fn meta_sessions(
    service_key: String,
    running_only: Option<bool>,
) -> Result<Vec<LocalSessionDto>> {
    Ok(meta::sessions(&service_key, running_only.unwrap_or(false))?
        .into_iter()
        .map(local_session_dto)
        .collect())
}

/// Remote analogue of [`app_session_liveness`].
pub fn meta_session_liveness(service_key: String, thread_id: String) -> Result<SessionLivenessDto> {
    let v = meta::session_liveness(&service_key, &thread_id)?;
    Ok(meta_liveness_dto(v))
}

/// Subscribe to live read-only transcript + ownership snapshots for a session
/// held by another app-server. One long-lived meta response replaces client
/// polling; dropping the Dart stream stops forwarding.
pub fn meta_session_events(
    service_key: String,
    thread_id: String,
    sink: StreamSink<SessionFollowUpdateDto>,
) -> Result<()> {
    runtime::runtime().spawn(async move {
        let result = meta::follow_session(&service_key, &thread_id, |update| {
            sink.add(meta_follow_update_dto(update)).is_ok()
        })
        .await;
        if let Err(error) = result {
            let _ = sink.add_error(error.to_string());
        }
    });
    Ok(())
}

/// Remote analogue of [`app_local_session_transcript`].
pub fn meta_session_transcript(
    service_key: String,
    thread_id: String,
) -> Result<Vec<ThreadItemDto>> {
    Ok(meta::transcript(&service_key, &thread_id)?
        .into_iter()
        .map(meta_thread_item_dto)
        .collect())
}

/// Remote analogue of [`app_force_resume`]: the host evicts the rollout's live
/// holders and resumes it into its colocated app-server over loopback. The UI
/// must gate this on explicit confirmation and not offer it while a turn runs.
pub fn meta_force_resume(service_key: String, thread_id: String) -> Result<ForceResumeReportDto> {
    let o = meta::force_resume(&service_key, &thread_id)?;
    Ok(ForceResumeReportDto {
        killed: o.killed.into_iter().map(meta_holder_dto).collect(),
        survived: o.survived.into_iter().map(meta_holder_dto).collect(),
        still_held: o.still_held,
        resumed: o.resumed,
        resume_error: o.resume_error,
    })
}

/// Upload a document/file attachment to the host behind `service_key` (over
/// its meta tunnel — loopback when this app is the host), returning the
/// absolute HOST filesystem path where it was stored. The turn text then
/// references that path so the agent reads the file with its own tools —
/// codex's native host-file workflow (its input protocol carries only text
/// and images inline; there is no document slot).
pub fn meta_upload_file(service_key: String, file_name: String, bytes: Vec<u8>) -> Result<String> {
    Ok(meta::upload_file(&service_key, &file_name, bytes)?.path)
}

/// Capture attachment destination ownership before asynchronous file reads.
#[frb(sync)]
pub fn meta_upload_context() -> Result<String> {
    meta::upload_context()
}

/// Upload using the context captured before reading the file; reject a changed
/// account or relay without transmitting attachment bytes.
pub fn meta_upload_file_scoped(
    service_key: String,
    file_name: String,
    bytes: Vec<u8>,
    context: String,
) -> Result<String> {
    Ok(meta::upload_file_scoped(&service_key, &file_name, bytes, &context)?.path)
}

/// Read a thread's persisted config from the host behind `service_key`.
pub fn meta_thread_config_get(service_key: String, thread_id: String) -> Result<ThreadConfigDto> {
    Ok(thread_config_dto(meta::config_get(&service_key, &thread_id)?))
}

/// Persist a thread's config on the host behind `service_key`; returns the
/// stored value.
pub fn meta_thread_config_set(
    service_key: String,
    thread_id: String,
    config: ThreadConfigDto,
) -> Result<ThreadConfigDto> {
    Ok(thread_config_dto(meta::config_put(
        &service_key,
        &thread_id,
        thread_config_from_dto(config),
    )?))
}

/// The host's project-folder config (mirrored for Dart): the roots a remote
/// folder browser is confined to, and the default project new sessions open in.
pub struct ProjectConfigDto {
    /// Absolute host paths configured as project roots.
    pub project_roots: Vec<String>,
    /// Absolute host path new conversations default to (`None` = codex
    /// default).
    pub default_project: Option<String>,
}

fn project_config_dto(c: pocket_codex_host_svc::store::HostConfig) -> ProjectConfigDto {
    ProjectConfigDto {
        project_roots: c.project_roots,
        default_project: c.default_project,
    }
}

/// One browsable child directory of a host folder (mirrored for Dart).
pub struct DirEntryDto {
    /// The directory's own name (final path component).
    pub name: String,
    /// Absolute host path, ready to browse into or use as a session's cwd.
    pub path: String,
    /// Whether the directory is a git repository (a project hint).
    pub is_git_repo: bool,
}

/// One file in a host directory (mirrored for Dart), with size + mtime for the
/// file-transfer panel.
pub struct FileEntryDto {
    /// The file's own name (final path component).
    pub name: String,
    /// Absolute host path.
    pub path: String,
    /// Size in bytes.
    pub size: u64,
    /// Last-modified time in unix seconds (0 when unavailable).
    pub mtime: i64,
}

/// Read the project-folder config of the host behind `service_key`.
pub fn meta_project_config(service_key: String) -> Result<ProjectConfigDto> {
    Ok(project_config_dto(meta::project_config(&service_key)?))
}

/// Replace the project-folder config of the host behind `service_key`; returns
/// the stored value. The desktop host edits this over its own loopback tunnel.
pub fn meta_set_project_config(
    service_key: String,
    project_roots: Vec<String>,
    default_project: Option<String>,
) -> Result<ProjectConfigDto> {
    Ok(project_config_dto(meta::set_project_config(
        &service_key,
        pocket_codex_host_svc::store::HostConfig {
            project_roots,
            default_project,
        },
    )?))
}

/// Project settings with an optional new-host revision and effective default.
/// Older hosts retain their existing configured-default behaviour.
pub struct ProjectSettingsDto {
    /// Explicit browsing roots on the host.
    pub project_roots: Vec<String>,
    /// User override; absent selects the host OS automatic folder on new hosts.
    pub default_project: Option<String>,
    /// Compare-and-save token. Absent identifies a legacy host.
    pub revision: Option<String>,
    /// Actual host default, absent only on legacy hosts without one configured.
    pub effective_default: Option<String>,
    /// The host derives this folder from its OS rather than a saved override.
    pub automatic: bool,
    /// Effective folder exists now; checking it did not create it.
    pub exists: bool,
}

#[derive(serde::Deserialize)]
struct ProjectViewResponse {
    #[serde(flatten)]
    config: pocket_codex_host_svc::store::HostConfig,
    #[serde(default)]
    revision: Option<String>,
    #[serde(default)]
    effective_default: Option<pocket_codex_host_svc::projects::DefaultProject>,
}

impl From<ProjectViewResponse> for ProjectSettingsDto {
    fn from(value: ProjectViewResponse) -> Self {
        let (effective_default, automatic, exists) = match value.effective_default {
            Some(folder) => (Some(folder.path), folder.automatic, folder.exists),
            None => (value.config.default_project.clone(), false, false),
        };
        Self {
            project_roots: value.config.project_roots,
            default_project: value.config.default_project,
            revision: value.revision,
            effective_default,
            automatic,
            exists,
        }
    }
}

/// Read current host defaults and conflict metadata without creating a folder.
pub fn meta_project_settings(service_key: String) -> Result<ProjectSettingsDto> {
    let view: ProjectViewResponse = crate::engine::management_client::request(
        &service_key,
        reqwest::Method::GET,
        &["projects"],
        None::<&()>,
    )?;
    Ok(view.into())
}

/// Save reviewed project settings. New hosts require their last read revision.
pub fn meta_save_project_settings(
    service_key: String,
    project_roots: Vec<String>,
    default_project: Option<String>,
    expected_revision: Option<String>,
) -> Result<ProjectSettingsDto> {
    let body = pocket_codex_host_svc::projects::ProjectsUpdate {
        config: pocket_codex_host_svc::store::HostConfig {
            project_roots,
            default_project,
        },
        expected_revision,
    };
    let view: ProjectViewResponse = crate::engine::management_client::request(
        &service_key,
        reqwest::Method::PUT,
        &["projects"],
        Some(&body),
    )?;
    Ok(view.into())
}

/// Resolve the host's default at first send. Never substitute the controller's
/// filesystem or overwrite an explicitly selected project. On a legacy host,
/// returns its configured default or None so the existing picker can be used.
pub fn meta_ensure_default_project(service_key: String) -> Result<Option<String>> {
    if !meta::default_projects_available(&service_key)? {
        return Ok(None);
    }
    let view = match meta_project_settings(service_key.clone()) {
        Ok(view) => view,
        Err(error)
            if error
                .downcast_ref::<crate::engine::management_client::RemoteError>()
                .is_some_and(|error| error.status == 404) =>
        {
            return Ok(None)
        },
        Err(error) => return Err(error),
    };
    if view.revision.is_none() {
        return Ok(view.default_project);
    }
    let ready: pocket_codex_host_svc::projects::EnsuredProject =
        crate::engine::management_client::request(
            &service_key,
            reqwest::Method::POST,
            &["projects", "default", "ensure"],
            None::<&()>,
        )?;
    Ok(Some(ready.path))
}

/// List the sub-directories of `path` on the host behind `service_key`, for the
/// remote project-folder browser. Errors (with a `403`-carrying message) if
/// `path` is outside the host's configured project roots.
pub fn meta_list_dir(service_key: String, path: String) -> Result<Vec<DirEntryDto>> {
    Ok(meta::list_dir(&service_key, &path)?
        .into_iter()
        .map(|e| DirEntryDto {
            name: e.name,
            path: e.path,
            is_git_repo: e.is_git_repo,
        })
        .collect())
}

/// List the files (not sub-directories) in `path` on the host behind
/// `service_key`, for the file-transfer panel. Errors (with a `403`-carrying
/// message) if `path` is outside the host's configured project roots.
pub fn meta_list_files(service_key: String, path: String) -> Result<Vec<FileEntryDto>> {
    Ok(meta::list_files(&service_key, &path)?
        .into_iter()
        .map(|e| FileEntryDto {
            name: e.name,
            path: e.path,
            size: e.size,
            mtime: e.mtime,
        })
        .collect())
}

/// Download a host file's raw bytes (root-confined) from the host behind
/// `service_key`, for saving to the controller's local disk. Errors (with a
/// `403`-carrying message) if `path` is outside the configured project roots.
pub fn meta_read_file(service_key: String, path: String) -> Result<Vec<u8>> {
    meta::read_file(&service_key, &path)
}

/// Bounded file preview returned after an explicit user action.
pub struct FilePreviewDto {
    /// Preview bytes, capped at 8 MiB.
    pub bytes: Vec<u8>,
    /// Total file size, including bytes omitted from the preview.
    pub total_size: u64,
}

/// Determine whether the selected host shares this app's filesystem.
pub fn meta_host_is_local(service_key: String) -> Result<bool> {
    meta::host_is_local(&service_key)
}

/// Read a bounded preview of a selected session file link.
pub fn meta_file_preview(
    service_key: String,
    thread_id: Option<String>,
    href: String,
) -> Result<FilePreviewDto> {
    let preview = meta::file_preview(&service_key, thread_id.as_deref(), &href)?;
    Ok(FilePreviewDto {
        bytes: preview.bytes,
        total_size: preview.total_size,
    })
}

/// Stream a selected file into a new controller-side staging file.
pub fn meta_file_download(
    service_key: String,
    thread_id: Option<String>,
    href: String,
    destination: String,
) -> Result<()> {
    meta::file_download(&service_key, thread_id.as_deref(), &href, &destination)
}

/// Read an image that `thread_id`'s transcript already references, so the UI
/// can render it inline instead of naming it. NOT root-confined: the host
/// authorises user attachments and typed generated artifacts, which is what
/// makes a pasted screenshot in the OS temp directory visible to a remote
/// controller without granting it a general file read. Errors (with a
/// `403`-carrying message) for a path the transcript never mentioned.
pub fn meta_read_thread_image(
    service_key: String,
    thread_id: String,
    path: String,
) -> Result<Vec<u8>> {
    meta::read_thread_image(&service_key, &thread_id, &path)
}

/// Upload local `bytes` as `file_name` into host directory `dir`
/// (root-confined) on the host behind `service_key`; returns the absolute HOST
/// path where it landed. Never overwrites an existing same-named file (a
/// collision surfaces the host's `409` in the returned message).
pub fn meta_write_file(
    service_key: String,
    dir: String,
    file_name: String,
    bytes: Vec<u8>,
) -> Result<String> {
    Ok(meta::write_file(&service_key, &dir, &file_name, bytes)?.path)
}
