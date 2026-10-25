//! The harnesses this device can manage: the ones it can host.

use serde::{Deserialize, Serialize};

/// One external harness POCOX hosts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// OpenAI Codex (`codex app-server`).
    Codex,
    /// Native OpenCode (`opencode serve`).
    #[serde(rename = "opencode")]
    OpenCode,
    /// The `claude` CLI the Claude preset's adapter drives.
    Claude,
    /// Grok Build (`grok agent stdio`).
    Grok,
}

impl Kind {
    /// Every kind, in display order.
    pub const ALL: [Self; 4] = [Self::Codex, Self::OpenCode, Self::Claude, Self::Grok];

    /// Stable wire label.
    pub fn label(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::OpenCode => "opencode",
            Self::Claude => "claude",
            Self::Grok => "grok",
        }
    }

    /// The kind named `label`.
    pub fn parse(label: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.label() == label)
    }

    /// Whether this computer can host it: Codex wherever hosting runs; the
    /// others only where owned agent processes can be supervised.
    pub fn hostable(self) -> bool {
        match self {
            Self::Codex => true,
            Self::OpenCode | Self::Claude | Self::Grok => {
                crate::engine::serve_acp::hosting_supported()
            },
        }
    }
}
