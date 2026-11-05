//! Recovery: asking a linked device, and confirming a restore.
//!
//! Only the requester's confirmation changes anything. A hint locates a row; a
//! member's approval lets the requester see the group; neither moves a secret.

use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::Response;
use axum::Json;
use pocox_account_proto::pairing::{
    ConfirmRestoreRequest, CreateRestoreRequest, DecideRestoreRequest, PairingErrorCode,
    RestoreIntent, RestoreRequestStatus, RestoreRequestView,
};
use pocox_store::pairing::{
    DecideInput, OperationKind, OperationMeta, RestoreInput, RestoreProof, RestoreRequest,
    RestoreRequestState,
};

use super::address::PeerAddr;
use super::error::{PairingError, PairingResult};
use super::routes::{gate, now, require_current, require_operation_id, PairJson};
use super::service::{binding, fingerprint, Pairing};
use crate::api::AppState;

fn wire_status(state: RestoreRequestState) -> RestoreRequestStatus {
    match state {
        RestoreRequestState::Pending => RestoreRequestStatus::Pending,
        RestoreRequestState::Approved => RestoreRequestStatus::Approved,
        RestoreRequestState::Denied => RestoreRequestStatus::Denied,
        RestoreRequestState::Expired => RestoreRequestStatus::Expired,
        RestoreRequestState::Stale => RestoreRequestStatus::Stale,
    }
}

impl Pairing {
    /// A request as its requester sees it. The group appears only once
    /// approved.
    async fn request_view(&self, request: &RestoreRequest) -> PairingResult<RestoreRequestView> {
        let status = wire_status(request.state);
        let open =
            matches!(request.state, RestoreRequestState::Pending | RestoreRequestState::Approved);
        let approved = request.state == RestoreRequestState::Approved;
        Ok(RestoreRequestView {
            request_id: request.id.clone(),
            status,
            matching_id: open.then(|| self.keys.matching_id(&request.id)),
            expires_at: open.then_some(if approved {
                request.approval_expires_at.unwrap_or(request.expires_at)
            } else {
                request.expires_at
            }),
            target_device_id: approved.then(|| request.target_device_id.clone()),
            devices: if approved {
                self.preview_devices(&request.target_user_id).await?
            } else {
                Vec::new()
            },
        })
    }
}

/// `POST /v1/pair/restore/requests`: ask whichever device holds this hint. The
/// answer reveals nothing about it; `not_found` means no row holds the hint.
pub(super) async fn create_request(
    State(state): State<AppState>,
    PeerAddr(peer): PeerAddr,
    headers: HeaderMap,
    PairJson(request): PairJson<CreateRestoreRequest>,
) -> PairingResult<Json<RestoreRequestView>> {
    let (pairing, caller) = gate(&state, &headers).await?;
    require_current(&caller)?;
    let lookup = pairing.hint_lookup(&request.hint)?;
    let at = now();
    let bucket = pairing.client_bucket(peer, &headers);
    pairing
        .limiters
        .code_checks
        .charge(bucket.0, at)
        .map_err(|wait| PairingError::retry_later(PairingErrorCode::RateLimited, wait))?;
    pairing
        .charge_backend("restore_requests", pairing.settings.limits.restore_requests_backend, at)
        .await?;
    let created = pairing
        .store
        .create_restore_request(
            &caller.access.device.id,
            caller.access.session.generation,
            &lookup,
            pairing.settings.restore_slots,
            at,
        )
        .await?;
    Ok(Json(pairing.request_view(&created).await?))
}

/// `GET /v1/pair/restore/{request_id}`: poll, for the device that asked.
pub(super) async fn request_status(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(request_id): Path<String>,
) -> PairingResult<Json<RestoreRequestView>> {
    let (pairing, caller) = gate(&state, &headers).await?;
    require_current(&caller)?;
    let request = pairing
        .store
        .restore_request_for(&request_id, &caller.access.device.id, now())
        .await?
        .ok_or(PairingError::code(PairingErrorCode::NotFound))?;
    Ok(Json(pairing.request_view(&request).await?))
}

