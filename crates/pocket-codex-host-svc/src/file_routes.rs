//! Root-confined host file routes: folder browsing, file listing, download,
//! writing into a project folder, and attachment uploads.

use super::*;

/// Query for `GET /fs/list`.
#[derive(Deserialize)]
pub(super) struct ListDirQuery {
    /// Absolute host path to list. Must be a configured root or inside one.
    pub(super) path: String,
}

/// `{ "path": ..., "entries": [...] }` — one directory's browsable children.
#[derive(Serialize)]
pub(super) struct ListDirResponse {
    pub(super) path: String,
    pub(super) entries: Vec<fs::DirEntry>,
}

/// `GET /fs/list?path=<abs>` — the sub-directories of `path`, for the remote
/// project-folder browser. Confined to the configured roots: a path that is
/// not a root or inside one is refused (`403`) so the browser can never
/// free-roam the host filesystem.
pub(super) async fn list_dir(
    State(state): State<Arc<AppState>>,
    Query(q): Query<ListDirQuery>,
) -> Result<Json<ListDirResponse>, ApiError> {
    let roots = state.host.effective_roots().await?;
    let requested = std::path::PathBuf::from(&q.path);
    if !fs::within_roots(&requested, &roots) {
        return Err(ApiError(anyhow!("path is outside the configured project roots")));
    }
    let entries = tokio::task::spawn_blocking(move || fs::list_subdirs(&requested))
        .await
        .context("directory-listing task panicked")??;
    Ok(Json(ListDirResponse {
        path: q.path,
        entries,
    }))
}

/// `{ "path": ..., "files": [...] }` — one directory's files (not sub-dirs).
#[derive(Serialize)]
pub(super) struct ListFilesResponse {
    pub(super) path: String,
    pub(super) files: Vec<fs::FileEntry>,
}

/// `GET /fs/files?path=<abs>` — the files in `path` (root-confined), for the
/// file-transfer panel. `403` for a path outside the configured roots.
pub(super) async fn list_files_in(
    State(state): State<Arc<AppState>>,
    Query(q): Query<ListDirQuery>,
) -> Result<Json<ListFilesResponse>, ApiError> {
    let roots = state.host.effective_roots().await?;
    let requested = std::path::PathBuf::from(&q.path);
    if !fs::within_roots(&requested, &roots) {
        return Err(ApiError(anyhow!("path is outside the configured project roots")));
    }
    let files = tokio::task::spawn_blocking(move || fs::list_files(&requested))
        .await
        .context("file-listing task panicked")??;
    Ok(Json(ListFilesResponse {
        path: q.path,
        files,
    }))
}

/// `GET /fs/read?path=<file>` — a file's raw bytes (root-confined), to download
/// a host file to the controller. `403` outside roots, `400` if not a file.
/// Reads the whole file into memory: project files are the target, so a range
/// protocol would be premature; the meta tunnel is the only reachable caller.
pub(super) async fn read_file(
    State(state): State<Arc<AppState>>,
    Query(q): Query<ListDirQuery>,
) -> Result<Vec<u8>, ApiError> {
    let roots = state.host.effective_roots().await?;
    let requested = std::path::PathBuf::from(&q.path);
    if !fs::within_roots(&requested, &roots) {
        return Err(ApiError(anyhow!("path is outside the configured project roots")));
    }
    // within_roots already rejects non-existent paths; reject a directory too
    // so the error is honest rather than an opaque read failure.
    if !requested.is_file() {
        return Err(ApiError(anyhow!("path is not a file")));
    }
    let bytes = tokio::fs::read(&requested)
        .await
        .with_context(|| format!("reading {}", requested.display()))?;
    Ok(bytes)
}

/// Query for `POST /fs/write`.
#[derive(Deserialize)]
pub(super) struct WriteFileQuery {
    /// Absolute host directory to write into (root-confined).
    pub(super) dir: String,
    /// Client filename; sanitized to a single path component.
    pub(super) name: String,
}

/// `POST /fs/write?dir=<abs>&name=<file>` (body = bytes) — upload a local file
/// into a chosen host directory (root-confined). Never overwrites: an existing
/// same-named file yields `409`. `403` for a directory outside the roots.
pub(super) async fn write_file(
    State(state): State<Arc<AppState>>,
    Query(q): Query<WriteFileQuery>,
    body: axum::body::Bytes,
) -> Result<Json<UploadResponse>, ApiError> {
    let roots = state.host.effective_roots().await?;
    let dir = std::path::PathBuf::from(&q.dir);
    if !fs::within_roots(&dir, &roots) {
        return Err(ApiError(anyhow!("path is outside the configured project roots")));
    }
    let safe = sanitize_file_name(&q.name)?;
    let path = dir.join(&safe);
    // create_new is atomic: an existing same-named file is never silently
    // overwritten — it errors with AlreadyExists, which maps to 409.
    use tokio::io::AsyncWriteExt;
    match tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&path)
        .await
    {
        Ok(mut f) => {
            f.write_all(&body)
                .await
                .with_context(|| format!("writing {}", path.display()))?;
            // Tokio can finish write_all before its background write completes.
            // Wait for those bytes (and any error) before acknowledging upload.
            f.flush()
                .await
                .with_context(|| format!("flushing {}", path.display()))?;
        },
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            return Err(ApiError(anyhow!("a file named `{safe}` already exists here")));
        },
        Err(e) => {
            return Err(ApiError(
                anyhow::Error::from(e).context(format!("creating {}", path.display())),
            ));
        },
    }
    Ok(Json(UploadResponse {
        path: path.display().to_string(),
        size: body.len() as u64,
    }))
}

