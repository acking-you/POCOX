//! The relay's answers, classified, and the facts cached about it.

use std::time::Instant;

use pocox_account_proto::pairing::PairingErrorCode;
use pocox_pb::{relay_error_code, CredentialRecord, RelayStatus};
use pocox_store::pairing::RelayKeyRow;

use super::error::PairingError;
use super::service::{CachedStatus, Pairing};

/// A dead key answering a revoke or renew: `not_active` while its row lingers,
/// `not_found` once reaped. Authoritative, so not a transport failure.
const KEY_NOT_ACTIVE: &str = "temporary_key_not_active";
const KEY_NOT_FOUND: &str = "temporary_key_not_found";
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

/// What the relay says about a stored key id, asked before any renew or revoke,
/// which act on whichever key holds an id now.
pub(super) enum KeyCheck {
    /// The expected key, with what the relay reports about it.
    Ours(CredentialRecord),
    /// Another tenant's key holds this id. Never exposed and never touched.
    Foreign,
    /// Ours by label, in another namespace: revoke and reissue.
    Drifted,
    /// No such key can authenticate.
    Gone,
}

/// Clears the probe flag however the probing request ends, including when it is
/// dropped.
struct ProbeGuard<'a>(&'a Pairing);

impl Drop for ProbeGuard<'_> {
    fn drop(&mut self) {
        self.0.probe.lock().expect("probe lock").in_flight = false;
    }
}

impl Pairing {
    /// Read the relay's status now, refreshing the cache. Waits as long as the
    /// relay does, so a request-serving caller bounds it.
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

    /// What is known about the relay right now, without waiting on it for long.
    ///
    /// A relay that accepts connections and then says nothing must not hold
    /// requests, so a stale answer is refreshed by one caller at a time
    /// under a short bound, and for a while after that fails nobody waits
    /// at all. `None` means nothing is known: the answer to "may this go
    /// ahead" is then yes, and durable work waits for the relay.
    pub(super) async fn known_status(&self) -> Option<RelayStatus> {
        let (fresh, last_known) = {
            let status = self.status.lock().expect("status lock");
            let last_known = status.as_ref().map(|cached| cached.status.clone());
            let fresh = status
                .as_ref()
                .is_some_and(|cached| cached.fetched.elapsed() < self.settings.relay_status_ttl);
            (fresh, last_known)
        };
        if fresh {
            return last_known;
        }
        {
            let mut probe = self.probe.lock().expect("probe lock");
            let failed_recently = probe
                .failed_at
                .is_some_and(|at| at.elapsed() < self.settings.relay_status_ttl);
            if probe.in_flight || failed_recently {
                return last_known;
            }
            probe.in_flight = true;
        }
        let _guard = ProbeGuard(self);
        let answer =
            tokio::time::timeout(self.settings.relay_probe_wait, self.fresh_status()).await;
        match answer {
            Ok(Ok(status)) => {
                self.probe.lock().expect("probe lock").failed_at = None;
                Some(status)
            },
            _ => {
                self.probe.lock().expect("probe lock").failed_at = Some(Instant::now());
                last_known
            },
        }
    }

    /// Refuse before side effects on a relay known to be too old. An
    /// unreachable or silent relay is not known to be anything: durable
    /// work proceeds and waits for it.
    pub(super) async fn require_capable_relay(&self) -> Result<(), PairingError> {
        match self.known_status().await {
            Some(status) if !status.supports_key_namespaces => {
                Err(PairingError::code(PairingErrorCode::RelayTooOld))
            },
            _ => Ok(()),
        }
    }

    /// Ask the relay about a stored key id before acting on it. Costs no replay
    /// slot.
    pub(super) async fn inspect_key(
        &self,
        row: &RelayKeyRow,
        key_id: u64,
    ) -> Result<KeyCheck, RelayFailure> {
        let shown = pocox_pb::live_credential(&self.relay, key_id)
            .await
            .map_err(|error| RelayFailure::classify(&error));
        let record = match shown {
            Ok(Some(record)) => record,
            Ok(None) | Err(RelayFailure::KeyDead) => return Ok(KeyCheck::Gone),
            Err(other) => return Err(other),
        };
        if record.label.as_deref() != Some(row.label.as_str()) {
            tracing::error!(
                grant = %row.grant_id,
                "a stored key id answers with another label; not exposing or touching it"
            );
            return Ok(KeyCheck::Foreign);
        }
        if record.namespace.to_string() != row.namespace {
            tracing::error!(grant = %row.grant_id, "relay reports another namespace for a key");
            return Ok(KeyCheck::Drifted);
        }
        Ok(KeyCheck::Ours(record))
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
