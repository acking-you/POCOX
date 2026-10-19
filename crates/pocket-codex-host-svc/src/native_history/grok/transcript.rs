//! `updates.jsonl` as turns, with Grok's own replay rules
//! (`session/storage/mod.rs` `filter_rewind_by`, `UserRunTurnTracker` and
//! `storage/replay.rs`):
//!
//! - a counted user run opens a turn: every user run until the first
//!   `promptIndex` appears, afterwards only runs that carry one; host-turn
//!   chunks are not user runs;
//! - a `rewind_marker` (`_x.ai/session/update`) drops everything from the start
//!   of its target prompt;
//! - only ACP `session/update` lines are shown; `<fork-context>` /
//!   `<resume-context>` wrappers are stripped from user text, and an
//!   interjection shows its typed `displayText`.
//!
//! The log is append-only, so the index keeps its filter state and later
//! reads examine only appended, complete lines. Turn ids are the byte offset
//! of the turn's first line: a rewound and rewritten turn gets a new id.
//!
//! A tail read can also fold a live overlay ([`LiveTail`]): updates Grok's
//! leader delivered that the log does not hold yet. Every persisted line and
//! live notification carries the session's numeric `eventId` (with gaps:
//! some ids are neither persisted nor sent), and a merged text run is
//! written with its last chunk's id, so the overlay is the live updates past
//! the log's highest id, once the log is known to hold everything else.

use std::{
    fs::{self, File},
    io::{BufRead, BufReader, Read, Seek, SeekFrom},
    path::Path,
};

use anyhow::{bail, ensure, Context, Result};
use pocket_codex_core::history_sync::digest_bytes;
use serde::Deserialize;
use serde_json::{value::RawValue, Value};

use super::{super::NativePage, inventory};
use crate::acp::{
    fold::{replay_turn, Turn},
    schema::TurnOutcome,
};

const UPDATES_FILE: &str = "updates.jsonl";
const XAI_UPDATE: &str = "_x.ai/session/update";
/// Longest line parsed; a longer one is indexed but shown as omitted.
const MAX_LINE: usize = 8 * 1024 * 1024;
/// Most lines one session index holds.
const MAX_SPANS: usize = 500_000;
/// Most log bytes one page read folds.
const MAX_PAGE_BYTES: u64 = 32 * 1024 * 1024;

const ACP: u8 = 0;
const TURN_END: u8 = 1;
const OTHER: u8 = 2;
const OVERSIZED: u8 = 3;

#[derive(Clone, Copy)]
struct Span {
    offset: u64,
    len: u32,
    kind: u8,
}

/// The live (rewind-filtered) lines of one update log and its turn starts.
#[derive(Default)]
pub(in crate::native_history) struct Index {
    file: Option<(u64, u64)>,
    scanned: u64,
    spans: Vec<Span>,
    /// Indices into `spans` where a counted turn starts.
    prompts: Vec<usize>,
    tracker: Tracker,
    /// Highest `eventId` sequence of any complete line, rewound ones included.
    max_seq: u64,
}

/// Live updates of one session that may not be in its log yet.
#[derive(Clone, Debug, Default)]
pub(in crate::native_history) struct LiveTail {
    /// The overlay holds once the log reaches this `eventId` sequence: past
    /// it, every update the log lacks was received. Before, an update sent
    /// before the follower subscribed may still wait in Grok's write buffer,
    /// or a live rewind or an update too large to keep must reach the log.
    pub through: u64,
    /// `(sequence, update)` in arrival order.
    pub updates: Vec<(u64, Value)>,
}

/// `UserRunTurnTracker`, verbatim in behaviour.
#[derive(Default, Clone, Copy)]
struct Tracker {
    seen_marker: bool,
    in_user: bool,
    current: Option<usize>,
}

impl Tracker {
    /// Whether this user chunk opens a counted turn.
    fn on_user_chunk(&mut self, prompt_index: Option<usize>) -> bool {
        if prompt_index.is_some() {
            self.seen_marker = true;
        }
        let counts = if self.seen_marker { prompt_index.is_some() } else { true };
        let new_run = if !self.in_user {
            true
        } else if self.seen_marker || prompt_index.is_some() {
            prompt_index != self.current
        } else {
            false
        };
        self.in_user = true;
        if new_run {
            self.current = prompt_index;
            counts
        } else {
            false
        }
    }

