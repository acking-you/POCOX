//! Sharing loopback ports of this device with the user's other devices.
//!
//! ```text
//!   share ─► check ports answer ─► consent (agents) ─► reserve ─► publish
//!                                                         │
//!   maintain (every tick): expire leases, re-publish, re-check listeners
//! ```
//!
//! A share is reserved in the table before it is published, so a repeated or
//! concurrent call sees it and returns it instead of publishing twice.

use std::{
    collections::BTreeSet,
    net::{Ipv6Addr, SocketAddr},
    time::Duration,
};

use pocket_codex_core::service::{ServiceId, ServiceKind};
use pocket_codex_pb::{publish_pending, PublishError, Published, RegisterOptions};
use tokio::net::TcpStream;

use super::{
    consent,
    error::{Pending, ToolError},
    model::{
        bounded, clean_path, open_link, OwnerKind, OwnerView, ShareView, Shared, AGENT_LEASE_MS,
        MAX_PORTS_PER_SHARE, MAX_SHARED_PORTS,
    },
    state::{self, now_ms, OwnerKey, Share, SharedPort},
    tokens::{Kind, Principal},
};
use crate::engine::{runtime, transport};

/// Longest wait for a port to answer within one call.
const MAX_READY_WAIT: Duration = Duration::from_secs(20);

/// Who is calling, as POCOX knows it.
#[derive(Debug, Clone)]
pub struct Caller {
    /// The token's holder.
    pub principal: Principal,
    /// The conversation the call came from, when the harness says.
    pub conversation: Option<String>,
}

impl Caller {
    /// The user, from the app or the CLI.
    pub fn user(label: &str) -> Self {
        Self {
            principal: Principal {
                id: "user".into(),
                kind: Kind::User,
                label: bounded(label),
                harness: None,
                host: None,
                session: None,
            },
            conversation: None,
        }
    }

    /// What keeps its shares alive.
    pub fn key(&self) -> OwnerKey {
        OwnerKey {
            token: self.principal.id.clone(),
            conversation: self
                .principal
                .session
                .clone()
                .or_else(|| self.conversation.clone()),
        }
    }

    /// The owner recorded for it.
    pub fn owner(&self) -> OwnerView {
        self.principal.owner(self.conversation.as_deref())
    }

    /// Whether this is the user rather than an agent.
    pub fn is_user(&self) -> bool {
        self.principal.kind == Kind::User
    }

    /// How long a call waits for the user's answer. Harnesses POCOX hosts
    /// are configured with a longer tool timeout than common defaults.
    pub fn consent_wait(&self) -> Duration {
        match self.principal.kind {
            Kind::Hosted | Kind::Session => Duration::from_secs(110),
            Kind::Installed | Kind::User => Duration::from_secs(18),
        }
    }
}

/// What to share.
#[derive(Debug, Clone, Default)]
pub struct ShareRequest {
    /// Ports of this machine.
    pub ports: Vec<u16>,
    /// What it is.
    pub title: Option<String>,
    /// Path to open on the first port.
    pub path: Option<String>,
    /// How long to wait for the first port to answer (at most 20 s).
    pub wait_ready_seconds: Option<u64>,
}

/// The loopback address answering on `port`, IPv4 first.
pub async fn answering(port: u16) -> Option<SocketAddr> {
    for addr in
        [SocketAddr::from(([127, 0, 0, 1], port)), SocketAddr::from((Ipv6Addr::LOCALHOST, port))]
    {
        if let Ok(Ok(_)) =
            tokio::time::timeout(Duration::from_millis(400), TcpStream::connect(addr)).await
        {
            return Some(addr);
        }
    }
    None
}

