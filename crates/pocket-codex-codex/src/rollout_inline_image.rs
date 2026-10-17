//! The model request's own copy of an image a user message attached.
//!
//! codex sends every attachment inline: a user message's `response_item`
//! carries `<image name=[Image #N] path="…">`, the `input_image` data URL and
//! `</image>` as consecutive content parts. The app-server history keeps
//! only the `localImage` path. A pasted screenshot lives in the OS temp
//! directory, which the system clears, so once the file is gone this inline
//! copy is the only one left.

use std::{io::BufRead, path::Path};

use pocket_codex_core::Result;
use serde_json::Value;

/// The data URL a user message of the rollout at `rollout` sent for the
/// attachment at `path`, if it recorded one.
///
/// Only an `input_image` that directly follows the `<image … path="…">` tag
/// naming exactly `path` counts. Lines that do not mention the path are not
/// parsed, so scanning a long rollout stays cheap.
pub fn inline_user_image(rollout: &Path, path: &str) -> Result<Option<String>> {
    // How the path appears inside a JSON string (quotes and backslashes
    // escaped), for the prefilter.
    let escaped = serde_json::to_string(path)?;
    let needle = escaped.trim_matches('"');
    let reader = std::io::BufReader::new(std::fs::File::open(rollout)?);
    for line in reader.lines() {
        // A partially written last line, or a line that is not UTF-8, ends
        // nothing: the image may still be on an earlier line.
        let Ok(line) = line else { continue };
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
    use std::io::Write;

    use super::*;

    fn message(parts: Value) -> String {
        serde_json::json!({
            "type": "response_item",
            "payload": {"type": "message", "role": "user", "content": parts},
        })
        .to_string()
    }

    #[test]
    fn finds_the_inline_copy_named_by_the_attachment_tag() {
        let dir = tempfile::tempdir().expect("tempdir");
        let rollout = dir.path().join("rollout.jsonl");
        let wanted = "/var/folders/T/codex-clipboard-a.png";
        let mut file = std::fs::File::create(&rollout).expect("create");
        // A reply that merely names the path, and another attachment, come
        // first; neither is the image the user attached from `wanted`.
        writeln!(
            file,
            "{}",
            serde_json::json!({
                "type": "response_item",
                "payload": {"type": "message", "role": "assistant", "content": [
                    {"type": "output_text", "text": format!("<image name=[Image #1] path=\"{wanted}\">")},
                    {"type": "input_image", "image_url": "data:image/png;base64,QUFB"},
                ]},
            })
        )
        .expect("write");
        writeln!(
            file,
            "{}",
            message(serde_json::json!([
                {"type": "input_text", "text": "<image name=[Image #1] path=\"/tmp/other.png\">"},
                {"type": "input_image", "image_url": "data:image/png;base64,T1RIRVI="},
                {"type": "input_text", "text": "</image>"},
                {"type": "input_text", "text": format!("mentions {wanted} in prose")},
            ]))
        )
        .expect("write");
        writeln!(
            file,
            "{}",
            message(serde_json::json!([
                {"type": "input_text", "text": format!("<image name=[Image #2] path=\"{wanted}\">")},
                {"type": "input_image", "image_url": "data:image/png;base64,V0FOVEVE"},
                {"type": "input_text", "text": "</image>"},
            ]))
        )
        .expect("write");
        drop(file);

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
