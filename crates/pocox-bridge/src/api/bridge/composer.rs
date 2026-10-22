//! In-memory command admission for one host/project draft. No I/O, payload
//! parsing or network waits are permitted on this synchronous boundary.
use std::sync::Mutex;

use anyhow::Context;

use super::*;

/// Explicit transitions of the native composer controller.
#[derive(Clone, Copy)]
pub enum ComposerAction {
    /// Append a new command identity.
    Enqueue,
    /// Put an unconsumed supplement before pending commands.
    Prepend,
    /// Remove a command that is not in flight.
    Drop,
    /// Remove a command after its host acknowledged admission.
    Accept,
    /// Acquire the draft's exclusive send lease.
    BeginSend,
    /// Release only the matching send lease.
    EndSend,
    /// Pause automatic queue draining.
    Pause,
    /// Allow draining, retaining unknown-outcome protection.
    Resume,
    /// Begin sending the ready head command.
    BeginQueued,
    /// End an attempt without changing its outcome.
    EndQueued,
    /// Preserve an unknown outcome and pause the queue.
    Unknown,
    /// Preserve a definite refusal and pause the queue.
    Refused,
    /// The user's explicit retry of the unknown head command.
    RetryUnknown,
    /// Revoke outstanding attachment admissions.
    Revoke,
}

/// State of one command identity; display payloads stay in Flutter.
#[derive(Clone, Default)]
pub struct QueuedCommandDto {
    /// Identity assigned by the draft store.
    pub id: u32,
    /// The command belongs to an outstanding attempt.
    pub in_flight: bool,
    /// Only explicit retry may send this command again.
    pub uncertain: bool,
}

/// An immutable view after one atomic controller transition.
#[derive(Clone, Default)]
pub struct ComposerViewDto {
    /// Outstanding send lease, if any.
    pub send_token: Option<u32>,
    /// Attachment admission generation.
    pub admission: u32,
    /// Automatic draining is paused.
    pub queue_paused: bool,
    /// Pending commands in authoritative order.
    pub queue: Vec<QueuedCommandDto>,
}

#[frb(ignore)]
#[derive(Default)]
struct State {
    view: ComposerViewDto,
    next_token: u32,
}

/// Native state tied to the lifetime of a host/project draft. Releasing its
/// opaque handle releases the state; no process-global draft registry exists.
#[frb(opaque)]
pub struct ComposerController {
    state: Mutex<State>,
}

/// Create a draft's memory-only admission controller.
#[frb(sync)]
pub fn composer_create() -> ComposerController {
    ComposerController {
        state: Mutex::default(),
    }
}

/// Apply one bounded, memory-only command. The matching lease prevents an old
/// completion from releasing a newer send. Unknown results survive Resume.
#[frb(sync)]
pub fn composer_apply(
    controller: &ComposerController,
    action: ComposerAction,
    id: Option<u32>,
    token: Option<u32>,
) -> Result<ComposerViewDto> {
    let mut state = controller.state.lock().unwrap_or_else(|e| e.into_inner());
    state.apply(action, id, token)?;
    Ok(state.view.clone())
}

