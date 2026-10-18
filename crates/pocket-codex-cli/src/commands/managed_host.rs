//! Foreground computer management using the desktop's native hosting engine.

use std::{sync::mpsc, time::Duration};

use anyhow::{bail, Context, Result};
use pocket_codex_bridge::headless::{Manager, Options};
use pocket_codex_core::{
    config::{Config, Mode},
    paths,
};

use super::{api_proxy, relay, ui};
use crate::cli::ServeArgs;

pub(super) fn state_dir() -> Result<std::path::PathBuf> {
    Ok(paths::state_dir()?.join("managed-host"))
}

pub(super) async fn run(args: ServeArgs) -> Result<()> {
    if args.host != "127.0.0.1" {
        bail!(
            "--allow-remote-management requires --host 127.0.0.1; devices connect through the \
             relay"
        );
    }
    let config = Config::load()?;
    // As for ordinary `serve`: an explicit relay, or any self-host setup with
    // its saved or environment credential, is resolved here. A signed-in
    // account stays with the engine, which renews its own credential.
    let explicit = args
        .relay
        .relay
        .as_deref()
        .is_some_and(|relay| !relay.trim().is_empty());
    let relay = (explicit || !matches!(config.account_mode(), Mode::Account))
        .then(|| relay::resolve_session(args.relay.relay.as_deref(), &config))
        .transpose()?;
    let options = Options {
        config_dir: paths::config_dir()?,
        state_dir: state_dir()?,
        device: super::host_identity::device(args.device)?,
        name: args.name,
        binary: args
            .codex_binary
            .map(|path| {
                path.into_os_string()
                    .into_string()
                    .map_err(|_| anyhow::anyhow!("the Codex binary path must be valid UTF-8"))
            })
            .transpose()?,
        port: args.port,
        proxy: api_proxy::resolve_app_server_proxy(args.proxy.as_deref())?,
        relay,
    };
    let (stop_tx, stop_rx) = mpsc::channel();
    let mut task = tokio::task::spawn_blocking(move || -> Result<()> {
        let mut manager = Manager::start(options)?;
        ui::headline(ui::Tone::Ok, "managed computer hosting — Ctrl-C to stop");
        let mut previous_key = None;
        loop {
            match manager.refresh_status() {
                Ok(status) if status.management.service_key != previous_key => {
                    if let Some(key) = &status.management.service_key {
                        ui::field("management", key);
                    }
                    previous_key = status.management.service_key;
                },
                Ok(_) => {},
                Err(error) => tracing::warn!("reading managed-host status: {error:#}"),
            }
            match stop_rx.recv_timeout(Duration::from_secs(2)) {
                Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => {},
            }
        }
        manager.stop()
    });
    let signal = tokio::select! {
        result = &mut task => return result.context("managed-host supervisor failed")?,
        result = super::worker::shutdown_signal() => result,
    };
    // Owned services stop even when waiting for the signal itself failed.
    let _ = stop_tx.send(());
    task.await.context("stopping managed-host supervisor")??;
    signal
}
