//! Configuration for harnesses POCOX does not launch: a ready-to-paste
//! entry with the endpoint and a token issued to that harness. Entries go
//! into configuration files, never onto a command line, where the token
//! would reach shell history and other users' process listings.

use serde_json::json;

use super::Issued;

/// Where the entry for `harness` goes.
pub fn destination(harness: &str) -> &'static str {
    match harness {
        "codex" => "Add it to ~/.codex/config.toml.",
        "claude" => {
            "Add the pocox entry to \"mcpServers\" in ~/.claude.json (every project), or in a \
             project's .mcp.json kept out of version control."
        },
        "opencode" => "Merge it into ~/.config/opencode/opencode.json.",
        _ => "Add the pocox entry to your MCP client's servers.",
    }
}

/// The entry for `harness`: `codex` (config.toml), `opencode`
/// (opencode.json), or `mcpServers` JSON for Claude Code and any other MCP
/// client.
pub fn snippet(harness: &str, issued: &Issued) -> String {
    let bearer = format!("Bearer {}", issued.token);
    match harness {
        "codex" => format!(
            "# ~/.codex/config.toml\n[mcp_servers.pocox]\nurl = {url}\nhttp_headers = {{ \
             Authorization = {bearer} }}\ntool_timeout_sec = 180\n",
            url = json!(issued.url),
            bearer = json!(bearer),
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
        let claude: serde_json::Value =
            serde_json::from_str(&snippet("claude", &issued)).expect("json");
        assert_eq!(claude["mcpServers"]["pocox"]["headers"]["Authorization"], "Bearer pcxt_abc");
        let codex: toml::Value = toml::from_str(&snippet("codex", &issued)).expect("toml");
        assert_eq!(
            codex["mcp_servers"]["pocox"]["http_headers"]["Authorization"].as_str(),
            Some("Bearer pcxt_abc")
        );
    }
}
