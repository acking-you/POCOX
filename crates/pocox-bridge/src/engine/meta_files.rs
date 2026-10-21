//! Host files over the meta service: attachment uploads, the root-confined
//! file browser, previews and downloads of conversation file links, thread
//! images and writes into a project folder.

use super::*;

/// A stored attachment upload, echoed by the host. (The response also carries
/// a `size` field; the caller already knows the byte count it sent, so only
/// the path is modelled.)
#[derive(Deserialize)]
pub struct UploadedFile {
    /// Absolute HOST filesystem path where the file landed.
    pub path: String,
}

/// Big documents over a slow relay hop can outlive [`META_TIMEOUT`]; uploads
/// get their own generous per-request bound instead.
const UPLOAD_TIMEOUT: Duration = Duration::from_secs(180);

/// Revision for a pending attachment read. Includes saved configuration so
/// a change is visible even before transport invalidation is published.
pub fn upload_context() -> Result<String> {
    let support = runtime::support_dir()?;
    upload_context_at(&support)
}

pub(super) fn upload_context_at(support: &std::path::Path) -> Result<String> {
    let before = transport::epoch();
    let config = crate::engine::config::load_config(support)?;
    // Only return the digest; config contains credentials and stays local.
    let identity =
        serde_json::to_vec(&(before, &config.account, config.relay(), config.relay_key()))?;
    anyhow::ensure!(transport::is_current(before), "attachment context changed");
    Ok(pocox_core::history_sync::digest_bytes(&identity))
}

/// Upload only while the configuration captured before the file read remains
/// current. The endpoint is resolved once and never retargeted after this
/// check.
pub fn upload_file_scoped(
    service_key: &str,
    file_name: &str,
    bytes: Vec<u8>,
    expected: &str,
) -> Result<UploadedFile> {
    anyhow::ensure!(upload_context()? == expected, "attachment context changed; retry the upload");
    let url = endpoint(service_key, &["uploads", file_name])?;
    anyhow::ensure!(upload_context()? == expected, "attachment context changed; retry the upload");
    upload_to(url, bytes)
}

/// Upload a document/file attachment to the host behind `service_key`,
/// returning where it landed on the HOST filesystem. The turn text then
/// references that path so the agent reads the file with its own tools —
/// codex's native host-file workflow (its input protocol has no document
/// slot; only images travel inline).
pub fn upload_file(service_key: &str, file_name: &str, bytes: Vec<u8>) -> Result<UploadedFile> {
    let url = endpoint(service_key, &["uploads", file_name])?;
    upload_to(url, bytes)
}

fn upload_to(url: Url, bytes: Vec<u8>) -> Result<UploadedFile> {
    runtime::runtime().block_on(async move {
        let resp = client()
            .post(url)
            .timeout(UPLOAD_TIMEOUT)
            .body(bytes)
            .send()
            .await
            .context("meta POST upload")?;
        ensure_ok(resp)
            .await?
            .json()
            .await
            .context("decoding upload response")
    })
}

/// `{ "path": ..., "entries": [...] }` — one directory's browsable children.
#[derive(Deserialize)]
struct ListDirResponse {
    pub(super) entries: Vec<DirEntry>,
}

/// List the sub-directories of `path` on the host, for the remote
/// project-folder browser. The host confines this to its configured roots, so
/// a path outside them errors (surfaced as a `403` in the returned message).
pub fn list_dir(service_key: &str, path: &str) -> Result<Vec<DirEntry>> {
    let mut url = endpoint(service_key, &["fs", "list"])?;
    url.query_pairs_mut().append_pair("path", path);
    let resp: ListDirResponse = runtime::runtime().block_on(get_json(url))?;
    Ok(resp.entries)
}

/// `{ "path": ..., "files": [...] }` — one directory's files.
#[derive(Deserialize)]
struct ListFilesResponse {
    pub(super) files: Vec<FileEntry>,
}

/// List the files in `path` on the host (root-confined), for the file-transfer
/// panel. A path outside the configured roots errors (403 in the message).
pub fn list_files(service_key: &str, path: &str) -> Result<Vec<FileEntry>> {
    let mut url = endpoint(service_key, &["fs", "files"])?;
    url.query_pairs_mut().append_pair("path", path);
    let resp: ListFilesResponse = runtime::runtime().block_on(get_json(url))?;
    Ok(resp.files)
}

