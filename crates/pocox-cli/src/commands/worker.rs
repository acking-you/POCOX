//! Hidden foreground worker entrypoints spawned by high-level commands.

use std::time::Duration;

use anyhow::{bail, Result};
use pocox_core::config::{Config, Mode};
use pocox_core::paths;
use pocox_core::state::{PbRole, PbSessionInfo};
use pocox_pb::{
    register_background as pb_register, subscribe_background as pb_subscribe, RegisterOptions,
    RelaySession, SubscribeOptions, TunnelStatus,
};

use crate::cli::WorkerCmd;
use crate::commands::worker_health::Reporter;
use crate::commands::{account, api_proxy};

/// How many times a worker asks for a new key before giving up: about three
/// minutes.
const REPLACEMENT_TRIES: usize = 8;

/// Run an internal worker command.
pub async fn run(cmd: WorkerCmd) -> Result<()> {
    match cmd {
        WorkerCmd::PbRegister(args) => {
            // The parent always passes `--relay` and exports the credential, so
            // config is only consulted for parity with other commands; load it
            // best-effort so a broken config.toml can't fail a worker that never
            // needs it.
            let config = Config::load().unwrap_or_default();
            let session =
                crate::commands::relay::resolve_session(args.relay.relay.as_deref(), &config)?;
            let reporter =
                reporter(PbRole::Register, &args.key, &args.local_addr, &session, args.codec)?;
            let options = RegisterOptions {
                key: args.key.clone(),
                local_addr: args.local_addr,
                codec: args.codec,
            };
            until_credential_gone(session, &args.key, &config, |session| {
                let (options, reporter, config) = (options.clone(), &reporter, &config);
                async move {
                    let registration = pb_register(&session, options).await?;
                    let _refresh = keep_account_credential_alive(&session, config);
                    let outcome = until_identity_lost(
                        config,
                        &session,
                        monitor(reporter, registration.subscribe(), || registration.diagnostics()),
                    )
                    .await;
                    registration.stop().await?;
                    outcome
                }
            })
            .await?;
        },
        WorkerCmd::PbSubscribe(args) => {
            let config = Config::load().unwrap_or_default();
            let session =
                crate::commands::relay::resolve_session(args.relay.relay.as_deref(), &config)?;
            let reporter =
                reporter(PbRole::Subscribe, &args.key, &args.local_addr, &session, false)?;
            let options = SubscribeOptions {
                key: args.key.clone(),
                local_addr: args.local_addr,
            };
            until_credential_gone(session, &args.key, &config, |session| {
                let (options, reporter, config) = (options.clone(), &reporter, &config);
                async move {
                    let connection = pb_subscribe(&session, options).await?;
                    let _refresh = keep_account_credential_alive(&session, config);
                    let outcome = until_identity_lost(
                        config,
                        &session,
                        monitor(reporter, connection.subscribe(), || connection.diagnostics()),
                    )
                    .await;
                    connection.stop().await?;
                    outcome
                }
            })
            .await?;
        },
        WorkerCmd::ApiProxy(args) => {
            super::host_identity::initialize_for_metadata();
            api_proxy::run(args.listen, args.proxy).await?;
        },
    }
    Ok(())
}

/// Whether this worker runs on an account's own credential, rather than on a
/// relay the caller named with its key. Only then does anything about the
/// account concern it.
fn on_account_credential(session: &RelaySession, config: &Config) -> bool {
    session.credential.starts_with("pbmt1_") && config.account_mode() == Mode::Account
}

