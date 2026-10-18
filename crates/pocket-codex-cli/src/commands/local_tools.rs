//! The running POCOX host on this computer, as the CLI reaches it: the
//! desktop app or the CLI host (`pocox serve --allow-remote-management`).
//!
//! Each serves the agent tools' loopback endpoint and announces it in its
//! private hosting store, beside a token only this user can read. The CLI
//! sends that token only after the listener proved it is the process that
//! announced it. Shares and connections live in that process, so they
//! outlive the command that asked.

use std::{path::PathBuf, time::Duration};

use anyhow::{bail, Context, Result};
use pocket_codex_bridge::agent_tools::{endpoint, tokens};
use pocket_codex_core::paths;
use serde::{de::DeserializeOwned, Serialize};

/// One installation that can host on this computer.
#[derive(Debug, Clone)]
pub(super) struct Installation {
    /// `app` or `cli host`.
    pub label: &'static str,
    /// Its hosting store.
    pub root: PathBuf,
}

impl Installation {
    fn dir(&self) -> PathBuf {
        self.root.join("agent-tools")
    }

    /// Its announcement and the user's token, when it announced one.
    pub fn announced(&self) -> Option<(endpoint::Discovery, String)> {
        let discovery = endpoint::read_discovery(&self.dir())?;
        let token = tokens::read_user_token(&self.dir()).ok()?;
        Some((discovery, token))
    }
}

/// The CLI host first, then the desktop app.
pub(super) fn installations() -> Result<Vec<Installation>> {
    let state = paths::state_dir()?;
    Ok(vec![
        Installation {
            label: "cli host",
            root: state.join("managed-host").join("hosting"),
        },
        Installation {
            label: "app",
            root: state.join("hosting"),
        },
    ])
}

fn client() -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(3))
        .timeout(Duration::from_secs(150))
        .build()
        .context("initializing the local client")
}

/// A running host's local surface.
pub(super) struct Local {
    url: String,
    token: String,
}

/// `installation`, when it runs and answers.
pub(super) async fn reach(installation: &Installation) -> Option<Local> {
    let (discovery, token) = installation.announced()?;
    // A stale announcement's port may belong to another program by now (even
    // another user's): it gets the token only once it proves it wrote this
    // announcement.
    if !proven(&discovery).await {
        return None;
    }
    let local = Local {
        url: discovery.url,
        token,
    };
    local
        .get::<serde_json::Value>("status")
        .await
        .is_ok()
        .then_some(local)
}

async fn proven(discovery: &endpoint::Discovery) -> bool {
    let challenge = endpoint::new_secret();
    let Ok(client) = client() else { return false };
    let answer = async {
        client
            .get(format!("{}/local/v1/hello", discovery.url))
            .query(&[("challenge", challenge.as_str())])
            .send()
            .await
            .ok()?
            .json::<serde_json::Value>()
            .await
            .ok()
    }
    .await;
    answer.as_ref().and_then(|value| value["proof"].as_str())
        == Some(endpoint::proof(&discovery.secret, &challenge).as_str())
}

/// The first running host that answers.
pub(super) async fn running() -> Result<Option<Local>> {
    for installation in installations()? {
        if let Some(local) = reach(&installation).await {
            return Ok(Some(local));
        }
    }
    Ok(None)
}

/// [`running`], or an error saying how to start one.
pub(super) async fn require() -> Result<Local> {
    running().await?.ok_or_else(|| {
        anyhow::anyhow!(
            "POCOX is not running on this computer: start the POCOX app, or `pocox serve \
             --allow-remote-management`"
        )
    })
}

impl Local {
    async fn decode<T: DeserializeOwned>(response: reqwest::Response) -> Result<T> {
        let status = response.status();
        let body: serde_json::Value = response.json().await.context("reading POCOX's answer")?;
        if status.as_u16() == 202 {
            bail!(
                "{}",
                body["message"]
                    .as_str()
                    .unwrap_or("waiting; run the command again")
            );
        }
        if !status.is_success() {
            bail!(
                "{}",
                body["message"]
                    .as_str()
                    .unwrap_or("POCOX refused the request")
            );
        }
        serde_json::from_value(body).context("decoding POCOX's answer")
    }

    /// `GET /local/v1/<path>`.
    pub async fn get<T: DeserializeOwned>(&self, path: &str) -> Result<T> {
        let response = client()?
            .get(format!("{}/local/v1/{path}", self.url))
            .bearer_auth(&self.token)
            .send()
            .await
            .context("reaching POCOX on this computer")?;
        Self::decode(response).await
    }

    /// `POST /local/v1/<path>` with `body`.
    pub async fn post<T: DeserializeOwned, B: Serialize>(&self, path: &str, body: &B) -> Result<T> {
        let response = client()?
            .post(format!("{}/local/v1/{path}", self.url))
            .bearer_auth(&self.token)
            .json(body)
            .send()
            .await
            .context("reaching POCOX on this computer")?;
        Self::decode(response).await
    }
}
