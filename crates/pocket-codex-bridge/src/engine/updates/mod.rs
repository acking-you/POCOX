//! App updates from the project's GitHub Releases.
//!
//! A quiet check runs in the background (first shortly after start, then at
//! most every [`CHECK_EVERY`]); it fetches only the newest release's signed
//! manifest. On the user's word the file for this installation is
//! downloaded, checked against the manifest (size and SHA-256; on macOS also
//! the bundle's Developer ID team, notarization, identifier and version) and
//! applied the way the platform allows ([`apply`]).
//!
//! The UI renders [`Snapshot`]s: every change is pushed to the watchers, so
//! the Dart side holds no update logic of its own beyond quitting the app
//! (desktop) or calling the system installer (Android).
mod apply;
mod fetch;
mod macos;
pub mod manifest;
#[cfg(test)]
mod tests;

use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex, MutexGuard,
    },
    time::{Duration, Instant},
};

use once_cell::sync::Lazy;
use serde::{Deserialize, Serialize};

use self::{
    apply::Handoff,
    fetch::{Fetcher, Stop},
    manifest::{Manifest, Method, Plan, MANIFEST_NAME, PUBLIC_KEY, REPOSITORY, SIGNATURE_NAME},
};

/// How often the background check asks GitHub, across restarts.
pub const CHECK_EVERY: Duration = Duration::from_secs(6 * 60 * 60);
/// The first background check waits this long after the app starts.
const FIRST_CHECK: Duration = Duration::from_secs(20);
/// How often the background loop wakes to see whether a check is due.
const TICK: Duration = Duration::from_secs(60 * 60);
/// A manifest is a few kilobytes; anything far larger is not one.
const MANIFEST_LIMIT: usize = 1 << 20;

/// Why an update could not go ahead; the UI words it from the kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// GitHub could not be reached, or answered with an error.
    Network,
    /// The manifest is not signed by the release key.
    Signature,
    /// The download is not the file the manifest names.
    Checksum,
    /// The new app is not POCOX from the release team.
    Verification,
    /// Writing, opening or starting the update failed.
    Install,
    /// Android: the user has not let POCOX install packages.
    Permission,
    /// The app could not quit to let the update in.
    Quit,
}

impl Kind {
    /// The wire name.
    pub fn name(self) -> &'static str {
        match self {
            Self::Network => "network",
            Self::Signature => "signature",
            Self::Checksum => "checksum",
            Self::Verification => "verification",
            Self::Install => "install",
            Self::Permission => "permission",
            Self::Quit => "quit",
        }
    }

    /// The kind named `name`; unknown names are install failures.
    pub fn parse(name: &str) -> Self {
        match name {
            "network" => Self::Network,
            "signature" => Self::Signature,
            "checksum" => Self::Checksum,
            "verification" => Self::Verification,
            "permission" => Self::Permission,
            "quit" => Self::Quit,
            _ => Self::Install,
        }
    }
}

/// A failure with the underlying error, for the log and the copyable detail.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Failure {
    /// What went wrong.
    pub kind: Kind,
    /// The underlying error.
    pub detail: String,
}

impl Failure {
    /// A failure of `kind` because of `detail`.
    pub fn new(kind: Kind, detail: impl std::fmt::Display) -> Self {
        Self {
            kind,
            detail: detail.to_string(),
        }
    }
}

/// Where the update stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    /// Nothing known yet.
    Idle,
    /// Asking GitHub.
    Checking,
    /// This is the newest release.
    UpToDate,
    /// A newer release exists.
    Available,
    /// Fetching its file.
    Downloading,
    /// Checking the file (and on macOS the bundle inside it).
    Verifying,
    /// Verified and ready to apply.
    Ready,
    /// A development build verified the update and stops short of replacing
    /// itself.
    VerifiedOnly,
    /// Handed over: the app is quitting, or the system installer is open.
    Installing,
    /// Opened in the desktop's installer.
    Opened,
    /// Saved to Downloads.
    Saved,
    /// The last thing the user asked for failed.
    Failed,
}

impl Phase {
    /// The wire name.
    pub fn name(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Checking => "checking",
            Self::UpToDate => "up_to_date",
            Self::Available => "available",
            Self::Downloading => "downloading",
            Self::Verifying => "verifying",
            Self::Ready => "ready",
            Self::VerifiedOnly => "verified_only",
            Self::Installing => "installing",
            Self::Opened => "opened",
            Self::Saved => "saved",
            Self::Failed => "failed",
        }
    }

    fn busy(self) -> bool {
        matches!(self, Self::Checking | Self::Downloading | Self::Verifying | Self::Installing)
    }
}

