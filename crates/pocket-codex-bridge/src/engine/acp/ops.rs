//! Session, history, turn and settings operations of the ACP engine.
//!
//! Each operation captures one [`Link`](super::Link): its request carries the
//! host incarnation and generation that connection shows, and its result is
//! applied to that same connection only while it still shows them.

use anyhow::{anyhow, Result};
use pocket_codex_host_svc::acp::{
    fold::{ItemKind, Turn},
    Identity, SteerOutcome,
};
use serde::Deserialize as _;
use serde_json::Value;

use super::{block, conn, lock, translate, Link, Shared};
use crate::engine::{
    app_session::{OlderPage, ThreadHistory, ThreadItem, ThreadMeta, TurnItemsPage, TurnSummary},
    session_engine::Supplement,
};

/// Turns in the newest window and in each older page.
const WINDOW_TURNS: usize = 20;
/// Most sessions listed (pages are followed up to this many).
const MAX_SESSIONS: usize = 500;

/// Unix seconds of an RFC 3339 timestamp (`T`, `t` or space separator,
/// `Z`/`z` or a `±hh:mm` offset), or `None` when it is malformed or names an
/// impossible date. Only the agent's own timestamp is used; nothing is
/// fabricated.
pub fn unix_seconds(text: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(text)
        .ok()
        .map(|instant| instant.timestamp())
}

fn meta_of(session: &Value) -> Option<ThreadMeta> {
    let id = session["sessionId"].as_str()?.to_string();
    let title = session["title"]
        .as_str()
        .map(str::to_string)
        .filter(|t| !t.trim().is_empty());
    Some(ThreadMeta {
        id,
        preview: title.clone().unwrap_or_default(),
        name: title,
        thread_source: None,
        parent_thread_id: None,
        cwd: session["cwd"].as_str().unwrap_or("").to_string(),
        origin_url: None,
        updated_at: session["updatedAt"]
            .as_str()
            .and_then(unix_seconds)
            .unwrap_or(0),
    })
}

/// Sessions: the agent's own listing when it supports `session/list`,
/// otherwise the sessions this host admitted.
pub fn thread_list(service_key: &str) -> Result<Vec<ThreadMeta>> {
    let client = conn(service_key)?.client;
    let mut out = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let page = block(client.sessions(cursor.as_deref()))?;
        out.extend(
            page["sessions"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(meta_of),
        );
        match page["nextCursor"].as_str() {
            Some(next) if out.len() < MAX_SESSIONS && cursor.as_deref() != Some(next) => {
                cursor = Some(next.to_string());
            },
            _ => break,
        }
    }
    out.truncate(MAX_SESSIONS);
    Ok(out)
}

/// Sessions with a running turn, from the host's authoritative view.
pub fn running_threads(service_key: &str) -> Result<Vec<String>> {
    let shared = conn(service_key)?.shared;
    let mut running: Vec<String> = lock(&shared).running.keys().cloned().collect();
    running.sort();
    Ok(running)
}

/// The host changed while a request was in flight: its answer is not shown.
pub(super) fn superseded() -> anyhow::Error {
    anyhow!("the agent host changed while this was in progress; try again")
}

/// Create a session in `cwd` (validated by the host).
pub fn thread_start(service_key: &str, cwd: Option<String>) -> Result<String> {
    let link = conn(service_key)?;
    let cwd = cwd
        .filter(|c| !c.trim().is_empty())
        .ok_or_else(|| anyhow!("choose a project folder for the new session"))?;
    let identity = link.identity();
    let opened = block(link.client.new_session(&cwd, Some(&identity)))?;
    let id = opened["sessionId"]
        .as_str()
        .ok_or_else(|| anyhow!("the agent host returned no session id"))?
        .to_string();
    link.commit(&identity, |view| view.sessions.insert(id.clone(), opened))
        .ok_or_else(superseded)?;
    Ok(id)
}

