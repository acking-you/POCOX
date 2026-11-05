//! Durable membership changes: link, leave, removal, restore.
//!
//! The backend's commit is authoritative even when its response is lost, so
//! each operation's identity is saved in the device store before it is sent and
//! stays until local configuration has caught up. After that first send a
//! mutation is never sent again: its result is read with the secret, and
//! applied only if this installation still has the account it started from.

use anyhow::Result;
use pocox_account_proto::pairing::{
    ConfirmRestoreRequest, HardwareHint, LeaveRequest, LinkRequest, OperationStatus, OperationView,
    PairingErrorCode, RestoreIntent,
};
use pocox_core::pairing::{OperationKind, OperationState, StoredOperation};
use reqwest::{Method, RequestBuilder};

use super::client::Client;
use super::error::PairingError;
use super::identity::Identity;
use super::session::{self, Apply};
use crate::engine::config::load_config;

/// How long an operation the backend does not know can still be in flight: past
/// the client's own request timeout, it was never received.
const UNKNOWN_GRACE_SECS: i64 = 120;
/// Another installation's unfinished operation is left to it this long.
const OTHER_INSTALLATION_GRACE_SECS: i64 = 24 * 60 * 60;

/// Where an operation stands for the caller.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OperationOutcome {
    /// The operation's id.
    pub id: String,
    /// What it does.
    pub kind: OperationKind,
    /// Where it stands. Never repeat a pending action: read it again.
    pub status: OperationStatus,
    /// Why it failed.
    pub error: Option<PairingErrorCode>,
}

impl OperationOutcome {
    fn of(operation: &StoredOperation, status: OperationStatus) -> Self {
        Self {
            id: operation.id.clone(),
            kind: operation.kind,
            status,
            error: None,
        }
    }
}

/// What a restore confirms.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RestoreTarget {
    /// A device the user picked from a code's preview.
    Ticket {
        /// The preview's ticket.
        ticket: String,
        /// The group's device the user says this is.
        device_id: String,
    },
    /// A request a member approved.
    Approved {
        /// The approved request's id.
        request_id: String,
    },
}

fn installation(identity: &Identity) -> String {
    let digest =
        pocox_core::history_sync::digest_bytes(identity.support.to_string_lossy().as_bytes());
    digest[..16].to_string()
}

fn now() -> i64 {
    chrono::Utc::now().timestamp()
}

fn new_operation_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}

fn forget(identity: &Identity, id: &str) -> Result<()> {
    identity.store.update(|record| {
        record.operations.retain(|operation| operation.id != id);
    })?;
    Ok(())
}

fn refusal_of(error: &anyhow::Error) -> Option<&PairingError> {
    error
        .chain()
        .find_map(|cause| cause.downcast_ref::<PairingError>())
}

/// Save `kind`'s identity, send it once, and report where it stands.
async fn run(
    identity: &Identity,
    kind: OperationKind,
    what: &str,
    build: impl Fn(&Client, &str, &str) -> RequestBuilder,
) -> Result<OperationOutcome> {
    settle(identity).await?;
    let record = identity.store.ensure_secret()?;
    if let Some(open) = record
        .operations
        .iter()
        .find(|operation| operation.state == OperationState::Pending)
    {
        return Err(PairingError {
            code: PairingErrorCode::TransitionPending,
            status: 409,
            retry_after: None,
            operation_id: Some(open.id.clone()),
            grace_deadline: None,
        }
        .into());
    }
    let config = load_config(&identity.support)?;
    let operation = StoredOperation {
        id: new_operation_id(),
        kind,
        initiator: installation(identity),
        active_before: session::active_account(&config),
        started_at: now(),
        state: OperationState::Pending,
    };
    identity
        .store
        .update(|record| record.operations.push(operation.clone()))?;
    let answer: Result<OperationView> = identity
        .call(what, |client, token| build(client, token, &operation.id))
        .await;
    match answer {
        Ok(view) => conclude(identity, &operation, view).await,
        Err(error) => match refusal_of(&error) {
            Some(refusal)
                if refusal.code == PairingErrorCode::TransitionPending
                    && refusal.operation_id.as_deref() == Some(operation.id.as_str()) =>
            {
                Ok(OperationOutcome::of(&operation, OperationStatus::Pending))
            },
            Some(_) => {
                // The backend answered, and what it refused did not happen.
                forget(identity, &operation.id)?;
                Err(error)
            },
            None => {
                // No answer: it may or may not have reached the backend. Only its
                // result can say, and this send is never repeated.
                tracing::warn!("no answer to {what}; reading its result instead: {error:#}");
                settle_one(identity, &operation).await
            },
        },
    }
}

/// Act on the backend's word about `operation`.
async fn conclude(
    identity: &Identity,
    operation: &StoredOperation,
    view: OperationView,
) -> Result<OperationOutcome> {
    match view.status {
        OperationStatus::Completed => {
            if let Err(error) = catch_up(identity, operation, view).await {
                // Committed, whatever this says: the store keeps it for the next
                // pass, and no status here claims it did not happen.
                tracing::warn!("local state has yet to catch up: {error:#}");
            }
            Ok(OperationOutcome::of(operation, OperationStatus::Completed))
        },
        OperationStatus::Pending => Ok(OperationOutcome::of(operation, OperationStatus::Pending)),
        status @ (OperationStatus::Failed | OperationStatus::Unknown) => {
            forget(identity, &operation.id)?;
            Ok(OperationOutcome {
                error: view.error,
                ..OperationOutcome::of(operation, status)
            })
        },
    }
}

