//! Everything else a device does with its identity: preparing a code,
//! activating, previews, its group and recovery requests.
//!
//! Preparing changes nothing but the device store. Activation is the user's
//! explicit choice, the moment a hardware hint is read, and the moment this
//! identity becomes the active account here.

use anyhow::{bail, Result};
use pocox_account_proto::pairing::{
    normalize_code, ActivateRequest, ActivationStatus, CodeStatus, CreateRestoreRequest,
    DecideRestoreRequest, DeviceListResponse, DeviceSession, HardwareHint, PairingErrorCode,
    PreviewRequest, PreviewResponse, RenameDeviceRequest, RestoreRequestView, RotateCodeRequest,
    SetCodePausedRequest, PAIR_URI_PREFIX,
};
use pocox_core::pairing::{
    derive_hint, os_account, read_local_hardware_id, HintSource, RawHardwareId,
};
use reqwest::Method;

use super::error::{code_of, PairingError};
use super::identity::Identity;
use super::session::{self, Apply};
use crate::engine::config::load_config;

/// The longest invitation worth parsing.
const MAX_INVITATION_BYTES: usize = 128;

/// A hardware identifier a platform adapter read through the bridge. Mobile
/// only; a desktop reads its own. Used to derive a key and then dropped.
#[derive(Clone)]
pub struct NativeHint {
    /// `android_id`.
    pub source: String,
    /// The raw identifier.
    pub raw_id: String,
}

impl std::fmt::Debug for NativeHint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NativeHint")
            .field("source", &self.source)
            .finish_non_exhaustive()
    }
}

/// A device ready to show its code.
#[derive(Debug, Clone)]
pub struct Prepared {
    /// Its session, staged unless this identity is already the active account.
    pub session: DeviceSession,
    /// Its current code.
    pub code: CodeStatus,
}

/// The hint for `identity`, read at most once per explicit action.
pub async fn hardware_hint(
    identity: &Identity,
    native: Option<NativeHint>,
) -> Option<HardwareHint> {
    let raw = match native {
        Some(native) => HintSource::from_label(&native.source)
            .and_then(|source| RawHardwareId::new(source, &native.raw_id)),
        None => tokio::task::spawn_blocking(read_local_hardware_id)
            .await
            .ok()
            .flatten(),
    }?;
    let derived = derive_hint(&raw, identity.store.key(), &os_account());
    Some(HardwareHint {
        key: derived.key,
        source: Some(derived.source.to_string()),
    })
}

/// A session for this identity right now, keeping `[account]` current if it is
/// the active account here and leaving it alone if not.
async fn current_session(identity: &Identity, label: Option<&str>) -> Result<DeviceSession> {
    let record = identity.store.ensure_secret()?;
    let fresh = identity.mint(&record, label).await?;
    let config = load_config(&identity.support)?;
    if identity.is_active(&config) {
        session::apply(identity, fresh.clone(), Apply::Refresh).await?;
    }
    Ok(fresh)
}

/// Find or create this device's identity and its code. A device with no secret
/// starts as new and sends no hint. Changes no active account or hosting.
pub async fn prepare(identity: &Identity, label: Option<&str>) -> Result<Prepared> {
    let session = current_session(identity, label).await?;
    let code = code(identity).await?;
    Ok(Prepared {
        session,
        code,
    })
}

/// Get started, or Continue: mark this device activated, bind its hint and make
/// this identity the active account here.
pub async fn activate(identity: &Identity, native: Option<NativeHint>) -> Result<DeviceSession> {
    identity.store.ensure_secret()?;
    let hint = hardware_hint(identity, native).await;
    let _: ActivationStatus = identity
        .call("/v1/pair/activate", |client, token| {
            client
                .request(Method::POST, "/v1/pair/activate")
                .bearer_auth(token)
                .json(&ActivateRequest {
                    hint: hint.clone(),
                })
        })
        .await?;
    let record = identity.store.ensure_secret()?;
    let fresh = identity.mint(&record, None).await?;
    session::apply(identity, fresh.clone(), Apply::Adopt).await?;
    Ok(fresh)
}

/// This device's current code.
pub async fn code(identity: &Identity) -> Result<CodeStatus> {
    identity
        .call("/v1/pair/code", |client, token| {
            client
                .request(Method::GET, "/v1/pair/code")
                .bearer_auth(token)
        })
        .await
}

/// Pause or resume linking through this device's code.
pub async fn set_paused(identity: &Identity, paused: bool) -> Result<CodeStatus> {
    identity
        .call("PATCH /v1/pair/code", |client, token| {
            client
                .request(Method::PATCH, "/v1/pair/code")
                .bearer_auth(token)
                .json(&SetCodePausedRequest {
                    paused,
                })
        })
        .await
}

