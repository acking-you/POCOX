//! Activation and a device's own code.

use axum::extract::State;
use axum::http::HeaderMap;
use axum::Json;
use pocox_account_proto::pairing::{
    display_code, ActivateRequest, ActivationStatus, CodeStatus, PairingErrorCode,
    RotateCodeRequest, SetCodePausedRequest,
};
use pocox_store::pairing::{OperationKind, OperationMeta, RotateInput, CODE_ROTATION_WAIT_SECS};
use pocox_store::Refusal;

use super::error::{PairingError, PairingResult};
use super::routes::{gate, now, require_current, require_operation_id, PairJson};
use super::service::{binding, fingerprint, Pairing};
use crate::api::AppState;

impl Pairing {
    /// Show a device's own current code. Derived on demand: never stored in
    /// plaintext.
    fn code_status(&self, device: &pocox_store::pairing::Device) -> CodeStatus {
        CodeStatus {
            code: display_code(&self.keys.code(&device.id, device.code_generation)),
            issued_at: device.code_issued_at,
            next_rotation_at: device.code_issued_at + CODE_ROTATION_WAIT_SECS,
            paused: device.code_paused,
        }
    }
}

/// `POST /v1/pair/activate`: the explicit Get started or Continue. Opening or
/// polling never activates; this does, idempotently, and binds the hint.
pub(super) async fn activate(
    State(state): State<AppState>,
    headers: HeaderMap,
    PairJson(request): PairJson<ActivateRequest>,
) -> PairingResult<Json<ActivationStatus>> {
    let (pairing, caller) = gate(&state, &headers).await?;
    require_current(&caller)?;
    pairing.require_capable_relay().await?;
    let lookup = request
        .hint
        .as_ref()
        .map(|hint| pairing.hint_lookup(hint))
        .transpose()?;
    let activated_at = pairing
        .store
        .activate_device(
            &caller.access.device.id,
            caller.access.session.generation,
            binding(lookup.as_deref(), request.hint.as_ref()),
            now(),
        )
        .await?;
    Ok(Json(ActivationStatus {
        activated_at,
    }))
}

/// `GET /v1/pair/code`.
pub(super) async fn code(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> PairingResult<Json<CodeStatus>> {
    let (pairing, caller) = gate(&state, &headers).await?;
    require_current(&caller)?;
    Ok(Json(pairing.code_status(&caller.access.device)))
}

/// `PATCH /v1/pair/code`: an explicit state, not a retry-sensitive toggle.
pub(super) async fn set_paused(
    State(state): State<AppState>,
    headers: HeaderMap,
    PairJson(request): PairJson<SetCodePausedRequest>,
) -> PairingResult<Json<CodeStatus>> {
    let (pairing, caller) = gate(&state, &headers).await?;
    require_current(&caller)?;
    let device_id = &caller.access.device.id;
    pairing
        .store
        .set_code_paused(device_id, request.paused)
        .await?;
    let device = pairing
        .store
        .pairing_device(device_id)
        .await?
        .ok_or(PairingError::code(PairingErrorCode::SessionStale))?;
    Ok(Json(pairing.code_status(&device)))
}

/// `POST /v1/pair/code/rotate`: at most once per 24 hours of server time. The
/// old code dies at once and existing membership is unchanged.
pub(super) async fn rotate(
    State(state): State<AppState>,
    headers: HeaderMap,
    PairJson(request): PairJson<RotateCodeRequest>,
) -> PairingResult<Json<CodeStatus>> {
    let (pairing, caller) = gate(&state, &headers).await?;
    require_current(&caller)?;
    require_operation_id(&request.operation_id)?;
    let hash = &caller.access.session.secret_hash;
    let print = fingerprint(OperationKind::Rotate.as_str(), hash, &[]);
    pairing
        .store
        .rotate_code(
            RotateInput {
                meta: OperationMeta {
                    id: &request.operation_id,
                    fingerprint: &print,
                    actor_device_id: &caller.access.device.id,
                    actor_secret_hash: hash,
                    now: now(),
                },
                generation: caller.access.session.generation,
            },
            pairing.derive_lookup.as_ref(),
        )
        .await
        .map_err(|error| match error {
            pocox_store::StoreError::Refused(Refusal::TooSoon {
                retry_after,
            }) => PairingError::retry_later(PairingErrorCode::RateLimited, retry_after),
            other => other.into(),
        })?;
    let device = pairing
        .store
        .pairing_device(&caller.access.device.id)
        .await?
        .ok_or(PairingError::code(PairingErrorCode::SessionStale))?;
    Ok(Json(pairing.code_status(&device)))
}
