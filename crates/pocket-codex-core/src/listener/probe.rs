//! A bounded run of a listing tool (`lsof`, `netstat`): its time and output
//! are capped, nothing waits on it without a bound, and stopping it stops
//! only what it started.

use std::{
    io::Read,
    process::{Child, Command, ExitStatus, Stdio},
    sync::mpsc::{self, Receiver, RecvTimeoutError, Sender},
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

/// How a probe exited and what it printed.
#[derive(Debug, Default)]
pub(super) struct Probed {
    /// Its exit code; `None` when a signal ended it.
    pub(super) code: Option<i32>,
    /// Its standard output.
    pub(super) stdout: Vec<u8>,
    /// Its standard error.
    pub(super) stderr: Vec<u8>,
}

/// What a run's cleanup achieved.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Cleanup {
    /// The probe was reaped (a probe that does not die is left unreaped, so
    /// its id is never reused while anything here could still signal it).
    pub(super) reaped: bool,
    /// Both reader threads finished and were joined. One stays blocked only
    /// on a pipe held by a process outside the probe's group, which is never
    /// signalled.
    pub(super) readers_joined: bool,
}

/// A cleanup that left nothing behind.
const CLEAN: Cleanup = Cleanup {
    reaped: true,
    readers_joined: true,
};

/// How often a running probe is looked at.
const POLL: Duration = Duration::from_millis(10);

/// How long a probe's output may still arrive once it exited, and how long
/// the cleanup after every run may take to reap the probe and finish its
/// readers.
const SETTLE: Duration = Duration::from_millis(500);

/// One output stream (0 stdout, 1 stderr): its bytes, or `None` when it
/// exceeded the cap or could not be read.
type Stream = (usize, Option<Vec<u8>>);

/// Each reader's report once it arrived (see [`Stream`]).
type Reports = [Option<Option<Vec<u8>>>; 2];

/// Run `command` until `deadline`, keeping at most `cap` bytes of each output
/// stream; standard input is closed. `None` when it cannot be started, does
/// not finish by the deadline, prints more than the cap, or its output cannot
/// be read. Returns at most [`SETTLE`] after the deadline.
pub(super) fn run(command: &mut Command, deadline: Instant, cap: usize) -> Option<Probed> {
    let (probed, cleanup) = attempt(command, deadline, cap);
    if cleanup != CLEAN {
        tracing::debug!(?cleanup, "a listener probe was not fully cleaned up");
    }
    probed
}

/// [`run`], also reporting its cleanup. On unix the probe leads its own
/// process group; every run ends with [`finish`], so the group is stopped on
/// every path, never after the leader was reaped.
pub(super) fn attempt(
    command: &mut Command,
    deadline: Instant,
    cap: usize,
) -> (Option<Probed>, Cleanup) {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let Ok(mut child) = command.spawn() else {
        return (None, CLEAN);
    };
    let (tx, rx) = mpsc::channel();
    let mut readers = [None, None];
    if let (Some(out), Some(err)) = (child.stdout.take(), child.stderr.take()) {
        readers[0] = read_capped(out, 0, cap, &tx);
        if readers[0].is_some() {
            readers[1] = read_capped(err, 1, cap, &tx);
        }
    }
    drop(tx);
    let mut reports: Reports = [None, None];
    let complete =
        readers.iter().all(Option::is_some) && collect(&mut child, &rx, &mut reports, deadline);
    let (status, cleanup) = finish(&mut child, &rx, readers, &mut reports);
    let probed = match (complete, status) {
        (true, Some(status)) => {
            let [stdout, stderr] = reports.map(|report| report.flatten().unwrap_or_default());
            Some(Probed {
                code: status.code(),
                stdout,
                stderr,
            })
        },
        _ => None,
    };
    (probed, cleanup)
}

/// Receive both streams until the probe exited: `true` once both arrived
/// whole and it no longer runs, `false` on an overflow or read error, past
/// `deadline`, or when its output is still held open [`SETTLE`] after it
/// exited. The leader is never reaped here.
fn collect(
    child: &mut Child,
    rx: &Receiver<Stream>,
    reports: &mut Reports,
    deadline: Instant,
) -> bool {
    let mut exited: Option<Instant> = None;
    loop {
        let whole = reports.iter().all(|report| matches!(report, Some(Some(_))));
        if whole && exited.is_some() {
            return true;
        }
        let limit = exited.map_or(deadline, |at| deadline.min(at + SETTLE));
        let now = Instant::now();
        if now >= limit {
            return false;
        }
        match rx.recv_timeout(POLL.min(limit - now)) {
            Ok((index, Some(bytes))) => reports[index] = Some(Some(bytes)),
            Ok((index, None)) => {
                reports[index] = Some(None);
                return false;
            },
            Err(RecvTimeoutError::Timeout) => {},
            Err(RecvTimeoutError::Disconnected) if whole => thread::sleep(POLL),
            Err(RecvTimeoutError::Disconnected) => return false,
        }
        if exited.is_none() && !leader_runs(child) {
            exited = Some(Instant::now());
        }
    }
}