/// The operation committed: refresh, bring this installation along if it is
/// still on the account it started from, and only then let go of the identity.
async fn catch_up(
    identity: &Identity,
    operation: &StoredOperation,
    view: OperationView,
) -> Result<()> {
    identity.store.update(|record| {
        for stored in &mut record.operations {
            if stored.id == operation.id {
                stored.state = OperationState::Completed;
            }
        }
    })?;
    let fresh = match view.session {
        Some(fresh) => fresh,
        None => {
            let record = identity.store.ensure_secret()?;
            identity.mint(&record, None).await?
        },
    };
    let config = load_config(&identity.support)?;
    let started_here = operation.initiator == installation(identity)
        && session::same_account(&operation.active_before, &config);
    let moves_here = matches!(
        operation.kind,
        OperationKind::Link | OperationKind::Restore | OperationKind::Retake
    );
    if started_here && moves_here {
        session::apply(identity, fresh, Apply::Adopt).await?;
    } else if identity.is_active(&config) {
        session::apply(identity, fresh, Apply::Refresh).await?;
    }
    forget(identity, &operation.id)
}

/// Read one operation's result with the secret.
async fn settle_one(identity: &Identity, operation: &StoredOperation) -> Result<OperationOutcome> {
    if operation.state == OperationState::Completed {
        return conclude(identity, operation, OperationView {
            operation_id: operation.id.clone(),
            kind: pocox_account_proto::pairing::OperationKind::Unknown,
            status: OperationStatus::Completed,
            error: None,
            session: None,
        })
        .await;
    }
    let Some(record) = identity.read()? else {
        return Ok(OperationOutcome::of(operation, OperationStatus::Pending));
    };
    match identity
        .client
        .read_operation(record.secret(), &operation.id)
        .await
    {
        Ok(view) => conclude(identity, operation, view).await,
        Err(error) => match refusal_of(&error).map(|refusal| refusal.code) {
            Some(PairingErrorCode::OperationUnknown)
                if now() - operation.started_at < UNKNOWN_GRACE_SECS =>
            {
                Ok(OperationOutcome::of(operation, OperationStatus::Pending))
            },
            Some(
                code @ (PairingErrorCode::OperationUnknown
                | PairingErrorCode::DeviceSuperseded
                | PairingErrorCode::DeviceUnknown),
            ) => {
                // It never arrived, or this secret can no longer ask. Refreshing
                // says what this device is now.
                forget(identity, &operation.id)?;
                Ok(OperationOutcome {
                    error: Some(code),
                    ..OperationOutcome::of(operation, OperationStatus::Failed)
                })
            },
            _ => {
                tracing::debug!("operation result not available yet: {error:#}");
                Ok(OperationOutcome::of(operation, OperationStatus::Pending))
            },
        },
    }
}

/// Reconcile every saved operation: at start, before a new one and whenever a
/// pending screen asks. Reads results only.
pub async fn settle(identity: &Identity) -> Result<Vec<OperationOutcome>> {
    let Some(record) = identity.read()? else {
        return Ok(Vec::new());
    };
    let here = installation(identity);
    let mut outcomes = Vec::with_capacity(record.operations.len());
    for operation in &record.operations {
        if operation.initiator != here
            && now() - operation.started_at < OTHER_INSTALLATION_GRACE_SECS
        {
            outcomes.push(OperationOutcome::of(operation, OperationStatus::Pending));
            continue;
        }
        outcomes.push(settle_one(identity, operation).await?);
    }
    Ok(outcomes)
}

/// Move this device into the group a preview showed.
pub async fn link(
    identity: &Identity,
    ticket: &str,
    leave_current: bool,
    hint: Option<HardwareHint>,
) -> Result<OperationOutcome> {
    run(identity, OperationKind::Link, "/v1/pair/link", |client, token, id| {
        client
            .request(Method::POST, "/v1/pair/link")
            .bearer_auth(token)
            .json(&LinkRequest {
                ticket: ticket.to_string(),
                operation_id: id.to_string(),
                leave_current,
                hint: hint.clone(),
            })
    })
    .await
}

/// Move this device out of its group.
pub async fn leave(identity: &Identity) -> Result<OperationOutcome> {
    run(identity, OperationKind::Leave, "/v1/pair/leave", |client, token, id| {
        client
            .request(Method::POST, "/v1/pair/leave")
            .bearer_auth(token)
            .json(&LeaveRequest {
                operation_id: id.to_string(),
            })
    })
    .await
}

/// Remove another device from this group.
pub async fn remove(identity: &Identity, device_id: &str) -> Result<OperationOutcome> {
    run(identity, OperationKind::Remove, "DELETE /v1/devices", |client, token, id| {
        client
            .request(Method::DELETE, &format!("/v1/devices/{device_id}"))
            .query(&[("operation_id", id)])
            .bearer_auth(token)
    })
    .await
}

/// Take over a previous device's identity. `retake` ends the old authorization
/// at once and rotates its code, for a suspected compromise.
pub async fn restore(
    identity: &Identity,
    target: &RestoreTarget,
    retake: bool,
    hint: Option<HardwareHint>,
) -> Result<OperationOutcome> {
    let kind = if retake { OperationKind::Retake } else { OperationKind::Restore };
    run(identity, kind, "/v1/pair/restore", |client, token, id| {
        let (ticket, target_device_id, request_id) = match target {
            RestoreTarget::Ticket {
                ticket,
                device_id,
            } => (Some(ticket.clone()), Some(device_id.clone()), None),
            RestoreTarget::Approved {
                request_id,
            } => (None, None, Some(request_id.clone())),
        };
        client
            .request(Method::POST, "/v1/pair/restore")
            .bearer_auth(token)
            .json(&ConfirmRestoreRequest {
                ticket,
                target_device_id,
                request_id,
                operation_id: id.to_string(),
                hint: hint.clone(),
                intent: if retake { RestoreIntent::Retake } else { RestoreIntent::Restore },
            })
    })
    .await
}
