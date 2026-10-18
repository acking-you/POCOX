//! This device's catalog, other devices' catalogs, and the overview of
//! every device and service the caller can see.

use std::{collections::BTreeMap, time::Duration};

use anyhow::{bail, Context, Result};
use futures::{stream, StreamExt};
use once_cell::sync::OnceCell;
use pocket_codex_core::service::{ServiceId, ServiceKind};

use super::{
    consent,
    model::{
        bounded, Catalog, DeviceView, HostedView, Overview, ServiceEntry, ShareView, ToolsState,
        PROTOCOL,
    },
    state::{self, Share},
};
use crate::engine::{discovery, meta, runtime, serve, transport};

/// The agent hosts and APIs this process serves, read again.
pub fn refresh_services() {
    let services: Vec<HostedView> = serve::serve_status()
        .into_iter()
        .flat_map(|status| {
            let agent = match status.protocol.as_str() {
                "acp" => status
                    .profile_id
                    .clone()
                    .unwrap_or_else(|| bounded(&status.provider_name).to_lowercase()),
                "opencode-http" => "opencode".into(),
                _ => "codex".into(),
            };
            let online =
                |registered: bool| if status.alive && registered { "online" } else { "starting" };
            let mut rows = vec![HostedView {
                key: status.app_service_key.clone(),
                kind: "agent".into(),
                name: status.name.clone(),
                agent: Some(agent),
                status: online(status.app_registered).into(),
            }];
            if status.protocol == "codex-app-server" && !status.api_service_key.is_empty() {
                rows.push(HostedView {
                    key: status.api_service_key.clone(),
                    kind: "api".into(),
                    name: status.name.clone(),
                    agent: None,
                    status: online(status.api_registered).into(),
                });
            }
            rows
        })
        .collect();
    let mut state = state::lock();
    if state.services != services {
        state.services = services;
        state::changed(&mut state);
    }
}

/// This device's catalog.
pub fn local() -> Result<Catalog> {
    let device = runtime::device_id()?;
    let state = state::lock();
    Ok(Catalog {
        protocol: PROTOCOL,
        device,
        platform: std::env::consts::OS.into(),
        revision: state.revision,
        tools: ToolsState {
            enabled: state.settings.enabled,
            ask_before_sharing: state.settings.ask_before_sharing,
        },
        shares: state.shares.iter().map(Share::view).collect(),
        consents: consent::pending(&state),
        services: state.services.clone(),
        builtin: super::builtin::catalog(),
    })
}

fn client() -> &'static reqwest::Client {
    static CLIENT: OnceCell<reqwest::Client> = OnceCell::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(8))
            .build()
            .unwrap_or_else(|_| reqwest::Client::new())
    })
}

/// Largest catalog accepted from another device.
const LIMIT: usize = 512 * 1024;

/// Another device's catalog through its management entry; `None` when it
/// runs a POCOX without one. Call off the async workers (it may open a
/// tunnel).
pub fn fetch(host_key: &str) -> Result<Option<Catalog>> {
    let url = meta::endpoint(host_key, &["services", "v1"])?;
    runtime::runtime().block_on(async move {
        let mut response = client()
            .get(url)
            .send()
            .await
            .context("reading the device's services")?;
        match response.status().as_u16() {
            200 => {},
            404 | 405 => return Ok(None),
            status => bail!("the device answered {status}"),
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await? {
            if bytes.len() + chunk.len() > LIMIT {
                bail!("the device's catalog is too large");
            }
            bytes.extend_from_slice(&chunk);
        }
        let catalog: Catalog = serde_json::from_slice(&bytes).context("decoding the catalog")?;
        Ok((catalog.protocol == PROTOCOL).then(|| sanitize(catalog)))
    })
}

/// Bound everything another device wrote.
pub fn sanitize(mut catalog: Catalog) -> Catalog {
    catalog.device = bounded(&catalog.device);
    catalog.platform = bounded(&catalog.platform);
    catalog.shares.truncate(32);
    for share in &mut catalog.shares {
        share.title = bounded(&share.title);
        share.path = super::model::clean_path(Some(&share.path));
        share.owner.label = bounded(&share.owner.label);
        share.ports.truncate(8);
    }
    catalog.consents.truncate(16);
    for consent in &mut catalog.consents {
        consent.title = bounded(&consent.title);
        consent.owner.label = bounded(&consent.owner.label);
        consent.ports.truncate(8);
        consent.service = consent.service.as_deref().map(bounded);
    }
    catalog.services.truncate(64);
    for service in &mut catalog.services {
        service.name = bounded(&service.name);
        service.agent = service.agent.as_deref().map(bounded);
    }
    catalog.builtin.truncate(32);
    for tool in &mut catalog.builtin {
        tool.id = bounded(&tool.id);
        tool.title = bounded(&tool.title);
        tool.summary = bounded(&tool.summary);
    }
    catalog
}

fn kind_of(kind: ServiceKind) -> Option<&'static str> {
    match kind {
        ServiceKind::App | ServiceKind::Acp | ServiceKind::OpenCode => Some("agent"),
        ServiceKind::Api => Some("api"),
        ServiceKind::Port => Some("port"),
        ServiceKind::Host => Some("host"),
        ServiceKind::Meta | ServiceKind::Unknown => None,
    }
}

