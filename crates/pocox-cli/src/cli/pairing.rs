//! Arguments of `pocox pair` and `pocox devices`.

use clap::{Args, Subcommand};

/// Args for `pocox pair`.
#[derive(Debug, Args)]
pub struct PairArgs {
    /// Backend base URL. Defaults to the configured backend, then
    /// `$POCOX_BACKEND`, then the built-in default.
    #[arg(long, global = true)]
    pub backend: Option<String>,

    /// Answer yes to confirmations, which is the only way to give one without a
    /// terminal.
    #[arg(long, short = 'y', global = true)]
    pub yes: bool,

    /// Show the code and return instead of waiting for a device to link.
    #[arg(long)]
    pub no_wait: bool,

    /// What to do; without one, show this device's code.
    #[command(subcommand)]
    pub command: Option<PairCmd>,
}

/// Subcommands of `pocox pair`.
#[derive(Debug, Subcommand)]
pub enum PairCmd {
    /// Join another device's group. Reads its code from a prompt or stdin.
    Join,

    /// Recover a previous device, with a code from its group read from a prompt
    /// or stdin, or by asking a linked device with `--ask`.
    Restore {
        /// Ask a linked device to allow it instead of entering a code.
        #[arg(long)]
        ask: bool,

        /// For a suspected compromise: old access ends at once and the code
        /// changes.
        #[arg(long)]
        retake: bool,

        /// The group's device this is, from the list a code shows.
        #[arg(long)]
        device: Option<String>,
    },

    /// Leave a replaced or unknown identity behind and start as a new device.
    StartOver,

    /// Replace this device's code. An error during the 24-hour wait.
    Rotate,

    /// Stop this device's code from linking anyone until `pair resume`.
    Pause,

    /// Let this device's code link again.
    Resume,

    /// Move this device out of its group.
    Leave,
}

/// Args for `pocox devices`.
#[derive(Debug, Args)]
pub struct DevicesArgs {
    /// Backend base URL. Defaults to the configured backend, then
    /// `$POCOX_BACKEND`, then the built-in default.
    #[arg(long, global = true)]
    pub backend: Option<String>,

    /// What to do; without one, list them.
    #[command(subcommand)]
    pub command: Option<DevicesCmd>,
}

/// Subcommands of `pocox devices`.
#[derive(Debug, Subcommand)]
pub enum DevicesCmd {
    /// Remove a device from this group. Its new connections stop; one already
    /// open may last until an end closes it.
    Remove {
        /// The device's id, from `pocox devices`.
        id: String,

        /// Answer yes to the confirmation.
        #[arg(long, short = 'y')]
        yes: bool,
    },

    /// Allow a recovery request. Nothing changes until that device confirms.
    Allow {
        /// The device it asks to restore.
        id: String,

        /// The exact request, from `pocox devices`.
        #[arg(long)]
        request: String,
    },

    /// Deny a recovery request.
    Deny {
        /// The device it asks to restore.
        id: String,

        /// The exact request, from `pocox devices`.
        #[arg(long)]
        request: String,
    },
}
