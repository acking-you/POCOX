//! A GitHub session set aside while this installation uses pairing.
//!
//! `[account]` holds one session and switching must not discard the other, so
//! the one a user moved away from waits here, per backend. A file of its own,
//! because `config.toml` rejects unknown fields in older clients. As sensitive
//! as `config.toml` and as private. A pairing identity needs no such thing: its
//! secret stays in the device store, and a JWT is disposable.
//!
//! An entry is found by the backend its session really used, in canonical form,
//! and carries that backend with it: moving to pairing can change the backend
//! `[account]` names, and going back must put it back.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use pocox_core::config::{AccountProvider, Config};
use pocox_core::pairing::CanonicalBackend;
use serde::{Deserialize, Serialize};

use super::lifecycle;
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
    backend: String,
    token: String,
    refresh_token: String,
    login: String,
    #[serde(default)]
    account_id: Option<String>,
}

fn path(support: &Path) -> PathBuf {
    support.join(FILE)
}

/// What an entry is filed under. A GitHub session may be on a plain-http
/// development backend, which pairing would refuse but this file must still
/// tell apart.
fn key_of(backend: &str) -> String {
    match CanonicalBackend::parse(backend) {
        Ok(canonical) => canonical.as_str().to_string(),
        Err(_) => backend.trim().trim_end_matches('/').to_string(),
    }
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
    let backend = account::backend_base(config);
    let mut parked = read(support)?;
    parked.github.insert(key_of(&backend), ParkedGithub {
        backend,
        token: token.to_string(),
        refresh_token: refresh_token.to_string(),
        login: login.to_string(),
        account_id: config.account_id().map(str::to_string),
    });
    write(support, &parked)
}

/// A new GitHub sign-in on `backend` replaces what was set aside there.
pub fn forget_github(support: &Path, backend: &str) -> Result<()> {
    let mut parked = read(support)?;
    if parked.github.remove(&key_of(backend)).is_some() {
        write(support, &parked)?;
    }
    Ok(())
}

/// The entry a resume means: the one for `backend` when named, else the one for
/// the backend `config` names, else the only one there is.
fn chosen(parked: &Parked, backend: Option<&str>, config: &Config) -> Result<Option<String>> {
    if let Some(backend) = backend {
        let key = key_of(backend);
        return Ok(parked.github.contains_key(&key).then_some(key));
    }
    let current = key_of(&account::backend_base(config));
    if parked.github.contains_key(&current) {
        return Ok(Some(current));
    }
    let mut keys = parked.github.keys();
    match (keys.next(), keys.next()) {
        (Some(only), None) => Ok(Some(only.clone())),
        (None, _) => Ok(None),
        _ => bail!(
            "GitHub sessions are set aside on several backends ({}); name one",
            parked.github.keys().cloned().collect::<Vec<_>>().join(", ")
        ),
    }
}

/// The login of the GitHub session a resume would bring back.
pub fn parked_github(support: &Path) -> Result<Option<String>> {
    let parked = read(support)?;
    let config = load_config(support)?;
    let Ok(key) = chosen(&parked, None, &config) else {
        return Ok(None);
    };
    Ok(key
        .and_then(|key| parked.github.get(&key))
        .map(|entry| entry.login.clone()))
}

/// Make a GitHub session set aside here the active account again, stopping what
/// the pairing user owned first and starting it again under GitHub: left alone,
/// those hosts would stay published to a group this installation just left.
/// Returns its login, or `None` when none was set aside. Refuses to replace a
/// GitHub session already here, whose refresh token would be lost unrevoked.
pub async fn resume_github(support: &Path, backend: Option<&str>) -> Result<Option<String>> {
    let _guard = account::refresh_lock().lock().await;
    let config = load_config(support)?;
    refuse_over_github(&config)?;
    if chosen(&read(support)?, backend, &config)?.is_none() {
        return Ok(None);
    }
    lifecycle::before_user_change(support).await;
    let resumed = restore(support, backend);
    match &resumed {
        Ok(Some(_)) => lifecycle::left_pairing(support, &load_config(support)?),
        _ => lifecycle::after_failed_persist(support),
    }
    resumed
}

fn refuse_over_github(config: &Config) -> Result<()> {
    if config.account_provider() == AccountProvider::Github && config.account_token().is_some() {
        bail!(
            "already signed in with GitHub as {}; sign out first",
            config.account_login().unwrap_or("this account")
        );
    }
    Ok(())
}

fn restore(support: &Path, backend: Option<&str>) -> Result<Option<String>> {
    let mut parked = read(support)?;
    let resumed = update_config(support, |latest| {
        refuse_over_github(latest)?;
        let entry = chosen(&parked, backend, latest)?.and_then(|key| parked.github.remove(&key));
        let Some(entry) = entry else {
            return Ok(None);
        };
        latest.set_account_session(
            &entry.token,
            &entry.refresh_token,
            &entry.login,
            entry.account_id.clone(),
        );
        latest.set_account_backend(&entry.backend);
        Ok(Some(entry.login))
    })?;
    if resumed.is_some() {
        write(support, &parked)?;
    }
    Ok(resumed)
}
