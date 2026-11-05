//! Previewing a code, linking and leaving.

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;
use axum::Json;
use pocox_account_proto::pairing::{
    normalize_code, LeaveRequest, LinkRequest, PairingErrorCode, PreviewDevice, PreviewRequest,
    PreviewResponse,
};
use pocox_auth::pairing::PREVIEW_TICKET_TTL_SECS;
use pocox_auth::PreviewTicket;
use pocox_store::pairing::{CodeResolution, Device, LinkInput, OperationKind, OperationMeta};

use super::address::PeerAddr;
use super::error::{PairingError, PairingResult};
use super::routes::{gate, now, require_current, require_operation_id, PairJson};
use super::service::{binding, fingerprint, Pairing};
use crate::api::AppState;

impl Pairing {
    /// A group's devices as shown before confirming it. Bounded by the group
    /// limit.
    pub(super) async fn preview_devices(&self, user_id: &str) -> PairingResult<Vec<PreviewDevice>> {
        let devices = self
            .store
            .group_devices(user_id, None, self.settings.max_group_size)
            .await?;
        Ok(devices.iter().map(preview_device).collect())
    }
}

fn preview_device(device: &Device) -> PreviewDevice {
    PreviewDevice {
        id: device.id.clone(),
        name: device.label.clone(),
        last_active_day: device.last_active_day,
    }
}

/// `POST /v1/pair/preview`: what a code leads to, and a ticket to confirm
/// exactly that.
pub(super) async fn preview(
    State(state): State<AppState>,
    PeerAddr(peer): PeerAddr,
    headers: HeaderMap,
    PairJson(request): PairJson<PreviewRequest>,
) -> PairingResult<Json<PreviewResponse>> {
    let (pairing, caller) = gate(&state, &headers).await?;
    require_current(&caller)?;
    // Malformed input never reaches a lookup or a budget.
    let code = normalize_code(&request.code)
        .ok_or(PairingError::code(PairingErrorCode::InvalidRequest))?;
    let at = now();
    let bucket = pairing.client_bucket(peer, &headers);
    pairing.charge_code_check(bucket, at).await?;
    let lookup = pairing.keys.code_lookup(&code);
    let target = match pairing.store.resolve_code(&lookup).await? {
        CodeResolution::Active(device) => device,
        CodeResolution::Retired => return Err(PairingError::code(PairingErrorCode::CodeRetired)),
        CodeResolution::Unknown => return Err(PairingError::code(PairingErrorCode::CodeUnknown)),
    };
    if target.code_paused {
        return Err(PairingError::code(PairingErrorCode::LinkingPaused));
    }
    if target.id == caller.access.device.id {
        return Err(PairingError::code(PairingErrorCode::OwnCode));
    }
    // A valid code refunds its charge: only guesses stay on the meter.
    pairing.credit_valid_code(bucket, at)?;
    let group = pairing
        .store
        .device_access(&target.id, target.session_generation)
        .await?
        .ok_or(PairingError::code(PairingErrorCode::CodeUnknown))?
        .user;
    let exp = at + PREVIEW_TICKET_TTL_SECS;
    let ticket = pairing.keys.sign_ticket(&PreviewTicket {
        caller_device_id: caller.access.device.id.clone(),
        caller_generation: caller.access.session.generation,
        source_revision: caller.access.user.membership_revision,
        target_device_id: target.id.clone(),
        code_generation: target.code_generation,
        code_pause_epoch: target.code_pause_epoch,
        user_id: group.id.clone(),
        revision: group.membership_revision,
        exp,
    });
    Ok(Json(PreviewResponse {
        ticket,
        expires_at: exp,
        target_device_id: target.id.clone(),
        already_member: group.id == caller.access.user.id,
        devices: pairing.preview_devices(&group.id).await?,
    }))
}

/// `POST /v1/pair/link`: move this device, and only this device, into the group
/// the user confirmed. Two groups never merge.
pub(super) async fn link(
    State(state): State<AppState>,
    PeerAddr(peer): PeerAddr,
    headers: HeaderMap,
    PairJson(request): PairJson<LinkRequest>,
) -> PairingResult<Response> {
    let (pairing, caller) = gate(&state, &headers).await?;
    require_current(&caller)?;
    require_operation_id(&request.operation_id)?;
    let hash = caller.access.session.secret_hash.clone();
    let print = fingerprint(OperationKind::Link.as_str(), &hash, &[
        request.ticket.as_bytes(),
        &[u8::from(request.leave_current)],
        request
            .hint
            .as_ref()
            .map_or(&b""[..], |hint| hint.key.as_bytes()),
    ]);
    if let Some(operation) = pairing.replay(&request.operation_id, &print).await? {
        return pairing.respond_to_operation(&operation, false).await;
    }
    pairing.require_capable_relay().await?;
    let at = now();
    let bucket = pairing.client_bucket(peer, &headers);
    pairing.charge_code_check(bucket, at).await?;
    let ticket = pairing
        .keys
        .verify_ticket(&request.ticket, at)
        .filter(|ticket| ticket.caller_device_id == caller.access.device.id)
        .ok_or(PairingError::code(PairingErrorCode::PreviewStale))?;
    pairing.credit_valid_code(bucket, at)?;
    let lookup = request
        .hint
        .as_ref()
        .map(|hint| pairing.hint_lookup(hint))
        .transpose()?;
    let prepared = pairing
        .metered_prepare(&caller.access.device.id, bucket, at, || {
            pairing.store.prepare_link(LinkInput {
                meta: OperationMeta {
                    id: &request.operation_id,
                    fingerprint: &print,
                    actor_device_id: &caller.access.device.id,
                    actor_secret_hash: &hash,
                    now: at,
                },
                generation: ticket.caller_generation,
                source_revision: ticket.source_revision,
                target_device_id: &ticket.target_device_id,
                code_generation: ticket.code_generation,
                code_pause_epoch: ticket.code_pause_epoch,
                destination_user_id: &ticket.user_id,
                destination_revision: ticket.revision,
                leave_current: request.leave_current,
                hardware: binding(lookup.as_deref(), request.hint.as_ref()),
                max_group_size: pairing.settings.max_group_size,
            })
        })
        .await?;
    pairing.finish_mutation(prepared).await
}

/// `POST /v1/pair/leave`: move this device into a single-device user. A repeat
/// is a no-op, never another new group.
pub(super) async fn leave(
    State(state): State<AppState>,
    PeerAddr(peer): PeerAddr,
    headers: HeaderMap,
    PairJson(request): PairJson<LeaveRequest>,
) -> PairingResult<Response> {
    let (pairing, caller) = gate(&state, &headers).await?;
    require_current(&caller)?;
    require_operation_id(&request.operation_id)?;
    let hash = caller.access.session.secret_hash.clone();
    let print = fingerprint(OperationKind::Leave.as_str(), &hash, &[]);
    if let Some(operation) = pairing.replay(&request.operation_id, &print).await? {
        return pairing.respond_to_operation(&operation, false).await;
    }
    pairing.require_capable_relay().await?;
    let at = now();
    let bucket = pairing.client_bucket(peer, &headers);
    let prepared = pairing
        .metered_prepare(&caller.access.device.id, bucket, at, || {
            pairing.store.prepare_leave(
                OperationMeta {
                    id: &request.operation_id,
                    fingerprint: &print,
                    actor_device_id: &caller.access.device.id,
                    actor_secret_hash: &hash,
                    now: at,
                },
                caller.access.session.generation,
            )
        })
        .await?;
    pairing.finish_mutation(prepared).await
}
