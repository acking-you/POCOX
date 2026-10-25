//! What is installed: each harness found exactly as hosting finds it, its
//! version, how its vendor updates it, and where the vendor publishes its
//! newest version.
//!
//! Codex mirrors upstream (`codex-rs/install-context` and
//! `tui/src/update_action.rs`): an npm, bun or pnpm global package, a
//! Homebrew cask on macOS, or the standalone installer, each with the command
//! `codex update` itself runs; anything else is not updatable. Its package
//! manager is run directly, so a Windows host can stop its own `codex.exe`
//! first. OpenCode, the `claude` CLI and Grok Build have updaters of their
//! own (`opencode upgrade`, `claude update`, `grok update`), which are used
//! as they are, except a Homebrew `claude`, which Homebrew updates.

use std::path::{Path, PathBuf};

use super::command::{self, Invocation};
use super::Kind;
use crate::engine::host_profiles::Runtime;
use crate::engine::{claude_setup, config, host_lifecycle, runtime, serve_acp, serve_opencode};

/// A global package manager.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Manager {
    /// npm.
    Npm,
    /// Bun.
    Bun,
    /// pnpm.
    Pnpm,
}

/// How an installation updates.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Method {
    /// A global package of this manager.
    Package(Manager),
    /// A Homebrew cask.
    Brew,
    /// Codex's standalone installer.
    Standalone,
    /// The harness's own updater.
    Own,
    /// Not updatable from here: `unmanaged`, `winget` or `bundled`.
    Not(&'static str),
}

impl Method {
    /// Stable wire label, when it can update.
    pub(super) fn label(self) -> Option<&'static str> {
        match self {
            Self::Package(Manager::Npm) => Some("npm"),
            Self::Package(Manager::Bun) => Some("bun"),
            Self::Package(Manager::Pnpm) => Some("pnpm"),
            Self::Brew => Some("brew"),
            Self::Standalone => Some("standalone"),
            Self::Own => Some("own"),
            Self::Not(_) => None,
        }
    }
}

/// Where the newest version of an installation is published.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Source {
    /// An npm package's dist-tag.
    Npm {
        /// The package.
        package: &'static str,
        /// Its dist-tag.
        tag: &'static str,
    },
    /// A Homebrew cask's version.
    Cask(&'static str),
    /// A GitHub repository's latest release tag, less a prefix.
    GitHub {
        /// `owner/name`.
        repo: &'static str,
        /// The tag prefix before the version.
        prefix: &'static str,
    },
    /// A plain-text version at this URL.
    Text(&'static str),
    /// The harness reports it (`grok update --check --json`).
    Own,
    /// Nothing to look up: it is not updated here.
    Unchecked,
}

/// One installed harness.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Installed {
    /// Which harness.
    pub(super) kind: Kind,
    /// The executable hosting launches.
    pub(super) path: PathBuf,
    /// Its version, when it reports one.
    pub(super) version: Option<String>,
    /// How it updates.
    pub(super) method: Method,
    /// Where its newest version is published.
    pub(super) source: Source,
}

impl Installed {
    /// The vendor command that updates it, when it can be updated and its
    /// tool is found.
    pub(super) fn update(&self) -> Option<Invocation> {
        let own_dir = self.path.parent();
        // Only Codex updates as a global package.
        let package = "@openai/codex";
        let (program, args): (PathBuf, Vec<&str>) = match self.method {
            Method::Package(Manager::Npm) => {
                (command::resolve("npm", own_dir)?, vec!["install", "-g", package])
            },
            Method::Package(Manager::Bun) => {
                (command::resolve("bun", own_dir)?, vec!["install", "-g", package])
            },
            Method::Package(Manager::Pnpm) => {
                (command::resolve("pnpm", own_dir)?, vec!["add", "-g", package])
            },
            Method::Brew => {
                (command::resolve("brew", own_dir)?, vec!["upgrade", "--cask", match self.kind {
                    Kind::Claude => "claude-code",
                    _ => "codex",
                }])
            },
            Method::Standalone if cfg!(windows) => (command::resolve("powershell", None)?, vec![
                "-ExecutionPolicy",
                "Bypass",
                "-c",
                "$env:CODEX_NON_INTERACTIVE=1; irm https://chatgpt.com/codex/install.ps1 | iex",
            ]),
            Method::Standalone => (command::resolve("sh", None)?, vec![
                "-c",
                "curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh",
            ]),
            Method::Own => (self.path.clone(), vec![match self.kind {
                Kind::OpenCode => "upgrade",
                _ => "update",
            }]),
            Method::Not(_) => return None,
        };
        Some(Invocation {
            program,
            args: args.into_iter().map(str::to_string).collect(),
        })
    }

    /// The major version newer releases must share: OpenCode publishes its
    /// 1.x and 2.x lines separately, and moving between them is OpenCode's
    /// own explicit migration, never an update.
    pub(super) fn line(&self) -> Option<u64> {
        (self.kind == Kind::OpenCode)
            .then(|| self.version.as_deref().and_then(parse_version))
            .flatten()
            .map(|version| version.major)
    }
}

