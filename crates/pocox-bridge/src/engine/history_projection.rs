//! Chronological history merging using identity metadata only. The controller
//! keeps its presentation objects; existing indices always win shared IDs.
use std::collections::{HashMap, HashSet};

use anyhow::{ensure, Result};

type Key<'a> = (&'a str, Option<&'a str>);
type Groups<'a> = HashMap<Key<'a>, Vec<usize>>;

fn group<'a>(ids: &'a [String], turns: &'a [String], offset: usize) -> (Vec<Key<'a>>, Groups<'a>) {
    let mut order = Vec::new();
    let mut groups = HashMap::<_, Vec<_>>::new();
    for (index, (id, turn)) in ids.iter().zip(turns).enumerate() {
        let key = (turn.as_str(), turn.is_empty().then_some(id.as_str()));
        let rows = groups.entry(key).or_insert_with(|| {
            order.push(key);
            Vec::new()
        });
        rows.push(offset + index);
    }
    (order, groups)
}

/// Return indices into `current_ids` followed by `incoming_ids`. Unknown turns
/// retain their relative position, and repeated incoming identities emit once.
pub fn merge(
    current_ids: &[String],
    current_turns: &[String],
    incoming_ids: &[String],
    incoming_turns: &[String],
    turn_order: &[String],
    older_page: bool,
) -> Result<Vec<u32>> {
    ensure!(
        current_ids.len() == current_turns.len() && incoming_ids.len() == incoming_turns.len(),
        "history identity columns differ in length"
    );
    let rows = current_ids.len() + incoming_ids.len();
    ensure!(
        rows <= 100_000 && turn_order.len() <= 100_000,
        "history projection exceeds the row budget"
    );
    let bytes: usize = [current_ids, current_turns, incoming_ids, incoming_turns, turn_order]
        .into_iter()
        .flatten()
        .map(String::len)
        .sum();
    ensure!(bytes <= 16 << 20, "history projection exceeds the identity budget");
    let (existing, old) = group(current_ids, current_turns, 0);
    let (page_order, pages) = group(incoming_ids, incoming_turns, current_ids.len());
    let known: HashSet<Key<'_>> = turn_order.iter().map(|id| (id.as_str(), None)).collect();
    let first = existing
        .iter()
        .position(|key| known.contains(key))
        .unwrap_or(0);
    let mut seen = HashSet::new();
    let mut order: Vec<_> = existing[..first]
        .iter()
        .copied()
        .chain(turn_order.iter().map(|id| (id.as_str(), None)))
        .chain(existing.iter().copied())
        .filter(|key| seen.insert(*key))
        .collect();
    let missing = page_order
        .into_iter()
        .filter(|key| seen.insert(*key))
        .collect::<Vec<_>>();
    if older_page {
        order.splice(0..0, missing);
    } else {
        order.extend(missing);
    }
    let ids: Vec<_> = current_ids.iter().chain(incoming_ids).collect();
    let mut out = Vec::with_capacity(rows);
    for key in order {
        merge_turn(
            old.get(&key).map_or(&[], Vec::as_slice),
            pages.get(&key).map_or(&[], Vec::as_slice),
            &ids,
            older_page,
            &mut out,
        );
    }
    Ok(out.into_iter().map(|index| index as u32).collect())
}

fn merge_turn(
    current: &[usize],
    incoming: &[usize],
    ids: &[&String],
    older: bool,
    out: &mut Vec<usize>,
) {
    let positions: HashMap<_, _> = current
        .iter()
        .enumerate()
        .map(|(at, index)| (ids[*index], at))
        .collect();
    let mut seen = HashSet::new();
    let mut pending = Vec::new();
    let mut next = 0;
    let mut anchored = false;
    for index in incoming {
        if !seen.insert(ids[*index]) {
            continue;
        }
        match positions.get(ids[*index]) {
            None => pending.push(*index),
            Some(&at) if at >= next => {
                out.extend_from_slice(&current[next..at]);
                out.append(&mut pending);
                out.push(current[at]);
                next = at + 1;
                anchored = true;
            },
            _ => {},
        }
    }
    if anchored || older {
        out.append(&mut pending);
        out.extend_from_slice(&current[next..]);
    } else {
        out.extend_from_slice(current);
        out.append(&mut pending);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn run(old: &[(&str, &str)], page: &[(&str, &str)], turns: &[&str], older: bool) -> Vec<u32> {
        merge(
            &old.iter().map(|r| r.0.into()).collect::<Vec<_>>(),
            &old.iter().map(|r| r.1.into()).collect::<Vec<_>>(),
            &page.iter().map(|r| r.0.into()).collect::<Vec<_>>(),
            &page.iter().map(|r| r.1.into()).collect::<Vec<_>>(),
            &turns.iter().map(|s| (*s).into()).collect::<Vec<_>>(),
            older,
        )
        .unwrap()
    }
    #[test]
    fn pages_preserve_live_objects_disjoint_turns_and_anonymous_rows() {
        assert_eq!(
            run(
                &[("a1", "t1"), ("a5", "t5")],
                &[("a2", "t2"), ("a3", "t3")],
                &["t1", "t2", "t3", "t4", "t5"],
                true
            ),
            [0, 2, 3, 1]
        );
        assert_eq!(
            run(
                &[("tail", "t1")],
                &[("opening", "t1"), ("tail", "t1"), ("after", "t1")],
                &["t1"],
                false
            ),
            [1, 0, 3]
        );
        assert_eq!(
            run(
                &[("old", "t1"), ("optimistic", ""), ("live", "t2"), ("next", "")],
                &[("older", "t0")],
                &["t0", "t1"],
                true
            ),
            [4, 0, 1, 2, 3]
        );
        assert_eq!(
            run(
                &[("outside", "t0"), ("latest", "t5")],
                &[("oldest", "before"), ("middle", "t3")],
                &["t2", "t3", "t4", "t5"],
                true
            ),
            [2, 0, 3, 1]
        );
        assert_eq!(run(&[("tail", "t1")], &[("older", "t1"), ("older", "t1")], &["t1"], true), [
            1, 0
        ]);
    }
    #[test]
    fn rejects_misaligned_columns_before_reading_indices() {
        assert!(merge(&["a".into()], &[], &[], &[], &[], false).is_err());
    }
}