/// `POST /v1/devices/{id}/restore`: a current member allows or denies this
/// exact request. Allowing changes nothing until the requester confirms.
pub(super) async fn decide(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(target_id): Path<String>,
    PairJson(request): PairJson<DecideRestoreRequest>,
) -> PairingResult<StatusCode> {
    let (pairing, caller) = gate(&state, &headers).await?;
    require_current(&caller)?;
    require_operation_id(&request.operation_id)?;
    let hash = &caller.access.session.secret_hash;
    let print = fingerprint(OperationKind::Decide.as_str(), hash, &[
        target_id.as_bytes(),
        request.request_id.as_bytes(),
        &[u8::from(request.allow)],
    ]);
    pairing
        .store
        .decide_restore_request(DecideInput {
            meta: OperationMeta {
                id: &request.operation_id,
                fingerprint: &print,
                actor_device_id: &caller.access.device.id,
                actor_secret_hash: hash,
                now: now(),
            },
            generation: caller.access.session.generation,
            target_device_id: &target_id,
            request_id: &request.request_id,
            allow: request.allow,
        })
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

/// `POST /v1/pair/restore`: the requester's confirmation, with a ticket and the
/// chosen device or an approved request. Only this replaces a secret.
pub(super) async fn confirm(
    State(state): State<AppState>,
    PeerAddr(peer): PeerAddr,
    headers: HeaderMap,
    PairJson(request): PairJson<ConfirmRestoreRequest>,
) -> PairingResult<Response> {
    let (pairing, caller) = gate(&state, &headers).await?;
    require_current(&caller)?;
    require_operation_id(&request.operation_id)?;
    let retake = request.intent == RestoreIntent::Retake;
    let kind = if retake { OperationKind::Retake } else { OperationKind::Restore };
    let hash = caller.access.session.secret_hash.clone();
    let print = fingerprint(kind.as_str(), &hash, &[
        request.ticket.as_deref().unwrap_or_default().as_bytes(),
        request
            .target_device_id
            .as_deref()
            .unwrap_or_default()
            .as_bytes(),
        request.request_id.as_deref().unwrap_or_default().as_bytes(),
        request
            .hint
            .as_ref()
            .map_or(&b""[..], |hint| hint.key.as_bytes()),
    ]);
    if let Some(operation) = pairing.replay(&request.operation_id, &print).await? {
        return pairing.respond_to_operation(&operation).await;
    }
    pairing.require_capable_relay().await?;
    let at = now();
    let invalid = || PairingError::code(PairingErrorCode::InvalidRequest);
    let lookup = request
        .hint
        .as_ref()
        .map(|hint| pairing.hint_lookup(hint))
        .transpose()?;
    let verified_ticket;
    let approved_request;
    let (proof, target_id): (RestoreProof<'_>, &str) =
        match (request.ticket.as_deref(), request.request_id.as_deref()) {
            (Some(ticket), None) => {
                let target = request.target_device_id.as_deref().ok_or_else(invalid)?;
                let bucket = pairing.client_bucket(peer, &headers);
                pairing.charge_code_check(bucket, at).await?;
                verified_ticket = pairing
                    .keys
                    .verify_ticket(ticket, at)
                    .filter(|ticket| {
                        ticket.caller_device_id == caller.access.device.id
                            && ticket.caller_generation == caller.access.session.generation
                    })
                    .ok_or(PairingError::code(PairingErrorCode::PreviewStale))?;
                pairing.limiters.code_checks.refund(bucket.0);
                (
                    RestoreProof::Ticket {
                        source_revision: verified_ticket.source_revision,
                        code_device_id: &verified_ticket.target_device_id,
                        code_generation: verified_ticket.code_generation,
                        destination_user_id: &verified_ticket.user_id,
                        destination_revision: verified_ticket.revision,
                    },
                    target,
                )
            },
            (None, Some(id)) => {
                approved_request = pairing
                    .store
                    .restore_request_for(id, &caller.access.device.id, at)
                    .await?
                    .ok_or(PairingError::code(PairingErrorCode::NotFound))?;
                (
                    RestoreProof::Request {
                        request_id: id,
                    },
                    approved_request.target_device_id.as_str(),
                )
            },
            _ => return Err(invalid()),
        };
    let operation = pairing
        .store
        .prepare_restore(RestoreInput {
            meta: OperationMeta {
                id: &request.operation_id,
                fingerprint: &print,
                actor_device_id: &caller.access.device.id,
                actor_secret_hash: &hash,
                now: at,
            },
            generation: caller.access.session.generation,
            target_device_id: target_id,
            proof,
            retake,
            hardware: binding(lookup.as_deref(), request.hint.as_ref()),
            overlap_secs: pairing.settings.overlap_secs,
            retake_limit: pairing.settings.retake_limit,
            retake_window_secs: pairing.settings.retake_window_secs,
        })
        .await?;
    let driven = pairing.drive_in_foreground(operation).await?;
    pairing.respond_to_operation(&driven).await
}
