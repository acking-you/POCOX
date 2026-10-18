//! One lifecycle lease per canonical instance name (see
//! [`super::host_names`]).
//!
//! Every start, stop, restart and apply of a local host holds its name's
//! lease from its first check to its last effect, so they never interleave:
//! an apply cannot race a stop or a start, and a start cannot slip between
//! an apply's stop and its restart. Internal steps take the held [`Lease`]
//! as proof instead of acquiring it again. A caller waits a bounded time
//! for a busy name and is then told what it is busy with.
//!
//! Quitting closes admission ([`close_admission`]): no new operation starts,
//! the quit waits for those in progress ([`drain`]) and then stops each host
//! under its own lease ([`acquire_for_quit`]), never around a holder.
//!
//! Only the process that owns the hosting state ([`super::host_owner`]) is
//! granted a lease for anything but a stop, so a second app on the same
//! state starts, restarts and applies nothing.
//!
//! This sits above [`super::hosting`], whose claims still keep two
//! *providers* off one name; the lease orders operations on one instance.

use std::{
    collections::HashMap,
    sync::{Condvar, Mutex, MutexGuard},
    time::{Duration, Instant},
};

use anyhow::{bail, Result};
use once_cell::sync::Lazy;

use super::host_names;

/// How long an operation waits for another one on the same instance. An
/// apply (a stop, a start and possibly a restore) fits within it.
pub(super) const LEASE_WAIT: Duration = Duration::from_secs(120);

/// What holds an instance.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    /// Starting it.
    Start,
    /// Stopping it.
    Stop,
    /// Restarting its agent in place.
    Restart,
    /// Applying a saved configuration (stop, start, maybe restore).
    Apply,
}

impl Op {
    /// Stable lower-case label (for status and errors).
    pub fn label(self) -> &'static str {
        match self {
            Self::Start => "starting",
            Self::Stop => "stopping",
            Self::Restart => "restarting",
            Self::Apply => "applying",
        }
    }

    fn phrase(self) -> &'static str {
        match self {
            Self::Apply => "applying its configuration",
            other => other.label(),
        }
    }
}

#[derive(Default)]
struct State {
    held: HashMap<String, Op>,
    /// The app is quitting: no new lease is granted except to the quit
    /// itself ([`acquire_for_quit`]).
    closing: bool,
}

struct Table {
    state: Mutex<State>,
    released: Condvar,
}

static TABLE: Lazy<Table> = Lazy::new(Table::new);

impl Table {
    fn new() -> Self {
        Self {
            state: Mutex::new(State::default()),
            released: Condvar::new(),
        }
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn acquire(&'static self, name: &str, op: Op, wait: Duration, quit: bool) -> Result<Lease> {
        let name = host_names::canonical(name)?;
        if op != Op::Stop {
            super::host_owner::require()?;
        }
        let deadline = Instant::now() + wait;
        let mut state = self.state();
        loop {
            if state.closing && !quit {
                bail!("the app is quitting; `{name}` is not {}", op.label());
            }
            let Some(busy) = state.held.get(&name).copied() else {
                state.held.insert(name.clone(), op);
                return Ok(Lease {
                    table: self,
                    name,
                    op,
                });
            };
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                bail!("`{name}` is busy {}; try again when it finishes", busy.phrase());
            }
            state = self
                .released
                .wait_timeout(state, left)
                .unwrap_or_else(|p| p.into_inner())
                .0;
        }
    }

    fn close(&self) {
        self.state().closing = true;
        // Waiters re-check and give up.
        self.released.notify_all();
    }

    fn drain(&self, wait: Duration) -> bool {
        let deadline = Instant::now() + wait;
        let mut state = self.state();
        while !state.held.is_empty() {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return false;
            }
            state = self
                .released
                .wait_timeout(state, left)
                .unwrap_or_else(|p| p.into_inner())
                .0;
        }
        true
    }
}

/// The exclusive lease of one instance; released on drop (a panic
/// included).
#[must_use = "dropping a lease releases the instance"]
pub struct Lease {
    table: &'static Table,
    name: String,
    op: Op,
}

impl std::fmt::Debug for Lease {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Lease")
            .field("name", &self.name)
            .field("op", &self.op)
            .finish()
    }
}

impl Lease {
    /// The canonical instance name.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// What it was taken for.
    #[cfg(test)]
    pub fn op(&self) -> Op {
        self.op
    }
}

impl Drop for Lease {
    fn drop(&mut self) {
        self.table.state().held.remove(&self.name);
        self.table.released.notify_all();
    }
}

/// Take the lease of `name` for `op`, waiting up to [`LEASE_WAIT`].
pub(super) fn acquire(name: &str, op: Op) -> Result<Lease> {
    acquire_within(name, op, LEASE_WAIT)
}

/// Acquire then validate the caller's still-current authority before any
/// effect.
pub(super) fn acquire_checked(
    name: &str,
    op: Op,
    check: impl FnOnce() -> Result<()>,
) -> Result<Lease> {
    let lease = acquire(name, op)?;
    check()?;
    Ok(lease)
}

/// [`acquire`] with its own bound. Refused once the app is quitting.
pub(super) fn acquire_within(name: &str, op: Op, wait: Duration) -> Result<Lease> {
    TABLE.acquire(name, op, wait, false)
}

/// Stop `name` for the quit itself, after [`close_admission`]: waits like
/// [`acquire_within`], and is never refused for the quit.
pub(super) fn acquire_for_quit(name: &str, wait: Duration) -> Result<Lease> {
    TABLE.acquire(name, Op::Stop, wait, true)
}