#[frb(ignore)]
impl State {
    fn apply(&mut self, action: ComposerAction, id: Option<u32>, token: Option<u32>) -> Result<()> {
        use ComposerAction::*;
        let view = &mut self.view;
        match action {
            BeginSend => {
                anyhow::ensure!(
                    view.send_token.is_none(),
                    "a send is already pending for this draft"
                );
                self.next_token = self
                    .next_token
                    .checked_add(1)
                    .context("composer lease exhausted")?;
                view.send_token = Some(self.next_token);
            },
            EndSend => {
                if token.is_some() && token == view.send_token {
                    view.send_token = None;
                }
            },
            Pause => view.queue_paused = true,
            Resume => view.queue_paused = false,
            Revoke => {
                view.admission = view
                    .admission
                    .checked_add(1)
                    .context("composer generation exhausted")?
            },
            Enqueue | Prepend => {
                let id = id.context("queued command requires an identity")?;
                anyhow::ensure!(view.queue.len() < 1024, "conversation queue is full");
                anyhow::ensure!(
                    !view.queue.iter().any(|entry| entry.id == id),
                    "queued identity already exists"
                );
                let entry = QueuedCommandDto {
                    id,
                    ..Default::default()
                };
                if matches!(action, Enqueue) {
                    view.queue.push(entry);
                } else {
                    anyhow::ensure!(
                        !view.queue.first().is_some_and(|head| head.in_flight),
                        "cannot prepend before a sending command"
                    );
                    view.queue.insert(0, entry);
                }
            },
            Drop | Accept | BeginQueued | EndQueued | Unknown | Refused | RetryUnknown => {
                let id = id.context("queue transition requires an identity")?;
                let Some(at) = view.queue.iter().position(|entry| entry.id == id) else {
                    // Ending or dropping a command that already left is a no-op.
                    anyhow::ensure!(
                        matches!(action, EndQueued | Drop),
                        "queued command is no longer present"
                    );
                    return Ok(());
                };
                let (head, paused, leased) =
                    (at == 0, view.queue_paused, view.send_token.is_some());
                let entry = &mut view.queue[at];
                match action {
                    Drop => {
                        anyhow::ensure!(!entry.in_flight, "a sending command cannot be removed");
                        view.queue.remove(at);
                    },
                    Accept => {
                        anyhow::ensure!(
                            head && entry.in_flight,
                            "only the sending head may be accepted"
                        );
                        view.queue.remove(at);
                    },
                    BeginQueued => {
                        anyhow::ensure!(
                            head && !paused && !entry.uncertain && !entry.in_flight,
                            "queued command is not ready for automatic sending"
                        );
                        entry.in_flight = true;
                    },
                    EndQueued => entry.in_flight = false,
                    Unknown | Refused => {
                        entry.in_flight = false;
                        entry.uncertain = matches!(action, Unknown);
                        view.queue_paused = true;
                    },
                    // RetryUnknown, the user's explicit retry.
                    _ => {
                        anyhow::ensure!(
                            head && !entry.in_flight && !leased,
                            "only an idle queue head may be retried"
                        );
                        entry.uncertain = false;
                    },
                }
            },
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use ComposerAction::*;

    use super::*;
    #[test]
    fn unknown_results_never_resume_automatically_and_active_commands_cannot_move() {
        let mut state = State::default();
        state.apply(Enqueue, Some(1), None).unwrap();
        state.apply(Enqueue, Some(2), None).unwrap();
        assert!(state.apply(BeginQueued, Some(2), None).is_err());
        state.apply(BeginQueued, Some(1), None).unwrap();
        assert!(state.apply(Drop, Some(1), None).is_err());
        assert!(state.apply(Prepend, Some(3), None).is_err());
        state.apply(Unknown, Some(1), None).unwrap();
        state.apply(Resume, None, None).unwrap();
        assert!(state.apply(BeginQueued, Some(1), None).is_err());
        state.apply(RetryUnknown, Some(1), None).unwrap();
        state.apply(BeginQueued, Some(1), None).unwrap();
        state.apply(Accept, Some(1), None).unwrap();
        assert_eq!(state.view.queue[0].id, 2);
    }
    #[test]
    fn old_completions_never_release_a_new_send_or_attachment_generation() {
        let mut state = State::default();
        state.apply(BeginSend, None, None).unwrap();
        let old = state.view.send_token;
        assert!(state.apply(BeginSend, None, None).is_err());
        state.apply(EndSend, None, old).unwrap();
        state.apply(BeginSend, None, None).unwrap();
        let new = state.view.send_token;
        state.apply(Revoke, None, None).unwrap();
        state.apply(EndSend, None, old).unwrap();
        assert_eq!(state.view.send_token, new);
        assert_eq!(state.view.admission, 1);
    }
}

/// Recognize only host refusals issued before admission. Unknown wording,
/// transport failures and timeouts never authorize automatic replay.
#[frb(sync)]
pub fn turn_error_is_refusal(message: String) -> bool {
    let prefix: String = message
        .chars()
        .take(128)
        .map(|c| c.to_ascii_lowercase())
        .collect();
    [
        "the agent is not running",
        "the agent host changed",
        "unknown session",
        "a turn is already running in this session",
        "the session is still loading",
        "too many sessions are busy",
        "too many pending operations",
        "invalid request:",
    ]
    .iter()
    .any(|start| prefix.starts_with(start))
}
