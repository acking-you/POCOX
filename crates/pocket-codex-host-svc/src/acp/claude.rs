//! Launching the Claude preset on what this computer actually has.
//!
//! Claude speaks ACP through a separate adapter,
//! `@agentclientprotocol/claude-agent-acp` (binary `claude-agent-acp`), a
//! Node.js program that needs Node.js 22 or newer and drives the native
//! `claude` CLI itself. The native CLI never speaks ACP on stdio, so finding
//! it never counts as finding the adapter.
//!
//! Discovery applies only to the preset's own bare program
//! ([`applies`]); an explicit path or any other program is launched exactly
//! as configured. Then, first match wins:
//!
//! 1. **Adapter**: the child `PATH`, well-known global install directories,
//!    per-version Node.js managers (newest first), then this app's prepared
//!    copy of the pinned version (see [`super::claude_setup`]), accepted only
//!    with a valid completion marker and an installation that still checks out
//!    ([`check_installation`]).
//! 2. **Runtime**: a Node.js >= [`MIN_NODE_MAJOR`] — the one beside the
//!    adapter, the child `PATH`, well-known locations, then version managers
//!    newest first — verified by running `node --version` (bounded in time and
//!    output, in its own cleaned-up process group). An adapter installed as a
//!    Node.js script is then launched as `node <script> <args…>`, so the user's
//!    default Node.js is never changed and nothing global is touched. Without
//!    an adapter, the search continues to the first such Node.js with npm
//!    beside it, which can prepare one.
//! 3. **Native CLI**: an inherited [`CLI_ENV`] is kept as is; otherwise the
//!    `claude` found on the child `PATH` or in its usual install locations is
//!    passed to the adapter through [`CLI_ENV`] in the child's environment
//!    only. Without one the adapter uses the CLI bundled with its SDK.
//!
//! Authentication stays Claude's own (its login or its environment, which the
//! child inherits); nothing here reads credentials, and status shows only
//! paths and versions.

use std::{
    ffi::{OsStr, OsString},
    path::{Path, PathBuf},
    time::Duration,
};

use serde_json::Value;

use super::spec::{is_executable, AgentSpec};
use crate::process;

/// The preset's profile id.
pub const PROFILE_ID: &str = "claude";
/// The adapter's executable name.
pub const ADAPTER_BIN: &str = "claude-agent-acp";
/// The adapter's npm package.
pub const ADAPTER_PACKAGE: &str = "@agentclientprotocol/claude-agent-acp";
/// The adapter version this app prepares (pinned, never `latest`).
pub const ADAPTER_VERSION: &str = "0.89.1";
/// The npm registry integrity of [`ADAPTER_VERSION`]'s tarball.
pub const ADAPTER_INTEGRITY: &str =
    "sha512-t1k8YPDvo/\
     zUghL3x2pFs40tWfYTLhYmK8jt37CVBpY7eq1Ztj2hLZBAmy9ZX++tUyJaGfuuMrzvJGvU9tjBsg==";
/// The oldest Node.js major version the adapter supports.
pub const MIN_NODE_MAJOR: u32 = 22;
/// The adapter's variable naming the native CLI.
pub const CLI_ENV: &str = "CLAUDE_CODE_EXECUTABLE";
/// The marker a completed preparation leaves in its directory.
pub const READY_MARKER: &str = ".pocket-codex-ready.json";
const NODE_PROBE_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_NODE_PROBES: usize = 8;
/// More than a version line is not `node --version`.
const PROBE_OUTPUT_LIMIT: usize = 64;

/// A `major.minor.patch` version.
pub type Version = (u32, u32, u32);

/// Where to look; every input is explicit so tests use fixtures.
#[derive(Debug, Clone, Copy)]
pub struct Lookup<'a> {
    /// The child's `PATH`.
    pub search_path: Option<&'a OsStr>,
    /// The user's home directory.
    pub home: Option<&'a Path>,
    /// This app's runtime cache (`<state>/acp-runtime`).
    pub cache: &'a Path,
    /// Whether [`CLI_ENV`] is already set in the environment the child
    /// inherits.
    pub inherited_cli: bool,
    /// Whether the fixed system locations (`/opt/homebrew`, `/usr/local`)
    /// are searched too; fixtures turn this off.
    pub system: bool,
}

