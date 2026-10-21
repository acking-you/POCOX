//! Folding ACP `session/update` notifications into a bounded transcript.
//!
//! The host folds every update it receives (live and `session/load` replay)
//! so a controller that connects later can read the conversation; the
//! controller folds the same live updates with this same code (see
//! [`super::replica`]) to produce item events, so live and reloaded views
//! agree on item ids and text.
//!
//! Folding follows the schema's replacement rules: a `tool_call_update`
//! replaces the `content` / `locations` collections it supplies, a `plan`
//! replaces the whole plan, and message chunks append to the message they
//! continue.
//!
//! # Bounds
//!
//! Every retained byte is charged to the transcript — text, titles, ids,
//! images, tool input, diffs, locations, plans and a fixed per-item
//! overhead — and the limits hold even inside one long turn:
//!
//! - an item keeps at most [`MAX_ITEM_TEXT`] of text, [`MAX_ITEM_IMAGES`]
//!   images within [`MAX_ITEM_IMAGE_BYTES`], and tool input up to
//!   [`MAX_RAW_INPUT`]. Text past its limit ends with a visible marker and sets
//!   `text_full` (later text is dropped); anything else dropped is named in
//!   `omitted` (`images`, `diffs`, `input`, …) so the UI can say so — losing an
//!   image never stops the text that follows it. Both set `truncated`;
//! - past [`MAX_TRANSCRIPT_BYTES`] / [`MAX_ITEMS`] / [`MAX_TURNS`] whole oldest
//!   turns are evicted first, then the oldest items of the remaining turn
//!   (never its prompt or its newest item), counted in `omitted`.
//!
//! Any eviction marks the transcript `truncated`: it never pretends to be
//! complete. Item ids come from a per-turn counter that is never reused, so
//! they stay stable across eviction and recovery.
//!
//! # Protocol ids
//!
//! Tool call and message ids are the agent's and are compared exactly. An
//! id longer than [`MAX_PROTOCOL_ID`] is kept as a fixed-size key — a
//! prefix plus its SHA-256 — that is longer than any id kept verbatim, so
//! distinct ids never alias and one id always maps to the same key.

use std::collections::VecDeque;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use self::tool::apply_tool_fields;
use super::schema::{available_commands, select_options, TurnOutcome};

/// Largest text retained per item (a truncation marker follows when cut).
pub const MAX_ITEM_TEXT: usize = 512 * 1024;
/// Largest retained transcript, counting every retained byte.
pub const MAX_TRANSCRIPT_BYTES: usize = 8 * 1024 * 1024;
/// Most retained items.
pub const MAX_ITEMS: usize = 4000;
/// Most retained turns.
pub const MAX_TURNS: usize = 500;
/// Largest total size of the inline images kept on one item.
pub const MAX_ITEM_IMAGE_BYTES: usize = 2 * 1024 * 1024;
/// Most inline images kept on one item.
pub const MAX_ITEM_IMAGES: usize = 8;
/// Largest retained tool input, serialized.
pub const MAX_RAW_INPUT: usize = 64 * 1024;
const MAX_DIFFS: usize = 64;
const MAX_LOCATIONS: usize = 64;
const MAX_LOCATION: usize = 4096;
/// Bookkeeping charged per retained item on top of its payload.
const ITEM_OVERHEAD: usize = 128;
const TRUNCATED: &str = "\n[… truncated]";
/// Longest agent id kept verbatim (see the module docs).
pub const MAX_PROTOCOL_ID: usize = 256;
/// Bytes of an oversized id kept before its digest.
const ID_PREFIX: usize = 192;

/// Omission reason: images over the item's image budget.
pub const OMITTED_IMAGES: &str = "images";
/// Omission reason: tool diffs over their budget.
pub const OMITTED_DIFFS: &str = "diffs";
/// Omission reason: tool input over [`MAX_RAW_INPUT`].
pub const OMITTED_INPUT: &str = "input";
/// Omission reason: tool locations over their limit.
pub const OMITTED_LOCATIONS: &str = "locations";
/// Omission reason: tool content entries over their limit.
pub const OMITTED_CONTENT: &str = "content";
/// Omission reason: plan entries over their limit.
pub const OMITTED_PLAN: &str = "plan";

