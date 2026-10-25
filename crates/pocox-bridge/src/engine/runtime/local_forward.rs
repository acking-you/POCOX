//! A loopback port chosen for one of this process's own services (the
//! Responses API panel). Each connection is forwarded to the listener the
//! service's host owns at that moment, so the chosen port keeps working
//! across host restarts, which bind new ephemeral listeners. Nothing reaches
//! a relay, and a stopped host refuses connections instead of falling back.

use std::net::SocketAddr;
use std::time::Duration;

use anyhow::{Context as _, Result};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::{JoinHandle, JoinSet};

use super::super::local_services;
use super::super::transport::{self, Context};

/// A forwarding listener. Dropping it closes the port and every connection
/// it carries.
pub(super) struct Forward {
    context: Context,
    service: String,
    epoch: u64,
    task: JoinHandle<()>,
}

impl Forward {
    /// Listen on `127.0.0.1:<port>` (`0`: any free port) for `service` of
    /// `context`, while `epoch` is current.
    pub(super) fn bind(
        context: Context,
        service: String,
        epoch: u64,
        port: u16,
    ) -> Result<(SocketAddr, Self)> {
        let requested = format!("127.0.0.1:{port}");
        let listener = std::net::TcpListener::bind(&requested)
            .with_context(|| format!("cannot bind {requested}"))?;
        listener.set_nonblocking(true)?;
        let address = listener.local_addr()?;
        let listener = {
            let _entered = super::runtime().enter();
            TcpListener::from_std(listener)?
        };
        let task = super::runtime().spawn(serve(listener, context.clone(), service.clone(), epoch));
        Ok((address, Self {
            context,
            service,
            epoch,
            task,
        }))
    }

    /// Whether a connection made now reaches the service.
    pub(super) fn is_current(&self) -> bool {
        transport::is_current(self.epoch) && target(&self.context, &self.service).is_some()
    }
}

impl Drop for Forward {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// The listener `service` has now; none while its host is stopped.
fn target(context: &Context, service: &str) -> Option<String> {
    local_services::lookup(context, service)
        .ok()
        .flatten()
        .map(|endpoint| endpoint.address())
}

async fn serve(listener: TcpListener, context: Context, service: String, epoch: u64) {
    // Owned by this task, so aborting it closes every forwarded connection.
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            accepted = listener.accept() => match accepted {
                Ok((mut inbound, _)) => {
                    let address = transport::is_current(epoch)
                        .then(|| target(&context, &service))
                        .flatten();
                    let Some(address) = address else { continue };
                    connections.spawn(async move {
                        if let Ok(mut outbound) = TcpStream::connect(address).await {
                            if let Err(error) =
                                tokio::io::copy_bidirectional(&mut inbound, &mut outbound).await
                            {
                                tracing::debug!(%error, "a local forward ended with an error");
                            }
                        }
                    });
                },
                // Out of descriptors, say: wait a moment instead of spinning.
                Err(error) => {
                    tracing::debug!(%error, "accepting a local forward failed");
                    tokio::time::sleep(Duration::from_millis(100)).await;
                },
            },
            Some(_) = connections.join_next(), if !connections.is_empty() => {},
        }
    }
}
