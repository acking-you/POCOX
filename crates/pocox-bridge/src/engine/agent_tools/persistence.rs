//! Saving a share is a separate decision from removing its expiry timer.
//! The user can save directly; an agent requests permission for its own
//! exact share, then loses control of it once it belongs to the user.

use super::consent;
use super::error::{Pending, ToolError};
use super::model::{bounded, ShareView, Shared};
use super::shares::{self, Caller};
use super::state::{self, State};
use crate::engine::transport;

/// Save a share until the user stops it, without changing its attribution.
pub fn keep(id: &str) -> Result<ShareView, ToolError> {
    let mut state = state::lock();
    let index = find(&state, id)?;
    keep_in(&mut state, index)
}

fn find(state: &State, target: &str) -> Result<usize, ToolError> {
    let target = target.trim();
    state
        .shares
        .iter()
        .position(|share| {
            share.id == target
                || share
                    .ports
                    .iter()
                    .any(|port| port.key == target || port.port.to_string() == target)
        })
        .ok_or_else(|| ToolError::NotFound(format!("The share `{}`", bounded(target))))
}

fn keep_in(state: &mut State, index: usize) -> Result<ShareView, ToolError> {
    let unsaved = state.shares_unsaved;
    let share = &mut state.shares[index];
    let before = (share.key.take(), share.expires_ms.take());
    if state.save_shares().is_err() {
        let share = &mut state.shares[index];
        (share.key, share.expires_ms) = before;
        state.shares_unsaved = unsaved;
        return Err(ToolError::NotSaved);
    }
    let view = state.shares[index].view();
    state::changed(state);
    Ok(view)
}

fn owned_view(state: &State, caller: &Caller, target: &str) -> Result<ShareView, ToolError> {
    state.admits(caller)?;
    let share = &state.shares[find(state, target)?];
    if share.key.as_ref().is_some_and(|key| key != &caller.key()) {
        return Err(ToolError::NotOwner);
    }
    Ok(share.view())
}

/// Ask to save an agent's existing share. A repeat of an already saved
/// share only describes it; it does not give the agent ownership back.
pub async fn request_keep(
    caller: &Caller,
    target: &str,
) -> Result<Result<Shared, Pending>, ToolError> {
    let epoch = transport::epoch();
    let before = owned_view(&state::lock(), caller, target)?;
    if before.persistence() == Some(true) {
        return Ok(Ok(shares::shared(before)));
    }
    let ports: Vec<u16> = before.ports.iter().map(|port| port.port).collect();
    if let Err(waiting) = consent::admit_keep(caller, &before.id, &before.title, &ports).await? {
        return Ok(Err(waiting));
    }
    let view = {
        let mut state = state::lock();
        if !transport::is_current(epoch) {
            return Err(ToolError::ContextChanged);
        }
        commit(&mut state, caller, &before)?
    };
    Ok(Ok(shares::shared(view)))
}

/// Recheck the token, share identity and every port after waiting for consent.
fn commit(state: &mut State, caller: &Caller, before: &ShareView) -> Result<ShareView, ToolError> {
    let current = owned_view(state, caller, &before.id)?;
    if current.ports.len() != before.ports.len()
        || current
            .ports
            .iter()
            .any(|port| !before.ports.iter().any(|old| old.port == port.port))
    {
        return Err(ToolError::Invalid(
            "The share's ports changed while waiting. Call keep_sharing again for its current \
             ports."
                .into(),
        ));
    }
    let index = find(state, &before.id)?;
    keep_in(state, index)
}

#[cfg(test)]
mod tests {
    use super::super::state::{Share, SharedPort};
    use super::super::tokens::Kind;
    use super::*;