/// The key an agent id is kept under: itself when short, otherwise a
/// collision-resistant fixed-size form that no verbatim id can equal.
pub fn protocol_key(raw: &str) -> String {
    if raw.len() <= MAX_PROTOCOL_ID {
        return raw.to_string();
    }
    let mut end = ID_PREFIX;
    while !raw.is_char_boundary(end) {
        end -= 1;
    }
    let digest = pocox_core::history_sync::digest_bytes(raw.as_bytes());
    format!("{}#sha256:{digest}", &raw[..end])
}

/// What a transcript item is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ItemKind {
    /// The user's prompt.
    UserMessage,
    /// Agent prose.
    AgentMessage,
    /// Agent reasoning.
    Thought,
    /// A tool call.
    ToolCall,
    /// The agent's plan.
    Plan,
}

/// A file modification reported in tool content.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Diff {
    /// File path as reported by the agent (display only).
    pub path: String,
    /// Previous content; `None` for a new file.
    pub old_text: Option<String>,
    /// New content.
    pub new_text: String,
}

/// Folded state of one tool call.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Tool {
    /// The agent's tool call id.
    pub call_id: String,
    /// Tool kind (`read`, `edit`, `execute`, …, or an unknown future value).
    pub kind: String,
    /// `pending` / `in_progress` / `completed` / `failed`.
    pub status: String,
    /// Programmatic tool name, when supplied.
    pub name: Option<String>,
    /// The agent's own finer kind, when it names one (Grok's
    /// `_meta["x.ai/tool"].kind`: `list_dir`, `web_search`, `task`, …).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<String>,
    /// Reported locations (display only; never file-read authority).
    pub locations: Vec<String>,
    /// Reported diffs.
    pub diffs: Vec<Diff>,
    /// Raw input, when supplied (replaced by a short note when too large).
    pub raw_input: Option<Value>,
    /// Embedded terminals (not supported by this client; counted only).
    pub terminals: usize,
}

/// One plan entry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanEntry {
    /// Task description.
    pub content: String,
    /// `pending` / `in_progress` / `completed`.
    pub status: String,
}

fn is_false(value: &bool) -> bool {
    !*value
}

/// One transcript item.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    /// Stable id within the session.
    pub id: String,
    /// Kind.
    pub kind: ItemKind,
    /// Tool title; empty for messages.
    pub title: String,
    /// Message text, or tool output text.
    pub text: String,
    /// Inline images as data URLs.
    #[serde(default)]
    pub images: Vec<String>,
    /// Tool state, for tool calls.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<Tool>,
    /// Plan entries, for plans.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<Vec<PlanEntry>>,
    /// The agent's message id, when supplied.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
    /// Some of this item's content was dropped to stay within the bounds.
    #[serde(default, skip_serializing_if = "is_false")]
    pub truncated: bool,
    /// The text reached [`MAX_ITEM_TEXT`] (it ends with a marker); later
    /// text for this item is dropped.
    #[serde(default, skip_serializing_if = "is_false")]
    pub text_full: bool,
    /// What else was dropped (`images`, `diffs`, …), for a visible notice.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub omitted: Vec<String>,
}

impl Item {
    /// Record that content of `reason` was dropped. `true` when new.
    fn omit(&mut self, reason: &str) -> bool {
        self.truncated = true;
        if self.omitted.iter().any(|known| known == reason) {
            return false;
        }
        self.omitted.push(reason.to_string());
        true
    }

    /// Set whether `reason` applies, for collections an update replaces.
    fn omit_if(&mut self, reason: &str, dropped: bool) {
        if dropped {
            self.omit(reason);
        } else {
            self.omitted.retain(|known| known != reason);
        }
    }
}

/// One turn: a user prompt and everything the agent produced for it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Turn {
    /// Host turn id (live turns) or a replay id (loaded history).
    pub id: String,
    /// Items, in order.
    pub items: Vec<Item>,
    /// How the turn ended; `None` while running or unknown (replay).
    pub outcome: Option<TurnOutcome>,
    /// Whether the turn came from `session/load` replay.
    pub replayed: bool,
    /// Next item ordinal. Ordinals are never reused, so ids stay stable
    /// when earlier items of the turn are evicted.
    #[serde(default)]
    pub next_item: u64,
    /// Items evicted from inside this turn (shown as a gap).
    #[serde(default)]
    pub omitted: u64,
}

impl Turn {
    fn new(id: String, replayed: bool) -> Self {
        Self {
            id,
            items: Vec::new(),
            outcome: None,
            replayed,
            next_item: 0,
            omitted: 0,
        }
    }

