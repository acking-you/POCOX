//! The relay's answers, classified, and the facts cached about it.

use std::time::Instant;

use pocox_account_proto::pairing::PairingErrorCode;
use pocox_pb::{relay_error_code, CredentialRecord, RelayStatus};

use super::error::PairingError;
use super::service::{CachedStatus, Pairing};

/// A dead key answering a revoke or renew: `not_active` while its row lingers,
/// `not_found` once reaped. Authoritative, so not a transport failure.
pub(super) const KEY_NOT_ACTIVE: &str = "temporary_key_not_active";
pub(super) const KEY_NOT_FOUND: &str = "temporary_key_not_found";
const KEY_NOT_RENEWABLE: &str = "temporary_key_not_renewable";
const NAMESPACE_NOT_ALLOCATED: &str = "namespace_not_allocated";
const KEY_CAPACITY_EXHAUSTED: &str = "temporary_key_capacity_exhausted";

/// What went wrong with a relay call.
#[derive(Debug)]
pub(super) enum RelayFailure {
    /// The relay answered that this key cannot authenticate.
    KeyDead,
    /// The relay does not know this namespace, so it lost its state.
    NamespaceLost,
    /// The relay's key table is full.
    TableFull,
    /// No authoritative answer about the request, or a refusal we cannot act
    /// on. Whether it took effect is unknown.
    Unavailable(String),
}

impl RelayFailure {
    pub(super) fn classify(error: &anyhow::Error) -> Self {
        match relay_error_code(error) {
            Some(KEY_NOT_ACTIVE | KEY_NOT_FOUND | KEY_NOT_RENEWABLE) => Self::KeyDead,
            Some(NAMESPACE_NOT_ALLOCATED) => Self::NamespaceLost,
            Some(KEY_CAPACITY_EXHAUSTED) => Self::TableFull,
            _ => Self::Unavailable(format!("{error:#}")),
        }
    }
}

impl From<RelayFailure> for PairingError {
    fn from(failure: RelayFailure) -> Self {
        use PairingErrorCode as Code;
        match failure {
            RelayFailure::NamespaceLost => Self::retry_later(Code::RelayStateLost, 60),
            RelayFailure::TableFull => Self::retry_later(Code::RelayCapacity, 60),
            RelayFailure::KeyDead => Self::retry_later(Code::RelayUnavailable, 5),
            RelayFailure::Unavailable(detail) => {
                tracing::warn!(error = %detail, "relay call failed");
                Self::retry_later(Code::RelayUnavailable, 5)
            },
        }
    }
}

impl Pairing {
    /// Read the relay's status now, refreshing the cache.
    pub(super) async fn fresh_status(&self) -> Result<RelayStatus, RelayFailure> {
        let status = pocox_pb::relay_status(&self.relay)
            .await
            .map_err(|error| RelayFailure::classify(&error))?;
        *self.status.lock().expect("status lock") = Some(CachedStatus {
            status: status.clone(),
            fetched: Instant::now(),
        });
        Ok(status)
    }

    /// The relay's status, cached where a slightly old answer cannot do harm.
    /// Every call that names a stored key id uses [`Self::fresh_status`]
    /// instead.
    pub(super) async fn cached_status(&self) -> Result<RelayStatus, RelayFailure> {
        let cached = self
            .status
            .lock()
            .expect("status lock")
            .as_ref()
            .filter(|cached| cached.fetched.elapsed() < self.settings.relay_status_ttl)
            .map(|cached| cached.status.clone());
        match cached {
            Some(status) => Ok(status),
            None => self.fresh_status().await,
        }
    }

    /// Refuse before side effects on a relay known to be too old. An
    /// unreachable relay is not known to be anything: durable work proceeds
    /// and waits for it.
    pub(super) async fn require_capable_relay(&self) -> Result<(), PairingError> {
        match self.cached_status().await {
            Ok(status) if !status.supports_key_namespaces => {
                Err(PairingError::code(PairingErrorCode::RelayTooOld))
            },
            _ => Ok(()),
        }
    }

