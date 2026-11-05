//! Pairing-code login, for the app's first screens and Account settings.
//!
//! Everything here works through the device store and leaves the active account
//! alone, except what the user explicitly confirms: [`pairing_activate`],
//! [`pairing_link`] and [`pairing_restore_confirm`]. A refusal arrives as a
//! [`PairingErrorDto`] whose `code` is the backend's stable reason.
//!
//! Mobile plugs in through [`pairing_install_native_store`] and by passing a
//! [`NativeHintDto`] to the calls that take one; a desktop needs neither.

use std::sync::Arc;

use anyhow::{Context, Result};
use flutter_rust_bridge::DartFnFuture;
use pocox_account_proto::pairing::{
    display_code, normalize_code, CodeStatus, DeviceListResponse, DeviceSession,
    MembershipChangeKind, OperationStatus, PreviewResponse, RestoreRequestStatus,
    RestoreRequestView, PAIR_URI_PREFIX,
};
use pocox_core::pairing::{install_platform_store, OperationKind, StoreBackend, StoredOperation};
use pocox_core::redact::scrub_pairing;

use crate::engine::config::load_config;
use crate::engine::execution::{self, Lane};
use crate::engine::pairing::identity::Identity;
use crate::engine::pairing::operations::{self, RestoreTarget};
use crate::engine::pairing::{self, flows, status, NativeHint, OperationOutcome, PairingError};
use crate::engine::{account, runtime, transport};

/// Why a pairing call failed. Match on `code`, never on `message`.
#[derive(Debug, Clone)]
pub struct PairingErrorDto {
    /// The backend's stable reason (`device_superseded`, `preview_stale`, …),
    /// `signed_out` for a session with no saved identity, or `failed` for
    /// anything else: an unreachable backend or an unreadable store, say.
    pub code: String,
    /// For the log. Holds no secret, code or pairing link.
    pub message: String,
    /// Seconds to wait before trying again.
    pub retry_after_secs: Option<u64>,
    /// The pending operation this waits on, when it is this device's own.
    pub operation_id: Option<String>,
    /// For a superseded secret, when its overlap ends (unix seconds).
    pub grace_deadline: Option<i64>,
}

impl From<anyhow::Error> for PairingErrorDto {
    fn from(error: anyhow::Error) -> Self {
        let message = scrub_pairing(&format!("{error:#}")).into_owned();
        let refusal = error
            .chain()
            .find_map(|cause| cause.downcast_ref::<PairingError>());
        let code = match refusal {
            Some(refusal) => refusal.code.as_str().to_string(),
            None if error.chain().any(|cause| cause.is::<pairing::SignedOut>()) => {
                "signed_out".to_string()
            },
            None => "failed".to_string(),
        };
        Self {
            code,
            message,
            retry_after_secs: refusal.and_then(|refusal| refusal.retry_after),
            operation_id: refusal.and_then(|refusal| refusal.operation_id.clone()),
            grace_deadline: refusal.and_then(|refusal| refusal.grace_deadline),
        }
    }
}

/// A raw hardware identifier a platform adapter read, for the one call that
/// asked for it. Rust derives a key from it and drops it; it is never stored or
/// sent.
pub struct NativeHintDto {
    /// The adapter's source: `android_id`.
    pub source: String,
    /// The raw identifier.
    pub raw_id: String,
}

/// A native store's answer to a read. `error` means the store exists and cannot
/// be read, which never becomes a new device.
pub struct NativeStoreRead {
    /// The record, absent when there is none.
    pub value: Option<String>,
    /// Why it cannot be read.
    pub error: Option<String>,
}

/// This device's session as the app sees it. Holds no token.
pub struct PairingSessionDto {
    /// This device's id.
    pub device_id: String,
    /// Its current user.
    pub account_id: String,
    /// Its display name.
    pub label: String,
    /// Whether the user has set it up.
    pub activated: bool,
    /// Its last membership transition: `linked`, `left`, `removed` or
    /// `unknown`.
    pub membership_change: Option<String>,
    /// When that was (unix seconds).
    pub membership_changed_at: Option<i64>,
}

