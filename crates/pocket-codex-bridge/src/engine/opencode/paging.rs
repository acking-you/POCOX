//! Selected-turn windows walk the native opaque message cursor in bounded
//! pages. Finding no items in one page never means the turn is absent.

use super::{
    super::app_session::{ThreadItem, TurnItemsPage},
    *,
};

#[derive(Clone, Default)]
pub(super) struct Page {
    before: Option<String>,
    items: Vec<ThreadItem>,
    done: bool,
}

impl Page {
    fn bytes(&self) -> usize {
        self.items
            .iter()
            .map(|i| {
                i.text.len() + i.title.len() + i.images.iter().map(String::len).sum::<usize>() + 512
            })
            .sum()
    }
}

pub(super) fn read(
    service: &str,
    session: &str,
    turn: &str,
    more: bool,
    delta: bool,
) -> Result<TurnItemsPage> {
    let link = conn(service)?;
    read_link(&link, session, turn, more, delta)
}

fn read_link(
    link: &Link,
    session: &str,
    turn: &str,
    more: bool,
    delta: bool,
) -> Result<TurnItemsPage> {
    let identity = link.identity();
    let key = (session.to_owned(), turn.to_owned());
    let previous = if more {
        lock(&link.shared)
            .turn_pages
            .get(&key)
            .cloned()
            .ok_or_else(|| anyhow!("this turn window expired; reopen the turn"))?
    } else {
        Page::default()
    };
    if previous.done {
        return Ok(TurnItemsPage {
            turn_id: turn.into(),
            items: if delta { vec![] } else { previous.items },
            has_more: false,
        });
    }
    let snapshot = block(link.client.snapshot(session, previous.before.as_deref()))?;
    validate_snapshot(&identity, &snapshot)?;
    if snapshot.session.id != session {
        bail!("OpenCode returned another session");
    }
    let next = advance(previous.clone(), &snapshot, turn)?;
    let new_items: Vec<_> = next
        .items
        .iter()
        .filter(|i| !previous.items.iter().any(|old| old.id == i.id))
        .cloned()
        .collect();
    link.commit(&identity, |view| {
        if more && view.turn_pages.get(&key).map(|page| &page.before) != Some(&previous.before) {
            bail!("the native turn cursor changed; reopen the turn");
        }
        view.turn_pages.remove(&key);
        while view.turn_pages.len() >= 8
            || view.turn_pages.values().map(Page::bytes).sum::<usize>() + next.bytes()
                > 16 * 1024 * 1024
        {
            let Some(victim) = view.turn_pages.keys().next().cloned() else { break };
            view.turn_pages.remove(&victim);
        }
        view.turn_pages.insert(key, next.clone());
        Ok(())
    })??;
    Ok(TurnItemsPage {
        turn_id: turn.into(),
        items: if delta { new_items } else { next.items },
        has_more: !next.done,
    })
}

fn advance(mut previous: Page, snapshot: &Snapshot, turn: &str) -> Result<Page> {
    if previous.before.is_some() && snapshot.window.next_before == previous.before {
        bail!("OpenCode returned a repeated message cursor");
    }
    let mut items: Vec<_> = projection::items(snapshot)
        .into_iter()
        .filter(|i| i.turn_id == turn)
        .collect();
    items.extend(
        previous
            .items
            .into_iter()
            .filter(|old| !items_contains(snapshot, turn, &old.id)),
    );
    previous.items = items;
    previous.done = snapshot
        .window
        .messages
        .iter()
        .any(|m| m.info["role"] == "user" && m.info["id"] == turn)
        || snapshot.window.next_before.is_none();
    previous.before = snapshot.window.next_before.clone();
    if previous.bytes() > 16 * 1024 * 1024 {
        bail!(
            "this native turn exceeds the selected-window limit; read it through ordinary history \
             pages"
        );
    }
    if previous.done && previous.items.is_empty() {
        bail!("this native turn is no longer available");
    }
    Ok(previous)
}

fn items_contains(snapshot: &Snapshot, turn: &str, id: &str) -> bool {
    snapshot.window.messages.iter().any(|m| {
        let owns = m.info["id"] == turn || m.info["parentID"] == turn;
        owns && (m.info["id"] == id || m.parts.iter().any(|p| p["id"] == id))
    })
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    #[test]
    fn message_page_boundary_does_not_cut_a_native_turn_short() {
        let mut snapshot = super::super::tests::snapshot();
        snapshot.window.messages.remove(0);
        let first = advance(Page::default(), &snapshot, "msg_user").expect("assistant-only page");
        assert!(!first.done);
        assert_eq!(first.items.len(), 1);
        snapshot.window.messages =
            vec![serde_json::from_value(json!({"info":{"id":"msg_user","role":"user"},
            "parts":[{"id":"prt_user","type":"text","text":"Question"}]}))
            .expect("user")];
        snapshot.window.next_before = Some("older_native_cursor".into());
        let all = advance(first, &snapshot, "msg_user").expect("complete native turn");
        assert!(all.done);
        assert_eq!(all.items.len(), 2);
        assert_eq!(all.items[0].item_type, "userMessage");
    }
    #[test]
    fn empty_newer_page_keeps_search_cursor() {
        let snapshot = super::super::tests::snapshot();
        let next =
            advance(Page::default(), &snapshot, "msg_older").expect("older turn not reached");
        assert!(!next.done);
        assert!(next.items.is_empty());
        assert!(
            advance(next, &snapshot, "msg_older").is_err(),
            "repeated cursor cannot loop forever"
        );
    }
}
