//! Read-only original-session follow. Native events are process-local, so
//! external writers also require bounded persisted-history refreshes. This
//! never calls open/resume or changes writer admission.
use std::time::Duration;

use pocket_codex_host_svc::{
    session_access::SessionAccess,
    sessions::{SessionFollowUpdate, SessionLiveness},
};

use super::*;

fn state(access: &SessionAccess) -> SessionLiveness {
    SessionLiveness {
        thread_id: access.session_id.clone(),
        turn_state: access.turn.clone(),
        held_open: access.writer != "none" && access.writer != "unknown",
        safety: "nativeUnknown".into(),
        allows_resume: false,
        requires_takeover: false,
        holders: Vec::new(),
    }
}

/// Read fresh access as legacy follow metadata, never as take-over permission.
pub fn liveness(service: &str, session: &str) -> Result<SessionLiveness> {
    Ok(state(&access(service, session)?))
}

/// Follow only this captured host/source and original ID until the UI leaves.
pub async fn follow_session<F>(service: &str, session: &str, on_update: F) -> Result<()>
where
    F: FnMut(SessionFollowUpdate) -> bool,
{
    let link = conn(service)?;
    follow_link(link, service, session, on_update).await
}

pub(super) async fn follow_link<F>(
    link: Link,
    service: &str,
    session: &str,
    mut on_update: F,
) -> Result<()>
where
    F: FnMut(SessionFollowUpdate) -> bool,
{
    let identity = link.identity();
    let mut updates = link.tx.subscribe();
    let mut tick = tokio::time::interval(Duration::from_secs(2));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut previous = None;
    loop {
        tokio::select! {
            _ = tick.tick() => {},
            event = updates.recv() => {
                match event {
                    Err(broadcast::error::RecvError::Closed) => bail!("OpenCode follow disconnected"),
                    Ok(event) if event.thread_id.as_deref().is_some_and(|id| id != session) => continue,
                    _ => {},
                }
                // Several full-part events may represent one merged window.
                tokio::time::sleep(Duration::from_millis(250)).await;
                while updates.try_recv().is_ok() {}
            },
        }
        let snapshot = match link.client.snapshot(session, None).await {
            Ok(snapshot) => snapshot,
            Err(error) => {
                if events::deleted_session(&link, &identity, session, &error).await? {
                    return Ok(());
                }
                return Err(error.into());
            },
        };
        if snapshot.session.id != session {
            bail!("OpenCode follow returned another session");
        }
        validate_snapshot(&identity, &snapshot)?;
        link.commit(&identity, |_| ())?;
        let revision = revision(&snapshot.window)?;
        let update = SessionFollowUpdate {
            liveness: state(&snapshot.access),
            items: Vec::new(),
            history_revision: Some(revision),
        };
        if previous.as_ref() == Some(&update) {
            continue;
        }
        super::super::app_session::external_history_changed(service, session);
        previous = Some(update.clone());
        if !on_update(update) {
            return Ok(());
        }
    }
}

fn revision(window: &pocket_codex_host_svc::opencode::fold::Window) -> Result<String> {
    Ok(pocket_codex_core::history_sync::digest_bytes(&serde_json::to_vec(&(
        &window.messages,
        &window.gaps,
        window.connected,
    ))?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn follow_refreshes_when_a_gap_recovers_without_new_text() {
        let mut window = super::super::tests::snapshot().window;
        let original = revision(&window).unwrap();
        window.sequence += 1;
        assert_eq!(revision(&window).unwrap(), original);
        window.gaps.push("prt_answer".into());
        assert_ne!(revision(&window).unwrap(), original);
        window.gaps.clear();
        assert_eq!(revision(&window).unwrap(), original);
        window.connected = false;
        assert_ne!(revision(&window).unwrap(), original);
    }
}