/// This device's own code.
pub struct PairingCodeDto {
    /// The code as people read it: `K7M2-F9QX-3RTB`.
    pub code: String,
    /// What its QR code carries.
    pub uri: String,
    /// When it was issued (unix seconds, server time).
    pub issued_at: i64,
    /// Earliest rotation (unix seconds, server time).
    pub next_rotation_at: i64,
    /// Whether linking through it is paused.
    pub paused: bool,
}

/// A device ready to show its code.
pub struct PairingPreparedDto {
    /// Its session.
    pub session: PairingSessionDto,
    /// Its code.
    pub code: PairingCodeDto,
}

/// A membership change, which may still be under way.
pub struct PairingOperationDto {
    /// Its id.
    pub id: String,
    /// `link`, `leave`, `remove`, `restore` or `retake`.
    pub kind: String,
    /// `pending`, `completed`, `failed` or `unknown`. Never repeat a pending
    /// action: call [`pairing_settle`].
    pub status: String,
    /// Why it failed.
    pub error: Option<String>,
}

/// One reading of this device's identity.
pub struct PairingStatusDto {
    /// `no_device`, `inactive`, `active`, `removed`, `superseded`, `unknown` or
    /// `pending`.
    pub state: String,
    /// The canonical backend.
    pub backend: String,
    /// The session, when one could be issued.
    pub session: Option<PairingSessionDto>,
    /// Whether this identity is the active account here.
    pub active_here: bool,
    /// For a superseded secret, when its overlap ends (unix seconds).
    pub grace_deadline: Option<i64>,
    /// Changes whose result is not in yet, which survive a restart.
    pub pending: Vec<PairingOperationDto>,
    /// The login of a GitHub session set aside here, which
    /// [`pairing_resume_github`] brings back.
    pub parked_github: Option<String>,
}

/// A device shown before confirming a group.
pub struct PairingPreviewDeviceDto {
    /// Its id, which a restore names as its target.
    pub id: String,
    /// Its display name.
    pub name: String,
    /// The day it was last active, in days since the unix epoch.
    pub last_active_day: i64,
}

/// What a code leads to. Nothing has changed yet.
pub struct PairingPreviewDto {
    /// What confirming names.
    pub ticket: String,
    /// When the ticket stops working (unix seconds).
    pub expires_at: i64,
    /// The device whose code this is.
    pub target_device_id: String,
    /// Whether this device is already in that group.
    pub already_member: bool,
    /// The group's devices.
    pub devices: Vec<PairingPreviewDeviceDto>,
}

/// One device in this group.
pub struct PairingDeviceDto {
    /// Its id.
    pub id: String,
    /// Its display name.
    pub name: String,
    /// Its platform label.
    pub platform: Option<String>,
    /// When it joined (unix seconds).
    pub joined_at: i64,
    /// The day it was last active, in days since the unix epoch.
    pub last_active_day: i64,
    /// Whether it has been set up. An inactive peer hosts nothing.
    pub activated: bool,
    /// Whether this is this device.
    pub is_self: bool,
}

/// A recovery request waiting on a member.
pub struct PairingPendingRequestDto {
    /// Its id, which an answer must name.
    pub request_id: String,
    /// The device it asks to restore.
    pub target_device_id: String,
    /// The requester's self-reported name. Does not identify anyone.
    pub requester_name: String,
    /// Compare with the requester's screen.
    pub matching_id: String,
    /// When it expires (unix seconds).
    pub expires_at: i64,
}

/// One page of this group.
pub struct PairingDevicesDto {
    /// Its devices.
    pub devices: Vec<PairingDeviceDto>,
    /// Pass back for the next page.
    pub next_cursor: Option<String>,
    /// Requests a member can answer.
    pub pending_requests: Vec<PairingPendingRequestDto>,
}

/// Where this device's recovery request stands.
pub struct PairingRestoreRequestDto {
    /// Its id.
    pub request_id: String,
    /// `pending`, `approved`, `denied`, `expired`, `stale` or `unknown`.
    pub status: String,
    /// Shown on both devices to tell this request from an impostor.
    pub matching_id: Option<String>,
    /// When it stops being answerable (unix seconds).
    pub expires_at: Option<i64>,
    /// Approved only: the device this would restore.
    pub target_device_id: Option<String>,
    /// Approved only: the group's devices, to confirm before anything changes.
    pub devices: Vec<PairingPreviewDeviceDto>,
}

