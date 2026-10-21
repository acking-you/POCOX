//! Local codex session inventory and *force takeover*, layered on the
//! `pocox-codex` rollout / liveness / takeover primitives.
//!
//! These read `CODEX_HOME` and inspect/terminate local processes, so they
//! act on the machine the bridge runs on (the host that owns the
//! sessions). In POCOX's desktop setup the Flutter app runs
//! alongside the codex desktop app, so "list the sessions under this
//! CODEX_HOME and tell me which are safe to resume" is answered locally.
//!
//! The two-signal model (see `pocox_codex::takeover`):
//!
//! * a session whose latest turn is *running* and whose rollout is *held open*
//!   by a live process must stay read-only;
//! * a *finished* session whose rollout is *free* is plainly resumable;
//! * a finished session still *held open* by another codex app-server (e.g. the
//!   desktop app) is resumable only via a confirmed [`force_resume`], which
//!   releases the holder before resuming and refuses a failed release.

use anyhow::{anyhow, Result};
use pocox_codex::{liveness::Holder, rollout, takeover};
use pocox_core::state::RuntimeState;
pub use pocox_host_svc::sessions::{list as list_local_sessions, LocalSession};

use crate::engine::app_session;

/// A single session's liveness detail, including the processes a force
/// takeover would target.
#[derive(Clone, Debug)]
pub struct SessionLivenessView {
    /// Thread / conversation id.
    pub thread_id: String,
    /// Most-recent-turn state tag.
    pub turn_state: String,
    /// Whether the rollout is currently held open.
    pub held_open: bool,
    /// Resume-safety tag.
    pub safety: String,
    /// Whether the UI may offer a resume action.
    pub allows_resume: bool,
    /// Whether resuming requires a force takeover.
    pub requires_takeover: bool,
    /// Processes a force takeover would attempt to terminate (already
    /// excluding POCOX's own app-server).
    pub holders: Vec<Holder>,
}

/// Outcome of a [`force_resume`].
#[derive(Clone, Debug)]
pub struct ForceResumeOutcome {
    /// Holders that were successfully terminated.
    pub killed: Vec<Holder>,
    /// Holders the kill could not reach (already gone, denied, or
    /// respawned-and-distinct).
    pub survived: Vec<Holder>,
    /// Whether the rollout is still held open after the eviction attempt.
    /// A true value blocks the subsequent resume.
    pub still_held: bool,
    /// Whether the subsequent `thread/resume` into our app-server
    /// succeeded.
    pub resumed: bool,
    /// The resume error message, when `resumed` is false.
    pub resume_error: Option<String>,
}

/// PIDs that a force takeover must never terminate: POCOX's own
/// supervised app-server (the very server we resume into) and the current
/// process.
///
/// On Windows the takeover can't name the exact rollout holder, so it kills
/// from the whole `codex app-server` pool — which includes our own server.
/// The recorded `state.codex.pid` alone is not a safe shield: it can be stale
/// (split `state.toml`) or, when `codex` is an npm/node shim, never the real
/// listener. So we also protect whatever process actually serves the recorded
/// listen port, matched the same way [`crate::engine::app_session`] resolves
/// it — that way a force takeover can never kill the live server it resumes
/// into, even if `state.codex.pid` has drifted.
fn protected_pids() -> Vec<u32> {
    let mut pids = vec![std::process::id()];
    if let Ok(state) = RuntimeState::load() {
        if let Some(codex) = state.codex {
            pids.push(codex.pid);
            if let Some(pid) = pocox_core::process::find_codex_app_server(&codex.listen) {
                pids.push(pid);
            }
        }
    }
    pids
}