    fn next_ordinal(&mut self) -> u64 {
        let ordinal = self.next_item.max(self.items.len() as u64);
        self.next_item = ordinal + 1;
        ordinal
    }
}

/// What changed in the transcript, for live event translation.
#[derive(Debug, Clone, PartialEq)]
pub enum Change {
    /// A new item appeared.
    Started(Item),
    /// Text was appended to a message item.
    Delta {
        /// Item id.
        item_id: String,
        /// Item kind.
        kind: ItemKind,
        /// Appended text.
        delta: String,
    },
    /// An item was replaced (tool calls, plans, images).
    Updated(Item),
}

/// Session-level state carried by an update rather than transcript content.
#[derive(Debug, Clone, PartialEq)]
pub enum SessionSignal {
    /// Full replacement of the select configuration options.
    ConfigOptions(Vec<Value>),
    /// The legacy current mode changed.
    Mode(String),
    /// Title metadata: `Some(None)` clears it, `None` leaves it unchanged.
    Title(Option<Option<String>>),
    /// The slash commands the agent offers (full replacement).
    Commands(Vec<Value>),
    /// Context window usage.
    Usage {
        /// Tokens in context.
        used: u64,
        /// Context window size.
        size: u64,
    },
}

/// Recognize the session-level update kinds.
pub fn session_signal(update: &Value) -> Option<SessionSignal> {
    match update["sessionUpdate"].as_str()? {
        "config_option_update" => {
            Some(SessionSignal::ConfigOptions(select_options(&update["configOptions"])))
        },
        "current_mode_update" => update["currentModeId"]
            .as_str()
            .map(|mode| SessionSignal::Mode(mode.to_string())),
        "session_info_update" => {
            let title = match update.get("title") {
                None => None,
                Some(Value::Null) => Some(None),
                Some(Value::String(title)) => Some(Some(title.chars().take(512).collect())),
                Some(_) => return None,
            };
            Some(SessionSignal::Title(title))
        },
        "available_commands_update" => {
            Some(SessionSignal::Commands(available_commands(&update["availableCommands"])))
        },
        "usage_update" => Some(SessionSignal::Usage {
            used: update["used"].as_u64()?,
            size: update["size"].as_u64()?,
        }),
        _ => None,
    }
}

/// A bounded, folded conversation.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Transcript {
    /// Retained turns, oldest first.
    pub turns: VecDeque<Turn>,
    /// Whether older history was evicted (or never received).
    pub truncated: bool,
    #[serde(skip)]
    bytes: usize,
    #[serde(skip)]
    items: usize,
    #[serde(skip)]
    replays: u64,
}

/// An `io::Write` that only counts the bytes written to it.
struct ByteCount(usize);

