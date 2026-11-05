//! `pocox pair …` and `pocox devices …`: pairing-code login.
//!
//! A code comes from a prompt or stdin, never argv, where other accounts and
//! shell history could read it. Every change of membership shows what it does
//! and asks first; off a terminal `--yes` is that answer. The engine owns the
//! identity, so these commands and the app work on one device store.

use std::io::{BufRead as _, IsTerminal as _, Write as _};
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use pocox_account_proto::pairing::{
    display_code, normalize_code, CodeStatus, OperationStatus, PairingErrorCode, PreviewDevice,
    RestoreRequestStatus, PAIR_URI_PREFIX,
};
use pocox_bridge::pairing::identity::Identity;
use pocox_bridge::pairing::operations::{self, RestoreTarget};
use pocox_bridge::pairing::{code_of, flows, status, OperationOutcome, PairingState};
use pocox_core::config::Config;
use pocox_core::paths;
use pocox_core::redact::scrub_pairing;

use crate::cli::{DevicesCmd, PairArgs, PairCmd};
use crate::commands::{account, ui};

const LINK_POLL: Duration = Duration::from_secs(5);
const RESTORE_POLL: Duration = Duration::from_secs(5);
const OPERATION_POLL: Duration = Duration::from_secs(2);
/// How long a command waits on a pending change before leaving it to the next
/// run.
const OPERATION_WAIT: Duration = Duration::from_secs(60);
/// A device active within this many days counts as active today for a warning.
const SECONDS_PER_DAY: i64 = 86_400;

fn identity(backend: Option<&str>) -> Result<Identity> {
    let config = Config::load()?;
    let base = account::backend_base(backend, &config);
    Identity::open(&support()?, &base)
}

fn support() -> Result<PathBuf> {
    Ok(paths::config_dir()?)
}

/// Dispatch `pocox pair`.
pub(crate) async fn run(args: PairArgs) -> Result<()> {
    let result = dispatch(args).await;
    // Whatever an error quotes, it never reaches a terminal or a log with a code.
    result.map_err(|error| anyhow::anyhow!("{}", scrub_pairing(&format!("{error:#}"))))
}

async fn dispatch(args: PairArgs) -> Result<()> {
    let backend = args.backend.as_deref();
    match args.command {
        None => show(backend, args.yes, args.no_wait).await,
        Some(PairCmd::Join) => join(backend, args.yes).await,
        Some(PairCmd::Restore {
            ask,
            retake,
            device,
        }) => restore(backend, args.yes, ask, retake, device).await,
        Some(PairCmd::StartOver) => start_over(backend, args.yes).await,
        Some(PairCmd::Rotate) => {
            print_code(&flows::rotate(&identity(backend)?).await?);
            Ok(())
        },
        Some(PairCmd::Pause) => {
            let code = flows::set_paused(&identity(backend)?, true).await?;
            ui::headline(ui::Tone::Change, "linking through this code is paused");
            print_code(&code);
            ui::code("pocox pair resume");
            Ok(())
        },
        Some(PairCmd::Resume) => {
            let code = flows::set_paused(&identity(backend)?, false).await?;
            ui::headline(ui::Tone::Ok, "linking through this code is back on");
            print_code(&code);
            Ok(())
        },
        Some(PairCmd::Leave) => leave(backend, args.yes).await,
    }
}

/// `pocox devices` and its subcommands.
pub(crate) async fn devices(command: Option<DevicesCmd>, backend: Option<&str>) -> Result<()> {
    let result = match command {
        None => list(backend).await,
        Some(DevicesCmd::Remove {
            id,
            yes,
        }) => remove(backend, &id, yes).await,
        Some(DevicesCmd::Allow {
            id,
            request,
        }) => decide(backend, &id, &request, true).await,
        Some(DevicesCmd::Deny {
            id,
            request,
        }) => decide(backend, &id, &request, false).await,
    };
    result.map_err(|error| anyhow::anyhow!("{}", scrub_pairing(&format!("{error:#}"))))
}

fn print_code(code: &CodeStatus) {
    let compact = normalize_code(&code.code).unwrap_or_else(|| code.code.clone());
    ui::field("code", &display_code(&compact));
    ui::field("link", &format!("{PAIR_URI_PREFIX}{compact}"));
    if code.paused {
        ui::field("linking", "paused");
    }
}

