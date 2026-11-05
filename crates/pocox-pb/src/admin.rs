//! Administrator operations against a relay: minting and withdrawing the
//! short-lived credentials clients actually use.
//!
//! ```text
//!     backend (holds the admin key)          relay
//!     ─────────────────────────────          ─────────────────────────────
//!     issue_credential(ttl) ───────────────▶ derive from
//!            ◀───── pbmt1_… + key id         (root, instance id, key id)
//!            │                                        │
//!            ▼                                        │
//!     hand to one client                              │
//!            │                                        ▼
//!            └── register/subscribe ────────▶ re-derive and compare
//! ```
//!
//! # Why the relay stores no client secrets
//!
//! A temporary credential is HKDF-derived from the relay's root key, its server
//! instance id, and the key id. The relay can therefore verify a credential it
//! holds no copy of, and a key id is the only per-key state. Two properties
//! fall out of that which a shared key could not offer:
//!
//! * **Revocation is immediate, not eventual.** A live credential holds a lease
//!   carrying a cancellation token, so [`revoke_credential`] tears down that
//!   client's in-flight connections rather than merely failing its next
//!   attempt.
//! * **Everything can be invalidated without touching individual keys**, by
//!   rotating the root or resetting the instance id — both inputs to the
//!   derivation.
//!
//! # Namespaces
//!
//! A namespace decides which services a credential can see. Two shapes exist:
//!
//! ```text
//!   issue_credential                   one key, its id is the namespace; every
//!                                      device of an account holds the same key
//!   allocate_namespace                 one namespace, a key per device; revoking
//!   + issue_credential_in_namespace    one leaves the others where they are
//! ```
//!
//! Check [`relay_supports_key_namespaces`] before starting anything that needs
//! the second shape: an older relay refuses it, but only once a caller has
//! already asked.
//!
//! # The one rule
//!
//! Only the administrator key may call anything here, and it must never leave
//! the process that holds it. Hand out [`IssuedCredential::credential`]; never
//! the admin key itself. The SDK enforces the first half locally — asking an
//! admin RPC of a temporary-credential session fails before any I/O — but only
//! the caller can enforce the second.

use std::time::Duration;

use anyhow::{Context, Result};

use crate::session::RelaySession;

/// A credential the relay just minted, as handed to exactly one client.
///
/// The relay returns key material only at issue time — it will not repeat a
/// secret it has already delivered — so [`Self::credential`] must be captured
/// here or re-issued.
#[derive(Debug, Clone)]
pub struct IssuedCredential {
    /// The `pbmt1_…` string the client presents to the relay.
    pub credential: String,
    /// The relay's handle for this credential, for renew and revoke.
    pub key_id: u64,
    /// The namespace the credential is confined to: the one it was issued into,
    /// or else the one its key id names.
    pub namespace: u64,
    /// Unix seconds at which the relay stops accepting it.
    pub expires_at: u64,
    /// The label it was issued with, if any.
    pub label: Option<String>,
}

impl From<pb_mapper::IssuedKey> for IssuedCredential {
    fn from(issued: pb_mapper::IssuedKey) -> Self {
        Self {
            credential: issued.credential,
            key_id: issued.key_id,
            namespace: issued.namespace,
            expires_at: issued.expires_at,
            label: issued.label,
        }
    }
}

/// Mint a temporary credential valid for `ttl`.
///
/// `session` must present the administrator key. `label` is opaque to the relay
/// and exists so an operator listing credentials can tell which client a key
/// belongs to — pass something identifying, like the account and device.
pub async fn issue_credential(
    session: &RelaySession,
    ttl: Duration,
    label: Option<String>,
) -> Result<IssuedCredential> {
    let issued = session
        .admin()?
        .issue_key(ttl, label)
        .await
        .with_context(|| format!("issuing a temporary credential on {}", session.relay_addr))?;
    Ok(issued.into())
}

/// Whether this relay can allocate namespaces, issue credentials into them and
/// keep each credential's namespace across a restart.
pub async fn relay_supports_key_namespaces(session: &RelaySession) -> Result<bool> {
    session
        .admin()?
        .supports_key_namespaces()
        .await
        .with_context(|| format!("reading the capabilities of {}", session.relay_addr))
}

