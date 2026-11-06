//! This installation's way to the device identity: the store for a backend, and
//! a session from its secret.
//!
//! Any installation can use the identity without it being the active account:
//! that is the staged principal a first screen, or a device still on GitHub,
//! works through. Its JWT stays in memory and nothing here touches `[account]`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

use anyhow::{Context, Result};
use pocox_account_proto::http::session_token_exp;
use pocox_account_proto::pairing::{parse_label, DeviceSession, PairingErrorCode};
use pocox_core::config::{AccountProvider, Config, Mode};
use pocox_core::device::DeviceMetadata;
use pocox_core::pairing::{CanonicalBackend, DeviceRecord, DeviceStore, SessionMark, StoreKey};
use reqwest::RequestBuilder;
use serde::de::DeserializeOwned;

use super::client::Client;
use super::error::{code_of, no_device_error, signed_out_error};
use super::session;
use crate::engine::account;
use crate::engine::config::load_config;

/// A staged JWT, reused until shortly before it ends.
struct Staged {
    secret_digest: String,
    token: String,
}

fn staged() -> std::sync::MutexGuard<'static, HashMap<String, Staged>> {
    static STAGED: LazyLock<Mutex<HashMap<String, Staged>>> = LazyLock::new(Mutex::default);
    STAGED.lock().unwrap_or_else(|poison| poison.into_inner())
}

/// Which device store a test's installation uses, so two "devices" can live in
/// one test process.
#[cfg(test)]
pub(super) static TEST_STORES: Mutex<Option<TestStores>> = Mutex::new(None);

/// Each test installation's store directory and device scope.
#[cfg(test)]
pub(super) type TestStores = HashMap<PathBuf, (PathBuf, Option<String>)>;

/// This installation's view of one backend's device identity.
#[derive(Clone)]
pub struct Identity {
    pub(super) support: PathBuf,
    pub(super) backend: CanonicalBackend,
    pub(super) store: DeviceStore,
    pub(super) client: Client,
}

impl Identity {
    /// The identity for `backend`, which must be `https://` or loopback.
    pub fn open(support: &Path, backend: &str) -> Result<Self> {
        let backend = CanonicalBackend::parse(backend)?;
        Ok(Self {
            support: support.to_path_buf(),
            store: store_for(support, &backend)?,
            client: Client::new(support, &backend)?,
            backend,
        })
    }

    /// The identity for the backend `config` names.
    pub fn of_config(support: &Path, config: &Config) -> Result<Self> {
        Self::open(support, &account::backend_base(config))
    }

    /// The canonical backend.
    pub fn backend(&self) -> &str {
        self.backend.as_str()
    }

    /// The saved record. An unreadable store is an error, never a new device.
    pub fn read(&self) -> Result<Option<DeviceRecord>> {
        self.store.read()
    }

    /// The record of a device that exists, for work on it. A `[account]` with
    /// nothing behind it is signed out on the way; a device with no identity is
    /// told so, because only [`Self::ensure_record`]'s callers may start one.
    pub(super) async fn require_record(&self) -> Result<DeviceRecord> {
        if session::sign_out_if_orphaned(self).await? {
            return Err(signed_out_error());
        }
        self.read()?
            .filter(|record| record.registered)
            .ok_or_else(no_device_error)
    }

    /// The record, starting one when there is none: preparing, activating,
    /// previewing a code and asking to recover. A restored `[account]` is
    /// signed out first, or the new secret would stand behind its JWT.
    pub(super) async fn ensure_record(&self) -> Result<DeviceRecord> {
        session::sign_out_if_orphaned(self).await?;
        self.store.ensure_secret()
    }

    /// Whether `[account]` here is this very identity. A chosen self-host mode
    /// means it is not: pairing sleeps while that stands.
    pub(super) fn is_active(&self, config: &Config) -> bool {
        config.account_provider() == AccountProvider::DeviceCode
            && config.account_mode() == Mode::Account
            && CanonicalBackend::parse(&account::backend_base(config))
                .is_ok_and(|backend| backend == self.backend)
    }

    /// Whether this installation's active account is this identity.
    pub fn is_active_here(&self) -> Result<bool> {
        Ok(self.is_active(&load_config(&self.support)?))
    }