/// `pocox pair`: show this device's code, ask before activating, wait for a
/// link.
async fn show(backend: Option<&str>, yes: bool, no_wait: bool) -> Result<()> {
    let identity = identity(backend)?;
    operations::settle(&identity).await?;
    let prepared = match flows::prepare(&identity, None).await {
        Ok(prepared) => prepared,
        Err(error) => return Err(explain_dead_identity(error)),
    };
    ui::headline(ui::Tone::Action, "this device's pairing code");
    print_code(&prepared.code);
    // A retained identity after a logout or a GitHub sign-in is as much the user's
    // choice to resume as a new one is to set up.
    if !prepared.session.activated || !identity.is_active_here()? {
        if prepared.session.activated {
            ui::muted("  this installation is not using this device's pairing identity");
        } else {
            ui::muted("  this device is not set up yet: it has no relay access until you continue");
        }
        if confirm("use this device's pairing identity now?", yes)? {
            let session = flows::activate(&identity, None).await?;
            ui::headline(ui::Tone::Ok, "this device is set up");
            ui::field("device", &session.login);
        }
    }
    if no_wait {
        return Ok(());
    }
    if !std::io::stdout().is_terminal() && !std::io::stdin().is_terminal() {
        // Nobody is watching: printing the code was the job.
        return Ok(());
    }
    wait_for_link(&identity).await
}

async fn wait_for_link(identity: &Identity) -> Result<()> {
    ui::muted("  enter this code on another device; Ctrl-C to stop waiting");
    let known = flows::devices(identity, None).await?.devices.len();
    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => return Ok(()),
            () = tokio::time::sleep(LINK_POLL) => {},
        }
        let current = flows::devices(identity, None).await?;
        if current.devices.len() > known {
            ui::headline(ui::Tone::Ok, "a device linked");
            for device in current.devices.iter().filter(|device| !device.is_self) {
                ui::field("device", &device.name);
            }
            return Ok(());
        }
    }
}

/// `pocox pair join`: read a code, show its group, confirm, move this device
/// there.
async fn join(backend: Option<&str>, yes: bool) -> Result<()> {
    let identity = identity(backend)?;
    let code = read_code()?;
    let preview = flows::preview(&identity, &code).await?;
    ui::headline(ui::Tone::Action, "this code's group");
    print_group(&preview.devices);
    let group = flows::devices(&identity, None).await?;
    let peers = group
        .devices
        .iter()
        .filter(|device| !device.is_self)
        .count();
    if preview.already_member {
        ui::muted("  this device is already in this group");
    }
    let leave_current = peers > 0 && !preview.already_member;
    if leave_current {
        ui::warn(&format!(
            "this device leaves its {peers} current peer(s), and every POCOX installation on it \
             moves too"
        ));
    }
    if !confirm("join this group?", yes)? {
        bail!("nothing changed");
    }
    let hint = flows::hardware_hint(&identity, None).await;
    let outcome = operations::link(&identity, &preview.ticket, leave_current, hint).await?;
    finish(&identity, outcome, "this device joined the group").await
}

/// `pocox pair restore`: recover a previous device with a code from its group,
/// or by asking a linked device.
async fn restore(
    backend: Option<&str>,
    yes: bool,
    ask: bool,
    retake: bool,
    device: Option<String>,
) -> Result<()> {
    let identity = identity(backend)?;
    flows::prepare(&identity, None)
        .await
        .map_err(explain_dead_identity)?;
    let (target, devices) = if ask {
        let approved = wait_for_approval(&identity).await?;
        let RestoreRequestStatus::Approved = approved.status else {
            bail!("nothing changed: the request ended without an approval");
        };
        (
            RestoreTarget::Approved {
                request_id: approved.request_id,
            },
            approved.devices,
        )
    } else {
        let code = read_code()?;
        let preview = flows::preview(&identity, &code).await?;
        ui::headline(ui::Tone::Action, "this code's group");
        print_group(&preview.devices);
        let device_id = match device {
            Some(device) => device,
            None => pick_device(&preview.devices)?,
        };
        let chosen = preview
            .devices
            .iter()
            .find(|candidate| candidate.id == device_id)
            .context("that device is not in this group")?;
        warn_if_active_today(chosen);
        (
            RestoreTarget::Ticket {
                ticket: preview.ticket.clone(),
                device_id,
            },
            preview.devices.clone(),
        )
    };
    print_group(&devices);
    if retake {
        ui::warn("old access ends at once and this device's code changes");
    }
    if !confirm("these are my devices: restore?", yes)? {
        bail!("nothing changed; this device carries on as new");
    }
    let hint = flows::hardware_hint(&identity, None).await;
    let outcome = operations::restore(&identity, &target, retake, hint).await?;
    finish(&identity, outcome, "this device was restored").await
}

