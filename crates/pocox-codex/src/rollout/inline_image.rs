//! The model request's own copy of an image a user message attached.
//!
//! codex sends every attachment inline: a user message's `response_item`
//! carries `<image name=[Image #N] path="…">`, the `input_image` data URL and
//! `</image>` as consecutive content parts. The app-server history keeps
//! only the `localImage` path. A pasted screenshot lives in the OS temp
//! directory, which the system clears, so once the file is gone this inline
//! copy is the only one left.

use std::io::BufRead;
use std::path::Path;

use pocox_core::Result;
use serde_json::Value;

/// The data URL a user message of the rollout at `rollout` sent for the
/// attachment at `path`, if it recorded one.
///
/// Only an `input_image` that directly follows the `<image … path="…">` tag
/// naming exactly `path` counts. Lines that do not mention the path are not
/// parsed, so scanning a long rollout stays cheap. A fork searches only the
/// ancestor prefixes it inherited, just as its transcript does.
pub fn inline_user_image(rollout: &Path, path: &str) -> Result<Option<String>> {
    // How the path appears inside a JSON string (quotes and backslashes
    // escaped), for the prefilter.
    let escaped = serde_json::to_string(path)?;
    let needle = escaped.trim_matches('"');
    for segment in super::lineage::segments(rollout) {
        let reader = match segment.open() {
            Ok(reader) => reader,
            Err(_) if segment.is_ancestor() => continue,
            Err(error) => return Err(error),
        };
        if let Some(url) = scan_image(reader, path, needle)? {
            return Ok(Some(url));
        }
    }
    Ok(None)
}

fn scan_image(reader: impl BufRead, path: &str, needle: &str) -> Result<Option<String>> {
    for line in reader.lines() {
        // A line that is not UTF-8 (its bytes are consumed) ends nothing: the
        // image may still be on another line. Any other read error would
        // repeat on every attempt, so it ends the search.
        let line = match line {
            Ok(line) => line,
            Err(error) if error.kind() == std::io::ErrorKind::InvalidData => continue,
            Err(error) => return Err(error.into()),
        };
        if !line.contains(needle) || !line.contains("input_image") {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if let Some(url) = image_in_line(&value, path) {
            return Ok(Some(url));
        }
    }
    Ok(None)
}

fn image_in_line(value: &Value, path: &str) -> Option<String> {
    if value.get("type").and_then(Value::as_str) != Some("response_item") {
        return None;
    }
    let payload = value.get("payload")?;
    if payload.get("type").and_then(Value::as_str) != Some("message")
        || payload.get("role").and_then(Value::as_str) != Some("user")
    {
        return None;
    }
    let parts = payload.get("content")?.as_array()?;
    parts.windows(2).find_map(|pair| {
        let tag = pair[0].get("text").and_then(Value::as_str)?;
        if !names_path(tag, path) {
            return None;
        }
        let image = &pair[1];
        if image.get("type").and_then(Value::as_str) != Some("input_image") {
            return None;
        }
        let url = image.get("image_url").and_then(Value::as_str)?;
        url.starts_with("data:image/").then(|| url.to_string())
    })
}

/// Whether `tag` is an `<image …>` opening tag whose `path` attribute is
/// exactly `path`.
fn names_path(tag: &str, path: &str) -> bool {
    tag.starts_with("<image ") && tag.ends_with('>') && tag.contains(&format!("path=\"{path}\""))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn message(role: &str, parts: Value) -> String {
        json!({
            "type": "response_item",
            "payload": {"type": "message", "role": role, "content": parts},
        })
        .to_string()
    }

    #[test]
    fn a_fork_finds_inherited_images_but_not_later_source_images() {
        const SOURCE: &str = "01000000-0000-7000-8000-000000000001";
        let home = tempfile::tempdir().expect("home");
        let active = home.path().join("sessions");
        let archived = home.path().join("archived_sessions");
        std::fs::create_dir_all(&active).expect("sessions");
        std::fs::create_dir_all(&archived).expect("archive");
        let image = |path: &str| {
            message(
                "user",
                json!([
                    {"type": "input_text", "text": format!("<image path=\"{path}\">")},
                    {"type": "input_image", "image_url": "data:image/png;base64,QUFB"},
                ]),
            )
        };
        let inherited = format!("{}\n", image("/tmp/inherited.png"));
        let source = archived.join(format!("rollout-2026-11-02T10-00-00-{SOURCE}.jsonl"));
        std::fs::write(&source, format!("{inherited}{}\n", image("/tmp/later.png")))
            .expect("source");
        let fork = active.join("fork.jsonl");
        let header = json!({"type": "session_meta", "payload": {"history_base": {
            "thread_id": SOURCE, "end_byte_offset": inherited.len(),
        }}});
        std::fs::write(&fork, format!("{header}\n{}\n", image("/tmp/own.png"))).expect("fork");

        assert_eq!(
            inline_user_image(&fork, "/tmp/inherited.png")
                .expect("inherited image")
                .as_deref(),
            Some("data:image/png;base64,QUFB")
        );
        assert_eq!(inline_user_image(&fork, "/tmp/later.png").expect("later image"), None);
        std::fs::remove_file(source).expect("remove ancestor");
        assert!(inline_user_image(&fork, "/tmp/own.png")
            .expect("own image")
            .is_some());
    }

    #[test]
    fn finds_the_inline_copy_named_by_the_attachment_tag() {
        let dir = tempfile::tempdir().expect("tempdir");
        let rollout = dir.path().join("rollout.jsonl");
        let wanted = "/var/folders/T/codex-clipboard-a.png";
        let tag = |path: &str, n: u8| format!("<image name=[Image #{n}] path=\"{path}\">");
        // A reply that merely names the path, and another attachment, come
        // first; neither is the image the user attached from `wanted`.
        let lines = [
            message(
                "assistant",
                json!([
                    {"type": "output_text", "text": tag(wanted, 1)},
                    {"type": "input_image", "image_url": "data:image/png;base64,QUFB"},
                ]),
            ),
            message(
                "user",
                json!([
                    {"type": "input_text", "text": tag("/tmp/other.png", 1)},
                    {"type": "input_image", "image_url": "data:image/png;base64,T1RIRVI="},
                    {"type": "input_text", "text": "</image>"},
                    {"type": "input_text", "text": format!("mentions {wanted} in prose")},
                ]),
            ),
            message(
                "user",
                json!([
                    {"type": "input_text", "text": tag(wanted, 2)},
                    {"type": "input_image", "image_url": "data:image/png;base64,V0FOVEVE"},
                    {"type": "input_text", "text": "</image>"},
                ]),
            ),
        ];
        std::fs::write(&rollout, lines.join("\n")).expect("write");

        assert_eq!(
            inline_user_image(&rollout, wanted)
                .expect("scan")
                .as_deref(),
            Some("data:image/png;base64,V0FOVEVE")
        );
        assert_eq!(
            inline_user_image(&rollout, "/var/folders/T/codex-clipboard-a.pn").expect("scan"),
            None,
            "a prefix of the attachment's path names a different file"
        );
    }
}
