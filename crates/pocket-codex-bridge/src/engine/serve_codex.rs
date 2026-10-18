//! The external codex process of a native host: its per-host log file and
//! tailer (with the size cap), the health watchdog and restarts, and the
//! startup-failure message.

use super::*;

/// How often the watchdog probes codex's `/readyz`.
const HEALTH_INTERVAL: Duration = Duration::from_secs(15);
/// Per-probe timeout — a wedged app-server hangs rather than refusing.
const HEALTH_TIMEOUT: Duration = Duration::from_secs(4);
/// Consecutive failed probes before codex is treated as wedged.
const HEALTH_FAILURES: u32 = 3;
/// Pause after a restart before probing resumes (codex is still booting).
const HEALTH_RESTART_GRACE: Duration = Duration::from_secs(12);

/// Size at which a running host's log file is truncated by its tailer.
///
/// Deliberately a SIZE bound and not a time window. "Keep the last six hours"
/// sounds like the right rule and isn't: the burst that prompted this peaked at
/// 72 MB/min, which is 25 GB over six hours — a time rule bounds nothing on a
/// disk. 8 MB is far more than the in-app viewer can show (its ring holds 2000
/// lines) and comfortably more than a normal session writes, while staying
/// negligible on any disk.
pub(super) const MAX_HOST_LOG_BYTES: u64 = 8 * 1024 * 1024;

/// Whether a host log of `len` bytes has outgrown [`MAX_HOST_LOG_BYTES`].
/// Trivial, but split out so the threshold is asserted somewhere rather than
/// living only inside an async poll loop no unit test can reach.
pub(super) fn over_log_cap(len: u64) -> bool {
    len > MAX_HOST_LOG_BYTES
}

/// Truncate a live host's log to zero, returning whether it worked.
///
/// `set_len(0)` and not `remove_file`: the child holds this file open, so
/// unlinking would leave it appending to a deleted inode and the blocks would
/// stay allocated until the host stopped — the opposite of what a disk-pressure
/// guard should do. Truncating frees them now, and the child's next append
/// lands at offset 0, which the caller's `len < pos` resync already handles.
pub(super) async fn truncate_host_log(log_file: &std::path::Path) -> bool {
    match tokio::fs::OpenOptions::new()
        .write(true)
        .open(log_file)
        .await
    {
        Ok(f) => f.set_len(0).await.is_ok(),
        Err(cause) => {
            tracing::debug!(?log_file, %cause, "could not truncate oversized host log");
            false
        },
    }
}

/// This host's own codex log file (each external host gets its own, so one
/// tailer never picks up another host's — or an earlier run's — interleaved
/// output from the shared default file).
pub(super) fn per_host_log_file(name: &str) -> Result<std::path::PathBuf> {
    let safe: String = name
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .collect();
    Ok(runtime::support_dir()?
        .join("codex-logs")
        .join(format!("codex-{safe}.log")))
}

/// The longest partial line a tailer keeps; a longer line is withheld whole
/// (never emitted in pieces, which could split a key between two of them).
const CARRY_CAP: usize = 64 * 1024;

/// Child output as the tailer shows it, across reads: complete lines only,
/// and nothing of a line over [`CARRY_CAP`] up to its real end of line. For
/// a host with a key, only this app's fixed notices are shown (its log holds
/// nothing else, see `pocket_codex_codex::spawn_with_env_redacted`).
pub(super) struct TailState {
    // Bytes, not a String: a multi-byte UTF-8 char split across a read
    // boundary must be held intact until its line completes, then decoded —
    // decoding the partial chunk would corrupt it into replacement chars.
    lines: pocket_codex_core::redact::Lines,
    redactor: host_profiles::Redactor,
}

impl TailState {
    /// A tailer's state for output read through `redactor`.
    pub(super) fn new(redactor: host_profiles::Redactor) -> Self {
        Self {
            lines: pocket_codex_core::redact::Lines::new(CARRY_CAP),
            redactor,
        }
    }

    /// The file was truncated or rotated: drop any partial line.
    pub(super) fn reset(&mut self) {
        self.lines.reset();
    }