    fn on_non_user(&mut self) {
        self.in_user = false;
        self.current = None;
    }
}

enum Step {
    Rewind(usize),
    UserChunk(Option<usize>),
    Other,
}

#[derive(Deserialize)]
struct Envelope<'a> {
    #[serde(default)]
    method: Option<&'a str>,
    #[serde(borrow, default)]
    params: Option<&'a RawValue>,
}

#[derive(Deserialize)]
struct ParamsPeek<'a> {
    #[serde(borrow, default)]
    update: Option<UpdatePeek<'a>>,
    #[serde(borrow, default, rename = "_meta")]
    meta: Option<LineMeta<'a>>,
}

#[derive(Deserialize)]
struct LineMeta<'a> {
    #[serde(borrow, default, rename = "eventId")]
    event_id: Option<&'a str>,
}

/// The counter of an `eventId` (`<session-id>-<n>`, `util/event_id.rs`).
pub(in crate::native_history) fn event_seq(event_id: &str) -> Option<u64> {
    event_id.rsplit_once('-')?.1.parse().ok()
}

#[derive(Deserialize)]
struct UpdatePeek<'a> {
    #[serde(rename = "sessionUpdate")]
    session_update: &'a str,
    #[serde(default)]
    target_prompt_index: Option<usize>,
    #[serde(default, rename = "_meta")]
    meta: Option<ChunkMeta>,
}

#[derive(Deserialize)]
struct ChunkMeta {
    #[serde(default, rename = "promptIndex")]
    prompt_index: Option<u64>,
    #[serde(default, rename = "hostTurn")]
    host_turn: Option<bool>,
}

/// The raw `params` of a line (enveloped, or the legacy bare form) and
/// whether it is an xAI extension update.
fn params_of(line: &str) -> (&str, bool) {
    match serde_json::from_str::<Envelope<'_>>(line) {
        Ok(envelope) => (
            envelope.params.map(RawValue::get).unwrap_or(line),
            envelope.method == Some(XAI_UPDATE),
        ),
        Err(_) => (line, false),
    }
}

fn classify(line: &str) -> (Step, u8, Option<u64>) {
    let (params, xai) = params_of(line);
    let Ok(peek) = serde_json::from_str::<ParamsPeek<'_>>(params) else {
        return (Step::Other, OTHER, None);
    };
    let seq = peek.meta.and_then(|m| m.event_id).and_then(event_seq);
    let Some(update) = peek.update else { return (Step::Other, OTHER, seq) };
    if xai {
        return match (update.session_update, update.target_prompt_index) {
            ("rewind_marker", Some(target)) => (Step::Rewind(target), OTHER, seq),
            ("turn_completed", _) => (Step::Other, TURN_END, seq),
            _ => (Step::Other, OTHER, seq),
        };
    }
    let host_turn = update.meta.as_ref().and_then(|m| m.host_turn) == Some(true);
    if !host_turn && update.session_update == "user_message_chunk" {
        let index = update.meta.and_then(|m| m.prompt_index).map(|v| v as usize);
        return (Step::UserChunk(index), ACP, seq);
    }
    (Step::Other, ACP, seq)
}

/// A live ACP update's step for the turn tracker.
fn live_step(update: &Value) -> Step {
    let meta = &update["_meta"];
    if update["sessionUpdate"] == "user_message_chunk" && meta["hostTurn"] != true {
        return Step::UserChunk(meta["promptIndex"].as_u64().map(|v| v as usize));
    }
    Step::Other
}

impl Index {
    fn reset(&mut self, file: (u64, u64)) {
        *self = Self {
            file: Some(file),
            ..Self::default()
        };
    }