/// Everything the UI shows about updates.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    /// The running version.
    pub current: String,
    /// Where the update stands.
    pub phase: Phase,
    /// The newest release, once a check found one.
    pub latest: Option<String>,
    /// Whether it is newer than the running version.
    pub newer: bool,
    /// How that release would apply here.
    pub method: Method,
    /// The size of its file for this installation.
    pub size: Option<u64>,
    /// Bytes downloaded so far.
    pub received: u64,
    /// The newest release's page (every release before a check).
    pub page: String,
    /// When GitHub last answered a check (Unix milliseconds).
    pub checked_at: Option<i64>,
    /// The last failure: of the action that failed, or of a background
    /// check (which leaves the phase alone).
    pub failure: Option<Failure>,
    /// The saved or opened file, or (Android) the package to install.
    pub path: Option<String>,
    /// The newest version the user has been told about.
    pub announced: Option<String>,
}

/// Where updates come from and what runs here. Fixed in release builds;
/// development builds may point it at a copy of a release for testing.
#[derive(Debug, Clone)]
pub struct Config {
    /// The running version.
    pub current: semver::Version,
    /// A directory URL (ending in `/`) holding a copy of a release, instead
    /// of GitHub.
    pub feed: Option<String>,
    /// The raw base64 Ed25519 key manifests must be signed with.
    pub public_key: String,
    /// Whether the app may replace itself; development builds only verify,
    /// unless a test feed or version was set on purpose.
    pub replace_self: bool,
}

impl Config {
    /// This build's configuration. Development builds read
    /// `POCOX_UPDATE_FEED`, `POCOX_UPDATE_PUBLIC_KEY` and
    /// `POCOX_UPDATE_INSTALLED_VERSION`; release builds ignore them.
    pub fn current() -> Self {
        let built = semver::Version::parse(env!("CARGO_PKG_VERSION"))
            .unwrap_or_else(|_| semver::Version::new(0, 0, 0));
        let mut config = Self {
            current: built,
            feed: None,
            public_key: PUBLIC_KEY.into(),
            replace_self: !cfg!(debug_assertions),
        };
        if cfg!(debug_assertions) {
            let var = |name: &str| std::env::var(name).ok().filter(|value| !value.is_empty());
            if let Some(feed) = var("POCOX_UPDATE_FEED") {
                config.feed = Some(if feed.ends_with('/') { feed } else { format!("{feed}/") });
                config.replace_self = true;
            }
            if let Some(key) = var("POCOX_UPDATE_PUBLIC_KEY") {
                config.public_key = key;
            }
            if let Some(version) = var("POCOX_UPDATE_INSTALLED_VERSION")
                .and_then(|value| semver::Version::parse(&value).ok())
            {
                config.current = version;
                config.replace_self = true;
            }
        }
        config
    }

    fn manifest_url(&self) -> String {
        match &self.feed {
            Some(feed) => format!("{feed}{MANIFEST_NAME}"),
            None => {
                format!("https://github.com/{REPOSITORY}/releases/latest/download/{MANIFEST_NAME}")
            },
        }
    }

    /// `name` in the release tagged `v<version>`. The signature is fetched
    /// from the version the manifest claims rather than "latest", so a
    /// release published in between cannot pair one manifest with another's
    /// signature.
    fn file_url(&self, version: &semver::Version, name: &str) -> String {
        match &self.feed {
            Some(feed) => format!("{feed}{name}"),
            None => format!("https://github.com/{REPOSITORY}/releases/download/v{version}/{name}"),
        }
    }
}

/// What a check last learned, kept across restarts so the background check
/// stays rare and a found release is offered at once on the next start.
#[derive(Debug, Default, Serialize, Deserialize)]
struct Saved {
    checked_at: Option<i64>,
    manifest: Option<String>,
    signature: Option<String>,
    announced: Option<String>,
}

#[derive(Debug, Clone)]
struct Staged {
    version: semver::Version,
    method: Method,
    path: PathBuf,
    work: PathBuf,
}

#[derive(Debug)]
struct State {
    phase: Phase,
    release: Option<(Manifest, Plan)>,
    received: u64,
    checked_at: Option<i64>,
    failure: Option<Failure>,
    staged: Option<Staged>,
    path: Option<PathBuf>,
    announced: Option<String>,
    loaded: bool,
}

type Watcher = Box<dyn FnMut(&Snapshot) -> bool + Send>;