/// Run `work` while the account's credential can be had. A computer that slept
/// past its key's end wakes to a relay that refuses it for good, and nothing
/// else would start this worker again, so it fetches the replacement and
/// carries on. A refusal with no replacement for this same user is how a
/// removed or moved device stops.
async fn until_credential_gone<F, Fut>(
    mut session: RelaySession,
    key: &str,
    config: &Config,
    mut work: F,
) -> Result<()>
where
    F: FnMut(RelaySession) -> Fut,
    Fut: std::future::Future<Output = Result<()>>,
{
    loop {
        let error = match work(session.clone()).await {
            Ok(()) => return Ok(()),
            Err(error) => error,
        };
        if !on_account_credential(&session, config) || !credential_refused(&error) {
            return Err(error);
        }
        match replacement_credential(&session, key, config).await {
            Some(next) => {
                tracing::info!("the relay ended this worker's key; continuing on its replacement");
                session = next;
            },
            None => return Err(error),
        }
    }
}

/// Whether the relay said this credential is over, rather than anything
/// passing.
fn credential_refused(error: &anyhow::Error) -> bool {
    let said = format!("{error:#}");
    said.contains("temporary_key_expired") || said.contains("temporary_key_revoked")
}

/// A new credential for `key`, if the backend gives this same user one. Retried
/// for a while: a computer waking from sleep often has no network yet. The
/// backend refusing is the answer, and so is its naming another user.
async fn replacement_credential(
    session: &RelaySession,
    key: &str,
    config: &Config,
) -> Option<RelaySession> {
    let backend = account::backend_base(None, config);
    let mut delay = Duration::from_secs(2);
    for _ in 0..REPLACEMENT_TRIES {
        let mut latest = Config::load().unwrap_or_else(|_| config.clone());
        match account::fetch_relay_credential(&mut latest, &backend).await {
            Ok(relay) => {
                let same_user = key.starts_with(&format!("pcxu:{}:", relay.namespace));
                let new = relay.credential != session.credential;
                return (same_user && new).then(|| {
                    RelaySession::new(relay.relay_addr, relay.credential)
                        .with_preferences(&latest.pb_mapper)
                });
            },
            Err(error) if pocox_bridge::pairing::code_of(&error).is_some() => {
                tracing::warn!("this worker's key was not replaced: {error:#}");
                return None;
            },
            Err(error) => {
                tracing::warn!(
                    retry_secs = delay.as_secs(),
                    "fetching a replacement key: {error:#}"
                );
                tokio::time::sleep(delay).await;
                delay = (delay * 2).min(Duration::from_secs(30));
            },
        }
    }
    None
}

/// Run `work` while this installation's account stands. A worker outlives the
/// command that spawned it, and a removed device must not keep trying to
/// republish on a key that is gone, nor a GitHub one to renew a key this
/// installation moved away from. One given a relay of its own never ends early.
async fn until_identity_lost(
    config: &Config,
    session: &RelaySession,
    work: impl std::future::Future<Output = Result<()>>,
) -> Result<()> {
    if !on_account_credential(session, config) {
        return work.await;
    }
    let backend = account::backend_base(None, config);
    tokio::select! {
        outcome = work => outcome,
        reason = account::identity_lost(config, &backend) => {
            tracing::warn!("worker stopping: {reason}");
            Ok(())
        },
    }
}