fn default_agent(kind: ServiceKind) -> Option<String> {
    match kind {
        ServiceKind::App => Some("codex".into()),
        ServiceKind::OpenCode => Some("opencode".into()),
        ServiceKind::Acp => Some("acp".into()),
        _ => None,
    }
}

/// One device's services: what the relay lists, described by its catalog.
fn device_view(name: &str, listed: &[ServiceId], catalog: Option<&Catalog>) -> DeviceView {
    let port_share = |key: &str| -> Option<(&ShareView, &super::model::PortView)> {
        catalog?.shares.iter().find_map(|share| {
            share
                .ports
                .iter()
                .find(|port| port.key == key)
                .map(|port| (share, port))
        })
    };
    let mut services: Vec<ServiceEntry> = listed
        .iter()
        .filter_map(|id| {
            let kind = kind_of(id.kind)?;
            let key = id.key();
            let hosted = catalog.and_then(|c| c.services.iter().find(|s| s.key == key));
            let share = port_share(&key);
            Some(ServiceEntry {
                key,
                kind: kind.into(),
                name: id.name.clone(),
                agent: hosted
                    .and_then(|h| h.agent.clone())
                    .or_else(|| default_agent(id.kind)),
                title: share.map(|(share, _)| share.title.clone()),
                port: share.map(|(_, port)| port.port).or_else(|| {
                    (id.kind == ServiceKind::Port)
                        .then(|| id.name.parse().ok())
                        .flatten()
                }),
                status: share
                    .and_then(|(_, port)| serde_json::to_value(port.status).ok())
                    .and_then(|v| v.as_str().map(str::to_string))
                    .or_else(|| hosted.map(|h| h.status.clone()))
                    .unwrap_or_else(|| "online".into()),
                owner: share.map(|(share, _)| share.owner.label.clone()),
                share: share.map(|(share, _)| share.id.clone()),
            })
        })
        .collect();
    // Shares still waiting for the relay are not listed there yet.
    if let Some(catalog) = catalog {
        for share in &catalog.shares {
            for port in &share.ports {
                if services.iter().all(|s| s.key != port.key) {
                    services.push(ServiceEntry {
                        key: port.key.clone(),
                        kind: "port".into(),
                        name: port.port.to_string(),
                        agent: None,
                        title: Some(share.title.clone()),
                        port: Some(port.port),
                        status: "starting".into(),
                        owner: Some(share.owner.label.clone()),
                        share: Some(share.id.clone()),
                    });
                }
            }
        }
    }
    services.sort_by(|a, b| {
        (a.kind.as_str(), a.name.as_str()).cmp(&(b.kind.as_str(), b.name.as_str()))
    });
    DeviceView {
        name: name.to_string(),
        platform: catalog
            .map(|c| c.platform.clone())
            .filter(|p| !p.is_empty()),
        online: !listed.is_empty(),
        catalog: catalog.is_some(),
        tools: catalog.map(|c| c.tools),
        services,
        shares: catalog.map(|c| c.shares.clone()).unwrap_or_default(),
        consents: catalog.map(|c| c.consents.clone()).unwrap_or_default(),
        builtin: catalog.map(|c| c.builtin.clone()).unwrap_or_default(),
    }
}

/// The overview of `listed` services, described by the `catalogs` that
/// answered (this device's own among them while it serves the tools).
pub fn assemble(
    this_device: String,
    listed: &[ServiceId],
    catalogs: &BTreeMap<String, Catalog>,
) -> Overview {
    let mut by_device: BTreeMap<String, Vec<ServiceId>> = BTreeMap::new();
    for id in listed {
        by_device
            .entry(id.device.clone())
            .or_default()
            .push(id.clone());
    }
    for device in catalogs.keys() {
        by_device.entry(device.clone()).or_default();
    }
    // This device is always there, even when it only connects (a phone):
    // the galaxy's home star and its connections hang on it.
    if !this_device.is_empty() {
        by_device.entry(this_device.clone()).or_default();
    }
    let mut devices: Vec<DeviceView> = by_device
        .iter()
        .map(|(device, ids)| {
            let mut view = device_view(device, ids, catalogs.get(device));
            if *device == this_device {
                // It answers for itself.
                view.online = true;
                view.platform
                    .get_or_insert_with(|| std::env::consts::OS.into());
            }
            view
        })
        .collect();
    devices.sort_by_key(|d| (d.name != this_device, d.name.clone()));
    Overview {
        this_device,
        devices,
        connections: super::connections::list(),
    }
}

