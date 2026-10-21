//! Following every device's catalog for the app: one event stream per
//! device with a management entry, merged with the relay's listing into
//! overviews.
//!
//! ```text
//!   relay listing (every 20 s) ─┐
//!   /services/v1/events × N ────┼─► overview + what is new ─► the app
//!   this device's own state ────┘
//! ```

use std::{
    collections::{BTreeMap, HashMap},
    sync::{Arc, Mutex},
    time::Duration,
};

use anyhow::{bail, Context, Result};
use futures::StreamExt;
use once_cell::sync::OnceCell;
use pocox_core::service::{ServiceId, ServiceKind};
use tokio::{sync::Notify, task::JoinHandle};

use super::{
    catalog,
    model::{Catalog, CatalogEvent, DeviceView, Overview},
    state,
};
use crate::engine::{discovery, meta, runtime, transport};

/// One update for the app.
#[derive(Debug, Clone)]
pub struct Update {
    /// Everything visible now.
    pub overview: Overview,
    /// `(device, share id)` of shares announced since the previous update,
    /// this device's own included.
    pub added: Vec<(String, String)>,
}

#[derive(Default)]
struct Seen {
    listed: Vec<ServiceId>,
    catalogs: BTreeMap<String, Catalog>,
    /// This device's catalog at the previous update.
    local: Option<Catalog>,
    added: Vec<(String, String)>,
    /// Every device seen in this context, with its platform when known:
    /// one that leaves the relay stays listed, offline.
    known: BTreeMap<String, Option<String>>,
    /// Each device's share ids at its last event, kept when its stream drops:
    /// a reconnected stream's first event is compared with them, so a share
    /// made in between is still announced.
    shares_seen: BTreeMap<String, Vec<String>>,
}

fn stream_client() -> &'static reqwest::Client {
    static CLIENT: OnceCell<reqwest::Client> = OnceCell::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(8))
            .read_timeout(Duration::from_secs(45))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new())
    })
}

/// Largest single event accepted.
const MAX_EVENT: usize = 512 * 1024;

/// Read `host_key`'s event stream until it ends, recording each event.
async fn follow(
    device: String,
    host_key: String,
    seen: Arc<Mutex<Seen>>,
    wake: Arc<Notify>,
) -> Result<()> {
    let key = host_key.clone();
    let url =
        tokio::task::spawn_blocking(move || meta::endpoint(&key, &["services", "v1", "events"]))
            .await??;
    let response = stream_client()
        .get(url)
        .header("accept", "text/event-stream")
        .send()
        .await
        .context("opening the device's events")?;
    match response.status().as_u16() {
        200 => {},
        404 | 405 => return Ok(()),
        status => bail!("the device answered {status}"),
    }
    let mut body = response.bytes_stream();
    let mut buffer: Vec<u8> = Vec::new();
    while let Some(chunk) = body.next().await {
        buffer.extend_from_slice(&chunk?);
        while let Some(end) = find_blank_line(&buffer) {
            // Judged before it is copied or parsed: a whole frame can arrive
            // in one chunk.
            if end > MAX_EVENT {
                bail!("the device sent an oversized event");
            }
            let frame: Vec<u8> = buffer.drain(..end).collect();
            if let Some(event) = parse(&frame) {
                record(&device, event, &seen);
                wake.notify_one();
            }
        }
        if buffer.len() > MAX_EVENT {
            bail!("the device sent an oversized event");
        }
    }
    Ok(())
}

fn find_blank_line(buffer: &[u8]) -> Option<usize> {
    buffer
        .windows(2)
        .position(|w| w == b"\n\n")
        .map(|at| at + 2)
}

fn parse(frame: &[u8]) -> Option<CatalogEvent> {
    let text = std::str::from_utf8(frame).ok()?;
    let mut name = "message";
    let mut data = String::new();
    for line in text.lines() {
        if let Some(value) = line.strip_prefix("event:") {
            name = value.trim();
        } else if let Some(value) = line.strip_prefix("data:") {
            data.push_str(value.strip_prefix(' ').unwrap_or(value));
        }
    }
    (name == "catalog")
        .then(|| serde_json::from_str::<CatalogEvent>(&data).ok())
        .flatten()
}