impl Lookup<'_> {
    fn system_dirs<'s>(&self, dirs: &'s [&'s str]) -> &'s [&'s str] {
        if self.system {
            dirs
        } else {
            &[]
        }
    }
}

/// Whether `spec` is the Claude preset's own bare program, whose launch is
/// discovered here; anything else is launched verbatim.
pub fn applies(spec: &AgentSpec) -> bool {
    spec.profile_id == PROFILE_ID && spec.program == ADAPTER_BIN
}

/// Where the adapter came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AdapterSource {
    /// Installed by the user.
    Installed,
    /// This app's prepared copy of [`ADAPTER_VERSION`].
    Prepared,
}

/// A found adapter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Adapter {
    /// The executable found (its session records are keyed by this path).
    pub bin: PathBuf,
    /// The Node.js script it runs, when it is the adapter package's own.
    pub entry: Option<PathBuf>,
    /// Where it came from.
    pub source: AdapterSource,
}

/// A verified Node.js runtime.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Node {
    /// The executable.
    pub path: PathBuf,
    /// Its reported version.
    pub version: Version,
}

/// The native CLI handed to the adapter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Cli {
    /// [`CLI_ENV`] is inherited and kept.
    Inherited,
    /// Found here; passed through [`CLI_ENV`].
    Found(PathBuf),
    /// Not found: the adapter falls back to its SDK's bundled CLI.
    Missing,
}

/// What this computer has for the Claude preset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Environment {
    /// The adapter, if any.
    pub adapter: Option<Adapter>,
    /// A Node.js >= [`MIN_NODE_MAJOR`], if any.
    pub node: Option<Node>,
    /// The newest older Node.js seen, when none was new enough.
    pub too_old: Option<Version>,
    /// A Node.js >= [`MIN_NODE_MAJOR`] with npm beside it, which can prepare
    /// the adapter; searched only when there is no adapter. It may differ
    /// from [`Environment::node`] when that one has no npm.
    pub npm: Option<Npm>,
    /// The native CLI.
    pub cli: Cli,
}

/// A Node.js new enough and the npm installed with it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Npm {
    /// The Node.js executable.
    pub node: PathBuf,
    /// npm's CLI script.
    pub cli: PathBuf,
}

/// What the preset launches.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Launch {
    /// The executable to start.
    pub program: PathBuf,
    /// Its arguments: the adapter script (when run by Node.js) then the
    /// spec's own arguments, verbatim.
    pub args: Vec<String>,
    /// Child-only variables.
    pub env: Vec<(OsString, OsString)>,
    /// The adapter executable, which keys the session record.
    pub source: PathBuf,
}

/// Why the preset cannot start yet.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Missing {
    /// No adapter is installed or prepared.
    #[error(
        "Claude's ACP adapter ({}) is not installed; start the Claude host from the hosting \
         dialog to prepare it, or install it yourself",
        ADAPTER_PACKAGE
    )]
    Adapter,
    /// No Node.js new enough.
    #[error("Claude's ACP adapter needs Node.js {} or newer; {}", MIN_NODE_MAJOR, .0)]
    Runtime(String),
}

