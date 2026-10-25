//! What this device knows about its harnesses (the last check and update)
//! and the operations on it: reading, checking, updating, and the schedule
//! that checks by itself and runs the automatic updates this device's
//! settings ask for.

use std::collections::BTreeMap;
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::Result;
use once_cell::sync::Lazy;

use super::install::{self, Installed};
use super::restart::{self, Outcome};
use super::view::{Harness, Job, Overview, SettingsChange};
use super::{latest, settings, Kind};

/// A background check runs this long after the host starts …
const FIRST_CHECK: Duration = Duration::from_secs(60);
/// … and then this often; reading a device whose last check is older starts
/// one too.
const CHECK_EVERY: Duration = Duration::from_secs(6 * 60 * 60);

/// The last check: what was installed, and the newest versions found.
pub(super) struct Found {
    pub(super) installed: Option<Installed>,
    pub(super) latest: Option<String>,
}

#[derive(Default)]
struct State {
    /// By kind; empty before the first check.
    found: BTreeMap<Kind, Found>,
    checked_at_ms: Option<u64>,
    checking: bool,
    job: Option<Job>,
    runs: u64,
    /// Moves whenever an update records what it installed.
    generation: u64,
    /// The [`Self::generation`] at which each kind's update recorded it.
    installed_at: BTreeMap<Kind, u64>,
}

struct Shared {
    state: Mutex<State>,
    /// Signalled when a check or a job ends.
    changed: Condvar,
}

static SHARED: Lazy<Shared> = Lazy::new(|| Shared {
    state: Mutex::new(State::default()),
    changed: Condvar::new(),
});

fn state() -> MutexGuard<'static, State> {
    SHARED
        .state
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
}

/// Why a harness operation was refused before it started.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    /// This device hosts nothing (a phone).
    Unsupported,
    /// Another update is running on this device.
    Running,
    /// The harness is not installed, or its installation cannot be updated
    /// here.
    Unavailable,
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Unsupported => "this device cannot host services",
            Self::Running => "another harness update is running on this device",
            Self::Unavailable => "this harness is not installed or cannot be updated here",
        })
    }
}

impl std::error::Error for Refusal {}

/// Phones host nothing, so they manage no harness of their own.
pub(super) fn supported() -> bool {
    !cfg!(any(target_os = "ios", target_os = "android"))
}

fn require_supported() -> Result<()> {
    if supported() {
        Ok(())
    } else {
        Err(Refusal::Unsupported.into())
    }
}

/// This device's harnesses as last checked, with their running services and
/// settings. Starts a background check when none ran for a while.
pub fn overview() -> Result<Overview> {
    require_supported()?;
    let settings = settings::load()?;
    let stale = state().checked_at_ms.is_none_or(|at| {
        now_ms().saturating_sub(at) > u64::try_from(CHECK_EVERY.as_millis()).unwrap_or(0)
    });
    // Reserved before this answer is read, so it says a check runs and the
    // controller keeps reading until it ends.
    if stale
        && crate::engine::host_owner::require().is_ok()
        && reserve_check()
        && !spawn("pcx-harness-check", run_check)
    {
        end_check();
    }
    let mut services = restart::targets();
    let state = state();
    // Nothing is listed before the first check: "not installed" would be a
    // guess.
    let harnesses = Kind::ALL
        .into_iter()
        .filter(|kind| kind.hostable())
        .filter_map(|kind| {
            let found = state.found.get(&kind)?;
            let services = services.remove(&kind).unwrap_or_default();
            Some(row(kind, found, settings.auto(kind), services))
        })
        .collect();
    Ok(Overview {
        harnesses,
        checked_at_ms: state.checked_at_ms,
        checking: state.checking,
        restart_services: settings.restart_services,
        job: state.job.clone(),
    })
}

fn row(kind: Kind, found: &Found, auto_update: bool, services: Vec<restart::Target>) -> Harness {
    let services = services.into_iter().map(|target| target.name).collect();
    let installed = found.installed.as_ref();
    let latest = found.latest.clone();
    let version = installed.and_then(|found| found.version.clone());
    let update_available = match (installed, &version, &latest) {
        (Some(found), Some(version), Some(latest)) => {
            install::is_newer(latest, version, found.line())
        },
        _ => false,
    };
    let method = installed.map(|found| found.method);
    let problem = match method {
        None => None,
        Some(install::Method::Not(reason)) => Some(reason),
        Some(_) if version.is_none() => Some("version_unknown"),
        Some(_) if latest.is_none() => Some("check_failed"),
        Some(_) => None,
    };
    Harness {
        kind: kind.label().into(),
        installed: installed.is_some(),
        version,
        latest,
        update_available,
        method: method.and_then(install::Method::label).map(str::to_string),
        can_update: method.and_then(install::Method::label).is_some(),
        problem: problem.map(str::to_string),
        auto_update,
        services,
    }
}