/// Download a host file's raw bytes (root-confined) to the controller. Reuses
/// the generous upload timeout since a large file over a relay hop can outlast
/// [`META_TIMEOUT`].
pub fn read_file(service_key: &str, path: &str) -> Result<Vec<u8>> {
    let mut url = endpoint(service_key, &["fs", "read"])?;
    url.query_pairs_mut().append_pair("path", path);
    runtime::runtime().block_on(async move {
        let resp = client()
            .get(url)
            .timeout(UPLOAD_TIMEOUT)
            .send()
            .await
            .context("meta GET read")?;
        let resp = ensure_ok(resp).await?;
        Ok(resp.bytes().await.context("reading file bytes")?.to_vec())
    })
}

/// A bounded explicit file preview and the full file's size.
pub struct FilePreview {
    /// At most the host preview limit in bytes.
    pub bytes: Vec<u8>,
    /// Full size before truncation.
    pub total_size: u64,
}

fn file_link_url(service: &str, thread: Option<&str>, href: &str, preview: bool) -> Result<Url> {
    let mut url = endpoint(service, &["fs", "thread-file"])?;
    url.query_pairs_mut()
        .append_pair("href", href)
        .append_pair("preview", if preview { "true" } else { "false" });
    if let Some(thread) = thread {
        url.query_pairs_mut().append_pair("thread", thread);
    }
    Ok(url)
}

/// Fetch a bounded preview only after an explicit user action.
pub fn file_preview(service: &str, thread: Option<&str>, href: &str) -> Result<FilePreview> {
    let url = file_link_url(service, thread, href, true)?;
    runtime::runtime().block_on(async {
        let mut response = ensure_ok(client().get(url).send().await?).await?;
        let total_size: u64 = response
            .headers()
            .get("x-file-size")
            .context("host omitted file size")?
            .to_str()?
            .parse()?;
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await? {
            anyhow::ensure!(
                bytes.len() + chunk.len() <= pocox_host_svc::file_links::PREVIEW_LIMIT as usize,
                "host preview exceeds size limit"
            );
            bytes.extend_from_slice(&chunk);
        }
        anyhow::ensure!(
            bytes.len() as u64 == total_size.min(pocox_host_svc::file_links::PREVIEW_LIMIT),
            "file preview was incomplete"
        );
        Ok(FilePreview {
            bytes,
            total_size,
        })
    })
}

struct RemoveFile(Option<std::path::PathBuf>);
impl Drop for RemoveFile {
    fn drop(&mut self) {
        if let Some(path) = &self.0 {
            let _ = std::fs::remove_file(path);
        }
    }
}

pub(super) async fn download_response(
    mut response: reqwest::Response,
    destination: &std::path::Path,
    legacy: bool,
) -> Result<()> {
    use tokio::io::AsyncWriteExt;
    // Declare cleanup first so the open handle is dropped before removal on
    // Windows.
    let mut cleanup = RemoveFile(None);
    let mut file = tokio::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(destination)
        .await?;
    cleanup.0 = Some(destination.to_path_buf());
    let result = async {
        let expected = if legacy {
            // Reqwest removes Content-Length after transparent decompression;
            // a chunked legacy response may also have no declared size.
            response.content_length()
        } else {
            Some(
                response
                    .headers()
                    .get("x-file-size")
                    .context("host omitted file size")?
                    .to_str()?
                    .parse::<u64>()?,
            )
        };
        let mut received = 0_u64;
        while let Some(chunk) = tokio::time::timeout(META_TIMEOUT, response.chunk())
            .await
            .context("file download stalled")??
        {
            received += chunk.len() as u64;
            anyhow::ensure!(
                expected.is_none_or(|expected| received <= expected),
                "host sent more bytes than the declared file size"
            );
            file.write_all(&chunk).await?;
        }
        anyhow::ensure!(
            expected.is_none_or(|expected| received == expected),
            "file download was incomplete"
        );
        file.flush().await?;
        Ok::<_, anyhow::Error>(())
    }
    .await;
    // Wait for queued filesystem writes before closing and deleting on Windows.
    drop(file.into_std().await);
    if result.is_ok() {
        cleanup.0 = None;
    }
    result
}

/// Stream a file into a new private staging path without buffering its body.
pub fn file_download(
    service: &str,
    thread: Option<&str>,
    href: &str,
    destination: &str,
) -> Result<()> {
    let url = file_link_url(service, thread, href, false)?;
    let legacy_url = if thread.is_none() {
        let mut url = endpoint(service, &["fs", "read"])?;
        url.query_pairs_mut().append_pair("path", href);
        Some(url)
    } else {
        None
    };
    runtime::runtime().block_on(download_file(url, legacy_url, std::path::Path::new(destination)))
}

