//! Original-session operations through one captured native host identity.

use pocket_codex_host_svc::{
    opencode::{
        catalog::Command,
        host::{Answer, Input, Options},
    },
    session_access::SessionAccess,
};
use serde_json::Value;

use super::{
    super::{
        app_session::{OlderPage, ThreadHistory},
        session_engine::{StartOptions, Supplement, TurnOptions},
    },
    *,
};

/// Inspect fresh writer evidence without acquiring a session.
pub fn access(service: &str, session: &str) -> Result<SessionAccess> {
    access_for_link(&conn(service)?, session)
}

pub(super) fn access_for_link(link: &Link, session: &str) -> Result<SessionAccess> {
    let identity = link.identity();
    let access = match runtime::runtime().block_on(link.client.access(session)) {
        Ok(access) => access,
        Err(error) => {
            if !runtime::runtime()
                .block_on(events::deleted_session(link, &identity, session, &error))?
            {
                return Err(error.into());
            }
            let mut access =
                SessionAccess::unknown(session, &identity.host_id, identity.generation, "opencode");
            access.source_generation = Some(identity.source_generation.clone());
            access.mode = "blocked".into();
            access.reason = "not_found".into();
            access.writer = "none".into();
            access.recheck = false;
            access
        },
    };
    validate_access(&identity, &access, session)?;
    link.commit(&identity, |_| ())?;
    Ok(access)
}

pub(super) fn validate_access(
    identity: &Identity,
    access: &SessionAccess,
    session: &str,
) -> Result<()> {
    if access.session_id != session
        || access.host_id != identity.host_id
        || access.generation != identity.generation
        || access.source_generation.as_deref() != Some(&identity.source_generation)
    {
        bail!("the OpenCode host or history source changed; reconnect");
    }
    Ok(())
}

/// Open the original ID, returning either admitted controls or a safe follow
/// view.
pub fn open(service: &str, session: &str) -> Result<SessionAccess> {
    let link = conn(service)?;
    let identity = link.identity();
    let next = block(link.client.open(session, &identity))?;
    if next.session.id != session {
        bail!("OpenCode returned another session");
    }
    let old = link.commit(&identity, |view| view.sessions.get(session).cloned())?;
    if link.accept(&identity, next.clone())? {
        events::announce(&link, &identity, old.as_ref(), &next);
    }
    link.commit(&identity, |view| {
        view.sessions
            .get(session)
            .map(|s| s.access.clone())
            .unwrap_or(next.access)
    })
}

/// Release only the exact host/source/session shown by the caller.
pub fn release(service: &str, snapshot: &SessionAccess) -> Result<SessionAccess> {
    let link = conn(service)?;
    let identity = link.identity();
    validate_access(&identity, snapshot, &snapshot.session_id)?;
    let next = block(link.client.release(&snapshot.session_id, &identity))?;
    validate_access(&identity, &next, &snapshot.session_id)?;
    link.commit(&identity, |view| {
        if let Some(snapshot) = view.sessions.get_mut(&next.session_id) {
            snapshot.access = next.clone();
        }
    })?;
    Ok(next)
}

/// Public native command names, with no templates or implementation settings.
pub fn commands(service: &str, directory: Option<&str>) -> Result<Vec<Command>> {
    Ok(super::catalog(service, directory)?.commands)
}

pub(super) fn start(service: &str, options: StartOptions) -> Result<String> {
    let link = conn(service)?;
    let identity = link.identity();
    let cwd = options
        .cwd
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| anyhow!("choose a project folder for the new session"))?;
    let session = block(link.client.create(
        &cwd,
        &Options {
            model: options.model,
            ..Options::default()
        },
        &identity,
    ))?;
    link.commit(&identity, |_| ())?;
    let next = block(link.client.snapshot(&session.id, None))?;
    link.accept(&identity, next)?;
    Ok(session.id)
}

pub(super) fn read(service: &str, session: &str) -> Result<ThreadHistory> {
    let link = conn(service)?;
    let identity = link.identity();
    let snapshot = block(link.client.snapshot(session, None))?;
    if snapshot.session.id != session {
        bail!("OpenCode returned another session");
    }
    link.accept(&identity, snapshot.clone())?;
    link.commit(&identity, |view| {
        let snapshot = view.sessions.get(session).unwrap_or(&snapshot);
        let result = projection::history(snapshot);
        view.cursors
            .insert(session.into(), snapshot.window.next_before.clone());
        result
    })
}