/// A store whose bytes a platform adapter holds.
struct NativeStore {
    read: Box<dyn Fn(String) -> DartFnFuture<NativeStoreRead> + Send + Sync>,
    write: Box<dyn Fn(String, String) -> DartFnFuture<Option<String>> + Send + Sync>,
}

impl StoreBackend for NativeStore {
    fn read(&self, slot: &str) -> Result<Option<Vec<u8>>> {
        // Waits for Dart's event loop, which runs elsewhere and never waits on
        // this thread.
        let answer = futures::executor::block_on((self.read)(slot.to_string()));
        match answer.error {
            Some(error) => anyhow::bail!("the device store cannot be read: {error}"),
            None => Ok(answer.value.map(String::into_bytes)),
        }
    }

    fn write(&self, slot: &str, bytes: &[u8]) -> Result<()> {
        let value = String::from_utf8(bytes.to_vec()).context("encoding the device store")?;
        match futures::executor::block_on((self.write)(slot.to_string(), value)) {
            Some(error) => anyhow::bail!("the device store cannot be saved: {error}"),
            None => Ok(()),
        }
    }
}

/// Keep the device store in a platform's secure storage for the rest of this
/// run: the iOS Keychain, or on Android `no_backup` plus Block Store. Call once
/// at startup, before any other pairing call. `lock_dir` is an app-private
/// directory for its lock files. `read` and `write` receive an opaque slot name
/// and the record as text; `write` answers only after the record is durable,
/// and either reports a failure by value rather than by throwing. Desktops
/// never call this.
pub fn pairing_install_native_store(
    lock_dir: String,
    read: impl Fn(String) -> DartFnFuture<NativeStoreRead> + Send + Sync + 'static,
    write: impl Fn(String, String) -> DartFnFuture<Option<String>> + Send + Sync + 'static,
) {
    install_platform_store(
        lock_dir.into(),
        Arc::new(NativeStore {
            read: Box::new(read),
            write: Box::new(write),
        }),
    );
}

/// One reading of this device's identity, settling what can be settled. Creates
/// nothing.
pub async fn pairing_status(backend: Option<String>) -> Result<PairingStatusDto, PairingErrorDto> {
    run(backend, move |identity| async move { Ok(status_dto(status::status(&identity).await?)) })
        .await
}

/// Opening sign-in: find or create this device's identity and its code. Changes
/// no active account or hosting, and sends no hardware hint.
pub async fn pairing_prepare(
    label: Option<String>,
    backend: Option<String>,
) -> Result<PairingPreparedDto, PairingErrorDto> {
    run(backend, move |identity| async move {
        let prepared = flows::prepare(&identity, label.as_deref()).await?;
        Ok(PairingPreparedDto {
            session: session_dto(prepared.session),
            code: code_dto(prepared.code),
        })
    })
    .await
}

/// Get started, or Continue: set this device up and make it the active account
/// here. Hosts stopped for a removal start again.
pub async fn pairing_activate(
    native_hint: Option<NativeHintDto>,
    backend: Option<String>,
) -> Result<PairingSessionDto, PairingErrorDto> {
    run(backend, move |identity| async move {
        // A change of user already dropped what the old one owned, and moving the
        // context again here could fail the hosts it is restarting.
        let session = flows::activate(&identity, native_hint.map(native)).await?;
        Ok(session_dto(session))
    })
    .await
}

/// This device's current code.
pub async fn pairing_code() -> Result<PairingCodeDto, PairingErrorDto> {
    run(None, move |identity| async move { Ok(code_dto(flows::code(&identity).await?)) }).await
}

/// Pause or resume linking through this device's code.
pub async fn pairing_set_paused(paused: bool) -> Result<PairingCodeDto, PairingErrorDto> {
    run(
        None,
        move |identity| async move { Ok(code_dto(flows::set_paused(&identity, paused).await?)) },
    )
    .await
}

