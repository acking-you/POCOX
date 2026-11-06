//! Durable membership changes: link, leave, removal, restore.
//!
//! The backend's commit is authoritative even when its response is lost, so
//! each operation's identity is saved in the device store before it is sent and
//! stays until local configuration has caught up. After that first send a
//! mutation is never sent again: its result is read with the secret, and
//! applied only if this installation still has the account it started from.
//!
//! Any installation sharing the store may read a result. Only the one that
//! started a move may adopt it, which is what the day it is left to that
//! installation is for; it blocks nothing else meanwhile.

use std::time::Duration;

use anyhow::Result;
use pocox_account_proto::pairing::{
    ConfirmRestoreRequest, DeviceSession, HardwareHint, LeaveRequest, LinkRequest, OperationStatus,
    OperationView, PairingErrorCode, RestoreIntent,
};
use pocox_core::pairing::{OperationKind, OperationState, StoredOperation};
use reqwest::{Method, RequestBuilder};

use super::client::Client;
use super::error::{code_of, refusal_of, PairingError};
use super::identity::Identity;
use super::session::{self, Apply};
use crate::engine::config::load_config;

/// How long an operation the backend does not know can still be in flight: past
/// the client's own request timeout, it was never received.
const UNKNOWN_GRACE_SECS: i64 = 120;
/// How long the backend keeps a finished operation to be read.
const BACKEND_RETENTION_SECS: i64 = 7 * 24 * 60 * 60;
/// How long a completed move waits for the installation that started it to
/// adopt it.
const ADOPTION_WINDOW_SECS: i64 = 24 * 60 * 60;
/// How long an operation that did not happen stays to be heard about.
const FAILED_RETENTION_SECS: i64 = 24 * 60 * 60;
/// How many times local configuration tries to catch up before leaving it to
/// the next pass.
const CATCH_UP_TRIES: u64 = 3;

/// Where an operation stands for the caller.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OperationOutcome {
    /// The operation's id.
    pub id: String,
    /// What it does.
    pub kind: OperationKind,
    /// Where it stands. Never repeat a pending action: read it again.
    /// `Unknown` means its result can no longer be learned: the device's own
    /// state says where it stands.
    pub status: OperationStatus,
    /// Why it failed: the backend's code.
    pub error: Option<String>,
    /// For a completed one, whether this installation has caught up with it. If
    /// not the commit still stands, and the next reading tries again.
    pub caught_up: bool,
}

impl OperationOutcome {
    fn of(operation: &StoredOperation, status: OperationStatus) -> Self {
        Self {
            id: operation.id.clone(),
            kind: operation.kind,
            status,
            error: None,
            caught_up: true,
        }
    }