    /// The lines one read of `bytes` completes, as shown.
    pub(super) fn read(&mut self, bytes: &[u8]) -> Vec<String> {
        use pocket_codex_core::redact::Piece;
        let mut shown = Vec::new();
        let redactor = &self.redactor;
        self.lines.feed(bytes, |piece| match piece {
            Piece::Line(line) => shown.extend(shown_line(line, redactor)),
            Piece::Withheld(bytes) if redactor.is_empty() => shown.push(withheld_partial(bytes)),
            Piece::Withheld(_) => {},
        });
        shown
    }
}

/// Tail an external codex process's log file (its own `tracing` output) into
/// the in-app log stream. Starts at
/// `start_pos` (this run's first byte), polls for appended content, and emits
/// each complete new line under a `codex(<name>)` target (for a host with a
/// key, `redactor` lets only this app's notices through). Aborted on stop.
pub(super) fn tail_codex_log(
    log_file: std::path::PathBuf,
    start_pos: u64,
    name: String,
    redactor: host_profiles::Redactor,
) -> JoinHandle<()> {
    use tokio::io::{AsyncReadExt, AsyncSeekExt};
    let target = format!("codex({name})");
    runtime::runtime().spawn(async move {
        let mut pos = start_pos;
        let mut tail = TailState::new(redactor);
        loop {
            tokio::time::sleep(Duration::from_millis(500)).await;
            let Ok(meta) = tokio::fs::metadata(&log_file).await else {
                continue;
            };
            let mut len = meta.len();
            // Enforce the size cap HERE, not only at spawn. The spawn-time check
            // alone is useless against the case that actually hurt: one host
            // running for hours. The burst that prompted this wrote 4.9 GB in a
            // single ~12h session, peaking at 72 MB/min — a check that only runs
            // between sessions never fired once.
            //
            // Truncate in place rather than unlink: the child holds this file
            // open, so removing it would leave the writer appending to a deleted
            // inode (the space never comes back until the host stops, which is
            // exactly the wrong behaviour for a disk-pressure guard). `set_len(0)`
            // frees the blocks immediately and the child's next append lands at 0.
            if over_log_cap(len) && truncate_host_log(&log_file).await {
                tracing::info!(?log_file, bytes = len, "host log passed its size cap; truncated");
                len = 0;
            }
            if len < pos {
                // Truncated / rotated — resync to the new end (don't replay the
                // whole file).
                pos = len;
                tail.reset();
            }
            if len == pos {
                continue;
            }
            let Ok(mut f) = tokio::fs::File::open(&log_file).await else {
                continue;
            };
            if f.seek(std::io::SeekFrom::Start(pos)).await.is_err() {
                continue;
            }
            let mut buf = Vec::with_capacity((len - pos) as usize);
            if f.take(len - pos).read_to_end(&mut buf).await.is_err() {
                continue;
            }
            pos = len;
            for text in tail.read(&buf) {
                logging::push_external(&target, &text);
            }
        }
    })
}

/// One complete child output line as shown, or `None` when blank or, for a
/// host with a key, anything but this app's own notice.
pub(super) fn shown_line(line: &[u8], redactor: &host_profiles::Redactor) -> Option<String> {
    let text = String::from_utf8_lossy(line);
    let text = text.trim_end();
    if text.is_empty() {
        return None;
    }
    redactor.output(text).map(str::to_string)
}

/// The notice shown instead of a line too long to keep.
pub(super) fn withheld_partial(bytes: usize) -> String {
    format!("[at least {bytes} bytes of output withheld: the line was too long]")
}

/// What a watchdog supervises: one incarnation of one host.
pub(super) struct Watched {
    /// The host table key.
    pub(super) name: String,
    /// The incarnation it may restart; a replaced host is never touched.
    pub(super) incarnation: String,
    /// The app-server's loopback `host:port`.
    pub(super) local_addr: String,
    /// How it was spawned (pinned to its port).
    pub(super) spawn_opts: SpawnOptions,
    /// Its child-only secret environment.
    pub(super) secret_env: Vec<(String, pocket_codex_core::provider::Secret)>,
    /// The route its launch selected, checked again after a restart.
    pub(super) expected: Option<pocket_codex_codex::provider_launch::ExpectedRoute>,
    /// Withholds the host's key from restart errors.
    pub(super) redactor: host_profiles::Redactor,
}