/// Replace this device's code. `rate_limited` with `retry_after_secs` before a
/// day has passed since the last one.
pub async fn pairing_rotate() -> Result<PairingCodeDto, PairingErrorDto> {
    run(None, move |identity| async move { Ok(code_dto(flows::rotate(&identity).await?)) }).await
}

/// The code in a scanned `pocox://pair` invitation, or `None` when it is not
/// one. Scanning executes nothing: pass the code to [`pairing_preview`].
#[flutter_rust_bridge::frb(sync)]
pub fn pairing_parse_invitation(uri: String) -> Option<String> {
    flows::parse_invitation(&uri)
}

/// Look up a typed or scanned code. Changes nothing.
pub async fn pairing_preview(
    code: String,
    backend: Option<String>,
) -> Result<PairingPreviewDto, PairingErrorDto> {
    run(
        backend,
        move |identity| async move { Ok(preview_dto(flows::preview(&identity, &code).await?)) },
    )
    .await
}

/// Confirm a preview: move this device into that group. `leave_current` is the
/// user's explicit confirmation of leaving current peers and every local
/// installation sharing this identity.
pub async fn pairing_link(
    ticket: String,
    leave_current: bool,
    native_hint: Option<NativeHintDto>,
    backend: Option<String>,
) -> Result<PairingOperationDto, PairingErrorDto> {
    run(backend, move |identity| async move {
        let hint = flows::hardware_hint(&identity, native_hint.map(native)).await;
        let outcome = operations::link(&identity, &ticket, leave_current, hint).await?;
        Ok(outcome_dto(outcome))
    })
    .await
}

/// Move this device out of its group, after the user confirmed.
pub async fn pairing_leave() -> Result<PairingOperationDto, PairingErrorDto> {
    run(None, move |identity| async move { Ok(outcome_dto(operations::leave(&identity).await?)) })
        .await
}

/// Reconcile every change saved on this device, without repeating any. Call at
/// start and from a pending screen.
pub async fn pairing_settle(
    backend: Option<String>,
) -> Result<Vec<PairingOperationDto>, PairingErrorDto> {
    run(backend, move |identity| async move {
        Ok(operations::settle(&identity)
            .await?
            .into_iter()
            .map(outcome_dto)
            .collect())
    })
    .await
}

/// One page of this device's group.
pub async fn pairing_devices(cursor: Option<String>) -> Result<PairingDevicesDto, PairingErrorDto> {
    run(None, move |identity| async move {
        Ok(devices_dto(flows::devices(&identity, cursor.as_deref()).await?))
    })
    .await
}

/// Rename a device in this group.
pub async fn pairing_rename_device(device_id: String, name: String) -> Result<(), PairingErrorDto> {
    run(None, move |identity| async move { flows::rename(&identity, &device_id, &name).await })
        .await
}

/// Remove a device from this group, after the user confirmed.
pub async fn pairing_remove_device(
    device_id: String,
) -> Result<PairingOperationDto, PairingErrorDto> {
    run(None, move |identity| async move {
        Ok(outcome_dto(operations::remove(&identity, &device_id).await?))
    })
    .await
}

/// Allow or deny the exact recovery request a member sees. Allowing changes
/// nothing until the requester confirms.
pub async fn pairing_decide_restore(
    device_id: String,
    request_id: String,
    allow: bool,
) -> Result<(), PairingErrorDto> {
    run(None, move |identity| async move {
        flows::decide(&identity, &device_id, &request_id, allow).await
    })
    .await
}

/// Ask this device's former group to let it back. `not_found` when there is
/// nothing to ask with or nobody holds this hardware's hint: the code path and
/// continuing as new stay open.
pub async fn pairing_restore_request(
    native_hint: Option<NativeHintDto>,
    backend: Option<String>,
) -> Result<PairingRestoreRequestDto, PairingErrorDto> {
    run(backend, move |identity| async move {
        let view = flows::request_restore(&identity, native_hint.map(native)).await?;
        Ok(restore_request_dto(view))
    })
    .await
}

