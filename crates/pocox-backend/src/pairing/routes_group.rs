//! A group's device list, renames and removal.

use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::Response;
use axum::Json;
use pocox_account_proto::pairing::{
    parse_label, DeviceEntry, DeviceListResponse, PairingErrorCode, PendingRestoreSummary,
    RenameDeviceRequest,
};
use pocox_store::pairing::{OperationKind, OperationMeta, RemoveInput};
use serde::Deserialize;

use super::error::{PairingError, PairingResult};
use super::routes::{gate, now, require_current, require_operation_id, PairJson};
use super::service::fingerprint;
use crate::api::AppState;

/// Devices per page.
const DEVICE_PAGE: i64 = 50;

/// Pending request summaries in one listing.
const REQUEST_SUMMARIES: i64 = 20;

#[derive(Debug, Default, Deserialize)]
pub(super) struct ListQuery {
    cursor: Option<String>,
}

/// `GET /v1/devices`: the caller's group. Never another device's code or
/// secret.
pub(super) async fn list(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<ListQuery>,
) -> PairingResult<Json<DeviceListResponse>> {
    let (pairing, caller) = gate(&state, &headers).await?;
    require_current(&caller)?;
    let at = now();
    let user_id = &caller.access.user.id;
    let page = pairing
        .store
        .group_devices(user_id, query.cursor.as_deref(), DEVICE_PAGE + 1)
        .await?;
    let has_more = page.len() as i64 > DEVICE_PAGE;
    let devices: Vec<DeviceEntry> = page
        .iter()
        .take(DEVICE_PAGE as usize)
        .map(|device| DeviceEntry {
            id: device.id.clone(),
            name: device.label.clone(),
            platform: device.platform.clone(),
            joined_at: device.joined_at,
            last_active_day: device.last_active_day,
            activated: device.activated_at.is_some(),
            is_self: device.id == caller.access.device.id,
        })
        .collect();
    let next_cursor = has_more
        .then(|| devices.last().map(|device| device.id.clone()))
        .flatten();
    let pending_requests = pairing
        .store
        .pending_restore_requests(user_id, REQUEST_SUMMARIES, at)
        .await?
        .into_iter()
        .map(|(request, requester_name)| PendingRestoreSummary {
            matching_id: pairing.keys.matching_id(&request.id),
            request_id: request.id,
            target_device_id: request.target_device_id,
            requester_name,
            expires_at: request.expires_at,
        })
        .collect();
    Ok(Json(DeviceListResponse {
        devices,
        next_cursor,
        pending_requests,
    }))
}

/// `PATCH /v1/devices/{id}`: rename only a device in the caller's current user.
pub(super) async fn rename(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    PairJson(request): PairJson<RenameDeviceRequest>,
) -> PairingResult<StatusCode> {
    let (pairing, caller) = gate(&state, &headers).await?;
    require_current(&caller)?;
    let name =
        parse_label(&request.name).ok_or(PairingError::code(PairingErrorCode::InvalidRequest))?;
    pairing
        .store
        .rename_device(&caller.access.user.id, &id, &name)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Debug, Deserialize)]
pub(super) struct RemoveQuery {
    operation_id: String,
}

/// `DELETE /v1/devices/{id}?operation_id=…`: remove a peer from the caller's
/// current user. Every key of the removed device is revoked before this reports
/// completion.
pub(super) async fn remove(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Query(query): Query<RemoveQuery>,
) -> PairingResult<Response> {
    let (pairing, caller) = gate(&state, &headers).await?;
    require_current(&caller)?;
    require_operation_id(&query.operation_id)?;
    let hash = caller.access.session.secret_hash.clone();
    let print = fingerprint(OperationKind::Remove.as_str(), &hash, &[id.as_bytes()]);
    if let Some(operation) = pairing.replay(&query.operation_id, &print).await? {
        return pairing.respond_to_operation(&operation).await;
    }
    pairing.require_capable_relay().await?;
    let operation = pairing
        .store
        .prepare_remove(RemoveInput {
            meta: OperationMeta {
                id: &query.operation_id,
                fingerprint: &print,
                actor_device_id: &caller.access.device.id,
                actor_secret_hash: &hash,
                now: now(),
            },
            generation: caller.access.session.generation,
            subject_device_id: &id,
        })
        .await?;
    let driven = pairing.drive_in_foreground(operation).await?;
    pairing.respond_to_operation(&driven).await
}
