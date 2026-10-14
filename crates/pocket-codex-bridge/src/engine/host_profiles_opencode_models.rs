//! Read only the configured gateway's advertised models, with bounded I/O.

use std::{collections::BTreeMap, time::Duration};

use anyhow::{anyhow, bail, ensure, Result};
use pocket_codex_core::provider::{ApiProtocol, ProviderEndpoint};
use reqwest::{header::HeaderValue, Client, Url};
use serde_json::{json, Map, Value};

const MAX_BYTES: usize = 4 * 1024 * 1024;
const MAX_MODELS: usize = 4096;
const MAX_PAGES: usize = 32;
const TIMEOUT: Duration = Duration::from_secs(15);

pub(super) async fn discover(endpoint: &ProviderEndpoint) -> Result<Map<String, Value>> {
    tokio::time::timeout(TIMEOUT, load(endpoint))
        .await
        .map_err(|_| anyhow!("model discovery timed out"))?
}

async fn load(endpoint: &ProviderEndpoint) -> Result<Map<String, Value>> {
    let mut url = Url::parse(&endpoint.base_url)
        .map_err(|_| anyhow!("the model discovery URL is invalid"))?;
    ensure!(
        matches!(url.scheme(), "http" | "https")
            && url.username().is_empty()
            && url.password().is_none()
            && url.fragment().is_none(),
        "the model discovery URL is invalid"
    );
    url.set_path(&format!("{}/models", url.path().trim_end_matches('/')));
    let key = endpoint
        .key
        .as_ref()
        .ok_or_else(|| anyhow!("the gateway API key is missing"))?;
    let anthropic = endpoint.protocol == ApiProtocol::AnthropicMessages;
    let value =
        if anthropic { key.expose().to_owned() } else { format!("Bearer {}", key.expose()) };
    let mut credential =
        HeaderValue::from_str(&value).map_err(|_| anyhow!("the gateway API key is invalid"))?;
    credential.set_sensitive(true);
    let http = Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(5))
        .timeout(TIMEOUT)
        .build()
        .map_err(|_| anyhow!("model discovery could not initialize"))?;
    let mut models = BTreeMap::new();
    let mut cursor: Option<String> = None;
    let mut seen = std::collections::BTreeSet::new();
    let mut bytes = 0;
    for _ in 0..MAX_PAGES {
        let mut request = http.get(url.clone());
        if anthropic {
            request = request
                .header("x-api-key", credential.clone())
                .header("anthropic-version", "2023-06-01")
                .query(&[("limit", "1000")]);
            if let Some(cursor) = &cursor {
                request = request.query(&[("after_id", cursor)]);
            }
        } else {
            request = request.header("authorization", credential.clone());
        }
        let response = request
            .send()
            .await
            .map_err(|_| anyhow!("model discovery request did not complete"))?;
        ensure!(
            response.status().is_success(),
            "model discovery returned HTTP {}",
            response.status().as_u16()
        );
        let page = read_page(response, &mut bytes).await?;
        let entries = page["data"]
            .as_array()
            .ok_or_else(|| anyhow!("the gateway returned an invalid model list"))?;
        for entry in entries {
            let id = entry["id"]
                .as_str()
                .filter(|id| valid_text(id, 512))
                .ok_or_else(|| anyhow!("the gateway returned an invalid model identifier"))?;
            if entry["lifecycle"] == "retired" {
                continue;
            }
            let name = entry["display_name"]
                .as_str()
                .or_else(|| entry["name"].as_str())
                .filter(|name| valid_text(name, 256))
                .unwrap_or(id);
            // Do not import arbitrary provider options, headers or model overrides.
            models
                .entry(id.to_owned())
                .or_insert_with(|| json!({"name":name}));
            ensure!(models.len() <= MAX_MODELS, "the gateway model list exceeds the model limit");
        }
        match page.get("has_more") {
            None | Some(Value::Bool(false)) => {
                ensure!(!models.is_empty(), "the gateway returned no available models");
                return Ok(models.into_iter().collect());
            },
            Some(Value::Bool(true)) if anthropic => {
                let next = page["last_id"]
                    .as_str()
                    .filter(|id| valid_text(id, 512))
                    .ok_or_else(|| anyhow!("the gateway model list has no valid next cursor"))?;
                ensure!(
                    !entries.is_empty() && seen.insert(next.to_owned()),
                    "the gateway model list repeated a page"
                );
                cursor = Some(next.to_owned());
            },
            _ => bail!("the gateway model list has unsupported pagination"),
        }
    }
    bail!("the gateway model list exceeds the page limit")
}

fn valid_text(value: &str, max: usize) -> bool {
    !value.trim().is_empty() && value.len() <= max && super::literal(value)
}

async fn read_page(mut response: reqwest::Response, total: &mut usize) -> Result<Value> {
    if let Some(size) = response.content_length() {
        ensure!(
            size <= MAX_BYTES.saturating_sub(*total) as u64,
            "the gateway model list exceeds the byte limit"
        );
    }
    let mut body = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| anyhow!("model discovery response did not complete"))?
    {
        *total = total.saturating_add(chunk.len());
        ensure!(*total <= MAX_BYTES, "the gateway model list exceeds the byte limit");
        body.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&body).map_err(|_| anyhow!("the gateway returned an invalid model list"))
}

#[cfg(test)]
#[path = "host_profiles_opencode_models_tests.rs"]
mod tests;