impl std::io::Write for ByteCount {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0 += bytes.len();
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Length of `value`'s compact JSON serialization, without building it.
fn serialized_len(value: &Value) -> usize {
    let mut count = ByteCount(0);
    serde_json::to_writer(&mut count, value).map_or(0, |()| count.0)
}

/// Every retained byte of `item`, plus a fixed overhead.
fn weight(item: &Item) -> usize {
    let tool = item.tool.as_ref().map_or(0, |tool| {
        tool.call_id.len()
            + tool.kind.len()
            + tool.status.len()
            + tool.name.as_ref().map_or(0, String::len)
            + tool.category.as_ref().map_or(0, String::len)
            + tool.locations.iter().map(String::len).sum::<usize>()
            + tool
                .diffs
                .iter()
                .map(|d| {
                    d.path.len() + d.new_text.len() + d.old_text.as_ref().map_or(0, String::len)
                })
                .sum::<usize>()
            + tool.raw_input.as_ref().map_or(0, serialized_len)
    });
    let plan = item.plan.as_ref().map_or(0, |plan| {
        plan.iter()
            .map(|e| e.content.len() + e.status.len())
            .sum::<usize>()
    });
    ITEM_OVERHEAD
        + item.id.len()
        + item.title.len()
        + item.text.len()
        + item.message_id.as_ref().map_or(0, String::len)
        + item.images.iter().map(String::len).sum::<usize>()
        + item.omitted.iter().map(String::len).sum::<usize>()
        + tool
        + plan
}

/// Cut `text` to `limit` bytes plus a visible marker. `true` when cut.
fn clip(text: &mut String, limit: usize) -> bool {
    if text.len() <= limit {
        return false;
    }
    let mut end = limit;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text.truncate(end);
    text.push_str(TRUNCATED);
    true
}

/// Keep `image` when the item's image budget allows. `false` when dropped.
fn push_image(images: &mut Vec<String>, image: String) -> bool {
    let used: usize = images.iter().map(String::len).sum();
    if images.len() >= MAX_ITEM_IMAGES || used + image.len() > MAX_ITEM_IMAGE_BYTES {
        return false;
    }
    images.push(image);
    true
}

/// Text and image carried by one content block.
fn block_content(block: &Value) -> (String, Option<String>) {
    match block["type"].as_str() {
        Some("text") => (block["text"].as_str().unwrap_or("").to_string(), None),
        Some("image") => {
            let mime = block["mimeType"].as_str().unwrap_or("");
            let data = block["data"].as_str().unwrap_or("");
            let image = (mime.starts_with("image/") && !data.is_empty())
                .then(|| format!("data:{mime};base64,{data}"));
            (String::new(), image)
        },
        Some("resource_link") => {
            let name = block["title"]
                .as_str()
                .or_else(|| block["name"].as_str())
                .unwrap_or("");
            (format!("[{name}]({})", block["uri"].as_str().unwrap_or("")), None)
        },
        Some("resource") => {
            let resource = &block["resource"];
            match resource["text"].as_str() {
                Some(text) => (text.to_string(), None),
                None => (format!("[{}]", resource["uri"].as_str().unwrap_or("resource")), None),
            }
        },
        Some("audio") => ("[audio]".to_string(), None),
        _ => (String::new(), None),
    }
}

fn message_kind(update: &str) -> Option<ItemKind> {
    match update {
        "user_message_chunk" => Some(ItemKind::UserMessage),
        "agent_message_chunk" => Some(ItemKind::AgentMessage),
        "agent_thought_chunk" => Some(ItemKind::Thought),
        _ => None,
    }
}

fn kind_tag(kind: ItemKind) -> &'static str {
    match kind {
        ItemKind::UserMessage => "u",
        ItemKind::AgentMessage => "m",
        ItemKind::Thought => "r",
        ItemKind::ToolCall => "t",
        ItemKind::Plan => "p",
    }
}

fn new_item(id: String, kind: ItemKind) -> Item {
    Item {
        id,
        kind,
        title: String::new(),
        text: String::new(),
        images: Vec::new(),
        tool: None,
        plan: None,
        message_id: None,
        truncated: false,
        text_full: false,
        omitted: Vec::new(),
    }
}

impl Transcript {
    /// An empty transcript; `missing_history` marks that earlier history
    /// exists but is not available here.
    pub fn new(missing_history: bool) -> Self {
        Self {
            truncated: missing_history,
            ..Self::default()
        }
    }

    /// A transcript holding `turns` as read from a host (controller-side
    /// recovery). Ids and ordinals continue exactly where the host's did.
    pub fn from_turns(turns: impl IntoIterator<Item = Turn>, truncated: bool) -> Self {
        let mut transcript = Self {
            turns: turns.into_iter().collect(),
            truncated,
            ..Self::default()
        };
        transcript.replays = transcript
            .turns
            .iter()
            .filter_map(|turn| turn.id.strip_prefix("replay:")?.parse::<u64>().ok())
            .max()
            .unwrap_or(0);
        transcript.recount();
        transcript.enforce_bounds();
        transcript
    }

    /// Number of retained items.
    pub fn len(&self) -> usize {
        self.items
    }

    /// Whether nothing is retained.
    pub fn is_empty(&self) -> bool {
        self.items == 0
    }

    /// Retained bytes as charged against [`MAX_TRANSCRIPT_BYTES`].
    pub fn retained_bytes(&self) -> usize {
        self.bytes
    }

    /// The retained turn `id`.
    pub fn turn(&self, id: &str) -> Option<&Turn> {
        self.turns.iter().rev().find(|turn| turn.id == id)
    }

    /// Recompute the bounds bookkeeping after deserialization.
    pub fn recount(&mut self) {
        self.items = self.turns.iter().map(|t| t.items.len()).sum();
        self.bytes = self.turns.iter().flat_map(|t| &t.items).map(weight).sum();
    }