/// Look up what is installed and the newest versions now, then answer as
/// [`overview`]. Joins a check already running.
pub fn check() -> Result<Overview> {
    require_supported()?;
    check_now();
    overview()
}

/// Mark a check as running; false when one already runs.
fn reserve_check() -> bool {
    let mut state = state();
    !std::mem::replace(&mut state.checking, true)
}

fn end_check() {
    state().checking = false;
    SHARED.changed.notify_all();
}

/// Run a check, or wait for the one already running.
fn check_now() {
    if reserve_check() {
        run_check();
        return;
    }
    let mut state = state();
    while state.checking {
        state = SHARED
            .changed
            .wait(state)
            .unwrap_or_else(|poison| poison.into_inner());
    }
}

/// The check [`reserve_check`] reserved.
fn run_check() {
    // Ends the check however it ends.
    struct Checking;
    impl Drop for Checking {
        fn drop(&mut self) {
            end_check();
        }
    }
    let _checking = Checking;
    let since = state().generation;
    let targets = restart::targets();
    let installed: Vec<(Kind, Option<Installed>)> = std::thread::scope(|scope| {
        let probes: Vec<_> = Kind::ALL
            .into_iter()
            .filter(|kind| kind.hostable())
            .map(|kind| {
                let running = restart::installation(&targets, kind);
                (kind, scope.spawn(move || install::detect(kind, running.as_deref())))
            })
            .collect();
        probes
            .into_iter()
            .map(|(kind, probe)| (kind, probe.join().ok().flatten()))
            .collect()
    });
    let present: Vec<Installed> = installed
        .iter()
        .filter_map(|(_, found)| found.clone())
        .collect();
    let mut newest = latest::lookup(&present).into_iter();
    let mut checked = BTreeMap::new();
    for (kind, installed) in installed {
        let latest = installed.as_ref().and_then(|_| newest.next().flatten());
        checked.insert(kind, Found {
            installed,
            latest,
        });
    }
    let mut state = state();
    let State {
        found,
        installed_at,
        ..
    } = &mut *state;
    publish(found, checked, |kind| installed_at.get(&kind).is_some_and(|at| *at > since));
    state.checked_at_ms = Some(now_ms());
}

/// Replace `found` with a check's results, except what an update recorded
/// after the check began (`updated`): its probes may have seen the previous
/// installation, so that kind keeps the update's, with the newest version
/// the check found.
pub(super) fn publish(
    found: &mut BTreeMap<Kind, Found>,
    checked: BTreeMap<Kind, Found>,
    updated: impl Fn(Kind) -> bool,
) {
    for (kind, mut result) in checked {
        if updated(kind) {
            if let Some(previous) = found.get_mut(&kind) {
                result.installed = previous.installed.take();
            }
        }
        found.insert(kind, result);
    }
}

/// Save a change to this device's settings, then answer as [`overview`].
pub fn set(change: &SettingsChange) -> Result<Overview> {
    require_supported()?;
    settings::change(change)?;
    overview()
}

/// Start updating `kind`, then answer as [`overview`]; the update goes on
/// after the answer (read its progress with [`overview`]).
pub fn update(kind: Kind) -> Result<Overview> {
    require_supported()?;
    start(kind, false)?;
    overview()
}

fn start(kind: Kind, automatic: bool) -> Result<u64> {
    crate::engine::host_owner::require()?;
    if state()
        .job
        .as_ref()
        .is_some_and(|job| job.state == "running")
    {
        return Err(Refusal::Running.into());
    }
    // Looked up again: what runs the update is what is installed now, the
    // installation this device's services run.
    let running = restart::installation(&restart::targets(), kind);
    let installed = install::detect(kind, running.as_deref()).ok_or(Refusal::Unavailable)?;
    let invocation = installed.update().ok_or(Refusal::Unavailable)?;
    let run = {
        let mut state = state();
        if state.job.as_ref().is_some_and(|job| job.state == "running") {
            return Err(Refusal::Running.into());
        }
        state.runs += 1;
        let run = state.runs;
        state.job = Some(Job {
            run,
            kind: kind.label().into(),
            state: "running".into(),
            stage: Some("updating".into()),
            automatic,
            from_version: installed.version.clone(),
            to_version: None,
            failure: None,
            restarted: Vec::new(),
            not_restarted: Vec::new(),
            started_at_ms: now_ms(),
            finished_at_ms: None,
        });
        run
    };
    if !spawn("pcx-harness-update", move || run_job(run, installed, invocation)) {
        // Ends it as failed: a job never stays running.
        drop(Unfinished(run));
    }
    Ok(run)
}

/// Run `work` on a thread of its own; false when none could be started.
fn spawn(name: &str, work: impl FnOnce() + Send + 'static) -> bool {
    match std::thread::Builder::new().name(name.into()).spawn(work) {
        Ok(_) => true,
        Err(error) => {
            tracing::warn!("{name} could not start: {error}");
            false
        },
    }
}

