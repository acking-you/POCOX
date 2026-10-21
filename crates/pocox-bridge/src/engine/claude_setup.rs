//! The Claude preset's local environment, as this app sees it, and the one
//! preparation of its pinned ACP adapter.
//!
//! Detection is `pocox_host_svc::acp::claude`'s, run against the
//! child `PATH` Codex children get, the user's home, and this app's runtime
//! cache. Preparation (`acp::claude_setup`) is started only by an explicit
//! request from the hosting editor, never by picking the preset or by
//! restoring a host; overlapping requests join the one in progress. Each
//! run has its own number: only the caller that started a run is told so
//! ([`Snapshot::started`]), and [`prepare_cancel_run`] stops that run only,
//! never one another caller started later.

use std::{
    ffi::OsString,
    path::PathBuf,
    sync::{Mutex, MutexGuard},
    time::Instant,
};

use anyhow::{Context, Result};
use pocox_host_svc::acp::{
    claude::{self, Environment, Lookup, Status, CLI_ENV},
    claude_setup::{self, Prepare, SetupError, Stage, PREPARE_TIMEOUT},
};
use tokio::sync::watch;

use super::runtime;

fn cache_dir() -> Result<PathBuf> {
    Ok(pocox_core::paths::state_dir()
        .context("resolving the state directory")?
        .join("acp-runtime"))
}

fn child_path() -> Option<OsString> {
    pocox_codex::external_tool_path().or_else(|| std::env::var_os("PATH"))
}

async fn detect() -> Result<Environment> {
    let cache = cache_dir()?;
    let search = child_path();
    let home = std::env::var_os("HOME").map(PathBuf::from);
    Ok(claude::detect(&Lookup {
        search_path: search.as_deref(),
        home: home.as_deref(),
        cache: &cache,
        inherited_cli: std::env::var_os(CLI_ENV).is_some_and(|value| !value.is_empty()),
        system: true,
    })
    .await)
}

/// What this computer has for the Claude preset now. Blocks on bounded
/// `node --version` probes; call it from a worker thread, never from the
/// runtime or the UI thread.
pub fn environment() -> Result<Environment> {
    runtime::runtime().block_on(detect())
}

/// [`environment`]'s display summary.
pub fn status() -> Result<Status> {
    environment().map(|env| env.status())
}

/// Where the preparation is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    /// `idle` / `running` / `done` / `failed` / `cancelled`.
    pub state: &'static str,
    /// `installing` / `downloading` / `verifying` while running.
    pub stage: Option<&'static str>,
    /// Milliseconds since it started.
    pub elapsed_ms: u64,
    /// Actual received package bytes, when transfer telemetry is available.
    pub downloaded_bytes: Option<u64>,
    /// Recent measured transfer rate, in bytes per second.
    pub download_bytes_per_second: Option<u64>,
    /// Why it failed (safe to show).
    pub error: Option<String>,
    /// The run this state belongs to (0 before any).
    pub run: u64,
    /// This very call started [`Self::run`] (only [`prepare_start`] says
    /// so; a call that joined a run in progress did not).
    pub started: bool,
}

enum Phase {
    Idle,
    Running { stage: Option<Stage>, cancel: watch::Sender<bool> },
    Done,
    Failed(String),
    Cancelled,
}

struct Job {
    phase: Phase,
    started: Option<Instant>,
    /// Bumped by every start, so a finished run never overwrites a newer one.
    run: u64,
    downloaded_bytes: Option<u64>,
}

fn job() -> MutexGuard<'static, Job> {
    static JOB: Mutex<Job> = Mutex::new(Job {
        phase: Phase::Idle,
        started: None,
        run: 0,
        downloaded_bytes: None,
    });
    JOB.lock().unwrap_or_else(|poison| poison.into_inner())
}