/// The update flow of one installation.
pub struct Updater {
    config: Config,
    host: manifest::Host,
    /// Where [`Saved`] and downloads live.
    dir: Box<dyn Fn() -> Option<PathBuf> + Send + Sync>,
    state: Mutex<State>,
    watchers: Mutex<Vec<Watcher>>,
    cancelled: AtomicBool,
    auto: std::sync::Once,
}

static UPDATER: Lazy<Updater> = Lazy::new(|| {
    Updater::new(Config::current(), apply::host(), || {
        super::runtime::support_dir()
            .ok()
            .map(|dir| dir.join("updates"))
    })
});

/// This app's updater.
pub fn updater() -> &'static Updater {
    &UPDATER
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

impl Updater {
    /// An updater for `host` under `config`, keeping its files in `dir`.
    pub fn new(
        config: Config,
        host: manifest::Host,
        dir: impl Fn() -> Option<PathBuf> + Send + Sync + 'static,
    ) -> Self {
        Self {
            config,
            host,
            dir: Box::new(dir),
            state: Mutex::new(State {
                phase: Phase::Idle,
                release: None,
                received: 0,
                checked_at: None,
                failure: None,
                staged: None,
                path: None,
                announced: None,
                loaded: false,
            }),
            watchers: Mutex::new(Vec::new()),
            cancelled: AtomicBool::new(false),
            auto: std::sync::Once::new(),
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        let mut state = self.state.lock().unwrap_or_else(|p| p.into_inner());
        if !state.loaded {
            state.loaded = true;
            self.restore(&mut state);
        }
        state
    }

    fn saved_path(&self) -> Option<PathBuf> {
        (self.dir)().map(|dir| dir.join("state.json"))
    }

    fn read_saved(&self) -> Saved {
        self.saved_path()
            .and_then(|path| std::fs::read(path).ok())
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn write_saved(&self, saved: &Saved) {
        let Some(path) = self.saved_path() else { return };
        let write = || -> std::io::Result<()> {
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir)?;
            }
            let temp = path.with_extension("json.tmp");
            std::fs::write(&temp, serde_json::to_vec_pretty(saved)?)?;
            std::fs::rename(temp, &path)
        };
        if let Err(error) = write() {
            tracing::warn!(%error, "could not save the update check");
        }
    }

    /// Restores the last check: its time, the announced version and, if its
    /// signature still holds, the release it found.
    fn restore(&self, state: &mut State) {
        let saved = self.read_saved();
        state.announced = saved.announced;
        state.checked_at = saved.checked_at;
        if let (Some(text), Some(signature)) = (saved.manifest, saved.signature) {
            if let Ok(manifest) =
                manifest::verify(text.as_bytes(), &signature, &self.config.public_key)
            {
                self.adopt(state, manifest);
            }
        }
    }

    /// Records `manifest` as the newest release.
    fn adopt(&self, state: &mut State, release: Manifest) {
        let newer = release.version > self.config.current;
        let plan = manifest::plan(&release, self.host);
        if state
            .staged
            .as_ref()
            .is_some_and(|staged| staged.version != release.version)
        {
            state.staged = None;
        }
        state.phase = if newer { Phase::Available } else { Phase::UpToDate };
        state.release = Some((release, plan));
    }

    fn snapshot_of(&self, state: &State) -> Snapshot {
        let release = state.release.as_ref();
        let newer = release.filter(|(manifest, _)| manifest.version > self.config.current);
        Snapshot {
            current: self.config.current.to_string(),
            phase: state.phase,
            latest: release.map(|(manifest, _)| manifest.version.to_string()),
            newer: newer.is_some(),
            method: newer.map_or(Method::ReleasePage, |(_, plan)| plan.method),
            size: newer.and_then(|(_, plan)| plan.asset.as_ref().map(|asset| asset.size)),
            received: state.received,
            page: manifest::release_page(release.map(|(manifest, _)| &manifest.version)),
            checked_at: state.checked_at,
            failure: state.failure.clone(),
            path: state.path.as_ref().map(|path| path.display().to_string()),
            announced: state.announced.clone(),
        }
    }

    /// The current state.
    pub fn snapshot(&self) -> Snapshot {
        self.snapshot_of(&self.lock())
    }

    /// Calls `watcher` with the current state and every later change, until
    /// it returns false.
    pub fn watch(&self, mut watcher: impl FnMut(&Snapshot) -> bool + Send + 'static) {
        if watcher(&self.snapshot()) {
            self.watchers
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .push(Box::new(watcher));
        }
    }