async fn wait_answering(port: u16, budget: Duration) -> Option<SocketAddr> {
    let deadline = tokio::time::Instant::now() + budget;
    loop {
        if let Some(addr) = answering(port).await {
            return Some(addr);
        }
        if tokio::time::Instant::now() >= deadline {
            return None;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

fn validate(request: &ShareRequest, endpoint_port: Option<u16>) -> Result<Vec<u16>, ToolError> {
    let mut seen = BTreeSet::new();
    let ports: Vec<u16> = request
        .ports
        .iter()
        .copied()
        .filter(|port| seen.insert(*port))
        .collect();
    if ports.is_empty() {
        return Err(ToolError::Invalid("Give at least one port to share.".into()));
    }
    if ports.len() > MAX_PORTS_PER_SHARE {
        return Err(ToolError::Invalid(format!(
            "Share at most {MAX_PORTS_PER_SHARE} ports at once."
        )));
    }
    if let Some(port) = ports
        .iter()
        .find(|p| **p == 0 || Some(**p) == endpoint_port)
    {
        return Err(ToolError::Invalid(format!("Port {port} cannot be shared.")));
    }
    Ok(ports)
}

fn ends(expires_ms: Option<i64>, owner: &OwnerView) -> String {
    match (expires_ms, owner.kind, owner.conversation.is_some()) {
        (None, _, _) => "when the user stops sharing it".into(),
        (Some(_), OwnerKind::Agent, true) => {
            "when this conversation's harness stops, or in 24 hours".into()
        },
        (Some(_), _, _) => "when its owner stops, or in 24 hours".into(),
    }
}

/// The result shape for `share`.
pub fn shared(share: ShareView) -> Shared {
    let first = share
        .ports
        .first()
        .map(|port| port.port)
        .unwrap_or_default();
    let key = share.first_key().unwrap_or_default().to_string();
    Shared {
        on_this_machine: format!("http://localhost:{first}{}", share.path),
        open: open_link(&key, &share.path),
        ends: ends(share.expires_ms, &share.owner),
        share,
    }
}

/// Share `request.ports` for `caller`. `Ok(Err(_))` is a pending result the
/// caller repeats.
pub async fn share(
    caller: &Caller,
    request: ShareRequest,
) -> Result<Result<Shared, Pending>, ToolError> {
    let endpoint_port = {
        let state = state::lock();
        if !state.hosting {
            return Err(ToolError::NotHosting);
        }
        if !state.settings.enabled && !caller.is_user() {
            return Err(ToolError::Off);
        }
        state.settings.port
    };
    let ports = validate(&request, endpoint_port)?;
    let key = caller.key();
    if let Some(done) = existing(&ports, &key) {
        return Ok(Ok(shared(done)));
    }
    let new: Vec<u16> = {
        let state = state::lock();
        ports
            .iter()
            .copied()
            .filter(|port| state.share_with_port(*port).is_none())
            .collect()
    };
    if new.is_empty() {
        // Shared by a concurrent call between the two looks.
        return existing(&ports, &key)
            .map(|view| Ok(shared(view)))
            .ok_or_else(|| ToolError::NotFound("The share".into()));
    }
    let budget = request
        .wait_ready_seconds
        .map(Duration::from_secs)
        .unwrap_or(Duration::from_secs(10))
        .min(MAX_READY_WAIT);
    let Some(first) = wait_answering(new[0], budget).await else {
        return Ok(Err(Pending::WaitingForPort(new[0])));
    };
    let mut addrs = vec![(new[0], first)];
    for port in &new[1..] {
        let addr = answering(*port)
            .await
            .unwrap_or_else(|| SocketAddr::from(([127, 0, 0, 1], *port)));
        addrs.push((*port, addr));
    }
    let title = request
        .title
        .as_deref()
        .map(bounded)
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| format!("Port {}", ports[0]));
    if !caller.is_user() {
        let asked = consent::admit(caller, &key, &title, &new).await?;
        if let Err(pending) = asked {
            return Ok(Err(pending));
        }
    }
    let id = reserve(caller, &key, title, clean_path(request.path.as_deref()), &addrs)?;
    publish_reserved(&id).await?;
    let view = state::lock()
        .shares
        .iter()
        .find(|share| share.id == id)
        .map(Share::view)
        .ok_or_else(|| ToolError::NotFound("The share".into()))?;
    tracing::info!(share = %id, owner = %view.owner.label, ports = ?ports, "shared ports");
    Ok(Ok(shared(view)))
}

/// A share that already covers every requested port (shared again: same
/// answer).
fn existing(ports: &[u16], key: &OwnerKey) -> Option<ShareView> {
    let state = state::lock();
    let holders: Vec<&Share> = ports
        .iter()
        .map(|port| state.share_with_port(*port))
        .collect::<Option<Vec<_>>>()?;
    holders
        .iter()
        .find(|share| share.key.as_ref() == Some(key))
        .or_else(|| holders.first())
        .map(|share| share.view())
}

fn reserve(
    caller: &Caller,
    key: &OwnerKey,
    title: String,
    path: String,
    addrs: &[(u16, SocketAddr)],
) -> Result<String, ToolError> {
    let device = runtime::device_id().map_err(|e| ToolError::Relay(format!("{e:#}")))?;
    let mut state = state::lock();
    let wanted = addrs;
    let addrs: Vec<(u16, SocketAddr)> = wanted
        .iter()
        .copied()
        .filter(|(port, _)| state.share_with_port(*port).is_none())
        .collect();
    if addrs.is_empty() {
        // A concurrent call shared them meanwhile.
        return wanted
            .first()
            .and_then(|(port, _)| state.share_with_port(*port))
            .map(|share| share.id.clone())
            .ok_or_else(|| ToolError::NotFound("The share".into()));
    }
    if state.shared_ports() + addrs.len() > MAX_SHARED_PORTS {
        return Err(ToolError::Invalid(format!(
            "This device already shares {} ports; stop one first (at most {MAX_SHARED_PORTS}).",
            state.shared_ports()
        )));
    }
    let ports = addrs.iter().map(|(port, addr)| SharedPort {
        port: *port,
        key: ServiceId::new(&device, ServiceKind::Port, port.to_string()).key(),
        addr: *addr,
        published: None,
        epoch: 0,
        reachable: true,
    });
    // The same owner sharing more ports extends its share.
    let id = if let Some(share) = state
        .shares
        .iter_mut()
        .find(|share| share.key.as_ref() == Some(key))
    {
        share.ports.extend(ports);
        share.id.clone()
    } else {
        let owner = caller.owner();
        let user = caller.is_user();
        let id = uuid::Uuid::new_v4().simple().to_string()[..10].to_string();
        state.shares.push(Share {
            id: id.clone(),
            title,
            path,
            owner,
            key: (!user).then(|| key.clone()),
            created_ms: now_ms(),
            expires_ms: (!user).then(|| now_ms() + AGENT_LEASE_MS),
            ports: ports.collect(),
        });
        id
    };
    state.save_shares();
    state::changed(&mut state);
    Ok(id)
}

/// Publish every unpublished port of share `id`.
async fn publish_reserved(id: &str) -> Result<(), ToolError> {
    let todo: Vec<(u16, String, SocketAddr)> = state::lock()
        .shares
        .iter()
        .filter(|share| share.id == id)
        .flat_map(|share| share.ports.iter())
        .filter(|port| port.published.is_none())
        .map(|port| (port.port, port.key.clone(), port.addr))
        .collect();
    for (port, key, addr) in todo {
        match publish(&key, addr).await {
            Ok(Some((published, epoch))) => store(id, port, published, epoch),
            Ok(None) => {},
            Err(error) => {
                remove_port(id, port);
                return Err(error);
            },
        }
    }
    Ok(())
}

async fn publish(key: &str, addr: SocketAddr) -> Result<Option<(Published, u64)>, ToolError> {
    let owned = transport::resolve_owned()
        .await
        .map_err(|e| ToolError::Relay(format!("{e:#}")))?;
    let options = RegisterOptions {
        key: owned.transport.relay_key(key),
        local_addr: addr.to_string(),
        codec: true,
    };
    match publish_pending(&owned.transport.session, options).await {
        Ok((published, _)) => Ok(Some((published, owned.epoch))),
        Err(PublishError::Conflict {
            ..
        }) => Err(ToolError::Conflict(
            "Another POCOX process publishes this port under the same device name; stop it or \
             give one of them another device name."
                .into(),
        )),
        Err(PublishError::Other(error)) => {
            tracing::warn!(%key, "sharing will retry: {error:#}");
            Ok(None)
        },
    }
}

fn store(id: &str, port: u16, published: Published, epoch: u64) {
    let mut state = state::lock();
    let slot = state
        .shares
        .iter_mut()
        .filter(|share| share.id == id)
        .flat_map(|share| share.ports.iter_mut())
        .find(|p| p.port == port && p.published.is_none());
    match slot {
        Some(slot) => {
            slot.published = Some(published);
            slot.epoch = epoch;
            state::changed(&mut state);
        },
        // Stopped while publishing: release it.
        None => {
            drop(state);
            runtime::runtime().spawn(async move {
                let _ = published.stop().await;
            });
        },
    }
}

fn remove_port(id: &str, port: u16) {
    let mut state = state::lock();
    for share in state.shares.iter_mut().filter(|share| share.id == id) {
        share.ports.retain(|p| p.port != port);
    }
    state.shares.retain(|share| !share.ports.is_empty());
    state.save_shares();
    state::changed(&mut state);
}

/// Release registrations in the background.
pub fn release(ports: Vec<SharedPort>) {
    let published: Vec<Published> = ports.into_iter().filter_map(|p| p.published).collect();
    if published.is_empty() {
        return;
    }
    runtime::runtime().spawn(async move {
        for registration in published {
            if let Err(error) = registration.stop().await {
                tracing::warn!("releasing a shared port failed: {error:#}");
            }
        }
    });
}

/// End the share `target` names (its id, a port number or a port's key).
/// An agent ends only its own; `None` is the user.
pub fn stop(caller: Option<&Caller>, target: &str) -> Result<ShareView, ToolError> {
    let target = target.trim();
    let mut state = state::lock();
    let index = state
        .shares
        .iter()
        .position(|share| {
            share.id == target
                || share
                    .ports
                    .iter()
                    .any(|p| p.key == target || p.port.to_string() == target)
        })
        .ok_or_else(|| ToolError::NotFound(format!("The share `{}`", bounded(target))))?;
    if let Some(caller) = caller.filter(|c| !c.is_user()) {
        let mine = state.shares[index]
            .key
            .as_ref()
            .is_some_and(|key| key.token == caller.principal.id);
        if !mine {
            return Err(ToolError::NotOwner);
        }
    }
    let share = state.shares.remove(index);
    let view = share.view();
    state.save_shares();
    state::changed(&mut state);
    drop(state);
    release(share.ports);
    tracing::info!(share = %view.id, "stopped sharing");
    Ok(view)
}

/// Keep a share until the user stops it (no owner lifetime, no expiry).
pub fn keep(id: &str) -> Result<ShareView, ToolError> {
    let mut state = state::lock();
    let share = state
        .shares
        .iter_mut()
        .find(|share| share.id == id)
        .ok_or_else(|| ToolError::NotFound(format!("The share `{}`", bounded(id))))?;
    share.key = None;
    share.expires_ms = None;
    let view = share.view();
    state.save_shares();
    state::changed(&mut state);
    Ok(view)
}

/// End every share whose owner `ended` selects.
pub fn end_owned(ended: impl Fn(&OwnerKey) -> bool) {
    let mut state = state::lock();
    let (gone, kept): (Vec<Share>, Vec<Share>) = std::mem::take(&mut state.shares)
        .into_iter()
        .partition(|share| share.key.as_ref().is_some_and(&ended));
    state.shares = kept;
    if gone.is_empty() {
        return;
    }
    state.save_shares();
    state::changed(&mut state);
    drop(state);
    for share in gone {
        tracing::info!(share = %share.id, "share ended with its owner");
        release(share.ports);
    }
}

/// Restore the shares saved before a restart (published by [`maintain`]).
pub fn restore(saved: Vec<state::SavedShare>) {
    let Ok(device) = runtime::device_id() else { return };
    let now = now_ms();
    let mut state = state::lock();
    for share in saved {
        if share.expires_ms.is_some_and(|at| at <= now) || share.ports.is_empty() {
            continue;
        }
        let ports = share
            .ports
            .iter()
            .filter(|port| state.share_with_port(**port).is_none())
            .map(|port| SharedPort {
                port: *port,
                key: ServiceId::new(&device, ServiceKind::Port, port.to_string()).key(),
                addr: SocketAddr::from(([127, 0, 0, 1], *port)),
                published: None,
                epoch: 0,
                reachable: false,
            })
            .collect::<Vec<_>>();
        if ports.is_empty() {
            continue;
        }
        state.shares.push(Share {
            id: share.id,
            title: bounded(&share.title),
            path: clean_path(Some(&share.path)),
            owner: share.owner,
            key: None,
            created_ms: share.created_ms,
            expires_ms: share.expires_ms,
            ports,
        });
    }
    state::changed(&mut state);
}

/// One maintenance pass: expire, re-publish and (with `probe`) re-check
/// listeners.
pub async fn maintain(probe: bool) {
    let now = now_ms();
    let expired: Vec<Share> = {
        let mut state = state::lock();
        let (gone, kept): (Vec<Share>, Vec<Share>) = std::mem::take(&mut state.shares)
            .into_iter()
            .partition(|share| share.expires_ms.is_some_and(|at| at <= now));
        state.shares = kept;
        if !gone.is_empty() {
            state.save_shares();
            state::changed(&mut state);
        }
        gone
    };
    for share in expired {
        tracing::info!(share = %share.id, "share expired");
        release(share.ports);
    }
    let stale: Vec<(String, u16, String, SocketAddr)> = {
        let mut state = state::lock();
        let mut stale = Vec::new();
        let mut released = Vec::new();
        for share in &mut state.shares {
            for port in &mut share.ports {
                let moved = port.published.is_some() && !transport::is_current(port.epoch);
                let failed = port
                    .published
                    .as_ref()
                    .is_some_and(|p| p.failure().is_some());
                if moved || failed {
                    released.extend(port.published.take());
                }
                if port.published.is_none() {
                    stale.push((share.id.clone(), port.port, port.key.clone(), port.addr));
                }
            }
        }
        drop(state);
        for registration in released {
            runtime::runtime().spawn(async move {
                let _ = registration.stop().await;
            });
        }
        stale
    };
    for (id, port, key, addr) in stale {
        match publish(&key, addr).await {
            Ok(Some((published, epoch))) => store(&id, port, published, epoch),
            Ok(None) => {},
            Err(error) => tracing::warn!(%key, "a shared port could not be published: {error}"),
        }
    }
    if probe {
        recheck().await;
    }
}

async fn recheck() {
    let ports: Vec<(String, u16, SocketAddr, bool)> = state::lock()
        .shares
        .iter()
        .flat_map(|share| {
            share
                .ports
                .iter()
                .map(|p| (share.id.clone(), p.port, p.addr, p.reachable))
        })
        .collect();
    for (id, port, addr, was) in ports {
        let now = answering(port).await;
        let reachable = now.is_some();
        // A server restarted on the other loopback family is published again.
        let moved = now.filter(|found| *found != addr);
        if reachable == was && moved.is_none() {
            continue;
        }
        let released = {
            let mut state = state::lock();
            let mut released = None;
            if let Some(slot) = state
                .shares
                .iter_mut()
                .filter(|share| share.id == id)
                .flat_map(|share| share.ports.iter_mut())
                .find(|p| p.port == port)
            {
                slot.reachable = reachable;
                if let Some(found) = moved {
                    slot.addr = found;
                    released = slot.published.take();
                }
            }
            state::changed(&mut state);
            released
        };
        if let Some(registration) = released {
            let _ = registration.stop().await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requests_name_real_ports_only() {
        let request = |ports: Vec<u16>| ShareRequest {
            ports,
            ..ShareRequest::default()
        };
        assert_eq!(validate(&request(vec![5173, 5173, 8000]), None), Ok(vec![5173, 8000]));
        assert!(validate(&request(vec![]), None).is_err());
        assert!(validate(&request(vec![0]), None).is_err());
        assert!(validate(&request(vec![17863]), Some(17863)).is_err());
        assert!(validate(&request(vec![1, 2, 3, 4, 5]), None).is_err());
    }
}