fn record(device: &str, event: CatalogEvent, seen: &Mutex<Seen>) {
    let mut seen = seen.lock().unwrap_or_else(|p| p.into_inner());
    let catalog = catalog::sanitize(event.catalog);
    let ids: Vec<String> = catalog
        .shares
        .iter()
        .map(|share| share.id.clone())
        .collect();
    // The first time a device is seen its shares are not news (the stream's
    // own first event says none); afterwards, whatever it did not have.
    let added = match seen.shares_seen.get(device) {
        Some(before) => ids
            .iter()
            .filter(|id| !before.contains(id))
            .cloned()
            .collect(),
        None => event.added,
    };
    seen.added
        .extend(added.into_iter().map(|id| (device.to_string(), id)));
    seen.shares_seen.insert(device.to_string(), ids);
    seen.known
        .insert(device.to_string(), Some(catalog.platform.clone()).filter(|p| !p.is_empty()));
    seen.catalogs.insert(device.to_string(), catalog);
}

fn overview(seen: &mut Seen) -> Update {
    let this_device = runtime::device_id().unwrap_or_default();
    let hosting = state::lock().hosting;
    let mut catalogs = seen.catalogs.clone();
    if hosting {
        if let Ok(local) = catalog::local() {
            // This device's news, as the others learn it from its stream;
            // what exists when the app starts is not news.
            if let Some(previous) = &seen.local {
                let event = CatalogEvent::after(Some(previous), local.clone());
                seen.added
                    .extend(event.added.into_iter().map(|id| (this_device.clone(), id)));
            }
            seen.local = Some(local.clone());
            catalogs.insert(this_device.clone(), local);
        }
    }
    let mut overview = catalog::assemble(this_device, &seen.listed, &catalogs);
    // Devices that left the relay stay, offline and without services (the
    // galaxy's dim embers), until the account or relay changes.
    for (name, platform) in &seen.known {
        if overview.devices.iter().all(|device| &device.name != name) {
            overview.devices.push(DeviceView {
                name: name.clone(),
                platform: platform.clone(),
                online: false,
                catalog: false,
                tools: None,
                services: Vec::new(),
                shares: Vec::new(),
                consents: Vec::new(),
                builtin: Vec::new(),
            });
        }
    }
    let this_device = overview.this_device.clone();
    overview
        .devices
        .sort_by_key(|d| (d.name != this_device, d.name.clone()));
    Update {
        overview,
        added: std::mem::take(&mut seen.added),
    }
}

/// Follow every device until `deliver` returns `false` (the app stopped
/// listening). Restarts itself when the account or relay changes.
pub async fn run(mut deliver: impl FnMut(Update) -> bool + Send) {
    loop {
        match run_in_context(&mut deliver).await {
            Ok(()) => return,
            Err(error) => {
                tracing::debug!("catalog watch restarts: {error:#}");
                tokio::time::sleep(Duration::from_secs(3)).await;
            },
        }
    }
}