    fn publish(&self, state: MutexGuard<'_, State>) {
        let snapshot = self.snapshot_of(&state);
        drop(state);
        self.watchers
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .retain_mut(|watcher| watcher(&snapshot));
    }

    fn set(&self, change: impl FnOnce(&mut State)) {
        let mut state = self.lock();
        change(&mut state);
        self.publish(state);
    }

    /// Starts the background check once per process: shortly after start,
    /// then whenever [`CHECK_EVERY`] has passed since GitHub last answered.
    pub fn start_background(&'static self) {
        self.auto.call_once(|| {
            super::runtime::runtime().spawn(async move {
                tokio::time::sleep(FIRST_CHECK).await;
                loop {
                    self.check(false).await;
                    tokio::time::sleep(TICK).await;
                }
            });
        });
    }

    /// Asks GitHub for the newest release, unless `force` is false and it
    /// answered less than [`CHECK_EVERY`] ago. A failed background check
    /// leaves the phase alone and only records why.
    pub async fn check(&self, force: bool) -> Snapshot {
        {
            let mut state = self.lock();
            if state.phase.busy() || matches!(state.phase, Phase::Ready | Phase::VerifiedOnly) {
                return self.snapshot_of(&state);
            }
            let fresh = state
                .checked_at
                .is_some_and(|at| now_ms().saturating_sub(at) < CHECK_EVERY.as_millis() as i64);
            if !force && fresh {
                return self.snapshot_of(&state);
            }
            if force {
                state.phase = Phase::Checking;
                state.failure = None;
                self.publish(state);
            }
        }
        let result = self.fetch_release().await;
        let mut state = self.lock();
        match result {
            Ok((release, text, signature)) => {
                state.checked_at = Some(now_ms());
                state.failure = None;
                self.adopt(&mut state, release);
                let mut saved = self.read_saved();
                saved.checked_at = state.checked_at;
                saved.manifest = Some(text);
                saved.signature = Some(signature);
                self.write_saved(&saved);
            },
            Err(failure) => {
                tracing::info!(kind = failure.kind.name(), detail = %failure.detail, "update check failed");
                if force {
                    state.phase = Phase::Failed;
                }
                state.failure = Some(failure);
            },
        }
        let snapshot = self.snapshot_of(&state);
        self.publish(state);
        snapshot
    }

    async fn fetch_release(&self) -> Result<(Manifest, String, String), Failure> {
        let fetcher = Fetcher::new()?;
        let bytes = fetcher
            .small(&self.config.manifest_url(), MANIFEST_LIMIT)
            .await?;
        let claimed = Manifest::parse(&bytes)
            .map_err(|error| Failure::new(Kind::Signature, format!("{error:#}")))?;
        let signature = fetcher
            .small(&self.config.file_url(&claimed.version, SIGNATURE_NAME), 4096)
            .await?;
        let signature = String::from_utf8_lossy(&signature).trim().to_string();
        let release = manifest::verify(&bytes, &signature, &self.config.public_key)
            .map_err(|error| Failure::new(Kind::Signature, format!("{error:#}")))?;
        let text =
            String::from_utf8(bytes).map_err(|error| Failure::new(Kind::Signature, error))?;
        Ok((release, text, signature))
    }

    /// The user asked for the update: fetches the newest release's file for
    /// this installation, checks it and readies it to apply.
    pub async fn download(&self) -> Snapshot {
        let (release, asset, method, dir) = {
            let mut state = self.lock();
            if state.phase.busy() {
                return self.snapshot_of(&state);
            }
            // Readied before (and a failed quit or a dismissed installer
            // since): apply that again rather than fetch it anew.
            let current = state
                .release
                .as_ref()
                .map(|(release, _)| release.version.clone());
            if let Some(staged) = &state.staged {
                if Some(&staged.version) == current.as_ref() && staged.path.exists() {
                    state.phase = Phase::Ready;
                    state.failure = None;
                    let snapshot = self.snapshot_of(&state);
                    self.publish(state);
                    return snapshot;
                }
                state.staged = None;
            }
            let Some((release, plan)) = state.release.clone() else {
                return self.snapshot_of(&state);
            };
            let Some(asset) = plan.asset.filter(|_| release.version > self.config.current) else {
                return self.snapshot_of(&state);
            };
            let Some(dir) = (self.dir)() else {
                state.phase = Phase::Failed;
                state.failure = Some(Failure::new(Kind::Install, "no folder for downloads"));
                let snapshot = self.snapshot_of(&state);
                self.publish(state);
                return snapshot;
            };
            state.phase = Phase::Downloading;
            state.received = 0;
            state.failure = None;
            state.path = None;
            self.cancelled.store(false, Ordering::Relaxed);
            self.publish(state);
            (release, asset, plan.method, dir)
        };
        let outcome = self.fetch_and_stage(&release, &asset, method, &dir).await;
        let mut state = self.lock();
        match outcome {
            Ok(staged) => {
                state.phase = Phase::Ready;
                state.staged = Some(staged);
            },
            Err(Stop::Cancelled) => {
                state.phase = Phase::Available;
                state.received = 0;
            },
            Err(Stop::Failed(failure)) => {
                tracing::warn!(kind = failure.kind.name(), detail = %failure.detail, "update failed");
                state.phase = Phase::Failed;
                state.failure = Some(failure);
            },
        }
        let snapshot = self.snapshot_of(&state);
        self.publish(state);
        snapshot
    }