/// Where this device's recovery request stands.
pub async fn pairing_restore_poll(
    request_id: String,
    backend: Option<String>,
) -> Result<PairingRestoreRequestDto, PairingErrorDto> {
    run(backend, move |identity| async move {
        Ok(restore_request_dto(flows::poll_restore(&identity, &request_id).await?))
    })
    .await
}

/// Confirm a restore, once the user has seen the group's devices: a `ticket`
/// and `target_device_id` from a code's preview, or an approved `request_id`.
/// `retake` is for a suspected compromise: old authorization ends at once and
/// the code rotates.
pub async fn pairing_restore_confirm(
    ticket: Option<String>,
    target_device_id: Option<String>,
    request_id: Option<String>,
    retake: bool,
    native_hint: Option<NativeHintDto>,
    backend: Option<String>,
) -> Result<PairingOperationDto, PairingErrorDto> {
    run(backend, move |identity| async move {
        let target = match (ticket, target_device_id, request_id) {
            (Some(ticket), Some(device_id), None) => RestoreTarget::Ticket {
                ticket,
                device_id,
            },
            (None, None, Some(request_id)) => RestoreTarget::Approved {
                request_id,
            },
            _ => anyhow::bail!("a restore names a ticket and a device, or an approved request"),
        };
        let hint = flows::hardware_hint(&identity, native_hint.map(native)).await;
        Ok(outcome_dto(operations::restore(&identity, &target, retake, hint).await?))
    })
    .await
}

/// A superseded or unknown identity's way forward, on the user's choice:
/// discard the dead secret and start as a new inactive device, which can then
/// recover or carry on. Refused while the identity still works.
pub async fn pairing_start_over(
    label: Option<String>,
    backend: Option<String>,
) -> Result<PairingPreparedDto, PairingErrorDto> {
    run(backend, move |identity| async move {
        let prepared = flows::start_over(&identity, label.as_deref()).await?;
        Ok(PairingPreparedDto {
            session: session_dto(prepared.session),
            code: code_dto(prepared.code),
        })
    })
    .await
}

/// Make the GitHub session set aside here the active account again. Returns its
/// login, or `None` when none was set aside. The pairing identity stays in its
/// store, ready to resume.
pub async fn pairing_resume_github() -> Result<Option<String>, PairingErrorDto> {
    let resumed =
        execution::run(Lane::Control, move || pairing::resume_github(&runtime::support_dir()?))
            .await?;
    if resumed.is_some() {
        transport::context_changed();
    }
    Ok(resumed)
}

/// Run `work` for this installation's identity on `backend`, or on the backend
/// its configuration names.
async fn run<T, F, Fut>(backend: Option<String>, work: F) -> Result<T, PairingErrorDto>
where
    T: Send + 'static,
    F: FnOnce(Identity) -> Fut + Send + 'static,
    Fut: std::future::Future<Output = Result<T>>,
{
    Ok(execution::run(Lane::Control, move || {
        let support = runtime::support_dir()?;
        let backend = match backend
            .map(|url| url.trim().to_string())
            .filter(|url| !url.is_empty())
        {
            Some(backend) => backend,
            None => account::backend_base(&load_config(&support)?),
        };
        let identity = Identity::open(&support, &backend)?;
        runtime::runtime().block_on(work(identity))
    })
    .await?)
}

fn native(hint: NativeHintDto) -> NativeHint {
    NativeHint {
        source: hint.source,
        raw_id: hint.raw_id,
    }
}

fn session_dto(session: DeviceSession) -> PairingSessionDto {
    PairingSessionDto {
        device_id: session.device_id,
        account_id: session.account_id,
        label: session.login,
        activated: session.activated,
        membership_change: session.membership_change.map(|change| {
            match change.kind {
                MembershipChangeKind::Linked => "linked",
                MembershipChangeKind::Left => "left",
                MembershipChangeKind::Removed => "removed",
                MembershipChangeKind::Unknown => "unknown",
            }
            .to_string()
        }),
        membership_changed_at: session.membership_change.map(|change| change.at),
    }
}

