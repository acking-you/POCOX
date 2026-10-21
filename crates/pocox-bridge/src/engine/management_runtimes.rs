//! Host-side discovery and explicit preparation of built-in runtimes.

use anyhow::Result;
use serde::{Deserialize, Serialize};

use super::{claude_setup, config, runtime, serve_opencode};

/// A runtime already present on the selected computer; detection never
/// installs.
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Availability {
    /// `codex`, `opencode`, or `claude`.
    pub kind: String,
    /// The installed runtime can be selected now (provider credentials may
    /// still be required).
    pub ready: bool,
    /// Installed executable path, never supplied by a controller.
    pub path: Option<String>,
    /// Detected version when the runtime reports one.
    pub version: Option<String>,
    /// Existing inherited credentials need attention on the host.
    pub needs_host_login: bool,
    /// Explicit preparation can install the pinned built-in adapter.
    pub can_prepare: bool,
    /// Concise safe explanation of unavailable state.
    pub problem: Option<String>,
}

/// Detect the computer's supported native services without starting them.
pub fn detect() -> Result<Vec<Availability>> {
    let saved = config::load_config(&runtime::support_dir()?)?.codex.binary;
    let codex = pocox_codex::locate_binary(saved.as_deref());
    let setup = pocox_codex::setup::setup_status().ok();
    let mut rows = vec![Availability {
        kind: "codex".into(),
        ready: codex.is_some(),
        path: codex.as_ref().map(|p| p.to_string_lossy().into_owned()),
        version: None,
        needs_host_login: setup.as_ref().is_none_or(|s| s.needs_setup),
        can_prepare: false,
        problem: codex
            .is_none()
            .then(|| "Install Codex on this computer first.".into()),
    }];
    let opencode = serve_opencode::detect(None).ok();
    rows.push(Availability {
        kind: "opencode".into(),
        ready: opencode.is_some(),
        path: opencode.as_ref().map(|found| found.path.clone()),
        version: opencode.as_ref().map(|found| found.version.clone()),
        needs_host_login: false,
        can_prepare: false,
        problem: opencode
            .is_none()
            .then(|| "OpenCode is missing or could not be started on this computer.".into()),
    });
    let claude = claude_setup::status().ok();
    rows.push(Availability {
        kind: "claude".into(),
        ready: claude.as_ref().is_some_and(|s| s.ready),
        path: claude.as_ref().and_then(|s| s.adapter_path.clone()),
        version: None,
        needs_host_login: false,
        can_prepare: claude.as_ref().is_some_and(|s| s.can_prepare),
        problem: match &claude {
            Some(s) if s.ready => None,
            Some(s) if s.can_prepare => {
                Some("Prepare the pinned Claude adapter before starting.".into())
            },
            _ => Some(
                "Install a supported Node.js runtime on this computer to prepare Claude.".into(),
            ),
        },
    });
    let grok = super::serve_acp::locate(
        pocox_host_svc::acp::grok::PROGRAM,
        Some(pocox_host_svc::acp::grok::PROFILE_ID),
    );
    rows.push(Availability {
        kind: "grok".into(),
        ready: grok.is_some(),
        path: grok.as_ref().map(|p| p.to_string_lossy().into_owned()),
        version: None,
        // Grok's own sign-in happens on this computer; existing configuration
        // may already work through an API key or custom models.
        needs_host_login: false,
        can_prepare: false,
        problem: grok
            .is_none()
            .then(|| "Install Grok Build on this computer first.".into()),
    });
    Ok(rows)
}

/// Progress for the explicit pinned-adapter preparation.
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Preparation {
    /// `idle`, `running`, `done`, `failed`, or `cancelled`.
    pub state: String,
    /// Current download/install phase.
    pub stage: Option<String>,
    /// Elapsed milliseconds.
    pub elapsed_ms: u64,
    /// Received bytes, when known.
    pub downloaded_bytes: Option<u64>,
    /// Bytes per second, when known.
    pub download_bytes_per_second: Option<u64>,
    /// Stable run identity.
    pub run: u64,
    /// This call initiated the run; false for observers/joiners.
    pub started: bool,
    /// Safe explanation; raw package-manager output stays on the host.
    pub error: Option<String>,
}
impl From<claude_setup::Snapshot> for Preparation {
    fn from(s: claude_setup::Snapshot) -> Self {
        Self {
            state: s.state.into(),
            stage: s.stage.map(str::to_string),
            elapsed_ms: s.elapsed_ms,
            downloaded_bytes: s.downloaded_bytes,
            download_bytes_per_second: s.download_bytes_per_second,
            run: s.run,
            started: s.started,
            error: s.error.map(|_| {
                "Adapter preparation failed. Check the host's diagnostics and retry.".into()
            }),
        }
    }
}

/// Explicit request only; discovery and starting a host never call this.
pub fn prepare() -> Preparation {
    claude_setup::prepare_start().into()
}
/// Observe without starting or joining a new run.
pub fn progress() -> Preparation {
    claude_setup::prepare_state().into()
}
