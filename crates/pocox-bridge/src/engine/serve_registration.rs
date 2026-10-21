//! Relay registrations of native hosts: unpublish and re-publish one service,
//! and the rate-limited self-healing re-publication run by status polls.

use super::*;

/// Re-publish whichever of `name`'s three services are not currently published.
///
/// Errors only on a name CONFLICT, which is the one condition a caller must act
/// on: the local host stays up either way, but a name another device owns can
/// never publish, so a re-host under it has to say so rather than report
/// success.
///
/// Takes the hosts lock only to read what needs publishing and to store the
/// results — never across the relay round trip, which would stall status polls.
pub(super) fn republish_dropped(name: &str) -> Result<()> {
    let Some((device, pending)) = ({
        let guard = hosts_locked();
        guard.get(name).map(|ls| {
            let pending: Vec<(ServiceKind, SocketAddr)> = [
                (ServiceKind::App, ls.app_local, &ls.app_register),
                (ServiceKind::Api, ls.api_local, &ls.api_register),
                (ServiceKind::Meta, ls.meta_local, &ls.meta_register),
            ]
            .into_iter()
            .filter(|(_, _, slot)| needs_publishing(slot))
            .map(|(kind, local, _)| (kind, local))
            .collect();
            (ls.device.clone(), pending)
        })
    }) else {
        return Ok(());
    };
    if pending.is_empty() {
        return Ok(());
    }
    let transport = transport::resolve_blocking()?;

    let mut conflict = None;
    for (kind, local) in pending {
        // Drop the refused registration BEFORE publishing again, so the relay
        // releases the old key and the fresh publish is not competing with its
        // own predecessor for the name.
        take_registration(name, kind);
        let published = match register_service(&transport, &device, kind, name, local) {
            Ok(published) => published,
            Err(err) => {
                // Keep going: a conflict on one kind (typically `app`) should not
                // leave the other two unpublished, and the caller wants the app
                // conflict reported once everything else is up.
                conflict = conflict.or(Some(err));
                continue;
            },
        };
        store_registration(name, kind, published);
    }
    match conflict {
        Some(err) => Err(err),
        None => Ok(()),
    }
}

/// Take a host's registration for `kind` out of the map and drop it, releasing
/// the relay key. No-op for an unknown host.
fn take_registration(name: &str, kind: ServiceKind) {
    let mut guard = hosts_locked();
    if let Some(ls) = guard.get_mut(name) {
        *registration_slot(ls, kind) = None;
    }
}

/// Store a freshly published registration, or clear the slot when publishing
/// did not produce one. Drops it immediately if the host vanished while we
/// published.
fn store_registration(name: &str, kind: ServiceKind, published: Option<Published>) {
    let mut guard = hosts_locked();
    match guard.get_mut(name) {
        Some(ls) => *registration_slot(ls, kind) = published,
        // The host was stopped while we were publishing; unpublish rather than
        // leaving a key on the relay with nothing behind it.
        None => drop(published),
    }
}

fn registration_slot(ls: &mut LocalServe, kind: ServiceKind) -> &mut Option<Published> {
    match kind {
        ServiceKind::Api => &mut ls.api_register,
        ServiceKind::Meta => &mut ls.meta_register,
        // `App` and any future kind share the app slot: a host publishes exactly
        // these three, and routing an unknown kind here is better than panicking
        // in a code path that holds the hosts lock.
        _ => &mut ls.app_register,
    }
}

