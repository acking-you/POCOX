//! Native database handles are evidence of possible writers, not session
//! leases.

use std::{
    collections::BTreeSet,
    path::{Path, PathBuf},
    time::Duration,
};

use anyhow::{ensure, Context, Result};
use pocket_codex_core::process::{
    is_process_descendant, process_arguments, process_identity, process_start_time,
};

use crate::process;

/// A positive outside holder of this exact native database.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Holder {
    /// Verified live operating-system process id.
    pub pid: u32,
    /// Creation time in Unix milliseconds.
    pub started_at: u64,
    /// OpenCode 2's background server (`opencode serve --service`), which its
    /// own clients start and leave running. It changes only the explanation.
    pub background_server: bool,
}

/// Fresh source admission. Neither an unfinished message nor quiet history
/// can turn a possible external writer into an idle/released session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Evidence {
    /// The owned server has the source open and no outside handle was observed.
    Clear,
    /// Other verified processes also hold the same native source. Their exact
    /// session and turn state are not available from OpenCode's database.
    External(Vec<Holder>),
    /// Missing, replaced, inaccessible, or ambiguous ownership evidence.
    Unknown,
}

/// Source identity captured after native readiness. Inspections never read
/// process environments, signal holders, or open the database for writing.
pub struct Source {
    path: PathBuf,
    identity: String,
    pid: u32,
    started: u64,
}

impl Source {
    /// Capture the canonical source used by the owned native server.
    pub fn new(path: PathBuf, pid: u32, started: u64) -> Result<Self> {
        let path = path
            .canonicalize()
            .context("OpenCode source is unavailable")?;
        let identity = identity(&path).context("OpenCode source identity is unavailable")?;
        Ok(Self {
            path,
            identity,
            pid,
            started,
        })
    }

    /// Opaque database identity used to invalidate controller
    /// history/admission.
    pub fn generation(&self) -> &str {
        &self.identity
    }

    /// Inspect the exact database afresh. A missing inspector never implies
    /// an empty owner list. Only this Pocket process's read-only native history
    /// handles and the owned server tree are excluded from external holders.
    pub async fn inspect(&self) -> Evidence {
        let Some(program) = inspector() else { return Evidence::Unknown };
        if identity(&self.path).as_deref() != Some(&self.identity) {
            return Evidence::Unknown;
        }
        let args = vec![
            "-nP".into(),
            "-Fpc".into(),
            "--".into(),
            self.path.to_string_lossy().into_owned(),
        ];
        let Some(output) =
            process::read_output(program, &args, None, &[], Duration::from_secs(5), 64 * 1024)
                .await
        else {
            return Evidence::Unknown;
        };
        let Some(pids) = parse_holders(&output) else { return Evidence::Unknown };
        let root = self.pid;
        let started = self.started;
        let evidence = tokio::task::spawn_blocking(move || classify(&pids, root, started))
            .await
            .unwrap_or(Evidence::Unknown);
        if identity(&self.path).as_deref() != Some(&self.identity) {
            return Evidence::Unknown;
        }
        evidence
    }
}

fn inspector() -> Option<&'static Path> {
    ["/usr/sbin/lsof", "/usr/bin/lsof", "/bin/lsof"]
        .into_iter()
        .map(Path::new)
        .find(|path| path.is_file())
}

fn identity(path: &Path) -> Option<String> {
    let metadata = path.metadata().ok()?;
    if !metadata.is_file() {
        return None;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Some(pocket_codex_core::history_sync::digest_bytes(
            format!("{}:{}:{}", path.display(), metadata.dev(), metadata.ino()).as_bytes(),
        ))
    }
    #[cfg(not(unix))]
    {
        let _ = metadata;
        None
    }
}

fn parse_holders(output: &[u8]) -> Option<BTreeSet<u32>> {
    let mut pids = BTreeSet::new();
    let mut current = None;
    let mut has_file = false;
    for line in std::str::from_utf8(output).ok()?.lines() {
        if let Some(pid) = line.strip_prefix('p') {
            if current.is_some() && !has_file {
                return None;
            }
            let pid = pid.parse::<u32>().ok()?;
            if pid == 0 || !pids.insert(pid) || pids.len() > 64 {
                return None;
            }
            current = Some(pid);
            has_file = false;
        } else if let Some(fd) = line.strip_prefix('f') {
            // lsof always emits file descriptors, even with -Fpc. A process
            // without a matching file is not positive source evidence.
            if current.is_none() || fd.is_empty() {
                return None;
            }
            has_file = true;
        } else if !line.starts_with('c') || current.is_none() {
            return None;
        }
    }
    (!pids.is_empty() && has_file).then_some(pids)
}

fn classify(pids: &BTreeSet<u32>, root: u32, started: u64) -> Evidence {
    if process_start_time(root) != Some(started) {
        return Evidence::Unknown;
    }
    let mut owned = false;
    let mut external = Vec::new();
    for &pid in pids {
        if pid == std::process::id() {
            continue;
        }
        let Some(identity) = process_identity(pid) else { return Evidence::Unknown };
        if is_process_descendant(pid, identity.started, root, started) {
            owned = true;
        } else {
            external.push(Holder {
                pid,
                started_at: identity.started.saturating_mul(1000),
                background_server: process_arguments(pid)
                    .is_some_and(|args| background_server(&args)),
            });
        }
    }
    if !owned {
        Evidence::Unknown
    } else if external.is_empty() {
        Evidence::Clear
    } else {
        Evidence::External(external)
    }
}

fn background_server(args: &[std::ffi::OsString]) -> bool {
    args.windows(2)
        .skip(1)
        .any(|pair| pair[0] == "serve" && pair[1] == "--service")
}

/// Require an unchanged source before restoring previously retained windows.
pub fn validate_generation(actual: &str, expected: &str) -> Result<()> {
    ensure!(actual == expected, "OpenCode history source changed; reload this session");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn malformed_or_empty_process_inventory_never_grants_admission() {
        for text in ["", "p0\ncfoo\n", "p42\ncfoo\np42\n", "p42\nunknown\n", "pbad\n"] {
            assert!(parse_holders(text.as_bytes()).is_none(), "{text:?}");
        }
        assert_eq!(
            parse_holders(b"p42\ncopencode\nf8\nf13\np75\ncnode\nf10\n"),
            Some(BTreeSet::from([42, 75]))
        );
    }

    #[test]
    fn a_replaced_database_invalidates_old_admission() {
        let dir = tempfile::tempdir().expect("temp dir");
        let path = dir.path().join("opencode.db");
        std::fs::write(&path, b"old").expect("file");
        let old = identity(&path).expect("identity");
        let next = dir.path().join("next.db");
        std::fs::write(&next, b"new").expect("replacement");
        std::fs::rename(next, &path).expect("replace");
        assert!(validate_generation(&identity(&path).expect("new identity"), &old).is_err());
    }
}
