//! Automatic original-session admission over the provider-neutral host API.

use pocox_host_svc::session_access::SessionAccess;

use super::*;

fn accept(
    link: &Link,
    expected: &Identity,
    session: &str,
    access: SessionAccess,
) -> Result<SessionAccess> {
    if access.session_id != session
        || Some(access.host_id.as_str()) != expected.host_id.as_deref()
        || Some(access.generation) != expected.generation
    {
        bail!("session access identity changed");
    }
    link.commit(expected, |_| ()).ok_or_else(ops::superseded)?;
    Ok(access)
}

/// Inspect fresh native ownership without loading another writer.
pub fn session_access(service: &str, session: &str) -> Result<SessionAccess> {
    let link = conn(service)?;
    let identity = link.identity();
    let access = block(link.client.session_access(session, &identity))?;
    accept(&link, &identity, session, access)
}

/// Open the exact original session, or retain its follow-only view.
pub fn session_open(service: &str, session: &str) -> Result<SessionAccess> {
    let link = conn(service)?;
    let identity = link.identity();
    let access = block(link.client.session_open(session, &identity))?;
    let access = accept(&link, &identity, session, access)?;
    if access.mode == "write" {
        let body = block(link.client.open_session(session, Some(&identity)))?;
        ops::accept_history(&link, &identity, &body, |view| {
            view.sessions.insert(session.into(), body.clone());
        })?;
    }
    Ok(access)
}

/// Close only the idle writer shown by the supplied host/source snapshot.
pub fn session_release(service: &str, snapshot: &SessionAccess) -> Result<SessionAccess> {
    release_on_link(&conn(service)?, snapshot)
}

pub(super) fn release_on_link(link: &Link, snapshot: &SessionAccess) -> Result<SessionAccess> {
    let identity = Identity {
        host_id: Some(snapshot.host_id.clone()),
        generation: Some(snapshot.generation),
    };
    link.commit(&identity, |_| ()).ok_or_else(ops::superseded)?;
    let access = block(link.client.session_release(snapshot))?;
    let access = accept(link, &identity, &snapshot.session_id, access)?;
    link.commit(&identity, |view| {
        view.sessions.remove(&snapshot.session_id);
    })
    .ok_or_else(ops::superseded)?;
    Ok(access)
}
