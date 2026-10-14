//! Native per-session choices, with draft defaults that never mutate the host.

use pocket_codex_host_svc::opencode::host::Options;
use serde_json::{json, Value};

use super::*;

pub(super) fn settings(service: &str, session: &str) -> Option<Value> {
    let link = conn(service).ok()?;
    let identity = link.identity();
    let snapshot = link
        .commit(&identity, |view| view.sessions.get(session).cloned())
        .ok()?;
    let directory = snapshot.as_ref().map(|s| s.session.directory.as_str());
    let catalog = block(link.client.catalog(directory, &identity)).ok()?;
    link.commit(&identity, |_| ()).ok()?;
    let selected = snapshot
        .as_ref()
        .map(|s| s.options.clone())
        .unwrap_or_default();
    let model = selected.model.as_ref();
    let variants:Vec<_>=catalog.models.iter().filter(|m|session.is_empty() || model==Some(&m.key()))
        .map(|m|json!({"group":m.key(),"name":m.key(),"options":
            std::iter::once(json!({"value":"","name":"Default"})).chain(m.variants.iter().map(|v|json!({"value":v,"name":v}))).collect::<Vec<_>>()})).collect();
    Some(json!({"runningTurnId":snapshot.as_ref().and_then(|s|s.turn_id.as_ref()),"configOptions":[
        {"id":"model","name":"Model","category":"model","currentValue":model.cloned().unwrap_or_default(),
         "options":std::iter::once(json!({"value":"","name":"Inherited"})).chain(catalog.models.iter().map(|m|json!({"value":m.key(),"name":m.name,"description":m.provider_name}))).collect::<Vec<_>>()},
        {"id":"agent","name":"Agent","category":"mode","currentValue":selected.agent.unwrap_or_default(),
         "options":std::iter::once(json!({"value":"","name":"Default"})).chain(catalog.agents.iter().map(|a|json!({"value":a.name,"name":a.name,"description":a.description}))).collect::<Vec<_>>()},
        {"id":"variant","name":"Variant","category":"thought_level","currentValue":selected.variant.unwrap_or_default(),"options":variants}
    ]}))
}

pub(super) fn set(service: &str, session: &str, id: &str, value: &str) -> Result<()> {
    set_link(&conn(service)?, session, id, value)
}

pub(super) fn set_link(link: &Link, session: &str, id: &str, value: &str) -> Result<()> {
    if session.is_empty() {
        bail!("draft choices must be applied after creating the native session");
    }
    let identity = link.identity();
    let current = block(link.client.snapshot(session, None))?;
    validate_snapshot(&identity, &current)?;
    let mut options = current.options.clone();
    let selected = (!value.is_empty()).then(|| value.to_owned());
    match id {
        "model" => {
            options.model = selected;
            options.variant = None;
        },
        "agent" => options.agent = selected,
        "variant" => {
            if options.model.is_none() && selected.is_some() {
                bail!("select the native model before its variant");
            }
            options.variant = selected;
        },
        _ => bail!("unknown OpenCode option"),
    }
    let options = block(link.client.options(session, &options, &identity))?;
    link.commit(&identity, |view| {
        if let Some(snapshot) = view.sessions.get_mut(session) {
            snapshot.options = options;
        }
    })?;
    Ok(())
}

pub(super) fn initial(model: Option<String>) -> Options {
    Options {
        model,
        ..Options::default()
    }
}