/// A version manager's per-version directories under `home`, and where its
/// executables sit inside each.
const MANAGERS: &[(&str, &str)] = &[
    (".nvm/versions/node", "bin"),
    (".local/share/fnm/node-versions", "installation/bin"),
    ("Library/Application Support/fnm/node-versions", "installation/bin"),
    (".asdf/installs/nodejs", "bin"),
    (".local/share/mise/installs/node", "bin"),
    (".volta/tools/image/node", "bin"),
];
/// Global install directories under `home`, in order.
const HOME_BINS: &[&str] = &[
    ".npm-global/bin",
    ".local/bin",
    ".bun/bin",
    ".volta/bin",
    ".local/share/pnpm",
    "Library/pnpm",
    ".yarn/bin",
];
/// Global install directories, after the home ones.
const SYSTEM_BINS: &[&str] = &["/opt/homebrew/bin", "/usr/local/bin"];
/// Extra Node.js locations, after `PATH`.
const NODE_DIRS: &[&str] = &[
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/opt/homebrew/opt/node@22/bin",
    "/usr/local/opt/node@22/bin",
];
/// Usual native CLI locations under `home`, after `PATH`.
const CLI_HOME_DIRS: &[&str] = &[".local/bin", ".claude/local"];

/// Parse `v22.11.0` / `22.11.0` (trailing labels ignored).
pub fn parse_version(text: &str) -> Option<Version> {
    let text = text.trim();
    let mut parts = text.strip_prefix('v').unwrap_or(text).splitn(3, '.');
    let number = |part: Option<&str>| -> Option<u32> {
        let digits: String = part?.chars().take_while(char::is_ascii_digit).collect();
        digits.parse().ok()
    };
    Some((number(parts.next())?, number(parts.next())?, number(parts.next())?))
}

fn absolute_dirs(search_path: Option<&OsStr>) -> Vec<PathBuf> {
    search_path
        .map(|paths| {
            std::env::split_paths(paths)
                .filter(|dir| dir.is_absolute())
                .collect()
        })
        .unwrap_or_default()
}

/// Version-manager bin directories, newest version first.
fn manager_dirs(home: Option<&Path>) -> Vec<(Option<Version>, PathBuf)> {
    let Some(home) = home else { return Vec::new() };
    let mut out = Vec::new();
    for (root, bin) in MANAGERS {
        let Ok(entries) = std::fs::read_dir(home.join(root)) else { continue };
        for entry in entries.flatten() {
            let name = entry.file_name();
            let version = name.to_str().and_then(parse_version);
            out.push((version, entry.path().join(bin)));
        }
    }
    out.sort_by_key(|entry| std::cmp::Reverse(entry.0));
    out
}

/// The adapter package's script behind `bin`, when `bin` is (a link to)
/// its `dist/index.js`.
pub fn adapter_entry(bin: &Path) -> Option<PathBuf> {
    let entry = std::fs::canonicalize(bin).ok()?;
    if entry.extension() != Some(OsStr::new("js")) {
        return None;
    }
    let package = entry.parent()?.parent()?;
    (read_json(&package.join("package.json"))?["name"] == ADAPTER_PACKAGE).then_some(entry)
}

/// `<cache>/claude-agent-acp`: everything preparation owns.
pub fn package_root(cache: &Path) -> PathBuf {
    cache.join(ADAPTER_BIN)
}

/// Where [`ADAPTER_VERSION`] is prepared.
pub fn version_dir(cache: &Path) -> PathBuf {
    package_root(cache).join(ADAPTER_VERSION)
}

/// The script inside a prepared directory.
pub fn prepared_entry(dir: &Path) -> PathBuf {
    dir.join("node_modules")
        .join(ADAPTER_PACKAGE)
        .join("dist")
        .join("index.js")
}

/// The marker contents of a completed preparation.
pub fn ready_marker() -> Value {
    serde_json::json!({
        "package": ADAPTER_PACKAGE,
        "version": ADAPTER_VERSION,
        "integrity": ADAPTER_INTEGRITY,
    })
}

fn read_json(path: &Path) -> Option<Value> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