    /// Open a live turn for a prompt the host sent.
    pub fn begin_turn(&mut self, id: &str, user_text: &str, images: &[String]) -> Vec<Change> {
        let mut user = new_item(format!("{id}:u"), ItemKind::UserMessage);
        user.text = user_text.to_string();
        user.text_full = clip(&mut user.text, MAX_ITEM_TEXT);
        user.truncated = user.text_full;
        for image in images {
            if !push_image(&mut user.images, image.clone()) {
                user.omit(OMITTED_IMAGES);
            }
        }
        self.bytes += weight(&user);
        self.items += 1;
        let mut turn = Turn::new(id.to_string(), false);
        turn.next_item = 1;
        turn.items.push(user.clone());
        self.turns.push_back(turn);
        self.enforce_bounds();
        vec![Change::Started(user)]
    }

    /// Add user input the agent accepted into live turn `id` while it ran
    /// (a `_session/steering` supplement). Its `images` are counted, not
    /// kept: events never carry image data, so a controller's fold could
    /// not hold them, and both sides must agree item for item. Nothing
    /// changes when the turn is not retained.
    pub fn supplement(&mut self, id: &str, text: &str, images: usize) -> Vec<Change> {
        let Some(turn) = self.turns.iter_mut().rev().find(|turn| turn.id == id) else {
            return Vec::new();
        };
        let ordinal = turn.next_ordinal();
        let mut item = new_item(format!("{id}:s{ordinal}"), ItemKind::UserMessage);
        item.text = text.to_string();
        item.text_full = clip(&mut item.text, MAX_ITEM_TEXT);
        item.truncated = item.text_full;
        if images > 0 {
            item.omit(OMITTED_IMAGES);
        }
        self.bytes += weight(&item);
        self.items += 1;
        turn.items.push(item.clone());
        self.enforce_bounds();
        vec![Change::Started(item)]
    }

    /// A replayed message the user added to a running turn (Grok marks it
    /// `_meta.interjection` and keeps the typed text as
    /// `content._meta.displayText`): its own item of the replayed turn, like
    /// a live supplement, never part of the prompt.
    fn replayed_interjection(&mut self, update: &Value) -> Vec<Change> {
        let content = &update["content"];
        let text = match content["_meta"]["displayText"].as_str() {
            Some(typed) => typed.to_string(),
            None => {
                let raw = content["text"].as_str().unwrap_or_default();
                raw.split_once("<user_query>")
                    .and_then(|(_, rest)| rest.split_once("</user_query>"))
                    .map_or(raw, |(query, _)| query)
                    .trim()
                    .to_string()
            },
        };
        if text.trim().is_empty() {
            return Vec::new();
        }
        let index = self.target_turn(None, false);
        let turn = &mut self.turns[index];
        let ordinal = turn.next_ordinal();
        let mut item = new_item(format!("{}:s{ordinal}", turn.id), ItemKind::UserMessage);
        item.text = text;
        item.text_full = clip(&mut item.text, MAX_ITEM_TEXT);
        item.truncated = item.text_full;
        self.bytes += weight(&item);
        self.items += 1;
        turn.items.push(item.clone());
        self.enforce_bounds();
        vec![Change::Started(item)]
    }

    /// Record how a live turn ended.
    pub fn end_turn(&mut self, id: &str, outcome: TurnOutcome) {
        if let Some(turn) = self.turns.iter_mut().rev().find(|turn| turn.id == id) {
            turn.outcome = Some(outcome);
        }
    }

    /// The turn an update belongs to: the live `turn` when given, otherwise
    /// a replay turn (a replayed user message opens a new one).
    fn target_turn(&mut self, turn: Option<&str>, opens: bool) -> usize {
        if let Some(id) = turn {
            if let Some(index) = self.turns.iter().rposition(|t| t.id == id) {
                return index;
            }
            self.turns.push_back(Turn::new(id.to_string(), false));
            return self.turns.len() - 1;
        }
        let reuse = self.turns.back().is_some_and(|last| {
            last.replayed
                && !(opens
                    && last
                        .items
                        .iter()
                        .any(|item| item.kind != ItemKind::UserMessage))
        });
        if !reuse {
            self.replays += 1;
            self.turns
                .push_back(Turn::new(format!("replay:{}", self.replays), true));
        }
        self.turns.len() - 1
    }