/// Keep this worker's relay credential from lapsing, for as long as it runs.
///
/// A detached worker outlives the command that spawned it — that is the point —
/// so in account mode it holds a credential with a finite life and nothing else
/// to renew it. Expiry does not merely refuse the next request: the relay
/// cancels the credential's lease and tears down every tunnel it opened, so a
/// service hosted from the CLI would go unreachable after its TTL while the
/// worker process sat there looking healthy (and `managed_pb::ensure` would
/// keep reusing it, since the pid is alive).
///
/// Asking the backend for the credential again is what renews it: the backend
/// renews rather than re-mints, which extends the existing lease and returns
/// the same credential string — so this worker's live tunnel keeps working and
/// there is no new value to install anywhere.
///
/// Returns a guard whose drop stops refreshing. `None` in self-host mode, where
/// the operator's own key does not expire.
fn keep_account_credential_alive(session: &RelaySession, config: &Config) -> Option<OwnedTask> {
    if !on_account_credential(session, config) {
        return None;
    }
    let backend = account::backend_base(None, config);
    let initial_config = config.clone();
    Some(OwnedTask(tokio::spawn(async move {
        let mut delay = Duration::from_secs(2);
        let expires_at = loop {
            let mut config = Config::load().unwrap_or_else(|_| initial_config.clone());
            match account::fetch_relay_credential(&mut config, &backend).await {
                Ok(relay) => break relay.expires_at,
                Err(error) => {
                    tracing::warn!(%error, retry_secs = delay.as_secs(), "credential expiry lookup failed; retrying");
                    tokio::time::sleep(delay).await;
                    delay = (delay * 2).min(Duration::from_secs(30));
                },
            }
        };
        let mut refresh = OwnedTask(pocox_pb::keep_credential_alive(expires_at, move || {
            let backend = backend.clone();
            async move {
                let mut config = Config::load()?;
                Ok(account::fetch_relay_credential(&mut config, &backend)
                    .await?
                    .expires_at)
            }
        }));
        let _ = (&mut refresh.0).await;
    })))
}

struct OwnedTask(tokio::task::JoinHandle<()>);
impl Drop for OwnedTask {
    fn drop(&mut self) {
        self.0.abort();
    }
}

fn reporter(
    role: PbRole,
    key: &str,
    local_addr: &str,
    session: &RelaySession,
    codec: bool,
) -> Result<Reporter> {
    Reporter::new(&PbSessionInfo {
        role,
        key: key.to_string(),
        local_addr: local_addr.to_string(),
        relay_addr: session.relay_addr.clone(),
        pid: std::process::id(),
        log_file: paths::pb_log_file(role, key)?,
        codec,
        started_at: chrono::Utc::now().to_rfc3339(),
    })
}

async fn monitor(
    reporter: &Reporter,
    mut status: tokio::sync::watch::Receiver<TunnelStatus>,
    diagnostics: impl Fn() -> pocox_pb::TunnelDiagnostics,
) -> Result<()> {
    let shutdown = shutdown_signal();
    tokio::pin!(shutdown);
    let mut interval = tokio::time::interval(Duration::from_secs(5));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut snapshot_failed = false;
    loop {
        let current = status.borrow_and_update().clone();
        if let Err(error) = reporter.write(current.clone(), diagnostics()) {
            if !snapshot_failed {
                tracing::warn!(%error, "worker runtime snapshot unavailable");
            }
            snapshot_failed = true;
        } else {
            snapshot_failed = false;
        }
        match current {
            TunnelStatus::Failed(reason) => bail!("network worker failed: {reason}"),
            TunnelStatus::Stopped => return Ok(()),
            _ => {},
        }
        tokio::select! {
            result = &mut shutdown => return result,
            _ = interval.tick() => {},
            result = status.changed() => { if result.is_err() { bail!("network worker stopped reporting status"); } },
        }
    }
}

/// Ctrl-C, or the platform's other polite stops: SIGTERM (how systemd stops a
/// unit), or on Windows Ctrl-Break, closing the console window and system
/// shutdown, so owned processes are stopped instead of orphaned. Not log-off:
/// a process outside the user's session receives it whenever anyone signs out.
pub(super) async fn shutdown_signal() -> Result<()> {
    #[cfg(unix)]
    {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        tokio::select! { result = tokio::signal::ctrl_c() => result?, _ = term.recv() => {} }
    }
    #[cfg(windows)]
    {
        use tokio::signal::windows;
        let mut brk = windows::ctrl_break()?;
        let mut close = windows::ctrl_close()?;
        let mut shutdown = windows::ctrl_shutdown()?;
        tokio::select! {
            result = tokio::signal::ctrl_c() => result?,
            _ = brk.recv() => {},
            _ = close.recv() => {},
            _ = shutdown.recv() => {},
        }
    }
    #[cfg(not(any(unix, windows)))]
    tokio::signal::ctrl_c().await?;
    Ok(())
}