/// Whether the probe still runs, without reaping it on unix: a zombie leader
/// keeps its process and group ids reserved until [`finish`] signalled them.
#[cfg(unix)]
fn leader_runs(child: &mut Child) -> bool {
    crate::process::pid_running(child.id())
}

/// Whether the probe still runs; the handle held here keeps its id reserved.
#[cfg(not(unix))]
fn leader_runs(child: &mut Child) -> bool {
    matches!(child.try_wait(), Ok(None))
}

/// Read `pipe` to its end on a thread of its own and send it as stream
/// `index`: `None` beyond `cap` bytes (reading stops there) or on a read
/// error. `None` when no thread could be started.
fn read_capped<R: Read + Send + 'static>(
    pipe: R,
    index: usize,
    cap: usize,
    tx: &Sender<Stream>,
) -> Option<JoinHandle<()>> {
    let tx = tx.clone();
    let limit = u64::try_from(cap).unwrap_or(u64::MAX).saturating_add(1);
    thread::Builder::new()
        .name("pcx-listener-probe".into())
        .spawn(move || {
            let mut bytes = Vec::new();
            let read = pipe.take(limit).read_to_end(&mut bytes);
            let kept = (read.is_ok() && bytes.len() <= cap).then_some(bytes);
            // reason: the run may have stopped receiving; the report is moot.
            let _ = tx.send((index, kept));
        })
        .ok()
}

/// Stop the probe and what it started, then reap it and finish its readers,
/// all within one [`SETTLE`]. On unix its process group is killed first,
/// while the leader is still unreaped, so the group id names no one else;
/// nothing is signalled after the reap. Its status when reaped.
fn finish(
    child: &mut Child,
    rx: &Receiver<Stream>,
    readers: [Option<JoinHandle<()>>; 2],
    reports: &mut Reports,
) -> (Option<ExitStatus>, Cleanup) {
    #[cfg(unix)]
    {
        use nix::{sys::signal, unistd::Pid};
        if let Ok(group) = i32::try_from(child.id()) {
            // reason: an exited group has no members left; the leader is reaped below.
            let _ = signal::killpg(Pid::from_raw(group), signal::Signal::SIGKILL);
        }
    }
    // reason: a leader that exited already is only reaped below.
    let _ = child.kill();
    let settled = Instant::now() + SETTLE;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if Instant::now() < settled => thread::sleep(POLL),
            _ => break None,
        }
    };
    // A reader that reported has finished reading; wait for the others'
    // reports (their pipes close once the group is gone), then join.
    while reports
        .iter()
        .zip(&readers)
        .any(|(report, reader)| report.is_none() && reader.is_some())
    {
        match rx.recv_timeout(settled.saturating_duration_since(Instant::now())) {
            Ok((index, report)) => reports[index] = Some(report),
            Err(_) => break,
        }
    }
    let mut readers_joined = true;
    for (reader, report) in readers.into_iter().zip(reports.iter()) {
        match reader {
            Some(reader) if report.is_some() => readers_joined &= reader.join().is_ok(),
            Some(_) => readers_joined = false,
            None => {},
        }
    }
    let cleanup = Cleanup {
        reaped: status.is_some(),
        readers_joined,
    };
    (status, cleanup)
}

#[cfg(all(test, unix))]
mod tests {
    use std::path::PathBuf;

    use super::*;

    fn sh(script: &str) -> Command {
        let mut sh = Command::new("/bin/sh");
        sh.args(["-c", script]);
        sh
    }

    fn roomy() -> Instant {
        Instant::now() + Duration::from_secs(10)
    }

    /// A fresh file a script's `$1` writes a helper's pid to.
    fn pid_file() -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("after the epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("pcx-probe-{}-{nanos}", std::process::id()))
    }

    /// `script` run with `$1` naming a fresh pid file: its outcome, cleanup,
    /// time taken and the helper pid it recorded.
    fn with_helper(
        script: &str,
        deadline: Duration,
        cap: usize,
    ) -> (Option<Probed>, Cleanup, Duration, u32) {
        let file = pid_file();
        let mut command = sh(script);
        command.arg("pcx-probe").arg(&file);
        let started = Instant::now();
        let (probed, cleanup) = attempt(&mut command, started + deadline, cap);
        let took = started.elapsed();
        let helper = std::fs::read_to_string(&file)
            .expect("the helper was started")
            .trim()
            .parse()
            .expect("its pid");
        let _ = std::fs::remove_file(&file);
        (probed, cleanup, took, helper)
    }

