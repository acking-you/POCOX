//! The newest version each vendor publishes for an installation, looked up
//! where the vendor's own updater looks (see `install::Source`). Requests
//! go through the app's HTTP client, so the app's network proxy applies;
//! Grok answers for itself with that proxy in its environment.

use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use serde_json::Value;

use super::command;
use super::install::{Installed, Source};
use crate::engine::{network, runtime};

const CONNECT: Duration = Duration::from_secs(10);
const TOTAL: Duration = Duration::from_secs(30);
/// A release document (GitHub lists every asset) fits within this.
const BODY_LIMIT: usize = 4 << 20;

fn client() -> Result<reqwest::Client> {
    network::client(&runtime::support_dir()?)?
        .connect_timeout(CONNECT)
        .timeout(TOTAL)
        .user_agent(concat!("POCOX/", env!("CARGO_PKG_VERSION"), " harness-check"))
        .build()
        .context("building the version check client")
}

/// The newest version of each installation, in order: `None` where the
/// lookup failed or there is nothing to look up. Blocks; the lookups run
/// concurrently.
pub(super) fn lookup(installed: &[Installed]) -> Vec<Option<String>> {
    let client = match client() {
        Ok(client) => client,
        Err(error) => {
            tracing::warn!("harness version checks unavailable: {error:#}");
            return vec![None; installed.len()];
        },
    };
    runtime::runtime().block_on(futures::future::join_all(installed.iter().map(|found| {
        let client = client.clone();
        async move {
            let result = match &found.source {
                Source::Unchecked => return None,
                Source::Own => {
                    let path = found.path.clone();
                    tokio::task::spawn_blocking(move || grok(&path))
                        .await
                        .map_err(|error| anyhow!("{error}"))
                        .and_then(|result| result)
                },
                source => fetch(&client, source).await,
            };
            match result {
                Ok(version) => Some(version),
                Err(error) => {
                    tracing::warn!(
                        kind = found.kind.label(),
                        "harness version check failed: {error:#}"
                    );
                    None
                },
            }
        }
    })))
}

async fn fetch(client: &reqwest::Client, source: &Source) -> Result<String> {
    let version = match source {
        Source::Npm {
            package,
            tag,
        } => {
            let url = format!(
                "https://registry.npmjs.org/-/package/{}/dist-tags",
                package.replace('/', "%2F")
            );
            json(client, &url).await?[*tag]
                .as_str()
                .map(str::to_string)
                .ok_or_else(|| anyhow!("{package} has no `{tag}` release"))?
        },
        Source::Cask(cask) => {
            let url = format!("https://formulae.brew.sh/api/cask/{cask}.json");
            let value = json(client, &url).await?;
            let version = value["version"]
                .as_str()
                .ok_or_else(|| anyhow!("the {cask} cask has no version"))?;
            // A cask version may carry a build after a comma.
            version.split(',').next().unwrap_or(version).to_string()
        },
        Source::GitHub {
            repo,
            prefix,
        } => {
            let url = format!("https://api.github.com/repos/{repo}/releases/latest");
            let value = json(client, &url).await?;
            let tag = value["tag_name"]
                .as_str()
                .ok_or_else(|| anyhow!("{repo} has no release tag"))?;
            tag.strip_prefix(prefix)
                .ok_or_else(|| anyhow!("unexpected {repo} release tag"))?
                .to_string()
        },
        Source::Text(url) => text(client, url).await?.trim().to_string(),
        Source::Own | Source::Unchecked => bail!("not looked up here"),
    };
    let version = version.trim_start_matches('v').to_string();
    super::install::parse_version(&version).ok_or_else(|| anyhow!("unexpected version text"))?;
    Ok(version)
}

async fn body(client: &reqwest::Client, url: &str) -> Result<Vec<u8>> {
    let mut response = client
        .get(url)
        .header(reqwest::header::ACCEPT, "application/json, text/plain")
        .send()
        .await
        .context("version check request failed")?
        .error_for_status()
        .context("version check refused")?;
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .context("version check interrupted")?
    {
        if bytes.len() + chunk.len() > BODY_LIMIT {
            bail!("version check answer too large");
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

async fn json(client: &reqwest::Client, url: &str) -> Result<Value> {
    serde_json::from_slice(&body(client, url).await?).context("unreadable version check answer")
}

async fn text(client: &reqwest::Client, url: &str) -> Result<String> {
    String::from_utf8(body(client, url).await?).context("unreadable version check answer")
}

/// Grok's own check (`grok update --check --json`), from its installer and
/// channel.
fn grok(path: &std::path::Path) -> Result<String> {
    let output = command::probe(path, &["update", "--check", "--json"])
        .ok_or_else(|| anyhow!("grok could not check for updates"))?;
    grok_latest(&output)
}

/// `latestVersion` of a `grok update --check --json` answer.
pub(super) fn grok_latest(output: &str) -> Result<String> {
    let value: Value =
        serde_json::from_str(output.trim()).context("unreadable grok update check")?;
    if let Some(error) = value["error"].as_str().filter(|error| !error.is_empty()) {
        bail!("grok could not check for updates: {error}");
    }
    let latest = value["latestVersion"]
        .as_str()
        .ok_or_else(|| anyhow!("grok reported no latest version"))?;
    super::install::version_text(latest).ok_or_else(|| anyhow!("unexpected grok version"))
}