/// Grant no new lease (other than [`acquire_for_quit`]) from now on: the
/// app is quitting. Operations already holding one finish.
pub(super) fn close_admission() {
    TABLE.close();
}

/// Wait up to `wait` until no lease is held; `false` when some still is.
pub(super) fn drain(wait: Duration) -> bool {
    TABLE.drain(wait)
}

/// What holds `name` now, if anything.
pub(super) fn holder(name: &str) -> Option<Op> {
    let name = host_names::canonical(name).ok()?;
    TABLE.state().held.get(&name).copied()
}

#[cfg(test)]
mod tests {
    use std::sync::{mpsc, Arc, Barrier};

    use super::*;

    #[test]
    fn a_revoked_waiter_cannot_act_when_the_lease_is_released() {
        use std::sync::atomic::{AtomicBool, Ordering};
        let first = acquire("management-revoked-waiter", Op::Stop).expect("hold");
        let permitted = Arc::new(AtomicBool::new(true));
        let (ready, begun) = mpsc::channel();
        let worker = std::thread::spawn({
            let permitted = permitted.clone();
            move || {
                ready.send(()).expect("signal");
                acquire_checked("management-revoked-waiter", Op::Start, || {
                    if permitted.load(Ordering::SeqCst) {
                        Ok(())
                    } else {
                        anyhow::bail!("revoked")
                    }
                })
                .map(drop)
            }
        });
        begun.recv_timeout(Duration::from_secs(5)).expect("worker");
        permitted.store(false, Ordering::SeqCst);
        drop(first);
        assert_eq!(
            worker
                .join()
                .expect("worker")
                .expect_err("refused")
                .to_string(),
            "revoked"
        );
        assert!(holder("management-revoked-waiter").is_none());
    }

    #[test]
    fn a_lease_is_exclusive_per_canonical_name() {
        let first = acquire("Lease Test One", Op::Apply).expect("free");
        assert_eq!(first.name(), "lease-test-one");
        assert_eq!(holder("lease-test-one"), Some(Op::Apply));
        let busy = acquire_within("lease-test-one", Op::Start, Duration::from_millis(20))
            .expect_err("held");
        assert!(busy.to_string().contains("applying"), "{busy}");
        let other = acquire_within("lease-test-two", Op::Start, Duration::ZERO).expect("other");
        drop((first, other));
        assert_eq!(holder("lease-test-one"), None);
    }

    #[test]
    fn a_waiter_gets_the_lease_when_it_is_released() {
        let first = acquire("lease-test-wait", Op::Stop).expect("free");
        let started = Arc::new(Barrier::new(2));
        let (done, finished) = mpsc::channel();
        let waiter = std::thread::spawn({
            let started = started.clone();
            move || {
                started.wait();
                let lease = acquire_within("lease-test-wait", Op::Start, Duration::from_secs(10));
                done.send(lease.map(|l| l.op())).expect("send");
            }
        });
        started.wait();
        assert!(finished.recv_timeout(Duration::from_millis(100)).is_err(), "still waiting");
        drop(first);
        let op = finished
            .recv_timeout(Duration::from_secs(10))
            .expect("woken");
        assert_eq!(op.expect("acquired"), Op::Start);
        waiter.join().expect("waiter");
    }

    #[test]
    fn a_panic_releases_the_lease() {
        let crashed = std::thread::spawn(|| {
            let _lease = acquire("lease-test-panic", Op::Apply).expect("free");
            panic!("crash while applying");
        })
        .join();
        assert!(crashed.is_err());
        assert_eq!(holder("lease-test-panic"), None);
        drop(acquire_within("lease-test-panic", Op::Start, Duration::ZERO).expect("free"));
    }

    #[test]
    fn a_blank_name_has_no_lease() {
        assert!(acquire_within(" ", Op::Start, Duration::ZERO).is_err());
    }

    /// A table of its own, so closing it never affects other tests.
    fn table() -> &'static Table {
        Box::leak(Box::new(Table::new()))
    }

    #[test]
    fn a_closed_table_admits_only_the_quit_and_drains_its_holders() {
        let table = table();
        let running = table
            .acquire("quit-a", Op::Start, Duration::ZERO, false)
            .expect("free");
        // A waiter for the same name is told the app is quitting.
        let (done, waited) = mpsc::channel();
        let waiter = std::thread::spawn(move || {
            let lease = table.acquire("quit-a", Op::Apply, Duration::from_secs(10), false);
            done.send(lease.map(|l| l.op())).expect("send");
        });
        std::thread::sleep(Duration::from_millis(50));
        table.close();
        let refused = waited.recv_timeout(Duration::from_secs(10)).expect("woken");
        assert!(refused
            .expect_err("refused")
            .to_string()
            .contains("quitting"));
        waiter.join().expect("waiter");
        assert!(table
            .acquire("quit-b", Op::Start, Duration::ZERO, false)
            .is_err());
        // Drain waits for the start in progress, never past its bound.
        assert!(!table.drain(Duration::from_millis(30)), "still held");
        let release = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            drop(running);
        });
        assert!(table.drain(Duration::from_secs(10)), "drained once released");
        release.join().expect("release");
        // The quit itself still gets each lease.
        let quit = table
            .acquire("quit-a", Op::Stop, Duration::ZERO, true)
            .expect("quit");
        assert_eq!(quit.op(), Op::Stop);
    }
}
