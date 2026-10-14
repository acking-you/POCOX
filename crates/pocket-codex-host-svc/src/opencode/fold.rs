//! Host-owned native stream state. Controllers receive invalidations, never
//! native deltas: HTTP history has no atomic cursor with the native stream.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{
    events::Event,
    public,
    schema::{Message, MessagePage, Status},
};

const MAX_BYTES: usize = 8 * 1024 * 1024;
const MAX_MESSAGES: usize = 128;

#[derive(Default)]
struct LiveMessage {
    info: Value,
    parts: BTreeMap<String, Value>,
    gaps: BTreeSet<String>,
    touched: u64,
    removed: bool,
    removed_parts: BTreeSet<String>,
}

/// A bounded public native history window with a host event watermark.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    /// Original native messages, in ascending identifier order.
    pub messages: Vec<Message>,
    /// Opaque native pagination cursor.
    pub next_before: Option<String>,
    /// Host observation number; later changes invalidate this window.
    pub sequence: u64,
    /// Part IDs with an incomplete live prefix after a transport interruption.
    pub gaps: Vec<String>,
    /// Whether the upstream stream currently has a confirmed connection.
    pub connected: bool,
}

/// Bounded live overlay. A full native part replaces earlier deltas; after a
/// gap only another full update can restore that part's synchronized prefix.
#[derive(Default)]
pub struct Fold {
    messages: BTreeMap<(String, String), LiveMessage>,
    sequence: u64,
    connected: bool,
    bytes: usize,
    statuses: BTreeMap<String, (u64, Status, u64)>,
}

impl Fold {
    /// Current observation number, including upstream stream transitions.
    pub fn sequence(&self) -> u64 {
        self.sequence
    }

    /// Stream readiness, required before accepting writes.
    pub fn connected(&self) -> bool {
        self.connected
    }

    /// Latest status sequence/value and last positive busy sequence. An old
    /// idle event alone cannot complete a newly dispatched prompt.
    pub fn status(&self, session: &str) -> Option<(u64, Status, u64)> {
        self.statuses.get(session).cloned()
    }

    /// Mark every retained text prefix uncertain when upstream events are lost.
    pub fn disconnect(&mut self) {
        self.sequence += 1;
        self.connected = false;
        for message in self.messages.values_mut() {
            message.gaps.extend(
                message
                    .parts
                    .iter()
                    .filter(|(_, part)| {
                        matches!(part["type"].as_str(), Some("text" | "reasoning"))
                            && part["time"]["end"].is_null()
                    })
                    .map(|(id, _)| id.clone()),
            );
        }
    }

    /// Apply a native event once. The result identifies the session whose
    /// public window changed; no raw event properties cross the gateway.
    pub fn apply(&mut self, event: Event) -> Option<String> {
        self.sequence += 1;
        if event.kind == "server.connected" {
            self.connected = true;
            return None;
        }
        let properties = &event.properties;
        let object = match event.kind.as_str() {
            "message.updated" => &properties["info"],
            "message.part.updated" => &properties["part"],
            _ => properties,
        };
        let session = object["sessionID"].as_str()?.to_owned();
        if event.kind == "session.status" {
            if let Ok(status) = serde_json::from_value::<Status>(object["status"].clone()) {
                let busy = if status.running() {
                    self.sequence
                } else {
                    self.statuses.get(&session).map_or(0, |(_, _, busy)| *busy)
                };
                self.statuses
                    .insert(session.clone(), (self.sequence, status, busy));
                if self.statuses.len() > 256 {
                    if let Some(key) = self
                        .statuses
                        .iter()
                        .min_by_key(|(_, (seq, _, _))| seq)
                        .map(|(key, _)| key.clone())
                    {
                        self.statuses.remove(&key);
                    }
                }
            }
        }
        let message_id = if event.kind == "message.updated" {
            object["id"].as_str()
        } else {
            object["messageID"].as_str()
        };
        let Some(message_id) = message_id else { return Some(session) };
        let key = (session.clone(), message_id.to_owned());
        let message = self.messages.entry(key).or_default();
        let previous = size(message);
        message.touched = self.sequence;
        match event.kind.as_str() {
            "message.removed" => {
                message.removed = true;
                message.parts.clear();
                message.gaps.clear();
                message.info = Value::Null;
            },
            "message.updated" => message.info = public::info(object),
            "message.part.updated" => {
                if let Some(part) = public::part(object) {
                    if let Some(id) = part["id"].as_str().map(str::to_owned) {
                        message.gaps.remove(&id);
                        message.removed_parts.remove(&id);
                        message.parts.insert(id, part);
                    }
                }
            },
            "message.part.delta" => delta(message, object),
            "message.part.removed" => {
                if let Some(id) = object["partID"].as_str() {
                    message.parts.remove(id);
                    message.gaps.remove(id);
                    message.removed_parts.insert(id.into());
                }
            },
            _ => {},
        }
        self.bytes = self
            .bytes
            .saturating_sub(previous)
            .saturating_add(size(message));
        while self.bytes > MAX_BYTES || self.messages.len() > MAX_MESSAGES {
            let key = self
                .messages
                .iter()
                .min_by_key(|(_, m)| m.touched)
                .map(|(key, _)| key.clone());
            let Some(key) = key else { break };
            if let Some(message) = self.messages.remove(&key) {
                self.bytes = self.bytes.saturating_sub(size(&message));
            }
        }
        Some(session)
    }

