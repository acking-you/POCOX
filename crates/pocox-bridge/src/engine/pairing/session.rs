//! The active pairing session: `[account]` with `provider = "device_code"`.
//!
//! A refreshed session is compared with this installation's own user *before*
//! it is written. On a change, what the old user owned stops first; only then
//! does the new user reach `config.toml`. The secret is read from the store on
//! every use, so a restored `config.toml` without its store is simply signed
//! out and a present but unreadable store stays an error.

use std::path::Path;
use std::time::Duration;

use anyhow::{anyhow, bail, Result};
use pocox_account_proto::http::{session_token_device, session_token_exp, RelayCredentialResponse};
use pocox_account_proto::pairing::{DeviceSession, PairingErrorCode};
use pocox_core::config::{AccountProvider, Config, Mode};
use pocox_core::pairing::{ActiveAccount, DeviceRecord};
use reqwest::Method;

use super::error::{code_of, signed_out_error, PairingError};
use super::identity::Identity;
use super::{lifecycle, parked};
use crate::engine::account;
use crate::engine::config::{load_config, update_config};

/// A token this close to its end is refreshed rather than used.
const EXPIRY_MARGIN_SECS: i64 = 60;
/// How many times a route that says "another request is working on this device"
/// is asked again before the caller hears about it.
const BUSY_RETRIES: usize = 3;
const BUSY_WAIT_LIMIT_SECS: u64 = 5;

/// How a session reaches `[account]`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Apply {
    /// A refresh of what is already active here.
    Refresh,
    /// The user's explicit choice to make this identity the active account.
    Adopt,
}

/// What this installation's active account is, for telling a later result
/// whether it still applies.
pub(super) fn active_account(config: &Config) -> ActiveAccount {
    let provider = if config.account.mode.as_deref().map(str::trim) == Some("self_host") {
        Some("self_host".to_string())
    } else if config.account_token().is_some() {
        Some(
            match config.account_provider() {
                AccountProvider::Github => "github",
                AccountProvider::DeviceCode => "device_code",
            }
            .to_string(),
        )
    } else {
        None
    };
    ActiveAccount {
        provider,
        account_id: config.account_id().map(str::to_string),
        login: config.account_login().map(str::to_string),
    }
}

/// Whether `config` is still the account `before` describes. A device's label
/// is display only and can change, so its id alone says.
pub(super) fn same_account(before: &ActiveAccount, config: &Config) -> bool {
    let now = active_account(config);
    now.provider == before.provider
        && now.account_id == before.account_id
        && (now.account_id.is_some() || now.login == before.login)
}

/// Who a long-running process works for: the account and the backend it is on.
#[derive(Debug, Clone)]
pub struct Principal {
    account: ActiveAccount,
    backend: Option<String>,
}

impl Principal {
    /// Who `config` names.
    pub fn of(config: &Config) -> Self {
        Self {
            account: active_account(config),
            backend: config
                .account_backend()
                .map(|backend| backend.trim_end_matches('/').to_string()),
        }
    }

    /// Whether this is a pairing session.
    pub fn is_device(&self) -> bool {
        self.account.provider.as_deref() == Some(AccountProvider::DEVICE_CODE)
    }

    /// Whether what runs under this must stop now that `latest` is what
    /// `config.toml` names. Moves that never touch pairing keep the rules they
    /// have always had.
    pub fn moved_to(&self, latest: &Self) -> bool {
        (self.is_device() || latest.is_device())
            && (self.backend != latest.backend
                || self.account.provider != latest.account.provider
                || self.account.account_id != latest.account.account_id
                || (self.account.account_id.is_none()
                    && self.account.login != latest.account.login))
    }
}

/// `config`'s token, while it is comfortably alive and the session another
/// installation last saw in the shared store is this token's own. A mismatch
/// means the identity moved under this installation: learn that before issuing
/// any new authenticated work, rather than from the next refusal.
fn still_good(config: &Config, record: &DeviceRecord) -> Option<String> {
    let token = config.account_token()?;
    let alive = session_token_exp(token)
        .is_some_and(|exp| exp > chrono::Utc::now().timestamp() + EXPIRY_MARGIN_SECS);
    if !alive {
        return None;
    }
    let mark = record.session.as_ref()?;
    let current = session_token_device(token).is_some_and(|(device_id, generation)| {
        device_id == mark.device_id && generation == mark.generation
    });
    current.then(|| token.to_string())
}

/// Whether a `[account]` naming `identity` has nothing behind it: no record, or
/// one no session ever came from. It was restored from elsewhere, or its store
/// was lost, and that JWT speaks for a device this store knows nothing about.
fn is_orphaned(record: Option<&DeviceRecord>) -> bool {
    record.is_none_or(|record| record.session.is_none())
}