/// The relay's instance id.
///
/// A reset out of a damaged snapshot changes it and starts key ids over, so a
/// stored key id means nothing under a different instance: [`renew_credential`]
/// and [`revoke_credential`] act on whichever key holds an id now. Compare this
/// first.
pub async fn relay_instance_id(session: &RelaySession) -> Result<String> {
    let status = session
        .admin()?
        .auth_status()
        .await
        .with_context(|| format!("reading the instance id of {}", session.relay_addr))?;
    Ok(status.server_instance_id)
}

/// What a backend needs to know about a relay before relying on it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayStatus {
    /// See [`relay_instance_id`].
    pub instance_id: String,
    /// See [`relay_supports_key_namespaces`].
    pub supports_key_namespaces: bool,
    /// How many temporary credentials the relay's table holds, dead ones
    /// included until it reclaims them.
    pub key_capacity: usize,
}

/// Read a relay's instance, capability and capacity in one round trip.
///
/// The relay audits every status read, so a caller wanting more than one of
/// these should ask once.
pub async fn relay_status(session: &RelaySession) -> Result<RelayStatus> {
    let status = session
        .admin()?
        .auth_status()
        .await
        .with_context(|| format!("reading the status of {}", session.relay_addr))?;
    Ok(RelayStatus {
        supports_key_namespaces: status
            .capabilities
            .iter()
            .any(|capability| capability == "key_namespaces"),
        key_capacity: status.capacity,
        instance_id: status.server_instance_id,
    })
}

/// The relay's stable error code behind `error`, if the relay refused the
/// request.
///
/// `None` means no authoritative answer arrived (a transport failure, a
/// timeout), so nothing is known about whether the request took effect.
pub fn relay_error_code(error: &anyhow::Error) -> Option<&str> {
    match error.downcast_ref::<pb_mapper::Error>() {
        Some(pb_mapper::Error::Remote {
            code, ..
        }) => Some(code),
        _ => None,
    }
}

/// Reserve a namespace that no credential owns, for
/// [`issue_credential_in_namespace`].
///
/// The relay hands a number out once, ever, so it stays safe to store against a
/// tenant after all of that tenant's credentials are gone. A caller that loses
/// the response wastes the number and asks again.
pub async fn allocate_namespace(session: &RelaySession) -> Result<u64> {
    session
        .admin()?
        .allocate_namespace()
        .await
        .with_context(|| format!("allocating a namespace on {}", session.relay_addr))
}

/// Mint a temporary credential valid for `ttl` inside an allocated namespace.
///
/// Every credential in a namespace sees the same services, and each is renewed
/// and revoked on its own. A number [`allocate_namespace`] did not return is
/// refused, including another credential's own namespace. See
/// [`issue_credential`] for `session` and `label`.
pub async fn issue_credential_in_namespace(
    session: &RelaySession,
    namespace: u64,
    ttl: Duration,
    label: Option<String>,
) -> Result<IssuedCredential> {
    let issued = session
        .admin()?
        .issue_key_in_namespace(namespace, ttl, label)
        .await
        .with_context(|| {
            format!("issuing a credential in namespace {namespace} on {}", session.relay_addr)
        })?;
    Ok(issued.into())
}

/// Set an existing credential's life to `ttl` from now, keeping its key id and
/// its text.
///
/// `ttl` may be shorter than what remains: the credential then stops at the new
/// deadline, restart included, and the relay's 10-second minimum applies.
/// Renewing also recovers a credential text its holder lost.
///
/// Preferred over issuing a replacement whenever the old credential is still
/// alive: a credential issued by [`issue_credential`] has its key id as its
/// namespace, so a fresh one would move the holder to a new namespace and
/// orphan every service already registered under the old one. Fails once the
/// credential is past renewal, at which point issuing is the only way back.
pub async fn renew_credential(
    session: &RelaySession,
    key_id: u64,
    ttl: Duration,
) -> Result<IssuedCredential> {
    let renewed = session
        .admin()?
        .renew_key(key_id, ttl)
        .await
        .with_context(|| format!("renewing credential {key_id} on {}", session.relay_addr))?;
    Ok(renewed.into())
}

/// A credential the relay still holds, without its secret.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CredentialRecord {
    /// The relay's handle for it.
    pub key_id: u64,
    /// The namespace it is confined to: the one it was issued into, or else the
    /// one its key id names.
    pub namespace: u64,
    /// The label it was issued with, if any.
    pub label: Option<String>,
    /// Unix seconds at which the relay stops accepting it.
    pub expires_at: u64,
}

