//! Hosted account: GitHub device-flow and web login, the signed-in user and
//! account services.

use super::*;

/// A started device flow, mirrored for Dart: show the code + URL, then poll.
pub struct DeviceCodeDto {
    /// Code the user types at [`Self::verification_uri`].
    pub user_code: String,
    /// URL the user opens to enter the code.
    pub verification_uri: String,
    /// Opaque handle passed back to [`account_login_poll`].
    pub poll_handle: String,
    /// Minimum seconds between polls.
    pub interval_secs: u64,
    /// Seconds until the flow expires.
    pub expires_in_secs: u64,
    /// Resolved backend base URL to echo back to [`account_login_poll`].
    pub backend: String,
}

/// Signed-in identity mirrored for Dart.
pub struct AccountUserDto {
    /// GitHub login/handle.
    pub login: String,
    /// GitHub account id, if known.
    pub account_id: Option<String>,
}

/// One service in the account, mirrored for Dart (the `pcxu:` prefix stripped).
pub struct AccountServiceDto {
    /// Device id segment.
    pub device: String,
    /// `app`, `acp`, `api` or `meta` (see [`ServiceIdDto::kind`]).
    pub kind: String,
    /// Instance name segment.
    pub name: String,
}

/// Outcome of one device-flow poll, mirrored for Dart. `status` is one of
/// `pending` / `slow_down` / `authorized` / `expired` / `denied`; `login` is
/// set only when `authorized`.
pub struct AccountPollDto {
    /// Poll status string.
    pub status: String,
    /// Signed-in login, when `status == "authorized"`.
    pub login: Option<String>,
    /// GitHub account id, when authorized and known.
    pub account_id: Option<String>,
}

/// Begin a GitHub device-flow login. `backend` overrides the configured /
/// default backend (and is remembered on success).
pub fn account_login_start(backend: Option<String>) -> Result<DeviceCodeDto> {
    let dir = runtime::support_dir()?;
    let start = runtime::runtime().block_on(account::device_start(&dir, backend.as_deref()))?;
    Ok(DeviceCodeDto {
        user_code: start.user_code,
        verification_uri: start.verification_uri,
        poll_handle: start.poll_handle,
        interval_secs: start.interval_secs,
        expires_in_secs: start.expires_in_secs,
        backend: start.backend,
    })
}

/// Poll a device flow once. On `authorized` the session is persisted and the
/// app switches to account mode.
pub fn account_login_poll(poll_handle: String, backend: String) -> Result<AccountPollDto> {
    let dir = runtime::support_dir()?;
    let outcome = runtime::runtime().block_on(account::device_poll(&dir, &backend, poll_handle))?;
    Ok(match outcome {
        account::PollOutcome::Pending => AccountPollDto {
            status: "pending".to_string(),
            login: None,
            account_id: None,
        },
        account::PollOutcome::SlowDown => AccountPollDto {
            status: "slow_down".to_string(),
            login: None,
            account_id: None,
        },
        account::PollOutcome::Expired => AccountPollDto {
            status: "expired".to_string(),
            login: None,
            account_id: None,
        },
        account::PollOutcome::Denied => AccountPollDto {
            status: "denied".to_string(),
            login: None,
            account_id: None,
        },
        account::PollOutcome::Authorized {
            login,
            account_id,
        } => {
            // Signed in: services are now the account's.
            transport::context_changed();
            AccountPollDto {
                status: "authorized".to_string(),
                login: Some(login),
                account_id,
            }
        },
    })
}

/// A started web (authorization-code) login, mirrored for Dart. The caller
/// opens [`Self::authorize_url`] in a browser, captures the redirect to its
/// `redirect_uri`, checks the redirect's `state` equals [`Self::state`], then
/// calls [`account_web_login_exchange`] with the redirect's `exchange_code` and
/// [`Self::code_verifier`].
pub struct WebLoginStartDto {
    /// GitHub authorization URL to open in a browser.
    pub authorize_url: String,
    /// CSRF state to match against the redirect's `state`.
    pub state: String,
    /// PKCE verifier to pass back to [`account_web_login_exchange`].
    pub code_verifier: String,
    /// Resolved backend base URL to echo back to
    /// [`account_web_login_exchange`].
    pub backend: String,
}

/// Begin a web (browser-redirect) GitHub login. `redirect_uri` is the
/// platform-specific callback the browser returns to (the app's custom scheme
/// on mobile, a loopback URL on desktop). `backend` overrides the configured /
/// default backend (and is remembered on a successful exchange).
pub fn account_web_login_start(
    redirect_uri: String,
    backend: Option<String>,
) -> Result<WebLoginStartDto> {
    let dir = runtime::support_dir()?;
    let start = runtime::runtime().block_on(account::web_login_start(
        &dir,
        &redirect_uri,
        backend.as_deref(),
    ))?;
    Ok(WebLoginStartDto {
        authorize_url: start.authorize_url,
        state: start.state,
        code_verifier: start.code_verifier,
        backend: start.backend,
    })
}

/// Redeem the one-time `exchange_code` (with its PKCE `code_verifier`) from the
/// browser redirect. On success the session is persisted and the app switches
/// to account mode. Returns the signed-in identity.
pub fn account_web_login_exchange(
    exchange_code: String,
    code_verifier: String,
    backend: String,
) -> Result<AccountUserDto> {
    let dir = runtime::support_dir()?;
    let outcome = runtime::runtime().block_on(account::web_login_exchange(
        &dir,
        &backend,
        exchange_code,
        code_verifier,
    ))?;
    match outcome {
        account::PollOutcome::Authorized {
            login,
            account_id,
        } => {
            transport::context_changed();
            Ok(AccountUserDto {
                login,
                account_id,
            })
        },
        _ => Err(anyhow!("web exchange did not authorize")),
    }
}

/// The signed-in user (verified against the backend), or `None` if not signed
/// in.
pub fn account_current_user() -> Result<Option<AccountUserDto>> {
    let dir = runtime::support_dir()?;
    Ok(runtime::runtime()
        .block_on(account::current_user(&dir))?
        .map(|u| AccountUserDto {
            login: u.login,
            account_id: u.account_id,
        }))
}

/// Sign out: revoke the refresh token (best effort) and clear the local
/// session.
pub fn account_logout() -> Result<()> {
    let dir = runtime::support_dir()?;
    let result = runtime::runtime().block_on(account::logout(&dir));
    // Whatever the revocation did, this device no longer acts as the account.
    transport::context_changed();
    result
}

/// List the account's services from the backend.
pub fn account_services() -> Result<Vec<AccountServiceDto>> {
    let dir = runtime::support_dir()?;
    Ok(runtime::runtime()
        .block_on(account::services(&dir))?
        .into_iter()
        .map(|s| AccountServiceDto {
            device: s.device,
            kind: s.kind.as_key_segment().to_string(),
            name: s.name,
        })
        .collect())
}

/// Deregister one of the account's services from the relay (best-effort; a
/// still-running host re-registers shortly after). `kind` is the service's
/// key segment (`"app"`, `"acp"`, `"api"` or `"meta"`).
pub fn account_deregister_service(device: String, kind: String, name: String) -> Result<()> {
    let dir = runtime::support_dir()?;
    runtime::runtime().block_on(account::deregister_service(&dir, &device, &kind, &name))
}