/// Reopen a session (load with replay, resume without, or attach to a live
/// one) and re-announce its pending permissions.
pub fn thread_resume(service_key: &str, thread_id: &str) -> Result<()> {
    let link = conn(service_key)?;
    let identity = link.identity();
    let opened = block(link.client.open_session(thread_id, Some(&identity)))?;
    let pending: Vec<Value> = link
        .commit(&identity, |view| {
            view.sessions.insert(thread_id.to_string(), opened.clone());
            view.oldest.remove(thread_id);
            view.history_epochs.remove(thread_id);
            view.permissions
                .values()
                .filter(|p| p["sessionId"] == thread_id)
                .cloned()
                .collect()
        })
        .ok_or_else(superseded)?;
    let _ = link
        .tx
        .send(translate::event(translate::SESSION_UPDATED, Some(thread_id), opened));
    for body in pending {
        let _ = link.tx.send(translate::permission_event(&body));
    }
    Ok(())
}

fn window_turns(history: &Value) -> Vec<Turn> {
    history["window"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|turn| Turn::deserialize(turn).ok())
        .collect()
}

/// UI items of retained turns, with a gap wherever a turn lost items.
fn items_of(turns: &[Turn]) -> Vec<ThreadItem> {
    turns.iter().flat_map(translate::turn_items).collect()
}

/// The marker for history missing before the retained window.
fn gap_item(thread: &str) -> ThreadItem {
    translate::gap_item(translate::synthetic_id("history-gap", thread), "")
}

/// Accept a history answer read through `link` while it showed `identity`
/// — the one rule of every history read. The answer must come from that
/// host incarnation and generation (a replacement behind the same endpoint
/// may reuse both the generation number and the session id), and `link`
/// must still be the registered connection showing `identity`, checked
/// when `commit` (cursor bookkeeping, possibly nothing) is applied. Only
/// then may the answer be shown.
pub(super) fn accept_history<T>(
    link: &Link,
    identity: &Identity,
    history: &Value,
    commit: impl FnOnce(&mut Shared) -> T,
) -> Result<T> {
    if history["hostId"].as_str() != identity.host_id.as_deref()
        || history["generation"].as_u64() != identity.generation
    {
        return Err(superseded());
    }
    link.commit(identity, commit).ok_or_else(superseded)
}

fn summaries(history: &Value, loaded: &[Turn]) -> Vec<TurnSummary> {
    history["turns"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|entry| {
            let id = entry["turnId"].as_str().unwrap_or("").to_string();
            let turn = loaded.iter().find(|t| t.id == id);
            let assistant = turn
                .and_then(|t| {
                    t.items
                        .iter()
                        .rev()
                        .find(|i| i.kind == ItemKind::AgentMessage)
                })
                .map(|i| i.text.chars().take(400).collect())
                .unwrap_or_default();
            TurnSummary {
                turn_id: id,
                user_text: entry["userText"].as_str().unwrap_or("").to_string(),
                assistant_text: assistant,
                loaded: turn.is_some(),
            }
        })
        .collect()
}

/// The newest retained window plus the turn rail. Retained history is
/// bounded by the host: a missing beginning is shown as a gap, never as an
/// authoritative start.
pub fn thread_read(service_key: &str, thread_id: &str) -> Result<ThreadHistory> {
    read_window(&conn(service_key)?, thread_id)
}

