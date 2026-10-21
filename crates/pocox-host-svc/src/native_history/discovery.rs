//! Resolve the installed reader alongside the adapter actually being used.

use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde_json::Value;

use super::ClaudeHistory;

impl ClaudeHistory {
    /// Use the official SDK installed with this adapter. No package is fetched,
    /// and no unrelated global SDK or controller-local data root is
    /// substituted.
    pub fn from_adapter(node: PathBuf, adapter: &Path, root: PathBuf) -> Result<Self> {
        let adapter = adapter
            .canonicalize()
            .context("resolving the installed ACP adapter")?;
        for parent in adapter.ancestors().skip(1).take(6) {
            let Ok(manifest) = std::fs::read(parent.join("package.json")) else { continue };
            let Ok(manifest) = serde_json::from_slice::<Value>(&manifest) else { continue };
            if manifest["name"] != crate::acp::claude::ADAPTER_PACKAGE {
                continue;
            }
            // Node resolves a dependency from the package, then its ancestors.
            for base in parent.ancestors().take(5) {
                let sdk = base.join("node_modules/@anthropic-ai/claude-agent-sdk");
                let Ok(manifest) = std::fs::read(sdk.join("package.json")) else { continue };
                let Ok(manifest) = serde_json::from_slice::<Value>(&manifest) else { continue };
                if manifest["name"] == "@anthropic-ai/claude-agent-sdk"
                    && sdk.join("sdk.mjs").is_file()
                {
                    return Self::new(node, sdk.join("sdk.mjs").canonicalize()?, root);
                }
            }
            break;
        }
        bail!(
            "the installed Claude ACP adapter has no readable official session SDK; prepare the \
             environment again"
        )
    }
}