/// Per-file cap for `/uploads/{name}` bodies. Generous for documents while
/// keeping a runaway request bounded (the tunnel itself has no practical cap).
pub(super) const UPLOAD_BODY_LIMIT: usize = 64 * 1024 * 1024;

/// `{ "path": ..., "size": ... }` — where an uploaded attachment landed.
#[derive(Serialize)]
pub(super) struct UploadResponse {
    /// Absolute host filesystem path of the stored file.
    pub(super) path: String,
    /// Stored size in bytes.
    pub(super) size: u64,
}

/// Store an uploaded attachment under `$CODEX_HOME/pocket-codex-uploads/` and
/// return its absolute host path. The controller then references that path in
/// the turn text, and the agent reads it with its own tools — codex's native
/// host-file workflow (its input protocol has no document slot). Only the
/// authenticated account owner can reach this tunnel; the filename is
/// sanitized to a single path component regardless.
pub(super) async fn upload_file(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
    body: axum::body::Bytes,
) -> Result<Json<UploadResponse>, ApiError> {
    let dir = match &state.uploads_dir {
        Some(dir) => dir.clone(),
        None => pocket_codex_codex::rollout::codex_home()
            .context("resolving CODEX_HOME")?
            .join("pocket-codex-uploads"),
    };
    tokio::fs::create_dir_all(&dir)
        .await
        .with_context(|| format!("creating uploads dir {}", dir.display()))?;
    let path = save_upload(&dir, &name, &body).await?;
    Ok(Json(UploadResponse {
        path: path.display().to_string(),
        size: body.len() as u64,
    }))
}

/// Write `bytes` into a fresh per-upload subdirectory of `dir` under the
/// sanitized client-provided `name`; returns the final path. A subdirectory
/// (millisecond timestamp, counter-bumped on collision) rather than a name
/// prefix keeps the file's BASENAME exactly what the user attached — the path
/// is quoted into the prompt and rendered as a chip, so `report.pdf` must not
/// become `1735689…-report.pdf`.
async fn save_upload(
    dir: &std::path::Path,
    name: &str,
    bytes: &[u8],
) -> Result<PathBuf, anyhow::Error> {
    let safe = sanitize_file_name(name)?;
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    // CLAIM the subdirectory atomically with `create_dir` (which errors on an
    // existing dir) — a check-then-create would let two same-millisecond
    // uploads share one subdir and silently overwrite same-named files.
    let mut n = 0u32;
    let sub = loop {
        let cand =
            if n == 0 { dir.join(format!("{millis}")) } else { dir.join(format!("{millis}-{n}")) };
        match tokio::fs::create_dir(&cand).await {
            Ok(()) => break cand,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => n += 1,
            Err(e) => {
                return Err(e).with_context(|| format!("creating upload dir {}", cand.display()));
            },
        }
    };
    let path = sub.join(safe);
    tokio::fs::write(&path, bytes)
        .await
        .with_context(|| format!("writing upload {}", path.display()))?;
    Ok(path)
}