    /// `pid` stops running soon (a zombie counts as stopped).
    fn assert_gone(pid: u32) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while crate::process::pid_running(pid) {
            assert!(Instant::now() < deadline, "the probe's helper {pid} was stopped");
            thread::sleep(Duration::from_millis(20));
        }
    }

    /// A process outside every probe's group: it survives their cleanups.
    struct Bystander(std::process::Child);

    impl Bystander {
        fn start() -> Self {
            Self(Command::new("sleep").arg("30").spawn().expect("sleep"))
        }

        fn assert_running(&mut self) {
            assert!(matches!(self.0.try_wait(), Ok(None)), "an unrelated process survives");
        }
    }

    impl Drop for Bystander {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    #[test]
    fn a_probe_reports_its_exit_and_both_streams() {
        let (ran, cleanup) = attempt(&mut sh("printf out; printf err >&2; exit 3"), roomy(), 64);
        let ran = ran.expect("ran");
        assert_eq!(cleanup, CLEAN);
        assert_eq!(ran.code, Some(3));
        assert_eq!(ran.stdout, b"out");
        assert_eq!(ran.stderr, b"err");
        let quiet = run(&mut sh("exit 1"), roomy(), 64).expect("ran");
        assert_eq!((quiet.code, quiet.stdout.len(), quiet.stderr.len()), (Some(1), 0, 0));
        assert!(run(&mut Command::new("/nonexistent/pcx-probe"), roomy(), 64).is_none());
    }

    #[test]
    fn output_beyond_the_cap_is_unreadable_and_stops_the_probe() {
        let ran = run(&mut sh("printf 0123456789"), roomy(), 10).expect("exactly the cap");
        assert_eq!(ran.stdout, b"0123456789");
        let started = Instant::now();
        assert!(run(&mut sh("printf 0123456789"), roomy(), 9).is_none());
        // An endless writer is stopped as soon as it passed the cap.
        for endless in ["while :; do printf 0123456789; done", "while :; do printf e >&2; done"] {
            let (ran, cleanup) = attempt(&mut sh(endless), roomy(), 1024);
            assert!(ran.is_none());
            assert_eq!(cleanup, CLEAN, "{endless}");
        }
        assert!(started.elapsed() < Duration::from_secs(8), "{:?}", started.elapsed());
    }

    /// An overflow stops what the probe forked as well, and finishes both
    /// readers; a process outside its group is untouched.
    #[test]
    fn an_overflowing_probe_is_stopped_with_its_helper() {
        let mut bystander = Bystander::start();
        let (ran, cleanup, took, helper) = with_helper(
            "sleep 30 & echo $! > \"$1\"; while :; do printf 0123456789; done",
            Duration::from_secs(10),
            1024,
        );
        assert!(ran.is_none());
        assert_eq!(cleanup, CLEAN);
        assert!(took < Duration::from_secs(4), "{took:?}");
        assert_gone(helper);
        bystander.assert_running();
    }

    /// A probe past its deadline is stopped and both readers finish within
    /// the settle bound, even if it was not scheduled before the deadline.
    /// The other cleanup tests cover forked helpers without a startup race.
    #[test]
    fn a_probe_that_outlives_its_deadline_is_stopped() {
        let mut bystander = Bystander::start();
        let started = Instant::now();
        let (ran, cleanup) =
            attempt(&mut sh("exec sleep 30"), started + Duration::from_secs(1), 64);
        let took = started.elapsed();
        assert!(ran.is_none());
        assert_eq!(cleanup, CLEAN);
        assert!(took < Duration::from_secs(1) + 2 * SETTLE, "{took:?}");
        bystander.assert_running();
    }

    /// A probe that exited while a helper it forked keeps its pipes open
    /// cannot be read. The helper is stopped through the group the unreaped
    /// leader still reserves, both readers finish, and an unrelated process
    /// survives; the wait is bounded by the settle time, not the deadline.
    #[test]
    fn an_exited_probe_whose_pipes_stay_open_is_cleaned_up_within_a_bound() {
        let mut bystander = Bystander::start();
        let (ran, cleanup, took, helper) =
            with_helper("sleep 30 & echo $! > \"$1\"; exit 0", Duration::from_secs(10), 64);
        assert!(ran.is_none());
        assert_eq!(cleanup, CLEAN);
        assert!(took < Duration::from_secs(4), "{took:?}");
        assert_gone(helper);
        bystander.assert_running();
    }

    /// A readable run still stops what its group left behind.
    #[test]
    fn a_readable_run_stops_a_helper_that_closed_its_pipes() {
        let (ran, cleanup, _, helper) = with_helper(
            "sleep 30 >&- 2>&- & echo $! > \"$1\"; printf ok",
            Duration::from_secs(10),
            64,
        );
        let ran = ran.expect("readable");
        assert_eq!((ran.code, ran.stdout.as_slice()), (Some(0), b"ok".as_slice()));
        assert_eq!(cleanup, CLEAN);
        assert_gone(helper);
    }
}