fn stage(run: u64, stage: &str) {
    if let Some(job) = state().job.as_mut().filter(|job| job.run == run) {
        job.stage = Some(stage.into());
    }
}

/// Ends job `run` as failed unless it finished: a job never stays running.
struct Unfinished(u64);
impl Drop for Unfinished {
    fn drop(&mut self) {
        let mut state = state();
        if let Some(job) = state
            .job
            .as_mut()
            .filter(|job| job.run == self.0 && job.state == "running")
        {
            job.state = "failed".into();
            job.stage = None;
            job.failure = Some("failed".into());
            job.finished_at_ms = Some(now_ms());
        }
        drop(state);
        SHARED.changed.notify_all();
    }
}

fn run_job(run: u64, installed: Installed, invocation: super::command::Invocation) {
    let _unfinished = Unfinished(run);
    let kind = installed.kind;
    let restart_services = settings::load().map_or(true, |settings| settings.restart_services);
    let mut outcome = Outcome::default();
    // Only services on the installation being updated restart; one on
    // another copy keeps running what it runs.
    let (targets, others) =
        restart::split(restart::targets().remove(&kind).unwrap_or_default(), &installed.path);
    outcome.skip_all(&others, "other_install");
    let paused = if restart_services && restart::STOP_FIRST {
        stage(run, "stopping");
        restart::pause(&targets, &mut outcome)
    } else {
        Vec::new()
    };
    stage(run, "updating");
    tracing::info!(kind = kind.label(), from = ?installed.version, "updating harness");
    let result = super::command::install(&invocation);
    let after = install::detect(kind, Some(&installed.path));
    let to_version = after.as_ref().and_then(|found| found.version.clone());
    let changed = result.is_ok() && to_version != installed.version;
    if !paused.is_empty() || changed && restart_services {
        stage(run, "restarting");
    }
    restart::resume(paused, &mut outcome);
    if changed {
        if !restart_services {
            outcome.skip_all(&targets, "disabled");
        } else if !restart::STOP_FIRST {
            restart::restart(&targets, &mut outcome);
        } else {
            // Stopped before the update and started again above; only the
            // ones that could not be stopped are left.
            let handled: Vec<String> = outcome
                .restarted
                .iter()
                .chain(outcome.skipped.iter().map(|skipped| &skipped.name))
                .cloned()
                .collect();
            let rest: Vec<_> = targets
                .into_iter()
                .filter(|target| !handled.contains(&target.name))
                .collect();
            restart::restart(&rest, &mut outcome);
        }
    }
    tracing::info!(
        kind = kind.label(),
        to = ?to_version,
        ok = result.is_ok(),
        restarted = outcome.restarted.len(),
        "harness update finished"
    );
    let mut state = state();
    // A check that began before this cannot replace it with what it saw.
    state.generation += 1;
    let generation = state.generation;
    state.installed_at.insert(kind, generation);
    state
        .found
        .entry(kind)
        .or_insert(Found {
            installed: None,
            latest: None,
        })
        .installed = after;
    if let Some(job) = state.job.as_mut().filter(|job| job.run == run) {
        job.state = if result.is_ok() { "done" } else { "failed" }.into();
        job.stage = None;
        job.to_version = to_version;
        job.failure = result.err().map(|failure| failure.code().into());
        job.restarted = outcome.restarted;
        job.not_restarted = outcome.skipped;
        job.finished_at_ms = Some(now_ms());
    }
}

/// Start the schedule once, in the app that owns this device's hosting: a
/// check after [`FIRST_CHECK`] and then every [`CHECK_EVERY`], each followed
/// by the automatic updates this device's settings ask for, one at a time.
pub fn initialize() {
    static STARTED: std::sync::Once = std::sync::Once::new();
    if !supported() || crate::engine::host_owner::require().is_err() {
        return;
    }
    STARTED.call_once(|| {
        spawn("pcx-harness-schedule", || {
            std::thread::sleep(FIRST_CHECK);
            loop {
                check_now();
                automatic_updates();
                std::thread::sleep(CHECK_EVERY);
            }
        });
    });
}

fn automatic_updates() {
    let Ok(overview) = overview() else { return };
    for harness in overview.harnesses {
        if !(harness.auto_update && harness.update_available && harness.can_update) {
            continue;
        }
        let Some(kind) = Kind::parse(&harness.kind) else { continue };
        match start(kind, true) {
            Ok(run) => wait_for(run),
            Err(error) => {
                tracing::info!(kind = kind.label(), "automatic update not started: {error:#}")
            },
        }
    }
}

fn wait_for(run: u64) {
    let mut state = state();
    while state
        .job
        .as_ref()
        .is_some_and(|job| job.run == run && job.state == "running")
    {
        state = SHARED
            .changed
            .wait(state)
            .unwrap_or_else(|poison| poison.into_inner());
    }
}
