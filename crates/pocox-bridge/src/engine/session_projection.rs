//! Per-subscriber live projection. Only complete item snapshots establish a
//! text prefix; delta-only reconnects remain partial until history recovers.
use std::collections::{HashMap, VecDeque};

use serde_json::Value;

use super::app_session::AppEvent;

const MAX_ITEMS: usize = 512;
const MAX_BYTES: usize = 16 << 20;
type Key = (String, String);

/// A native event with item metadata already decoded for the controller.
pub struct ProjectedEvent {
    /// Native-decoded thread activity, absent when the event says nothing.
    pub running: Option<bool>,
    /// Parsed file changes, attached by the delivering feed.
    pub diff: Option<super::git_diff::Diff>,
    /// Original event, with a coalesced delta or complete projected text.
    pub event: AppEvent,
    /// Explicit item turn; lifecycle events may also use `turn.id` or `id`.
    pub turn_id: Option<String>,
    /// Missing means unknown; empty means the host explicitly names no client.
    pub sender: Option<String>,
    /// A delta's text includes its confirmed prefix and replaces displayed
    /// text.
    pub text_is_snapshot: bool,
}

/// Bounded text ownership for a single controller subscription.
#[derive(Default)]
pub struct Projection {
    text: HashMap<Key, String>,
    order: VecDeque<Key>,
    bytes: usize,
}

/// Delta methods whose text concatenates without losing structured fields.
pub fn text_delta(event: &AppEvent) -> bool {
    matches!(
        event.kind.as_str(),
        "item/agentMessage/delta"
            | "item/commandExecution/outputDelta"
            | "item/reasoning/textDelta"
            | "item/reasoning/summaryTextDelta"
    ) && event.request_id.is_none()
        && event.item_id.is_some()
        && event.thread_id.is_some()
}

/// Whether two adjacent events can share a frame without crossing a boundary.
pub fn can_merge(a: &AppEvent, b: &AppEvent) -> bool {
    text_delta(a)
        && text_delta(b)
        && a.kind == b.kind
        && a.thread_id == b.thread_id
        && a.item_id == b.item_id
        && a.text.as_ref().map_or(0, String::len) + b.text.as_ref().map_or(0, String::len)
            <= 64 << 10
}

impl Projection {
    /// Apply an event once, retaining prefixes only while they fit the budget.
    pub fn apply(&mut self, mut event: AppEvent) -> ProjectedEvent {
        let mut params: Value = serde_json::from_str(&event.raw).unwrap_or(Value::Null);
        let turn_id = params
            .get("turnId")
            .and_then(Value::as_str)
            .or_else(|| {
                (!event.kind.starts_with("item/"))
                    .then(|| {
                        params
                            .get("id")
                            .and_then(Value::as_str)
                            .or_else(|| params.get("turn")?.get("id")?.as_str())
                    })
                    .flatten()
            })
            .filter(|id| !id.is_empty())
            .map(str::to_owned);
        let running = match event.kind.as_str() {
            "turn/started" => Some(true),
            "turn/completed" | "turn/failed" => Some(false),
            "thread/status/changed" => params
                .get("status")
                .and_then(|s| s.get("type"))
                .and_then(Value::as_str)
                .map(|s| s == "active"),
            _ => None,
        };
        let sender = params
            .get("clientId")
            .map(|id| id.as_str().unwrap_or_default().to_owned());
        let delta = text_delta(&event);
        let mut text_is_snapshot = false;
        if let (Some(thread), Some(id)) = (&event.thread_id, &event.item_id) {
            let key = (thread.clone(), id.clone());
            if delta {
                if let Some(text) = self.text.get_mut(&key) {
                    self.bytes -= text.capacity();
                    text.push_str(event.text.as_deref().unwrap_or_default());
                    self.bytes += text.capacity();
                    event.text = Some(text.clone());
                    text_is_snapshot = true;
                }
                // The typed text field is authoritative for these four methods.
                if let Some(object) = params.as_object_mut() {
                    object.remove("delta");
                }
                event.raw = params.to_string();
            } else if matches!(
                event.item_type.as_deref(),
                Some("agentMessage" | "commandExecution" | "reasoning")
            ) {
                let text = event.text.clone().unwrap_or_default();
                // Empty agent lifecycle edges preserve preceding streamed text.
                if !text.is_empty()
                    || event.item_type.as_deref() != Some("agentMessage")
                    || !self.text.contains_key(&key)
                {
                    if let Some(old) = self.text.insert(key.clone(), text.clone()) {
                        self.bytes -= old.capacity();
                    } else {
                        self.order.push_back(key);
                    }
                    self.bytes += text.capacity();
                }
            }
        }
        while self.text.len() > MAX_ITEMS || self.bytes > MAX_BYTES {
            let Some(key) = self.order.pop_front() else { break };
            if let Some(old) = self.text.remove(&key) {
                self.bytes -= old.capacity();
            }
        }
        ProjectedEvent {
            running,
            diff: None,
            event,
            turn_id,
            sender,
            text_is_snapshot,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn event(kind: &str, text: &str) -> AppEvent {
        AppEvent {
            kind: kind.into(),
            thread_id: Some("thread".into()),
            item_id: Some("item".into()),
            item_type: Some("agentMessage".into()),
            title: None,
            text: Some(text.into()),
            images: vec![],
            request_id: None,
            raw: r#"{"turnId":"turn","clientId":"","delta":"payload"}"#.into(),
        }
    }
    #[test]
    fn reconnect_suffixes_are_not_presented_as_complete_prefixes() {
        let mut view = Projection::default();
        assert!(
            !view
                .apply(event("item/agentMessage/delta", "suffix"))
                .text_is_snapshot
        );
        view.apply(event("item/started", "prefix"));
        let update = view.apply(event("item/agentMessage/delta", " suffix"));
        assert_eq!(update.event.text.as_deref(), Some("prefix suffix"));
        assert!(update.text_is_snapshot);
        assert!(!update.event.raw.contains("delta"));
        assert_eq!(update.turn_id.as_deref(), Some("turn"));
        assert_eq!(update.sender.as_deref(), Some(""));
        assert!(!can_merge(&event("item/agentMessage/delta", "x"), &event("item/completed", "x")));
    }
}