/// Every device and service the caller can see. Call off the async workers.
pub fn overview_blocking() -> Result<Overview> {
    let owned = transport::resolve_owned_blocking()?;
    let listed = runtime::runtime().block_on(async {
        tokio::time::timeout(Duration::from_secs(10), discovery::discover(&owned.transport))
            .await
            .context("listing services timed out")?
    })?;
    if !transport::is_current(owned.epoch) {
        bail!("the account or relay changed; try again");
    }
    let this_device = runtime::device_id().unwrap_or_default();
    let mut catalogs = BTreeMap::new();
    if state::lock().hosting {
        if let Ok(local) = local() {
            catalogs.insert(this_device.clone(), local);
        }
    }
    let remote: Vec<(String, String)> = listed
        .iter()
        .filter(|id| id.kind == ServiceKind::Host && !catalogs.contains_key(&id.device))
        .map(|id| (id.device.clone(), id.key()))
        .collect();
    let fetched: Vec<(String, Catalog)> = runtime::runtime().block_on(async {
        stream::iter(remote)
            .map(|(device, key)| async move {
                let fetched = tokio::task::spawn_blocking(move || fetch(&key)).await;
                (device, fetched.ok().and_then(Result::ok).flatten())
            })
            .buffer_unordered(6)
            .filter_map(|(device, catalog)| async move { catalog.map(|c| (device, c)) })
            .collect()
            .await
    });
    catalogs.extend(fetched);
    Ok(assemble(this_device, &listed, &catalogs))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::agent_tools::model::{OwnerKind, OwnerView, PortStatus, PortView};

    #[test]
    fn a_catalog_describes_listed_services_and_shares_still_publishing() {
        let listed = [
            ServiceId::new("studio", ServiceKind::App, "default"),
            ServiceId::new("studio", ServiceKind::Meta, "default"),
            ServiceId::new("studio", ServiceKind::Port, "5173"),
        ];
        let share = ShareView {
            id: "s1".into(),
            title: "Landing".into(),
            path: "/".into(),
            secure: false,
            ports: vec![
                PortView {
                    port: 5173,
                    key: "pcx:studio:port:5173".into(),
                    status: PortStatus::Online,
                },
                PortView {
                    port: 8000,
                    key: "pcx:studio:port:8000".into(),
                    status: PortStatus::Starting,
                },
            ],
            owner: OwnerView {
                kind: OwnerKind::Agent,
                label: "Codex · default".into(),
                harness: Some("codex".into()),
                host: Some("default".into()),
                conversation: None,
            },
            created_ms: 1,
            expires_ms: Some(2),
        };
        let catalog = Catalog {
            protocol: PROTOCOL,
            device: "studio".into(),
            platform: "macos".into(),
            revision: 1,
            tools: ToolsState {
                enabled: true,
                ask_before_sharing: true,
            },
            shares: vec![share],
            consents: vec![],
            services: vec![],
            builtin: vec![],
        };
        let view = device_view("studio", &listed, Some(&catalog));
        let keys: Vec<_> = view
            .services
            .iter()
            .map(|s| (s.key.as_str(), s.status.as_str()))
            .collect();
        assert_eq!(keys, [
            ("pcx:studio:app:default", "online"),
            ("pcx:studio:port:5173", "online"),
            ("pcx:studio:port:8000", "starting"),
        ]);
        assert_eq!(view.services[1].title.as_deref(), Some("Landing"));
        assert_eq!(view.services[0].agent.as_deref(), Some("codex"));
        let bare =
            device_view("devbox", &[ServiceId::new("devbox", ServiceKind::Port, "3000")], None);
        assert_eq!((bare.catalog, bare.services[0].port), (false, Some(3000)));
        // A phone lists nothing of its own, yet is its overview's home.
        let phone = assemble("phone".into(), &listed, &BTreeMap::new());
        assert_eq!((phone.devices[0].name.as_str(), phone.devices[0].online), ("phone", true));
    }
}
