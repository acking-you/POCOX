//! The processes this app started, identified by process id **and** start
//! time, so a stale id the system reused (or a replacement that took over a
//! child's port) is never signalled; and [`Retained`], which keeps an owned
//! child whose exit was not seen until a later stop or quit sees it exit.

use std::{
    sync::{Mutex, MutexGuard},
    time::{Duration, Instant},
};

use pocox_codex::{ProcessIdentity, SpawnReport};
use pocox_core::process::{force_kill, process_start_time, send_sigterm};

/// How long [`OwnedChild::stop`] waits for the process to exit, before and
/// after forcing it.
pub(super) const EXIT_WAIT: Duration = Duration::from_secs(6);

/// One process by id and start time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Proc {
    pid: u32,
    started: u64,
}

impl Proc {
    /// Whether this exact process still runs. An exited child this app has
    /// not reaped (a zombie keeps its id and may still report a start time)
    /// no longer runs.
    fn running(self) -> bool {
        process_start_time(self.pid) == Some(self.started)
            && pocox_codex::child_exited_unreaped(self.pid) != Some(true)
    }

    /// A graceful signal, a bounded wait for the process itself to exit (a
    /// closed port is not an exit), then a forced stop only while it is
    /// still the same process, and a second bounded wait.
    fn stop(self, wait: Duration) -> bool {
        if !self.running() {
            return true;
        }
        send_sigterm(self.pid);
        if self.exited(wait) {
            return true;
        }
        if self.running() {
            force_kill(self.pid);
        }
        let exited = self.exited(wait);
        if !exited {
            tracing::warn!(pid = self.pid, "an owned codex did not exit after a forced stop");
        }
        exited
    }

    /// Whether it stopped running within `wait`.
    fn exited(self, wait: Duration) -> bool {
        let deadline = Instant::now() + wait;
        while self.running() {
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        true
    }
}

impl From<ProcessIdentity> for Proc {
    fn from(id: ProcessIdentity) -> Self {
        Self {
            pid: id.pid,
            started: id.started,
        }
    }
}

/// What one launch owns: its server (the listener attributed to the spawn,
/// or the spawned process itself when none was) and, when they differ, the
/// spawned shim in front of it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct OwnedChild {
    main: Proc,
    shim: Option<Proc>,
}

impl OwnedChild {
    /// What `report`'s launch started, as identified at the spawn
    /// ([`SpawnReport::spawned`] / [`SpawnReport::owned`]); `None` for an
    /// adopted server or a child gone before it could be identified. Never
    /// a process found later by its address.
    pub(super) fn of_report(report: &SpawnReport) -> Option<Self> {
        if report.reused {
            return None;
        }
        let spawned = report.spawned.map(Proc::from);
        let main = report.owned.map(Proc::from).or(spawned)?;
        Some(Self {
            main,
            shim: spawned.filter(|shim| *shim != main),
        })
    }

    /// The process `pid` as it runs now; `None` when it does not run.
    #[cfg(test)]
    pub(super) fn of(pid: u32) -> Option<Self> {
        process_start_time(pid).map(|started| Self::recorded(pid, started))
    }

    /// An identity as recorded (tests name one that must never match).
    #[cfg(test)]
    pub(super) fn recorded(pid: u32, started: u64) -> Self {
        Self {
            main: Proc {
                pid,
                started,
            },
            shim: None,
        }
    }

    /// Its server's process id.
    #[cfg(test)]
    pub(super) fn pid(self) -> u32 {
        self.main.pid
    }

    /// Whether any of its processes still runs.
    pub(super) fn running(self) -> bool {
        self.main.running() || self.shim.is_some_and(Proc::running)
    }

    /// Stop its server, then its shim, each only while it is still that
    /// exact process. `true` once neither runs.
    pub(super) fn stop(self, wait: Duration) -> bool {
        #[cfg(test)]
        if tests::stop_refused(self.main.pid) {
            return false;
        }
        let main = self.main.stop(wait);
        self.shim.is_none_or(|shim| shim.stop(wait)) && main
    }
}