/// Check the installation in `dir` and return its script: npm's lockfile
/// records the package at [`ADAPTER_VERSION`] with [`ADAPTER_INTEGRITY`] (the
/// registry tarball npm verified when it installed it), the installed
/// manifest agrees, and the script exists. This is a consistency check of
/// what npm recorded, not a re-hash of the installed files. On failure, the
/// part that disagreed.
pub fn check_installation(dir: &Path) -> Result<PathBuf, &'static str> {
    let lock = read_json(&dir.join("package-lock.json"))
        .or_else(|| read_json(&dir.join("node_modules/.package-lock.json")))
        .ok_or("no lockfile")?;
    let locked = &lock["packages"][format!("node_modules/{ADAPTER_PACKAGE}")];
    if locked["version"] != ADAPTER_VERSION {
        return Err("locked version");
    }
    if locked["integrity"] != ADAPTER_INTEGRITY {
        return Err("integrity");
    }
    let manifest = read_json(
        &dir.join("node_modules")
            .join(ADAPTER_PACKAGE)
            .join("package.json"),
    )
    .ok_or("no manifest")?;
    if manifest["name"] != ADAPTER_PACKAGE || manifest["version"] != ADAPTER_VERSION {
        return Err("manifest");
    }
    let entry = prepared_entry(dir);
    if !entry.is_file() {
        return Err("no entry script");
    }
    Ok(entry)
}

/// The prepared adapter's script, only when its preparation completed and
/// its installation still checks out ([`check_installation`]): a partial,
/// foreign or since-changed directory is not used.
pub fn prepared_adapter(cache: &Path) -> Option<PathBuf> {
    let dir = version_dir(cache);
    if read_json(&dir.join(READY_MARKER))? != ready_marker() {
        return None;
    }
    check_installation(&dir).ok()
}

fn find_adapter(lookup: &Lookup<'_>) -> Option<Adapter> {
    let mut dirs = absolute_dirs(lookup.search_path);
    if let Some(home) = lookup.home {
        dirs.extend(HOME_BINS.iter().map(|dir| home.join(dir)));
    }
    dirs.extend(lookup.system_dirs(SYSTEM_BINS).iter().map(PathBuf::from));
    dirs.extend(manager_dirs(lookup.home).into_iter().map(|(_, dir)| dir));
    let installed = dirs
        .into_iter()
        .map(|dir| dir.join(ADAPTER_BIN))
        .find(|bin| is_executable(bin))
        .map(|bin| Adapter {
            entry: adapter_entry(&bin),
            bin,
            source: AdapterSource::Installed,
        });
    installed.or_else(|| {
        prepared_adapter(lookup.cache).map(|entry| Adapter {
            bin: entry.clone(),
            entry: Some(entry),
            source: AdapterSource::Prepared,
        })
    })
}

/// `node --version` of `path`; `None` when it fails, prints anything but a
/// short version, or does not finish within [`NODE_PROBE_TIMEOUT`]. The
/// bound covers its whole lifetime, output included. It runs in its own
/// process group ([`process::spawn`]), which is cleaned up in every case, so
/// a descendant holding its output open neither stalls this nor survives it.
pub async fn node_version(path: &Path) -> Option<Version> {
    // Preloads requested for the user's own programs are not needed to print
    // a version; an empty value requests none.
    let env = [(OsString::from("NODE_OPTIONS"), OsString::new())];
    let output = process::read_output(
        path,
        &["--version".into()],
        None,
        &env,
        NODE_PROBE_TIMEOUT,
        PROBE_OUTPUT_LIMIT,
    )
    .await?;
    parse_version(std::str::from_utf8(&output).ok()?)
}

/// What the Node.js search found.
#[derive(Default)]
struct Runtimes {
    /// The first Node.js new enough: it runs an adapter script.
    node: Option<Node>,
    /// The first Node.js new enough with npm beside it, searched only when
    /// there is no adapter yet: it prepares one.
    npm: Option<Npm>,
    /// The newest older Node.js seen.
    too_old: Option<Version>,
}

