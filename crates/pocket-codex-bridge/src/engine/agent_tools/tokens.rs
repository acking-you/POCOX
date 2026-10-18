//! Bearer tokens: who is calling the tools.
//!
//! Each hosted harness instance, each ACP session, each installed harness and
//! the local CLI get their own token, so every call is attributed without
//! trusting what a client says about itself. Only SHA-256 digests are kept;
//! a token is handed once to whatever presents it (a child's environment, an
//! ACP session's header, a harness entry, the CLI's private file) and is never
//! logged or put on a command line.

use std::{
    collections::HashMap,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use base64::Engine as _;
use pocket_codex_core::history_sync::digest_bytes;
use serde::{Deserialize, Serialize};

use super::model::{bounded, OwnerKind, OwnerView};
use crate::engine::host_profiles::files::write_private;

const FILE: &str = "tokens.json";
const USER_FILE: &str = "user-token";
const PREFIX: &str = "pcxt_";

/// What a token was issued to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// The user, through the local CLI.
    User,
    /// A harness instance POCOX launched.
    Hosted,
    /// One ACP session of a hosted agent.
    Session,
    /// A harness the user installed the tools into.
    Installed,
}

/// The caller behind a token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Principal {
    /// Token id (never the token).
    pub id: String,
    /// What it was issued to.
    pub kind: Kind,
    /// Display name.
    pub label: String,
    /// `codex`, `claude`, `opencode`, `acp`, or an installed harness.
    pub harness: Option<String>,
    /// The hosted instance it belongs to.
    pub host: Option<String>,
    /// The ACP session it was bound to.
    pub session: Option<String>,
}