    async fn fetch_and_stage(
        &self,
        release: &Manifest,
        asset: &manifest::Asset,
        method: Method,
        dir: &Path,
    ) -> Result<Staged, Stop> {
        // Earlier attempts' files are of no further use.
        let _ = tokio::fs::remove_dir_all(dir.join("work")).await;
        let work = dir
            .join("work")
            .join(format!("{}-{}", release.version, now_ms()));
        tokio::fs::create_dir_all(&work)
            .await
            .map_err(|error| Failure::new(Kind::Install, error))?;
        let file = work.join(&asset.name);
        let url = self.config.file_url(&release.version, &asset.name);
        let mut last = Instant::now();
        let progress = |received: u64| {
            // About ten updates a second is plenty for a progress label.
            if last.elapsed() >= Duration::from_millis(100) || received == asset.size {
                last = Instant::now();
                self.set(|state| state.received = received);
            }
        };
        let fetcher = Fetcher::new()?;
        let result = fetcher
            .file(&url, &file, asset, progress, &self.cancelled)
            .await;
        if let Err(stop) = result {
            let _ = tokio::fs::remove_dir_all(&work).await;
            return Err(stop);
        }
        self.set(|state| state.phase = Phase::Verifying);
        let version = release.version.clone();
        let (file_in, work_in) = (file.clone(), work.clone());
        let staged =
            tokio::task::spawn_blocking(move || apply::stage(method, &file_in, &work_in, &version))
                .await
                .map_err(|error| Failure::new(Kind::Verification, error))?;
        match staged {
            Ok(path) => Ok(Staged {
                version: release.version.clone(),
                method,
                path,
                work,
            }),
            Err(failure) => {
                let _ = tokio::fs::remove_dir_all(&work).await;
                Err(failure.into())
            },
        }
    }

    /// Stops a download in progress.
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Relaxed);
    }

    /// Applies the readied update. On a restart method the helper now waits
    /// and the caller must quit the app; on Android the caller then hands
    /// [`Snapshot::path`] to the system installer.
    pub fn install(&self) -> Snapshot {
        let mut state = self.lock();
        let Some(staged) = state.staged.clone().filter(|_| state.phase == Phase::Ready) else {
            return self.snapshot_of(&state);
        };
        if staged.method.restarts() && !self.config.replace_self {
            state.phase = Phase::VerifiedOnly;
        } else {
            match apply::hand_off(staged.method, &staged.path, &staged.work) {
                Ok(Handoff::Quit) => state.phase = Phase::Installing,
                // The system installer asks the user, who may decline; the
                // package stays readied for another try.
                Ok(Handoff::Opened(path) | Handoff::System(path)) => {
                    state.phase = Phase::Opened;
                    state.path = Some(path);
                },
                Ok(Handoff::Saved(path)) => {
                    state.phase = Phase::Saved;
                    state.path = Some(path);
                    state.staged = None;
                },
                Err(failure) => {
                    state.phase = Phase::Failed;
                    state.failure = Some(failure);
                },
            }
        }
        let snapshot = self.snapshot_of(&state);
        self.publish(state);
        snapshot
    }

    /// The app reports a failure of its part: the quit an update waited for,
    /// or the Android installer. A readied update stays ready to retry.
    pub fn report(&self, kind: Kind, detail: String) {
        self.set(|state| {
            state.phase = Phase::Failed;
            state.failure = Some(Failure {
                kind,
                detail,
            });
        });
    }

    /// Remembers that the user has been told about `version`.
    pub fn announce(&self, version: String) {
        let mut saved = self.read_saved();
        saved.announced = Some(version.clone());
        self.write_saved(&saved);
        self.set(|state| state.announced = Some(version));
    }
}
