//! A private, short-lived `grok agent --no-leader stdio` for Grok's own
//! account and session operations: sign-in status, sign-in and sign-out
//! (`authenticate`, `_x.ai/auth/*`), and renaming or deleting a stored
//! session (`_x.ai/session/rename`, `_x.ai/session/delete`). It is never a
//! host: it opens no session and sends no prompt, and the caller stops it
//! when the operation ends.
//!
//! Sign-in uses Grok's device flow: `authenticate` (method `grok.com`)
//! answers once the user approved the code in a browser; meanwhile
//! `_x.ai/auth/get_url` hands out the verification URL once.

use std::{ffi::OsString, path::Path, sync::Arc, time::Duration};

use serde_json::{json, Value};
use tokio::sync::Mutex;

use super::{
    grok,
    jsonrpc::{RequestId, RpcError},
    peer::{CallError, Inbound, Peer},
    schema,
};
use crate::process::{self, AgentProcess};

/// How long the handshake may take.
const HANDSHAKE: Duration = Duration::from_secs(20);
/// How long one account or session call may take.
pub const CALL_TIMEOUT: Duration = Duration::from_secs(15);

/// Why the control agent could not run an operation.
#[derive(Debug, thiserror::Error)]
pub enum ControlError {
    /// The executable could not be started.
    #[error("Grok could not be started: {0}")]
    Start(String),
    /// The agent did not complete the ACP handshake.
    #[error("Grok did not answer: {0}")]
    Handshake(CallError),
    /// The agent refused or failed a call.
    #[error("Grok refused the request: {0}")]
    Call(CallError),
}

/// What Grok reports about the signed-in account.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GrokAccount {
    /// An auth method is in effect (a cached sign-in or an API key).
    pub signed_in: bool,
    /// The effective auth method id (`cached_token`, `xai.api_key`, ...).
    pub method: Option<String>,
    /// The account email, when signed in with an account.
    pub email: Option<String>,
}

/// One running control agent. Cheap to share; stop it once.
pub struct GrokControl {
    peer: Peer,
    process: Mutex<Option<AgentProcess>>,
    /// The interactive sign-in method `initialize` advertised (`grok.com`,
    /// or `oidc` for an enterprise identity provider).
    sign_in_method: Option<String>,
    /// The model new sessions would use (`_meta.modelState.currentModelId`).
    current_model: Option<String>,
}

/// Answers every agent request with "method not found": the control agent
/// runs no session, so it never needs a permission or file answer.
struct Refuse;

impl Inbound for Refuse {
    fn notification(&self, _peer: &Peer, _method: &str, _params: Option<Value>) {}

    fn request(&self, peer: &Peer, id: RequestId, method: &str, _params: Option<Value>) {
        peer.respond_now(
            id,
            Err(RpcError::new(
                RpcError::METHOD_NOT_FOUND,
                format!("{method} is not available to this client"),
            )),
        );
    }
}

impl GrokControl {
    /// Start `program` with the preset's ACP arguments, `path` as the
    /// child's `PATH`, `env` added and `remove` taken out of its
    /// environment, and complete the handshake.
    pub async fn start(
        program: &Path,
        path: Option<&OsString>,
        env: &[(OsString, OsString)],
        remove: &[String],
    ) -> Result<Arc<Self>, ControlError> {
        let args: Vec<String> = grok::ARGS.iter().map(|a| (*a).to_string()).collect();
        let removed: Vec<&str> = remove.iter().map(String::as_str).collect();
        let spawned = process::spawn_without(program, &args, path, env, &removed)
            .map_err(|e| ControlError::Start(e.to_string()))?;
        let peer = Peer::spawn(spawned.stdout, spawned.stdin, Arc::new(Refuse));
        let process = Mutex::new(Some(spawned.process));
        let initialized = peer
            .request("initialize", schema::initialize_params(), Some(HANDSHAKE))
            .await;
        let initialized = match initialized {
            Ok(result) => result,
            Err(error) => {
                peer.shutdown(Duration::from_millis(200)).await;
                if let Some(process) = process.lock().await.take() {
                    process.terminate(Duration::from_millis(300)).await;
                }
                return Err(ControlError::Handshake(error));
            },
        };
        let sign_in_method = initialized["authMethods"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|method| method["id"].as_str())
            .find(|id| matches!(*id, "grok.com" | "oidc"))
            .map(str::to_owned);
        let current_model = initialized["_meta"]["modelState"]["currentModelId"]
            .as_str()
            .map(str::to_owned);
        Ok(Arc::new(Self {
            peer,
            process,
            sign_in_method,
            current_model,
        }))
    }

    /// The model new sessions would use, when Grok reports it.
    pub fn current_model(&self) -> Option<&str> {
        self.current_model.as_deref()
    }

    /// The interactive sign-in method, when Grok offers one.
    pub fn sign_in_method(&self) -> Option<&str> {
        self.sign_in_method.as_deref()
    }

    /// One request, answered within `timeout` (`None`: until it answers or
    /// the agent exits).
    pub async fn call(
        &self,
        method: &str,
        params: Value,
        timeout: Option<Duration>,
    ) -> Result<Value, ControlError> {
        self.peer
            .request(method, params, timeout)
            .await
            .map_err(ControlError::Call)
    }

    /// The effective sign-in.
    pub async fn account(&self) -> Result<GrokAccount, ControlError> {
        let info = self
            .call("_x.ai/auth/info", json!({}), Some(CALL_TIMEOUT))
            .await?;
        let method = info["methodId"].as_str().map(str::to_owned);
        Ok(GrokAccount {
            signed_in: method.is_some(),
            method,
            email: info["email"].as_str().map(str::to_owned),
        })
    }

    /// The sign-in URL of a running `authenticate`, once (`None` until the
    /// flow produced it, and after it was handed out).
    pub async fn take_sign_in_url(&self) -> Result<Option<(String, String)>, ControlError> {
        let answer = self
            .call("_x.ai/auth/get_url", json!({}), Some(CALL_TIMEOUT))
            .await?;
        Ok(answer["auth_url"].as_str().map(|url| {
            let mode = answer["mode"].as_str().unwrap_or("device").to_string();
            (url.to_string(), mode)
        }))
    }

    /// Whether the agent's connection is gone.
    pub fn is_closed(&self) -> bool {
        self.peer.is_closed()
    }

    /// Close the connection and stop the process group (bounded).
    pub async fn stop(&self) {
        self.peer.shutdown(Duration::from_millis(200)).await;
        if let Some(process) = self.process.lock().await.take() {
            process.terminate(Duration::from_millis(300)).await;
        }
    }
}
