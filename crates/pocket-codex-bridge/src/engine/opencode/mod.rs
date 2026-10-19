//! Independent native OpenCode controller. A connection and every answer belong
//! to one account/relay context and one host/source incarnation. Only the host
//! folds native SSE; controllers replace bounded windows after invalidations.

mod connection;
mod engine;
mod events;
mod follow;
mod ops;
mod paging;
mod projection;
#[cfg(test)]
mod reconciliation_tests;
mod settings;
#[cfg(test)]
mod tests;

use std::{
    collections::HashMap,
    sync::{Arc, Mutex, MutexGuard, Weak},
};

use anyhow::{anyhow, bail, Result};
pub use connection::{connect, context_changed, disconnect, is_connected, probe_reason};
pub use engine::{models_for_project, OpenCodeEngine};
pub use follow::{follow_session, liveness};
use once_cell::sync::Lazy;
pub use ops::{access, commands, open, release};
use pocket_codex_host_svc::opencode::{
    catalog::Catalog,
    client::ClientError,
    gateway::Gateway,
    host::{Identity, Info, Snapshot},
};
pub use settings::{draft_settings, refresh_settings};
use tokio::{sync::broadcast, task::JoinHandle};

use super::{
    app_session::AppEvent,
    runtime,
    session_engine::logical_key,
    transport::{self, Context},
};

type Key = (String, String);

fn catalog(service: &str, directory: Option<&str>) -> Result<Catalog> {
    catalog_for_link(&conn(service)?, directory)
}

fn catalog_for_link(link: &Link, directory: Option<&str>) -> Result<Catalog> {
    let identity = link.identity();
    let catalog = block(link.client.catalog(directory, &identity))?;
    link.commit(&identity, |_| ())?;
    Ok(catalog)
}
static CONNS: Lazy<Mutex<HashMap<Key, Conn>>> = Lazy::new(Mutex::default);

struct Shared {
    info: Info,
    image_input: bool,
    healthy: bool,
    /// Only bounded newest windows are retained; older pages go straight to UI.
    sessions: HashMap<String, Snapshot>,
    bytes: HashMap<String, usize>,
    cursors: HashMap<String, Option<String>>,
    turn_pages: HashMap<(String, String), paging::Page>,
    /// Turns this link admitted whose start no refresh has shown yet, by
    /// session; one that also ends before a refresh still ends here.
    admitted: HashMap<String, String>,
}

struct Conn {
    client: Gateway,
    shared: Arc<Mutex<Shared>>,
    tx: broadcast::Sender<AppEvent>,
    task: JoinHandle<()>,
    subscription: String,
}

fn lock<T>(value: &Mutex<T>) -> MutexGuard<'_, T> {
    value.lock().unwrap_or_else(|poison| poison.into_inner())
}

fn key_in(context: &Context, service: &str) -> Result<Key> {
    if !context.admits(service) {
        bail!("this service belongs to another account or relay");
    }
    Ok((context.id().into(), logical_key(service).ok_or_else(|| anyhow!("invalid service key"))?))
}

fn current_key(service: &str) -> Result<Key> {
    let context =
        transport::current_context().ok_or_else(|| anyhow!("OpenCode is not connected"))?;
    key_in(&context, service)
}

fn lifecycle(key: &Key) -> Arc<Mutex<()>> {
    type Locks = HashMap<Key, Weak<Mutex<()>>>;
    static LOCKS: Lazy<Mutex<Locks>> = Lazy::new(Mutex::default);
    let mut locks = lock(&LOCKS);
    if let Some(found) = locks.get(key).and_then(Weak::upgrade) {
        return found;
    }
    locks.retain(|_, entry| entry.strong_count() > 0);
    let result = Arc::new(Mutex::new(()));
    locks.insert(key.clone(), Arc::downgrade(&result));
    result
}

#[derive(Clone)]
struct Link {
    key: Key,
    client: Gateway,
    shared: Arc<Mutex<Shared>>,
    tx: broadcast::Sender<AppEvent>,
}

impl Link {
    fn identity(&self) -> Identity {
        lock(&self.shared).info.identity.clone()
    }

    fn commit<T>(&self, expected: &Identity, apply: impl FnOnce(&mut Shared) -> T) -> Result<T> {
        let registry = lock(&CONNS);
        if !registry
            .get(&self.key)
            .is_some_and(|conn| Arc::ptr_eq(&conn.shared, &self.shared))
        {
            bail!("the OpenCode connection changed; refresh before trying again");
        }
        let mut shared = lock(&self.shared);
        if &shared.info.identity != expected {
            bail!("the OpenCode host changed; reconnect");
        }
        Ok(apply(&mut shared))
    }

    fn accept(&self, expected: &Identity, snapshot: Snapshot) -> Result<bool> {
        validate_snapshot(expected, &snapshot)?;
        self.commit(expected, |view| {
            // An in-flight HTTP answer cannot overwrite a more recent live window.
            if view
                .sessions
                .get(&snapshot.session.id)
                .is_some_and(|old| old.window.sequence > snapshot.window.sequence)
            {
                return false;
            }
            let size = snapshot_bytes(&snapshot);
            let id = &snapshot.session.id;
            view.bytes.remove(id);
            while view.bytes.values().sum::<usize>().saturating_add(size) > 16 * 1024 * 1024
                || !view.sessions.contains_key(id) && view.sessions.len() >= 8
            {
                let Some(victim) = view
                    .sessions
                    .keys()
                    .filter(|key| *key != id)
                    .min_by_key(|key| {
                        (view.sessions[*key].turn_id.is_some(), view.sessions[*key].window.sequence)
                    })
                    .cloned()
                else {
                    break;
                };
                view.sessions.remove(&victim);
                view.cursors.remove(&victim);
                view.bytes.remove(&victim);
            }
            view.bytes.insert(id.clone(), size);
            view.sessions.insert(id.clone(), snapshot);
            true
        })
    }
}

fn snapshot_bytes(snapshot: &Snapshot) -> usize {
    struct Count(usize);
    impl std::io::Write for Count {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0 = self.0.saturating_add(bytes.len());
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let mut count = Count(0);
    let _ = serde_json::to_writer(&mut count, snapshot);
    count.0
}

fn validate_snapshot(expected: &Identity, snapshot: &Snapshot) -> Result<()> {
    ops::validate_access(expected, &snapshot.access, &snapshot.session.id)
}

fn conn(service: &str) -> Result<Link> {
    let key = current_key(service)?;
    let registry = lock(&CONNS);
    let found = registry
        .get(&key)
        .ok_or_else(|| anyhow!("OpenCode is not connected"))?;
    Ok(Link {
        key,
        client: found.client.clone(),
        shared: found.shared.clone(),
        tx: found.tx.clone(),
    })
}

fn block<T>(future: impl std::future::Future<Output = Result<T, ClientError>>) -> Result<T> {
    runtime::runtime()
        .block_on(future)
        .map_err(anyhow::Error::from)
}