impl Job {
    fn snapshot(&self) -> Snapshot {
        let (state, stage, error) = match &self.phase {
            Phase::Idle => ("idle", None, None),
            Phase::Running {
                stage, ..
            } => (
                "running",
                stage.map(|stage| match stage {
                    Stage::Installing => "installing",
                    Stage::Downloading {
                        active: true, ..
                    } => "downloading",
                    Stage::Downloading {
                        active: false, ..
                    } => "installing",
                    Stage::Verifying => "verifying",
                }),
                None,
            ),
            Phase::Done => ("done", None, None),
            Phase::Failed(error) => ("failed", None, Some(error.clone())),
            Phase::Cancelled => ("cancelled", None, None),
        };
        let transfer = match &self.phase {
            Phase::Running {
                stage:
                    Some(Stage::Downloading {
                        bytes,
                        bytes_per_second,
                        active: true,
                    }),
                ..
            } => Some((*bytes, *bytes_per_second)),
            _ => None,
        };
        Snapshot {
            downloaded_bytes: self.downloaded_bytes,
            download_bytes_per_second: transfer.map(|x| x.1),
            state,
            stage,
            elapsed_ms: self
                .started
                .map_or(0, |at| u64::try_from(at.elapsed().as_millis()).unwrap_or(u64::MAX)),
            error,
            run: self.run,
            started: false,
        }
    }
}

/// Start preparing the adapter, or join the preparation in progress. It
/// returns at once: the job is reserved under a short lock and everything
/// slow (detection, npm, verification) runs in its own task, so
/// [`prepare_state`] and [`prepare_cancel`] never wait for it. An adapter
/// that is already there needs none (`done`); one that cannot be prepared
/// here ends `failed` with the reason.
pub fn prepare_start() -> Snapshot {
    let (run, cancelled, snapshot) = {
        let mut current = job();
        if matches!(current.phase, Phase::Running { .. }) {
            return current.snapshot();
        }
        let (cancel, cancelled) = watch::channel(false);
        current.run += 1;
        current.phase = Phase::Running {
            stage: None,
            cancel,
        };
        current.started = Some(Instant::now());
        current.downloaded_bytes = None;
        let snapshot = Snapshot {
            started: true,
            ..current.snapshot()
        };
        (current.run, cancelled, snapshot)
    };
    runtime::runtime().spawn(async move {
        let ended = run_job(run, cancelled).await;
        let mut current = job();
        // A newer run owns the state; this one only reports its own end.
        if current.run == run {
            current.phase = ended;
        }
    });
    snapshot
}

/// Resolves once `cancelled` is (or was already) set, or its sender is gone.
async fn until_cancelled(cancelled: &mut watch::Receiver<bool>) {
    while !*cancelled.borrow_and_update() {
        if cancelled.changed().await.is_err() {
            return;
        }
    }
}

/// Why no preparation can run here.
fn unpreparable(env: &Environment) -> String {
    let problem = match (&env.node, env.too_old) {
        (Some(_), _) => {
            format!("npm was not found beside any Node.js {} or newer", claude::MIN_NODE_MAJOR)
        },
        (None, Some((major, minor, patch))) => format!(
            "the newest Node.js found is {major}.{minor}.{patch}, older than {}",
            claude::MIN_NODE_MAJOR
        ),
        (None, None) => "no Node.js was found".to_string(),
    };
    format!(
        "Claude's ACP adapter cannot be prepared: {}; install Node.js {} or newer with npm, or \
         install {} yourself",
        problem,
        claude::MIN_NODE_MAJOR,
        claude::ADAPTER_PACKAGE
    )
}

