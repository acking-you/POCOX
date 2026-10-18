//! Sharing loopback ports of this device with the user's other devices.
//!
//! ```text
//!   share ─► check ports answer ─► consent (agents) ─► reserve ─► publish
//!                                                         │
//!   maintain (every tick): expire leases, schedule publications, re-check
//! ```
//!
//! A share is reserved in the table before it is published, so a repeated or
//! concurrent call sees it and returns it instead of publishing twice. Each
//! port has at most one publication in flight, and the supervisor only
//! schedules them: it never waits for the relay itself.

use std::{
    collections::BTreeSet,
    net::{Ipv6Addr, SocketAddr},
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};

use pocket_codex_core::service::{ServiceId, ServiceKind};
use pocket_codex_pb::{publish_pending, PublishError, Published, RegisterOptions};
use tokio::net::TcpStream;

use super::{
    consent,
    error::{Pending, ToolError},
    model::{
        bounded, clean_path, open_link, scheme, OwnerKind, OwnerView, ShareView, Shared,
        AGENT_LEASE_MS, APP_PORT, CLI_PORT, MAX_PORTS_PER_SHARE, MAX_SHARED_PORTS,
    },
    state::{self, now_ms, OwnerKey, Share, SharedPort, State},
    tokens::{Kind, Principal},
};
use crate::engine::{management, runtime, transport};

/// Longest wait for a port to answer within one call.
const MAX_READY_WAIT: Duration = Duration::from_secs(20);

/// Pause before publishing again after the relay could not be reached.
const RETRY_MS: i64 = 15_000;

/// Pause before publishing again after the relay refused a registration.
const REFUSED_RETRY_MS: i64 = 60_000;

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

    /// What keeps its shares alive, and what owns them.
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
    /// The page is served over TLS (opened with `https`).
    pub secure: bool,
    /// Only while the account or relay stays the one the request was
    /// admitted under (a request from another device's management entry).
    pub epoch: Option<u64>,
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

fn port_of(addr: &str) -> Option<u16> {
    addr.trim_end_matches('/').rsplit(':').next()?.parse().ok()
}

/// Ports POCOX listens on itself: the tools endpoints, its hosts' listeners,
/// its management entry and its tunnels to other devices. Those are reachable
/// as services already; shared as a plain port, one would hand an agent host
/// or a management entry to whoever connects.
fn own_ports() -> BTreeSet<u16> {
    let mut ports: BTreeSet<u16> = runtime::list_subscriptions()
        .iter()
        .filter_map(|subscription| port_of(&subscription.local_addr))
        .collect();
    ports.extend(
        management::local_status()
            .ok()
            .and_then(|status| status.listen_addr)
            .as_deref()
            .and_then(port_of),
    );
    let state = state::lock();
    ports.extend([APP_PORT, CLI_PORT]);
    ports.extend(state.settings.port);
    ports.extend(state.endpoint.as_deref().and_then(port_of));
    drop(state);
    // Read live, not from the supervisor's last pass: a host may have bound
    // its listeners just now.
    ports.extend(crate::engine::serve::listen_ports());
    ports.extend(crate::engine::serve_acp::listen_ports());
    ports.extend(crate::engine::serve_opencode::listen_ports());
    ports
}