/// The first `x.y.z` token of a `--version` line (`codex-cli 0.46.0`,
/// `opencode v2.1.4`, `2.1.296 (Claude Code)`, `grok 1.0.62 (…) [stable]`).
pub(super) fn version_text(output: &str) -> Option<String> {
    output
        .split_whitespace()
        .map(|token| token.trim_matches(|c: char| !c.is_ascii_alphanumeric()))
        .find(|token| parse_version(token).is_some())
        .map(|token| token.trim_start_matches('v').to_string())
}

/// A version, with or without a leading `v`.
pub(super) fn parse_version(text: &str) -> Option<semver::Version> {
    semver::Version::parse(text.trim().trim_start_matches('v')).ok()
}

/// Whether `latest` is newer than `installed`, within `line` when given.
pub(super) fn is_newer(latest: &str, installed: &str, line: Option<u64>) -> bool {
    match (parse_version(latest), parse_version(installed)) {
        (Some(latest), Some(installed)) => {
            line.is_none_or(|major| latest.major == major) && latest > installed
        },
        _ => false,
    }
}

/// Look for `kind` on this computer; `None` when it is not installed.
/// Codex and OpenCode take the executable their running services were
/// launched with (`running`), then what a new service finds, then one a
/// stopped service saved; the others are found as their preset finds them.
/// Blocks on bounded version probes.
pub(super) fn detect(kind: Kind, running: Option<&Path>) -> Option<Installed> {
    if !kind.hostable() {
        return None;
    }
    match kind {
        Kind::Codex => codex(running),
        Kind::OpenCode => opencode(running),
        Kind::Claude => claude(),
        Kind::Grok => grok(),
    }
}

fn version_of(path: &Path) -> Option<String> {
    command::probe(path, &["--version"]).and_then(|output| version_text(&output))
}

/// The executables services of `kind` saved for their restore.
fn saved_binaries(kind: Kind) -> Vec<String> {
    host_lifecycle::entries()
        .unwrap_or_default()
        .into_values()
        .filter_map(|entry| match (kind, entry.runtime?) {
            (
                Kind::Codex,
                Runtime::Codex {
                    binary, ..
                },
            )
            | (
                Kind::OpenCode,
                Runtime::OpenCode {
                    binary, ..
                },
            ) => binary,
            _ => None,
        })
        .collect()
}

fn codex(running: Option<&Path>) -> Option<Installed> {
    let configured = runtime::support_dir()
        .ok()
        .and_then(|support| config::load_config(&support).ok())
        .and_then(|config| config.codex.binary);
    let path = running
        .filter(|path| path.exists())
        .map(Path::to_path_buf)
        .or_else(|| pocox_codex::locate_binary(configured.as_deref()))
        .or_else(|| {
            saved_binaries(Kind::Codex)
                .iter()
                .find_map(|binary| pocox_codex::locate_binary(Some(binary)))
        })?;
    let home = pocox_codex::rollout::codex_home().ok();
    let method = codex_method(&path, home.as_deref(), cfg!(target_os = "macos"));
    let source = match method {
        Method::Package(_) => Source::Npm {
            package: "@openai/codex",
            tag: "latest",
        },
        Method::Brew => Source::Cask("codex"),
        _ => Source::GitHub {
            repo: "openai/codex",
            prefix: "rust-v",
        },
    };
    Some(Installed {
        kind: Kind::Codex,
        version: version_of(&path),
        path,
        method,
        source,
    })
}

/// How the Codex at `path` was installed (upstream's `install_method`, from
/// outside the process: its npm shim's ownership checks become the package
/// layout around the executable).
pub(super) fn codex_method(path: &Path, codex_home: Option<&Path>, macos: bool) -> Method {
    let canonical = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let releases = codex_home
        .and_then(|home| std::fs::canonicalize(home).ok())
        .map(|home| home.join("packages").join("standalone").join("releases"));
    if releases.is_some_and(|releases| canonical.starts_with(releases)) {
        return Method::Standalone;
    }
    if let Some(manager) = package_manager(path, &canonical, &["@openai", "codex"]) {
        return Method::Package(manager);
    }
    if macos && (path.starts_with("/opt/homebrew") || path.starts_with("/usr/local")) {
        return Method::Brew;
    }
    Method::Not("unmanaged")
}

