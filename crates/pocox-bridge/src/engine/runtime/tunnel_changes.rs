//! A coalesced notice that some tunnel of this process changed, from the SDK's
//! event streams: what is on screen reads the new state when something
//! happens instead of waiting for its next poll.

use std::sync::LazyLock;

use pocox_pb::Connection;
use tokio::sync::watch;

static REVISION: LazyLock<watch::Sender<u64>> = LazyLock::new(|| watch::channel(0).0);

/// Follows the revision; intermediate values need no replay.
pub fn subscribe() -> watch::Receiver<u64> {
    REVISION.subscribe()
}

/// Something a list of tunnels shows changed.
pub(super) fn notify() {
    REVISION.send_modify(|revision| *revision = revision.wrapping_add(1));
}

/// Notify on every event of `connection`, until it stops. Following a tunnel
/// does not keep it alive.
pub(super) fn follow(connection: &Connection) {
    let mut events = connection.subscribe_events();
    super::runtime().spawn(async move {
        // A reader that fell behind is told so, which is a change as well.
        while events.recv().await.is_some() {
            notify();
        }
    });
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use pocox_pb::{subscribe_background, RelaySession, SubscribeOptions};

    use super::*;

    #[test]
    fn a_followed_tunnels_events_move_the_revision_until_it_stops() {
        crate::engine::runtime::init(std::env::temp_dir()).expect("test runtime");
        crate::engine::runtime::runtime().block_on(async {
            let closed = std::net::TcpListener::bind("127.0.0.1:0").expect("port");
            let relay = closed.local_addr().expect("address").to_string();
            drop(closed);
            let free = std::net::TcpListener::bind("127.0.0.1:0").expect("port");
            let local_addr = free.local_addr().expect("address").to_string();
            drop(free);
            let mut changes = subscribe();
            let connection =
                subscribe_background(&RelaySession::for_test(relay), SubscribeOptions {
                    key: "pcx:changes:port:1".into(),
                    local_addr,
                })
                .await
                .expect("handle");
            follow(&connection);
            tokio::time::timeout(Duration::from_secs(5), changes.changed())
                .await
                .expect("the worker's first step is an event")
                .expect("the revision stays open");
            connection.stop().await.expect("stop");
        });
    }
}
