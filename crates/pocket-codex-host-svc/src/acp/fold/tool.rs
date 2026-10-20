//! A tool call's fields, as an update reports them.

use serde_json::Value;

use super::*;

/// Apply supplied tool fields; collections are replaced, never appended, and
/// so are the omissions they report.
pub(super) fn apply_tool_fields(item: &mut Item, update: &Value) {
    let tool = item.tool.get_or_insert_with(Tool::default);
    if let Some(title) = update["title"].as_str() {
        item.title = title.chars().take(1024).collect();
    }
    if let Some(kind) = update["kind"].as_str() {
        tool.kind = kind.chars().take(64).collect();
    }
    if let Some(status) = update["status"].as_str() {
        tool.status = status.chars().take(64).collect();
    }
    if let Some(name) = update["name"].as_str() {
        tool.name = Some(name.chars().take(256).collect());
    }
    // Grok's canonical tool identity (`xai-grok-tools/src/tool_taxonomy.rs`).
    let canonical = &update["_meta"]["x.ai/tool"];
    if let Some(kind) = canonical["kind"].as_str() {
        tool.category = Some(kind.chars().take(64).collect());
    }
    if tool.name.is_none() {
        if let Some(name) = canonical["name"].as_str() {
            tool.name = Some(name.chars().take(256).collect());
        }
    }
    let mut input_dropped = None;
    if let Some(raw) = update.get("rawInput").filter(|raw| !raw.is_null()) {
        let size = serialized_len(raw);
        input_dropped = Some(size > MAX_RAW_INPUT);
        tool.raw_input = Some(if size > MAX_RAW_INPUT {
            Value::String(format!("[input omitted: {size} bytes]"))
        } else {
            raw.clone()
        });
    }
    let mut locations_dropped = None;
    if let Some(locations) = update["locations"].as_array() {
        let mut dropped = locations.len() > MAX_LOCATIONS;
        tool.locations = locations
            .iter()
            .filter_map(|location| location["path"].as_str())
            .take(MAX_LOCATIONS)
            .map(|path| {
                let mut path = path.to_string();
                dropped |= clip(&mut path, MAX_LOCATION);
                path
            })
            .collect();
        locations_dropped = Some(dropped);
    }
    let mut content_dropped = None;
    if let Some(content) = update["content"].as_array() {
        let mut text = String::new();
        let mut images = Vec::new();
        let mut diff_budget = MAX_ITEM_TEXT;
        let (mut images_dropped, mut diffs_dropped) = (false, false);
        tool.diffs.clear();
        tool.terminals = 0;
        for entry in content.iter().take(256) {
            match entry["type"].as_str() {
                Some("content") => {
                    let (piece, image) = block_content(&entry["content"]);
                    if !piece.is_empty() {
                        if !text.is_empty() {
                            text.push('\n');
                        }
                        text.push_str(&piece);
                    }
                    if let Some(image) = image {
                        images_dropped |= !push_image(&mut images, image);
                    }
                },
                Some("diff") => {
                    let (Some(path), Some(new_text)) =
                        (entry["path"].as_str(), entry["newText"].as_str())
                    else {
                        continue;
                    };
                    let old_text = entry["oldText"].as_str();
                    let size = path.len() + new_text.len() + old_text.map_or(0, str::len);
                    if tool.diffs.len() >= MAX_DIFFS || size > diff_budget {
                        diffs_dropped = true;
                        continue;
                    }
                    diff_budget -= size;
                    tool.diffs.push(Diff {
                        path: path.to_string(),
                        old_text: old_text.map(str::to_string),
                        new_text: new_text.to_string(),
                    });
                },
                Some("terminal") => tool.terminals += 1,
                _ => {},
            }
        }
        item.text_full = clip(&mut text, MAX_ITEM_TEXT);
        item.text = text;
        item.images = images;
        content_dropped = Some((content.len() > 256, images_dropped, diffs_dropped));
    }
    if item.text.is_empty() {
        if let Some(mut text) = raw_output_text(&update["rawOutput"]) {
            item.text_full = clip(&mut text, MAX_ITEM_TEXT);
            item.text = text;
        }
    }
    if let Some(dropped) = input_dropped {
        item.omit_if(OMITTED_INPUT, dropped);
    }
    if let Some(dropped) = locations_dropped {
        item.omit_if(OMITTED_LOCATIONS, dropped);
    }
    if let Some((entries, images, diffs)) = content_dropped {
        item.omit_if(OMITTED_CONTENT, entries);
        item.omit_if(OMITTED_IMAGES, images);
        item.omit_if(OMITTED_DIFFS, diffs);
    }
    item.truncated = item.text_full || !item.omitted.is_empty();
}

/// The text of a result reported only as `rawOutput`, as Grok reports MCP
/// calls and text results (its `ToolOutput`, `xai-grok-tools/src/types/
/// output.rs`; read the same way by its own client, `xai-grok-pager/src/acp/
/// tracker.rs`, `extract_use_tool_output`).
fn raw_output_text(raw: &Value) -> Option<String> {
    let text = match raw["type"].as_str()? {
        "MCP" => {
            let output = &raw["output"];
            output["OkayOutput"]
                .as_str()
                .or_else(|| output["Error"].as_str())
        },
        "Text" => raw["text"].as_str(),
        _ => None,
    }?;
    (!text.is_empty()).then(|| text.to_string())
}