    /// A fresh session from `record`'s secret: created when the backend has yet
    /// to acknowledge it, which is the idempotent retry after a lost response,
    /// and refreshed afterward, when an unknown secret must stay unknown.
    pub(super) async fn mint(
        &self,
        record: &DeviceRecord,
        label: Option<&str>,
    ) -> Result<DeviceSession> {
        let session = if record.registered {
            self.client.refresh(record.secret()).await?
        } else {
            let label = label.and_then(parse_label).unwrap_or_else(default_label);
            let platform = Some(DeviceMetadata::current().os);
            self.client
                .create(record.secret(), &label, platform)
                .await?
        };
        let secret = record.secret().to_string();
        let mark = SessionMark {
            device_id: session.device_id.clone(),
            generation: session.generation,
        };
        self.store
            .update(|current| {
                if current.secret() == secret {
                    current.registered = true;
                    current.session = Some(mark);
                }
            })
            .context("recording the session in the device store")?;
        self.remember_staged(&secret, &session);
        Ok(session)
    }

    fn remember_staged(&self, secret: &str, session: &DeviceSession) {
        staged().insert(self.store.key().slot(), Staged {
            secret_digest: digest(secret),
            token: session.token.clone(),
        });
    }

    fn forget_staged(&self) {
        staged().remove(&self.store.key().slot());
    }

    /// A JWT for this identity whether or not it is the active account here.
    /// Starts nothing: with no secret saved there is nothing to prove.
    pub(super) async fn token(&self) -> Result<String> {
        let mut config = load_config(&self.support)?;
        if self.is_active(&config) {
            return session::valid_token(&self.support, &mut config, self.backend()).await;
        }
        let record = self.read()?.ok_or_else(no_device_error)?;
        let cached = staged()
            .get(&self.store.key().slot())
            .filter(|cached| {
                cached.secret_digest == digest(record.secret())
                    && session_token_exp(&cached.token)
                        .is_some_and(|exp| exp > chrono::Utc::now().timestamp() + 60)
            })
            .map(|cached| cached.token.clone());
        match cached {
            Some(token) => Ok(token),
            None => Ok(self.mint(&record, None).await?.token),
        }
    }

    /// Mint a fresh session for the active installation now, so its stored
    /// label follows a rename of this device. Nothing for an inactive one.
    pub(super) async fn refresh_label(&self) -> Result<()> {
        let mut config = load_config(&self.support)?;
        if self.is_active(&config) {
            session::refresh_now(&self.support, &mut config, self.backend()).await?;
        }
        Ok(())
    }

    async fn fresh_token(&self) -> Result<String> {
        self.forget_staged();
        let mut config = load_config(&self.support)?;
        if self.is_active(&config) {
            return session::refresh_now(&self.support, &mut config, self.backend()).await;
        }
        let record = self.read()?.ok_or_else(no_device_error)?;
        Ok(self.mint(&record, None).await?.token)
    }

    /// Call a JWT route, refreshing once when this JWT's generation has moved
    /// on.
    pub(super) async fn call<T: DeserializeOwned>(
        &self,
        what: &str,
        build: impl Fn(&Client, &str) -> RequestBuilder,
    ) -> Result<T> {
        let token = self.token().await?;
        match self.client.json(build(&self.client, &token), what).await {
            Err(error) if code_of(&error) == Some(PairingErrorCode::SessionStale) => {
                let token = self.fresh_token().await?;
                self.client.json(build(&self.client, &token), what).await
            },
            other => other,
        }
    }

    /// [`Self::call`] for a route that answers with no body.
    pub(super) async fn call_empty(
        &self,
        what: &str,
        build: impl Fn(&Client, &str) -> RequestBuilder,
    ) -> Result<()> {
        let token = self.token().await?;
        match self
            .client
            .accepted(build(&self.client, &token), what)
            .await
        {
            Err(error) if code_of(&error) == Some(PairingErrorCode::SessionStale) => {
                let token = self.fresh_token().await?;
                self.client
                    .accepted(build(&self.client, &token), what)
                    .await?;
                Ok(())
            },
            Err(error) => Err(error),
            Ok(_) => Ok(()),
        }
    }
}

/// This OS account's store for `backend`.
fn store_for(support: &Path, backend: &CanonicalBackend) -> Result<DeviceStore> {
    #[cfg(test)]
    if let Some((root, scope)) = TEST_STORES
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .as_ref()
        .and_then(|stores| stores.get(support).cloned())
    {
        return DeviceStore::at(&root, StoreKey::new(backend, "test-native", scope));
    }
    let _ = support;
    DeviceStore::open(StoreKey::current(backend))
}

fn default_label() -> String {
    parse_label(&DeviceMetadata::current().hostname).unwrap_or_else(|| "device".to_string())
}

pub(super) fn digest(secret: &str) -> String {
    pocox_core::history_sync::digest_bytes(secret.as_bytes())
}

/// Whether this process has any device store to look in, without making one.
pub(super) fn store_exists(support: &Path) -> bool {
    #[cfg(test)]
    if TEST_STORES
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .as_ref()
        .is_some_and(|stores| stores.contains_key(support))
    {
        return true;
    }
    let _ = support;
    pocox_core::pairing::device_store_exists()
}
