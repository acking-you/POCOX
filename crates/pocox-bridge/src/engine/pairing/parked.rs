//! A GitHub session set aside while this installation uses pairing.
//!
//! `[account]` holds one session and switching must not discard the other, so
//! the one a user moved away from waits here, per backend. A file of its own,
//! because `config.toml` rejects unknown fields in older clients. As sensitive
//! as `config.toml` and as private. A pairing identity needs no such thing: its
//! secret stays in the device store, and a JWT is disposable.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use pocox_core::config::{AccountProvider, Config};
use serde::{Deserialize, Serialize};

use crate::engine::account;
use crate::engine::config::{load_config, update_config};

const FILE: &str = "parked-accounts.json";
const VERSION: u32 = 1;

#[derive(Serialize, Deserialize)]
struct Parked {
    version: u32,
    github: BTreeMap<String, ParkedGithub>,
}

#[derive(Clone, Serialize, Deserialize)]
struct ParkedGithub {
    token: String,
    refresh_token: String,
    login: String,
    #[serde(default)]
    account_id: Option<String>,
}

fn path(support: &Path) -> PathBuf {
    support.join(FILE)
}

fn read(support: &Path) -> Result<Parked> {
    match std::fs::read(path(support)) {
        Ok(bytes) => {
            // Parse errors can quote the input, which holds tokens.
            let parked: Parked = serde_json::from_slice(&bytes)
                .map_err(|_| anyhow::anyhow!("the set-aside GitHub session cannot be read"))?;
            anyhow::ensure!(parked.version == VERSION, "the set-aside GitHub session is too new");
            Ok(parked)
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Parked {
            version: VERSION,
            github: BTreeMap::new(),
        }),
        Err(error) => Err(error).context("reading the set-aside GitHub session"),
    }
}

fn write(support: &Path, parked: &Parked) -> Result<()> {
    std::fs::create_dir_all(support).context("creating the support directory")?;
    let bytes = serde_json::to_vec(parked).context("encoding the set-aside GitHub session")?;
    pocox_core::fs::write_private_atomic(&path(support), &bytes)
        .context("saving the set-aside GitHub session")
}

/// Set aside `config`'s session if it is GitHub's, before pairing replaces it.
pub(super) fn park_github(support: &Path, config: &Config) -> Result<()> {
    if config.account_provider() != AccountProvider::Github {
        return Ok(());
    }
    let (Some(token), Some(refresh_token), Some(login)) =
        (config.account_token(), config.account_refresh_token(), config.account_login())
    else {
        return Ok(());
    };
    let mut parked = read(support)?;
    parked
        .github
        .insert(account::backend_base(config), ParkedGithub {
            token: token.to_string(),
            refresh_token: refresh_token.to_string(),
            login: login.to_string(),
            account_id: config.account_id().map(str::to_string),
        });
    write(support, &parked)
}

/// A new GitHub sign-in on `backend` replaces what was set aside there.
pub(in crate::engine) fn forget_github(support: &Path, backend: &str) -> Result<()> {
    let mut parked = read(support)?;
    if parked.github.remove(backend).is_some() {
        write(support, &parked)?;
    }
    Ok(())
}

/// The login of the GitHub session set aside for `config`'s backend.
pub fn parked_github(support: &Path) -> Result<Option<String>> {
    let backend = account::backend_base(&load_config(support)?);
    Ok(read(support)?
        .github
        .remove(&backend)
        .map(|entry| entry.login))
}

/// Make the GitHub session set aside for this backend the active account again.
/// Returns its login, or `None` when nothing was set aside. The caller moves
/// the transport's context, as for any change of account.
pub fn resume_github(support: &Path) -> Result<Option<String>> {
    let mut parked = read(support)?;
    let resumed = update_config(support, |latest| {
        let backend = account::backend_base(latest);
        let Some(entry) = parked.github.remove(&backend) else {
            return Ok(None);
        };
        latest.set_account_session(
            &entry.token,
            &entry.refresh_token,
            &entry.login,
            entry.account_id.clone(),
        );
        Ok(Some(entry.login))
    })?;
    if resumed.is_some() {
        write(support, &parked)?;
        super::lifecycle::release_hold();
    }
    Ok(resumed)
}