    /// Merge a native page with retained live parts. A completed HTTP part is
    /// authoritative even when its final event is still in flight. Controllers
    /// refetch on invalidation, so they never append a delta twice.
    pub fn window(&self, session: &str, page: MessagePage, tail: bool) -> Window {
        let mut messages: BTreeMap<String, Message> = page
            .messages
            .into_iter()
            .map(public::message)
            .filter_map(|m| Some((m.info["id"].as_str()?.into(), m)))
            .collect();
        let mut gaps = BTreeSet::new();
        let first = messages.keys().next().cloned();
        for ((sid, id), live) in &self.messages {
            if sid != session || (!tail && !messages.contains_key(id)) {
                continue;
            }
            if tail && first.as_ref().is_some_and(|first| id < first) {
                continue;
            }
            if live.removed {
                messages.remove(id);
                continue;
            }
            if !messages.contains_key(id) && !live.info.is_object() {
                continue;
            }
            let message = messages.entry(id.clone()).or_insert_with(|| Message {
                info: live.info.clone(),
                parts: vec![],
            });
            if live.info.is_object() && message.info["time"]["completed"].is_null() {
                message.info = live.info.clone();
            }
            let mut parts: BTreeMap<String, Value> = std::mem::take(&mut message.parts)
                .into_iter()
                .filter_map(|p| Some((p["id"].as_str()?.into(), p)))
                .collect();
            for (id, part) in &live.parts {
                let complete = parts.get(id).is_some_and(|p| {
                    p["time"]["end"].is_number() || p["state"]["time"]["end"].is_number()
                });
                if complete {
                    continue;
                }
                if live.gaps.contains(id) {
                    gaps.insert(id.clone());
                }
                parts.insert(id.clone(), part.clone());
            }
            gaps.extend(
                live.gaps
                    .iter()
                    .filter(|id| !parts.contains_key(*id))
                    .cloned(),
            );
            for id in &live.removed_parts {
                parts.remove(id);
            }
            message.parts = parts.into_values().collect();
        }
        for (id, message) in &messages {
            for part in &message.parts {
                let Some(part_id) = part["id"].as_str() else { continue };
                if message.info["role"] == "assistant"
                    && message.info["time"]["completed"].is_null()
                    && matches!(part["type"].as_str(), Some("text" | "reasoning"))
                    && part["time"]["end"].is_null()
                    && !self
                        .messages
                        .get(&(session.into(), id.clone()))
                        .is_some_and(|live| live.parts.contains_key(part_id))
                {
                    gaps.insert(part_id.into());
                }
            }
        }
        Window {
            messages: messages.into_values().collect(),
            next_before: page.next_before,
            sequence: self.sequence,
            gaps: gaps.into_iter().collect(),
            connected: self.connected,
        }
    }
}

fn size(message: &LiveMessage) -> usize {
    message.info.to_string().len()
        + message
            .parts
            .values()
            .map(|v| v.to_string().len())
            .sum::<usize>()
        + message.gaps.iter().map(String::len).sum::<usize>()
        + message.removed_parts.iter().map(String::len).sum::<usize>()
}

fn delta(message: &mut LiveMessage, value: &Value) {
    let Some(id) = value["partID"].as_str() else { return };
    if value["field"] != "text" || message.gaps.contains(id) {
        return;
    }
    let Some(part) = message.parts.get_mut(id) else {
        message.gaps.insert(id.into());
        return;
    };
    let Some(delta) = value["delta"].as_str() else { return };
    if !matches!(part["type"].as_str(), Some("text" | "reasoning")) {
        return;
    }
    let Some(text) = part["text"].as_str() else { return };
    part["text"] = Value::String(format!("{text}{delta}"));
}

#[cfg(test)]
mod tests;