    /// Fold one `session/update` payload. `turn` is the live host turn the
    /// update arrived during, or `None` for replay / out-of-turn updates.
    /// Session-level kinds (see [`session_signal`]) and unknown kinds change
    /// nothing here.
    pub fn apply(&mut self, turn: Option<&str>, update: &Value) -> Vec<Change> {
        let Some(name) = update["sessionUpdate"].as_str() else {
            return Vec::new();
        };
        let changes = if let Some(kind) = message_kind(name) {
            // A live turn already holds the prompt the host sent; an echoed
            // user chunk would duplicate it.
            if kind == ItemKind::UserMessage && turn.is_some() {
                return Vec::new();
            }
            if kind == ItemKind::UserMessage && update["_meta"]["interjection"] == true {
                return self.replayed_interjection(update);
            }
            self.chunk(turn, kind, update)
        } else {
            match name {
                "tool_call" | "tool_call_update" => self.tool(turn, update),
                "plan" => self.plan(turn, update),
                _ => return Vec::new(),
            }
        };
        self.enforce_bounds();
        changes
    }

    fn chunk(&mut self, turn: Option<&str>, kind: ItemKind, update: &Value) -> Vec<Change> {
        let (text, image) = block_content(&update["content"]);
        if text.is_empty() && image.is_none() {
            return Vec::new();
        }
        // Compared and stored under the same key, so one long id is one
        // message and two ids never merge.
        let message_id = update["messageId"].as_str().map(protocol_key);
        let index = self.target_turn(turn, kind == ItemKind::UserMessage);
        let turn = &mut self.turns[index];
        let continues = turn
            .items
            .last()
            .is_some_and(|last| last.kind == kind && last.message_id == message_id);
        if continues {
            let Some(last) = turn.items.last_mut() else { return Vec::new() };
            let before = weight(last);
            let mut changes = Vec::new();
            // Only the text budget stops text; a dropped image does not.
            if !text.is_empty() && !last.text_full {
                let room = MAX_ITEM_TEXT.saturating_sub(last.text.len());
                let mut delta = text;
                if delta.len() > room {
                    // Streaming crossed the item limit: keep what fits and
                    // say so, both in the text and on the item.
                    let mut end = room;
                    while !delta.is_char_boundary(end) {
                        end -= 1;
                    }
                    delta.truncate(end);
                    delta.push_str(TRUNCATED);
                    last.text_full = true;
                    last.truncated = true;
                }
                last.text.push_str(&delta);
                changes.push(Change::Delta {
                    item_id: last.id.clone(),
                    kind,
                    delta,
                });
            }
            if let Some(image) = image {
                if push_image(&mut last.images, image) || last.omit(OMITTED_IMAGES) {
                    changes.push(Change::Updated(last.clone()));
                }
            }
            self.bytes = self.bytes.saturating_sub(before) + weight(last);
            return changes;
        }
        let ordinal = turn.next_ordinal();
        let mut item = new_item(format!("{}:{}{ordinal}", turn.id, kind_tag(kind)), kind);
        item.text = text;
        item.text_full = clip(&mut item.text, MAX_ITEM_TEXT);
        item.truncated = item.text_full;
        if let Some(image) = image {
            if !push_image(&mut item.images, image) {
                item.omit(OMITTED_IMAGES);
            }
        }
        item.message_id = message_id;
        self.bytes += weight(&item);
        self.items += 1;
        turn.items.push(item.clone());
        vec![Change::Started(item)]
    }

    fn find_tool(&mut self, call_id: &str) -> Option<&mut Item> {
        self.turns
            .iter_mut()
            .rev()
            .flat_map(|turn| turn.items.iter_mut().rev())
            .find(|item| {
                item.kind == ItemKind::ToolCall
                    && item
                        .tool
                        .as_ref()
                        .is_some_and(|tool| tool.call_id == call_id)
            })
    }

    fn tool(&mut self, turn: Option<&str>, update: &Value) -> Vec<Change> {
        let Some(call_id) = update["toolCallId"].as_str() else {
            return Vec::new();
        };
        // Compared exactly (see the module docs): no prefix aliasing.
        let call_id = protocol_key(call_id);
        if let Some(existing) = self.find_tool(&call_id) {
            let before = weight(existing);
            apply_tool_fields(existing, update);
            let after = weight(existing);
            let snapshot = existing.clone();
            self.bytes = self.bytes.saturating_sub(before) + after;
            return vec![Change::Updated(snapshot)];
        }
        let index = self.target_turn(turn, false);
        let mut item = new_item(format!("tool:{call_id}"), ItemKind::ToolCall);
        item.tool = Some(Tool {
            call_id,
            kind: "other".into(),
            status: "pending".into(),
            ..Tool::default()
        });
        apply_tool_fields(&mut item, update);
        // Tool ids are the agent's; the ordinal still advances so message
        // ids that follow never collide with evicted ones.
        self.turns[index].next_ordinal();
        self.bytes += weight(&item);
        self.items += 1;
        self.turns[index].items.push(item.clone());
        vec![Change::Started(item)]
    }

