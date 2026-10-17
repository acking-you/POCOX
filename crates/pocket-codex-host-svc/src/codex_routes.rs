//! Routes over the host's Codex rollouts and app-server: session inventory,
//! liveness, transcripts, follow, force-resume, and image previews authorised
//! by the thread's own transcript.

use super::*;

/// `{ "sessions": [...] }` — the local session inventory.
#[derive(Serialize)]
pub(super) struct SessionsResponse {
    pub(super) sessions: Vec<sessions::LocalSession>,
}

#[derive(Default, Deserialize)]
pub(super) struct SessionListQuery {
    #[serde(default)]
    pub(super) running_only: bool,
}

pub(super) async fn list_sessions(
    Query(query): Query<SessionListQuery>,
) -> Result<Json<SessionsResponse>, ApiError> {
    let sessions = tokio::task::spawn_blocking(move || {
        if query.running_only {
            sessions::running()
        } else {
            sessions::list()
        }
    })
    .await
    .context("session-scan task panicked")??;
    Ok(Json(SessionsResponse {
        sessions,
    }))
}

pub(super) async fn session_liveness(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<sessions::SessionLiveness>, ApiError> {
    let addr = state.app_ws_addr;
    // protected_pids + the liveness inspect both hit the process table.
    let view = tokio::task::spawn_blocking(move || {
        let protected = resume::protected_pids(addr);
        sessions::liveness(&id, &protected)
    })
    .await
    .context("liveness task panicked")??;
    Ok(Json(view))
}

/// `{ "items": [...] }` — a read-only transcript.
#[derive(Serialize)]
pub(super) struct TranscriptResponse {
    pub(super) items: Vec<sessions::TranscriptItem>,
}

pub(super) async fn session_transcript(
    Path(id): Path<String>,
) -> Result<Json<TranscriptResponse>, ApiError> {
    let items = tokio::task::spawn_blocking(move || sessions::transcript(&id))
        .await
        .context("transcript task panicked")??;
    Ok(Json(TranscriptResponse {
        items,
    }))
}

/// Follow a rollout over one long-lived response. The filesystem is sampled
/// close to its append cadence on the host. Changed snapshots and small
/// metadata heartbeats cross the relay; liveness is checked separately so a
/// completed writer is noticed even when releasing the file does not append
/// another record.
#[derive(Default, Deserialize)]
pub(super) struct FollowQuery {
    #[serde(default)]
    pub(super) metadata_only: bool,
}

pub(super) async fn session_follow(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Query(query): Query<FollowQuery>,
) -> Result<impl IntoResponse, ApiError> {
    let protected = resume::protected_pids(state.app_ws_addr);
    let initial_id = id.clone();
    let initial_protected = protected.clone();
    let metadata_only = query.metadata_only;
    let mut initial = tokio::task::spawn_blocking(move || {
        if metadata_only {
            Ok(sessions::SessionFollowUpdate {
                liveness: sessions::liveness(&initial_id, &initial_protected)?,
                items: Vec::new(),
                history_revision: None,
            })
        } else {
            sessions::follow_update(&initial_id, &initial_protected)
        }
    })
    .await
    .context("session-follow seed task panicked")??;
    let rollout_path = sessions::rollout_path(&id)?;
    let initial_metadata = tokio::fs::metadata(&rollout_path).await?;
    let mut revision = (initial_metadata.len(), initial_metadata.modified().ok());
    if metadata_only {
        initial.history_revision = Some(format!("{revision:?}"));
    }

    let (tx, rx) = mpsc::channel(4);
    tokio::spawn(async move {
        let mut previous = initial;
        let mut last_sent = match serde_json::to_string(&previous) {
            Ok(encoded) => encoded,
            Err(error) => {
                tracing::warn!(%error, "encoding session follow update failed");
                return;
            },
        };
        if send_follow_data(&tx, last_sent.clone()).await.is_err() {
            return;
        }

        let mut interval = tokio::time::interval(Duration::from_millis(300));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        // The first interval tick is immediate; the seed above already covers
        // it, so consume that tick before entering the change loop.
        interval.tick().await;
        let mut tick = 0_u8;
        loop {
            tokio::select! {
                _ = tx.closed() => break,
                _ = interval.tick() => {},
            }
            tick = tick.wrapping_add(1);
            let metadata = match tokio::fs::metadata(&rollout_path).await {
                Ok(metadata) => metadata,
                Err(error) => {
                    tracing::debug!(%error, thread_id = %id, "session follow rollout disappeared");
                    break;
                },
            };
            let next_revision = (metadata.len(), metadata.modified().ok());
            let transcript_changed = next_revision != revision;
            let check_liveness = tick.is_multiple_of(3);
            if !transcript_changed && !check_liveness {
                continue;
            }
            let next_id = id.clone();
            let next_protected = protected.clone();
            let next = match tokio::task::spawn_blocking(move || -> anyhow::Result<_> {
                let items = (transcript_changed && !metadata_only)
                    .then(|| sessions::transcript(&next_id))
                    .transpose()?;
                let liveness = check_liveness
                    .then(|| sessions::liveness(&next_id, &next_protected))
                    .transpose()?;
                Ok((items, liveness))
            })
            .await
            {
                Ok(Ok(update)) => update,
                Ok(Err(error)) => {
                    tracing::debug!(%error, thread_id = %id, "session follow stopped");
                    break;
                },
                Err(error) => {
                    tracing::warn!(%error, thread_id = %id, "session follow task panicked");
                    break;
                },
            };
            revision = next_revision;
            if metadata_only {
                previous.history_revision = Some(format!("{revision:?}"));
            }
            if let Some(items) = next.0 {
                previous.items = items;
            }
            if let Some(liveness) = next.1 {
                previous.liveness = liveness;
            }
            let encoded = match serde_json::to_string(&previous) {
                Ok(encoded) => encoded,
                Err(error) => {
                    tracing::warn!(%error, "encoding session follow update failed");
                    break;
                },
            };
            // FRB discovers a cancelled Dart sink on the next data event.
            // A tiny metadata heartbeat also retires quiet subscriptions.
            if encoded == last_sent && (!metadata_only || !tick.is_multiple_of(30)) {
                continue;
            }
            last_sent.clone_from(&encoded);
            if send_follow_data(&tx, encoded).await.is_err() {
                break;
            }
        }
    });

    Ok(Sse::new(ReceiverStream::new(rx)).keep_alive(
        KeepAlive::new()
            .interval(Duration::from_secs(10))
            .text("session-follow"),
    ))
}

async fn send_follow_data(
    tx: &mpsc::Sender<Result<Event, Infallible>>,
    data: String,
) -> Result<(), ()> {
    tx.send(Ok(Event::default().event("snapshot").data(data)))
        .await
        .map_err(|_| ())
}

pub(super) async fn session_resume(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<resume::ForceResumeOutcome>, ApiError> {
    let outcome = resume::force_resume(state.app_ws_addr, &id).await?;
    Ok(Json(outcome))
}

/// Query for `GET /fs/thread-image`.
#[derive(Deserialize)]
pub(super) struct ThreadImageQuery {
    /// Thread whose transcript authorises the read.
    pub(super) thread: String,
    /// Absolute host path of the image, exactly as the transcript carries it.
    pub(super) path: String,
}

/// Image suffixes this endpoint will serve. Anything else is a document, and a
/// document is not what a remote controller needs to *look* at.
const IMAGE_SUFFIXES: [&str; 6] = ["png", "jpg", "jpeg", "gif", "webp", "bmp"];

/// Largest image this endpoint will inline. Matches the controller's own
/// ceiling, so the tunnel never carries bytes the UI would throw away.
const MAX_INLINE_IMAGE_BYTES: u64 = 8 * 1024 * 1024;

/// `GET /fs/thread-image?thread=<id>&path=<file>` — an image's bytes, for a
/// remote controller to render inline.
///
/// Deliberately NOT root-confined, because the images worth showing are
/// exactly the ones that are not project files: a pasted screenshot lands in
/// the OS temp directory. The authorisation is narrower instead — the path
/// must appear in a user message or a typed generated-image artifact of the
/// thread. A remote controller therefore sees only what this conversation
/// itself put in front of the model, and never gains a general file read:
///
///  * only user references and native generated artifacts count; a path
///    *written* in a reply is not readable — otherwise a prompt-injected reply
///    could name `~/.ssh/id_rsa` and have the controller fetch it;
///  * only image suffixes are served;
///  * `403` for anything unreferenced, `400` for a non-file.
///
/// An attachment whose file is gone (the system clears its temp directory)
/// is served from the copy the model request carried, which the rollout keeps.
pub(super) async fn read_thread_image(
    Query(q): Query<ThreadImageQuery>,
) -> Result<Vec<u8>, ApiError> {
    let suffix = std::path::Path::new(&q.path)
        .extension()
        .and_then(|e| e.to_str())
        .map(str::to_ascii_lowercase);
    if !suffix.is_some_and(|s| IMAGE_SUFFIXES.contains(&s.as_str())) {
        return Err(ApiError(anyhow!("path is not an image")));
    }
    let thread = q.thread.clone();
    let items = tokio::task::spawn_blocking(move || sessions::transcript(&thread))
        .await
        .context("transcript task panicked")??;
    if !items.iter().any(|i| references_path(i, &q.path)) {
        return Err(ApiError(anyhow!("path is outside the configured project roots")));
    }
    let requested = std::path::PathBuf::from(&q.path);
    if !requested.exists() {
        return inline_attachment(q.thread, q.path).await;
    }
    if !requested.is_file() {
        return Err(ApiError(anyhow!("path is not a file")));
    }
    // Cap before reading: the controller discards anything it can't draw
    // anyway, so a mis-named huge file would otherwise be pulled into host
    // memory and pushed through the tunnel for nothing.
    let size = tokio::fs::metadata(&requested)
        .await
        .with_context(|| format!("stat {}", requested.display()))?
        .len();
    if size > MAX_INLINE_IMAGE_BYTES {
        return Err(ApiError(anyhow!("path is not a file we will inline")));
    }
    let bytes = tokio::fs::read(&requested)
        .await
        .with_context(|| format!("reading {}", requested.display()))?;
    Ok(bytes)
}

/// The rollout's inline copy of the attachment `path` of `thread`, decoded;
/// "not a file" when it recorded none or it is too large to inline.
async fn inline_attachment(thread: String, path: String) -> Result<Vec<u8>, ApiError> {
    use base64::Engine as _;
    let url = tokio::task::spawn_blocking(move || -> anyhow::Result<Option<String>> {
        let rollout = sessions::rollout_path(&thread)?;
        Ok(pocket_codex_codex::rollout::inline_user_image(&rollout, &path)?)
    })
    .await
    .context("rollout image task panicked")??;
    let bytes = url
        .as_deref()
        .and_then(|url| url.split_once(";base64,"))
        .and_then(|(_, data)| base64::engine::general_purpose::STANDARD.decode(data).ok())
        .filter(|bytes| !bytes.is_empty() && bytes.len() as u64 <= MAX_INLINE_IMAGE_BYTES);
    bytes.ok_or_else(|| ApiError(anyhow!("path is not a file")))
}

/// Whether `item` explicitly generated `path` or a user named it — as an
/// attachment or in its text (where a client's IDE-context block lists
/// mentioned files). Separators are normalised because a client may write
/// either style on Windows; nothing else is loosened, since the match IS the
/// authorisation.
fn references_path(item: &sessions::TranscriptItem, path: &str) -> bool {
    let want = path.replace('\\', "/");
    if item.item_type == "imageGeneration" {
        // Only typed generated artifact references authorize a read, never
        // prompt/revised-prompt text or arbitrary tool output.
        return item.images.iter().any(|i| i.replace('\\', "/") == want);
    }
    if item.item_type != "userMessage" {
        return false;
    }
    item.images.iter().any(|i| i.replace('\\', "/") == want)
        || mentions_whole_path(&item.text.replace('\\', "/"), &want)
}

/// Whether `text` names exactly `want` — not merely a path it is a prefix of.
/// A bare `contains` would authorise reading `/tmp/a.png` because the message
/// mentioned `/tmp/a.png.bak`, and this match IS the authorisation.
fn mentions_whole_path(text: &str, want: &str) -> bool {
    text.match_indices(want).any(|(at, _)| {
        text[at + want.len()..]
            .chars()
            .next()
            .is_none_or(|c| !(c.is_alphanumeric() || matches!(c, '.' | '-' | '_' | '/')))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(item_type: &str, text: &str, images: &[&str]) -> sessions::TranscriptItem {
        sessions::TranscriptItem {
            id: "1".into(),
            item_type: item_type.into(),
            title: String::new(),
            text: text.into(),
            images: images.iter().map(|s| (*s).to_string()).collect(),
        }
    }

    #[test]
    fn thread_image_authorises_only_paths_the_user_sent() {
        // Attached to a user message, or named in its text (a client's
        // IDE-context block) — both are things the user put in front of the
        // model, so both are readable.
        assert!(references_path(&item("userMessage", "", &["/tmp/shot.png"]), "/tmp/shot.png"));
        assert!(references_path(
            &item("userMessage", "## shot.png: /tmp/shot.png", &[]),
            "/tmp/shot.png"
        ));
        // Windows clients write either separator for the same file.
        assert!(references_path(
            &item("userMessage", "", &[r"C:\Temp\shot.png"]),
            "C:/Temp/shot.png"
        ));
    }

    #[test]
    fn thread_image_authorizes_only_the_generated_artifact() {
        let generated =
            item("imageGeneration", "Create /private/secret.png", &["/tmp/generated.png"]);
        assert!(references_path(&generated, "/tmp/generated.png"));
        assert!(!references_path(&generated, "/private/secret.png"));
        assert!(!references_path(&generated, "/tmp/generated.png.bak"));
        assert!(!references_path(
            &item("dynamicToolCall", "", &["/private/secret.png"]),
            "/private/secret.png"
        ));
    }

    #[test]
    fn thread_image_refuses_paths_the_user_did_not_send() {
        // The critical case: a path the MODEL wrote is not authorisation. A
        // prompt-injected reply naming a private file must not become a read.
        assert!(!references_path(
            &item("agentMessage", "see /home/u/.ssh/id_rsa.png", &[]),
            "/home/u/.ssh/id_rsa.png"
        ));
        assert!(!references_path(
            &item("reasoning", "", &["/home/u/.ssh/id_rsa.png"]),
            "/home/u/.ssh/id_rsa.png"
        ));
        // An unrelated user message authorises nothing.
        assert!(!references_path(&item("userMessage", "look at /tmp/a.png", &[]), "/tmp/b.png"));
        // Nor does one whose path merely STARTS with the requested one — a bare
        // substring match would hand over /tmp/a.png on the strength of a
        // message about /tmp/a.png.bak.
        assert!(!references_path(&item("userMessage", "see /tmp/a.png.bak", &[]), "/tmp/a.png"));
        // The real mention still matches at end-of-text and before punctuation.
        assert!(references_path(&item("userMessage", "see /tmp/a.png", &[]), "/tmp/a.png"));
        assert!(references_path(
            &item("userMessage", "## a.png: /tmp/a.png\n\nwhy?", &[]),
            "/tmp/a.png"
        ));
    }
}