pub(super) async fn download_file(
    url: Url,
    legacy_url: Option<Url>,
    destination: &std::path::Path,
) -> Result<()> {
    let mut response = tokio::time::timeout(META_TIMEOUT, stream_client().get(url).send())
        .await
        .context("connecting for file download")??;
    let mut legacy = false;
    if response.status() == reqwest::StatusCode::NOT_FOUND {
        if let Some(url) = legacy_url {
            // Only the existing root-confined file browser can use this path.
            // Session links retain their selected-thread authorization.
            drop(response);
            response = tokio::time::timeout(META_TIMEOUT, stream_client().get(url).send())
                .await
                .context("connecting for legacy file download")??;
            legacy = true;
        }
    }
    download_response(ensure_ok(response).await?, destination, legacy).await
}

/// Verify shared filesystem access; a loopback tunnel is not evidence of
/// locality.
pub fn host_is_local(service: &str) -> Result<bool> {
    if serve::local_endpoints(service).is_some() {
        return Ok(true);
    }
    let dir = pocox_host_svc::file_links::probe_dir()?;
    std::fs::create_dir_all(&dir)?;
    let id = uuid::Uuid::new_v4();
    let secret = uuid::Uuid::new_v4().to_string();
    let path = dir.join(id.to_string());
    let mut options = std::fs::OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut cleanup = RemoveFile(None);
    let mut file = options.open(&path)?;
    cleanup.0 = Some(path);
    std::io::Write::write_all(&mut file, secret.as_bytes())?;
    drop(file);
    let mut url = endpoint(service, &["host", "local-probe"])?;
    url.query_pairs_mut().append_pair("id", &id.to_string());
    let verified = runtime::runtime().block_on(async {
        let response = client()
            .get(url)
            .timeout(Duration::from_secs(5))
            .send()
            .await?;
        let value: serde_json::Value = ensure_ok(response).await?.json().await?;
        Ok::<_, anyhow::Error>(
            value.get("token").and_then(serde_json::Value::as_str) == Some(secret.as_str()),
        )
    });
    Ok(verified.unwrap_or(false))
}

/// Read an image the thread's transcript already references, so it can be
/// shown inline. Unlike [`read_file`] this is not root-confined — the host
/// authorises it against the transcript instead (see the host service's
/// `/fs/thread-image`), which is what lets a pasted screenshot in the OS temp
/// directory render on a remote controller.
pub fn read_thread_image(service_key: &str, thread_id: &str, path: &str) -> Result<Vec<u8>> {
    if let Ok(Some(bytes)) = crate::engine::session_sync::preview(service_key, thread_id, path) {
        return Ok(bytes);
    }
    let mut url = endpoint(service_key, &["fs", "thread-image"])?;
    url.query_pairs_mut()
        .append_pair("thread", thread_id)
        .append_pair("path", path);
    let bytes = runtime::runtime().block_on(async move {
        let resp = client()
            .get(url)
            .timeout(UPLOAD_TIMEOUT)
            .send()
            .await
            .context("meta GET thread-image")?;
        let resp = ensure_ok(resp).await?;
        Ok::<_, anyhow::Error>(resp.bytes().await.context("reading image bytes")?.to_vec())
    })?;
    crate::engine::session_sync::save_preview(service_key, thread_id, path, &bytes);
    Ok(bytes)
}

/// Upload local `bytes` as `file_name` into host directory `dir`
/// (root-confined); returns where it landed. Never overwrites (a collision
/// surfaces the host's 409 in the returned message).
pub fn write_file(
    service_key: &str,
    dir: &str,
    file_name: &str,
    bytes: Vec<u8>,
) -> Result<UploadedFile> {
    let mut url = endpoint(service_key, &["fs", "write"])?;
    url.query_pairs_mut()
        .append_pair("dir", dir)
        .append_pair("name", file_name);
    runtime::runtime().block_on(async move {
        let resp = client()
            .post(url)
            .timeout(UPLOAD_TIMEOUT)
            .body(bytes)
            .send()
            .await
            .context("meta POST write")?;
        ensure_ok(resp)
            .await?
            .json()
            .await
            .context("decoding write response")
    })
}