/// Replace this device's code, allowed once per day. A lost response needs no
/// saved identity: the code route shows the result.
pub async fn rotate(identity: &Identity) -> Result<CodeStatus> {
    let operation_id = uuid::Uuid::new_v4().simple().to_string();
    identity
        .call("/v1/pair/code/rotate", |client, token| {
            client
                .request(Method::POST, "/v1/pair/code/rotate")
                .bearer_auth(token)
                .json(&RotateCodeRequest {
                    operation_id: operation_id.clone(),
                })
        })
        .await
}

/// The code in a scanned invitation. Only `pocox://pair?c=<code>` qualifies:
/// scanning never executes anything, and a link cannot name another backend.
pub fn parse_invitation(uri: &str) -> Option<String> {
    if uri.len() > MAX_INVITATION_BYTES {
        return None;
    }
    normalize_code(uri.strip_prefix(PAIR_URI_PREFIX)?)
}

/// Look up a typed code. Changes nothing; what comes back must be confirmed.
pub async fn preview(identity: &Identity, code: &str) -> Result<PreviewResponse> {
    let Some(code) = normalize_code(code) else {
        return Err(PairingError {
            code: PairingErrorCode::CodeUnknown,
            status: 404,
            retry_after: None,
            operation_id: None,
            grace_deadline: None,
        }
        .into());
    };
    identity
        .call("/v1/pair/preview", |client, token| {
            client
                .request(Method::POST, "/v1/pair/preview")
                .bearer_auth(token)
                .json(&PreviewRequest {
                    code: code.clone(),
                })
        })
        .await
}

/// One page of this device's group, with recovery requests a member can answer.
pub async fn devices(identity: &Identity, cursor: Option<&str>) -> Result<DeviceListResponse> {
    identity
        .call("/v1/devices", |client, token| {
            let mut request = client
                .request(Method::GET, "/v1/devices")
                .bearer_auth(token);
            if let Some(cursor) = cursor {
                request = request.query(&[("cursor", cursor)]);
            }
            request
        })
        .await
}

/// Rename a device in this group.
pub async fn rename(identity: &Identity, device_id: &str, name: &str) -> Result<()> {
    identity
        .call_empty("PATCH /v1/devices", |client, token| {
            client
                .request(Method::PATCH, &format!("/v1/devices/{device_id}"))
                .bearer_auth(token)
                .json(&RenameDeviceRequest {
                    name: name.to_string(),
                })
        })
        .await
}

/// Answer the exact recovery request a member sees. Allowing changes nothing
/// until the requester confirms.
pub async fn decide(
    identity: &Identity,
    device_id: &str,
    request_id: &str,
    allow: bool,
) -> Result<()> {
    let operation_id = uuid::Uuid::new_v4().simple().to_string();
    identity
        .call_empty("POST /v1/devices/restore", |client, token| {
            client
                .request(Method::POST, &format!("/v1/devices/{device_id}/restore"))
                .bearer_auth(token)
                .json(&DecideRestoreRequest {
                    request_id: request_id.to_string(),
                    operation_id: operation_id.clone(),
                    allow,
                })
        })
        .await
}

/// Ask this device's former group to let it back. Reveals nothing about that
/// group. With no hardware source there is nothing to ask with, which reads as
/// nothing found: the code path stays open.
pub async fn request_restore(
    identity: &Identity,
    native: Option<NativeHint>,
) -> Result<RestoreRequestView> {
    let Some(hint) = hardware_hint(identity, native).await else {
        return Err(PairingError {
            code: PairingErrorCode::NotFound,
            status: 404,
            retry_after: None,
            operation_id: None,
            grace_deadline: None,
        }
        .into());
    };
    identity
        .call("/v1/pair/restore/requests", |client, token| {
            client
                .request(Method::POST, "/v1/pair/restore/requests")
                .bearer_auth(token)
                .json(&CreateRestoreRequest {
                    hint: hint.clone(),
                })
        })
        .await
}

/// Where this device's recovery request stands.
pub async fn poll_restore(identity: &Identity, request_id: &str) -> Result<RestoreRequestView> {
    identity
        .call("/v1/pair/restore", |client, token| {
            client
                .request(Method::GET, &format!("/v1/pair/restore/{request_id}"))
                .bearer_auth(token)
        })
        .await
}

/// A superseded or unknown identity's way forward: discard the dead secret
/// under the store's lock and start as a new inactive device, which can then
/// recover or carry on. Only ever on the user's choice, and refused while the
/// secret still works, so nothing reclaims a device in a loop or throws away a
/// live identity.
pub async fn start_over(identity: &Identity, label: Option<&str>) -> Result<Prepared> {
    let record = identity.store.ensure_secret()?;
    if !record.registered {
        bail!("this device has not been set up yet; there is nothing to start over from");
    }
    match identity.client.refresh(record.secret()).await {
        Ok(_) => bail!("this device's identity still works; nothing was discarded"),
        Err(error)
            if matches!(
                code_of(&error),
                Some(PairingErrorCode::DeviceSuperseded | PairingErrorCode::DeviceUnknown)
            ) =>
        {
            identity.store.replace_dead_secret(record.secret())?;
        },
        Err(error) => return Err(error),
    }
    prepare(identity, label).await
}