    /// Find a key by its exact label.
    ///
    /// The relay's listing pages by position, so a removal between pages can
    /// skip a row: one walk that misses is not proof of absence. Only two
    /// consecutive walks missing it are, and only then may another be
    /// minted.
    pub(super) async fn find_key_by_label(
        &self,
        label: &str,
    ) -> Result<Option<CredentialRecord>, RelayFailure> {
        for _ in 0..2 {
            let live = pocox_pb::live_credentials(&self.relay)
                .await
                .map_err(|error| RelayFailure::classify(&error))?;
            if let Some(found) = live
                .into_iter()
                .find(|key| key.label.as_deref() == Some(label))
            {
                return Ok(Some(found));
            }
        }
        Ok(None)
    }

    /// Revoke a key the database knows, treating the relay's word that it is
    /// already dead as success. Only that word counts: a timeout proves
    /// nothing.
    pub(super) async fn revoke_key(&self, key_id: u64) -> Result<(), RelayFailure> {
        match pocox_pb::revoke_credential(&self.relay, key_id).await {
            Ok(()) => Ok(()),
            Err(error) => match RelayFailure::classify(&error) {
                RelayFailure::KeyDead => Ok(()),
                other => Err(other),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use pocox_auth::Auth;
    use pocox_pb::{RelaySession, RelayStatus};
    use pocox_store::Store;

    use super::*;
    use crate::pairing::PairingSettings;

    #[tokio::test]
    async fn an_old_relay_is_refused_before_side_effects_and_an_unreachable_one_is_not() {
        let dir = std::env::temp_dir().join(format!("pocox-relay-facts-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("directory");
        let store = Store::connect(&format!("sqlite://{}", dir.join("backend.db").display()))
            .await
            .expect("store");
        let auth = Arc::new(
            Auth::new(store.clone(), pocox_auth::Config {
                github_client_id: "client".to_string(),
                github_client_secret: None,
                github_scope: "read:user".to_string(),
                jwt_secret: "j".repeat(32),
                jwt_ttl_secs: 3600,
                refresh_ttl_secs: 1000,
                web_callback_url: None,
                pairing_secret: Some("p".repeat(32)),
            })
            .expect("auth"),
        );
        let pairing = Pairing::new(
            auth,
            store,
            RelaySession::for_test("127.0.0.1:1"),
            PairingSettings::default(),
        )
        .expect("pairing");

        // Nothing is known about a relay that cannot be reached: durable work waits.
        pairing
            .require_capable_relay()
            .await
            .expect("unknown is not too old");

        let known = |supports_key_namespaces| CachedStatus {
            status: RelayStatus {
                instance_id: "instance".to_string(),
                supports_key_namespaces,
                key_capacity: 16,
            },
            fetched: Instant::now(),
        };
        *pairing.status.lock().expect("status") = Some(known(false));
        let refused = pairing.require_capable_relay().await.expect_err("too old");
        assert_eq!(refused.refusal_code(), Some(PairingErrorCode::RelayTooOld));

        *pairing.status.lock().expect("status") = Some(known(true));
        pairing.require_capable_relay().await.expect("capable");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_relays_word_that_a_key_is_dead_is_not_a_transport_failure() {
        for code in [KEY_NOT_ACTIVE, KEY_NOT_FOUND, KEY_NOT_RENEWABLE] {
            let error: anyhow::Error = anyhow::Error::new(pb_mapper::Error::Remote {
                code: code.to_string(),
                message: String::new(),
                retryable: false,
            });
            assert!(matches!(RelayFailure::classify(&error), RelayFailure::KeyDead));
        }
        let timeout = anyhow::anyhow!("administrator request timed out");
        assert!(matches!(RelayFailure::classify(&timeout), RelayFailure::Unavailable(_)));
    }
}