fn validate(request: &ShareRequest, own: &BTreeSet<u16>) -> Result<Vec<u16>, ToolError> {
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
    if ports.contains(&0) {
        return Err(ToolError::Invalid("Port 0 cannot be shared.".into()));
    }
    if let Some(port) = ports.iter().find(|port| own.contains(port)) {
        return Err(ToolError::Invalid(format!(
            "Port {port} belongs to POCOX itself; its services are already reachable from the \
             user's devices."
        )));
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
        on_this_machine: format!("{}://localhost:{first}{}", scheme(share.secure), share.path),
        open: open_link(&key, &share.path, share.secure),
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
    {
        let state = state::lock();
        if !state.hosting {
            return Err(ToolError::NotHosting);
        }
        state.admits(caller)?;
    }
    let ports = validate(&request, &own_ports())?;
    let key = caller.key();
    if existing(&ports).is_some() {
        // Shared already: the same answer, and the user's ask makes those
        // shares theirs.
        if caller.is_user() {
            take_over(&mut state::lock(), &ports, caller)?;
        }
        return existing(&ports)
            .map(|done| Ok(shared(done)))
            .ok_or_else(|| ToolError::NotFound("The share".into()));
    }
    refuse_split(&state::lock(), caller, &key, &ports)?;
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
        return existing(&ports)
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
    // The waits above can be long: a POCOX listener may have taken a port.
    let own = own_ports();
    if let Some(port) = new.iter().find(|port| own.contains(port)) {
        return Err(ToolError::Invalid(format!(
            "Port {port} now belongs to POCOX itself; it cannot be shared."
        )));
    }
    if caller.is_user() {
        // Only now that every port answers: a call still waiting for a port
        // changes nothing.
        take_over(&mut state::lock(), &ports, caller)?;
    }
    let page = Page {
        port: ports[0],
        title,
        path: clean_path(request.path.as_deref()),
        secure: request.secure,
    };
    let (id, reserved) = reserve(caller, &key, page, &addrs, request.epoch)?;
    publish_reserved(&id, &reserved, request.epoch).await?;
    if caller.is_user() {
        confirm(&id, &reserved)?;
    }
    // The answer describes the page: the share holding the first port, even
    // when this call only added its other ports.
    let view = existing(&ports)
        .or_else(|| {
            state::lock()
                .shares
                .iter()
                .find(|s| s.id == id)
                .map(Share::view)
        })
        .ok_or_else(|| ToolError::NotFound("The share".into()))?;
    tracing::info!(share = %id, owner = %view.owner.label, ports = ?ports, "shared ports");
    Ok(Ok(shared(view)))
}

/// A page and its other ports stay one share, the one opening the page
/// connects: a requested port another share holds apart from the page, or
/// (for an agent) a page someone else shares, cannot take new ports.
fn refuse_split(
    state: &State,
    caller: &Caller,
    key: &OwnerKey,
    ports: &[u16],
) -> Result<(), ToolError> {
    let page = state.share_with_port(ports[0]);
    if let Some(page) = page.filter(|share| !caller.is_user() && share.key.as_ref() != Some(key)) {
        return Err(ToolError::Invalid(format!(
            "Port {} is already shared by {}; share the other ports in a call of their own.",
            ports[0], page.owner.label
        )));
    }
    let page = page.map(|share| share.id.as_str());
    if let Some(port) = ports[1..].iter().find(|port| {
        state
            .share_with_port(**port)
            .is_some_and(|holder| Some(holder.id.as_str()) != page)
    }) {
        return Err(ToolError::Invalid(format!(
            "Port {port} is already shared apart from port {}; stop that share, or share these \
             ports in calls of their own.",
            ports[0]
        )));
    }
    Ok(())
}

/// The user sharing ports an agent shares makes those shares the user's: no
/// owner lifetime, no expiry, kept across restarts. Nothing changes unless
/// that is saved.
fn take_over(state: &mut State, ports: &[u16], user: &Caller) -> Result<(), ToolError> {
    let taken: Vec<usize> = state
        .shares
        .iter()
        .enumerate()
        .filter(|(_, share)| {
            share.key.is_some() && share.ports.iter().any(|p| ports.contains(&p.port))
        })
        .map(|(index, _)| index)
        .collect();
    if taken.is_empty() {
        return Ok(());
    }
    let unsaved = state.shares_unsaved;
    let before: Vec<_> = taken
        .iter()
        .map(|&index| {
            let share = &mut state.shares[index];
            let before = (share.key.take(), share.expires_ms.take(), share.owner.clone());
            share.owner = user.owner();
            before
        })
        .collect();
    if state.save_shares().is_err() {
        for (&index, (key, expires_ms, owner)) in taken.iter().zip(before) {
            let share = &mut state.shares[index];
            (share.key, share.expires_ms, share.owner) = (key, expires_ms, owner);
        }
        state.shares_unsaved = unsaved;
        return Err(ToolError::NotSaved);
    }
    state::changed(state);
    Ok(())
}

/// The share that holds the requested page (the first port) when every
/// requested port is shared already: shared again, same answer.
fn existing(ports: &[u16]) -> Option<ShareView> {
    let state = state::lock();
    if !ports
        .iter()
        .all(|port| state.share_with_port(*port).is_some())
    {
        return None;
    }
    state
        .share_with_port(*ports.first()?)
        .map(|share| share.view())
}

/// What a new share shows.
struct Page {
    /// The requested page port (the first).
    port: u16,
    title: String,
    path: String,
    secure: bool,
}

/// Reserve the free ports of `addrs` for `caller`, checking once more that
/// it may act: the call may have waited long for a port or for the user.
/// Returns the share and the ports this call reserved.
fn reserve(
    caller: &Caller,
    key: &OwnerKey,
    page: Page,
    addrs: &[(u16, SocketAddr)],
    epoch: Option<u64>,
) -> Result<(String, Vec<u16>), ToolError> {
    let device = runtime::device_id().map_err(|e| ToolError::Relay(format!("{e:#}")))?;
    let mut state = state::lock();
    if !state.hosting {
        return Err(ToolError::NotHosting);
    }
    state.admits(caller)?;
    if epoch.is_some_and(|epoch| !transport::is_current(epoch)) {
        return Err(ToolError::ContextChanged);
    }
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
            .map(|share| (share.id.clone(), Vec::new()))
            .ok_or_else(|| ToolError::NotFound("The share".into()));
    }
    if state.shared_ports() + addrs.len() > MAX_SHARED_PORTS {
        return Err(ToolError::Invalid(format!(
            "This device already shares {} ports; stop one first (at most {MAX_SHARED_PORTS}).",
            state.shared_ports()
        )));
    }
    let reserved: Vec<u16> = addrs.iter().map(|(port, _)| *port).collect();
    let user = caller.is_user();
    let ports = addrs.iter().map(|(port, addr)| {
        let key = ServiceId::new(&device, ServiceKind::Port, port.to_string()).key();
        // Published by this call, not by the supervisor; the user's is saved
        // once published ([`confirm`]).
        SharedPort {
            publishing: true,
            confirmed: !user,
            ..SharedPort::new(*port, key, *addr, true)
        }
    });
    // More ports join the page's share: the user's share that holds the
    // page, or the agent's own share.
    let joined = if user {
        state.shares.iter().position(|share| {
            share.key.is_none() && share.ports.iter().any(|p| p.port == page.port)
        })
    } else {
        state
            .shares
            .iter()
            .position(|share| share.key.as_ref() == Some(key))
    };
    let id = if let Some(index) = joined {
        let share = &mut state.shares[index];
        share.ports.extend(ports);
        share.id.clone()
    } else {
        let owner = caller.owner();
        let id = uuid::Uuid::new_v4().simple().to_string()[..10].to_string();
        state.shares.push(Share {
            id: id.clone(),
            title: page.title,
            path: page.path,
            secure: page.secure,
            owner,
            key: (!user).then(|| key.clone()),
            created_ms: now_ms(),
            expires_ms: (!user).then(|| now_ms() + AGENT_LEASE_MS),
            ports: ports.collect(),
        });
        id
    };
    state::changed(&mut state);
    Ok((id, reserved))
}

