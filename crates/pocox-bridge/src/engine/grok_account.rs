//! Grok Build's own account and local sessions, through a private,
//! short-lived `grok agent stdio` ([`GrokControl`]): sign-in status, the
//! device sign-in of the Grok-account model service, sign-out, and renaming
//! or deleting a session of this computer's Grok home. No host is started,
//! no session is opened and no prompt is sent.
//!
//! The control agent runs with the Grok-account route (the user's own Grok
//! home, without API-key or endpoint variables), so status and sign-in are
//! those of the account a Grok-account host uses. Each sign-in attempt owns
//! its agent until it ends or is cancelled; quitting closes admission and
//! stops every attempt's process group.

use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, LazyLock, Mutex, MutexGuard,
    },
    time::Duration,
};

use anyhow::{anyhow, bail, ensure, Context, Result};
use pocox_host_svc::{
    acp::{
        grok,
        grok_control::{GrokAccount, GrokControl, CALL_TIMEOUT},
    },
    native_history::SessionClaim,
};
use serde_json::json;
use tokio::task::JoinHandle;

use super::{native_sessions, runtime, serve_acp};

/// Most sign-in attempts at once (each is a `grok` process).
const MAX_ATTEMPTS: usize = 2;
/// How long Grok's device sign-in may wait for the browser.
const SIGN_IN_TIMEOUT: Duration = Duration::from_secs(15 * 60);
/// How often a running sign-in is asked for its URL.
const URL_POLL: Duration = Duration::from_millis(250);
/// How long quitting waits for the attempts' agents to stop.
const QUIT_WAIT: Duration = Duration::from_secs(5);

/// Where one sign-in attempt is.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SignIn {
    /// `starting`, `waiting` (open `url`), `signed_in`, `failed`,
    /// `cancelled`.
    pub phase: String,
    /// The verification URL to open.
    pub url: Option<String>,
    /// The code the URL confirms, for display.
    pub code: Option<String>,
    /// The signed-in account, once done.
    pub email: Option<String>,
    /// Why it failed.
    pub error: Option<String>,
}

impl SignIn {
    fn ended(&self) -> bool {
        matches!(self.phase.as_str(), "signed_in" | "failed" | "cancelled")
    }
}

struct Attempt {
    state: Arc<Mutex<SignIn>>,
    control: Arc<Mutex<Option<Arc<GrokControl>>>>,
    task: Option<JoinHandle<()>>,
}

#[derive(Default)]
struct Table {
    closing: bool,
    attempts: HashMap<u64, Attempt>,
}

static TABLE: LazyLock<Mutex<Table>> = LazyLock::new(|| Mutex::new(Table::default()));
static NEXT: AtomicU64 = AtomicU64::new(1);

fn table() -> MutexGuard<'static, Table> {
    TABLE.lock().unwrap_or_else(|p| p.into_inner())
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|p| p.into_inner())
}

/// The `grok` executable: `program` when given, else the preset's.
fn program(program: Option<&str>) -> Result<PathBuf> {
    let program = program.map(str::trim).filter(|p| !p.is_empty());
    serve_acp::locate(program.unwrap_or(grok::PROGRAM), Some(grok::PROFILE_ID))
        .ok_or_else(|| anyhow!("Grok is not installed; install it or choose its full path"))
}

/// Start a control agent on the Grok-account route.
async fn account_control(program: &std::path::Path) -> Result<Arc<GrokControl>> {
    let route = grok::account_launch();
    GrokControl::start(
        program,
        pocox_codex::external_tool_path().as_ref(),
        &route.env,
        &route.env_remove,
    )
    .await
    .map_err(|e| anyhow!("{e}"))
}

/// The account a Grok-account host would use.
pub fn status(program_path: Option<&str>) -> Result<GrokAccount> {
    let program = program(program_path)?;
    runtime::runtime().block_on(async {
        let control = account_control(&program).await?;
        let account = control.account().await;
        control.stop().await;
        account.map_err(|e| anyhow!("{e}"))
    })
}