/// The first Node.js new enough (and, without an adapter, the first one
/// with npm), and the newest older one seen. Candidates are deduplicated and
/// at most [`MAX_NODE_PROBES`] are run.
async fn find_node(
    lookup: &Lookup<'_>,
    adapter: Option<&Adapter>,
    probe: &mut impl AsyncFnMut(&Path) -> Option<Version>,
) -> Runtimes {
    let mut candidates: Vec<(Option<Version>, PathBuf)> = Vec::new();
    if let Some(dir) = adapter.and_then(|a| a.bin.parent()) {
        candidates.push((None, dir.join("node")));
    }
    candidates.extend(
        absolute_dirs(lookup.search_path)
            .into_iter()
            .map(|dir| (None, dir.join("node"))),
    );
    candidates.extend(
        lookup
            .system_dirs(NODE_DIRS)
            .iter()
            .map(|dir| (None, Path::new(dir).join("node"))),
    );
    candidates.extend(
        manager_dirs(lookup.home)
            .into_iter()
            .map(|(version, dir)| (version, dir.join("node"))),
    );
    let wants_npm = adapter.is_none();
    let mut found = Runtimes::default();
    let mut seen = Vec::new();
    let mut probes = 0;
    for (named, path) in candidates {
        if found.node.is_some() && (found.npm.is_some() || !wants_npm) {
            break;
        }
        if !is_executable(&path) {
            continue;
        }
        let real = std::fs::canonicalize(&path).unwrap_or_else(|_| path.clone());
        if seen.contains(&real) {
            continue;
        }
        seen.push(real);
        // A manager directory named for an older version is not run.
        if let Some(named) = named.filter(|v| v.0 < MIN_NODE_MAJOR) {
            found.too_old = found.too_old.max(Some(named));
            continue;
        }
        // Once a runtime is chosen, only one with npm is still useful.
        let npm = if wants_npm { npm_cli(&path) } else { None };
        if found.node.is_some() && npm.is_none() {
            continue;
        }
        if probes == MAX_NODE_PROBES {
            break;
        }
        probes += 1;
        match probe(&path).await {
            Some(version) if version.0 >= MIN_NODE_MAJOR => {
                if wants_npm && found.npm.is_none() {
                    found.npm = npm.map(|cli| Npm {
                        node: path.clone(),
                        cli,
                    });
                }
                found.node.get_or_insert(Node {
                    path,
                    version,
                });
            },
            Some(version) => found.too_old = found.too_old.max(Some(version)),
            None => {},
        }
    }
    found
}

/// npm's CLI script installed with the Node.js at `node`.
pub fn npm_cli(node: &Path) -> Option<PathBuf> {
    let real = std::fs::canonicalize(node).ok();
    [Some(node.to_path_buf()), real]
        .into_iter()
        .flatten()
        .filter_map(|node| Some(node.parent()?.parent()?.to_path_buf()))
        .map(|prefix| prefix.join("lib/node_modules/npm/bin/npm-cli.js"))
        .find(|script| script.is_file())
}

fn find_cli(lookup: &Lookup<'_>) -> Cli {
    if lookup.inherited_cli {
        return Cli::Inherited;
    }
    let mut dirs = absolute_dirs(lookup.search_path);
    if let Some(home) = lookup.home {
        dirs.extend(CLI_HOME_DIRS.iter().map(|dir| home.join(dir)));
    }
    dirs.extend(lookup.system_dirs(SYSTEM_BINS).iter().map(PathBuf::from));
    dirs.into_iter()
        .map(|dir| dir.join("claude"))
        .find(|cli| is_executable(cli))
        .map_or(Cli::Missing, Cli::Found)
}

/// Look at what this computer has (runs bounded `node --version` probes on
/// candidates; must run inside a Tokio runtime).
pub async fn detect(lookup: &Lookup<'_>) -> Environment {
    detect_with(lookup, node_version).await
}

/// [`detect`] with the Node.js probe supplied.
pub async fn detect_with(
    lookup: &Lookup<'_>,
    mut probe: impl AsyncFnMut(&Path) -> Option<Version>,
) -> Environment {
    let adapter = find_adapter(lookup);
    let found = find_node(lookup, adapter.as_ref(), &mut probe).await;
    Environment {
        adapter,
        node: found.node,
        too_old: found.too_old,
        npm: found.npm,
        cli: find_cli(lookup),
    }
}