fn code_dto(code: CodeStatus) -> PairingCodeDto {
    let compact = normalize_code(&code.code).unwrap_or_else(|| code.code.clone());
    PairingCodeDto {
        uri: format!("{PAIR_URI_PREFIX}{compact}"),
        code: display_code(&compact),
        issued_at: code.issued_at,
        next_rotation_at: code.next_rotation_at,
        paused: code.paused,
    }
}

fn kind_label(kind: OperationKind) -> &'static str {
    match kind {
        OperationKind::Link => "link",
        OperationKind::Leave => "leave",
        OperationKind::Remove => "remove",
        OperationKind::Restore => "restore",
        OperationKind::Retake => "retake",
    }
}

fn outcome_dto(outcome: OperationOutcome) -> PairingOperationDto {
    PairingOperationDto {
        id: outcome.id,
        kind: kind_label(outcome.kind).to_string(),
        status: match outcome.status {
            OperationStatus::Pending => "pending",
            OperationStatus::Completed => "completed",
            OperationStatus::Failed => "failed",
            OperationStatus::Unknown => "unknown",
        }
        .to_string(),
        error: outcome.error.map(|code| code.as_str().to_string()),
    }
}

fn pending_dto(operation: StoredOperation) -> PairingOperationDto {
    PairingOperationDto {
        id: operation.id,
        kind: kind_label(operation.kind).to_string(),
        status: "pending".to_string(),
        error: None,
    }
}

fn status_dto(status: status::PairingStatus) -> PairingStatusDto {
    PairingStatusDto {
        state: match status.state {
            status::PairingState::NoDevice => "no_device",
            status::PairingState::Inactive => "inactive",
            status::PairingState::Active => "active",
            status::PairingState::Removed => "removed",
            status::PairingState::Superseded => "superseded",
            status::PairingState::Unknown => "unknown",
            status::PairingState::Pending => "pending",
        }
        .to_string(),
        backend: status.backend,
        session: status.session.map(session_dto),
        active_here: status.active_here,
        grace_deadline: status.grace_deadline,
        pending: status.pending.into_iter().map(pending_dto).collect(),
        parked_github: status.parked_github,
    }
}

fn preview_devices(
    devices: Vec<pocox_account_proto::pairing::PreviewDevice>,
) -> Vec<PairingPreviewDeviceDto> {
    devices
        .into_iter()
        .map(|device| PairingPreviewDeviceDto {
            id: device.id,
            name: device.name,
            last_active_day: device.last_active_day,
        })
        .collect()
}

fn preview_dto(preview: PreviewResponse) -> PairingPreviewDto {
    PairingPreviewDto {
        ticket: preview.ticket,
        expires_at: preview.expires_at,
        target_device_id: preview.target_device_id,
        already_member: preview.already_member,
        devices: preview_devices(preview.devices),
    }
}

fn devices_dto(list: DeviceListResponse) -> PairingDevicesDto {
    PairingDevicesDto {
        devices: list
            .devices
            .into_iter()
            .map(|device| PairingDeviceDto {
                id: device.id,
                name: device.name,
                platform: device.platform,
                joined_at: device.joined_at,
                last_active_day: device.last_active_day,
                activated: device.activated,
                is_self: device.is_self,
            })
            .collect(),
        next_cursor: list.next_cursor,
        pending_requests: list
            .pending_requests
            .into_iter()
            .map(|request| PairingPendingRequestDto {
                request_id: request.request_id,
                target_device_id: request.target_device_id,
                requester_name: request.requester_name,
                matching_id: request.matching_id,
                expires_at: request.expires_at,
            })
            .collect(),
    }
}

fn restore_request_dto(view: RestoreRequestView) -> PairingRestoreRequestDto {
    PairingRestoreRequestDto {
        request_id: view.request_id,
        status: match view.status {
            RestoreRequestStatus::Pending => "pending",
            RestoreRequestStatus::Approved => "approved",
            RestoreRequestStatus::Denied => "denied",
            RestoreRequestStatus::Expired => "expired",
            RestoreRequestStatus::Stale => "stale",
            RestoreRequestStatus::Unknown => "unknown",
        }
        .to_string(),
        matching_id: view.matching_id,
        expires_at: view.expires_at,
        target_device_id: view.target_device_id,
        devices: preview_devices(view.devices),
    }
}