    fn setup() -> (State, Caller) {
        let mut state = State {
            hosting: true,
            ..State::default()
        };
        let (principal, _) = state
            .tokens
            .mint(Kind::Installed, "Codex", Some("codex"), None)
            .unwrap();
        let caller = Caller {
            principal,
            conversation: Some("video".into()),
        };
        state.shares.push(Share {
            id: "video".into(),
            title: "Videos".into(),
            path: "/static/?sort=name#latest".into(),
            secure: true,
            owner: caller.owner(),
            key: Some(caller.key()),
            created_ms: 1,
            expires_ms: None,
            ports: vec![SharedPort::new(
                5555,
                "pcx:studio:port:5555".into(),
                "127.0.0.1:5555".parse().unwrap(),
                true,
            )],
        });
        (state, caller)
    }

    #[test]
    fn no_timer_is_temporary_until_saved_and_reloaded_from_disk() {
        let (mut state, caller) = setup();
        let dir = tempfile::tempdir().unwrap();
        state.dir = Some(dir.path().into());
        state.save_shares().unwrap();
        assert!(state::saved_shares(dir.path()).unwrap().is_empty());
        let before = owned_view(&state, &caller, "5555").unwrap();
        assert_eq!(before.persistence(), Some(false));
        let kept = commit(&mut state, &caller, &before).unwrap();
        assert_eq!(kept.persistence(), Some(true));
        assert!(state.shares[0].key.is_none());
        assert_eq!(kept.owner.label, before.owner.label, "saving preserves attribution");
        let saved = state::saved_shares(dir.path()).unwrap();
        assert_eq!(saved.len(), 1);
        assert_eq!(saved[0].id, before.id);
        assert_eq!(saved[0].path, before.path);
        assert!(saved[0].secure);
        assert_eq!(saved[0].ports, [5555]);
        assert_eq!(commit(&mut state, &caller, &before).unwrap().id, kept.id);
    }

    #[test]
    fn failed_save_preserves_agent_ownership_and_expiry() {
        let (mut state, caller) = setup();
        state.shares[0].expires_ms = Some(123);
        state.shares_blocked = true;
        let before = state.shares[0].view();
        assert!(matches!(commit(&mut state, &caller, &before), Err(ToolError::NotSaved)));
        assert_eq!(state.shares[0].key, Some(caller.key()));
        assert_eq!(state.shares[0].expires_ms, Some(123));
        assert_eq!(state.shares[0].view().persistence(), Some(false));
    }

    #[test]
    fn approval_cannot_save_another_owner_or_a_changed_share() {
        let (mut state, caller) = setup();
        let before = state.shares[0].view();
        let other = Caller {
            conversation: Some("other".into()),
            ..caller.clone()
        };
        assert!(matches!(commit(&mut state, &other, &before), Err(ToolError::NotOwner)));
        state.shares[0].ports.push(SharedPort::new(
            5556,
            "pcx:studio:port:5556".into(),
            "127.0.0.1:5556".parse().unwrap(),
            true,
        ));
        assert!(matches!(commit(&mut state, &caller, &before), Err(ToolError::Invalid(_))));
        state.shares[0].ports.pop();
        state.shares[0].id = "replacement".into();
        assert!(matches!(commit(&mut state, &caller, &before), Err(ToolError::NotFound(_))));
        state.shares[0].id = before.id.clone();
        state.tokens.forget_where(|p| p.id == caller.principal.id);
        assert!(matches!(commit(&mut state, &caller, &before), Err(ToolError::Revoked)));
        assert!(!state.shares[0].durable());
    }

    #[test]
    fn old_catalogs_do_not_turn_unlimited_agent_shares_into_saved_shares() {
        let (state, _) = setup();
        let mut wire = serde_json::to_value(state.shares[0].view()).unwrap();
        wire.as_object_mut().unwrap().remove("persistent");
        let old: ShareView = serde_json::from_value(wire.clone()).unwrap();
        assert_eq!(old.persistence(), None);
        wire["owner"]["kind"] = serde_json::json!("user");
        let old: ShareView = serde_json::from_value(wire).unwrap();
        assert_eq!(old.persistence(), Some(true));
    }
}