    fn push(&mut self, span: Span, step: Step) -> Result<()> {
        match step {
            Step::Rewind(target) => {
                let keep = self
                    .prompts
                    .get(target)
                    .copied()
                    .unwrap_or(self.spans.len());
                self.spans.truncate(keep);
                self.prompts.truncate(target);
                self.tracker.on_non_user();
                return Ok(());
            },
            Step::UserChunk(index) => {
                if self.tracker.on_user_chunk(index) {
                    self.prompts.push(self.spans.len());
                }
            },
            Step::Other => self.tracker.on_non_user(),
        }
        ensure!(self.spans.len() < MAX_SPANS, "this Grok session is too long to display here");
        self.spans.push(span);
        Ok(())
    }

    /// Index the complete lines appended since the last call.
    fn update(&mut self, path: &Path) -> Result<()> {
        let mut file = match File::open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                // A session with no turns yet has no update log.
                *self = Self::default();
                return Ok(());
            },
            Err(error) => return Err(error).context("opening the Grok session log"),
        };
        let meta = file.metadata()?;
        let identity = file_identity(&meta);
        if self.file != Some(identity) || meta.len() < self.scanned {
            self.reset(identity);
        }
        file.seek(SeekFrom::Start(self.scanned))?;
        let mut reader = BufReader::with_capacity(256 * 1024, file.take(meta.len() - self.scanned));
        let mut line = Vec::new();
        loop {
            let offset = self.scanned;
            let (read, complete, oversized) = read_line(&mut reader, &mut line)?;
            if read == 0 || !complete {
                // A partial last line is read again once it is finished.
                break;
            }
            let text = trim_line(&line);
            if text.is_empty() {
                self.scanned += read as u64;
                continue;
            }
            let span_len = u32::try_from(read).unwrap_or(u32::MAX);
            if oversized {
                self.push(
                    Span {
                        offset,
                        len: span_len,
                        kind: OVERSIZED,
                    },
                    Step::Other,
                )?;
                self.scanned += read as u64;
                continue;
            }
            let (step, kind, seq) = match std::str::from_utf8(text) {
                Ok(text) => classify(text),
                Err(_) => (Step::Other, OTHER, None),
            };
            self.max_seq = self.max_seq.max(seq.unwrap_or(0));
            self.push(
                Span {
                    offset,
                    len: span_len,
                    kind,
                },
                step,
            )?;
            // Only a line the index took is behind the scan offset.
            self.scanned += read as u64;
        }
        Ok(())
    }

    /// Turn ranges over `spans`: an orphan prefix before the first counted
    /// prompt is a turn of its own.
    fn turns(&self) -> Vec<(usize, usize)> {
        let mut starts: Vec<usize> = Vec::with_capacity(self.prompts.len() + 1);
        if !self.spans.is_empty() && self.prompts.first() != Some(&0) {
            starts.push(0);
        }
        starts.extend(
            self.prompts
                .iter()
                .copied()
                .filter(|&s| s < self.spans.len()),
        );
        starts
            .iter()
            .enumerate()
            .map(|(i, &start)| (start, starts.get(i + 1).copied().unwrap_or(self.spans.len())))
            .filter(|(start, end)| start < end)
            .collect()
    }

    /// The log's highest `eventId` sequence.
    pub(in crate::native_history) fn max_seq(&self) -> u64 {
        self.max_seq
    }

    /// What of `live` extends the log's last turn: the updates past the
    /// log's highest id, up to one that would open a new counted turn (that
    /// turn is shown once its first line is in the log, which gives it its
    /// id). Nothing until the log reaches `live.through`.
    fn overlay(&self, live: &LiveTail) -> Vec<Value> {
        let disk = self.max_seq;
        if self.spans.is_empty() || disk < live.through {
            return Vec::new();
        }
        let mut tracker = self.tracker;
        let mut out = Vec::new();
        for (_, update) in live.updates.iter().filter(|(seq, _)| *seq > disk) {
            match live_step(update) {
                Step::UserChunk(index) if tracker.on_user_chunk(index) => break,
                Step::UserChunk(_) => {},
                _ => tracker.on_non_user(),
            }
            if update["sessionUpdate"] != "available_commands_update" {
                out.push(displayed(update.clone()));
            }
        }
        out
    }
}

