//! Coalesced invalidations refresh complete host-merged windows. Native text
//! deltas never reach this controller, including after a reconnect.

use std::{collections::HashMap, time::Duration};

use pocket_codex_host_svc::opencode::events::EventStream;
use serde_json::{json, Value};

use super::*;

pub(super) fn handle(identity: &Identity, session: &str, kind: &str, request: &str) -> String {
    json!([identity.host_id, identity.generation, session, kind, request]).to_string()
}

pub(super) fn pending(snapshot: &Snapshot, identity: &Identity) -> HashMap<String, AppEvent> {
    let thread = &snapshot.session.id;
    let mut out = HashMap::new();
    for request in &snapshot.permissions {
        let Some(id) = request["id"].as_str() else { continue };
        let handle = handle(identity, thread, "permission", id);
        let mut event = projection::event(
            "acp/permission/requested",
            Some(thread),
            json!({
            "threadId":thread,"turnId":snapshot.turn_id,"patterns":request["patterns"],"always":request["always"],
            "toolCall":{"title":request["permission"],"rawInput":request["patterns"]},
            "options":[{"optionId":"once","name":"","kind":"allow_once"},
                {"optionId":"always","name":"","kind":"allow_always"},
                {"optionId":"reject","name":"","kind":"reject_once"}]}),
        );
        event.request_id = Some(handle.clone());
        event.title = request["permission"].as_str().map(str::to_owned);
        out.insert(handle, event);
    }
    for request in &snapshot.questions {
        let Some(id) = request["id"].as_str() else { continue };
        let handle = handle(identity, thread, "question", id);
        let questions:Vec<Value> = request["questions"].as_array().into_iter().flatten().enumerate()
            .map(|(i,q)|json!({"id":format!("q{i}"),"header":q["header"],"question":q["question"],
                "multiple":q["multiple"],"isOther":q["custom"]!=false,"isSecret":false,"options":q["options"]})).collect();
        let mut event = projection::event(
            "item/tool/requestUserInput",
            Some(thread),
            json!({
            "threadId":thread,"turnId":snapshot.turn_id,"questions":questions}),
        );
        event.request_id = Some(handle.clone());
        out.insert(handle, event);
    }
    out
}

pub(super) fn announce(link: &Link, identity: &Identity, old: Option<&Snapshot>, next: &Snapshot) {
    let thread = &next.session.id;
    let previous = pending_opt(old, identity);
    let pending = pending(next, identity);
    for id in previous.keys().filter(|id| !pending.contains_key(*id)) {
        let _ = link.tx.send(projection::event(
            "serverRequest/resolved",
            Some(thread),
            json!({"threadId":thread,"requestId":id}),
        ));
    }
    let prior_turn = old.and_then(|old| old.turn_id.as_ref());
    let old_items = old.map(projection::items).unwrap_or_default();
    let ended = prior_turn.filter(|turn| next.turn_id.as_ref() != Some(*turn));
    let items = projection::items(next);
    for marker in old_items.iter().filter(|item| {
        item.item_type == "contentOmitted" && !items.iter().any(|next| next.id == item.id)
    }) {
        let mut cleared = marker.clone();
        cleared.text.clear();
        let _ = link.tx.send(projection::item_event(thread, &cleared));
    }
    let changed = |item: &&super::super::app_session::ThreadItem| {
        !old_items.iter().any(|old| {
            old.id == item.id
                && old.text == item.text
                && old.images == item.images
                && old.item_type == item.item_type
                && old.title == item.title
        })
    };
    // Complete the old turn before announcing a successor. Every item is a
    // full replacement; an invalidation can never append the same prefix twice.
    if let Some(turn) = ended {
        for item in items
            .iter()
            .filter(changed)
            .filter(|item| item.turn_id == *turn)
        {
            let _ = link.tx.send(projection::item_event(thread, item));
        }
        let _ = link.tx.send(projection::ended(next, turn));
    }
    if let Some(turn) = next
        .turn_id
        .as_ref()
        .filter(|turn| Some(*turn) != prior_turn)
    {
        let _ = link.tx.send(projection::event(
            "turn/started",
            Some(thread),
            json!({"threadId":thread,"turn":{"id":turn,"status":"inProgress"}}),
        ));
    }
    for item in items
        .iter()
        .filter(changed)
        .filter(|item| ended.is_none_or(|turn| item.turn_id != *turn))
    {
        let _ = link.tx.send(projection::item_event(thread, item));
    }
    for event in pending.into_values() {
        let _ = link.tx.send(event);
    }
    let _ = link.tx.send(projection::event(
        "acp/session/updated",
        Some(thread),
        json!({
        "sessionId":thread,"admitted":next.access.mode=="write","runningTurnId":next.turn_id}),
    ));
    if old.is_none_or(|old| old.access != next.access) {
        let _ = link.tx.send(projection::event(
            "session/access/changed",
            Some(thread),
            json!({"threadId":thread}),
        ));
    }
    if old.is_some_and(|old| old.session.title != next.session.title) {
        let _ = link.tx.send(projection::event(
            "thread/name/updated",
            Some(thread),
            json!({"threadId":thread,"name":next.session.title}),
        ));
    }
}