pub(super) fn read_window(link: &Link, thread_id: &str) -> Result<ThreadHistory> {
    let identity = link.identity();
    let history = block(
        link.client
            .history(thread_id, None, None, Some(WINDOW_TURNS)),
    )?;
    let session = &history["session"];
    let turns = window_turns(&history);
    // Another host or generation answered, or this connection is gone:
    // its history is not this view's (the stream resynchronizes and the
    // screen reloads) — even when it is empty.
    accept_history(link, &identity, &history, |view| {
        match history["historyEpoch"].as_str() {
            Some(epoch) => {
                view.history_epochs
                    .insert(thread_id.to_owned(), epoch.to_owned());
            },
            None => {
                view.history_epochs.remove(thread_id);
            },
        }
        match turns.first() {
            Some(first) => {
                view.oldest.insert(thread_id.to_string(), first.id.clone());
            },
            None => {
                view.oldest.remove(thread_id);
            },
        }
    })?;
    let truncated = history["truncated"] == true || history["available"] != true;
    let has_older = history["hasOlder"] == true;
    let mut items = items_of(&turns);
    if truncated && !has_older {
        items.insert(0, gap_item(thread_id));
    }
    let running = session["runningTurnId"].as_str().map(str::to_string);
    let first_turn_id = (!truncated && !has_older)
        .then(|| history["turns"][0]["turnId"].as_str().map(str::to_string))
        .flatten();
    Ok(ThreadHistory {
        history_epoch: history["historyEpoch"].as_str().map(str::to_string),
        turns: summaries(&history, &turns),
        first_turn_id,
        has_older,
        items,
        running: running.is_some(),
        active_turn_id: running,
        branch: None,
        cwd: session["cwd"].as_str().map(str::to_string),
        tokens_used: session["usage"]["used"].as_i64(),
        context_window: session["usage"]["size"].as_i64(),
        collaboration_mode: None,
        reasoning_effort: None,
        model: None,
        model_provider: None,
        approval_policy: None,
        approvals_reviewer: None,
        service_tier: None,
        sandbox_mode: None,
        config_confirmed: false,
        turn_pages: Vec::new(),
    })
}

/// One page of older retained turns.
pub fn thread_older_page(service_key: &str, thread_id: &str) -> Result<OlderPage> {
    older_page(&conn(service_key)?, thread_id)
}

pub(super) fn older_page(link: &Link, thread_id: &str) -> Result<OlderPage> {
    let identity = link.identity();
    let (before, epoch) = {
        let view = lock(&link.shared);
        (view.oldest.get(thread_id).cloned(), view.history_epochs.get(thread_id).cloned())
    };
    let Some(before) = before else {
        return Ok(OlderPage {
            items: Vec::new(),
            has_older: false,
        });
    };
    let history = block(
        link.client
            .history(thread_id, Some(&before), None, Some(WINDOW_TURNS)),
    )?;
    let turns = window_turns(&history);
    // The cursor moves only for an answer of this view's host, and only
    // if it still is the cursor this page was asked for.
    accept_history(link, &identity, &history, |view| {
        if view.oldest.get(thread_id) != Some(&before)
            || view.history_epochs.get(thread_id) != epoch.as_ref()
            || history["historyEpoch"].as_str() != epoch.as_deref()
        {
            return Err(superseded());
        }
        match turns.first() {
            Some(first) => {
                view.oldest.insert(thread_id.to_string(), first.id.clone());
            },
            None => {
                view.oldest.remove(thread_id);
            },
        }
        Ok(())
    })??;
    let has_older = history["hasOlder"] == true;
    let mut items = items_of(&turns);
    if !has_older && history["truncated"] == true {
        items.insert(0, gap_item(thread_id));
    }
    Ok(OlderPage {
        items,
        has_older,
    })
}

/// One retained turn, read whole (no continuation pages).
pub fn thread_turn_page(
    service_key: &str,
    thread_id: &str,
    turn_id: &str,
    load_more: bool,
) -> Result<TurnItemsPage> {
    let empty = TurnItemsPage {
        turn_id: turn_id.to_string(),
        items: Vec::new(),
        has_more: false,
    };
    if load_more {
        return Ok(empty);
    }
    let link = conn(service_key)?;
    let identity = link.identity();
    let epoch = lock(&link.shared).history_epochs.get(thread_id).cloned();
    let history = block(link.client.history(thread_id, None, Some(turn_id), None))?;
    accept_history(&link, &identity, &history, |view| {
        if view.history_epochs.get(thread_id) != epoch.as_ref()
            || history["historyEpoch"].as_str() != epoch.as_deref()
        {
            return Err(superseded());
        }
        Ok(())
    })??;
    let turns = window_turns(&history);
    if turns.is_empty() {
        return Err(anyhow!("this turn is no longer retained by the agent host"));
    }
    Ok(TurnItemsPage {
        items: items_of(&turns),
        ..empty
    })
}