async fn wait_for_approval(
    identity: &Identity,
) -> Result<pocox_account_proto::pairing::RestoreRequestView> {
    let mut view = match flows::request_restore(identity, None).await {
        Ok(view) => view,
        Err(error) if code_of(&error) == Some(PairingErrorCode::NotFound) => {
            bail!("no linked device was found to ask; use a code from the group instead");
        },
        Err(error) => return Err(error),
    };
    ui::headline(ui::Tone::Action, "asked your linked devices");
    if let Some(matching) = &view.matching_id {
        ui::field("matching id", matching);
    }
    ui::muted("  allow it on a linked device if the matching id is the same there");
    while view.status == RestoreRequestStatus::Pending {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => bail!("nothing changed; the request stays until it expires"),
            () = tokio::time::sleep(RESTORE_POLL) => {},
        }
        view = flows::poll_restore(identity, &view.request_id).await?;
    }
    Ok(view)
}

fn pick_device(devices: &[PreviewDevice]) -> Result<String> {
    if !std::io::stdin().is_terminal() {
        bail!("name the device to restore with --device <id>");
    }
    for (index, device) in devices.iter().enumerate() {
        println!("  {}. {} ({})", index + 1, device.name, device.id);
    }
    let answer = prompt("which device is this? number: ")?;
    let index: usize = answer.trim().parse().context("not a number")?;
    devices
        .get(index.wrapping_sub(1))
        .map(|device| device.id.clone())
        .context("no device has that number")
}

fn warn_if_active_today(device: &PreviewDevice) {
    let today = chrono::Utc::now().timestamp() / SECONDS_PER_DAY;
    if device.last_active_day >= today - 1 {
        ui::warn(&format!("{} was active today: restoring cuts it off", device.name));
    }
}

/// `pocox pair start-over`: leave a superseded or unknown identity behind.
async fn start_over(backend: Option<&str>, yes: bool) -> Result<()> {
    let identity = identity(backend)?;
    if !confirm("discard this device's dead identity and start as a new device?", yes)? {
        bail!("nothing changed");
    }
    let prepared = flows::start_over(&identity, None).await?;
    ui::headline(ui::Tone::Ok, "this is a new device");
    print_code(&prepared.code);
    ui::code("pocox pair");
    Ok(())
}

/// `pocox pair leave`.
async fn leave(backend: Option<&str>, yes: bool) -> Result<()> {
    let identity = identity(backend)?;
    ui::warn("this device leaves its group, and every POCOX installation on it moves too");
    if !confirm("leave?", yes)? {
        bail!("nothing changed");
    }
    let outcome = operations::leave(&identity).await?;
    finish(&identity, outcome, "this device left its group").await
}

async fn list(backend: Option<&str>) -> Result<()> {
    let identity = identity(backend)?;
    let reading = status::status(&identity).await?;
    if reading.state == PairingState::NoDevice {
        ui::headline(ui::Tone::Muted, "this device has no pairing identity yet");
        ui::code("pocox pair");
        return Ok(());
    }
    let mut cursor = None;
    let mut table = ui::new_table(&["device", "name", "platform", "state", "last active"]);
    let mut requests = Vec::new();
    loop {
        let page = flows::devices(&identity, cursor.as_deref()).await?;
        for device in page.devices {
            let mut name = device.name;
            if device.is_self {
                name.push_str(" (this device)");
            }
            table.add_row(vec![
                device.id,
                name,
                device.platform.unwrap_or_default(),
                if device.activated { "set up" } else { "not set up" }.to_string(),
                format_day(device.last_active_day),
            ]);
        }
        requests.extend(page.pending_requests);
        cursor = page.next_cursor;
        if cursor.is_none() {
            break;
        }
    }
    println!("{table}");
    for request in requests {
        ui::headline(ui::Tone::Action, "a device asks to be restored");
        ui::field("from", &request.requester_name);
        ui::field("matching id", &request.matching_id);
        ui::code(&format!(
            "pocox devices allow {} --request {}",
            request.target_device_id, request.request_id
        ));
        ui::code(&format!(
            "pocox devices deny {} --request {}",
            request.target_device_id, request.request_id
        ));
    }
    Ok(())
}