/// Sign out of Grok (its cached sign-in is removed by Grok itself).
pub fn sign_out(program_path: Option<&str>) -> Result<GrokAccount> {
    let program = program(program_path)?;
    runtime::runtime().block_on(async {
        let control = account_control(&program).await?;
        let result = async {
            control
                .call("_x.ai/auth/logout", json!({}), Some(CALL_TIMEOUT))
                .await?;
            control.account().await
        }
        .await;
        control.stop().await;
        result.map_err(|e| anyhow!("{e}"))
    })
}

/// Begin a device sign-in; poll it with [`sign_in_state`].
pub fn sign_in_start(program_path: Option<&str>) -> Result<u64> {
    let program = program(program_path)?;
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    let state = Arc::new(Mutex::new(SignIn {
        phase: "starting".into(),
        ..SignIn::default()
    }));
    let control = Arc::new(Mutex::new(None));
    {
        let mut table = table();
        ensure!(!table.closing, "the app is quitting");
        table
            .attempts
            .retain(|_, attempt| !lock(&attempt.state).ended());
        ensure!(
            table.attempts.len() < MAX_ATTEMPTS,
            "another Grok sign-in is still running; cancel it first"
        );
        let task = runtime::runtime().spawn(run(program, state.clone(), control.clone()));
        table.attempts.insert(id, Attempt {
            state,
            control,
            task: Some(task),
        });
    }
    Ok(id)
}

async fn run(
    program: PathBuf,
    state: Arc<Mutex<SignIn>>,
    slot: Arc<Mutex<Option<Arc<GrokControl>>>>,
) {
    let fail = |error: String| {
        let mut state = lock(&state);
        if !state.ended() {
            state.phase = "failed".into();
            state.error = Some(error);
        }
    };
    let control = match account_control(&program).await {
        Ok(control) => control,
        Err(error) => return fail(format!("{error:#}")),
    };
    *lock(&slot) = Some(control.clone());
    if lock(&state).ended() {
        // Cancelled while starting.
        control.stop().await;
        return;
    }
    let Some(method) = control.sign_in_method().map(str::to_owned) else {
        control.stop().await;
        return fail("Grok offers no interactive sign-in here".into());
    };
    let authenticate = {
        let control = control.clone();
        tokio::spawn(async move {
            control
                .call("authenticate", json!({"methodId": method}), Some(SIGN_IN_TIMEOUT))
                .await
        })
    };
    tokio::pin!(authenticate);
    loop {
        tokio::select! {
            result = &mut authenticate => {
                match result {
                    Ok(Ok(_)) => match control.account().await {
                        Ok(account) if account.signed_in => {
                            let mut state = lock(&state);
                            state.phase = "signed_in".into();
                            state.email = account.email;
                            state.url = None;
                        },
                        Ok(_) => fail("Grok finished the sign-in but reports no account".into()),
                        Err(error) => fail(error.to_string()),
                    },
                    Ok(Err(error)) => fail(error.to_string()),
                    Err(_) => fail("the sign-in task ended unexpectedly".into()),
                }
                break;
            }
            _ = tokio::time::sleep(URL_POLL) => {
                if lock(&state).url.is_some() {
                    continue;
                }
                if let Ok(Some((url, _mode))) = control.take_sign_in_url().await {
                    let mut state = lock(&state);
                    state.code = user_code(&url);
                    state.url = Some(url);
                    if state.phase == "starting" {
                        state.phase = "waiting".into();
                    }
                }
            }
        }
    }
    control.stop().await;
}

/// The device code a verification URL carries (`?user_code=`).
fn user_code(url: &str) -> Option<String> {
    reqwest::Url::parse(url)
        .ok()?
        .query_pairs()
        .find(|(key, _)| key == "user_code")
        .map(|(_, value)| value.into_owned())
        .filter(|code| code.len() <= 64)
}

/// Where sign-in `id` is.
pub fn sign_in_state(id: u64) -> Result<SignIn> {
    let table = table();
    let attempt = table
        .attempts
        .get(&id)
        .context("this sign-in is no longer running")?;
    let state = lock(&attempt.state).clone();
    Ok(state)
}

