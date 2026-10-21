//! Follow native history through the selected host, without ACP admission.

use pocox_host_svc::sessions::{SessionFollowUpdate, SessionLiveness};

use super::*;

/// Read ownership conservatively from this connection's host and generation.
pub fn native_liveness(service_key: &str, session: &str) -> Result<SessionLiveness> {
    let link = conn(service_key)?;
    let identity = link.identity();
    let body = block(link.client.native_status(
        session,
        identity.host_id.as_deref().unwrap_or(""),
        identity.generation.unwrap_or(0),
    ))?;
    ops::accept_history(&link, &identity, &body, |_| ())?;
    serde_json::from_value(body["liveness"].clone()).context("reading native session ownership")
}

/// Follow source revisions without loading or resuming an external session.
pub async fn follow_native_session<F, Fut>(
    service_key: &str,
    session: &str,
    mut on_update: F,
) -> Result<()>
where
    F: FnMut(SessionFollowUpdate) -> Fut,
    Fut: std::future::Future<Output = bool>,
{
    let link = conn(service_key)?;
    let identity = link.identity();
    let mut stream = link
        .client
        .native_events(
            session,
            identity.host_id.as_deref().unwrap_or(""),
            identity.generation.unwrap_or(0),
        )
        .await?;
    let mut version = None;
    while let Some(body) = stream.next().await {
        let body = body?;
        ops::accept_history(&link, &identity, &body, |_| ())?;
        let update: SessionFollowUpdate =
            serde_json::from_value(body).context("reading native session follow")?;
        if update.liveness.thread_id != session {
            bail!("native session follow returned another session");
        }
        let next = (update.history_revision.clone(), update.liveness.turn_state.clone());
        if update.history_revision.is_some() && version.as_ref() != Some(&next) {
            super::super::app_session::external_history_changed(service_key, session);
        }
        version = Some(next);
        if !on_update(update).await {
            return Ok(());
        }
    }
    bail!("native session follow ended unexpectedly")
}
