//! Fetching release files: a small one whole, a package to disk with its
//! size and SHA-256 checked as it arrives.
use std::{
    path::Path,
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};

use futures::StreamExt;
use ring::digest::{Context as Digest, SHA256};
use tokio::io::AsyncWriteExt;

use super::{manifest::Asset, Failure, Kind};

const CONNECT: Duration = Duration::from_secs(15);
/// A small file arrives whole within this.
const SMALL: Duration = Duration::from_secs(30);
/// A package may take long; a stall this long ends it.
const STALL: Duration = Duration::from_secs(60);

/// The updater's HTTP client: the system's proxy variables apply, as for
/// every outbound request of the app.
pub struct Fetcher {
    client: reqwest::Client,
}

/// Why a download stopped.
pub enum Stop {
    /// It failed.
    Failed(Failure),
    /// The user cancelled it.
    Cancelled,
}

impl From<Failure> for Stop {
    fn from(failure: Failure) -> Self {
        Self::Failed(failure)
    }
}

fn network(error: impl std::fmt::Display) -> Failure {
    Failure::new(Kind::Network, error)
}

impl Fetcher {
    /// A client with the updater's timeouts.
    pub fn new() -> Result<Self, Failure> {
        let client = reqwest::Client::builder()
            .connect_timeout(CONNECT)
            .user_agent(concat!("POCOX/", env!("CARGO_PKG_VERSION"), " updater"))
            .build()
            .map_err(network)?;
        Ok(Self {
            client,
        })
    }

    async fn get(&self, url: &str) -> Result<reqwest::Response, Failure> {
        let response = self.client.get(url).send().await.map_err(network)?;
        let status = response.status();
        if !status.is_success() {
            return Err(network(format!("HTTP {status} for {url}")));
        }
        Ok(response)
    }

    /// A small file, at most `limit` bytes.
    pub async fn small(&self, url: &str, limit: usize) -> Result<Vec<u8>, Failure> {
        tokio::time::timeout(SMALL, async {
            let mut response = self.get(url).await?;
            let mut body = Vec::new();
            while let Some(chunk) = response.chunk().await.map_err(network)? {
                body.extend_from_slice(&chunk);
                if body.len() > limit {
                    return Err(network(format!("{url} is too large")));
                }
            }
            Ok(body)
        })
        .await
        .map_err(|_| network(format!("{url} timed out")))?
    }

    /// `url` into `target`, which ends up exactly `asset` or removed.
    /// `progress` hears the bytes received so far; `cancelled` stops it.
    pub async fn file(
        &self,
        url: &str,
        target: &Path,
        asset: &Asset,
        mut progress: impl FnMut(u64),
        cancelled: &AtomicBool,
    ) -> Result<(), Stop> {
        let result = self
            .download(url, target, asset, &mut progress, cancelled)
            .await;
        if result.is_err() {
            let _ = tokio::fs::remove_file(target).await;
        }
        result
    }

    async fn download(
        &self,
        url: &str,
        target: &Path,
        asset: &Asset,
        progress: &mut impl FnMut(u64),
        cancelled: &AtomicBool,
    ) -> Result<(), Stop> {
        let response = self.get(url).await?;
        let mut file = tokio::fs::File::create(target)
            .await
            .map_err(|error| Failure::new(Kind::Install, error))?;
        let mut stream = response.bytes_stream();
        let mut digest = Digest::new(&SHA256);
        let mut received = 0u64;
        loop {
            if cancelled.load(Ordering::Relaxed) {
                return Err(Stop::Cancelled);
            }
            let chunk = match tokio::time::timeout(STALL, stream.next()).await {
                Err(_) => return Err(network(format!("{url} stalled")).into()),
                Ok(None) => break,
                Ok(Some(chunk)) => chunk.map_err(network)?,
            };
            received += chunk.len() as u64;
            if received > asset.size {
                return Err(Failure::new(Kind::Checksum, "larger than the release says").into());
            }
            digest.update(&chunk);
            file.write_all(&chunk)
                .await
                .map_err(|error| Failure::new(Kind::Install, error))?;
            progress(received);
        }
        file.flush()
            .await
            .map_err(|error| Failure::new(Kind::Install, error))?;
        file.sync_all()
            .await
            .map_err(|error| Failure::new(Kind::Install, error))?;
        let hash = hex(digest.finish().as_ref());
        if received != asset.size || hash != asset.sha256 {
            return Err(
                Failure::new(Kind::Checksum, format!("got {received} bytes, {hash}")).into()
            );
        }
        Ok(())
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
