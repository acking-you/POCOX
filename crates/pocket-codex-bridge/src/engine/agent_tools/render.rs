//! Plain-text answers for models and terminals, and the `services` filter.
//!
//! Titles and labels another device wrote are quoted as data.

use std::{collections::HashSet, fmt::Write as _};

use pocket_codex_core::service::sanitize_component;

use super::{
    model::{ConnectionView, Overview, Shared},
    state,
};

/// What `services` narrows to.
#[derive(Debug, Default, Clone)]
pub struct Filter {
    /// One device.
    pub device: Option<String>,
    /// `agent`, `api`, `port` or `all`.
    pub kind: Option<String>,
    /// `online`, `offline` or `all`.
    pub status: Option<String>,
    /// Only what this owner (token and conversation) shared or connected.
    pub mine: Option<state::OwnerKey>,
}

/// `overview` narrowed by `filter`. Management entries are never listed.
pub fn filter(mut overview: Overview, filter: &Filter) -> Overview {
    if let Some(device) = &filter.device {
        let device = sanitize_component(device);
        overview.devices.retain(|d| d.name == device);
    }
    let kind = filter.kind.as_deref().filter(|k| *k != "all");
    let status = filter.status.as_deref().filter(|s| *s != "all");
    for device in &mut overview.devices {
        device.services.retain(|service| {
            service.kind != "host"
                && kind.is_none_or(|k| service.kind == k)
                && status.is_none_or(|s| (service.status == "online") == (s == "online"))
        });
    }
    if let Some(owner) = &filter.mine {
        let state = state::lock();
        let owned = |key: Option<&state::OwnerKey>| key == Some(owner);
        let shares: HashSet<String> = state
            .shares
            .iter()
            .filter(|s| owned(s.key.as_ref()))
            .map(|s| s.id.clone())
            .collect();
        let connections: HashSet<String> = state
            .connections
            .iter()
            .filter(|c| c.held_by(owner))
            .map(|c| c.service.clone())
            .collect();
        drop(state);
        for device in &mut overview.devices {
            device
                .services
                .retain(|s| s.share.as_ref().is_some_and(|id| shares.contains(id)));
            device.shares.retain(|s| shares.contains(&s.id));
            device.consents.clear();
        }
        overview.devices.retain(|d| !d.services.is_empty());
        overview
            .connections
            .retain(|c| connections.contains(&c.service));
    }
    overview
}

/// What an agent sees: no requests waiting for the user (answering them is
/// the user's) and no conversation ids, which only the user's devices need.
pub fn for_agent(mut overview: Overview) -> Overview {
    for device in &mut overview.devices {
        device.consents.clear();
        for share in &mut device.shares {
            share.owner.conversation = None;
        }
    }
    for connection in &mut overview.connections {
        connection.owner.conversation = None;
    }
    overview
}

/// A compact listing.
pub fn table(overview: &Overview) -> String {
    let mut out = format!("This device: {}\n", overview.this_device);
    if overview.devices.is_empty() {
        out.push_str("No devices match.\n");
    }
    for device in &overview.devices {
        let platform = device.platform.as_deref().unwrap_or("unknown platform");
        let _ = write!(out, "\n{} ({platform}", device.name);
        if device.name == overview.this_device {
            out.push_str(", this device");
        }
        if !device.online {
            out.push_str(", offline");
        }
        if !device.catalog {
            out.push_str(", older POCOX: no titles or owners");
        }
        if device.tools.is_some_and(|tools| !tools.enabled) {
            out.push_str(", agent tools off");
        }
        out.push_str(")\n");
        if device.services.is_empty() {
            out.push_str("  no services\n");
        }
        for service in &device.services {
            let name = match (service.kind.as_str(), &service.agent) {
                ("agent", Some(agent)) => format!("agent {agent} \"{}\"", service.name),
                ("port", _) => format!("port {}", service.name),
                (kind, _) => format!("{kind} \"{}\"", service.name),
            };
            let _ = write!(out, "  - {name}");
            if let Some(title) = &service.title {
                let _ = write!(out, " \"{title}\"");
            }
            let _ = write!(out, " — {}", service.status);
            if let Some(owner) = &service.owner {
                let _ = write!(out, ", shared by {owner}");
            }
            let _ = writeln!(out, "  [{}]", service.key);
        }
        for consent in &device.consents {
            let _ = writeln!(
                out,
                "  waiting for the user: {} asks to share \"{}\" ({:?})",
                consent.owner.label, consent.title, consent.ports
            );
        }
    }
    if !overview.connections.is_empty() {
        out.push_str("\nConnected on this device:\n");
        for connection in &overview.connections {
            let _ = writeln!(out, "  - {} → {}", connection.service, connection.local);
        }
    }
    out
}

/// What a share tells the model.
pub fn shared(shared: &Shared) -> String {
    let ports: Vec<String> = shared
        .share
        .ports
        .iter()
        .map(|p| p.port.to_string())
        .collect();
    format!(
        "Shared \"{}\" (port {}). The user can open it in POCOX on any of their devices, where it \
         appears under Shared with you: {}\nOn this machine: {}\nIt ends {}.",
        shared.share.title,
        ports.join(", "),
        shared.open,
        shared.on_this_machine,
        shared.ends
    )
}

/// What a connection tells the model.
pub fn connected(view: &ConnectionView) -> String {
    let port = view.local.rsplit(':').next().unwrap_or_default();
    let mut out =
        format!("Connected {} at {} (http://localhost:{port}/).", view.service, view.local);
    if !view.same_port {
        out.push_str(
            " Its own port number was busy here, so absolute localhost URLs that name that port \
             will not reach it.",
        );
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::agent_tools::model::{DeviceView, ServiceEntry};

    fn entry(key: &str, kind: &str, status: &str) -> ServiceEntry {
        ServiceEntry {
            key: key.into(),
            kind: kind.into(),
            name: key.rsplit(':').next().unwrap_or_default().into(),
            agent: None,
            title: None,
            port: None,
            status: status.into(),
            owner: None,
            share: None,
        }
    }

    #[test]
    fn filters_narrow_by_device_kind_and_state_and_hide_management() {
        let overview = Overview {
            this_device: "studio".into(),
            devices: vec![DeviceView {
                name: "studio".into(),
                platform: Some("macos".into()),
                online: true,
                catalog: true,
                tools: None,
                services: vec![
                    entry("pcx:studio:host:pocket", "host", "online"),
                    entry("pcx:studio:app:default", "agent", "online"),
                    entry("pcx:studio:port:5173", "port", "unreachable"),
                ],
                shares: vec![],
                consents: vec![],
                builtin: vec![],
            }],
            connections: vec![],
        };
        let all = filter(overview.clone(), &Filter::default());
        assert_eq!(all.devices[0].services.len(), 2);
        let offline_ports = filter(overview.clone(), &Filter {
            kind: Some("port".into()),
            status: Some("offline".into()),
            ..Filter::default()
        });
        assert_eq!(offline_ports.devices[0].services[0].key, "pcx:studio:port:5173");
        let elsewhere = filter(overview, &Filter {
            device: Some("devbox".into()),
            ..Filter::default()
        });
        assert!(elsewhere.devices.is_empty());
    }
}