/// Read one line into `line` (cleared), keeping at most [`MAX_LINE`] bytes.
/// Returns the bytes consumed, whether a newline ended it and whether it
/// was longer than kept.
fn read_line(reader: &mut impl BufRead, line: &mut Vec<u8>) -> Result<(usize, bool, bool)> {
    line.clear();
    let mut consumed = 0;
    let mut oversized = false;
    loop {
        let buffer = reader.fill_buf()?;
        if buffer.is_empty() {
            return Ok((consumed, false, oversized));
        }
        let (chunk, done) = match buffer.iter().position(|&b| b == b'\n') {
            Some(end) => (&buffer[..=end], true),
            None => (buffer, false),
        };
        let room = MAX_LINE.saturating_sub(line.len());
        if chunk.len() > room {
            oversized = true;
            line.extend_from_slice(&chunk[..room]);
        } else {
            line.extend_from_slice(chunk);
        }
        let used = chunk.len();
        reader.consume(used);
        consumed += used;
        if done {
            return Ok((consumed, true, oversized));
        }
    }
}

fn trim_line(line: &[u8]) -> &[u8] {
    let mut end = line.len();
    while end > 0 && matches!(line[end - 1], b'\n' | b'\r' | b' ' | b'\t') {
        end -= 1;
    }
    &line[..end]
}

#[cfg(unix)]
fn file_identity(meta: &fs::Metadata) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt;
    (meta.dev(), meta.ino())
}

#[cfg(not(unix))]
fn file_identity(meta: &fs::Metadata) -> (u64, u64) {
    let created = meta
        .created()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_nanos() as u64);
    (created, 0)
}

/// What identifies a persisted session and what changes with its content.
pub(in crate::native_history) struct Stamp {
    dir: (u64, u64),
    created: String,
    log: Option<(u64, u64, u64, Option<std::time::SystemTime>)>,
    summary: (u64, Option<std::time::SystemTime>),
}

impl Stamp {
    pub(in crate::native_history) fn read(dir: &Path) -> Result<Self> {
        let dir_meta = fs::metadata(dir).context("the Grok session is unavailable")?;
        let summary = fs::metadata(dir.join(inventory::SUMMARY_FILE))
            .context("the Grok session summary is unavailable")?;
        let log = fs::metadata(dir.join(UPDATES_FILE)).ok().map(|meta| {
            let (dev, ino) = file_identity(&meta);
            (dev, ino, meta.len(), meta.modified().ok())
        });
        Ok(Self {
            dir: file_identity(&dir_meta),
            created: inventory::created_at(dir).unwrap_or_default(),
            log,
            summary: (summary.len(), summary.modified().ok()),
        })
    }

    /// Source identity: the session directory and its creation. Grok only
    /// appends to the update log (a rewind is a marker), so the log's first
    /// write keeps it; a shorter log shows as fewer `source_bytes`.
    pub(in crate::native_history) fn generation(&self) -> String {
        digest_bytes(format!("grok:{}:{}:{}", self.dir.0, self.dir.1, self.created).as_bytes())
    }

    /// Content revision of the log and the summary.
    pub(in crate::native_history) fn revision(&self) -> String {
        let log = self.log.map(|(_, _, len, modified)| (len, modified));
        digest_bytes(format!("{log:?}:{:?}", self.summary).as_bytes())
    }

    fn log_len(&self) -> u64 {
        self.log.map_or(0, |(_, _, len, _)| len)
    }
}