/// Send a prompt; it is admitted by the host and streams through events.
/// It is refused when the host was replaced or moved to another generation
/// than the one this controller shows.
pub fn turn_start(service_key: &str, thread_id: &str, text: &str, images: &[String]) -> Result<()> {
    let link = conn(service_key)?;
    let identity = link.identity();
    block(link.client.prompt(thread_id, text, images, Some(&identity))).map(|_| ())
}

/// Add input to `turn_id` (the caller's turn; else the turn this controller
/// sees running) through the agent's negotiated steering. Another turn is
/// refused by the host; an idle session consumes nothing
/// ([`Supplement::PromptRequired`]). An unrecognized or lost answer is an
/// error and is never retried here.
pub fn turn_supplement(
    service_key: &str,
    thread_id: &str,
    turn_id: Option<&str>,
    text: &str,
    images: &[String],
) -> Result<Supplement> {
    supplement(&conn(service_key)?, thread_id, turn_id, text, images)
}

/// [`turn_supplement`] through `link`.
pub(super) fn supplement(
    link: &Link,
    thread_id: &str,
    turn_id: Option<&str>,
    text: &str,
    images: &[String],
) -> Result<Supplement> {
    let (turn, identity) = {
        let view = lock(&link.shared);
        let turn = turn_id
            .filter(|turn| !turn.trim().is_empty())
            .map(str::to_string)
            .or_else(|| view.running.get(thread_id).cloned());
        (turn, view.identity())
    };
    let (outcome, accepted) =
        block(
            link.client
                .steer(thread_id, turn.as_deref(), text, images, Some(&identity)),
        )?;
    // The answer belongs to the connection and host that asked. A
    // replacement may already show another session state, so an answer
    // arriving after it is neither "added" nor "not consumed": the caller
    // keeps its input and nothing is sent in its place.
    if link.commit(&identity, |_| ()).is_none() {
        return Err(uncertain(
            "the agent host changed before it answered, so the message may or may not have been \
             added",
        ));
    }
    match (outcome, accepted) {
        (SteerOutcome::Injected, Some(accepted))
            if !accepted.trim().is_empty() && turn.as_deref().is_none_or(|t| t == accepted) =>
        {
            Ok(Supplement::Injected(accepted))
        },
        (SteerOutcome::Injected, _) => Err(uncertain(
            "the agent host did not confirm which turn took the message, so it may or may not \
             have been added",
        )),
        (SteerOutcome::PromptRequired, _) => Ok(Supplement::PromptRequired),
    }
}

/// An answer that does not establish what happened to a supplement.
fn uncertain(why: &str) -> anyhow::Error {
    anyhow!("{why}; check the conversation before sending it again")
}

/// Cancel `turn_id` (the caller's turn; else the turn this controller sees
/// running). A turn that already ended is left alone, and a newer turn of
/// the session — or a turn of a replacement host — is never cancelled in
/// its place.
pub fn turn_interrupt(service_key: &str, thread_id: &str, turn_id: Option<String>) -> Result<()> {
    let link = conn(service_key)?;
    let (turn, identity) = {
        let view = lock(&link.shared);
        let turn = turn_id
            .filter(|turn| !turn.trim().is_empty())
            .or_else(|| view.running.get(thread_id).cloned());
        (turn, view.identity())
    };
    block(
        link.client
            .cancel(thread_id, turn.as_deref(), Some(&identity)),
    )
    .map(|_| ())
}

/// Answer permission `handle` with the agent's own option id. Handles are
/// unique per host incarnation, so a replacement host cannot match one.
pub fn respond_permission(service_key: &str, handle: &str, option_id: &str) -> Result<()> {
    let client = conn(service_key)?.client;
    block(client.answer(handle, option_id))
}

