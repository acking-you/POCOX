//! Native foreground hosting shared by CLI and desktop management.

use std::{
    fs::{File, TryLockError},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use host_profiles::files::write_private;
use pocket_codex_pb::{RelaySession, Transport};
use serde::{Deserialize, Serialize};

use super::{host_lifecycle, host_profiles, management, runtime, serve};

/// Held for the supervisor's lifetime; its holder is the live supervisor.
const OWNER_LOCK: &str = "owner.lock";
const STATUS: &str = "status.json";

/// Startup configuration for one native managed-host supervisor.
pub struct Options {
    /// Directory containing the existing CLI account/relay `config.toml`.
    pub config_dir: PathBuf,
    /// Private daemon state, independent of desktop restore preferences.
    pub state_dir: PathBuf,
    /// Device segment of every service and the management entry. The caller
    /// initializes the installation identity before starting.
    pub device: String,
    /// Initial Codex instance, used only without a saved lifecycle choice.
    pub name: String,
    /// External Codex executable for the initial instance.
    pub binary: Option<String>,
    /// Initial Codex app-server's loopback port.
    pub port: u16,
    /// Initial instance's upstream proxy.
    pub proxy: Option<String>,
    /// Explicit self-host relay; otherwise use the saved transport and renewal.
    pub relay: Option<RelaySession>,
}

/// Safe local status for one hosted service.
#[derive(Serialize, Deserialize)]
pub struct ServiceStatus {
    /// Instance name.
    pub name: String,
    /// Owned agent PID, if available.
    pub pid: Option<u32>,
    /// Agent is responding.
    pub alive: bool,
    /// Loopback endpoint.
    pub endpoint: String,
    /// Relay service key.
    pub key: String,
}

/// What the supervisor last reported; contains no launch secrets.
#[derive(Serialize, Deserialize)]
pub struct Status {
    /// Supervisor PID.
    pub pid: u32,
    /// Management permission and relay reachability.
    pub management: management::LocalStatus,
    /// Services owned by this supervisor.
    pub services: Vec<ServiceStatus>,
}

/// One foreground owner of all services created through its management entry.
pub struct Manager {
    state_dir: PathBuf,
    stopped: bool,
    /// The status file's current contents, so an unchanged state is not
    /// rewritten every tick.
    written: Vec<u8>,
    /// Whether the last save failed, so a lasting failure is logged once.
    save_failed: bool,
    _lock: File,
}

fn lock(state: &Path) -> Result<File> {
    std::fs::create_dir_all(state).context("creating managed-host state")?;
    let mut options = std::fs::OpenOptions::new();
    options.create(true).read(true).write(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        std::fs::set_permissions(state, std::fs::Permissions::from_mode(0o700))?;
        options.mode(0o600);
    }
    let file = options.open(state.join(OWNER_LOCK))?;
    // A `pocket-codex status` probe holds the lock for an instant; only a
    // holder that outlasts it is another supervisor.
    for attempt in 0.. {
        match file.try_lock() {
            Ok(()) => break,
            Err(TryLockError::WouldBlock) if attempt < 10 => {
                std::thread::sleep(std::time::Duration::from_millis(20));
            },
            Err(error) => {
                return Err(error)
                    .context("another managed-host supervisor owns this state directory");
            },
        }
    }
    // A report left by a supervisor that did not exit cleanly is not ours.
    match std::fs::remove_file(state.join(STATUS)) {
        Ok(()) => {},
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {},
        Err(error) => return Err(error).context("removing a stale managed-host status"),
    }
    Ok(file)
}

impl Manager {
    /// Restore saved services and enable the existing device-management
    /// protocol. Call on a blocking thread; shutdown owns only this
    /// process's engines.
    pub fn start(options: Options) -> Result<Self> {
        let name = super::host_names::canonical(&options.name)?;
        let lock = lock(&options.state_dir)?;
        runtime::configure_host(runtime::HostContext {
            device: pocket_codex_core::service::sanitize_component(&options.device),
            profiles: options.state_dir.join("hosting"),
            transport: options.relay.map(|session| Transport {
                session,
                namespace: None,
            }),
        })?;
        let _ = rustls::crypto::ring::default_provider().install_default();
        runtime::init(options.config_dir)?;
        let mut manager = Self {
            state_dir: options.state_dir,
            stopped: false,
            written: Vec::new(),
            save_failed: false,
            _lock: lock,
        };
        let initial = host_profiles::Runtime::Codex {
            binary: options.binary,
            port: options.port,
            proxy: options.proxy,
        };
        if let Err(error) = manager.restore(&name, initial) {
            if let Err(stop) = manager.stop() {
                tracing::error!(%stop, "managed-host startup cleanup failed");
            }
            return Err(error);
        }
        Ok(manager)
    }

    /// Restore every saved service, then publish management. A service that
    /// cannot start is reported and left for repair from another device; only
    /// an unreadable restore ledger, whose choices would be guesses, stops
    /// startup.
    fn restore(&mut self, initial_name: &str, initial: host_profiles::Runtime) -> Result<()> {
        let entries = host_lifecycle::entries()?;
        let saved = entries
            .iter()
            .filter(|(_, entry)| entry.runtime.is_some())
            .map(|(name, entry)| (name.as_str(), Some(entry.revision), None));
        let first_start =
            (!entries.contains_key(initial_name)).then_some((initial_name, None, Some(initial)));
        for (name, revision, runtime) in saved.chain(first_start) {
            if let Err(error) = host_lifecycle::restore(name, revision, runtime) {
                tracing::warn!(service = name, "not restored: {error:#}");
                host_lifecycle::record_restore_failure(name);
            }
        }
        management::set_enabled(true)?;
        self.refresh_status()?;
        Ok(())
    }

    /// Report the current state to `pocket-codex status`, rewriting the file
    /// only when it changed. The file is a view: failing to save it is logged,
    /// never fatal to the services.
    pub fn refresh_status(&mut self) -> Result<Status> {
        let status = Status {
            pid: std::process::id(),
            management: management::local_status()?,
            services: serve::serve_status()
                .into_iter()
                .map(|host| ServiceStatus {
                    name: host.name,
                    pid: host.pid,
                    alive: host.alive,
                    endpoint: host.app_listen_addr,
                    key: host.app_service_key,
                })
                .collect(),
        };
        let bytes = serde_json::to_vec(&status)?;
        if bytes != self.written {
            match write_private(&self.state_dir.join(STATUS), &bytes) {
                Ok(_) => {
                    self.written = bytes;
                    self.save_failed = false;
                },
                Err(error) if !self.save_failed => {
                    self.save_failed = true;
                    tracing::warn!("managed-host status not saved: {error:#}");
                },
                Err(_) => {},
            }
        }
        Ok(status)
    }

    /// Withdraw management and stop owned services without changing restore
    /// choices.
    pub fn stop(&mut self) -> Result<()> {
        if !self.stopped {
            serve::serve_stop_all()?;
            self.stopped = true;
            match std::fs::remove_file(self.state_dir.join(STATUS)) {
                Ok(()) => {},
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {},
                Err(error) => return Err(error).context("removing managed-host status"),
            }
        }
        Ok(())
    }
}

impl Drop for Manager {
    fn drop(&mut self) {
        if let Err(error) = self.stop() {
            tracing::error!(%error, "managed-host shutdown failed");
        }
    }
}

/// The running supervisor's last report, or `None` when no supervisor holds
/// this state directory (or it has not reported yet).
pub fn read_status(state_dir: &Path) -> Result<Option<Status>> {
    let owner = match File::open(state_dir.join(OWNER_LOCK)) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error).context("opening the managed-host lock"),
    };
    match owner.try_lock_shared() {
        // Nobody holds it. Release the probe at once rather than on close,
        // which Windows may delay, so a starting supervisor is not refused.
        Ok(()) => {
            let _ = owner.unlock();
            return Ok(None);
        },
        Err(TryLockError::WouldBlock) => {},
        Err(TryLockError::Error(error)) => {
            return Err(error).context("probing the managed-host lock");
        },
    }
    match std::fs::read(state_dir.join(STATUS)) {
        // A report from a different version shows as not reported yet.
        Ok(bytes) => Ok(serde_json::from_slice(&bytes).ok()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).context("reading managed-host status"),
    }
}