/// Save the user's share `id` now that it is published: it outlives
/// restarts, so the call succeeds only once it is saved. Unsaved, it is
/// withdrawn and the call fails; until then it was never in the file.
fn confirm(id: &str, reserved: &[u16]) -> Result<(), ToolError> {
    let mut state = state::lock();
    let unsaved = state.shares_unsaved;
    let Some(share) = state.shares.iter_mut().find(|share| share.id == id) else {
        // Stopped meanwhile.
        return Ok(());
    };
    for port in share
        .ports
        .iter_mut()
        .filter(|p| reserved.contains(&p.port))
    {
        port.confirmed = true;
    }
    if state.save_shares().is_ok() {
        state::changed(&mut state);
        return Ok(());
    }
    state.shares_unsaved = unsaved;
    drop(state);
    withdraw(id, reserved);
    Err(ToolError::NotSaved)
}

/// Publish the ports of share `id` this call reserved. A failure withdraws
/// all of them, so the call fails as a whole and nothing it asked for stays
/// shared.
async fn publish_reserved(id: &str, reserved: &[u16], epoch: Option<u64>) -> Result<(), ToolError> {
    let todo: Vec<(u16, String, SocketAddr)> = state::lock()
        .shares
        .iter()
        .filter(|share| share.id == id)
        .flat_map(|share| share.ports.iter())
        .filter(|port| reserved.contains(&port.port))
        .map(|port| (port.port, port.key.clone(), port.addr))
        .collect();
    for (port, key, addr) in todo {
        match publish(&key, addr, epoch).await {
            Ok(outcome) => settle(id, port, outcome),
            Err(error) => {
                withdraw(id, reserved);
                return Err(error);
            },
        }
    }
    Ok(())
}

