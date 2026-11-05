//! A device's view of the routes it shares with GitHub that reach the relay's
//! service table. Both are administrator requests made on the caller's behalf,
//! so what a device can make the relay do has to stay bounded: the relay's
//! replay window holds 65,536 writes per 10 minutes for the whole backend,
//! GitHub included.

use std::sync::Arc;
use std::time::Instant;

use pocox_account_proto::pairing::PairingErrorCode;
use pocox_pb::ServiceRecord;

use super::error::{PairingError, PairingResult};
use super::relay::RelayFailure;
use super::service::{unix_now, ClientBucket, Pairing};

fn unavailable() -> PairingError {
    PairingError::retry_later(PairingErrorCode::RelayUnavailable, 5)
}

impl Pairing {
    /// The relay's service listing, shared by every device caller for a few
    /// seconds.
    ///
    /// A listing makes the relay collect and sort its whole table, so however
    /// many devices ask, it is asked once per interval. A silent relay gets
    /// a 503 within a bound, not a held request.
    pub(crate) async fn service_snapshot(&self) -> PairingResult<Arc<Vec<ServiceRecord>>> {
        let work = async {
            let mut snapshot = self.services.lock().await;
            if let Some((at, records)) = snapshot.as_ref() {
                if at.elapsed() < self.settings.services_snapshot_ttl {
                    return Ok(Arc::clone(records));
                }
            }
            let records = Arc::new(
                pocox_pb::all_services(&self.relay)
                    .await
                    .map_err(|error| PairingError::from(RelayFailure::classify(&error)))?,
            );
            *snapshot = Some((Instant::now(), Arc::clone(&records)));
            Ok(records)
        };
        tokio::time::timeout(self.settings.foreground_wait, work)
            .await
            .map_err(|_| unavailable())?
    }

    /// Retire a device's own service, for a current session.
    ///
    /// Every retirement is a relay write that takes a replay slot, whether or
    /// not the service exists, so it is metered per device, per address and
    /// across the backend, and a service the listing does not show costs
    /// the relay nothing.
    pub(crate) async fn retire_device_service(
        &self,
        device_id: &str,
        namespace: u64,
        relay_key: &str,
        bucket: ClientBucket,
    ) -> PairingResult<()> {
        let now = unix_now();
        let device_key = self.device_key(device_id);
        let rate_limited = |wait| PairingError::retry_later(PairingErrorCode::RateLimited, wait);
        self.limiters
            .deregistrations_by_device
            .charge(device_key, now)
            .map_err(rate_limited)?;
        self.limiters
            .deregistrations_by_address
            .charge(bucket.0, now)
            .map_err(rate_limited)?;
        let listed = self
            .service_snapshot()
            .await?
            .iter()
            .any(|service| service.namespace == namespace && service.name == relay_key);
        if !listed {
            return Ok(());
        }
        self.charge_backend(
            "service_retirements",
            self.settings.limits.deregistrations_backend,
            now,
        )
        .await?;
        let retired = tokio::time::timeout(
            self.settings.foreground_wait,
            pocox_pb::retire_service(&self.relay, namespace, relay_key),
        )
        .await
        .map_err(|_| unavailable())?;
        retired.map_err(|error| PairingError::from(RelayFailure::classify(&error)))?;
        *self.services.lock().await = None;
        Ok(())
    }
}