    fn plan(&mut self, turn: Option<&str>, update: &Value) -> Vec<Change> {
        let Some(entries) = update["entries"].as_array() else { return Vec::new() };
        let plan: Vec<PlanEntry> = entries
            .iter()
            .take(256)
            .filter_map(|entry| {
                Some(PlanEntry {
                    content: entry["content"].as_str()?.chars().take(2048).collect(),
                    status: entry["status"]
                        .as_str()
                        .unwrap_or("pending")
                        .chars()
                        .take(32)
                        .collect(),
                })
            })
            .collect();
        let index = self.target_turn(turn, false);
        let turn = &mut self.turns[index];
        let id = format!("{}:plan", turn.id);
        if let Some(existing) = turn.items.iter_mut().find(|item| item.id == id) {
            let before = weight(existing);
            existing.plan = Some(plan);
            existing.omit_if(OMITTED_PLAN, entries.len() > 256);
            existing.truncated = !existing.omitted.is_empty();
            let snapshot = existing.clone();
            self.bytes = self.bytes.saturating_sub(before) + weight(&snapshot);
            return vec![Change::Updated(snapshot)];
        }
        let mut item = new_item(id, ItemKind::Plan);
        item.plan = Some(plan);
        item.omit_if(OMITTED_PLAN, entries.len() > 256);
        self.bytes += weight(&item);
        self.items += 1;
        turn.items.push(item.clone());
        vec![Change::Started(item)]
    }

    fn over_bounds(&self) -> bool {
        self.bytes > MAX_TRANSCRIPT_BYTES || self.items > MAX_ITEMS || self.turns.len() > MAX_TURNS
    }

    /// Evict until the bounds hold: whole oldest turns first, then the
    /// oldest items of the one remaining turn, keeping its prompt and its
    /// newest item (whose own size is bounded per item).
    fn enforce_bounds(&mut self) {
        while self.over_bounds() {
            if self.turns.len() > 1 {
                if let Some(turn) = self.turns.pop_front() {
                    self.items = self.items.saturating_sub(turn.items.len());
                    self.bytes = self
                        .bytes
                        .saturating_sub(turn.items.iter().map(weight).sum::<usize>());
                    self.truncated = true;
                }
                continue;
            }
            let Some(turn) = self.turns.front_mut() else { return };
            let last = turn.items.len().saturating_sub(1);
            let victim = (0..last)
                .find(|&index| !(index == 0 && turn.items[0].kind == ItemKind::UserMessage));
            let Some(victim) = victim else { return };
            let removed = turn.items.remove(victim);
            turn.omitted += 1;
            self.items = self.items.saturating_sub(1);
            self.bytes = self.bytes.saturating_sub(weight(&removed));
            self.truncated = true;
        }
    }
}

/// Fold the persisted `session/update` payloads of one turn, as replayed,
/// into a single turn named `id`. A reader of an agent's own stored history
/// folds each turn alone, so ids stay stable across pages. A user message
/// after agent output (an interjection) stays in this turn as its own item.
pub fn replay_turn(id: &str, updates: &[Value]) -> Turn {
    let mut folded = Transcript::new(false);
    for update in updates {
        folded.apply(None, update);
    }
    let mut turn = Turn::new(id.to_string(), true);
    if folded.truncated {
        // Whole earlier parts were dropped to stay within the bounds.
        turn.omitted += 1;
    }
    for (index, part) in folded.turns.into_iter().enumerate() {
        let prefix = if index == 0 { id.to_string() } else { format!("{id}.{index}") };
        turn.omitted += part.omitted;
        for mut item in part.items {
            if let Some(rest) = item.id.strip_prefix(part.id.as_str()) {
                item.id = format!("{prefix}{rest}");
            }
            turn.items.push(item);
        }
    }
    turn.next_item = turn.items.len() as u64;
    turn
}

#[cfg(test)]
mod tests;
mod tool;
