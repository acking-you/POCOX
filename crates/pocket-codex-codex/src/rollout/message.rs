//! What a rollout's user messages say: typed text and attachments apart from
//! codex's wire framing and injected context, and the one-line preview.

use serde_json::Value;

/// Maximum length of the extracted preview string.
const PREVIEW_MAX_CHARS: usize = 160;

/// Split a `message` payload's `content` array into (typed text, image data
/// URLs). codex uses `input_text` / `output_text` parts for text (both carry
/// it under `text`) and `input_image` parts for inlined attachments — every
/// attachment (including `localImage` paths) is converted into a
/// `data:image/...;base64,...` URL when the model request is built, so the
/// rollout records renderable URLs.
///
/// The `<image>` / `<image name=…>` / `</image>` marker texts codex wraps
/// around each inlined image are wire framing, not something the user typed —
/// but a marker is stripped ONLY when it is actually adjacent to an
/// `input_image` part (mirroring codex's own `parse_user_message`), so a user
/// who literally typed "<image>" keeps their text.
pub(super) fn split_message_content(payload: &Value) -> (String, Vec<String>) {
    let Some(parts) = payload.get("content").and_then(Value::as_array) else {
        return (String::new(), Vec::new());
    };
    // Contextual fragments are judged PER CONTENT PART, the way upstream's
    // `is_contextual_user_fragment` does it — one user message routinely
    // carries several (the plugin list, then AGENTS.md) ahead of nothing at
    // all. Joining first and testing the result matches none of them and
    // leaves a title made of wire.
    let is_user = payload.get("role").and_then(Value::as_str) == Some("user");
    let is_image = |p: Option<&Value>| {
        p.and_then(|p| p.get("type")).and_then(Value::as_str) == Some("input_image")
    };
    let mut text = String::new();
    let mut images = Vec::new();
    for (idx, part) in parts.iter().enumerate() {
        if is_image(Some(part)) {
            if let Some(url) = part.get("image_url").and_then(Value::as_str) {
                images.push(url.to_string());
            }
            continue;
        }
        let Some(t) = part.get("text").and_then(Value::as_str) else {
            continue;
        };
        let open = t == "<image>" || (t.starts_with("<image name=") && t.ends_with('>'));
        let close = t == "</image>";
        if (open && is_image(parts.get(idx + 1)))
            || (close && idx > 0 && is_image(parts.get(idx - 1)))
        {
            continue;
        }
        if is_user && is_context_fragment(t) {
            continue;
        }
        text.push_str(t);
    }
    (text, images)
}

/// Marker pairs codex wraps an injected **contextual user fragment** in. Such a
/// message carries the user role but was written by codex, not by the person —
/// so it is neither a preview nor a turn to display.
///
/// The set mirrors the wire constants in
/// `codex-rs/protocol/src/protocol.rs` plus the fragments that declare their
/// own `type_markers()` under `codex-rs/core/src/context/`. Unknown future
/// fragments simply show through, which is the safe direction to fail: a stray
/// machine message is visible, never a hidden human one.
const CONTEXT_FRAGMENT_MARKERS: [(&str, &str); 17] = [
    // The project's AGENTS.md, which upstream marks by prose rather than a tag
    // (`UserInstructions::type_markers`, core/src/context/user_instructions.rs).
    ("# AGENTS.md instructions", "</INSTRUCTIONS>"),
    ("<user_instructions>", "</user_instructions>"),
    ("<environment_context>", "</environment_context>"),
    ("<apps_instructions>", "</apps_instructions>"),
    ("<skills_instructions>", "</skills_instructions>"),
    ("<plugins_instructions>", "</plugins_instructions>"),
    ("<collaboration_mode>", "</collaboration_mode>"),
    ("<multi_agent_mode>", "</multi_agent_mode>"),
    ("<realtime_conversation>", "</realtime_conversation>"),
    ("<context_window>", "</context_window>"),
    ("<context_window_guidance>", "</context_window_guidance>"),
    ("<recommended_plugins>", "</recommended_plugins>"),
    ("<model_switch>", "</model_switch>"),
    ("<personality_spec>", "</personality_spec>"),
    ("<subagent_notification>", "</subagent_notification>"),
    ("<turn_aborted>", "</turn_aborted>"),
    ("<user_shell_command>", "</user_shell_command>"),
];

