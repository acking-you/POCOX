//! Plain-text answers for models and terminals, and the `services` filter.
//!
//! Titles and labels another device wrote are quoted as data.

use std::collections::HashSet;
use std::fmt::Write as _;

use pocox_core::service::sanitize_component;

use super::model::{in_words, ConnectionView, LinkView, Overview, ShareView, Shared};
use super::state;

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
            if let Some(share) = device
                .shares
                .iter()
                .find(|share| Some(&share.id) == service.share.as_ref())
            {
                let _ = write!(out, "; {}", persistence_label(share));
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
            let _ = write!(
                out,
                "  - {} → {} ({}",
                connection.service,
                connection.local,
                lasts(connection)
            );
            if let Some(link) = &connection.link {
                let _ = write!(out, "; {}", path_in_words(link));
            }
            out.push_str(")\n");
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
    let lifecycle = match shared.share.persistence() {
        Some(true) => "Saved across agent and POCOX restarts. The user manages it in POCOX.",
        _ => {
            "Not saved across restarts. For long-term use, call connect with action=keep_sharing \
             and this service; POCOX asks for permission to save it."
        },
    };
    format!(
        "Shared \"{}\" (port {}). The user can open it in POCOX on any of their devices, where it \
         appears under Shared with you: {}\nOn this machine: {}\nIt ends {}.\n{} POCOX and the \
         server must be running on this device; sharing does not start the server or configure \
         its autostart.",
        shared.share.title,
        ports.join(", "),
        shared.open,
        shared.on_this_machine,
        shared.ends,
        lifecycle
    )
}

fn persistence_label(share: &ShareView) -> String {
    match share.persistence() {
        Some(true) => "saved across restarts".into(),
        Some(false) => match share.expires_ms {
            Some(at) => {
                format!("temporary, ends with its agent or {}", in_words(at - state::now_ms()))
            },
            None => "temporary, no timer, ends with its agent or POCOX".into(),
        },
        None => "persistence unknown (older host)".into(),
    }
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
    match view.expires_ms {
        Some(at) => {
            let _ = write!(
                out,
                " It ends {}; connect again to renew it.",
                in_words(at - state::now_ms())
            );
        },
        None => out.push_str(
            " It has no expiry: it stays until disconnected, reconnecting on its own after \
             network or relay outages.",
        ),
    }
    if let Some(link) = &view.link {
        let _ = write!(out, " {}.", travels(link));
    }
    if view.owner.kind == super::model::OwnerKind::Agent {
        out.push_str(" It also ends when its agent or POCOX stops; no expiry does not mean saved.");
    }
    out
}

/// How long a connection lasts, briefly.
fn lasts(connection: &ConnectionView) -> String {
    match connection.expires_ms {
        Some(at) => format!("ends {}", in_words(at - state::now_ms())),
        None => "no expiry".into(),
    }
}

/// What a connection's traffic goes through, briefly.
fn path_in_words(link: &LinkView) -> &'static str {
    match (link.state.as_str(), link.path.as_str()) {
        ("restoring", _) => "reopening its tunnel",
        ("connecting", _) => "tunnel coming up",
        ("reconnecting", _) => "relay link reconnecting",
        (_, "direct") => "direct P2P",
        (_, "relay") => "via the relay",
        (_, "mixed") => "partly direct P2P, partly via the relay",
        _ if link.policy == "relay_only" => "relay only",
        _ => "P2P first, idle",
    }
}

/// How a connection travels, in a sentence.
pub fn travels(link: &LinkView) -> String {
    let mut out = match link.path.as_str() {
        "direct" => "Its traffic goes direct (P2P, hole-punched)".to_string(),
        "relay" => "Its traffic goes through the relay".to_string(),
        "mixed" => "Its traffic goes partly direct (P2P), partly through the relay".to_string(),
        _ if link.policy == "relay_only" => {
            "Its traffic will go through the relay: direct P2P is off on this device".to_string()
        },
        _ => "Each new connection through it tries a direct P2P path first, falling back to the \
              relay"
            .to_string(),
    };
    match link.state.as_str() {
        "connecting" => out.push_str("; its tunnel is still coming up"),
        "reconnecting" => out.push_str("; its link to the relay is reconnecting"),
        "restoring" => out.push_str("; POCOX is reopening its tunnel, which ended"),
        _ => {},
    }
    if link.direct_sessions + link.relay_sessions > 0 {
        let _ = write!(
            out,
            " ({} direct, {} via the relay so far",
            link.direct_sessions, link.relay_sessions
        );
        if let Some(stage) = &link.last_fallback_stage {
            let _ = write!(out, "; the last fallback gave up while {stage}");
        }
        out.push(')');
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
                    entry("pcx:studio:host:pocox", "host", "online"),
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