/// Cancel sign-in `id` (Grok's own cancel, then its agent is stopped).
pub fn sign_in_cancel(id: u64) -> Result<()> {
    let (state, control, task) = {
        let mut table = table();
        let Some(mut attempt) = table.attempts.remove(&id) else { return Ok(()) };
        (attempt.state.clone(), attempt.control.clone(), attempt.task.take())
    };
    cancel(&state, &control, task);
    Ok(())
}

fn cancel(
    state: &Arc<Mutex<SignIn>>,
    control: &Arc<Mutex<Option<Arc<GrokControl>>>>,
    task: Option<JoinHandle<()>>,
) {
    {
        let mut state = lock(state);
        if !state.ended() {
            state.phase = "cancelled".into();
        }
    }
    let control = lock(control).clone();
    runtime::runtime().block_on(async {
        if let Some(control) = control {
            let _ = control
                .call("_x.ai/auth/cancel", json!({}), Some(Duration::from_secs(2)))
                .await;
            control.stop().await;
        }
        if let Some(task) = task {
            let _ = tokio::time::timeout(QUIT_WAIT, task).await;
        }
    });
}

/// Quit: no sign-in starts any more and every running one is stopped.
pub fn close_all() {
    let attempts: Vec<Attempt> = {
        let mut table = table();
        table.closing = true;
        table.attempts.drain().map(|(_, attempt)| attempt).collect()
    };
    for mut attempt in attempts {
        let task = attempt.task.take();
        cancel(&attempt.state, &attempt.control, task);
    }
}

/// Rename (`Some(title)`) or delete (`None`) the session `session` of this
/// computer's Grok home, through Grok itself. Refused while a Grok terminal
/// client has it open or a POCOX host holds it; editors running `grok agent
/// stdio` register nowhere and must be closed by the user.
pub fn manage_session(session: &str, title: Option<&str>, source_id: Option<&str>) -> Result<()> {
    ensure!(
        uuid::Uuid::parse_str(session).is_ok_and(|u| u.hyphenated().to_string() == session),
        "invalid Grok session id"
    );
    let title = match title.map(str::trim) {
        Some("") => bail!("enter a title"),
        Some(title) if title.chars().count() > 512 || title.chars().any(char::is_control) => {
            bail!("the title is too long or contains control characters")
        },
        other => other.map(str::to_owned),
    };
    let source = native_sessions::source("grok", source_id, false)?;
    let pocox_host_svc::native_history::NativeHistory::Grok(reader) = &source.reader else {
        bail!("this history source is not Grok's");
    };
    let home = reader.home().to_path_buf();
    let program = program(None)?;
    runtime::runtime().block_on(async {
        reader.ensure_unheld(session).await?;
        // Held for the whole operation: no POCOX host admits it meanwhile.
        let _claim = SessionClaim::acquire(&home, session).map_err(|error| match error {
            pocox_host_svc::native_history::ClaimError::Busy => {
                anyhow!("a POCOX host has this session open; hand it back there first")
            },
            other => anyhow!("{other}"),
        })?;
        // This computer's own Grok, in the same home the list shows.
        let env = vec![(grok::HOME_ENV.into(), home.clone().into_os_string())];
        let control =
            GrokControl::start(&program, pocox_codex::external_tool_path().as_ref(), &env, &[])
                .await
                .map_err(|e| anyhow!("{e}"))?;
        let result = match &title {
            Some(title) => {
                control
                    .call(
                        "_x.ai/session/rename",
                        json!({"sessionId": session, "title": title}),
                        Some(CALL_TIMEOUT),
                    )
                    .await
            },
            None => {
                control
                    .call("_x.ai/session/delete", json!({"sessionId": session}), Some(CALL_TIMEOUT))
                    .await
            },
        };
        control.stop().await;
        let answer = result.map_err(|e| anyhow!("{e}"))?;
        ensure!(answer["success"] == true, "Grok did not change the session");
        Ok(())
    })
}


#[cfg(test)]
#[path = "grok_account_tests.rs"]
mod tests;
