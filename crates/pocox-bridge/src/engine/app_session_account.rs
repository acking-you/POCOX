//! The host's Codex account: ChatGPT login, auth status, logout, token usage
//! and rate limits.

use super::*;

/// Extract `(tokens_in_context, context_window)` from a `tokenUsage` value
/// shaped `{ total, last: {totalTokens, ...}, modelContextWindow }`. Context
/// occupancy is the most recent turn's total (falling back to the cumulative
/// total); both are best-effort since the server's exact shape can drift.
pub fn parse_token_usage(usage: Option<&Value>) -> (Option<i64>, Option<i64>) {
    let Some(usage) = usage else {
        return (None, None);
    };
    let window = usage
        .get("modelContextWindow")
        .and_then(Value::as_i64)
        .filter(|w| *w > 0);
    let total_of = |k: &str| {
        usage
            .get(k)
            .and_then(|b| b.get("totalTokens"))
            .and_then(Value::as_i64)
    };
    let used = total_of("last")
        .or_else(|| total_of("total"))
        .or_else(|| usage.get("totalTokens").and_then(Value::as_i64));
    (used, window)
}

/// Read the account's rate-limit / quota snapshot (5h + weekly windows). The
/// shape is nested and volatile, so the raw JSON is returned for Dart to parse.
pub fn rate_limits(service_key: &str) -> Result<String> {
    let client = client_for(service_key)?;
    // Omission remains supported by both the new capability-bearing request
    // and older servers that required Option<()> here.
    let res = runtime::runtime().block_on(client.request_no_params("account/rateLimits/read"))?;
    Ok(res.to_string())
}

/// A started codex ChatGPT login. Browser OAuth is tried first; if codex can't
/// bind its fixed local callback port (`:1455`/`:1457`) it falls back to the
/// device-code flow, which needs no local port.
pub struct ChatgptLoginStart {
    /// `"browser"` (open `auth_url`) or `"device"` (open `verification_url` and
    /// enter `user_code`).
    pub mode: String,
    /// Opaque id for [`login_cancel`].
    pub login_id: String,
    /// Browser flow: the OAuth URL to open. `None` for the device flow.
    pub auth_url: Option<String>,
    /// Device flow: the URL to open. `None` for the browser flow.
    pub verification_url: Option<String>,
    /// Device flow: the one-time code the user enters. `None` for browser.
    pub user_code: Option<String>,
}

/// Start a codex ChatGPT login on the app-server behind `service_key`.
///
/// Tries the browser OAuth flow first (smoothest where the callback port is
/// free). On a login-server *bind* failure — codex can't open its fixed
/// `:1455`/`:1457` callback port, which is reserved on many Windows machines
/// (Hyper-V/WSL/Docker reserve those ranges → `os error 10013`) — it
/// transparently retries with the device-code flow, which needs no local port.
/// Either way codex writes `auth.json` itself; poll [`auth_status`] until
/// authenticated. The OAuth HTTP runs inside codex, so it honours the host's
/// proxy.
pub fn login_chatgpt_start(service_key: &str) -> Result<ChatgptLoginStart> {
    let client = client_for(service_key)?;
    // Browser OAuth first: `{ "type": "chatgpt" }`.
    let browser = runtime::runtime()
        .block_on(client.request("account/login/start", json!({ "type": "chatgpt" })));
    match browser {
        Ok(res) => {
            let auth_url = res
                .get("authUrl")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| anyhow!("account/login/start returned no authUrl"))?
                .to_string();
            Ok(ChatgptLoginStart {
                mode: "browser".to_string(),
                login_id: login_id_of(&res),
                auth_url: Some(auth_url),
                verification_url: None,
                user_code: None,
            })
        },
        Err(e) if is_login_server_bind_failure(&e) => {
            // codex couldn't start its local callback server → device code.
            let res = runtime::runtime().block_on(
                client.request("account/login/start", json!({ "type": "chatgptDeviceCode" })),
            )?;
            let verification_url = res
                .get("verificationUrl")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| anyhow!("device-code login returned no verificationUrl"))?
                .to_string();
            let user_code = res
                .get("userCode")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            Ok(ChatgptLoginStart {
                mode: "device".to_string(),
                login_id: login_id_of(&res),
                auth_url: None,
                verification_url: Some(verification_url),
                user_code: Some(user_code),
            })
        },
        Err(e) => Err(e),
    }
}

/// The `loginId` of a `account/login/start` response, or empty when absent.
fn login_id_of(res: &Value) -> String {
    res.get("loginId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

/// Whether a `account/login/start` error is codex failing to *bind* its local
/// OAuth callback server (so the caller retries with device code). codex
/// reports it as "failed to start login server: <os error>"; the raw socket
/// errors (`10013` access-denied for a reserved port, `10048` in-use) are
/// matched too so a wording change upstream doesn't defeat the fallback.
fn is_login_server_bind_failure(e: &anyhow::Error) -> bool {
    let msg = e.to_string().to_lowercase();
    msg.contains("login server")
        || msg.contains("os error 10013")
        || msg.contains("os error 10048")
        || msg.contains("address in use")
        || msg.contains("address already in use")
}

/// The app-server's codex auth status: `(authenticated, method)` where `method`
/// is `chatgpt` / `apikey` / … when signed in. Polled after
/// [`login_chatgpt_start`] to learn when the browser flow completed.
pub fn auth_status(service_key: &str) -> Result<(bool, Option<String>)> {
    let client = client_for(service_key)?;
    let res = runtime::runtime().block_on(client.request("account/read", json!({})))?;
    Ok(auth_status_from_response(&res))
}

pub(super) fn auth_status_from_response(res: &Value) -> (bool, Option<String>) {
    let method = nonempty_str(res.get("account").and_then(|account| account.get("type")))
        .map(|method| if method == "apiKey" { "apikey".into() } else { method });
    (method.is_some(), method)
}

/// Cancel an in-flight browser login (identified by the `login_id` from
/// [`login_chatgpt_start`]).
pub fn login_cancel(service_key: &str, login_id: &str) -> Result<()> {
    let client = client_for(service_key)?;
    runtime::runtime()
        .block_on(client.request("account/login/cancel", json!({ "loginId": login_id })))?;
    Ok(())
}

/// Sign the app-server's codex out: revoke the refresh token (best effort) and
/// delete its `auth.json`.
pub fn codex_logout(service_key: &str) -> Result<()> {
    let client = client_for(service_key)?;
    // `account/logout` takes no params (`Option<()>`, skipped when absent).
    runtime::runtime().block_on(client.request_no_params("account/logout"))?;
    Ok(())
}
