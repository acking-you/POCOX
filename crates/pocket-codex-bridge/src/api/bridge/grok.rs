//! Grok Build's own account, for the Grok-account model service of a
//! Grok host. Each call runs a private, short-lived `grok` (no host, no
//! session, no prompt); see `engine::grok_account`.
use anyhow::{Context, Result};
use flutter_rust_bridge::frb;

use crate::engine::grok_account;

/// What Grok reports about its sign-in.
pub struct GrokAccountDto {
    /// A sign-in (or an API key Grok stored) is in effect.
    pub signed_in: bool,
    /// The effective auth method id (`cached_token`, `xai.api_key`, ...).
    pub method: Option<String>,
    /// The account email, when signed in with an account.
    pub email: Option<String>,
}

/// Where one Grok sign-in is.
pub struct GrokSignInDto {
    /// `starting`, `waiting` (open `url`), `signed_in`, `failed`,
    /// `cancelled`.
    pub phase: String,
    /// The verification URL to open in a browser.
    pub url: Option<String>,
    /// The code that URL confirms, for display.
    pub code: Option<String>,
    /// The signed-in account, once done.
    pub email: Option<String>,
    /// Why it failed.
    pub error: Option<String>,
}

fn account(account: pocket_codex_host_svc::acp::grok_control::GrokAccount) -> GrokAccountDto {
    GrokAccountDto {
        signed_in: account.signed_in,
        method: account.method,
        email: account.email,
    }
}

/// The Grok account a Grok-account host on this computer would use, read
/// through `program` (default: the installed `grok`).
pub fn grok_account_status(program: Option<String>) -> Result<GrokAccountDto> {
    grok_account::status(program.as_deref()).map(account)
}

/// Sign out of Grok on this computer.
pub fn grok_sign_out(program: Option<String>) -> Result<GrokAccountDto> {
    grok_account::sign_out(program.as_deref()).map(account)
}

/// Begin Grok's device sign-in; returns the attempt id to poll.
pub fn grok_sign_in_start(program: Option<String>) -> Result<String> {
    grok_account::sign_in_start(program.as_deref()).map(|id| id.to_string())
}

/// Where sign-in `attempt` is.
#[frb(sync)]
pub fn grok_sign_in_state(attempt: String) -> Result<GrokSignInDto> {
    let id = attempt.parse().context("invalid sign-in attempt")?;
    let state = grok_account::sign_in_state(id)?;
    Ok(GrokSignInDto {
        phase: state.phase,
        url: state.url,
        code: state.code,
        email: state.email,
        error: state.error,
    })
}

/// Cancel sign-in `attempt` and stop its `grok`.
pub fn grok_sign_in_cancel(attempt: String) -> Result<()> {
    let id = attempt.parse().context("invalid sign-in attempt")?;
    grok_account::sign_in_cancel(id)
}