fn version_text(version: Version) -> String {
    format!("{}.{}.{}", version.0, version.1, version.2)
}

impl Environment {
    /// The launch for a spec with `args`, or why it cannot start.
    pub fn launch(&self, args: &[String]) -> Result<Launch, Missing> {
        let adapter = self.adapter.as_ref().ok_or(Missing::Adapter)?;
        let env = match &self.cli {
            Cli::Found(path) => vec![(OsString::from(CLI_ENV), path.clone().into_os_string())],
            Cli::Inherited | Cli::Missing => Vec::new(),
        };
        // An adapter that is not the package's own script (a shim or a
        // wrapper) chooses its runtime itself.
        let script = adapter
            .entry
            .as_ref()
            .and_then(|entry| entry.to_str().map(str::to_string));
        let Some(script) = script else {
            return Ok(Launch {
                program: adapter.bin.clone(),
                args: args.to_vec(),
                env,
                source: adapter.bin.clone(),
            });
        };
        let node = self.node.as_ref().ok_or_else(|| {
            Missing::Runtime(match self.too_old {
                Some(old) => format!("the newest one found is {}", version_text(old)),
                None => "none was found".to_string(),
            })
        })?;
        let mut launched = Vec::with_capacity(args.len() + 1);
        launched.push(script);
        launched.extend_from_slice(args);
        Ok(Launch {
            program: node.path.clone(),
            args: launched,
            env,
            source: adapter.bin.clone(),
        })
    }

    /// Whether preparing the pinned adapter could help and can run.
    pub fn can_prepare(&self) -> bool {
        self.adapter.is_none() && self.npm.is_some()
    }

    /// A display summary (paths and versions only).
    pub fn status(&self) -> Status {
        let launch = self.launch(&[]);
        let needs_node = self.adapter.as_ref().is_none_or(|a| a.entry.is_some());
        Status {
            ready: launch.is_ok(),
            adapter: match self.adapter.as_ref().map(|a| a.source) {
                Some(AdapterSource::Installed) => "installed",
                Some(AdapterSource::Prepared) => "prepared",
                None => "missing",
            },
            adapter_path: self.adapter.as_ref().map(|a| a.bin.display().to_string()),
            runtime: match (&self.node, self.too_old) {
                (Some(_), _) => "found",
                (None, _) if !needs_node => "notNeeded",
                (None, Some(_)) => "tooOld",
                (None, None) => "missing",
            },
            runtime_version: self
                .node
                .as_ref()
                .map(|n| n.version)
                .or(self.too_old)
                .map(version_text),
            runtime_path: self.node.as_ref().map(|n| n.path.display().to_string()),
            cli: match &self.cli {
                Cli::Inherited => "inherited",
                Cli::Found(_) => "found",
                Cli::Missing => "missing",
            },
            cli_path: match &self.cli {
                Cli::Found(path) => Some(path.display().to_string()),
                Cli::Inherited | Cli::Missing => None,
            },
            can_prepare: self.can_prepare(),
            problem: launch.err().map(|missing| missing.to_string()),
        }
    }
}

/// [`Environment::status`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    /// The preset can start now.
    pub ready: bool,
    /// `installed` / `prepared` / `missing`.
    pub adapter: &'static str,
    /// The adapter executable.
    pub adapter_path: Option<String>,
    /// `found` / `tooOld` / `missing` / `notNeeded` (a wrapper adapter).
    pub runtime: &'static str,
    /// The runtime's version (or the newest too-old one).
    pub runtime_version: Option<String>,
    /// The runtime executable.
    pub runtime_path: Option<String>,
    /// `inherited` / `found` / `missing` (the SDK's bundled CLI is used).
    pub cli: &'static str,
    /// The native CLI passed to the adapter.
    pub cli_path: Option<String>,
    /// Preparing the pinned adapter is possible and needed.
    pub can_prepare: bool,
    /// Why it cannot start, when it cannot.
    pub problem: Option<String>,
}

#[cfg(all(test, unix))]
#[path = "claude_tests.rs"]
mod tests;
