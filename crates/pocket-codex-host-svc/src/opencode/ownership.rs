//! Native database handles, and the clients of an attached background
//! server, are evidence of possible writers, not session leases.

use std::{
    collections::BTreeSet,
    net::SocketAddr,
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
    /// What the process is to this source.
    pub role: Role,
}

/// How an outside process may write this source.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// It has the database open: another engine.
    Database,
    /// OpenCode 2's background server (`opencode serve --service`) has it
    /// open, beside a server of this host's own.
    BackgroundServer,
    /// It is connected to the attached background server. That server says
    /// which sessions run, not which sessions a client shows.
    Client,
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
    service: Option<SocketAddr>,
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
            service: None,
        })
    }

    /// The server is OpenCode 2's background server, listening on `address`,
    /// not one this host owns: only that process counts as this host's
    /// holder, and every other process connected to it is a possible writer.
    pub fn attached(mut self, address: SocketAddr) -> Self {
        self.service = Some(address);
        self
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
        let (root, started, exact) = (self.pid, self.started, self.service.is_some());
        let mut evidence =
            tokio::task::spawn_blocking(move || classify(&pids, root, started, exact))
                .await
                .unwrap_or(Evidence::Unknown);
        if let (Evidence::Clear, Some(address)) = (&evidence, self.service) {
            evidence = clients(program, address, root, started).await;
        }
        if identity(&self.path).as_deref() != Some(&self.identity) {
            return Evidence::Unknown;
        }
        evidence
    }
}

/// Whether `pid` has this exact database open.
pub(crate) async fn holds(path: &Path, pid: u32) -> bool {
    let Some(program) = inspector() else { return false };
    let args = vec!["-nP".into(), "-Fpc".into(), "--".into(), path.to_string_lossy().into_owned()];
    process::read_output(program, &args, None, &[], Duration::from_secs(5), 64 * 1024)
        .await
        .and_then(|output| parse_holders(&output))
        .is_some_and(|pids| pids.contains(&pid))
}

/// Processes connected to the attached server at `address`, other than this
/// one. The server's own listening socket must be seen; a connection whose
/// other end this user cannot see (another user's process, another computer)
/// or that the server opened to itself (its remote-access tunnel) is unknown.
async fn clients(program: &Path, address: SocketAddr, root: u32, started: u64) -> Evidence {
    let args = vec![
        "-nP".into(),
        format!("-iTCP:{}", address.port()),
        "-sTCP:LISTEN,ESTABLISHED".into(),
        "-Fpn".into(),
    ];
    let Some(output) =
        process::read_output(program, &args, None, &[], Duration::from_secs(5), 256 * 1024).await
    else {
        return Evidence::Unknown;
    };
    let Some(sockets) = parse_sockets(&output) else { return Evidence::Unknown };
    tokio::task::spawn_blocking(move || {
        if process_start_time(root) != Some(started) {
            return Evidence::Unknown;
        }
        let Some(pids) = connected(&sockets, address, root, std::process::id()) else {
            return Evidence::Unknown;
        };
        let mut holders = Vec::new();
        for pid in pids {
            let Some(identity) = process_identity(pid) else { return Evidence::Unknown };
            holders.push(Holder {
                pid,
                started_at: identity.started.saturating_mul(1000),
                role: Role::Client,
            });
        }
        if holders.is_empty() {
            Evidence::Clear
        } else {
            Evidence::External(holders)
        }
    })
    .await
    .unwrap_or(Evidence::Unknown)
}

struct Socket {
    pid: u32,
    local: SocketAddr,
    remote: Option<SocketAddr>,
}

