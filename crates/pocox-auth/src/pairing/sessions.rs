//! Generation-aware device sessions.
//!
//! A device JWT is only half the check. Every route also confirms the row, the
//! user, the generation, the session's state and any pending transition,
//! because a token signed an hour ago knows none of what has happened since.

use pocox_account_proto::key::SERVICE_NS_PREFIX;
use pocox_account_proto::pairing::{
    secret_is_well_formed, DeviceSession, MembershipChange, MembershipChangeKind,
};
use pocox_store::pairing::{Device, DeviceAccess, SessionState, TransitionKind};
use uuid::Uuid;

use super::keys::{hash_device_secret, PairingKeys};
use crate::jwt::{Claims, Principal};
use crate::{Auth, AuthError, Result};

const PAIRING_KEY_VERIFICATION: &str = "pairing_key_check";

/// What a device session may do right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionMode {
    /// A current session.
    Current,
    /// A retiring session, inside its overlap. Accepted only on grace-eligible
    /// routes, and never again at or after the deadline.
    Retiring {
        /// The generation's fixed deadline.
        deadline: i64,
    },
}

/// An authenticated device, re-derived from the database for this request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceCaller {
    /// The device, the session generation presented and the current user.
    pub access: DeviceAccess,
    /// What that generation may do.
    pub mode: SessionMode,
}

fn membership_change_of(device: &Device) -> Option<MembershipChange> {
    let kind = match device.last_transition_kind? {
        TransitionKind::Linked => MembershipChangeKind::Linked,
        TransitionKind::Left => MembershipChangeKind::Left,
        TransitionKind::Removed => MembershipChangeKind::Removed,
        TransitionKind::Restored | TransitionKind::Retaken => return None,
    };
    Some(MembershipChange {
        kind,
        at: device.last_transition_at?,
    })
}

impl Auth {
    /// The pairing keys, or `None` when pairing is disabled.
    pub fn pairing_keys(&self) -> Option<&PairingKeys> {
        self.pairing.as_ref()
    }

    /// Check the pairing key against this database before serving anything.
    ///
    /// On a populated database a changed key is not a harmless environment
    /// update: derived codes would disagree with stored lookups, and
    /// hardware indexes use the old key too. An empty database adopts the
    /// key it is given.
    pub async fn verify_pairing_key(&self) -> Result<()> {
        let Some(keys) = &self.pairing else {
            return Ok(());
        };
        let expected = keys.verification_value();
        match self
            .store
            .pairing_metadata(PAIRING_KEY_VERIFICATION)
            .await?
        {
            Some(stored) if stored == expected => Ok(()),
            Some(_) => Err(AuthError::PairingKeyMismatch),
            None if self.store.has_pairing_state().await? => Err(AuthError::PairingKeyMismatch),
            None => {
                self.store
                    .set_pairing_metadata(PAIRING_KEY_VERIFICATION, &expected)
                    .await?;
                Ok(())
            },
        }
    }

    /// Mint a session for a device's current generation.
    ///
    /// Callers reach this only through a check that the presented secret is
    /// still current; stored results never hold one of these.
    pub fn issue_device_session(&self, access: &DeviceAccess, now: i64) -> Result<DeviceSession> {
        let user_id = &access.user.id;
        let claims = Claims {
            sub: user_id.clone(),
            ns: format!("{SERVICE_NS_PREFIX}:{user_id}"),
            login: access.device.label.clone(),
            gh_id: None,
            did: Some(access.device.id.clone()),
            dgen: Some(access.session.generation),
            iat: now,
            exp: now + self.jwt_ttl_secs,
            jti: Uuid::new_v4().simple().to_string(),
        };
        Ok(DeviceSession {
            token: self.jwt.issue(&claims)?,
            expires_in_secs: self.jwt_ttl_secs.max(0) as u64,
            login: access.device.label.clone(),
            account_id: user_id.clone(),
            device_id: access.device.id.clone(),
            generation: access.session.generation,
            activated: access.device.activated_at.is_some(),
            membership_change: membership_change_of(&access.device),
        })
    }

    /// Exchange a device's current secret for a session.
    ///
    /// Checks the current session first, so a historical hash cannot override
    /// it. A superseded secret can never mint a token, and while a
    /// transition is under way none is minted at all: the device learns the
    /// outcome after it commits.
    pub async fn refresh_device(&self, secret: &str, now: i64) -> Result<DeviceSession> {
        if self.pairing.is_none() {
            return Err(AuthError::PairingDisabled);
        }
        if !secret_is_well_formed(secret) {
            return Err(AuthError::DeviceUnknown);
        }
        let hash = hash_device_secret(secret);
        let Some(access) = self.store.device_by_secret(&hash).await? else {
            return Err(match self.store.superseded_secret(&hash).await? {
                Some(grace_deadline) => AuthError::DeviceSuperseded {
                    grace_deadline,
                },
                None => AuthError::DeviceUnknown,
            });
        };
        if access.device.pending_transition_id.is_some() || access.session.grace_deadline.is_some()
        {
            // A device being removed or restored by someone else learns the outcome
            // from a later refresh: that operation is not its own to read.
            let operation_id = match &access.device.pending_transition_id {
                Some(id) => self
                    .store
                    .operation(id)
                    .await?
                    .filter(|operation| operation.actor_secret_hash == hash)
                    .map(|operation| operation.id),
                None => None,
            };
            return Err(AuthError::TransitionPending {
                operation_id,
            });
        }
        self.store.touch_device(&access.device.id, now).await?;
        self.issue_device_session(&access, now)
    }

    /// Re-derive what this device token may do, from current state.
    ///
    /// A generation that is revoked, past its deadline or simply gone
    /// authorizes nothing, and returning to an earlier user can never
    /// revive one: generations only move forward.
    pub async fn authenticate_device(&self, claims: &Claims, now: i64) -> Result<DeviceCaller> {
        if self.pairing.is_none() {
            return Err(AuthError::PairingDisabled);
        }
        // The token library allows a minute's leeway. A device session gets none: its
        // secret refreshes it at no cost, and an expired token is an expired token.
        if now >= claims.exp {
            return Err(AuthError::SessionStale);
        }
        let Some(Principal::Device {
            device_id,
            generation,
        }) = claims.principal()
        else {
            return Err(AuthError::BadPrincipal);
        };
        let access = self
            .store
            .device_access(device_id, generation)
            .await?
            .ok_or(AuthError::SessionStale)?;
        if access.session.original_user_id != claims.sub
            || access.device.user_id != access.session.original_user_id
        {
            return Err(AuthError::SessionStale);
        }
        let mode = match (access.session.state, access.session.grace_deadline) {
            (SessionState::Revoked, _) | (SessionState::Grace, None) => {
                return Err(AuthError::SessionStale);
            },
            (SessionState::Current, None) => SessionMode::Current,
            (SessionState::Current | SessionState::Grace, Some(deadline)) => {
                if now >= deadline {
                    return Err(AuthError::SessionStale);
                }
                SessionMode::Retiring {
                    deadline,
                }
            },
        };
        if mode == SessionMode::Current {
            self.store.touch_device(&access.device.id, now).await?;
        }
        Ok(DeviceCaller {
            access,
            mode,
        })
    }
}