/// Re-publish every host's permanently-refused services, quietly.
///
/// The self-healing half of [`serve_status`]. Best-effort by construction: it
/// cannot report to anyone, so a failure just leaves the service unpublished
/// for the next tick to retry. Rate-limited because status is polled often and
/// each attempt is a relay round trip — without that, a relay that is down
/// would turn a 1 Hz UI poll into a 1 Hz publish storm, which is the shape of
/// the 2026-07-07 outage.
pub(super) fn republish_refused() {
    static LAST: Mutex<Option<Instant>> = Mutex::new(None);
    /// Minimum gap between recovery sweeps.
    const RECOVERY_INTERVAL: Duration = Duration::from_secs(30);

    {
        let mut last = LAST.lock().unwrap_or_else(|poison| poison.into_inner());
        if last.is_some_and(|at| at.elapsed() < RECOVERY_INTERVAL) {
            return;
        }
        *last = Some(Instant::now());
    }

    let names: Vec<String> = hosts_locked()
        .values()
        .filter(|ls| {
            needs_publishing(&ls.app_register)
                || needs_publishing(&ls.api_register)
                || needs_publishing(&ls.meta_register)
        })
        .map(|ls| ls.name.clone())
        .collect();
    for name in names {
        if let Err(err) = republish_dropped(&name) {
            tracing::debug!(
                service = %name,
                error = %format!("{err:#}"),
                "re-publishing a refused service failed; will retry"
            );
        }
    }
}

/// Take one service (`kind` = `"app"`/`"api"`/`"meta"`) off the relay without
/// stopping the host. Reversible via [`serve_reregister`].
///
/// Dropping the registration IS the deregistration now, and it releases the
/// relay key as it goes. It used to need a `DELETE /v1/services` on top,
/// because the local end of the tunnel was a task the app could abort while the
/// BACKEND still held the relay-side registration open — so the key lingered
/// until its lease expired unless the backend was asked to retire it. With the
/// app registering directly there is no second party holding anything.
pub fn serve_deregister(name: &str, kind: &str) -> Result<()> {
    if crate::engine::serve_opencode::is_hosting(name) {
        return crate::engine::serve_opencode::deregister(name, kind);
    }
    if crate::engine::serve_acp::is_hosting(name) {
        return crate::engine::serve_acp::deregister(name, kind);
    }
    let kind: ServiceKind = kind
        .parse()
        .map_err(|_| anyhow!("invalid service kind `{kind}`"))?;
    let published = {
        let mut guard = hosts_locked();
        let ls = guard
            .get_mut(name)
            .ok_or_else(|| anyhow!("`{name}` is not hosting locally"))?;
        registration_slot(ls, kind).take()
    };
    // Awaited outside the hosts lock, and awaited rather than dropped, so the
    // relay frees the key before a re-register could race its own predecessor.
    if let Some(published) = published {
        if let Err(e) = runtime::runtime().block_on(published.stop()) {
            tracing::warn!(
                error = %format!("{e:#}"),
                service = %name,
                kind = %kind.as_key_segment(),
                "releasing the relay key on deregister failed; it lingers until lease expiry"
            );
        }
    }
    Ok(())
}

/// Re-publish a previously [`serve_deregister`]'d service, forwarding to the
/// still-running process. No-op if already published.
pub fn serve_reregister(name: &str, kind: &str) -> Result<()> {
    if crate::engine::serve_opencode::is_hosting(name) {
        return crate::engine::serve_opencode::reregister(name, kind);
    }
    if crate::engine::serve_acp::is_hosting(name) {
        return crate::engine::serve_acp::reregister(name, kind);
    }
    let kind: ServiceKind = kind
        .parse()
        .map_err(|_| anyhow!("invalid service kind `{kind}`"))?;
    let Some((device, local)) = ({
        let guard = hosts_locked();
        let ls = guard
            .get(name)
            .ok_or_else(|| anyhow!("`{name}` is not hosting locally"))?;
        let (local, slot) = match kind {
            ServiceKind::Api => (ls.api_local, &ls.api_register),
            ServiceKind::Meta => (ls.meta_local, &ls.meta_register),
            _ => (ls.app_local, &ls.app_register),
        };
        needs_publishing(slot).then(|| (ls.device.clone(), local))
    }) else {
        return Ok(());
    };
    // Publishing waits on the relay, so it happens with the hosts lock RELEASED —
    // holding it would stall every status poll for as long as the relay takes.
    let transport = transport::resolve_blocking()?;
    let published = register_service(&transport, &device, kind, name, local)?;
    store_registration(name, kind, published);
    Ok(())
}