/// One run, ending in its final phase: detect, then prepare with the
/// Node.js/npm pair found.
async fn run_job(run: u64, mut cancelled: watch::Receiver<bool>) -> Phase {
    // A cancel during detection ends it at once; a probe dropped mid-way
    // kills its own process group (`AgentProcess`'s drop).
    let detected = tokio::select! {
        detected = detect() => detected,
        () = until_cancelled(&mut cancelled) => return Phase::Cancelled,
    };
    let env = match detected {
        Ok(env) => env,
        Err(error) => return Phase::Failed(format!("{error:#}")),
    };
    if env.adapter.is_some() {
        return Phase::Done;
    }
    if *cancelled.borrow() {
        return Phase::Cancelled;
    }
    let Some(npm) = env.npm.as_ref() else {
        return Phase::Failed(unpreparable(&env));
    };
    let cache = match cache_dir() {
        Ok(cache) => cache,
        Err(error) => return Phase::Failed(format!("{error:#}")),
    };
    let prepare = Prepare {
        node: npm.node.clone(),
        npm_cli: npm.cli.clone(),
        cache,
        path: child_path(),
        timeout: PREPARE_TIMEOUT,
    };
    let progress = |stage| {
        let mut current = job();
        if current.run == run {
            if let Phase::Running {
                stage: at, ..
            } = &mut current.phase
            {
                *at = Some(stage);
                if let Stage::Downloading {
                    bytes, ..
                } = stage
                {
                    current.downloaded_bytes = Some(bytes);
                }
            }
        }
    };
    match claude_setup::prepare(&prepare, progress, cancelled).await {
        Ok(_) => Phase::Done,
        Err(SetupError::Cancelled) => Phase::Cancelled,
        Err(error) => {
            tracing::warn!(%error, "preparing the Claude ACP adapter failed");
            Phase::Failed(error.to_string())
        },
    }
}

/// The preparation's current state.
pub fn prepare_state() -> Snapshot {
    job().snapshot()
}

/// Ask a running preparation to stop; it reports `cancelled` once its npm
/// process is stopped and its staging directory removed.
pub fn prepare_cancel() -> Snapshot {
    cancel_if(|_| true)
}

/// [`prepare_cancel`] for run `run` only: a later run (another caller's)
/// is left running.
pub fn prepare_cancel_run(run: u64) -> Snapshot {
    cancel_if(|current| current == run)
}

fn cancel_if(owned: impl FnOnce(u64) -> bool) -> Snapshot {
    let current = job();
    if let Phase::Running {
        cancel, ..
    } = &current.phase
    {
        if owned(current.run) {
            cancel.send_replace(true);
        }
    }
    current.snapshot()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The job is process-wide: these tests take turns.
    fn serial() -> MutexGuard<'static, ()> {
        static SERIAL: Mutex<()> = Mutex::new(());
        SERIAL.lock().unwrap_or_else(|poison| poison.into_inner())
    }

    /// A run in progress, without a task behind it.
    fn running(run: u64) -> watch::Receiver<bool> {
        let (cancel, cancelled) = watch::channel(false);
        let mut current = job();
        current.run = run;
        current.phase = Phase::Running {
            stage: None,
            cancel,
        };
        cancelled
    }

    #[test]
    fn transfer_metrics_survive_verification_and_finish_without_stale_speed() {
        let (cancel, _) = watch::channel(false);
        let mut current = Job {
            phase: Phase::Running {
                stage: Some(Stage::Downloading {
                    bytes: 4096,
                    bytes_per_second: 1024,
                    active: true,
                }),
                cancel: cancel.clone(),
            },
            started: Some(Instant::now()),
            run: 1,
            downloaded_bytes: Some(4096),
        };
        assert_eq!(current.snapshot().download_bytes_per_second, Some(1024));
        for phase in [
            Phase::Running {
                stage: Some(Stage::Verifying),
                cancel,
            },
            Phase::Done,
            Phase::Cancelled,
            Phase::Failed("failed".into()),
        ] {
            current.phase = phase;
            let snapshot = current.snapshot();
            assert_eq!(snapshot.downloaded_bytes, Some(4096));
            assert_eq!(snapshot.download_bytes_per_second, None);
        }
    }

    #[test]
    fn a_cancel_names_its_run_and_never_stops_a_later_one() {
        let _serial = serial();
        let later = running(41);
        let snapshot = prepare_cancel_run(40);
        assert_eq!((snapshot.state, snapshot.run, snapshot.started), ("running", 41, false));
        assert!(!*later.borrow(), "another caller's run keeps going");
        prepare_cancel_run(41);
        assert!(*later.borrow(), "its own run is asked to stop");
        job().phase = Phase::Idle;
    }

    #[test]
    fn joining_a_run_in_progress_does_not_own_it() {
        let _serial = serial();
        let _held = running(7);
        let joined = prepare_start();
        assert_eq!((joined.state, joined.run, joined.started), ("running", 7, false));
        job().phase = Phase::Idle;
    }
}