/// Owned children whose exit has not been seen, by owner (a host or a
/// sign-in attempt). A child is put here before the record that owned it is
/// dropped — callers hold their own table lock while doing so, and this
/// lock is always taken inside theirs, never around it — so a quit always
/// finds it in one place or the other, and it leaves only once it exited.
pub(super) struct Retained(Mutex<Vec<(String, OwnedChild)>>);

impl Retained {
    /// An empty ledger.
    pub(super) const fn new() -> Self {
        Self(Mutex::new(Vec::new()))
    }

    fn held(&self) -> MutexGuard<'_, Vec<(String, OwnedChild)>> {
        self.0.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Keep `child` for `owner` until it is seen to exit.
    pub(super) fn hold(&self, owner: &str, child: OwnedChild) {
        let mut held = self.held();
        if !held.iter().any(|(_, c)| *c == child) {
            held.push((owner.to_string(), child));
        }
    }

    fn release(&self, child: OwnedChild) {
        self.held().retain(|(_, c)| *c != child);
    }

    /// Stop `child` for `owner`, keeping it here unless it exited. `true`
    /// once it no longer runs.
    pub(super) fn stop(&self, owner: &str, child: OwnedChild, wait: Duration) -> bool {
        self.hold(owner, child);
        let exited = child.stop(wait);
        if exited {
            self.release(child);
        }
        exited
    }

    /// Release every kept child seen to have exited, signalling nothing.
    pub(super) fn prune(&self) {
        self.held().retain(|(_, child)| child.running());
    }

    /// Stop every child kept for an owner `of` selects again; the owners
    /// whose child still runs.
    pub(super) fn settle(&self, of: impl Fn(&str) -> bool, wait: Duration) -> Vec<String> {
        let kept: Vec<(String, OwnedChild)> = self
            .held()
            .iter()
            .filter(|(owner, _)| of(owner))
            .cloned()
            .collect();
        for (_, child) in kept {
            if child.stop(wait) {
                self.release(child);
            }
        }
        self.owners(of)
    }

    /// The owners `of` selects with a child still kept.
    pub(super) fn owners(&self, of: impl Fn(&str) -> bool) -> Vec<String> {
        let mut owners: Vec<String> = self
            .held()
            .iter()
            .filter(|(owner, _)| of(owner))
            .map(|(owner, _)| owner.clone())
            .collect();
        owners.sort();
        owners.dedup();
        owners
    }
}

#[cfg(test)]
pub(super) mod tests {
    use super::*;

    /// Process ids whose stop a test makes fail, to control the outcome.
    static REFUSED: Mutex<Vec<u32>> = Mutex::new(Vec::new());

    /// Make every stop of `child` fail (`refused`) or work again.
    pub(in crate::engine) fn refuse_stops(child: OwnedChild, refused: bool) {
        let mut held = REFUSED.lock().unwrap_or_else(|p| p.into_inner());
        held.retain(|pid| *pid != child.main.pid);
        if refused {
            held.push(child.main.pid);
        }
    }

    pub(super) fn stop_refused(pid: u32) -> bool {
        REFUSED
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .contains(&pid)
    }

    /// A spawned fixture process, killed and reaped however its test ends
    /// (an assertion's unwind included). Derefs to the [`std::process::Child`]
    /// for the test's own signals and waits; a process the test already
    /// reaped is not signalled again.
    #[cfg(unix)]
    pub(in crate::engine) struct Fixture(std::process::Child);

