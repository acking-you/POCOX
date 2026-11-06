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
    display_code, normalize_code, CodeStatus, DeviceEntry, DeviceSession, MembershipChangeKind,
    OperationStatus, PairingErrorCode, PendingRestoreSummary, PreviewDevice, RestoreRequestStatus,
    PAIR_URI_PREFIX,
};
use pocox_bridge::pairing::identity::Identity;
use pocox_bridge::pairing::operations::{self, RestoreTarget};
use pocox_bridge::pairing::{
    code_of, flows, status, NoDevice, OperationOutcome, PairingError, PairingState,
};
use pocox_core::config::Config;
use pocox_core::pairing::OperationKind;
use pocox_core::paths;
use pocox_core::redact::scrub_pairing;

use crate::cli::{DevicesCmd, PairArgs, PairCmd};
use crate::commands::{account, ui};

/// How often a waiting command lists its group, as any foreground page does.
const LINK_POLL: Duration = Duration::from_secs(60);
/// A wait starts here and backs off to [`MAX_POLL`].
const FIRST_POLL: Duration = Duration::from_secs(5);
const MAX_POLL: Duration = Duration::from_secs(60);
const OPERATION_POLL: Duration = Duration::from_secs(2);
const MAX_OPERATION_POLL: Duration = Duration::from_secs(15);
/// How long a command waits on a pending change before leaving it to the next
/// run.
const OPERATION_WAIT: Duration = Duration::from_secs(60);
/// A device active within this many days counts as active today for a warning.
const SECONDS_PER_DAY: i64 = 86_400;
/// The conventional exit code of a process stopped by Ctrl-C.
const EXIT_INTERRUPTED: i32 = 130;

/// The exit code of a command whose change the backend has yet to finish:
/// neither done nor failed, and never to be repeated.
pub(crate) const EXIT_STILL_PENDING: i32 = 75;

/// A change is under way and this command stopped waiting for it. Already told
/// to the user; the process exits with [`EXIT_STILL_PENDING`].
#[derive(Debug, Clone, Copy)]
pub(crate) struct StillPending;

impl std::fmt::Display for StillPending {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("still pending")
    }
}

impl std::error::Error for StillPending {}

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
    dispatch(args).await.map_err(scrubbed)
}

/// Whatever an error quotes, it never reaches a terminal or a log with a code.
fn scrubbed(error: anyhow::Error) -> anyhow::Error {
    if error.is::<StillPending>() {
        return error;
    }
    let error = explain_dead_identity(explain_no_device(error));
    anyhow::anyhow!("{}", scrub_pairing(&format!("{error:#}")))
}

