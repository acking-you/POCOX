//! `pocox services …` subcommand handlers, and `pocox open`.

use anyhow::{anyhow, bail, Result};
use comfy_table::Cell;
use pocket_codex_bridge::agent_tools::model::{ConnectionView, Overview, ShareView, Shared};
use pocket_codex_core::{config::Config, service::ServiceKind};
use serde::Serialize;

use crate::{
    cli::{
        OpenArgs, ServicesCmd, ServicesConnectArgs, ServicesDefaultCmd, ServicesDefaultSetArgs,
        ServicesListArgs, ServicesShareArgs, ServicesTargetArgs,
    },
    commands::{local_tools, service_target::discover_services, transport, ui},
};

/// Dispatch the `services` subcommand group.
pub async fn run(cmd: ServicesCmd) -> Result<()> {
    match cmd {
        ServicesCmd::List(args) => list(args).await,
        ServicesCmd::Default(ServicesDefaultCmd::Set(args)) => default_set(args),
        ServicesCmd::Share(args) => share(args).await,
        ServicesCmd::Unshare(args) => unshare(args).await,
        ServicesCmd::Connect(args) => connect(args).await,
        ServicesCmd::Disconnect(args) => disconnect(args).await,
    }
}

#[derive(Serialize)]
struct Listed {
    key: String,
    device: String,
    kind: String,
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    owner: Option<String>,
}

/// List the services this device can reach — the relay's own listing in both
/// modes, since an account credential already sees only its own namespace.
async fn list(args: ServicesListArgs) -> Result<()> {
    let wanted = args.kind.map(ServiceKind::from);
    let config = Config::load()?;
    let transport =
        transport::resolve_transport(args.relay.relay.as_deref(), None, &config).await?;

    let mut services = Vec::new();
    for kind in wanted.map(|k| vec![k]).unwrap_or_else(all_kinds) {
        services.extend(discover_services(&transport, kind).await?);
    }
    services.sort_by_key(|id| id.key());

    if args.json {
        // Titles, status and owners come from the POCOX running here, when
        // there is one; the relay's listing stands on its own otherwise.
        let overview: Option<Overview> = match local_tools::running().await? {
            Some(local) => local.get("overview").await.ok(),
            None => None,
        };
        let described = |key: &str| {
            overview.as_ref().and_then(|o| {
                o.devices
                    .iter()
                    .flat_map(|d| d.services.iter())
                    .find(|s| s.key == key)
            })
        };
        let rows: Vec<Listed> = services
            .iter()
            .map(|service| {
                let key = service.key();
                let entry = described(&key);
                Listed {
                    key: transport.key(service),
                    device: service.device.clone(),
                    kind: service.kind.as_key_segment().into(),
                    name: service.name.clone(),
                    title: entry.and_then(|e| e.title.clone()),
                    status: entry.map(|e| e.status.clone()),
                    owner: entry.and_then(|e| e.owner.clone()),
                }
            })
            .collect();
        println!("{}", serde_json::to_string_pretty(&rows)?);
        return Ok(());
    }

    if services.is_empty() {
        ui::muted(match transport.is_account() {
            true => "no services in your account",
            false => "no POCOX services found",
        });
        return Ok(());
    }

    let mut table = ui::new_table(&["KEY", "DEVICE", "KIND", "NAME"]);
    for service in services {
        table.add_row(vec![
            Cell::new(transport.key(&service)),
            Cell::new(&service.device),
            ui::kind_cell(service.kind.as_key_segment(), service.kind),
            Cell::new(&service.name),
        ]);
    }
    println!("{table}");
    Ok(())
}

/// Every kind a listing shows when `--kind` is absent.
///
/// `Meta` is deliberately excluded: it is colocated with an app service as an
/// implementation detail, and listing it invites a user to connect to something
/// that is not a codex endpoint.
fn all_kinds() -> Vec<ServiceKind> {
    vec![ServiceKind::App, ServiceKind::Api, ServiceKind::Port]
}

fn default_set(args: ServicesDefaultSetArgs) -> Result<()> {
    let kind = ServiceKind::from(args.kind);
    if kind == ServiceKind::Port {
        bail!("shared ports have no default target; connect to one with `pocox services connect`");
    }
    let mut config = Config::load()?;
    config.set_default_service(kind, &args.device, &args.name);
    config.save()?;
    let target = config
        .default_service(kind)
        .ok_or_else(|| anyhow!("default target missing after setting {kind} service"))?;
    ui::headline(ui::Tone::Ok, &format!("default {kind} service"));
    ui::field("target", &format!("pcx:{}:{}:{}", target.device, kind, target.name));
    Ok(())
}

async fn share(args: ServicesShareArgs) -> Result<()> {
    let local = local_tools::require().await?;
    let shared: Shared = local
        .post(
            "share",
            &serde_json::json!({
                "ports": args.ports, "title": args.title, "path": args.path,
                "waitReadySeconds": 10,
            }),
        )
        .await?;
    if args.json {
        println!("{}", serde_json::to_string_pretty(&shared)?);
        return Ok(());
    }
    ui::headline(ui::Tone::Ok, &format!("shared {}", shared.share.title));
    ui::field("id", &shared.share.id);
    for port in &shared.share.ports {
        ui::field(&format!("port {}", port.port), &port.key);
    }
    ui::field("here", &shared.on_this_machine);
    ui::field("link", &shared.open);
    ui::muted("open it from POCOX on your other devices, or with `pocox open <link>`");
    Ok(())
}

