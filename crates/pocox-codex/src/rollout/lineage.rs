//! Follow a paginated fork back through the rollouts it references.
//!
//! A fork of a paginated thread copies nothing: its own rollout starts with a
//! `history_base` naming the parent rollout and how many of that file's leading
//! bytes belong to the fork. Those bytes never change, so reading them from a
//! file another client is still appending to is safe. Ancestors live in the
//! same Codex home as the fork, active or archived.

use std::collections::HashSet;
use std::io::{BufRead, Read};
use std::path::{Path, PathBuf};

use pocox_core::Result;
use serde_json::Value;

use super::{open_rollout, read_head, rollout_path_in};

/// Archived rollouts keep their history, and forks may still reference them.
const HISTORY_DIRS: [&str; 2] = ["sessions", "archived_sessions"];

/// One file of a rollout's logical history.
pub(super) struct Segment {
    path: PathBuf,
    /// Leading bytes that belong to the history; `None` for the requested
    /// rollout itself, which is read to its end.
    end_byte_offset: Option<u64>,
}

impl Segment {
    /// Open the part of this file that belongs to the history.
    pub(super) fn open(&self) -> Result<Box<dyn BufRead + Send>> {
        let reader = open_rollout(&self.path)?;
        Ok(match self.end_byte_offset {
            Some(end) => Box::new(reader.take(end)),
            None => reader,
        })
    }

    /// Whether this is a referenced ancestor rather than the requested rollout.
    pub(super) fn is_ancestor(&self) -> bool {
        self.end_byte_offset.is_some()
    }
}

/// The files holding `path`'s history, oldest first, ending with `path`.
///
/// An unreadable or missing ancestor ends the walk: what remains is still that
/// rollout's own record, and these readers only serve read-only views.
pub(super) fn segments(path: &Path) -> Vec<Segment> {
    let mut chain = vec![Segment {
        path: path.to_path_buf(),
        end_byte_offset: None,
    }];
    let mut seen = HashSet::new();
    let mut current = path.to_path_buf();
    while let Some((rollout_id, end_byte_offset)) = history_base(&current) {
        if !seen.insert(rollout_id.clone()) {
            break;
        }
        let Some(ancestor) = locate(path, &rollout_id) else {
            break;
        };
        chain.push(Segment {
            path: ancestor.clone(),
            end_byte_offset: Some(end_byte_offset),
        });
        current = ancestor;
    }
    chain.reverse();
    chain
}

/// The parent rollout id and inherited byte count a rollout's header declares.
fn history_base(path: &Path) -> Option<(String, u64)> {
    let head = read_head(path, 1).ok()?;
    let line: Value = serde_json::from_str(head.lines().next()?).ok()?;
    if line.get("type").and_then(Value::as_str) != Some("session_meta") {
        return None;
    }
    let base = line.pointer("/payload/history_base")?;
    // Named `thread_id` upstream, but it identifies the rollout file.
    let rollout_id = base.get("thread_id")?.as_str()?;
    let end_byte_offset = base.get("end_byte_offset")?.as_u64()?;
    Some((rollout_id.to_owned(), end_byte_offset))
}

/// Find `rollout_id` in the Codex home that holds `path`.
fn locate(path: &Path, rollout_id: &str) -> Option<PathBuf> {
    let home = path
        .ancestors()
        .find(|dir| {
            dir.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| HISTORY_DIRS.contains(&name))
        })?
        .parent()?;
    HISTORY_DIRS
        .iter()
        .find_map(|dir| rollout_path_in(&home.join(dir), rollout_id).ok().flatten())
}
