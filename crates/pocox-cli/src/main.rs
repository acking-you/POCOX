//! `pocox` command-line entrypoint.
//!
//! POCOX orchestrates a local `codex app-server` process and a
//! `pb-mapper` register/subscribe session so users can drive Codex
//! from any device. This binary wires the three library crates
//! (`pocox-core`, `pocox-codex`, `pocox-pb`)
//! into the user-facing subcommands documented in `docs/cli.md`.

#![forbid(unsafe_code)]

use anyhow::Result;
use clap::Parser;
use tracing_subscriber::EnvFilter;

mod cli;
mod commands;

/// Default tracing filter when `RUST_LOG` is unset.
const DEFAULT_LOG_FILTER: &str = "warn,pocox=info,pocox_cli=info";

/// Stderr for logs, where a pairing secret, code or link never appears: the
/// code formats none of them, and this covers a dependency's error quoting its
/// input.
struct ScrubbedStderr;

impl std::io::Write for ScrubbedStderr {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let text = String::from_utf8_lossy(bytes);
        std::io::stderr().write_all(pocox_core::redact::scrub_pairing(&text).as_bytes())?;
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        std::io::stderr().flush()
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let filter =
        EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(DEFAULT_LOG_FILTER));
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(|| ScrubbedStderr)
        .init();

    let cli = cli::Cli::parse();
    commands::dispatch(cli).await
}