async fn remove(backend: Option<&str>, id: &str, yes: bool) -> Result<()> {
    let identity = identity(backend)?;
    ui::warn(
        "its access for new connections ends; a connection already open may last until an end \
         closes it",
    );
    if !confirm("remove this device?", yes)? {
        bail!("nothing changed");
    }
    let outcome = operations::remove(&identity, id).await?;
    finish(&identity, outcome, "new connections from that device stopped").await
}

async fn decide(backend: Option<&str>, id: &str, request: &str, allow: bool) -> Result<()> {
    flows::decide(&identity(backend)?, id, request, allow).await?;
    if allow {
        ui::headline(ui::Tone::Ok, "allowed; nothing changes until that device confirms");
    } else {
        ui::headline(ui::Tone::Ok, "denied");
    }
    Ok(())
}

/// Report a change's result, reading a pending one for a while. Never repeats
/// it.
async fn finish(identity: &Identity, mut outcome: OperationOutcome, done: &str) -> Result<()> {
    let deadline = std::time::Instant::now() + OPERATION_WAIT;
    while outcome.status == OperationStatus::Pending && std::time::Instant::now() < deadline {
        tokio::time::sleep(OPERATION_POLL).await;
        if let Some(latest) = operations::settle(identity)
            .await?
            .into_iter()
            .find(|candidate| candidate.id == outcome.id)
        {
            outcome = latest;
        } else {
            outcome.status = OperationStatus::Completed;
        }
    }
    match outcome.status {
        OperationStatus::Completed => {
            ui::headline(ui::Tone::Ok, done);
            Ok(())
        },
        OperationStatus::Pending => {
            ui::headline(ui::Tone::Change, "still waiting for the relay to confirm this");
            ui::muted("  it continues without this command; run `pocox devices` to see the result");
            Ok(())
        },
        OperationStatus::Failed | OperationStatus::Unknown => {
            let reason = outcome.error.map_or("unknown", |code| code.as_str());
            bail!("that did not happen: {reason}");
        },
    }
}

fn explain_dead_identity(error: anyhow::Error) -> anyhow::Error {
    match code_of(&error) {
        Some(PairingErrorCode::DeviceSuperseded) => error.context(
            "another device took over this one's identity; run `pocox pair start-over`, then \
             `pocox pair restore` if this should be a device you had",
        ),
        Some(PairingErrorCode::DeviceUnknown) => {
            error.context("the backend does not know this device; run `pocox pair start-over`")
        },
        _ => error,
    }
}

fn print_group(devices: &[PreviewDevice]) {
    for device in devices {
        ui::field(
            "device",
            &format!("{} (last active {})", device.name, format_day(device.last_active_day)),
        );
    }
}

fn format_day(day: i64) -> String {
    let today = chrono::Utc::now().timestamp() / SECONDS_PER_DAY;
    match today - day {
        0 => "today".to_string(),
        1 => "yesterday".to_string(),
        days => format!("{days} days ago"),
    }
}

/// A code from the terminal or the first line of stdin.
fn read_code() -> Result<String> {
    let raw = if std::io::stdin().is_terminal() {
        prompt("pairing code: ")?
    } else {
        let mut line = String::new();
        std::io::stdin()
            .lock()
            .read_line(&mut line)
            .context("reading the code from stdin")?;
        line
    };
    let raw = raw.trim();
    let raw = raw.strip_prefix(PAIR_URI_PREFIX).unwrap_or(raw);
    normalize_code(raw).context("that is not a pairing code")
}

fn prompt(question: &str) -> Result<String> {
    let mut out = std::io::stderr();
    write!(out, "{question}")?;
    out.flush()?;
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line)?;
    Ok(line)
}

/// `yes`, or the answer of someone at a terminal. Off a terminal, a change
/// nobody confirmed does not happen.
fn confirm(question: &str, yes: bool) -> Result<bool> {
    if yes {
        return Ok(true);
    }
    if !std::io::stdin().is_terminal() {
        ui::muted(&format!("  {question} (pass --yes to confirm without a terminal)"));
        return Ok(false);
    }
    let answer = prompt(&format!("{question} [y/N] "))?;
    Ok(matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes"))
}