/// Whether `text` is entirely one injected context fragment.
///
/// Mirrors upstream `matches_marked_text`
/// (`codex-rs/context-fragments/src/fragment.rs:116`): the trimmed text must
/// both open and close with the pair, matched ASCII-case-insensitively. Text
/// that merely *contains* a marker is left alone — a user quoting
/// `<turn_aborted>` in a question is still their message.
pub fn is_context_fragment(text: &str) -> bool {
    // Compared as BYTES, never as `&str[..n]`: the marker lengths land inside a
    // Han glyph in any Chinese message long enough to reach the check, and
    // string slicing panics on a non-char boundary. A byte slice cannot, and
    // `eq_ignore_ascii_case` over bytes is exactly upstream's rule — which also
    // has to be case-insensitive in BOTH directions, since one marker
    // (`# AGENTS.md instructions`) is not lowercase.
    fn bounded_by(hay: &str, open: &str, close: &str) -> bool {
        let (h, o, c) = (hay.as_bytes(), open.as_bytes(), close.as_bytes());
        h.len() >= o.len() + c.len()
            && h[..o.len()].eq_ignore_ascii_case(o)
            && h[h.len() - c.len()..].eq_ignore_ascii_case(c)
    }
    let trimmed = text.trim();
    CONTEXT_FRAGMENT_MARKERS
        .iter()
        .any(|(open, close)| bounded_by(trimmed, open, close))
}

/// The spoken turn inside a `<realtime_delegation>` wrapper.
///
/// Voice handoff wraps what the user actually said in `<input>…</input>`
/// alongside a transcript delta (`codex-rs/core/src/realtime_conversation.rs`).
/// Unlike the fragments above these ARE the person's words, so they are
/// unwrapped for display rather than hidden.
pub fn realtime_delegation_input(text: &str) -> Option<String> {
    let trimmed = text.trim();
    if !trimmed.starts_with("<realtime_delegation>") || !trimmed.ends_with("</realtime_delegation>")
    {
        return None;
    }
    let (_, rest) = trimmed.split_once("<input>")?;
    let (input, _) = rest.split_once("</input>")?;
    let input = input.trim();
    (!input.is_empty()).then(|| input.to_string())
}

/// Best-effort preview: the first user message text found in the head of
/// a rollout, trimmed to [`PREVIEW_MAX_CHARS`].
///
/// Injected context fragments are skipped. A session started from an IDE opens
/// with one (`<recommended_plugins>`), so taking the first user-role message
/// verbatim labelled every such session with the same wire tag instead of what
/// the person asked.
pub(super) fn extract_preview(head: &str) -> String {
    for line in head.lines() {
        if !(line.contains("user_message")
            || line.contains("input_text")
            || line.contains("\"role\":\"user\""))
        {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        if let Some(text) = user_text(&value) {
            if is_context_fragment(&text) {
                continue;
            }
            let text = realtime_delegation_input(&text).unwrap_or(text);
            return truncate_chars(text.trim(), PREVIEW_MAX_CHARS);
        }
    }
    String::new()
}

/// Pull user-authored text out of a rollout line, tolerating the shapes
/// codex uses (`user_message` event, `input_text` payload, or a
/// `message` response item with `role:"user"` and a `content[].text`).
fn user_text(value: &Value) -> Option<String> {
    let payload = value.get("payload")?;
    if let Some(text) = payload.get("text").and_then(Value::as_str) {
        if !text.trim().is_empty() {
            return Some(text.to_string());
        }
    }
    let is_user_message = payload.get("role").and_then(Value::as_str) == Some("user")
        || payload.get("type").and_then(Value::as_str) == Some("user_message");
    if !is_user_message {
        return None;
    }
    // `content` is either a plain string (`"content":"hi"`) or the structured
    // array of parts (`[{"type":"input_text","text":"hi"}]`). Handle both so the
    // preview isn't lost for string-content sessions. The array form goes
    // through [`split_message_content`] so an attachment's `<image>` wire
    // markers never leak into the preview.
    let content = payload.get("content")?;
    if let Some(s) = content.as_str() {
        return (!s.trim().is_empty()).then(|| s.to_string());
    }
    content.as_array()?;
    let (collected, _images) = split_message_content(payload);
    (!collected.trim().is_empty()).then_some(collected)
}

/// Truncate to at most `max` characters (char-boundary safe), appending
/// an ellipsis when shortened.
pub(super) fn truncate_chars(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    let mut out: String = text.chars().take(max.saturating_sub(1)).collect();
    out.push('…');
    out
}