/// Sign out a `[account]` naming `identity` with nothing behind it, before
/// anything is created or sent on its behalf. Returns whether it did.
pub(super) async fn sign_out_if_orphaned(identity: &Identity) -> Result<bool> {
    let mut config = load_config(&identity.support)?;
    if !identity.is_active(&config) || !is_orphaned(identity.read()?.as_ref()) {
        return Ok(false);
    }
    let error = sign_out_installation(&identity.support, &mut config).await;
    if error.is::<super::SignedOut>() {
        Ok(true)
    } else {
        Err(error)
    }
}

/// A usable JWT for the active device session, refreshing when needed.
pub async fn valid_token(support: &Path, config: &mut Config, backend: &str) -> Result<String> {
    let identity = Identity::open(support, backend)?;
    let record = identity.read()?;
    let record = match record {
        Some(record) if !is_orphaned(Some(&record)) => record,
        _ => return Err(sign_out_installation(support, config).await),
    };
    if let Some(token) = still_good(config, &record) {
        return Ok(token);
    }
    refresh(identity, config, false).await
}

/// A fresh JWT for the active device session, whatever the current one says.
pub async fn refresh_now(support: &Path, config: &mut Config, backend: &str) -> Result<String> {
    refresh(Identity::open(support, backend)?, config, true).await
}

async fn refresh(identity: Identity, config: &mut Config, force: bool) -> Result<String> {
    // Before waiting too: a change holds the lock below for as long as it takes to
    // stop what the old user owned, which may include the start asking for this.
    lifecycle::refuse_while_changing(&identity.support)?;
    let before = active_account(config);
    // The credential refresher can be what got here, and a change of user stops
    // it: this work finishes in its own task, or a half-applied change would be
    // left behind.
    let (token, latest) = tokio::spawn(async move {
        let _guard = account::refresh_lock().lock().await;
        lifecycle::refuse_while_changing(&identity.support)?;
        let latest = load_config(&identity.support)?;
        if !same_account(&before, &latest) || !identity.is_active(&latest) {
            bail!("the account changed while waiting for its token");
        }
        let record = identity.read()?;
        let record = match record {
            Some(record) if !is_orphaned(Some(&record)) => record,
            _ => {
                let mut latest = latest;
                return Err(sign_out_installation(&identity.support, &mut latest).await);
            },
        };
        if !force {
            if let Some(token) = still_good(&latest, &record) {
                return Ok((token, latest));
            }
        }
        if let Some(refusal) = lifecycle::known_dead(record.secret()) {
            return Err(refusal.into());
        }
        match identity.mint(&record, None).await {
            Ok(session) => {
                let Some(token) = apply_locked(&identity, session, Apply::Refresh, &before).await?
                else {
                    bail!("the account changed during a token refresh");
                };
                Ok((token, load_config(&identity.support)?))
            },
            Err(error) => {
                if matches!(
                    code_of(&error),
                    Some(PairingErrorCode::DeviceSuperseded | PairingErrorCode::DeviceUnknown)
                ) {
                    // Only while this is still what this installation runs: a user who
                    // moved on meanwhile has hosts this answer says nothing about.
                    let latest = load_config(&identity.support)?;
                    if same_account(&before, &latest) && identity.is_active(&latest) {
                        lifecycle::identity_dead(&identity.support, record.secret(), &error).await;
                    }
                }
                Err(error)
            },
        }
    })
    .await
    .map_err(|_| anyhow!("refreshing the session stopped unexpectedly"))??;
    *config = latest;
    Ok(token)
}

/// Whether a session asked for while `expected` was active may still reach
/// `config`. The user may have signed in elsewhere or out while the request
/// ran, and what they did last stands.
fn still_applies(
    identity: &Identity,
    how: Apply,
    expected: &ActiveAccount,
    config: &Config,
) -> bool {
    same_account(expected, config) && (how == Apply::Adopt || identity.is_active(config))
}

/// Bring `session` into `[account]`, comparing its user with this
/// installation's own first. Returns its token, or `None` when the account is
/// no longer `expected`, which was read before the request that got `session`:
/// then nothing here changed. One at a time within a process, like a refresh,
/// so what a change stops and what it writes cannot interleave with another's.
pub(super) async fn apply(
    identity: &Identity,
    session: DeviceSession,
    how: Apply,
    expected: &ActiveAccount,
) -> Result<Option<String>> {
    let _guard = account::refresh_lock().lock().await;
    apply_locked(identity, session, how, expected).await
}

