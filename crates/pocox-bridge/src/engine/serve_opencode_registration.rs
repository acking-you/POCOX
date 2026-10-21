//! Publication tickets bind the host incarnation, account/relay context and
//! slot revision. Late publication cannot revive a removed or replaced host.
use super::*;

fn slot(host: &mut Serving, kind: ServiceKind) -> Result<&mut Slot> {
    match kind {
        ServiceKind::OpenCode => Ok(&mut host.register),
        ServiceKind::Meta => Ok(&mut host.meta_register),
        _ => bail!("an OpenCode host has no `{kind}` service"),
    }
}
fn withdraw(published: Option<Published>) {
    if let Some(published) = published {
        if let Err(error) = runtime::runtime().block_on(published.stop()) {
            tracing::warn!(%error, "releasing an OpenCode relay key failed");
        }
    }
}
pub(in crate::engine) fn deregister(name: &str, kind: &str) -> Result<()> {
    let kind = kind.parse().map_err(|_| anyhow!("invalid service kind"))?;
    let published = {
        let mut registry = hosts();
        let host = registry
            .hosts
            .get_mut(name)
            .ok_or_else(|| anyhow!("host not found"))?;
        let slot = slot(host, kind)?;
        slot.revision += 1;
        slot.published.take()
    };
    withdraw(published);
    Ok(())
}
pub(in crate::engine) fn reregister(name: &str, kind: &str) -> Result<()> {
    let kind: ServiceKind = kind.parse().map_err(|_| anyhow!("invalid service kind"))?;
    let (device, local, incarnation, context, revision) = {
        let mut registry = hosts();
        if registry.closing {
            bail!("the app is quitting");
        }
        let host = registry
            .hosts
            .get_mut(name)
            .ok_or_else(|| anyhow!("host not found"))?;
        ensure!(!host.stopped, "OpenCode is stopping");
        let (device, local, incarnation, context) = (
            host.device.clone(),
            if kind == ServiceKind::Meta { host.meta } else { host.local },
            host.host.info().identity.host_id,
            host.context.clone(),
        );
        let slot = slot(host, kind)?;
        if !host_services::needs_publishing(&slot.published) {
            return Ok(());
        }
        (device, local, incarnation, context, slot.revision)
    };
    let owned = transport::resolve_owned_blocking()?;
    ensure!(
        transport::Context::of(&owned.transport) == context,
        "the account or relay changed; restart this OpenCode host"
    );
    let published = host_services::register_service(&owned.transport, &device, kind, name, local)?;
    let refused = {
        let mut registry = hosts();
        let closing = registry.closing;
        match registry.hosts.get_mut(name) {
            Some(host)
                if !closing
                    && !host.stopped
                    && host.host.info().identity.host_id == incarnation
                    && host.context == context
                    && transport::is_current(owned.epoch) =>
            {
                let slot = slot(host, kind)?;
                if slot.revision == revision {
                    slot.revision += 1;
                    std::mem::replace(&mut slot.published, published)
                } else {
                    published
                }
            },
            _ => published,
        }
    };
    withdraw(refused);
    Ok(())
}
pub(super) fn recover() {
    static LAST: Mutex<Option<Instant>> = Mutex::new(None);
    {
        let mut last = LAST.lock().unwrap_or_else(|error| error.into_inner());
        if last.is_some_and(|last| last.elapsed() < Duration::from_secs(30)) {
            return;
        }
        *last = Some(Instant::now());
    }
    let names: Vec<_> = hosts().hosts.keys().cloned().collect();
    for name in names {
        let _ = reregister(&name, "opencode");
        let _ = reregister(&name, "meta");
    }
}