fn parse_sockets(output: &[u8]) -> Option<Vec<Socket>> {
    let mut sockets = Vec::new();
    let mut pid = None;
    for line in std::str::from_utf8(output).ok()?.lines() {
        if let Some(value) = line.strip_prefix('p') {
            pid = Some(value.parse::<u32>().ok().filter(|pid| *pid != 0)?);
        } else if let Some(name) = line.strip_prefix('n') {
            let (local, remote) = match name.split_once("->") {
                Some((local, remote)) => (local, Some(remote.parse().ok()?)),
                None => (name, None),
            };
            sockets.push(Socket {
                pid: pid?,
                local: local.parse().ok()?,
                remote,
            });
            if sockets.len() > 1024 {
                return None;
            }
        } else if !line.starts_with('f') || pid.is_none() {
            return None;
        }
    }
    Some(sockets)
}

/// The client processes connected to `address`, or `None` when a connection
/// cannot be attributed.
fn connected(
    sockets: &[Socket],
    address: SocketAddr,
    root: u32,
    own: u32,
) -> Option<BTreeSet<u32>> {
    let mut listening = false;
    let mut clients = BTreeSet::new();
    for socket in sockets {
        match socket.remote {
            None => listening |= socket.pid == root && socket.local == address,
            Some(peer) if socket.pid == root => {
                // Accepted by the server: its other end must be a visible
                // client socket, not one of the server's own.
                let client = sockets
                    .iter()
                    .find(|c| c.local == peer && c.remote == Some(address))?;
                if socket.local != address || client.pid == root {
                    return None;
                }
            },
            Some(peer) if peer == address && socket.pid != own => {
                clients.insert(socket.pid);
            },
            Some(_) => {},
        }
    }
    listening.then_some(clients)
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

/// `exact`: only `root` itself is this host's, not its descendants (the
/// attached background server's terminals can run other OpenCode servers).
fn classify(pids: &BTreeSet<u32>, root: u32, started: u64, exact: bool) -> Evidence {
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
        let ours = if exact {
            pid == root
        } else {
            is_process_descendant(pid, identity.started, root, started)
        };
        if ours {
            owned = true;
        } else {
            let service = process_arguments(pid).is_some_and(|args| background_server(&args));
            external.push(Holder {
                pid,
                started_at: identity.started.saturating_mul(1000),
                role: if service { Role::BackgroundServer } else { Role::Database },
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
    fn only_this_process_may_be_connected_to_an_attached_server() {
        let service: SocketAddr = "127.0.0.1:49374".parse().expect("address");
        let inventory = |extra: &str| {
            let text = format!(
                "p10\nf7\nn127.0.0.1:49374\nf11\nn127.0.0.1:49374->127.0.0.1:50001\np20\nf8\nn127.\
                 0.0.1:50001->127.0.0.1:49374\n{extra}"
            );
            parse_sockets(text.as_bytes()).expect("lsof fields")
        };
        // Only this process (20) holds a connection.
        assert_eq!(connected(&inventory(""), service, 10, 20), Some(BTreeSet::new()));
        // A TUI (30) holds its event stream.
        let tui =
            "f12\nn127.0.0.1:49374->127.0.0.1:50002\np30\nf8\nn127.0.0.1:50002->127.0.0.1:49374\n";
        let tui = inventory(&format!("p10\n{tui}"));
        assert_eq!(connected(&tui, service, 10, 20), Some(BTreeSet::from([30])));
        // A peer this user cannot see, or the server's own tunnel, is unknown.
        let hidden = inventory("p10\nf12\nn127.0.0.1:49374->127.0.0.1:50003\n");
        assert_eq!(connected(&hidden, service, 10, 20), None);
        let tunnel =
            "f12\nn127.0.0.1:49374->127.0.0.1:50004\nf13\nn127.0.0.1:50004->127.0.0.1:49374\n";
        assert_eq!(connected(&inventory(&format!("p10\n{tunnel}")), service, 10, 20), None);
        // No listening socket of the server: not the attached server.
        assert_eq!(connected(&tui[1..], service, 10, 20), None);
        assert!(parse_sockets(b"p10\nf7\nn*:49374\n").is_none());
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
