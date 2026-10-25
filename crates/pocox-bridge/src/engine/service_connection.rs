//! Choose a process-owned loopback endpoint before resolving any relay
//! credential. All protocols keep their existing clients and admission rules.

use anyhow::{ensure, Result};

use super::local_services::{self, Endpoint};
use super::runtime;
use super::transport::{self, Context, Owned};

/// Transport selected for one service. A local failure never selects Remote.
pub(crate) enum Target {
    Local { context: Context, epoch: u64, endpoint: Endpoint },
    Remote(Owned),
}

impl Target {
    pub(crate) fn resolve(service: &str) -> Result<Self> {
        let epoch = transport::epoch();
        if let Some(context) = transport::current_context() {
            if let Some(endpoint) = local_services::lookup(&context, service)? {
                ensure!(transport::is_current(epoch), "the account or relay changed; try again");
                return Ok(Self::Local {
                    context,
                    epoch,
                    endpoint,
                });
            }
        }
        let owned = transport::resolve_owned_blocking()?;
        Self::in_context(service, owned)
    }

    pub(crate) fn in_context(service: &str, owned: Owned) -> Result<Self> {
        let context = Context::of(&owned.transport);
        match local_services::lookup(&context, service)? {
            Some(endpoint) => Ok(Self::Local {
                context,
                epoch: owned.epoch,
                endpoint,
            }),
            None => Ok(Self::Remote(owned)),
        }
    }

    pub(crate) fn context(&self) -> Context {
        match self {
            Self::Local {
                context, ..
            } => context.clone(),
            Self::Remote(owned) => Context::of(&owned.transport),
        }
    }

    pub(crate) fn epoch(&self) -> u64 {
        match self {
            Self::Local {
                epoch, ..
            } => *epoch,
            Self::Remote(owned) => owned.epoch,
        }
    }

    pub(crate) fn open(
        &self,
        service: &str,
        registry: String,
        port: u16,
        probe: bool,
    ) -> Result<Origin> {
        ensure!(transport::is_current(self.epoch()), "the account or relay changed; try again");
        match self {
            Self::Local {
                endpoint, ..
            } => {
                ensure!(endpoint.is_current(), "the local host stopped or restarted; reconnect");
                let subscription = if probe {
                    None
                } else {
                    runtime::subscribe_local(registry.clone(), endpoint.clone(), self.epoch())?;
                    Some(registry)
                };
                Ok(Origin {
                    address: endpoint.address(),
                    local: Some(endpoint.clone()),
                    subscription,
                    transient: None,
                })
            },
            Self::Remote(owned) if probe => {
                let (address, transient) =
                    runtime::subscribe_transient(service.into(), port, &owned.transport)?;
                Ok(Origin {
                    address,
                    local: None,
                    subscription: None,
                    transient: Some(transient),
                })
            },
            Self::Remote(owned) => {
                let sub = runtime::subscribe_service_as(
                    registry.clone(),
                    service,
                    port,
                    &owned.transport,
                    || transport::is_current(owned.epoch),
                )?;
                Ok(Origin {
                    address: sub.local_addr,
                    local: None,
                    subscription: Some(registry),
                    transient: None,
                })
            },
        }
    }
}

/// One protocol origin, with its optional tunnel owned separately from the
/// publisher. Reconnect can retain a live remote tunnel without redialling.
pub(crate) struct Origin {
    pub(crate) address: String,
    pub(crate) local: Option<Endpoint>,
    pub(crate) subscription: Option<String>,
    pub(crate) transient: Option<runtime::TransientSubscription>,
}

impl Origin {
    pub(crate) fn url(&self) -> String {
        format!("http://{}/", self.address)
    }

    pub(crate) fn is_current(&self) -> bool {
        self.local.as_ref().is_none_or(Endpoint::is_current)
    }

    pub(crate) fn release(&self) {
        if let Some(subscription) = &self.subscription {
            runtime::unsubscribe_service(subscription);
        }
    }

    pub(crate) fn close_probe(self) {
        if let Some(transient) = self.transient {
            transient.close();
        }
    }
}

#[cfg(test)]
#[path = "service_connection_tests.rs"]
mod tests;