/// Inspect one session's liveness in detail, listing the would-be
/// takeover targets (with POCOX's own app-server excluded).
pub fn session_liveness(thread_id: &str) -> Result<SessionLivenessView> {
    let path = rollout::rollout_path_for_thread(thread_id)
        .map_err(|e| anyhow!("locating rollout: {e}"))?
        .ok_or_else(|| anyhow!("no rollout found for thread {thread_id}"))?;
    let guardian =
        rollout::read_session_info(&path)?.thread_source.as_deref() == Some("guardian_review");
    let live = takeover::inspect(&path).map_err(|e| anyhow!("inspecting rollout: {e}"))?;
    let protected = protected_pids();
    let holders = live
        .holders
        .into_iter()
        .filter(|h| !protected.contains(&h.pid))
        .collect();
    Ok(SessionLivenessView {
        thread_id: thread_id.to_string(),
        turn_state: live.turn_state.tag().to_string(),
        held_open: live.held_open,
        safety: live.safety.tag().to_string(),
        allows_resume: !guardian && live.safety.allows_resume(),
        requires_takeover: !guardian && live.safety.requires_takeover(),
        holders,
    })
}

/// Read a local session's full transcript for READ-ONLY viewing.
///
/// Parses the on-disk rollout directly via [`rollout::read_transcript`], so
/// it works for a session another codex client owns and never touches the
/// app-server (no resume, no held-file write). Returned items are in the
/// same `{id, type, title, text}` shape as `thread/read`, so the viewer can
/// reuse the live-conversation rendering.
pub fn local_session_transcript(thread_id: &str) -> Result<Vec<rollout::TranscriptItem>> {
    let path = rollout::rollout_path_for_thread(thread_id)
        .map_err(|e| anyhow!("locating rollout: {e}"))?
        .ok_or_else(|| anyhow!("no rollout found for thread {thread_id}"))?;
    rollout::read_transcript(&path).map_err(|e| anyhow!("reading transcript: {e}"))
}

/// Force-resume a session into the app-server behind `service_key`.
///
/// Evicts live processes holding the session's rollout open (except
/// POCOX's own app-server), then issues `thread/resume` only if the
/// release succeeded. The returned [`ForceResumeOutcome`] preserves failed
/// releases and their cause without admitting another writer.
///
/// The caller is responsible for gating this on user confirmation and for
/// not offering it while a turn is actively running (see
/// [`SessionLivenessView::allows_resume`]).
pub fn force_resume(service_key: &str, thread_id: &str) -> Result<ForceResumeOutcome> {
    let path = rollout::rollout_path_for_thread(thread_id)
        .map_err(|e| anyhow!("locating rollout: {e}"))?
        .ok_or_else(|| anyhow!("no rollout found for thread {thread_id}"))?;
    // Re-check liveness against the freshest state right before acting: the
    // caller gated on a possibly-stale `LocalSession`, and other FFI callers
    // reach here directly. Never resume a rollout whose turn is running right
    // now — that would make two writers append to one file. Only
    // Resumable / ResumableUnfinished / (confirmed) OwnedIdle proceed.
    if rollout::read_session_info(&path)?.thread_source.as_deref() == Some("guardian_review") {
        return Err(anyhow!("Guardian approval sessions are read-only; open their parent session"));
    }
    let live = takeover::inspect(&path).map_err(|e| anyhow!("inspecting rollout: {e}"))?;
    if matches!(live.safety, takeover::ResumeSafety::OwnedRunning) {
        return Err(anyhow!(
            "session is running in another client right now; wait for its turn to finish before \
             resuming"
        ));
    }
    let protected = protected_pids();
    let report = takeover::force_release(&path, &protected);

    let (resumed, resume_error) = match report.resume_blocker() {
        Some(reason) => (false, Some(reason.to_owned())),
        None => match app_session::thread_resume(service_key, thread_id) {
            Ok(()) => (true, None),
            Err(err) => (false, Some(err.to_string())),
        },
    };

    Ok(ForceResumeOutcome {
        killed: report.killed,
        survived: report.survived,
        still_held: report.still_held,
        resumed,
        resume_error,
    })
}
