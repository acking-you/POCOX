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

use super::super::local_services::{self, Endpoint, Standing};
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

    /// Where the service a connection made now would reach stands.
    pub(super) fn standing(&self) -> Standing {
        if transport::is_current(self.epoch) {
            local_services::standing(&self.context, &self.service)
        } else {
            Standing::Stopped
        }
    }
}

impl Drop for Forward {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// The listener `service` has now; none while its host is stopped or
/// restarting.
fn target(context: &Context, service: &str) -> Option<Endpoint> {
    local_services::lookup(context, service).ok().flatten()
}

async fn serve(listener: TcpListener, context: Context, service: String, epoch: u64) {
    // Owned by this task, so aborting it closes every forwarded connection.
    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            accepted = listener.accept() => match accepted {
                Ok((mut inbound, _)) => {
                    let endpoint = transport::is_current(epoch)
                        .then(|| target(&context, &service))
                        .flatten();
                    let Some(endpoint) = endpoint else { continue };
                    connections.spawn(async move {
                        let Ok(mut outbound) = TcpStream::connect(endpoint.address()).await else {
                            return;
                        };
                        // The host may have stopped while this dialled, and
                        // another process may own the port by now.
                        if !endpoint.is_current() || !transport::is_current(epoch) {
                            return;
                        }
                        if let Err(error) =
                            tokio::io::copy_bidirectional(&mut inbound, &mut outbound).await
                        {
                            tracing::debug!(%error, "a local forward ended with an error");
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
