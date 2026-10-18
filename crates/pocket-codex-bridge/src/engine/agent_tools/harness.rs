//! Configuration for harnesses POCOX does not launch: a ready-to-paste
//! entry with the endpoint and a token issued to that harness.

use serde_json::json;

use super::Issued;

/// The entry for `harness`: `codex` (config.toml), `claude` (a `claude mcp
/// add` command), `opencode` (opencode.json) or any other MCP client
/// (`mcpServers` JSON).
pub fn snippet(harness: &str, issued: &Issued) -> String {
    let bearer = format!("Bearer {}", issued.token);
    match harness {
        "codex" => format!(
            "# ~/.codex/config.toml\n[mcp_servers.pocox]\nurl = {url}\nhttp_headers = {{ \
             Authorization = {bearer} }}\ntool_timeout_sec = 180\n",
            url = json!(issued.url),
            bearer = json!(bearer),
        ),
        "claude" => format!(
            "claude mcp add --transport http --scope user pocox {} --header {}\n",
            issued.url,
            shell_quote(&format!("Authorization: {bearer}")),
        ),
        "opencode" => format!(
            "{:#}\n",
            json!({"mcp": {"pocox": {
                "type": "remote", "url": issued.url, "enabled": true,
                "headers": {"Authorization": bearer}, "oauth": false, "timeout": 180000,
            }}})
        ),
        _ => format!(
            "{:#}\n",
            json!({"mcpServers": {"pocox": {
                "type": "http", "url": issued.url, "headers": {"Authorization": bearer},
            }}})
        ),
    }
}

fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_entry_names_the_endpoint_and_carries_the_token_once() {
        let issued = Issued {
            url: "http://127.0.0.1:17863/mcp".into(),
            token: "pcxt_abc".into(),
            id: "t".into(),
        };
        for harness in ["codex", "claude", "opencode", "generic"] {
            let text = snippet(harness, &issued);
            assert!(text.contains("http://127.0.0.1:17863/mcp"), "{harness}");
            assert_eq!(text.matches("pcxt_abc").count(), 1, "{harness}");
        }
        let codex: toml::Value = toml::from_str(&snippet("codex", &issued)).expect("toml");
        assert_eq!(
            codex["mcp_servers"]["pocox"]["http_headers"]["Authorization"].as_str(),
            Some("Bearer pcxt_abc")
        );
    }
}