async fn unshare(args: ServicesTargetArgs) -> Result<()> {
    let local = local_tools::require().await?;
    let share: ShareView = local
        .post("stop", &serde_json::json!({ "target": args.target }))
        .await?;
    ui::headline(ui::Tone::Ok, &format!("stopped sharing {}", share.title));
    Ok(())
}

async fn connect_to(service: &str, port: Option<u16>) -> Result<ConnectionView> {
    let local = local_tools::require().await?;
    local
        .post("connect", &serde_json::json!({ "service": service, "localPort": port }))
        .await
}

async fn connect(args: ServicesConnectArgs) -> Result<()> {
    let view = connect_to(&args.service, args.port).await?;
    if args.json {
        println!("{}", serde_json::to_string_pretty(&view)?);
        return Ok(());
    }
    ui::headline(ui::Tone::Ok, &format!("connected {}", view.service));
    ui::field("local", &view.local);
    if !view.same_port {
        ui::warn(
            "its own port was busy here; absolute localhost URLs to that port will not reach it",
        );
    }
    Ok(())
}

async fn disconnect(args: ServicesTargetArgs) -> Result<()> {
    let local = local_tools::require().await?;
    let view: ConnectionView = local
        .post("disconnect", &serde_json::json!({ "target": args.target }))
        .await?;
    ui::headline(ui::Tone::Ok, &format!("disconnected {}", view.service));
    Ok(())
}

/// What a `pocox://open` link names (or `target` itself, as a service).
#[derive(Debug, PartialEq, Eq)]
struct Link {
    service: String,
    path: Option<String>,
    /// The page is served over TLS (`scheme=https`).
    secure: bool,
}

fn parse_link(target: &str) -> Link {
    let Some(query) = target.strip_prefix("pocox://open?") else {
        return Link {
            service: target.to_string(),
            path: None,
            secure: false,
        };
    };
    let mut link = Link {
        service: String::new(),
        path: None,
        secure: false,
    };
    for pair in query.split('&') {
        let (name, value) = pair.split_once('=').unwrap_or((pair, ""));
        let value = url::form_urlencoded::parse(format!("v={value}").as_bytes())
            .next()
            .map(|(_, v)| v.into_owned())
            .unwrap_or_default();
        match name {
            "service" => link.service = value,
            "path" => link.path = Some(value),
            "scheme" => link.secure = value == "https",
            _ => {},
        }
    }
    link
}

/// The share that holds `service`, as the running POCOX sees it (none when
/// it cannot say).
async fn share_of(service: &str) -> Option<ShareView> {
    let local = local_tools::require().await.ok()?;
    let overview = local.get::<Overview>("overview").await.ok()?;
    overview
        .devices
        .into_iter()
        .flat_map(|device| device.shares)
        .find(|share| share.ports.iter().any(|port| port.key == service))
}

/// `pocox open`: connect a shared service here and open it.
pub async fn open(args: OpenArgs) -> Result<()> {
    let link = parse_link(args.target.trim());
    if link.service.is_empty() {
        bail!("the link names no service");
    }
    let view = connect_to(&link.service, None).await?;
    let share = share_of(&view.service).await;
    // The page's other ports (its API) come along before it opens: its first
    // request may already need them.
    for other in share.iter().flat_map(|share| &share.ports) {
        if other.key == view.service {
            continue;
        }
        if let Err(error) = connect_to(&other.key, None).await {
            ui::warn(&format!("{} could not be connected here: {error:#}", other.key));
        }
    }
    // A bare service names no path or scheme: the page's own share does.
    let page = share
        .as_ref()
        .filter(|share| share.first_key() == Some(view.service.as_str()));
    let path = args
        .path
        .or(link.path)
        .or_else(|| page.map(|share| share.path.clone()))
        .unwrap_or_else(|| "/".into());
    let port = view.local.rsplit(':').next().unwrap_or_default();
    let path = if path.starts_with('/') { path } else { format!("/{path}") };
    let secure = link.secure || page.is_some_and(|share| share.secure);
    let scheme = if secure { "https" } else { "http" };
    let url = format!("{scheme}://localhost:{port}{path}");
    if args.no_browser {
        println!("{url}");
        return Ok(());
    }
    ui::field("opening", &url);
    if open::that_detached(&url).is_err() {
        ui::warn("no browser could be opened; visit the address above");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn links_name_their_service_and_path() {
        assert_eq!(parse_link("pocox://open?service=pcx:studio:port:5173&path=/a%20b"), Link {
            service: "pcx:studio:port:5173".into(),
            path: Some("/a b".into()),
            secure: false,
        });
        assert!(parse_link("pocox://open?service=pcx:studio:port:8443&scheme=https").secure);
        assert_eq!(parse_link("studio/5173").service, "studio/5173");
    }
}
