//! One process at a time hosts from a hosting state directory.
//!
//! The owner holds an exclusive lock on `<dir>/owner.lock` for as long as it
//! runs. The operating system releases the lock when the process exits or
//! crashes, so a dead owner never blocks the next one and nothing stale is
//! left to clean up: the lock, never a recorded process id, decides who is
//! alive. The id the owner writes into the file only names it in messages.
//! Rust opens files close-on-exec (not inheritable on Windows), so an agent
//! the owner spawned and outlived never keeps the lock.
//!
//! The CLI supervisor ([`super::daemon`]) takes its directory's lock and does
//! not start without it. The desktop app claims its hosting state once, when
//! it starts ([`claim_desktop`]). A copy started while another one runs still
//! opens and can connect to services, but for the rest of its life every
//! start, restart and apply (through [`super::host_lease`]), an explicit
//! stop's restore record, the management entry and the agent tools refuse
//! ([`require`]). So it never starts, adopts, stops or re-registers the first
//! app's services, nor changes what that app restores or serves.

use std::{
    fs::{File, TryLockError},
    io::Write as _,
    path::{Path, PathBuf},
    sync::Mutex,
};

use anyhow::{anyhow, Context, Result};

use super::host_profiles::{self, files};

/// The lock file's name in the directory it guards.
pub(super) const LOCK_FILE: &str = "owner.lock";

/// A held owner lock; dropping it releases the directory.
pub(super) struct OwnerLock(File);

/// Another live process owns the directory.
#[derive(Debug, Clone)]
pub(super) struct HeldElsewhere {
    /// The owner's process id, when its lock file could be read.
    pub pid: Option<u32>,
}

impl std::fmt::Display for HeldElsewhere {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.pid {
            Some(pid) => {
                write!(f, "another POCOX process (pid {pid}) is hosting from this state directory")
            },
            None => f.write_str("another POCOX process is hosting from this state directory"),
        }
    }
}

impl std::error::Error for HeldElsewhere {}

impl OwnerLock {
    /// Take `dir`'s lock without waiting. Fails with [`HeldElsewhere`] while
    /// another live process holds it.
    pub(super) fn try_acquire(dir: &Path) -> Result<Self> {
        files::private_dir(dir)?;
        let path = dir.join(LOCK_FILE);
        let mut file = files::private_options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&path)
            .context("opening the hosting owner lock")?;
        match file.try_lock() {
            Ok(()) => {},
            Err(TryLockError::WouldBlock) => {
                return Err(HeldElsewhere {
                    pid: read_pid(&path),
                }
                .into())
            },
            Err(TryLockError::Error(error)) => {
                return Err(error).context("locking the hosting owner lock")
            },
        }
        let pid = std::process::id().to_string();
        if let Err(error) = file
            .set_len(0)
            .and_then(|()| file.write_all(pid.as_bytes()))
        {
            tracing::debug!(%error, "the hosting owner lock does not name its process");
        }
        Ok(Self(file))
    }
}

impl Drop for OwnerLock {
    fn drop(&mut self) {
        // At once rather than on close, which Windows may delay.
        let _ = self.0.unlock();
    }
}

/// The holder's id. Windows refuses to read a locked file, so it is unknown
/// there.
fn read_pid(path: &Path) -> Option<u32> {
    std::fs::read_to_string(path).ok()?.trim().parse().ok()
}

/// The desktop app's claim on its hosting state, made when it starts.
enum Claim {
    /// Held until the process exits.
    Owned { _lock: OwnerLock },
    /// Another live app owned it.
    Elsewhere(HeldElsewhere),
    /// It could not be locked.
    Failed(String),
}

fn claim(dir: Result<PathBuf>) -> Claim {
    match dir.and_then(|dir| OwnerLock::try_acquire(&dir)) {
        Ok(lock) => Claim::Owned {
            _lock: lock,
        },
        Err(error) => match error.downcast::<HeldElsewhere>() {
            Ok(held) => Claim::Elsewhere(held),
            Err(error) => Claim::Failed(format!("{error:#}")),
        },
    }
}

fn refusal(claim: &Claim) -> Result<()> {
    match claim {
        Claim::Owned {
            ..
        } => Ok(()),
        Claim::Elsewhere(held) => Err(held.clone().into()),
        Claim::Failed(reason) => Err(anyhow!("the hosting state could not be locked: {reason}")),
    }
}

/// `None` until [`claim_desktop`]: tests, phones and the CLI supervisor
/// never claim the desktop state.
static DESKTOP: Mutex<Option<Claim>> = Mutex::new(None);

fn desktop() -> std::sync::MutexGuard<'static, Option<Claim>> {
    DESKTOP.lock().unwrap_or_else(|p| p.into_inner())
}

/// Own this computer's hosting state for the rest of the desktop app's life,
/// or note that another app does. Never fails the app's start; a second call
/// changes nothing.
pub fn claim_desktop() {
    if cfg!(any(target_os = "ios", target_os = "android")) {
        return;
    }
    let mut desktop = desktop();
    if desktop.is_none() {
        let claim = claim(host_profiles::root());
        if let Err(error) = refusal(&claim) {
            tracing::warn!("this app hosts nothing: {error:#}");
        }
        *desktop = Some(claim);
    }
}

/// Ok when this process may host: it owns the hosting state, or never
/// claimed it.
pub(super) fn require() -> Result<()> {
    desktop().as_ref().map_or(Ok(()), refusal)
}

/// Whether another app owned this app's hosting state when it started.
pub fn owned_elsewhere() -> bool {
    matches!(*desktop(), Some(Claim::Elsewhere(_)))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Two apps on one hosting state, each with its own handle on the lock
    /// file: the first owns it, the second is refused and names the owner,
    /// and once the first has gone (its lock released, as at exit) the next
    /// app to start owns the state with nothing to clean up.
    #[test]
    fn a_second_app_never_hosts_while_the_first_lives() {
        let state = tempfile::tempdir().expect("state");
        let dir = || Ok(state.path().join("hosting"));
        let first = claim(dir());
        refusal(&first).expect("the first app owns the hosting state");
        let second = claim(dir());
        let Claim::Elsewhere(held) = &second else { panic!("the first app still runs") };
        if cfg!(unix) {
            assert_eq!(held.pid, Some(std::process::id()), "the owner is named");
        }
        assert!(refusal(&second).is_err_and(|error| error.is::<HeldElsewhere>()));
        drop(first);
        refusal(&claim(dir())).expect("the next app owns it");
    }
}