/// Reduce a client-supplied filename to one safe path component: strips
/// directory separators and traversal, drops characters Windows forbids,
/// trims TRAILING dots/spaces (the Windows-compat problem — leading dots are
/// meaningful dotfile names and survive), sidesteps Windows reserved device
/// names, and caps the length. Errors only when nothing usable remains.
fn sanitize_file_name(name: &str) -> Result<String, anyhow::Error> {
    let cleaned: String = name
        .chars()
        .filter(|c| !matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|'))
        .filter(|c| !c.is_control())
        .collect();
    let trimmed = cleaned.trim_start_matches(' ').trim_end_matches([' ', '.']);
    if trimmed.is_empty() {
        return Err(anyhow!("filename `{name}` has no usable characters"));
    }
    let capped: String = trimmed.chars().take(120).collect();
    // `CON`/`NUL`/`COM1`… (bare or with any extension) open DOS devices instead
    // of files on Windows hosts — the write would vanish into the device.
    // Prefix them so the bytes land on disk.
    let stem = capped.split('.').next().unwrap_or("").to_ascii_uppercase();
    let reserved = matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || (stem.len() == 4
            && (stem.starts_with("COM") || stem.starts_with("LPT"))
            && stem[3..].chars().all(|c| c.is_ascii_digit() && c != '0'));
    if reserved {
        return Ok(format!("_{capped}"));
    }
    Ok(capped)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::HostConfig;

    #[test]
    fn file_upload_waits_for_background_write_before_success() {
        use std::{
            future::Future,
            task::{Context as TaskContext, Waker},
        };

        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .max_blocking_threads(1)
            .build()
            .expect("runtime");
        runtime.block_on(async {
            let dir = tempfile::tempdir().expect("tempdir");
            let root = dir.path().display().to_string();
            let host = HostStore::open(dir.path().join("host.json"))
                .await
                .expect("host store");
            host.put(HostConfig {
                project_roots: vec![root.clone()],
                default_project: None,
            })
            .await
            .expect("project root");
            let state = Arc::new(AppState {
                app_ws_addr: "127.0.0.1:1".parse().expect("unused address"),
                store: Arc::new(
                    ConfigStore::open(dir.path().join("threads.json"))
                        .await
                        .expect("config store"),
                ),
                host: Arc::new(host),
                uploads_dir: None,
                session_dirs: None,
            });

            let block_worker = || {
                let (release, wait) = std::sync::mpsc::channel::<()>();
                let (started, ready) = tokio::sync::oneshot::channel();
                let task = tokio::task::spawn_blocking(move || {
                    let _ = started.send(());
                    let _ = wait.recv();
                });
                (release, ready, task)
            };

            // Finish the fresh project-policy read before controlling file IO.
            let (policy_release, policy_started, policy_task) = block_worker();
            policy_started.await.expect("policy blocker started");
            let mut upload = std::pin::pin!(write_file(
                State(state),
                Query(WriteFileQuery {
                    dir: root,
                    name: "note.txt".into()
                }),
                axum::body::Bytes::from_static(b"uploaded"),
            ));
            let mut cx = TaskContext::from_waker(Waker::noop());
            assert!(upload.as_mut().poll(&mut cx).is_pending());

            // Queue file open behind a blocked worker so its completion cannot
            // race the next poll of the handler.
            let (open_release, open_started, open_task) = block_worker();
            drop(policy_release);
            policy_task.await.expect("policy blocker");
            open_started.await.expect("open blocker started");
            assert!(upload.as_mut().poll(&mut cx).is_pending());

            // The second blocker runs after open, but before the handler can
            // queue its write. A successful response here would expose an
            // empty file to an immediate HTTP download or filesystem reader.
            let (write_release, write_started, write_task) = block_worker();
            drop(open_release);
            open_task.await.expect("open blocker");
            write_started.await.expect("write blocker started");
            let completed_early = upload.as_mut().poll(&mut cx).is_ready();
            let before = std::fs::read(dir.path().join("note.txt")).expect("created file");
            drop(write_release);
            write_task.await.expect("write blocker");
            assert!(before.is_empty(), "the write must still be queued");
            assert!(!completed_early, "upload acknowledged before the file write completed");
            let response = upload
                .await
                .map_err(|error| error.0)
                .expect("upload response");
            assert_eq!(response.size, 8);
            assert_eq!(std::fs::read(&response.path).expect("read acknowledged file"), b"uploaded");
        });
    }

    #[test]
    fn sanitize_strips_traversal_and_separators() {
        let clean = |n: &str| sanitize_file_name(n).expect("sanitizable name");
        assert_eq!(clean("report.pdf"), "report.pdf");
        // Traversal never escapes the uploads dir: separators are removed and
        // what remains is one path component (leading dots are harmless there).
        assert_eq!(clean("../../etc/passwd"), "....etcpasswd");
        assert_eq!(clean(r"..\..\boot.ini"), "....boot.ini");
        assert_eq!(clean("a:b*c?d\"e<f>g|h.txt"), "abcdefgh.txt");
        // CJK names survive.
        assert_eq!(clean("报告.md"), "报告.md");
        // Dotfiles keep their leading dot (only TRAILING dots/spaces are the
        // Windows-compat problem) — '.env' must not become 'env'.
        assert_eq!(clean(".env"), ".env");
        assert_eq!(clean("notes.txt.  "), "notes.txt");
        // Windows reserved device names are defused with a prefix.
        assert_eq!(clean("nul.txt"), "_nul.txt");
        assert_eq!(clean("COM1"), "_COM1");
        assert_eq!(clean("common.txt"), "common.txt"); // not COM<digit>
                                                       // Nothing usable → error.
        assert!(sanitize_file_name("../..").is_err());
        assert!(sanitize_file_name("").is_err());
    }

    #[tokio::test]
    async fn save_upload_writes_and_never_overwrites() {
        let dir = tempfile::tempdir().expect("tempdir");
        let a = save_upload(dir.path(), "notes.txt", b"one")
            .await
            .expect("first");
        let b = save_upload(dir.path(), "notes.txt", b"two")
            .await
            .expect("second");
        assert_ne!(a, b, "same name must not overwrite");
        assert_eq!(std::fs::read(&a).expect("read a"), b"one");
        assert_eq!(std::fs::read(&b).expect("read b"), b"two");
        assert!(a.starts_with(dir.path()) && b.starts_with(dir.path()));
        // The basename stays exactly what was attached — it is quoted into the
        // prompt and rendered as a chip.
        assert_eq!(a.file_name().and_then(|n| n.to_str()), Some("notes.txt"));
        assert_eq!(b.file_name().and_then(|n| n.to_str()), Some("notes.txt"));
    }
}