    #[cfg(unix)]
    impl Fixture {
        /// Spawn `command` and wait (up to 5 s) until it runs.
        pub(in crate::engine) fn start(command: &mut std::process::Command) -> (Self, OwnedChild) {
            let fixture = Self(command.spawn().expect("spawn the fixture"));
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                if let Some(child) = OwnedChild::of(fixture.id()) {
                    return (fixture, child);
                }
                assert!(Instant::now() < deadline, "the fixture child started");
                std::thread::sleep(Duration::from_millis(20));
            }
        }
    }

    #[cfg(unix)]
    impl std::ops::Deref for Fixture {
        type Target = std::process::Child;

        fn deref(&self) -> &Self::Target {
            &self.0
        }
    }

    #[cfg(unix)]
    impl std::ops::DerefMut for Fixture {
        fn deref_mut(&mut self) -> &mut Self::Target {
            &mut self.0
        }
    }

    #[cfg(unix)]
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    /// A fixture process, once it runs.
    #[cfg(unix)]
    pub(in crate::engine) fn sleeper() -> (Fixture, OwnedChild) {
        Fixture::start(std::process::Command::new("/bin/sh").args(["-c", "exec sleep 60"]))
    }

    #[test]
    fn a_reused_process_id_is_never_signalled() {
        let me = OwnedChild::of(std::process::id()).expect("this process runs");
        assert!(me.running());
        let other = OwnedChild::recorded(me.main.pid, me.main.started.wrapping_add(1));
        assert!(!other.running(), "another start time is another process");
        // Returns at once without signalling: this test process lives on.
        assert!(other.stop(EXIT_WAIT));
    }

    /// A child that ignores SIGTERM is forced, and the stop returns only
    /// once it exited (it stays unreaped here, which still counts).
    #[cfg(unix)]
    #[test]
    fn a_child_ignoring_the_graceful_signal_is_forced_and_waited_for() {
        let (mut process, child) = Fixture::start(
            std::process::Command::new("/bin/sh").args(["-c", "trap '' TERM; exec sleep 60"]),
        );
        // Let the shell install its trap and exec.
        std::thread::sleep(Duration::from_millis(300));
        assert!(child.running());
        assert!(child.stop(EXIT_WAIT), "it exited");
        assert!(!child.running(), "the stop returned after the process exited");
        let status = process.wait().expect("reap");
        assert!(!status.success(), "it was killed, not finished");
    }

    /// The spawned shim and the server it started are both owned; an
    /// adopted server is not owned at all.
    #[test]
    fn a_launch_owns_what_it_spawned_and_its_attributed_server_only() {
        use pocox_core::state::CodexProcessInfo;
        let me = ProcessIdentity::of(std::process::id()).expect("runs");
        let server = ProcessIdentity {
            pid: me.pid,
            started: me.started.wrapping_add(1),
        };
        let report = |reused, spawned, owned: Option<ProcessIdentity>| SpawnReport {
            info: CodexProcessInfo {
                pid: me.pid,
                listen: "ws://127.0.0.1:9".into(),
                log_file: "unused.log".into(),
                started_at: String::new(),
            },
            reused,
            log_offset: 0,
            listener_confirmed: owned.is_some(),
            spawned,
            owned,
        };
        let both = OwnedChild::of_report(&report(false, Some(me), Some(server))).expect("owned");
        assert_eq!(both.main, Proc::from(server));
        assert_eq!(both.shim, Some(Proc::from(me)));
        let direct = OwnedChild::of_report(&report(false, Some(me), Some(me))).expect("owned");
        assert_eq!(direct.shim, None, "no shim when the spawned process serves");
        let unattributed = OwnedChild::of_report(&report(false, Some(me), None)).expect("owned");
        assert_eq!(unattributed.main, Proc::from(me), "only the spawned process");
        assert_eq!(OwnedChild::of_report(&report(true, None, None)), None);
        assert_eq!(OwnedChild::of_report(&report(false, None, None)), None);
    }

    /// A child whose stop fails stays kept, however often it is retried,
    /// and leaves only once it exited.
    #[cfg(unix)]
    #[test]
    fn a_child_is_kept_until_its_exit_is_seen() {
        let retained = Retained::new();
        let (mut process, child) = sleeper();
        refuse_stops(child, true);
        assert!(!retained.stop("owner-a", child, Duration::ZERO));
        assert_eq!(retained.settle(|_| true, Duration::ZERO), ["owner-a"]);
        assert_eq!(retained.settle(|o| o == "owner-a", Duration::ZERO), ["owner-a"]);
        assert!(retained
            .settle(|o| o == "owner-b", Duration::ZERO)
            .is_empty());
        assert!(child.running(), "a refused stop signalled nothing");
        refuse_stops(child, false);
        assert!(retained.settle(|_| true, EXIT_WAIT).is_empty());
        assert!(!child.running());
        let _ = process.wait();
    }
}