/// Every credential the relay currently accepts.
///
/// Filtered to live keys: the table retains expired and revoked ones until a
/// sweep, and adopting one of those would hand a caller a namespace nothing can
/// authenticate into.
pub async fn live_credentials(session: &RelaySession) -> Result<Vec<CredentialRecord>> {
    let keys = session
        .admin()?
        .list_keys_all()
        .await
        .with_context(|| format!("listing credentials on {}", session.relay_addr))?;
    Ok(keys
        .into_iter()
        .filter(|key| key.state == "active")
        .map(|key| CredentialRecord {
            key_id: key.key_id,
            namespace: key.namespace,
            label: key.label,
            expires_at: key.expires_at,
        })
        .collect())
}

/// One registered service, as an administrator sees it.
///
/// Carries the owning `namespace` because the service NAME alone cannot be
/// trusted for attribution: a name is whatever its registrant typed, and every
/// namespace has its own. Account B can register the literal string
/// `pcxu:<account-A>:mac:app:default` inside B's namespace — the relay is right
/// to allow it, since namespaces are what isolate them — so a caller matching
/// on the name alone would show B's service as A's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServiceRecord {
    /// The relay namespace that owns the registration.
    pub namespace: u64,
    /// The service key the registrant chose.
    pub name: String,
}

/// Every service the relay knows, across all namespaces, with its owner.
///
/// Admin-scoped deliberately: a per-account credential sees only its own
/// namespace, which is right for a client but not for a backend answering "what
/// does this account have registered". That caller must filter on BOTH the
/// namespace and the key prefix — see [`ServiceRecord`] for why the name alone
/// is not enough.
pub async fn all_services(session: &RelaySession) -> Result<Vec<ServiceRecord>> {
    let services = session
        .admin()?
        .list_services_all(None)
        .await
        .with_context(|| format!("listing services on {}", session.relay_addr))?;
    Ok(services
        .into_iter()
        .map(|svc| ServiceRecord {
            namespace: svc.namespace,
            name: svc.service_name,
        })
        .collect())
}

/// Drop the relay's connections for a service in `namespace`.
///
/// For a registration whose owner is gone: the relay still holds the key and
/// the client that would have released it no longer exists. A live client
/// reconnects afterwards, so the cost is a brief interruption at worst.
///
/// `namespace` is REQUIRED, and is the account's, not the administrator's.
/// Omitting it does not mean "wherever this service lives" — the relay reads an
/// absent namespace as the unscoped one, where an administrator's own
/// registrations sit. Retiring an account's service without naming its
/// namespace therefore silently retires nothing.
pub async fn retire_service(
    session: &RelaySession,
    namespace: u64,
    service_name: &str,
) -> Result<u32> {
    session
        .admin()?
        .retire_connections(Some(namespace), service_name.to_string(), None)
        .await
        .with_context(|| {
            format!("retiring `{service_name}` in namespace {namespace} on {}", session.relay_addr)
        })
}

/// Withdraw a credential, cancelling whatever it currently holds open.
///
/// Revoking a dead key is an error at this layer: `temporary_key_not_active`
/// while its row lingers, `temporary_key_not_found` once reaped. Both are
/// authoritative answers that the key cannot authenticate; match them with
/// [`relay_error_code`] when that post-condition is all a caller wants.
pub async fn revoke_credential(session: &RelaySession, key_id: u64) -> Result<()> {
    session
        .admin()?
        .revoke_key(key_id)
        .await
        .map(|_| ())
        .with_context(|| format!("revoking credential {key_id} on {}", session.relay_addr))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_temporary_credential_cannot_drive_admin_rpcs() {
        // The privilege split is what the whole design rests on, and the SDK
        // checks it locally — so this holds without a relay to talk to.
        let session = RelaySession::new(
            "127.0.0.1:7666",
            "pbmt1_AQAAAAEAAAAAFNsL8qDUIBWtvMkHusQ9A6kEm0APq_BDwMZTCuoBCzqAsdCp",
        );
        let err = issue_credential(&session, Duration::from_secs(60), None)
            .await
            .expect_err("a temporary credential must not be able to mint credentials");
        assert!(
            format!("{err:#}").to_lowercase().contains("administrator"),
            "expected an administrator-privilege error, got: {err:#}"
        );
    }
}