/// The package manager whose global package `package` (`[scope, name]`)
/// `path` launches: the package itself is behind the link (Unix), beside the
/// shim (npm on Windows), in pnpm's `global/<n>` beside its shims, or in
/// Bun's `install/global` beside its `bin`.
fn package_manager(path: &Path, canonical: &Path, package: &[&str; 2]) -> Option<Manager> {
    let inside = |candidate: &Path| {
        let parts: Vec<String> = candidate
            .components()
            .map(|part| part.as_os_str().to_string_lossy().to_ascii_lowercase())
            .collect();
        parts.windows(3).any(|window| {
            window[0] == "node_modules" && window[1] == package[0] && window[2] == package[1]
        })
    };
    let dir = path.parent()?;
    let beside = |root: &Path| {
        root.join(package[0])
            .join(package[1])
            .join("package.json")
            .is_file()
    };
    let bun_global = dir
        .parent()
        .map(|bun| bun.join("install").join("global").join("node_modules"));
    let pnpm_global = || {
        std::fs::read_dir(dir.join("global"))
            .into_iter()
            .flatten()
            .flatten()
            .any(|store| beside(&store.path().join("node_modules")))
    };
    let found = inside(canonical)
        || beside(&dir.join("node_modules"))
        || bun_global.as_deref().is_some_and(beside)
        || pnpm_global();
    if !found {
        return None;
    }
    let text = |candidate: &Path| {
        candidate
            .to_string_lossy()
            .replace('\\', "/")
            .to_ascii_lowercase()
    };
    let seen = [text(path), text(canonical)];
    Some(if seen.iter().any(|text| text.contains("/.bun/")) {
        Manager::Bun
    } else if seen
        .iter()
        .any(|text| text.contains("/pnpm/") || text.contains("/.pnpm/"))
    {
        Manager::Pnpm
    } else {
        Manager::Npm
    })
}

fn opencode(running: Option<&Path>) -> Option<Installed> {
    let explicit = |path: &str| serve_opencode::program(Some(path)).ok();
    let path = running
        .and_then(|path| explicit(&path.to_string_lossy()))
        .or_else(|| serve_opencode::program(None).ok())
        .or_else(|| {
            saved_binaries(Kind::OpenCode)
                .iter()
                .find_map(|binary| explicit(binary))
        })?;
    let version = version_of(&path);
    let major = version.as_deref().and_then(parse_version).map(|v| v.major);
    Some(Installed {
        kind: Kind::OpenCode,
        source: Source::Npm {
            // OpenCode 1.x is `opencode-ai`; 2.x is `@opencode/cli`.
            package: if major.is_some_and(|major| major >= 2) {
                "@opencode/cli"
            } else {
                "opencode-ai"
            },
            tag: "latest",
        },
        version,
        path,
        method: Method::Own,
    })
}

fn claude() -> Option<Installed> {
    use pocox_host_svc::acp::claude::{Cli, CLI_ENV};
    let environment = claude_setup::environment().ok()?;
    let path = match environment.cli {
        Cli::Found(path) => path,
        Cli::Inherited => PathBuf::from(std::env::var_os(CLI_ENV)?),
        // The adapter drives the Claude Code its SDK bundles, which updates
        // with the adapter (pinned by this app), not here.
        Cli::Missing => {
            let adapter = environment.adapter?;
            return Some(Installed {
                kind: Kind::Claude,
                path: adapter.bin,
                version: None,
                method: Method::Not("bundled"),
                source: Source::Unchecked,
            });
        },
    };
    let channel = claude_channel();
    let canonical = std::fs::canonicalize(&path).unwrap_or_else(|_| path.clone());
    let text = canonical.to_string_lossy().replace('\\', "/");
    // `claude update` updates native and npm installations on their channel;
    // Homebrew updates its own cask.
    let (method, source) = if text.contains("/node_modules/@anthropic-ai/claude-code/") {
        (Method::Own, Source::Npm {
            package: "@anthropic-ai/claude-code",
            tag: channel,
        })
    } else if text.contains("/Caskroom/claude-code") {
        (Method::Brew, Source::Cask("claude-code"))
    } else {
        (
            Method::Own,
            Source::Text(match channel {
                "stable" => "https://downloads.claude.ai/claude-code-releases/stable",
                _ => "https://downloads.claude.ai/claude-code-releases/latest",
            }),
        )
    };
    Some(Installed {
        kind: Kind::Claude,
        version: version_of(&path),
        path,
        method,
        source,
    })
}

/// The release channel Claude Code updates from (`autoUpdatesChannel` in
/// its user settings): `stable` or `latest`, its default.
fn claude_channel() -> &'static str {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let settings = home
        .map(|home| home.join(".claude").join("settings.json"))
        .and_then(|path| std::fs::read(path).ok())
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok());
    match settings
        .as_ref()
        .and_then(|value| value["autoUpdatesChannel"].as_str())
    {
        Some("stable") => "stable",
        _ => "latest",
    }
}

fn grok() -> Option<Installed> {
    use pocox_host_svc::acp::grok;
    let path = serve_acp::locate(grok::PROGRAM, Some(grok::PROFILE_ID))?;
    let canonical = std::fs::canonicalize(&path).unwrap_or_else(|_| path.clone());
    // `grok update` refuses a WinGet installation; WinGet updates it.
    let winget = canonical
        .to_string_lossy()
        .to_ascii_lowercase()
        .replace('\\', "/")
        .contains("winget/packages/xai.grokbuild_");
    Some(Installed {
        kind: Kind::Grok,
        version: version_of(&path),
        path,
        method: if winget { Method::Not("winget") } else { Method::Own },
        source: Source::Own,
    })
}