fn pending_opt(snapshot: Option<&Snapshot>, identity: &Identity) -> HashMap<String, AppEvent> {
    snapshot
        .map(|snapshot| pending(snapshot, identity))
        .unwrap_or_default()
}

pub(super) async fn refresh(link: &Link, identity: &Identity) -> Result<()> {
    let sessions: Vec<_> = lock(&link.shared).sessions.keys().cloned().collect();
    for session in sessions {
        let next = match link.client.snapshot(&session, None).await {
            Ok(snapshot) => snapshot,
            Err(error) => {
                if deleted_session(link, identity, &session, &error).await? {
                    continue;
                }
                return Err(error.into());
            },
        };
        let old = link.commit(identity, |view| view.sessions.get(&session).cloned())?;
        if !link.accept(identity, next.clone())? {
            continue;
        }
        announce(link, identity, old.as_ref(), &next);
    }
    Ok(())
}

/// Native events are process-local. Access and follow reads must also report
/// a deletion by another process, even when this server emits no SSE change.
pub(super) async fn deleted_session(
    link: &Link,
    identity: &Identity,
    session: &str,
    error: &ClientError,
) -> Result<bool> {
    if !matches!(error, ClientError::Gateway { status: 404, code } if code == "session_not_found") {
        return Ok(false);
    }
    // A replacement listener must not erase the previous host's cache.
    if &link.client.info().await?.identity != identity {
        bail!("the OpenCode host changed; reconnect");
    }
    forget_deleted(link, identity, session)?;
    Ok(true)
}

fn forget_deleted(link: &Link, identity: &Identity, session: &str) -> Result<()> {
    let old = link.commit(identity, |view| {
        view.bytes.remove(session);
        view.cursors.remove(session);
        view.turn_pages.retain(|(id, _), _| id != session);
        view.sessions.remove(session)
    })?;
    for request in pending_opt(old.as_ref(), identity).keys() {
        let _ = link.tx.send(projection::event(
            "serverRequest/resolved",
            Some(session),
            json!({"threadId":session,"requestId":request}),
        ));
    }
    let _ = link.tx.send(projection::event(
        "acp/session/updated",
        Some(session),
        json!({"sessionId":session,"admitted":false,"runningTurnId":null}),
    ));
    if let Some(turn) = old.and_then(|old| old.turn_id) {
        let _ = link.tx.send(projection::event(
            "turn/completed",
            Some(session),
            json!({"threadId":session,"turn":{"id":turn,"status":"failed",
                "error":{"message":"The native OpenCode session was deleted."}}}),
        ));
    }
    let _ = link.tx.send(projection::event(
        "thread/deleted",
        Some(session),
        json!({"threadId":session}),
    ));
    Ok(())
}

fn healthy(link: &Link, identity: &Identity, healthy: bool) -> bool {
    let changed = link.commit(identity, |view| {
        let changed = view.healthy != healthy;
        view.healthy = healthy;
        changed
    });
    match changed {
        Ok(true) => {
            let _ = link.tx.send(projection::health(healthy));
            true
        },
        Ok(false) => true,
        Err(_) => false,
    }
}

pub(super) async fn run(link: Link, mut stream: EventStream) {
    let identity = link.identity();
    let mut tick = tokio::time::interval(Duration::from_millis(250));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut dirty = false;
    loop {
        let failed = tokio::select! {
            next=stream.next()=>match next {
                Some(Ok(event)) if event.kind=="changed"=>{dirty=true;false},
                Some(Ok(_))=>false,
                _=>true,
            },
            _=tick.tick(),if dirty=>{
                dirty=false;
                refresh(&link,&identity).await.is_err()
            }
        };
        if !failed {
            continue;
        }
        if !healthy(&link, &identity, false) {
            return;
        }
        // Permission handles are withdrawn during loss of positive live health.
        let snapshots: Vec<_> = lock(&link.shared).sessions.values().cloned().collect();
        for snapshot in snapshots {
            for id in pending(&snapshot, &identity).keys() {
                let _ = link.tx.send(projection::event(
                    "serverRequest/resolved",
                    Some(&snapshot.session.id),
                    json!({"threadId":snapshot.session.id,"requestId":id}),
                ));
            }
        }
        loop {
            tokio::time::sleep(Duration::from_secs(1)).await;
            let Ok(info) = link.client.info().await else { continue };
            if info.identity != identity {
                return;
            }
            let Ok(reopened) = link.client.events(&identity, 0).await else { continue };
            if refresh(&link, &identity).await.is_err() {
                continue;
            }
            if !healthy(&link, &identity, true) {
                return;
            }
            stream = reopened;
            dirty = true;
            break;
        }
    }
}
