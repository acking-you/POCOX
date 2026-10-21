//! `pocox tools …`: the agent tools' switch on this computer's POCOX
//! installations.

use anyhow::Result;
use pocox_bridge::agent_tools::{harness, model::Overview, settings, Issued, Status};
use serde::Serialize;

use super::{
    local_tools::{self, Installation},
    ui,
};
use crate::cli::{OnOff, ToolsCmd, ToolsTargetArgs};

/// Dispatch the `tools` subcommand group.
pub async fn run(cmd: ToolsCmd) -> Result<()> {
    match cmd {
        ToolsCmd::Status(args) => status(args.json).await,
        ToolsCmd::Enable(target) => change(&target, |s| s.enabled = true, "agent tools on"),
        ToolsCmd::Disable(target) => change(&target, |s| s.enabled = false, "agent tools off"),
        ToolsCmd::Config(args) => config(args.harness.id()).await,
        ToolsCmd::Requests => requests().await,
        ToolsCmd::Allow(args) => {
            let decision = if args.always { "allow_conversation" } else { "allow_once" };
            answer(&args.id, decision).await
        },
        ToolsCmd::Deny(args) => answer(&args.id, "deny").await,
        ToolsCmd::Ask(args) => {
            let ask = args.value == OnOff::On;
            let label = if ask {
                "asking before agents share or connect an API"
            } else {
                "agents share and connect without asking"
            };
            change(&args.target, |s| s.ask_before_sharing = ask, label)
        },
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Row {
    installation: &'static str,
    enabled: bool,
    ask_before_sharing: bool,
    running: bool,
    endpoint: Option<String>,
    shared_ports: usize,
    connections: usize,
    problem: Option<String>,
}

async fn row(installation: &Installation) -> Row {
    let saved =
        settings::load_at(&installation.root).unwrap_or_else(|_| settings::Settings::closed());
    let live: Option<Status> = match local_tools::reach(installation).await {
        Some(local) => local.get::<Status>("status").await.ok(),
        None => None,
    };
    Row {
        installation: installation.label,
        enabled: live.as_ref().map_or(saved.enabled, |s| s.enabled),
        ask_before_sharing: live
            .as_ref()
            .map_or(saved.ask_before_sharing, |s| s.ask_before_sharing),
        running: live.is_some(),
        endpoint: live.as_ref().and_then(|s| s.endpoint.clone()),
        shared_ports: live.as_ref().map_or(0, |s| s.shared_ports),
        connections: live.as_ref().map_or(0, |s| s.connections),
        problem: live.and_then(|s| s.problem),
    }
}

async fn status(json: bool) -> Result<()> {
    let mut rows = Vec::new();
    for installation in local_tools::installations()? {
        rows.push(row(&installation).await);
    }
    if json {
        println!("{}", serde_json::to_string_pretty(&rows)?);
        return Ok(());
    }
    ui::headline(ui::Tone::Ok, "agent tools");
    for row in rows {
        let switch = if row.enabled { "on" } else { "off" };
        let detail = match (&row.endpoint, row.running) {
            (Some(endpoint), _) => format!(
                "{switch} · {endpoint} · {} shared, {} connected",
                row.shared_ports, row.connections
            ),
            (None, true) => format!("{switch} · running, not serving"),
            (None, false) => format!("{switch} · not running"),
        };
        ui::field(row.installation, &detail);
        if let Some(problem) = row.problem {
            ui::warn(&problem);
        }
    }
    Ok(())
}

async fn requests() -> Result<()> {
    let local = local_tools::require().await?;
    let overview: Overview = local.get("overview").await?;
    let mut any = false;
    for device in &overview.devices {
        for consent in &device.consents {
            any = true;
            let ports: Vec<String> = consent.ports.iter().map(u16::to_string).collect();
            match &consent.service {
                Some(service) => println!(
                    "{}  {} asks to connect {} on {}",
                    consent.id, consent.owner.label, service, device.name
                ),
                None => println!(
                    "{}  {} asks to share \"{}\" (port {}) on {}",
                    consent.id,
                    consent.owner.label,
                    consent.title,
                    ports.join(", "),
                    device.name
                ),
            }
        }
    }
    if !any {
        ui::muted("no requests are waiting");
    }
    Ok(())
}

async fn answer(id: &str, decision: &str) -> Result<()> {
    let local = local_tools::require().await?;
    let overview: Overview = local.get("overview").await?;
    let device = overview
        .devices
        .iter()
        .find(|d| d.consents.iter().any(|c| c.id == id))
        .map(|d| d.name.clone())
        .ok_or_else(|| anyhow::anyhow!("no waiting request `{id}`; see `pocox tools requests`"))?;
    let _: serde_json::Value = local
        .post("answer", &serde_json::json!({ "device": device, "id": id, "decision": decision }))
        .await?;
    ui::headline(ui::Tone::Ok, if decision == "deny" { "refused" } else { "allowed" });
    Ok(())
}

async fn config(harness: &str) -> Result<()> {
    let local = local_tools::require().await?;
    let issued: Issued = local
        .post("tokens", &serde_json::json!({ "harness": harness }))
        .await?;
    // The entry alone goes to stdout, so it can be piped into a file.
    print!("{}", harness::snippet(harness, &issued));
    eprintln!(
        "{} The token is shown once; revoke it in POCOX settings.",
        harness::destination(harness)
    );
    Ok(())
}

fn change(
    target: &ToolsTargetArgs,
    apply: impl Fn(&mut settings::Settings),
    done: &str,
) -> Result<()> {
    let chosen: Vec<Installation> = local_tools::installations()?
        .into_iter()
        .filter(|i| match (target.app, target.cli_host) {
            (true, _) => i.label == "app",
            (_, true) => i.label == "cli host",
            // Every installation that has hosted on this computer.
            _ => i.root.exists(),
        })
        .collect();
    if chosen.is_empty() {
        anyhow::bail!(
            "no POCOX installation has hosted on this computer yet; pass --app or --cli-host to \
             choose which one to set"
        );
    }
    for installation in chosen {
        settings::update_at(&installation.root, &apply)?;
        ui::field(installation.label, done);
    }
    ui::muted("a running POCOX applies this within a few seconds");
    Ok(())
}