/// Publish `key` for `addr` under the current account or relay, or under
/// `epoch`'s only.
async fn publish(
    key: &str,
    addr: SocketAddr,
    epoch: Option<u64>,
) -> Result<Option<(Published, u64)>, ToolError> {
    let owned = transport::resolve_owned()
        .await
        .map_err(|e| ToolError::Relay(format!("{e:#}")))?;
    if epoch.is_some_and(|epoch| epoch != owned.epoch) {
        return Err(ToolError::ContextChanged);
    }
    let options = RegisterOptions {
        key: owned.transport.relay_key(key),
        local_addr: addr.to_string(),
        codec: true,
    };
    match publish_pending(&owned.transport.session, options).await {
        Ok((published, _)) => {
            // The wait can be long: the account or relay may have changed
            // (the handle is the old one's: a bound request fails, any other
            // is published again), or POCOX itself may now listen on the port.
            let moved = !transport::is_current(owned.epoch);
            let own = own_ports().contains(&addr.port());
            if !moved && !own {
                return Ok(Some((published, owned.epoch)));
            }
            runtime::runtime().spawn(async move {
                let _ = published.stop().await;
            });
            if own {
                Err(ToolError::Invalid(format!(
                    "Port {} now belongs to POCOX itself; it cannot be shared.",
                    addr.port()
                )))
            } else if epoch.is_some() {
                Err(ToolError::ContextChanged)
            } else {
                Ok(None)
            }
        },
        Err(PublishError::Conflict {
            ..
        }) => Err(ToolError::Conflict(
            "Another POCOX process publishes this port under the same device name; stop it or \
             give one of them another device name."
                .into(),
        )),
        Err(PublishError::Other(error)) => {
            tracing::debug!(%key, "sharing will retry: {error:#}");
            Ok(None)
        },
    }
}

/// Record the outcome of the publication in flight for `port` of share `id`.
fn settle(id: &str, port: u16, outcome: Option<(Published, u64)>) {
    let mut state = state::lock();
    let slot = state
        .shares
        .iter_mut()
        .filter(|share| share.id == id)
        .flat_map(|share| share.ports.iter_mut())
        .find(|p| p.port == port && p.publishing);
    match (slot, outcome) {
        (Some(slot), Some((published, epoch))) => {
            slot.publishing = false;
            slot.refused = false;
            slot.retry_at_ms = 0;
            slot.published = Some(published);
            slot.epoch = epoch;
            state::changed(&mut state);
        },
        (Some(slot), None) => {
            slot.publishing = false;
            if slot.retry_at_ms == 0 {
                tracing::warn!(key = %slot.key, "the relay is unreachable; sharing will retry");
            }
            slot.retry_at_ms = now_ms() + RETRY_MS;
        },
        // Stopped while publishing: release it.
        (None, Some((published, _))) => {
            drop(state);
            runtime::runtime().spawn(async move {
                let _ = published.stop().await;
            });
        },
        (None, None) => {},
    }
}

/// Take `ports` out of share `id`, releasing whatever was published.
fn withdraw(id: &str, ports: &[u16]) {
    let mut state = state::lock();
    let mut gone = Vec::new();
    for share in state.shares.iter_mut().filter(|share| share.id == id) {
        let (out, kept): (Vec<SharedPort>, Vec<SharedPort>) = std::mem::take(&mut share.ports)
            .into_iter()
            .partition(|p| ports.contains(&p.port));
        share.ports = kept;
        gone.extend(out);
    }
    state.shares.retain(|share| !share.ports.is_empty());
    let _ = state.save_shares();
    state::changed(&mut state);
    drop(state);
    release(gone);
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
/// An agent ends only what its own conversation shared; `None` is the user.
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
        if state.shares[index].key.as_ref() != Some(&caller.key()) {
            return Err(ToolError::NotOwner);
        }
    }
    let unsaved = state.shares_unsaved;
    let share = state.shares.remove(index);
    // A stopped share that outlives restarts must not come back after one:
    // unless its removal is saved, nothing changes.
    if state.save_shares().is_err() && share.durable() {
        state.shares.insert(index, share);
        state.shares_unsaved = unsaved;
        return Err(ToolError::NotSaved);
    }
    let view = share.view();
    state::changed(&mut state);
    drop(state);
    release(share.ports);
    tracing::info!(share = %view.id, "stopped sharing");
    Ok(view)
}