pub(super) fn older(service: &str, session: &str) -> Result<OlderPage> {
    let link = conn(service)?;
    let identity = link.identity();
    let cursor = lock(&link.shared)
        .cursors
        .get(session)
        .cloned()
        .ok_or_else(|| anyhow!("read the conversation before requesting older messages"))?;
    let Some(before) = cursor else {
        return Ok(OlderPage {
            items: vec![],
            has_older: false,
        });
    };
    let snapshot = block(link.client.snapshot(session, Some(&before)))?;
    validate_snapshot(&identity, &snapshot)?;
    if snapshot.session.id != session {
        bail!("OpenCode returned another session");
    }
    if snapshot.window.next_before.as_deref() == Some(&before) {
        bail!("OpenCode returned a repeated history cursor");
    }
    link.commit(&identity, |view| {
        if view.cursors.get(session) != Some(&Some(before)) {
            bail!("the OpenCode history cursor changed; retry");
        }
        view.cursors
            .insert(session.into(), snapshot.window.next_before.clone());
        Ok(())
    })??;
    Ok(OlderPage {
        items: projection::items(&snapshot),
        has_older: snapshot.window.next_before.is_some(),
    })
}

pub(super) fn prompt(service: &str, session: &str, options: TurnOptions) -> Result<()> {
    let link = conn(service)?;
    if let Some(model) = options.model {
        settings::set_link(&link, session, "model", &model)?;
    }
    send(&link, session, None, &Input {
        text: options.text,
        images: options.images,
    })
    .map(|_| ())
}

fn send(link: &Link, session: &str, expected: Option<&str>, input: &Input) -> Result<String> {
    let identity = link.identity();
    let turn = block(link.client.prompt(session, input, expected, &identity))?;
    // A lost/replaced connection never turns uncertain delivery into permission to
    // retry.
    link.commit(&identity, |_| ()).map_err(|_| {
        anyhow!(
            "OpenCode connection changed after sending; check the conversation before sending \
             again"
        )
    })?;
    Ok(turn)
}

pub(super) fn supplement(
    service: &str,
    session: &str,
    turn: Option<&str>,
    text: &str,
    images: &[String],
) -> Result<Supplement> {
    let link = conn(service)?;
    let identity = link.identity();
    let current = block(link.client.snapshot(session, None))?;
    link.accept(&identity, current.clone())?;
    let Some(actual) = current.turn_id.as_deref() else { return Ok(Supplement::PromptRequired) };
    if turn.is_some_and(|turn| turn != actual) {
        bail!("the OpenCode turn changed; refresh before supplementing");
    }
    send(&link, session, Some(actual), &Input {
        text: text.into(),
        images: images.to_vec(),
    })
    .map(Supplement::Injected)
}

pub(super) fn cancel(service: &str, session: &str, turn: Option<String>) -> Result<()> {
    let link = conn(service)?;
    let identity = link.identity();
    let turn = turn.or_else(|| {
        lock(&link.shared)
            .sessions
            .get(session)
            .and_then(|s| s.turn_id.clone())
    });
    let Some(turn) = turn else { bail!("no confirmed OpenCode turn to stop") };
    block(link.client.cancel(session, &turn, &identity))?;
    link.commit(&identity, |_| ())
}

pub(super) fn answer(
    service: &str,
    request: &str,
    permission: Option<&str>,
    answers: Option<&str>,
) -> Result<()> {
    let link = conn(service)?;
    let identity = link.identity();
    let handle: Value = serde_json::from_str(request)?;
    if handle[0] != identity.host_id || handle[1] != identity.generation {
        bail!("this pending request belongs to another OpenCode host");
    }
    let session = handle[2]
        .as_str()
        .ok_or_else(|| anyhow!("invalid request"))?;
    let id = handle[4]
        .as_str()
        .ok_or_else(|| anyhow!("invalid request"))?;
    let snapshot = block(link.client.snapshot(session, None))?;
    validate_snapshot(&identity, &snapshot)?;
    if !events::pending(&snapshot, &identity).contains_key(request) {
        bail!("this OpenCode request is no longer pending");
    }
    let answer = match (handle[3].as_str(), permission, answers) {
        (Some("permission"), Some(reply), None) => Answer::Permission {
            reply: reply.into(),
        },
        (Some("question"), None, Some(body)) => {
            let request = snapshot
                .questions
                .iter()
                .find(|q| q["id"] == id)
                .ok_or_else(|| anyhow!("question no longer pending"))?;
            question_answer(body, request["questions"].as_array().map_or(0, Vec::len))?
        },
        _ => bail!("invalid OpenCode response kind"),
    };
    block(link.client.answer(session, id, &answer, &identity))?;
    link.commit(&identity, |_| ())
}


pub(super) fn question_answer(body: &str, count: usize) -> Result<Answer> {
    let body: Value = serde_json::from_str(body)?;
    let body = body
        .as_object()
        .ok_or_else(|| anyhow!("invalid question answers"))?;
    if body.is_empty() {
        return Ok(Answer::RejectQuestion);
    }
    if body.len() != count {
        bail!("answer every question or skip the request");
    }
    let answers = (0..count)
        .map(|i| {
            body.get(&format!("q{i}"))
                .and_then(Value::as_array)
                .ok_or_else(|| anyhow!("invalid question answer"))?
                .iter()
                .map(|v| {
                    v.as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| anyhow!("invalid answer label"))
                })
                .collect::<Result<Vec<_>>>()
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(Answer::Question {
        answers,
    })
}