async fn run_in_context(deliver: &mut (impl FnMut(Update) -> bool + Send)) -> Result<()> {
    let owned = transport::resolve_owned().await?;
    let seen = Arc::new(Mutex::new(Seen::default()));
    let wake = Arc::new(Notify::new());
    let mut followers: HashMap<String, JoinHandle<()>> = HashMap::new();
    let mut local = state::changes();
    let mut last_listing = tokio::time::Instant::now() - Duration::from_secs(60);
    let result = loop {
        if !transport::is_current(owned.epoch) {
            break Err(anyhow::anyhow!("context changed"));
        }
        if last_listing.elapsed() >= Duration::from_secs(20) {
            last_listing = tokio::time::Instant::now();
            let listed = tokio::time::timeout(
                Duration::from_secs(10),
                discovery::discover(&owned.transport),
            )
            .await
            .ok()
            .and_then(Result::ok);
            if let Some(listed) = listed {
                let this_device = runtime::device_id().unwrap_or_default();
                let hosts: HashMap<String, String> = listed
                    .iter()
                    .filter(|id| id.kind == ServiceKind::Host && id.device != this_device)
                    .map(|id| (id.device.clone(), id.key()))
                    .collect();
                followers.retain(|device, task| {
                    let keep = hosts.contains_key(device) && !task.is_finished();
                    if !keep {
                        task.abort();
                    }
                    keep
                });
                {
                    let mut seen = seen.lock().unwrap_or_else(|p| p.into_inner());
                    seen.catalogs.retain(|device, _| hosts.contains_key(device));
                    for id in &listed {
                        seen.known.entry(id.device.clone()).or_insert(None);
                    }
                    seen.listed = listed;
                }
                for (device, key) in hosts {
                    if followers.contains_key(&device) {
                        continue;
                    }
                    let (seen, wake) = (seen.clone(), wake.clone());
                    let name = device.clone();
                    followers.insert(
                        device,
                        runtime::runtime().spawn(async move {
                            if let Err(error) =
                                follow(name.clone(), key, seen.clone(), wake.clone()).await
                            {
                                tracing::debug!(device = %name, "catalog stream ended: {error:#}");
                            }
                            seen.lock()
                                .unwrap_or_else(|p| p.into_inner())
                                .catalogs
                                .remove(&name);
                            wake.notify_one();
                        }),
                    );
                }
                wake.notify_one();
            }
        }
        let update = overview(&mut seen.lock().unwrap_or_else(|p| p.into_inner()));
        if !deliver(update) {
            break Ok(());
        }
        tokio::select! {
            _ = wake.notified() => {},
            _ = local.changed() => {},
            _ = tokio::time::sleep(Duration::from_secs(20)) => {},
        }
        // Several changes in a burst become one update.
        tokio::time::sleep(Duration::from_millis(200)).await;
    };
    for task in followers.into_values() {
        task.abort();
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_parse_only_catalog_events() {
        let catalog = serde_json::json!({
            "catalog": {"protocol": 1, "device": "studio", "revision": 3,
                        "tools": {"enabled": true, "askBeforeSharing": true},
                        "shares": [], "consents": []},
            "added": ["s1"],
        });
        let frame = format!("event: catalog\ndata: {catalog}\n\n");
        let event = parse(frame.as_bytes()).expect("event");
        assert_eq!(
            (event.catalog.device.as_str(), event.added.as_slice()),
            ("studio", &["s1".to_string()][..])
        );
        assert!(parse(b": keep-alive\n\n").is_none());
        assert_eq!(find_blank_line(b"event: x\ndata: y\n\nrest"), Some(18));
    }

    #[test]
    fn a_share_made_while_a_stream_was_down_is_still_announced() {
        let event = |ids: &[&str]| -> CatalogEvent {
            let shares: Vec<serde_json::Value> = ids
                .iter()
                .map(|id| {
                    serde_json::json!({"id": id, "title": "Page", "path": "/", "ports": [],
                        "owner": {"kind": "agent", "label": "Codex"}, "createdMs": 1})
                })
                .collect();
            serde_json::from_value(serde_json::json!({
                "catalog": {"protocol": 1, "device": "studio", "revision": 1,
                            "tools": {"enabled": true, "askBeforeSharing": true},
                            "shares": shares, "consents": []},
                "added": [],
            }))
            .expect("event")
        };
        let seen = Mutex::new(Seen::default());
        record("studio", event(&["s1"]), &seen);
        assert!(seen.lock().unwrap().added.is_empty(), "what exists at first is not news");
        // The stream dropped; its replacement's first event names nothing new.
        record("studio", event(&["s1", "s2"]), &seen);
        assert_eq!(seen.lock().unwrap().added, [("studio".to_string(), "s2".to_string())]);
    }

    #[test]
    fn a_device_that_left_the_relay_stays_listed_offline() {
        let mut seen = Seen::default();
        seen.known.insert("devbox".into(), Some("linux".into()));
        let update = overview(&mut seen);
        let devbox = update
            .overview
            .devices
            .iter()
            .find(|d| d.name == "devbox")
            .expect("kept");
        assert!(!devbox.online && devbox.services.is_empty());
        assert_eq!(devbox.platform.as_deref(), Some("linux"));
    }
}