    fn failed(operation: &StoredOperation, error: Option<String>) -> Self {
        Self {
            error,
            ..Self::of(operation, OperationStatus::Failed)
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

fn mark(identity: &Identity, id: &str, state: OperationState, error: Option<String>) -> Result<()> {
    identity.store.update(|record| {
        for stored in &mut record.operations {
            if stored.id == id {
                stored.state = state;
                stored.error.clone_from(&error);
            }
        }
    })?;
    Ok(())
}

/// Save `kind`'s identity, send it once, and report where it stands.
async fn run(
    identity: &Identity,
    kind: OperationKind,
    what: &str,
    build: impl Fn(&Client, &str, &str) -> RequestBuilder,
) -> Result<OperationOutcome> {
    identity.require_record().await?;
    settle(identity).await?;
    let record = identity.require_record().await?;
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
        error: None,
    };
    identity
        .store
        .update(|record| record.operations.push(operation.clone()))?;
    let answer: Result<OperationView> = identity
        .call(what, |client, token| build(client, token, &operation.id))
        .await;
    match answer {
        Ok(view) => conclude(identity, &operation, view, false).await,
        Err(error) => match refusal_of(&error) {
            Some(refusal)
                if refusal.code == PairingErrorCode::TransitionPending
                    && refusal.operation_id.as_deref() == Some(operation.id.as_str()) =>
            {
                Ok(OperationOutcome::of(&operation, OperationStatus::Pending))
            },
            Some(refusal) if refusal.is_definite() => {
                // The backend refused it, so it did not happen.
                forget(identity, &operation.id)?;
                Err(error)
            },
            _ => {
                // No answer, or a server failure the commit may still follow. Only its
                // result can say, and this send is never repeated.
                tracing::warn!("no clear answer to {what}; reading its result: {error:#}");
                settle_one(identity, &operation, false).await
            },
        },
    }
}

/// Act on the backend's word about `operation`.
async fn conclude(
    identity: &Identity,
    operation: &StoredOperation,
    view: OperationView,
    adoption_open: bool,
) -> Result<OperationOutcome> {
    match view.status {
        OperationStatus::Completed => {
            Ok(completed(identity, operation, view.session, adoption_open).await)
        },
        // A status this client does not know is no reason to call it over.
        OperationStatus::Pending | OperationStatus::Unknown => {
            Ok(OperationOutcome::of(operation, OperationStatus::Pending))
        },
        OperationStatus::Failed => {
            let error = view.error.map(|code| code.as_str().to_string());
            mark(identity, &operation.id, OperationState::Failed, error.clone())?;
            Ok(OperationOutcome::failed(operation, error))
        },
    }
}

/// The commit stands whatever happens here. Local configuration gets a few
/// tries and the store keeps the operation for the next pass.
async fn completed(
    identity: &Identity,
    operation: &StoredOperation,
    session: Option<DeviceSession>,
    adoption_open: bool,
) -> OperationOutcome {
    let mut caught_up = false;
    for attempt in 0..CATCH_UP_TRIES {
        if attempt > 0 {
            tokio::time::sleep(Duration::from_secs(attempt)).await;
        }
        match catch_up(identity, operation, session.clone(), adoption_open).await {
            Ok(()) => {
                caught_up = true;
                break;
            },
            Err(error) => {
                tracing::warn!("local state has yet to catch up: {error:#}");
                if matches!(
                    code_of(&error),
                    Some(PairingErrorCode::DeviceSuperseded | PairingErrorCode::DeviceUnknown)
                ) {
                    // This secret is over, so nothing here ever will catch up.
                    if let Err(error) = forget(identity, &operation.id) {
                        tracing::warn!("forgetting a finished operation: {error:#}");
                    }
                    break;
                }
            },
        }
    }
    OperationOutcome {
        caught_up,
        ..OperationOutcome::of(operation, OperationStatus::Completed)
    }
}

/// The operation committed: refresh, bring this installation along if it is the
/// one that started it and still on the account it started from, and then let
/// go of the identity, unless it is still waiting for that installation.
async fn catch_up(
    identity: &Identity,
    operation: &StoredOperation,
    session: Option<DeviceSession>,
    adoption_open: bool,
) -> Result<()> {
    mark(identity, &operation.id, OperationState::Completed, None)?;
    let config = load_config(&identity.support)?;
    let account = session::active_account(&config);
    let fresh = match session {
        Some(fresh) => fresh,
        None => {
            let record = identity.read()?.ok_or_else(super::error::no_device_error)?;
            identity.mint(&record, None).await?
        },
    };
    let started_here = operation.initiator == installation(identity)
        && session::same_account(&operation.active_before, &config);
    let moves_here = matches!(
        operation.kind,
        OperationKind::Link | OperationKind::Restore | OperationKind::Retake
    );
    if started_here && moves_here {
        session::apply(identity, fresh, Apply::Adopt, &operation.active_before).await?;
    } else if identity.is_active(&config) {
        session::apply(identity, fresh, Apply::Refresh, &account).await?;
    }
    if adoption_open {
        return Ok(());
    }
    forget(identity, &operation.id)
}

/// Read one operation's result with the secret.
async fn settle_one(
    identity: &Identity,
    operation: &StoredOperation,
    adoption_open: bool,
) -> Result<OperationOutcome> {
    if operation.state == OperationState::Completed {
        return Ok(completed(identity, operation, None, adoption_open).await);
    }
    let Some(record) = identity.read()? else {
        return Ok(OperationOutcome::of(operation, OperationStatus::Pending));
    };
    match identity
        .client
        .read_operation(record.secret(), &operation.id)
        .await
    {
        Ok(view) => conclude(identity, operation, view, adoption_open).await,
        Err(error) => match code_of(&error) {
            Some(PairingErrorCode::OperationUnknown)
                if now() - operation.started_at < UNKNOWN_GRACE_SECS =>
            {
                Ok(OperationOutcome::of(operation, OperationStatus::Pending))
            },
            Some(PairingErrorCode::OperationUnknown)
                if now() - operation.started_at < BACKEND_RETENTION_SECS =>
            {
                // The backend keeps a finished one this long, so it never arrived.
                let error = Some(PairingErrorCode::OperationUnknown.as_str().to_string());
                mark(identity, &operation.id, OperationState::Failed, error.clone())?;
                Ok(OperationOutcome::failed(operation, error))
            },
            Some(
                PairingErrorCode::OperationUnknown
                | PairingErrorCode::DeviceSuperseded
                | PairingErrorCode::DeviceUnknown,
            ) => {
                // Purged since, or this secret can no longer ask: how it ended
                // cannot be learned. The next refresh says where this device stands.
                forget(identity, &operation.id)?;
                Ok(OperationOutcome::of(operation, OperationStatus::Unknown))
            },
            _ => {
                tracing::debug!("operation result not available yet: {error:#}");
                Ok(OperationOutcome::of(operation, OperationStatus::Pending))
            },
        },
    }
}

/// Reconcile every saved operation: at start, before a new one and whenever a
/// pending screen asks. Reads results only, and never adopts another
/// installation's move while it can still adopt that itself.
pub async fn settle(identity: &Identity) -> Result<Vec<OperationOutcome>> {
    let Some(record) = identity.read()? else {
        return Ok(Vec::new());
    };
    let here = installation(identity);
    let mut outcomes = Vec::with_capacity(record.operations.len());
    for operation in &record.operations {
        let adoption_open =
            operation.initiator != here && now() - operation.started_at < ADOPTION_WINDOW_SECS;
        let outcome = match operation.state {
            OperationState::Failed => OperationOutcome::failed(operation, operation.error.clone()),
            OperationState::Completed if adoption_open => {
                OperationOutcome::of(operation, OperationStatus::Completed)
            },
            _ => settle_one(identity, operation, adoption_open).await?,
        };
        outcomes.push(outcome);
    }
    let old_failure = |operation: &StoredOperation| {
        operation.state == OperationState::Failed
            && now() - operation.started_at >= FAILED_RETENTION_SECS
    };
    if record.operations.iter().any(old_failure) {
        identity.store.update(|record| {
            record
                .operations
                .retain(|operation| !old_failure(operation));
        })?;
    }
    Ok(outcomes)
}

/// The backend's word on `outcome`'s operation, for one no longer in the store:
/// its absence alone says nothing about how it ended. `None` when that cannot
/// be learned.
pub async fn read_outcome(
    identity: &Identity,
    outcome: &OperationOutcome,
) -> Option<OperationOutcome> {
    let record = identity.read().ok()??;
    let view = identity
        .client
        .read_operation(record.secret(), &outcome.id)
        .await
        .ok()?;
    let status = match view.status {
        OperationStatus::Unknown => OperationStatus::Pending,
        status => status,
    };
    Some(OperationOutcome {
        status,
        error: view.error.map(|code| code.as_str().to_string()),
        caught_up: true,
        ..outcome.clone()
    })
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
