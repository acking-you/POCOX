//! External Codex bootstrap: `CODEX_HOME` provider setup, ChatGPT login and
//! the system prompt variant.

use super::*;
use crate::engine::execution::{self, Lane};

/// What the external codex has on disk in `CODEX_HOME`, for the onboarding
/// wizard.
pub struct CodexSetupStatusDto {
    /// Resolved `CODEX_HOME` (display path).
    pub codex_home: String,
    /// `config.toml` exists.
    pub has_config: bool,
    /// A credential exists (`auth.json` or `CODEX_ACCESS_TOKEN`).
    pub has_auth: bool,
    /// A non-OpenAI custom provider is configured (authorizes turns on its
    /// own).
    pub has_custom_provider: bool,
    /// `auth.json`'s `auth_mode` (`apikey` / `chatgpt` / …), when present.
    pub auth_mode: Option<String>,
    /// Nothing lets codex authenticate yet → show the setup wizard.
    pub needs_setup: bool,
    /// Active system-prompt variant (`default` / `non_degraded` / `custom`).
    pub prompt_variant: String,
    /// `config.toml`'s top-level `model_provider`, when set.
    pub selected_provider: Option<String>,
    /// `config.toml` exists but could not be read or parsed.
    pub config_error: bool,
    /// What a host inheriting this configuration uses: `custom`, `account`,
    /// `none` or `invalid`. Configured, not verified.
    pub effective_source: String,
}

/// Detect whether the external codex has a usable provider + credentials.
/// Drives the first-run setup wizard: `needs_setup` is `true` when neither a
/// login nor a custom provider is configured.
pub async fn codex_setup_status() -> Result<CodexSetupStatusDto> {
    execution::run(Lane::Read, move || {
        let s = pocox_codex::setup::setup_status()?;
        Ok(CodexSetupStatusDto {
            codex_home: s.codex_home,
            has_config: s.has_config,
            has_auth: s.has_auth,
            has_custom_provider: s.has_custom_provider,
            auth_mode: s.auth_mode,
            needs_setup: s.needs_setup,
            prompt_variant: s.prompt_variant,
            selected_provider: s.selected_provider,
            config_error: s.config_error,
            effective_source: s.effective_source.to_string(),
        })
    })
    .await
}

/// Configure a minimal custom OpenAI-compatible provider (base URL + API key)
/// for the external codex, writing `$CODEX_HOME/config.toml`. No `codex login`
/// is needed — the key rides as the provider's bearer token. `model` is
/// optional (defaults to a sensible model). Takes effect on the next hosting
/// start.
pub async fn codex_setup_provider(
    base_url: String,
    api_key: String,
    model: Option<String>,
) -> Result<()> {
    execution::run(Lane::Read, move || {
        pocox_codex::setup::write_provider_config(&base_url, &api_key, model.as_deref())
    })
    .await
}

/// The active external-codex system-prompt variant (`default` / `non_degraded`
/// / `custom`).
pub async fn codex_prompt_variant() -> Result<String> {
    execution::run(Lane::Read, move || Ok(pocox_codex::setup::setup_status()?.prompt_variant)).await
}

/// Switch the external-codex system prompt. `non_degraded` swaps in the bundled
/// prompt that drops the commentary / intermediary-update mandates (which can
/// starve reasoning, see openai/codex#30364); `default` restores codex's
/// built-in prompt. Takes effect for threads started after the change.
pub async fn codex_set_prompt_variant(variant: String) -> Result<()> {
    execution::run(Lane::Read, move || pocox_codex::setup::set_prompt_variant(&variant)).await
}

/// A started ChatGPT login on the external codex, mirrored for Dart. `mode` is
/// `"browser"` (open `auth_url`) or `"device"` (open `verification_url` and
/// enter `user_code`) — codex falls back to device code when it can't bind its
/// local OAuth callback port.
pub struct CodexLoginStartDto {
    /// `"browser"` or `"device"`.
    pub mode: String,
    /// Opaque id to pass back to [`codex_login_cancel`].
    pub login_id: String,
    /// Browser flow: OAuth URL to open. `None` for device flow.
    pub auth_url: Option<String>,
    /// Device flow: URL to open. `None` for browser flow.
    pub verification_url: Option<String>,
    /// Device flow: one-time code to enter. `None` for browser flow.
    pub user_code: Option<String>,
}

/// codex auth status for the app-server behind `service_key`, mirrored for
/// Dart.
pub struct CodexAuthStatusDto {
    /// Signed in (a credential is active).
    pub authenticated: bool,
    /// Method when signed in (`chatgpt` / `apikey` / …).
    pub method: Option<String>,
}

/// Begin codex's official ChatGPT login on the app-server behind `service_key`
/// (which must be a connected host). Tries the browser flow, falling back to
/// device code when codex can't bind its local callback port (`:1455`/`:1457`,
/// reserved on many Windows machines). codex writes `auth.json` itself —
/// POCOX never generates the credential. Poll [`codex_auth_status`]
/// until `authenticated`. The OAuth HTTP inherits the proxy the host was
/// started with, so a China-network user hosts with a proxy and login goes
/// through it.
pub async fn codex_login_chatgpt_start(service_key: String) -> Result<CodexLoginStartDto> {
    execution::run(Lane::Read, move || {
        let s = app_session::login_chatgpt_start(&service_key)?;
        Ok(CodexLoginStartDto {
            mode: s.mode,
            login_id: s.login_id,
            auth_url: s.auth_url,
            verification_url: s.verification_url,
            user_code: s.user_code,
        })
    })
    .await
}

/// Poll the codex auth status for the app-server behind `service_key`.
pub async fn codex_auth_status(service_key: String) -> Result<CodexAuthStatusDto> {
    execution::run(Lane::Read, move || {
        let (authenticated, method) = app_session::auth_status(&service_key)?;
        Ok(CodexAuthStatusDto {
            authenticated,
            method,
        })
    })
    .await
}

/// Cancel an in-flight ChatGPT login (from [`codex_login_chatgpt_start`]).
pub async fn codex_login_cancel(service_key: String, login_id: String) -> Result<()> {
    execution::run(Lane::Control, move || app_session::login_cancel(&service_key, &login_id)).await
}

/// Sign the external codex out (revoke + delete its `auth.json`) on
/// `service_key`.
pub async fn codex_logout(service_key: String) -> Result<()> {
    execution::run(Lane::Read, move || app_session::codex_logout(&service_key)).await
}