/// Keep a share until the user stops it (no owner lifetime, no expiry), once
/// that is saved.
pub fn keep(id: &str) -> Result<ShareView, ToolError> {
    let mut state = state::lock();
    let index = state
        .shares
        .iter()
        .position(|share| share.id == id)
        .ok_or_else(|| ToolError::NotFound(format!("The share `{}`", bounded(id))))?;
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
    let _ = state.save_shares();
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
            .map(|port| {
                let key = ServiceId::new(&device, ServiceKind::Port, port.to_string()).key();
                SharedPort::new(*port, key, SocketAddr::from(([127, 0, 0, 1], *port)), false)
            })
            .collect::<Vec<_>>();
        if ports.is_empty() {
            continue;
        }
        state.shares.push(Share {
            id: share.id,
            title: bounded(&share.title),
            path: clean_path(Some(&share.path)),
            secure: share.secure,
            owner: share.owner,
            key: None,
            created_ms: share.created_ms,
            expires_ms: share.expires_ms,
            ports,
        });
    }
    state::changed(&mut state);
}

/// One maintenance pass: expire leases, release what the relay refused or
/// what belongs to an old account or relay, and schedule publications;
/// with `probe`, re-check listeners in the background.
pub fn maintain(probe: bool) {
    let now = now_ms();
    let expired: Vec<Share> = {
        let mut state = state::lock();
        let (gone, kept): (Vec<Share>, Vec<Share>) = std::mem::take(&mut state.shares)
            .into_iter()
            .partition(|share| share.expires_ms.is_some_and(|at| at <= now));
        state.shares = kept;
        if !gone.is_empty() {
            let _ = state.save_shares();
            state::changed(&mut state);
        }
        gone
    };
    for share in expired {
        tracing::info!(share = %share.id, "share expired");
        release(share.ports);
    }
    let mut released = Vec::new();
    let mut todo: Vec<(String, u16, String, SocketAddr)> = Vec::new();
    // A restored share's port can since have been taken by POCOX itself (a
    // host, the management entry, a tunnel): never published while it is.
    let own = if state::lock().shares.is_empty() { BTreeSet::new() } else { own_ports() };
    {
        let mut state = state::lock();
        let mut changed = false;
        for share in &mut state.shares {
            for port in &mut share.ports {
                if own.contains(&port.port) {
                    if let Some(registration) = port.published.take() {
                        released.push(registration);
                        changed = true;
                    }
                    continue;
                }
                let moved = port.published.is_some() && !transport::is_current(port.epoch);
                let refusal = port.published.as_ref().and_then(Published::failure);
                if let Some(why) = &refusal {
                    tracing::warn!(key = %port.key, "the relay refused a shared port: {why}");
                    port.refused = true;
                    port.retry_at_ms = now + REFUSED_RETRY_MS;
                }
                if moved || refusal.is_some() {
                    released.extend(port.published.take());
                    changed = true;
                }
                if port.published.is_none() && !port.publishing && port.retry_at_ms <= now {
                    port.publishing = true;
                    todo.push((share.id.clone(), port.port, port.key.clone(), port.addr));
                }
            }
        }
        if changed {
            state::changed(&mut state);
        }
    }
    for registration in released {
        runtime::runtime().spawn(async move {
            let _ = registration.stop().await;
        });
    }
    for (id, port, key, addr) in todo {
        runtime::runtime().spawn(async move {
            let outcome = publish(&key, addr, None).await.unwrap_or_else(|error| {
                tracing::debug!(%key, "a shared port could not be published: {error}");
                None
            });
            settle(&id, port, outcome);
        });
    }
    static RECHECKING: AtomicBool = AtomicBool::new(false);
    if probe && !RECHECKING.swap(true, Ordering::SeqCst) {
        runtime::runtime().spawn(async {
            recheck().await;
            RECHECKING.store(false, Ordering::SeqCst);
        });
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
    fn requests_name_real_ports_that_are_not_pocox_own() {
        let request = |ports: Vec<u16>| ShareRequest {
            ports,
            ..ShareRequest::default()
        };
        let own = BTreeSet::from([17863, 41000]);
        assert_eq!(validate(&request(vec![5173, 5173, 8000]), &own), Ok(vec![5173, 8000]));
        assert!(validate(&request(vec![]), &own).is_err());
        assert!(validate(&request(vec![0]), &own).is_err());
        assert!(validate(&request(vec![5173, 41000]), &own).is_err());
        assert!(validate(&request(vec![1, 2, 3, 4, 5]), &own).is_err());
    }

    #[test]
    fn the_user_sharing_an_agents_port_makes_that_share_theirs() {
        let mut state = State::default();
        let addr = SocketAddr::from(([127, 0, 0, 1], 5173));
        state.shares.push(Share {
            id: "s1".into(),
            title: "Landing".into(),
            path: "/".into(),
            secure: false,
            owner: Caller::user("agent").owner(),
            key: Some(OwnerKey {
                token: "t1".into(),
                conversation: Some("c1".into()),
            }),
            created_ms: 0,
            expires_ms: Some(1),
            ports: vec![SharedPort::new(5173, "pcx:studio:port:5173".into(), addr, true)],
        });
        take_over(&mut state, &[8000], &Caller::user("You")).expect("nothing to take");
        assert!(state.shares[0].key.is_some(), "other ports are left alone");
        take_over(&mut state, &[5173], &Caller::user("You")).expect("taken");
        let share = &state.shares[0];
        assert!(share.key.is_none() && share.expires_ms.is_none() && share.durable());
    }

    #[test]
    fn a_page_and_its_other_ports_stay_one_share() {
        let addr = |port| SocketAddr::from(([127, 0, 0, 1], port));
        let agent = Caller {
            principal: Principal {
                id: "t1".into(),
                kind: Kind::Hosted,
                label: "Codex".into(),
                harness: Some("codex".into()),
                host: Some("default".into()),
                session: None,
            },
            conversation: Some("c1".into()),
        };
        let share = |id: &str, key: Option<OwnerKey>, port: u16| Share {
            id: id.into(),
            title: "Page".into(),
            path: "/".into(),
            secure: false,
            owner: agent.owner(),
            key,
            created_ms: 0,
            expires_ms: None,
            ports: vec![SharedPort::new(port, format!("pcx:studio:port:{port}"), addr(port), true)],
        };
        let mut state = State::default();
        state.shares.push(share("mine", Some(agent.key()), 5173));
        state.shares.push(share("theirs", None, 8000));
        let user = Caller::user("You");
        // Its own page takes more free ports; a port held apart does not join.
        assert!(refuse_split(&state, &agent, &agent.key(), &[5173, 9000]).is_ok());
        assert!(refuse_split(&state, &agent, &agent.key(), &[5173, 8000]).is_err());
        assert!(refuse_split(&state, &agent, &agent.key(), &[3000, 8000]).is_err());
        // Someone else's page takes no ports from an agent; the user's ask may.
        assert!(refuse_split(&state, &agent, &agent.key(), &[8000, 9000]).is_err());
        assert!(refuse_split(&state, &user, &user.key(), &[8000, 9000]).is_ok());
    }

    #[test]
    fn only_published_ports_of_the_users_shares_are_saved() {
        let addr = |port| SocketAddr::from(([127, 0, 0, 1], port));
        let pending = |port| SharedPort {
            confirmed: false,
            ..SharedPort::new(port, format!("pcx:studio:port:{port}"), addr(port), true)
        };
        let mut share = Share {
            id: "s1".into(),
            title: "Landing".into(),
            path: "/".into(),
            secure: false,
            owner: Caller::user("You").owner(),
            key: None,
            created_ms: 0,
            expires_ms: None,
            ports: vec![pending(5173)],
        };
        assert!(!share.durable(), "a share still publishing is not saved");
        share
            .ports
            .insert(0, SharedPort::new(5173, "pcx:studio:port:5173".into(), addr(5173), true));
        share.ports[1] = pending(8000);
        assert_eq!(share.saved().ports, [5173], "its companion joins once published");
    }
}