async fn apply_locked(
    identity: &Identity,
    session: DeviceSession,
    how: Apply,
    expected: &ActiveAccount,
) -> Result<Option<String>> {
    let support = identity.support.as_path();
    let before = load_config(support)?;
    if !still_applies(identity, how, expected, &before) {
        return Ok(None);
    }
    // What can fail locally goes first, while nothing has stopped.
    if how == Apply::Adopt {
        parked::park_github(support, &before)?;
    }
    let same_user = identity.is_active(&before) && before.account_id() == Some(&session.account_id);
    if !same_user {
        lifecycle::before_user_change(support).await;
    }
    let written = update_config(support, |latest| {
        if !still_applies(identity, how, expected, latest) {
            return Ok(false);
        }
        if how == Apply::Adopt {
            // Another process may have rotated this token since it was set aside.
            if latest.account_refresh_token() != before.account_refresh_token() {
                parked::park_github(support, latest)?;
            }
            latest.set_account_backend(identity.backend());
            latest.set_mode(Mode::Account);
        }
        latest.set_device_session(&session.token, &session.login, &session.account_id);
        Ok(true)
    });
    match written {
        Ok(true) => {
            lifecycle::after_persist(support, &session);
            Ok(Some(session.token))
        },
        Ok(false) => {
            lifecycle::after_failed_persist(support);
            Ok(None)
        },
        Err(error) => {
            lifecycle::after_failed_persist(support);
            Err(error)
        },
    }
}

/// A `[account]` naming a pairing session whose store has no record: restored
/// from a backup, or its store was lost. Its JWT must not linger as if it could
/// be refreshed, and nothing else here (a self-host setup) is touched.
async fn sign_out_installation(support: &Path, config: &mut Config) -> anyhow::Error {
    let before = active_account(config);
    let cleared = update_config(support, |latest| {
        if same_account(&before, latest) && latest.account_provider() == AccountProvider::DeviceCode
        {
            let mode = latest.account.mode.clone();
            latest.clear_account();
            latest.account.mode = mode;
        }
        Ok(latest.clone())
    });
    match cleared {
        Ok(latest) => {
            lifecycle::before_user_change(support).await;
            lifecycle::left_pairing(support, &latest);
            *config = latest;
            signed_out_error()
        },
        Err(error) => error,
    }
}

/// `GET /v1/me` as the active device: the cheapest question that tells a live
/// session from one whose generation moved on, which refreshes it.
pub(super) async fn check_in(identity: &Identity) -> Result<pocox_account_proto::http::MeResponse> {
    identity
        .call("/v1/me", |client, token| client.request(Method::GET, "/v1/me").bearer_auth(token))
        .await
}

/// `/v1/me` for the active device.
pub async fn me(support: &Path, backend: &str) -> Result<pocox_account_proto::http::MeResponse> {
    check_in(&Identity::open(support, backend)?).await
}

/// `GET /v1/services` for the active device.
pub async fn services(
    support: &Path,
    backend: &str,
) -> Result<Vec<pocox_account_proto::http::ServiceEntry>> {
    let body: pocox_account_proto::http::ServicesResponse = Identity::open(support, backend)?
        .call("/v1/services", |client, token| {
            client
                .request(Method::GET, "/v1/services?include_acp=true&include_opencode=true")
                .bearer_auth(token)
        })
        .await?;
    Ok(body.services)
}

/// `DELETE /v1/services/..` for the active device.
pub async fn deregister(
    support: &Path,
    backend: &str,
    device: &str,
    kind: &str,
    name: &str,
) -> Result<()> {
    Identity::open(support, backend)?
        .call_empty("DELETE /v1/services", |client, token| {
            client
                .request(Method::DELETE, &format!("/v1/services/{device}/{kind}/{name}"))
                .bearer_auth(token)
        })
        .await
}

/// This device's relay credential. While another request is working on this
/// device the backend answers `rate_limited` with a short wait, rather than
/// queueing, and two installations sharing a device can see that.
pub async fn relay_credential(support: &Path, backend: &str) -> Result<RelayCredentialResponse> {
    let identity = Identity::open(support, backend)?;
    let mut attempts = 0;
    loop {
        let answer = identity
            .call("/v1/relay", |client, token| {
                client.request(Method::GET, "/v1/relay").bearer_auth(token)
            })
            .await;
        let wait = match &answer {
            Err(error) => short_wait(error),
            Ok(_) => None,
        };
        match wait {
            Some(wait) if attempts < BUSY_RETRIES => {
                attempts += 1;
                tokio::time::sleep(Duration::from_secs(wait)).await;
            },
            _ => return answer,
        }
    }
}

fn short_wait(error: &anyhow::Error) -> Option<u64> {
    let refusal = error
        .chain()
        .find_map(|cause| cause.downcast_ref::<PairingError>())?;
    (refusal.code == PairingErrorCode::RateLimited)
        .then_some(refusal.retry_after)
        .flatten()
        .filter(|wait| *wait <= BUSY_WAIT_LIMIT_SECS)
}