impl Principal {
    /// The owner POCOX records for this caller in `conversation`.
    pub fn owner(&self, conversation: Option<&str>) -> OwnerView {
        OwnerView {
            kind: if self.kind == Kind::User { OwnerKind::User } else { OwnerKind::Agent },
            label: self.label.clone(),
            harness: self.harness.clone(),
            host: self.host.clone(),
            conversation: self
                .session
                .clone()
                .or_else(|| conversation.map(bounded))
                .filter(|c| !c.is_empty()),
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Record {
    id: String,
    digest: String,
    kind: Kind,
    label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    harness: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    host: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    session: Option<String>,
    created_ms: i64,
}

impl Record {
    fn principal(&self) -> Principal {
        Principal {
            id: self.id.clone(),
            kind: self.kind,
            label: self.label.clone(),
            harness: self.harness.clone(),
            host: self.host.clone(),
            session: self.session.clone(),
        }
    }

    /// Session tokens live only as long as the process that minted them.
    fn persisted(&self) -> bool {
        self.kind != Kind::Session
    }
}

/// A token listed for the user; the token itself is never listed.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TokenView {
    /// Revoke with this id.
    pub id: String,
    /// What it was issued to.
    pub kind: Kind,
    /// Display name.
    pub label: String,
    /// The harness.
    pub harness: Option<String>,
    /// Unix milliseconds.
    pub created_ms: i64,
}

#[derive(Default, Serialize, Deserialize)]
struct File {
    #[serde(default)]
    tokens: Vec<Record>,
}

/// Every valid token of this installation, by digest.
#[derive(Default)]
pub struct Tokens {
    dir: Option<PathBuf>,
    records: HashMap<String, Record>,
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

fn new_secret() -> String {
    let mut bytes = Vec::with_capacity(32);
    bytes.extend_from_slice(uuid::Uuid::new_v4().as_bytes());
    bytes.extend_from_slice(uuid::Uuid::new_v4().as_bytes());
    format!("{PREFIX}{}", base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
}

impl Tokens {
    /// The tokens saved in `dir`, keeping the CLI's own token valid (and
    /// creating it on first use).
    pub fn open(dir: &Path) -> Result<Self> {
        let file: File = match std::fs::read(dir.join(FILE)) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => File::default(),
            Err(error) => return Err(error).context("reading agent tool tokens"),
        };
        let mut tokens = Self {
            dir: Some(dir.to_path_buf()),
            records: file
                .tokens
                .into_iter()
                .map(|record| (record.digest.clone(), record))
                .collect(),
        };
        tokens.ensure_user()?;
        Ok(tokens)
    }

    fn ensure_user(&mut self) -> Result<()> {
        let Some(dir) = self.dir.clone() else { return Ok(()) };
        let path = dir.join(USER_FILE);
        if let Ok(secret) = std::fs::read_to_string(&path) {
            let digest = digest_bytes(secret.trim().as_bytes());
            if self
                .records
                .get(&digest)
                .is_some_and(|r| r.kind == Kind::User)
            {
                return Ok(());
            }
        }
        self.records.retain(|_, record| record.kind != Kind::User);
        let (_, secret) = self.mint(Kind::User, "You", None, None)?;
        write_private(&path, secret.as_bytes()).context("saving the CLI's agent tools token")?;
        Ok(())
    }

    /// Issue a token; the caller hands the returned secret to its holder.
    pub fn mint(
        &mut self,
        kind: Kind,
        label: &str,
        harness: Option<&str>,
        host: Option<&str>,
    ) -> Result<(Principal, String)> {
        let secret = new_secret();
        let record = Record {
            id: uuid::Uuid::new_v4().simple().to_string()[..12].to_string(),
            digest: digest_bytes(secret.as_bytes()),
            kind,
            label: bounded(label),
            harness: harness.map(bounded),
            host: host.map(bounded),
            session: None,
            created_ms: now_ms(),
        };
        let principal = record.principal();
        let persisted = record.persisted();
        self.records.insert(record.digest.clone(), record);
        if persisted {
            self.save()?;
        }
        Ok((principal, secret))
    }

    /// The caller presenting `secret`.
    pub fn authenticate(&self, secret: &str) -> Option<Principal> {
        let secret = secret.trim();
        if !secret.starts_with(PREFIX) || secret.len() > 128 {
            return None;
        }
        self.records
            .get(&digest_bytes(secret.as_bytes()))
            .map(Record::principal)
    }

    /// Bind a session token to the session it was minted for.
    pub fn bind_session(&mut self, id: &str, session: &str) {
        if let Some(record) = self.records.values_mut().find(|r| r.id == id) {
            record.session = Some(bounded(session));
        }
    }

    /// Revoke the tokens `which` selects; returns the revoked principals.
    pub fn revoke_where(&mut self, which: impl Fn(&Principal) -> bool) -> Vec<Principal> {
        let revoked: Vec<Principal> = self
            .records
            .values()
            .map(Record::principal)
            .filter(|p| p.kind != Kind::User && which(p))
            .collect();
        if revoked.is_empty() {
            return revoked;
        }
        self.records
            .retain(|_, record| !revoked.iter().any(|p| p.id == record.id));
        if let Err(error) = self.save() {
            tracing::warn!("agent tool tokens not saved: {error:#}");
        }
        revoked
    }

    /// Every token but the session ones, for Settings.
    pub fn list(&self) -> Vec<TokenView> {
        let mut views: Vec<TokenView> = self
            .records
            .values()
            .filter(|record| record.persisted())
            .map(|record| TokenView {
                id: record.id.clone(),
                kind: record.kind,
                label: record.label.clone(),
                harness: record.harness.clone(),
                created_ms: record.created_ms,
            })
            .collect();
        views.sort_by_key(|view| view.created_ms);
        views
    }

    fn save(&self) -> Result<()> {
        let Some(dir) = &self.dir else { return Ok(()) };
        let file = File {
            tokens: self
                .records
                .values()
                .filter(|record| record.persisted())
                .cloned()
                .collect(),
        };
        write_private(&dir.join(FILE), &serde_json::to_vec(&file)?)?;
        Ok(())
    }
}

/// The CLI's own token, as the host owner saved it in `dir`.
pub fn read_user_token(dir: &Path) -> Result<String> {
    Ok(std::fs::read_to_string(dir.join(USER_FILE))
        .context("reading the CLI's agent tools token")?
        .trim()
        .to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_issued_tokens_authenticate_and_revocation_is_final() {
        let mut tokens = Tokens::default();
        let (codex, secret) = tokens
            .mint(Kind::Hosted, "Codex · default", Some("codex"), Some("default"))
            .expect("mint");
        assert_eq!(tokens.authenticate(&secret).as_ref(), Some(&codex));
        assert!(tokens.authenticate("pcxt_forged").is_none());
        assert!(tokens.authenticate(&secret[PREFIX.len()..]).is_none());
        let revoked = tokens.revoke_where(|p| p.host.as_deref() == Some("default"));
        assert_eq!(revoked, vec![codex]);
        assert!(tokens.authenticate(&secret).is_none());
    }

    #[test]
    fn the_cli_token_survives_reopening_and_session_tokens_do_not() {
        let dir = tempfile::tempdir().expect("dir");
        let mut tokens = Tokens::open(dir.path()).expect("open");
        let user = read_user_token(dir.path()).expect("user token");
        let (_, session) = tokens
            .mint(Kind::Session, "Claude · claude", Some("claude"), Some("claude"))
            .expect("session");
        let (_, installed) = tokens
            .mint(Kind::Installed, "Claude Code", Some("claude"), None)
            .expect("installed");
        let reopened = Tokens::open(dir.path()).expect("reopen");
        assert_eq!(reopened.authenticate(&user).map(|p| p.kind), Some(Kind::User));
        assert!(reopened.authenticate(&installed).is_some());
        assert!(reopened.authenticate(&session).is_none());
    }
}