fn explain_no_device(error: anyhow::Error) -> anyhow::Error {
    if error.chain().any(|cause| cause.is::<NoDevice>()) {
        return error.context("nothing was changed; `pocox pair` sets this device up");
    }
    error
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
        Some(PairCmd::Rotate) => rotate(backend).await,
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
    result.map_err(scrubbed)
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
    print_changes(&operations::settle(&identity).await?);
    let prepared = match flows::prepare(&identity, None).await {
        Ok(prepared) => prepared,
        Err(error) => return Err(error),
    };
    ui::headline(ui::Tone::Action, "this device's pairing code");
    print_code(&prepared.code);
    print_membership(&prepared.session);
    // A retained identity after a logout or a GitHub sign-in is as much the user's
    // choice to resume as a new one is to set up.
    if !prepared.session.activated || !identity.is_active_here()? {
        if prepared.session.activated {
            ui::muted("  this installation is not using this device's pairing identity");
        } else {
            ui::muted("  this device is not set up yet: it has no relay access until you continue");
        }
        if confirm("use this device's pairing identity now?", yes).await? {
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

/// Every device in this group, and the requests a member can answer, which
/// every page repeats.
async fn whole_group(
    identity: &Identity,
) -> Result<(Vec<DeviceEntry>, Vec<PendingRestoreSummary>)> {
    let first = flows::devices(identity, None).await?;
    let requests = first.pending_requests;
    let mut devices = first.devices;
    let mut cursor = first.next_cursor;
    while let Some(next) = cursor {
        let page = flows::devices(identity, Some(&next)).await?;
        devices.extend(page.devices);
        cursor = page.next_cursor;
    }
    Ok((devices, requests))
}

async fn wait_for_link(identity: &Identity) -> Result<()> {
    ui::muted("  enter this code on another device; Ctrl-C to stop waiting");
    let known: Vec<String> = whole_group(identity)
        .await?
        .0
        .into_iter()
        .map(|device| device.id)
        .collect();
    let mut errors = Backoff::new(LINK_POLL);
    let mut wait = LINK_POLL;
    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => return Ok(()),
            () = tokio::time::sleep(wait) => {},
        }
        let group = match whole_group(identity).await {
            Ok((group, _)) => group,
            Err(error) => {
                wait = errors.after_failure(error)?;
                continue;
            },
        };
        wait = LINK_POLL;
        errors = Backoff::new(LINK_POLL);
        let joined: Vec<&DeviceEntry> = group
            .iter()
            .filter(|device| !known.contains(&device.id))
            .collect();
        if !joined.is_empty() {
            ui::headline(ui::Tone::Ok, "a device linked");
            for device in joined {
                ui::field("device", &device.name);
            }
            return Ok(());
        }
    }
}

/// How a wait treats its polls failing. A refusal ends it. Anything else may
/// only be a network coming back, so it asks less often rather than giving up.
struct Backoff {
    next: Duration,
}

impl Backoff {
    fn new(first: Duration) -> Self {
        Self {
            next: first,
        }
    }

    fn after_failure(&mut self, error: anyhow::Error) -> Result<Duration> {
        let refused = error
            .chain()
            .find_map(|cause| cause.downcast_ref::<PairingError>())
            .is_some_and(PairingError::is_definite);
        if refused || error.chain().any(|cause| cause.is::<NoDevice>()) {
            return Err(error);
        }
        tracing::debug!("still waiting after: {error:#}");
        let wait = self.next;
        self.next = (self.next * 2).min(MAX_POLL);
        Ok(wait)
    }
}

const MOVES_EVERY_INSTALLATION: &str = "every POCOX installation on this device moves with it";

/// `pocox pair join`: read a code, show its group, confirm, move this device
/// there.
async fn join(backend: Option<&str>, yes: bool) -> Result<()> {
    let identity = identity(backend)?;
    let code = read_code().await?;
    let preview = flows::preview(&identity, &code).await?;
    ui::headline(ui::Tone::Action, "this code's group");
    print_group(&preview.devices);
    let (group, _) = whole_group(&identity).await?;
    let peers = group.iter().filter(|device| !device.is_self).count();
    let activated = group
        .iter()
        .any(|device| device.is_self && device.activated);
    if preview.already_member {
        ui::muted("  this device is already in this group");
    }
    let leave_current = peers > 0 && !preview.already_member;
    if leave_current {
        ui::warn(&format!("this device leaves its {peers} current peer(s)"));
    }
    if (leave_current || activated) && !preview.already_member {
        ui::warn(MOVES_EVERY_INSTALLATION);
    }
    if !confirm("join this group?", yes).await? {
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
    let prepared = flows::prepare(&identity, None).await?;
    if prepared.session.activated {
        // The backend would refuse it: only a device not yet set up can take over
        // another's identity.
        bail!(
            "this device is set up, so it has nothing to recover. A restore runs on a replacement \
             device, with a code from the group. If someone may have this device's code, run \
             `pocox pair pause`, and remove anything you do not recognise from a linked device \
             with `pocox devices remove <id>`"
        );
    }
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
        let code = read_code().await?;
        let preview = flows::preview(&identity, &code).await?;
        ui::headline(ui::Tone::Action, "this code's group");
        print_group(&preview.devices);
        let device_id = match device {
            Some(device) => device,
            None => pick_device(&preview.devices).await?,
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
    ui::warn(MOVES_EVERY_INSTALLATION);
    if retake {
        ui::warn("old access ends at once and this device's code changes");
    }
    if !confirm("these are my devices: restore?", yes).await? {
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
    let stopped = || anyhow::anyhow!("nothing changed; the request stays until it expires");
    let mut errors = Backoff::new(FIRST_POLL);
    let mut wait = FIRST_POLL;
    while view.status == RestoreRequestStatus::Pending {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => return Err(stopped()),
            () = tokio::time::sleep(wait) => {},
        }
        let polled = tokio::select! {
            _ = tokio::signal::ctrl_c() => return Err(stopped()),
            polled = flows::poll_restore(identity, &view.request_id) => polled,
        };
        match polled {
            Ok(latest) => {
                view = latest;
                wait = (wait * 2).min(MAX_POLL);
            },
            Err(error) => wait = errors.after_failure(error)?,
        }
    }
    Ok(view)
}

async fn pick_device(devices: &[PreviewDevice]) -> Result<String> {
    if !std::io::stdin().is_terminal() {
        bail!("name the device to restore with --device <id>, from the ids shown above");
    }
    for (index, device) in devices.iter().enumerate() {
        println!("  {}. {} ({})", index + 1, device.name, device.id);
    }
    let answer = prompt("which device is this? number: ").await?;
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

/// `pocox pair rotate`. Refused within a day of the code's issue, which is also
/// what an earlier rotation whose answer never arrived looks like: the current
/// code and when it was issued say which.
async fn rotate(backend: Option<&str>) -> Result<()> {
    let identity = identity(backend)?;
    match flows::rotate(&identity).await {
        Ok(code) => {
            ui::headline(ui::Tone::Ok, "this device has a new code");
            print_code(&code);
            Ok(())
        },
        Err(error) if code_of(&error) == Some(PairingErrorCode::RateLimited) => {
            if let Ok(current) = flows::code(&identity).await {
                ui::headline(ui::Tone::Muted, "this device's code");
                print_code(&current);
                ui::field("issued", &format_time(current.issued_at));
                ui::field("rotates", &format!("after {}", format_time(current.next_rotation_at)));
            }
            Err(error.context("a code changes at most once a day"))
        },
        Err(error) => Err(error),
    }
}

/// `pocox pair start-over`: leave a superseded or unknown identity behind.
async fn start_over(backend: Option<&str>, yes: bool) -> Result<()> {
    let identity = identity(backend)?;
    if !confirm("discard this device's dead identity and start as a new device?", yes).await? {
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
    ui::warn("this device leaves its group");
    ui::warn(MOVES_EVERY_INSTALLATION);
    if !confirm("leave?", yes).await? {
        bail!("nothing changed");
    }
    let outcome = operations::leave(&identity).await?;
    finish(&identity, outcome, "this device left its group").await
}

async fn list(backend: Option<&str>) -> Result<()> {
    let identity = identity(backend)?;
    let reading = status::status(&identity).await?;
    print_changes(&operations::settle(&identity).await?);
    match reading.state {
        PairingState::NoDevice => {
            ui::headline(ui::Tone::Muted, "this device has no pairing identity yet");
            ui::code("pocox pair");
            return Ok(());
        },
        PairingState::Superseded | PairingState::Unknown => {
            print_dead_identity(reading.state, reading.grace_deadline);
            return Ok(());
        },
        // The backend lists nothing until it finishes; what is under way was said.
        PairingState::Pending => return Ok(()),
        _ => {},
    }
    if let Some(session) = &reading.session {
        print_membership(session);
    }
    let (devices, requests) = whole_group(&identity).await?;
    let mut table = ui::new_table(&["device", "name", "platform", "state", "last active"]);
    for device in devices {
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

fn kind_name(kind: OperationKind) -> &'static str {
    match kind {
        OperationKind::Link => "joining a group",
        OperationKind::Leave => "leaving a group",
        OperationKind::Remove => "removing a device",
        OperationKind::Restore => "restoring a device",
        OperationKind::Retake => "taking a device back",
    }
}

/// Changes still open and those that turned out not to happen, which a command
/// that lost its answer could not say.
pub(crate) fn print_changes(outcomes: &[OperationOutcome]) {
    for outcome in outcomes {
        match outcome.status {
            OperationStatus::Pending => ui::headline(
                ui::Tone::Change,
                &format!("{} is still under way; do not repeat it", kind_name(outcome.kind)),
            ),
            OperationStatus::Unknown => ui::muted(&format!(
                "  how {} ended can no longer be learned; this device's state shows where it \
                 stands",
                kind_name(outcome.kind)
            )),
            OperationStatus::Failed => ui::warn(&format!(
                "{} did not happen: {}",
                kind_name(outcome.kind),
                outcome.error.as_deref().unwrap_or("unknown")
            )),
            OperationStatus::Completed => {
                if !outcome.caught_up {
                    print_not_caught_up(outcome.kind);
                }
            },
        }
    }
}

fn print_not_caught_up(kind: OperationKind) {
    ui::warn(&format!(
        "{} went through, but this installation has yet to catch up; `pocox pair` tries again",
        kind_name(kind)
    ));
}

/// Say what happened to this device's membership, when a peer did it.
pub(crate) fn print_membership(session: &DeviceSession) {
    let Some(change) = session.membership_change else {
        return;
    };
    if change.kind == MembershipChangeKind::Removed && !session.activated {
        ui::warn(&format!(
            "another device removed this one on {}: its new connections stopped",
            format_time(change.at)
        ));
    }
}

pub(crate) fn print_dead_identity(state: PairingState, grace_deadline: Option<i64>) {
    if state == PairingState::Superseded {
        ui::warn("another device took over this one's identity");
    } else {
        ui::warn("the backend does not know this device");
    }
    if let Some(deadline) = grace_deadline {
        ui::field("old access ends", &format_time(deadline));
    }
    ui::code("pocox pair start-over");
}

fn format_time(unix_seconds: i64) -> String {
    chrono::DateTime::from_timestamp(unix_seconds, 0).map_or_else(
        || unix_seconds.to_string(),
        |time| time.format("%Y-%m-%d %H:%M UTC").to_string(),
    )
}

async fn remove(backend: Option<&str>, id: &str, yes: bool) -> Result<()> {
    let identity = identity(backend)?;
    ui::warn(
        "its access for new connections ends; a connection already open may last until an end \
         closes it",
    );
    if !confirm("remove this device?", yes).await? {
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
/// it, and never takes its absence from the store for success: another process
/// may have forgotten it for any reason, so the backend is asked.
async fn finish(identity: &Identity, mut outcome: OperationOutcome, done: &str) -> Result<()> {
    let deadline = std::time::Instant::now() + OPERATION_WAIT;
    let mut wait = OPERATION_POLL;
    while outcome.status == OperationStatus::Pending && std::time::Instant::now() < deadline {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => break,
            () = tokio::time::sleep(wait) => {},
        }
        wait = (wait * 2).min(MAX_OPERATION_POLL);
        let saved = operations::settle(identity)
            .await?
            .into_iter()
            .find(|candidate| candidate.id == outcome.id);
        let latest = match saved {
            Some(saved) => Some(saved),
            None => operations::read_outcome(identity, &outcome).await,
        };
        match latest {
            Some(latest) => outcome = latest,
            None => break,
        }
    }
    match outcome.status {
        OperationStatus::Completed => {
            ui::headline(ui::Tone::Ok, done);
            if !outcome.caught_up {
                print_not_caught_up(outcome.kind);
            }
            Ok(())
        },
        OperationStatus::Pending => {
            ui::headline(ui::Tone::Change, "the backend has yet to confirm this; do not repeat it");
            ui::muted("  `pocox devices` shows how it ended");
            Err(StillPending.into())
        },
        OperationStatus::Unknown => {
            bail!("how that ended can no longer be learned; `pocox devices` shows where this is");
        },
        OperationStatus::Failed => {
            bail!("that did not happen: {}", outcome.error.as_deref().unwrap_or("unknown"));
        },
    }
}

fn explain_dead_identity(error: anyhow::Error) -> anyhow::Error {
    let deadline = error
        .chain()
        .find_map(|cause| cause.downcast_ref::<PairingError>())
        .and_then(|refusal| refusal.grace_deadline)
        .map(|deadline| format!(" Its old access ends at {}.", format_time(deadline)))
        .unwrap_or_default();
    match code_of(&error) {
        // A replaced identity's last session may still finish what it had open,
        // and is refused the rest with this.
        Some(PairingErrorCode::DeviceSuperseded | PairingErrorCode::GraceRestricted) => error
            .context(format!(
                "another device took over this one's identity.{deadline} Run `pocox pair \
                 start-over`, then `pocox pair restore` if this should be a device you had"
            )),
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
            &format!(
                "{} ({}, last active {})",
                device.name,
                device.id,
                format_day(device.last_active_day)
            ),
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
async fn read_code() -> Result<String> {
    let raw = if std::io::stdin().is_terminal() {
        prompt("pairing code: ").await?
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

/// Ask at the terminal. Once a wait has listened for Ctrl-C the terminal no
/// longer stops this process on its own, so a prompt listens too. A blocked
/// read of stdin cannot be cancelled, and the runtime would wait on it, so this
/// leaves the process outright; nothing has changed at any prompt.
async fn prompt(question: &str) -> Result<String> {
    let question = question.to_string();
    let answer = tokio::task::spawn_blocking(move || -> Result<String> {
        let mut out = std::io::stderr();
        write!(out, "{question}")?;
        out.flush()?;
        let mut line = String::new();
        std::io::stdin().lock().read_line(&mut line)?;
        Ok(line)
    });
    tokio::select! {
        answer = answer => answer.context("reading the answer")?,
        _ = tokio::signal::ctrl_c() => {
            eprintln!("\nnothing changed");
            std::process::exit(EXIT_INTERRUPTED);
        },
    }
}

/// `yes`, or the answer of someone at a terminal. Off a terminal, a change
/// nobody confirmed does not happen.
async fn confirm(question: &str, yes: bool) -> Result<bool> {
    if yes {
        return Ok(true);
    }
    if !std::io::stdin().is_terminal() {
        ui::muted(&format!("  {question} (pass --yes to confirm without a terminal)"));
        return Ok(false);
    }
    let answer = prompt(&format!("{question} [y/N] ")).await?;
    Ok(matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes"))
}
