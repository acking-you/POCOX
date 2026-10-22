//! Native attachment preparation; picker and clipboard permissions stay in
//! Flutter.
use super::*;
use crate::engine::{
    attachments,
    execution::{self, Lane},
};

/// Encoded image ready to preview and send; no image algorithms run in Dart.
pub struct PreparedImageDto {
    /// Encoded original or resized JPEG.
    pub bytes: Vec<u8>,
    /// Encoded MIME type.
    pub mime: String,
    /// Encoded width.
    pub width: u32,
    /// Encoded height.
    pub height: u32,
    /// Exact wire payload, also reused for explicit retries.
    pub data_url: String,
}

/// Prepare clipboard bytes or a selected local file, with exactly one source.
pub async fn attachment_prepare_image(
    bytes: Option<Vec<u8>>,
    path: Option<String>,
) -> Result<PreparedImageDto> {
    execution::run(Lane::Cpu, move || {
        let bytes = match (bytes, path) {
            (Some(bytes), None) => bytes,
            (None, Some(path)) => attachments::read_file(std::path::Path::new(&path))?,
            _ => anyhow::bail!("select exactly one image source"),
        };
        let image = attachments::prepare(bytes)?;
        Ok(PreparedImageDto {
            bytes: image.bytes,
            mime: image.mime,
            width: image.width,
            height: image.height,
            data_url: image.data_url,
        })
    })
    .await
}

/// Local file bytes owned by Rust until uploaded or released by the picker
/// flow.
#[frb(opaque)]
pub struct PreparedFile {
    bytes: Vec<u8>,
    _lease: tokio::sync::OwnedSemaphorePermit,
}

/// Four handles of at most 32 MiB each.
static FILE_HANDLES: std::sync::LazyLock<std::sync::Arc<tokio::sync::Semaphore>> =
    std::sync::LazyLock::new(|| std::sync::Arc::new(tokio::sync::Semaphore::new(4)));

/// Read an explicitly picked local file without moving its body through Dart.
/// The caller must check its draft admission again before starting the upload.
pub async fn attachment_read_file(path: String) -> Result<PreparedFile> {
    let lease = FILE_HANDLES
        .clone()
        .try_acquire_owned()
        .map_err(|_| anyhow!("attachment memory budget is full; finish another upload first"))?;
    execution::run(Lane::Read, move || {
        Ok(PreparedFile {
            _lease: lease,
            bytes: attachments::read_file(std::path::Path::new(&path))?,
        })
    })
    .await
}

/// Upload a prepared file only to its originally authorized account/relay.
pub async fn meta_upload_prepared_file(
    service_key: String,
    file_name: String,
    file: PreparedFile,
    expected_context: String,
) -> Result<String> {
    // The lease is released when the upload ends, whatever its outcome.
    execution::run(Lane::Transfer, move || {
        let PreparedFile {
            bytes,
            _lease,
        } = file;
        Ok(meta::upload_file_scoped(&service_key, &file_name, bytes, &expected_context)?.path)
    })
    .await
}