/// The latest session state (configuration options, modes, usage, title)
/// this controller has seen for `thread_id`.
pub fn session_settings(service_key: &str, thread_id: &str) -> Option<Value> {
    let shared = conn(service_key).ok()?.shared;
    let settings = lock(&shared).sessions.get(thread_id).cloned();
    settings
}

/// Apply a settings answer to the connection that asked, if it still shows
/// the host it asked.
fn store_settings(
    link: &super::Link,
    identity: &pocket_codex_host_svc::acp::Identity,
    thread_id: &str,
    body: Value,
) -> Result<()> {
    link.commit(identity, |view| view.sessions.insert(thread_id.to_string(), body.clone()))
        .ok_or_else(superseded)?;
    let _ = link
        .tx
        .send(translate::event(translate::SESSION_UPDATED, Some(thread_id), body));
    Ok(())
}

/// Set a select configuration option to one of its advertised values.
pub fn set_session_config(
    service_key: &str,
    thread_id: &str,
    config_id: &str,
    value: &str,
) -> Result<()> {
    let link = conn(service_key)?;
    let identity = link.identity();
    let body = block(
        link.client
            .set_config(thread_id, config_id, value, Some(&identity)),
    )?;
    store_settings(&link, &identity, thread_id, body)
}

/// Switch the legacy session mode.
pub fn set_session_mode(service_key: &str, thread_id: &str, mode_id: &str) -> Result<()> {
    let link = conn(service_key)?;
    let identity = link.identity();
    let body = block(link.client.set_mode(thread_id, mode_id, Some(&identity)))?;
    store_settings(&link, &identity, thread_id, body)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamps_parse_only_when_well_formed() {
        assert_eq!(unix_seconds("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(unix_seconds("2026-10-01T00:00:00Z"), Some(1_790_812_800));
        assert_eq!(unix_seconds("2026-10-01T08:00:00.123+08:00"), Some(1_790_812_800));
        assert_eq!(unix_seconds("yesterday"), None);
        assert_eq!(unix_seconds("2026-13-01T00:00:00Z"), None);
    }

    #[test]
    fn timestamps_reject_impossible_dates_and_bad_grammar() {
        for bad in [
            "2026-02-31T00:00:00Z",
            "2026-02-29T00:00:00Z",
            "2026-04-31T00:00:00Z",
            "2026-10-01T00:00:00+99:99",
            "2026-10-01T00:00:00+05:60",
            "2026-10-01T00x00x00Z",
            "2026-10-01T00:00:00.Z",
            "2026-10-01T-1:00:00Z",
            "2026-10-01T24:00:00Z",
            "2026-10-01T00:00:00",
            "2026-10-01",
            "2026-10-01T00:00:00Z trailing",
            "",
        ] {
            assert_eq!(unix_seconds(bad), None, "{bad}");
        }
    }

    #[test]
    fn timestamps_accept_leap_days_offsets_and_equivalent_forms() {
        assert_eq!(unix_seconds("2024-02-29T00:00:00Z"), Some(1_709_164_800));
        assert_eq!(unix_seconds("2000-02-29T00:00:00Z"), Some(951_782_400));
        assert_eq!(unix_seconds("1900-02-29T00:00:00Z"), None, "1900 is not a leap year");
        let instant = Some(1_790_812_800);
        for same in [
            "2026-10-01T00:00:00Z",
            "2026-10-01t00:00:00z",
            "2026-10-01 00:00:00Z",
            "2026-10-01T00:00:00.999999999Z",
            "2026-10-01T00:00:00+00:00",
            "2026-10-01T00:00:00-00:00",
            "2026-10-01T05:30:00+05:30",
            "2026-09-30T14:00:00-10:00",
        ] {
            assert_eq!(unix_seconds(same), instant, "{same}");
        }
    }
}
