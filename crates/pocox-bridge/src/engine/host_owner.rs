//! One process at a time hosts from a hosting state directory.
//!
//! The owner holds an exclusive lock on `<dir>/owner.lock` until its hosting
//! cleanup succeeds. Desktop quit releases it explicitly: Rust statics are not
//! dropped at exit, and Windows need not release a terminated process's file
//! locks immediately. A failed cleanup keeps the lock for a retry. After a
//! crash the operating system releases it; the lock, never a recorded process
//! id, decides ownership. The id in the file only names it in messages.
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

use std::cell::RefCell;
use std::fs::{File, TryLockError};
use std::io::Write as _;
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};
use parking_lot::{ReentrantMutex, ReentrantMutexGuard};

use super::host_profiles::{self, files};

/// The lock file's name in the directory it guards.
pub(super) const LOCK_FILE: &str = "owner.lock";

/// A held owner lock; dropping it releases the directory.
pub(super) struct OwnerLock(Option<File>);

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
        Ok(Self(Some(file)))
    }

    /// Unlock before closing the file, retaining it when unlocking fails so
    /// a failed desktop quit can retry without losing its ownership record.
    fn release(&mut self) -> Result<()> {
        if let Some(file) = &self.0 {
            file.unlock().context("releasing the hosting owner lock")?;
        }
        self.0 = None;
        Ok(())
    }
}

impl Drop for OwnerLock {
    fn drop(&mut self) {
        // At once rather than on close, which Windows may delay.
        let _ = self.release();
    }
}

/// The holder's id. Windows refuses to read a locked file, so it is unknown
/// there.
fn read_pid(path: &Path) -> Option<u32> {
    std::fs::read_to_string(path).ok()?.trim().parse().ok()
}

/// The desktop app's claim on its hosting state, made when it starts.
enum Claim {
    /// Held until hosting cleanup succeeds.
    Owned { lock: OwnerLock },
    /// Cleanup succeeded; this process must never host or claim again.
    Released,
    /// Another live app owned it.
    Elsewhere(HeldElsewhere),
    /// It could not be locked.
    Failed(String),
}

fn claim(dir: Result<PathBuf>) -> Claim {
    match dir.and_then(|dir| OwnerLock::try_acquire(&dir)) {
        Ok(lock) => Claim::Owned {
            lock,
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
        Claim::Released => Err(anyhow!("the app has finished quitting; hosting is closed")),
        Claim::Elsewhere(held) => Err(held.clone().into()),
        Claim::Failed(reason) => Err(anyhow!("the hosting state could not be locked: {reason}")),
    }
}

/// `None` until [`claim_desktop`]: tests, phones and the CLI supervisor
/// never claim the desktop state.
static DESKTOP: ReentrantMutex<RefCell<Option<Claim>>> = ReentrantMutex::new(RefCell::new(None));

fn desktop() -> ReentrantMutexGuard<'static, RefCell<Option<Claim>>> {
    DESKTOP.lock()
}

/// Keeps desktop ownership through a hosting-state write. Profile transactions
/// call the atomic-file writer while already guarded, so this gate is
/// reentrant. CLI owners keep their separate process lock until their
/// supervisor exits.
#[must_use = "keep the guard until the hosting-state write finishes"]
pub(in crate::engine) struct WriteGuard {
    _claim: Option<ReentrantMutexGuard<'static, RefCell<Option<Claim>>>>,
}

/// Refuse writes by another or retired desktop, and prevent quit from releasing
/// its ownership until this write finishes. The guard must stay on this thread.
pub(in crate::engine) fn write_guard() -> Result<WriteGuard> {
    let desktop = desktop();
    let claimed = {
        let claim = desktop.borrow();
        claim.as_ref().map_or(Ok(()), refusal)?;
        claim.is_some()
    };
    Ok(WriteGuard {
        _claim: claimed.then_some(desktop),
    })
}

/// Own this computer's hosting state until its successful quit cleanup,
/// or note that another app does. Never fails the app's start; a second call
/// changes nothing.
pub fn claim_desktop() {
    if cfg!(any(target_os = "ios", target_os = "android")) {
        return;
    }
    let gate = desktop();
    let mut desktop = gate.borrow_mut();
    if desktop.is_none() {
        let claim = claim(host_profiles::root());
        if let Err(error) = refusal(&claim) {
            tracing::warn!("this app hosts nothing: {error:#}");
        }
        *desktop = Some(claim);
    }
}

/// Relinquish desktop hosting after quit fenced and drained its operations
/// and stopped every owned service. A failed quit must not call this. Keep a
/// terminal claim instead of `None`, which permits CLI and mobile operations.
pub(super) fn release_desktop() -> Result<()> {
    let gate = desktop();
    let mut desktop = gate.borrow_mut();
    if let Some(Claim::Owned {
        lock,
    }) = desktop.as_mut()
    {
        lock.release()?;
        *desktop = Some(Claim::Released);
    }
    Ok(())
}

/// Ok when this process may host: it owns the hosting state, or never
/// claimed it.
pub(super) fn require() -> Result<()> {
    desktop().borrow().as_ref().map_or(Ok(()), refusal)
}

/// Whether another app owned this app's hosting state when it started.
pub fn owned_elsewhere() -> bool {
    matches!(*desktop().borrow(), Some(Claim::Elsewhere(_)))
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
