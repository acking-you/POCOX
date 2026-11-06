//! What a pairing screen shows: one reading of this device's identity.

use anyhow::Result;
use pocox_account_proto::pairing::{DeviceSession, MembershipChangeKind, PairingErrorCode};
use pocox_core::pairing::{OperationState, StoredOperation};

use super::error::{no_device_error, refusal_of};
use super::identity::Identity;
use super::operations;
use super::session::{self, Apply};
use crate::engine::config::load_config;

/// Where this device's identity stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairingState {
    /// No secret here: opening sign-in will prepare one.
    NoDevice,
    /// A session and a code, and no relay authority until the user continues.
    Inactive,
    /// Set up.
    Active,
    /// Another device removed this one. Hosts nothing until Continue.
    Removed,
    /// This secret was replaced. Offer recovery or starting as new.
    Superseded,
    /// Nothing is known about this secret. Offer starting anew.
    Unknown,
    /// A membership change is under way; read again shortly.
    Pending,
}

/// One reading of this device's identity.
#[derive(Debug, Clone)]
pub struct PairingStatus {
    /// Where it stands.
    pub state: PairingState,
    /// The canonical backend.
    pub backend: String,
    /// The session, when one could be issued.
    pub session: Option<DeviceSession>,
    /// Whether `[account]` here is this identity.
    pub active_here: bool,
    /// For a superseded secret, when its overlap ends (unix seconds).
    pub grace_deadline: Option<i64>,
    /// Membership changes whose result is not in yet.
    pub pending: Vec<StoredOperation>,
    /// Membership changes that recently turned out not to have happened.
    pub failed: Vec<StoredOperation>,
    /// The login of a GitHub session set aside here, if any.
    pub parked_github: Option<String>,
}

/// Read this device's state, settling what can be settled. Creates no secret: a
/// device with none stays that way until something prepares one. A saved secret
/// the backend has yet to acknowledge is retried, which is idempotent.
pub async fn status(identity: &Identity) -> Result<PairingStatus> {
    session::sign_out_if_orphaned(identity).await?;
    let parked_github = parked(identity);
    if identity.read()?.is_none() {
        return Ok(PairingStatus {
            state: PairingState::NoDevice,
            backend: identity.backend().to_string(),
            session: None,
            active_here: identity.is_active(&load_config(&identity.support)?),
            grace_deadline: None,
            pending: Vec::new(),
            failed: Vec::new(),
            parked_github,
        });
    }
    operations::settle(identity).await?;
    let config = load_config(&identity.support)?;
    let active_here = identity.is_active(&config);
    let account = session::active_account(&config);
    let record = identity.read()?.ok_or_else(no_device_error)?;
    let minted = identity.mint(&record, None).await;
    let mut grace_deadline = None;
    let (state, session) = match minted {
        Ok(fresh) => {
            if active_here {
                session::apply(identity, fresh.clone(), Apply::Refresh, &account).await?;
            }
            (state_of(&fresh), Some(fresh))
        },
        Err(error) => {
            let Some(refusal) = refusal_of(&error) else {
                return Err(error);
            };
            grace_deadline = refusal.grace_deadline;
            let state = match refusal.code {
                PairingErrorCode::DeviceSuperseded => PairingState::Superseded,
                PairingErrorCode::DeviceUnknown => PairingState::Unknown,
                PairingErrorCode::TransitionPending => PairingState::Pending,
                _ => return Err(error),
            };
            (state, None)
        },
    };
    let operations = identity
        .read()?
        .map(|record| record.operations)
        .unwrap_or_default();
    let of_state = |state: OperationState| {
        operations
            .iter()
            .filter(|operation| operation.state == state)
            .cloned()
            .collect()
    };
    Ok(PairingStatus {
        state,
        backend: identity.backend().to_string(),
        session,
        active_here,
        grace_deadline,
        pending: of_state(OperationState::Pending),
        failed: of_state(OperationState::Failed),
        parked_github,
    })
}

/// The GitHub session set aside here. Damage to that file is not a reason to
/// fail a reading of this device.
fn parked(identity: &Identity) -> Option<String> {
    super::parked::parked_github(&identity.support).unwrap_or_else(|error| {
        tracing::warn!("reading the set-aside GitHub session: {error:#}");
        None
    })
}

fn state_of(session: &DeviceSession) -> PairingState {
    if session.activated {
        return PairingState::Active;
    }
    match session.membership_change.map(|change| change.kind) {
        Some(MembershipChangeKind::Removed) => PairingState::Removed,
        _ => PairingState::Inactive,
    }
}