/// How long a restart waits for the instance's lease before skipping this
/// round (a stop, apply or quit holds it and decides instead).
const RESTART_LEASE_WAIT: Duration = Duration::from_secs(1);

/// The lease for restarting `name`'s `incarnation`, or `None` when another
/// operation holds the instance, the host was stopped or replaced, or the
/// app is quitting. Held through the whole blocking restart, so a stop,
/// apply or quit waits for it instead of racing it.
pub(super) fn restart_guard(name: &str, incarnation: &str, wait: Duration) -> Option<Lease> {
    let lease = host_lease::acquire_within(name, Op::Restart, wait).ok()?;
    let owned = !quitting()
        && hosts_locked()
            .get(name)
            .is_some_and(|ls| ls.incarnation == incarnation);
    owned.then_some(lease)
}

/// Probe codex's `/readyz` and restart it when it stops responding, so turns
/// recover without the user intervening. Mirrors the CLI watchdog; logs via
/// `tracing`.
/// A respawn gets the same child-only `secret_env` as the first start.
pub(super) async fn health_watchdog(watched: Watched) {
    let watched = Arc::new(watched);
    let local_addr = watched.local_addr.clone();
    let Some(client) = probe_client() else {
        return;
    };
    let mut consecutive: u32 = 0;
    let mut restart_failures: u32 = 0;
    loop {
        tokio::time::sleep(HEALTH_INTERVAL).await;
        let health = async {
            client
                .get(format!("http://{local_addr}/readyz"))
                .send()
                .await?
                .error_for_status()?;
            pocket_codex_codex::readiness::probe_rpc(&format!("ws://{local_addr}"), READY_TIMEOUT)
                .await
        }
        .await;
        if let Err(error) = &health {
            tracing::warn!(%local_addr, error = %format!("{error:#}"), "app-server health check failed");
            if pocket_codex_core::error::is_file_limit(error.as_ref()) {
                consecutive = 0;
                continue;
            }
        }
        if health.is_ok() {
            consecutive = 0;
            restart_failures = 0;
            continue;
        }
        consecutive += 1;
        if consecutive < HEALTH_FAILURES {
            continue;
        }
        tracing::warn!("codex app-server failed {HEALTH_FAILURES} health checks; restarting it");
        match restart_codex(watched.clone()).await {
            Ok(true) => {
                tracing::info!("codex app-server restarted");
                restart_failures = 0;
            },
            Ok(false) => {
                tracing::info!("codex restart skipped: the host is busy, stopped or replaced");
            },
            Err(e) => {
                restart_failures += 1;
                let error = watched.redactor.text(&format!("{e:#}"));
                tracing::warn!(%error, attempt = restart_failures, "codex restart failed");
            },
        }
        consecutive = 0;
        tokio::time::sleep(health_restart_backoff(restart_failures)).await;
    }
}

/// Grace before probing resumes after a watchdog-driven restart, doubling per
/// consecutive failed recovery up to [`MAX_RESTART_BACKOFF`].
fn health_restart_backoff(restart_failures: u32) -> Duration {
    HEALTH_RESTART_GRACE
        .saturating_mul(1u32 << restart_failures.min(5))
        .min(MAX_RESTART_BACKOFF)
}

/// The HTTP client the watchdog probes `/readyz` with. Built with
/// `.no_proxy()`: probes only ever target our own loopback server, and the
/// process environment can carry an upstream proxy whose `NO_PROXY` doesn't
/// cover loopback — a proxied probe then fails against a perfectly healthy
/// server and the watchdog would keep "recovering" it forever.
fn probe_client() -> Option<reqwest::Client> {
    reqwest::Client::builder()
        .timeout(HEALTH_TIMEOUT)
        .no_proxy()
        .build()
        .ok()
}

