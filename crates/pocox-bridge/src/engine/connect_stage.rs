//! Where a session's connect stands, so the app can show a reconnect as it
//! unfolds: reaching the service through its tunnel, opening the session
//! over it, then the protocol handshake. The tunnel's own progress (relay
//! phases, hole punching) is in its subscription status.

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex, MutexGuard};

/// A step of connecting a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectStage {
    /// Opening or reusing the tunnel to the service.
    Tunnel,
    /// Opening the session's connection through the tunnel; a direct
    /// attempt, when there is one, happens here.
    Session,
    /// The session's protocol handshake.
    Handshake,
}

static STAGES: LazyLock<Mutex<HashMap<String, ConnectStage>>> = LazyLock::new(Mutex::default);

fn stages() -> MutexGuard<'static, HashMap<String, ConnectStage>> {
    STAGES.lock().unwrap_or_else(|poison| poison.into_inner())
}

/// A connect of one service in progress; dropping it ends the connect.
pub struct Connecting {
    key: String,
}

/// Begin connecting `key`, at [`ConnectStage::Tunnel`].
pub fn begin(key: &str) -> Connecting {
    stages().insert(key.into(), ConnectStage::Tunnel);
    Connecting {
        key: key.into(),
    }
}

/// Move the connect of `key` on to `stage`, if one is in progress.
pub fn enter(key: &str, stage: ConnectStage) {
    if let Some(current) = stages().get_mut(key) {
        *current = stage;
    }
}

/// The stage the connect of `key` is at, if one is in progress.
pub fn current(key: &str) -> Option<ConnectStage> {
    stages().get(key).copied()
}

impl Drop for Connecting {
    fn drop(&mut self) {
        stages().remove(&self.key);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_connect_reports_its_stage_until_it_ends() {
        let key = "pcx:stage-test:app:default";
        assert_eq!(current(key), None);
        let connecting = begin(key);
        assert_eq!(current(key), Some(ConnectStage::Tunnel));
        enter(key, ConnectStage::Handshake);
        assert_eq!(current(key), Some(ConnectStage::Handshake));
        drop(connecting);
        enter(key, ConnectStage::Session);
        assert_eq!(current(key), None, "no connect, no stage");
    }
}
