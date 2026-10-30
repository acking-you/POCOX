//! Reconcile the bounded live buffer with an authoritative history window.

use std::collections::{HashMap, HashSet};

use anyhow::{Context, Result};

use super::{ThreadItem, TurnSummary};
use crate::engine::history_projection;

/// Preserve stream-only prefixes and suffixes around the history's item order.
pub(super) fn reconcile(
    mut history: Vec<ThreadItem>,
    mut buffered: Vec<ThreadItem>,
    turns: &[TurnSummary],
    active_turn: Option<&str>,
) -> Result<Vec<ThreadItem>> {
    let positions: HashMap<_, _> = history
        .iter()
        .enumerate()
        .map(|(index, item)| (item.id.clone(), index))
        .collect();
    // A stream may first observe an item without its turn. Recovered metadata
    // puts that same identity in one group instead of emitting it twice.
    for item in &mut buffered {
        if let Some(&at) = positions.get(&item.id) {
            item.turn_id.clone_from(&history[at].turn_id);
        }
    }
    let retained_turns: HashSet<_> = history.iter().map(|item| item.turn_id.as_str()).collect();
    let anchored_turns: HashSet<_> = buffered
        .iter()
        .filter_map(|item| {
            positions
                .get(&item.id)
                .map(|at| history[*at].turn_id.as_str())
        })
        .collect();
    // A bounded window is not a complete turn. With no common identity there
    // is no evidence that a cached item belongs after it. Leave that turn's
    // disjoint buffer outside this window; it remains in the live cache and
    // can be recovered by history paging. Active and new turns still show
    // fresh output immediately, even before it enters a history snapshot.
    let buffered: Vec<_> = buffered
        .into_iter()
        .filter(|item| {
            item.turn_id.is_empty()
                || active_turn == Some(item.turn_id.as_str())
                || !retained_turns.contains(item.turn_id.as_str())
                || anchored_turns.contains(item.turn_id.as_str())
        })
        .collect();
    let order = history_projection::merge(
        &buffered
            .iter()
            .map(|item| item.id.clone())
            .collect::<Vec<_>>(),
        &buffered
            .iter()
            .map(|item| item.turn_id.clone())
            .collect::<Vec<_>>(),
        &history
            .iter()
            .map(|item| item.id.clone())
            .collect::<Vec<_>>(),
        &history
            .iter()
            .map(|item| item.turn_id.clone())
            .collect::<Vec<_>>(),
        &turns
            .iter()
            .map(|turn| turn.turn_id.clone())
            .collect::<Vec<_>>(),
        true,
    )?;
    // History owns completed content and turn metadata. Async questions are
    // live-only, and a newer approval review must not regress to inProgress.
    let mut selected: Vec<_> = (0..buffered.len() + history.len()).collect();
    for (index, item) in buffered.iter().enumerate() {
        if let Some(&at) = positions.get(&item.id) {
            if item.item_type == "autoApprovalReview"
                && (history[at].title == "inProgress" || item.title != "inProgress")
            {
                continue;
            }
            history[at].questions_json.clone_from(&item.questions_json);
            selected[index] = buffered.len() + at;
        }
    }
    let mut source: Vec<_> = buffered.into_iter().chain(history).map(Some).collect();
    order
        .into_iter()
        .map(|index| {
            source[selected[index as usize]]
                .take()
                .context("history projection repeated an item identity")
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, turn: &str) -> ThreadItem {
        ThreadItem {
            id: id.into(),
            turn_id: turn.into(),
            item_type: "commandExecution".into(),
            title: String::new(),
            text: id.into(),
            questions_json: None,
            images: Vec::new(),
            turn_completed_at: None,
            turn_duration_ms: None,
        }
    }

    #[test]
    fn a_hundred_buffered_items_do_not_follow_the_twenty_item_history_tail() {
        let buffered: Vec<_> = (0..100).map(|i| item(&i.to_string(), "turn")).collect();
        let mut history = buffered[80..].to_vec();
        history[19].item_type = "agentMessage".into();
        history[19].text = "complete final answer".into();
        let result = reconcile(history, buffered, &[], None).unwrap();
        assert_eq!(
            result.iter().map(|i| i.id.clone()).collect::<Vec<_>>(),
            (0..100).map(|i| i.to_string()).collect::<Vec<_>>()
        );
        assert_eq!(result.last().unwrap().text, "complete final answer");
    }

    #[test]
    fn authoritative_order_repairs_late_first_observations_and_keeps_new_turns() {
        let result = reconcile(
            vec![item("a", "one"), item("b", "one"), item("answer", "one")],
            vec![item("b", "one"), item("answer", "one"), item("a", "one"), item("new", "two")],
            &[],
            None,
        )
        .unwrap();
        assert_eq!(result.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), [
            "a", "b", "answer", "new"
        ]);
    }

    #[test]
    fn an_unanchored_old_buffer_cannot_change_the_tail_order() {
        let result = reconcile(
            vec![item("recent", "one"), item("answer", "one")],
            vec![item("outside-window", "one")],
            &[],
            None,
        )
        .unwrap();
        assert_eq!(result.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), ["recent", "answer"]);
    }

    #[test]
    fn history_content_and_live_questions_and_reviews_keep_their_owners() {
        let mut old = item("message", "one");
        old.text = "stale prefix".into();
        old.questions_json = Some("[]".into());
        let mut complete = item("message", "one");
        complete.text = "complete answer".into();
        complete.turn_completed_at = Some(100);
        let mut pending = item("review", "one");
        pending.item_type = "autoApprovalReview".into();
        pending.title = "inProgress".into();
        let mut reviewed = pending.clone();
        reviewed.title = "completed".into();
        let result = reconcile(
            vec![complete, pending],
            vec![old, reviewed, item("streaming", "one")],
            &[],
            Some("one"),
        )
        .unwrap();
        assert_eq!(result[0].text, "complete answer");
        assert_eq!(result[0].turn_completed_at, Some(100));
        assert_eq!(result[0].questions_json.as_deref(), Some("[]"));
        assert_eq!(result[1].title, "completed");
        assert_eq!(result[2].id, "streaming");
    }

    #[test]
    fn a_running_turn_keeps_new_items_even_before_the_next_history_snapshot() {
        let result =
            reconcile(vec![item("user", "one")], vec![item("streaming", "one")], &[], Some("one"))
                .unwrap();
        assert_eq!(result.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), ["user", "streaming"]);
    }

    #[test]
    fn recovered_turn_metadata_places_a_shared_identity_once() {
        let result =
            reconcile(vec![item("answer", "one")], vec![item("answer", "")], &[], None).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].turn_id, "one");
    }
}