/// Stop the wedged codex and spawn a fresh one on the same port (escalating to
/// a hard kill if it ignores the graceful stop), under the instance's lease
/// and only for the incarnation it watches. Blocking work runs off the
/// async runtime. `Ok(false)`: skipped (see [`restart_guard`]).
async fn restart_codex(watched: Arc<Watched>) -> Result<bool> {
    tokio::task::spawn_blocking(move || -> Result<bool> {
        let Some(_lease) = restart_guard(&watched.name, &watched.incarnation, RESTART_LEASE_WAIT)
        else {
            return Ok(false);
        };
        let spawn_opts = watched.spawn_opts.clone();
        // Nothing launches beside an earlier codex of this host still running.
        settle_retained(&watched.name)?;
        // Exactly the process this host runs now (the lease keeps it this
        // incarnation), never whoever listens on its port; one that does
        // not exit stays owned (by the record and the ledger).
        let old = hosts_locked().get(&watched.name).and_then(|ls| ls.child);
        if old.is_some_and(|old| !NATIVE.stop(&watched.name, old, EXIT_WAIT)) {
            bail!("the unresponsive codex did not exit; the restart was not attempted");
        }
        if let Some(ls) = hosts_locked().get_mut(&watched.name) {
            ls.child = None;
        }
        let report =
            spawn_ready_redacted(spawn_opts, &watched.secret_env, &watched.redactor, READY_TIMEOUT)
                .map_err(|err| match err {
                    SpawnReadyError::Spawn(e) => {
                        anyhow::Error::new(e).context("respawning the codex app-server")
                    },
                    // An adopted (reused) listener means spawn found the OLD process
                    // still bound — the restart did not take effect; report that
                    // precisely rather than as a readiness failure. Otherwise a
                    // respawn that dies on boot (e.g. something else grabbed the
                    // port while codex was down) must count as a FAILED restart, so
                    // the watchdog's restart backoff engages instead of resetting and
                    // hammering a bind that can never succeed. The fresh child is
                    // stopped, and kept owned if it does not exit.
                    SpawnReadyError::NotReady {
                        report,
                        failure,
                    } => {
                        if report.reused {
                            anyhow::anyhow!(
                                "codex is still holding the listen port; restart did not take \
                                 effect"
                            )
                        } else {
                            let exited = OwnedChild::of_report(&report)
                                .is_none_or(|child| NATIVE.stop(&watched.name, child, EXIT_WAIT));
                            let error = startup_failure_error(*failure);
                            if exited {
                                error
                            } else {
                                error.context("the respawned codex did not exit")
                            }
                        }
                    },
                })?;
        // Adopted-and-ready reads the same way: the old process survived, so
        // the restart did not take effect.
        anyhow::ensure!(
            !report.reused,
            "codex is still holding the listen port; restart did not take effect"
        );
        let child = OwnedChild::of_report(&report);
        if let Some(expected) = &watched.expected {
            let checked = pocket_codex_codex::provider_launch::check_effective_blocking(
                &report.info.listen,
                expected,
                READY_TIMEOUT,
            );
            if let Err(refusal) = checked {
                let exited = child.is_none_or(|child| NATIVE.stop(&watched.name, child, EXIT_WAIT));
                bail!("{refusal}{}", not_exited(exited));
            }
        }
        if !pocket_codex_codex::still_owned(&report) {
            let exited = child.is_none_or(|child| NATIVE.stop(&watched.name, child, EXIT_WAIT));
            bail!("the port is no longer served by the respawned codex{}", not_exited(exited));
        }
        // The lease is still held, so the host is still this incarnation.
        if let Some(ls) = hosts_locked().get_mut(&watched.name) {
            ls.pid = report.info.pid;
            ls.child = child;
        }
        Ok(true)
    })
    .await
    .context("codex restart task panicked")?
}

/// The caller's phrasing of the pick-another-port remedy (the hosting form's
/// port field) for [`startup_failure_error`].
fn port_retry_hint(port: u16) -> String {
    match port.checked_add(1) {
        Some(next) => format!("retry with port {next}, or 0 to pick a free port automatically"),
        None => "retry with a different port".to_string(),
    }
}

/// Render a [`StartupFailure`] as the hosting error surfaced to the UI —
/// [`StartupFailure::diagnosis`] with the remedy phrased as the hosting
/// form's port field (the CLI sibling phrases it as the `--port` flag).
pub(super) fn startup_failure_error(failure: StartupFailure) -> anyhow::Error {
    let retry = match failure.port {
        Some(port) => port_retry_hint(port),
        None => "retry with a different port".to_string(),
    };
    anyhow::anyhow!(failure.diagnosis(&retry))
}