/// Read the `limit` turns before `before` (a turn id, or `turn:<id>` for
/// exactly that turn), or the newest ones; a page holding the last turn
/// folds `live` into it.
pub(in crate::native_history) fn read(
    dir: &Path,
    session: &str,
    index: &mut Index,
    before: Option<&str>,
    limit: usize,
    live: Option<&LiveTail>,
) -> Result<NativePage> {
    let stamp = Stamp::read(dir)?;
    let path = dir.join(UPDATES_FILE);
    index.update(&path)?;
    let turns = index.turns();
    let ids: Vec<String> = turns
        .iter()
        .map(|(start, _)| format!("grok:{}", index.spans[*start].offset))
        .collect();
    let (first, end) = match before {
        Some(cursor) => match cursor.strip_prefix("turn:") {
            Some(turn) => {
                let at = ids
                    .iter()
                    .position(|id| id == turn)
                    .context("native turn not found")?;
                (at, at + 1)
            },
            None => {
                let at = ids
                    .iter()
                    .position(|id| id == cursor)
                    .context("this history page is no longer available; reload")?;
                (at.saturating_sub(limit), at)
            },
        },
        None => (turns.len().saturating_sub(limit), turns.len()),
    };
    let mut file = File::open(&path).ok();
    let mut budget = MAX_PAGE_BYTES;
    let mut truncated = false;
    let mut page_turns = Vec::with_capacity(end - first);
    let overlay = match live {
        Some(live) if end == turns.len() => index.overlay(live),
        _ => Vec::new(),
    };
    for (n, (turn, id)) in turns[first..end].iter().zip(&ids[first..end]).enumerate() {
        let spans = &index.spans[turn.0..turn.1];
        let extra = if first + n + 1 == turns.len() { &overlay[..] } else { &[] };
        let (folded, cut) = fold_turn(file.as_mut(), id, spans, &mut budget, extra)?;
        truncated |= cut;
        page_turns.push(folded);
    }
    let (title, cwd, updated) = inventory::describe(dir);
    Ok(NativePage {
        session_id: session.into(),
        generation: stamp.generation(),
        revision: stamp.revision(),
        source_bytes: stamp.log_len(),
        cwd,
        title,
        updated_at: updated.max(0) as u64,
        turns: page_turns,
        has_older: first > 0,
        next_before: (first > 0).then(|| ids[first].clone()),
        total_turns: Some(turns.len()),
        truncated,
    })
}

fn fold_turn(
    file: Option<&mut File>,
    id: &str,
    spans: &[Span],
    budget: &mut u64,
    extra: &[Value],
) -> Result<(Turn, bool)> {
    let mut updates = Vec::new();
    let mut outcome = None;
    let mut omitted = 0u64;
    if let Some(file) = file {
        for span in spans {
            if span.kind == OTHER {
                continue;
            }
            if span.kind == OVERSIZED || u64::from(span.len) > *budget {
                omitted += 1;
                continue;
            }
            *budget -= u64::from(span.len);
            let mut bytes = vec![0; span.len as usize];
            file.seek(SeekFrom::Start(span.offset))?;
            file.read_exact(&mut bytes)
                .context("the Grok session log changed while reading; retry")?;
            let Ok(text) = std::str::from_utf8(trim_line(&bytes)) else {
                omitted += 1;
                continue;
            };
            let (params, _) = params_of(text);
            let Ok(params) = serde_json::from_str::<Value>(params) else {
                omitted += 1;
                continue;
            };
            let update = &params["update"];
            if span.kind == TURN_END {
                if let Some(reason) = update["stop_reason"].as_str() {
                    outcome = Some(TurnOutcome::Stopped {
                        stop_reason: reason.chars().take(64).collect(),
                    });
                }
                continue;
            }
            if update["sessionUpdate"] == "available_commands_update" {
                continue;
            }
            updates.push(displayed(update.clone()));
        }
    } else if !spans.is_empty() {
        bail!("the Grok session log is unavailable");
    }
    updates.extend_from_slice(extra);
    let mut turn = replay_turn(id, &updates);
    turn.outcome = outcome;
    turn.omitted += omitted;
    Ok((turn, omitted > 0))
}

/// What Grok's own replay shows of a user chunk: the typed text of an
/// interjection, without fork/resume context wrappers.
fn displayed(mut update: Value) -> Value {
    if update["sessionUpdate"] != "user_message_chunk" {
        return update;
    }
    let content = &mut update["content"];
    if content["type"] != "text" {
        return update;
    }
    if let Some(display) = content["_meta"]["displayText"].as_str().map(str::to_owned) {
        content["text"] = Value::String(display);
    }
    if let Some(text) = content["text"].as_str() {
        let mut text = text.to_owned();
        for tag in ["fork-context", "resume-context"] {
            let (open, close) = (format!("<{tag}>"), format!("</{tag}>"));
            if let Some(start) = text.find(&open) {
                if let Some(rel) = text[start + open.len()..].find(&close) {
                    let end = start + open.len() + rel + close.len();
                    text = format!("{}{}", &text[..start], text[end..].trim_start());
                }
            }
        }
        content["text"] = Value::String(text);
    }
    update
}
