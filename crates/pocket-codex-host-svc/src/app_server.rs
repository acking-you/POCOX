//! One read-only loopback connection to the colocated Codex app-server,
//! shared by the session inventory and the history routes.

use std::{net::SocketAddr, sync::Arc};

use anyhow::{Context, Result};
use pocket_codex_codex::client::AppClient;
use serde_json::Value;
use tokio::sync::Mutex;

/// A lazily (re)connected app-server client for read-only requests. It never
/// resumes a thread, so it never subscribes to one or attaches a writer;
/// notifications are discarded.
pub struct CodexReader {
    address: SocketAddr,
    client: Mutex<Option<Arc<AppClient>>>,
}

impl CodexReader {
    /// Create a reader for the app-server at `address`; construction does not
    /// connect.
    pub fn new(address: SocketAddr) -> Self {
        Self {
            address,
            client: Mutex::new(None),
        }
    }

    /// The app-server's loopback listen address.
    pub fn address(&self) -> SocketAddr {
        self.address
    }

    /// Send one request, connecting (or reconnecting after the socket died)
    /// first.
    pub async fn request(&self, method: &str, params: Value) -> Result<Value> {
        let mut connection = self.client.lock().await;
        if !connection.as_ref().is_some_and(|client| client.is_alive()) {
            let (client, receiver) = AppClient::connect(&format!("ws://{}", self.address)).await?;
            // Read-only RPCs do not subscribe to session events. Dropping the
            // receiver also prevents unrelated notifications from accumulating.
            drop(receiver);
            client.initialize("pocket-codex-history", true).await?;
            *connection = Some(Arc::new(client));
        }
        let client = connection
            .as_ref()
            .context("app-server connection unavailable")?
            .clone();
        drop(connection);
        client.request(method, params).await
    }
}
