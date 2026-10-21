//! Which processes hold a listening socket that connections to a local TCP
//! endpoint reach, as the platform reports it — the evidence that a server
//! answering there is the process a launch started, not merely one whose
//! arguments match.
//!
//! Only listeners that apply to the requested address count: the same
//! address, the unspecified (wildcard) address of its family, any listener
//! of the family when the request itself is unspecified, and the IPv6
//! wildcard for an IPv4 request (whether that socket is dual-stack is not
//! visible, so it counts). A listener of another address or family that only
//! shares the port number is ignored.
//!
//! Scoped (link-local) endpoints are not attributed: a zone is named
//! differently by each source (an interface name, an index, or not at all in
//! `/proc`), so a listener on another interface could not be told apart. A
//! listed address with a zone that equals a requested address makes the
//! answer "cannot be told"; since requests are never scoped, an unrelated
//! scoped listener never affects an ordinary endpoint.
//!
//! - **Linux**: `/proc/net/tcp` and `/proc/net/tcp6` name each listening
//!   socket's address and inode; an inode is attributed only to a process of
//!   `tree` whose `/proc/<pid>/fd` holds it. One no process of `tree` holds is
//!   counted as someone else's, whoever that is.
//! - **Other Unix (macOS)**: `lsof -nP -w -iTCP:<port> -sTCP:LISTEN -Fftn`, the
//!   tool the session-liveness checks already use. It lists the holders this
//!   user may inspect: another user's listener can stay invisible.
//! - **Windows**: `netstat -ano -p TCP` and `-p TCPv6`, rows whose remote
//!   address ends in `:0` (the state column is localized, so it is not read).
//!
//! The tools run bounded in time and output (the `probe` module): one check
//! takes at most 3 s plus 0.5 s of cleanup per tool run, so 3.5 s with `lsof`
//! and 4 s with Windows' two `netstat` runs, which share the 3 s. A source
//! that fails, times out, prints too much, is cut off inside a record, or
//! lists an applicable socket that cannot be read makes the answer "cannot be
//! told" (`None`), never an empty listing.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
#[cfg(not(target_os = "linux"))]
use std::time::{Duration, Instant};

#[cfg(any(not(target_os = "linux"), test))]
mod probe;

/// How long the listing tools of one check may run before they are stopped
/// (and the answer cannot be told); each run's cleanup may add 0.5 s more.
#[cfg(not(target_os = "linux"))]
const PROBE_BUDGET: Duration = Duration::from_secs(3);

/// Most bytes read from each of a listing tool's output streams.
#[cfg(not(target_os = "linux"))]
const PROBE_CAP: usize = 4 << 20;

/// The holders of the listening sockets that apply to an endpoint.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Listening {
    /// Process ids holding one of them, sorted and without duplicates.
    pub pids: Vec<u32>,
    /// A listening socket no process of the tree was seen to hold (Linux).
    pub unattributed: bool,
}

impl Listening {
    /// Nothing listens there.
    pub fn is_empty(&self) -> bool {
        self.pids.is_empty() && !self.unattributed
    }
}

/// The addresses connections to the listen host `host` reach: an IP literal
/// (IPv6 with or without brackets) or `localhost` (both loopbacks). `None`
/// for any other name, whose address is not known here, and for a scoped
/// address (a `%zone` suffix, or IPv6 link-local without one), whose
/// interface cannot be matched against the listings.
pub fn requested(host: &str) -> Option<Vec<IpAddr>> {
    if host.eq_ignore_ascii_case("localhost") {
        return Some(vec![Ipv4Addr::LOCALHOST.into(), Ipv6Addr::LOCALHOST.into()]);
    }
    match listed(host)? {
        (_, Some(_)) => None,
        (IpAddr::V6(ip), None) if ip.is_unicast_link_local() => None,
        (ip, None) => Some(vec![ip]),
    }
}

/// The holders of the listening sockets on `port` that apply to one of the
/// `requested` addresses, with `tree` the processes a caller would accept as
/// its own (Linux maps sockets to those only). `None` when that cannot be
/// told: the platform's source failed, was cut off, or lists an applicable
/// socket it does not describe completely.
pub fn holders(requested: &[IpAddr], port: u16, tree: &[u32]) -> Option<Listening> {
    let mut listening = platform(requested, port, tree)?;
    listening.pids.sort_unstable();
    listening.pids.dedup();
    Some(listening)
}

/// An IP literal as URLs and listings print it, brackets removed, and its
/// zone (`%<zone>` suffix) if any.
fn listed(text: &str) -> Option<(IpAddr, Option<&str>)> {
    let text = text
        .strip_prefix('[')
        .and_then(|inner| inner.strip_suffix(']'))
        .unwrap_or(text);
    let (ip, zone) = match text.split_once('%') {
        Some((ip, zone)) => (ip, Some(zone)),
        None => (text, None),
    };
    Some((ip.parse().ok()?, zone))
}

/// Whether a listing's address `text` applies to `requested`; `None` when it
/// cannot be read, or it is scoped and names a requested address (the
/// interface cannot be compared). A scoped address applies to a wildcard
/// request whatever its zone.
#[cfg(any(not(target_os = "linux"), test))]
fn listed_applies(text: &str, requested: &[IpAddr]) -> Option<bool> {
    let (ip, zone) = listed(text)?;
    let named = || {
        requested
            .iter()
            .any(|r| r.to_canonical() == ip.to_canonical())
    };
    if zone.is_some() && named() {
        return None;
    }
    Some(applies(ip, requested))
}

/// Whether a listener bound to `bound` takes connections to one of
/// `requested` (see the module documentation).
fn applies(bound: IpAddr, requested: &[IpAddr]) -> bool {
    let bound = bound.to_canonical();
    requested
        .iter()
        .any(|requested| match (bound, requested.to_canonical()) {
            (IpAddr::V4(b), IpAddr::V4(r)) => b == r || b.is_unspecified() || r.is_unspecified(),
            (IpAddr::V6(b), IpAddr::V6(r)) => b == r || b.is_unspecified() || r.is_unspecified(),
            (IpAddr::V6(b), IpAddr::V4(_)) => b.is_unspecified(),
            (IpAddr::V4(_), IpAddr::V6(_)) => false,
        })
}

#[cfg(target_os = "linux")]
fn platform(requested: &[IpAddr], port: u16, tree: &[u32]) -> Option<Listening> {
    let mut inodes = Vec::new();
    for (table, v6) in [("/proc/net/tcp", false), ("/proc/net/tcp6", true)] {
        match std::fs::read_to_string(table) {
            Ok(text) => inodes.extend(listening_inodes(&text, requested, port)?),
            // A kernel without IPv6 has no IPv6 listener.
            Err(e) if v6 && e.kind() == std::io::ErrorKind::NotFound => {},
            Err(_) => return None,
        }
    }
    let mut listening = Listening::default();
    for inode in inodes {
        let link = format!("socket:[{inode}]");
        let mut held = false;
        for pid in tree {
            if holds(*pid, &link)? {
                listening.pids.push(*pid);
                held = true;
            }
        }
        listening.unattributed |= !held;
    }
    Some(listening)
}

/// Whether process `pid` has `link` (`socket:[<inode>]`) open; `None` when
/// its descriptors cannot be read (one that exited holds nothing).
#[cfg(target_os = "linux")]
fn holds(pid: u32, link: &str) -> Option<bool> {
    let fds = match std::fs::read_dir(format!("/proc/{pid}/fd")) {
        Ok(fds) => fds,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Some(false),
        Err(_) => return None,
    };
    Some(
        fds.flatten()
            .any(|fd| std::fs::read_link(fd.path()).is_ok_and(|target| target.as_os_str() == link)),
    )
}

/// The inodes of `/proc/net/tcp{,6}` rows listening (`0A`) on `port` at an
/// address that applies to `requested`; `None` when a row cannot be read.
/// An inode of 0 is kept: no process can be shown to hold that socket.
#[cfg(any(target_os = "linux", test))]
fn listening_inodes(table: &str, requested: &[IpAddr], port: u16) -> Option<Vec<u64>> {
    let mut inodes = Vec::new();
    for row in table.lines().skip(1).filter(|row| !row.trim().is_empty()) {
        let fields: Vec<&str> = row.split_whitespace().collect();
        if fields.len() < 10 {
            return None;
        }
        if fields[3] != "0A" {
            continue;
        }
        let (hex, hex_port) = fields[1].split_once(':')?;
        if u16::from_str_radix(hex_port, 16).ok()? != port {
            continue;
        }
        if applies(proc_address(hex)?, requested) {
            inodes.push(fields[9].parse().ok()?);
        }
    }
    Some(inodes)
}

/// A `/proc/net/tcp{,6}` address: 8 or 32 hex digits, each 32-bit word
/// printed in the kernel's native byte order.
#[cfg(any(target_os = "linux", test))]
fn proc_address(hex: &str) -> Option<IpAddr> {
    let word = |i: usize| {
        let digits = hex.get(i * 8..i * 8 + 8)?;
        u32::from_str_radix(digits, 16).ok().map(u32::to_ne_bytes)
    };
    match hex.len() {
        8 => Some(IpAddr::from(word(0)?)),
        32 => {
            let mut bytes = [0u8; 16];
            for (i, chunk) in bytes.chunks_exact_mut(4).enumerate() {
                chunk.copy_from_slice(&word(i)?);
            }
            Some(IpAddr::from(bytes))
        },
        _ => None,
    }
}

#[cfg(all(unix, not(target_os = "linux")))]
fn platform(requested: &[IpAddr], port: u16, _tree: &[u32]) -> Option<Listening> {
    let mut lsof = std::process::Command::new("lsof");
    lsof.args(["-nP", "-w", &format!("-iTCP:{port}"), "-sTCP:LISTEN", "-Fftn"]);
    let run = probe::run(&mut lsof, Instant::now() + PROBE_BUDGET, PROBE_CAP)?;
    Some(Listening {
        pids: lsof_listing(&run, requested, port)?,
        unattributed: false,
    })
}

/// The holders an `lsof -F ftn` run names. Empty only for its documented
/// no-match outcome: exit 1 with nothing printed. Any other exit, output on
/// standard error, or a listing [`lsof_pids`] cannot read is `None`.
#[cfg(any(all(unix, not(target_os = "linux")), test))]
fn lsof_listing(run: &probe::Probed, requested: &[IpAddr], port: u16) -> Option<Vec<u32>> {
    match run.code {
        Some(0) if !run.stdout.is_empty() && run.stderr.is_empty() => {
            lsof_pids(std::str::from_utf8(&run.stdout).ok()?, requested, port)
        },
        Some(1) if run.stdout.is_empty() && run.stderr.is_empty() => Some(Vec::new()),
        _ => None,
    }
}

/// The processes of `lsof -F ftn` records whose socket on `port` applies to
/// `requested`. The listing must be whole: newline-terminated, every `p`
/// record followed by at least one file, and every file (`f`) by exactly one
/// `t` and one `n` field before the next file, process or the end. Anything
/// else is a cut-off or unexpected listing and `None`, as is an applicable
/// file that cannot be read. `*` is the unspecified address of its family.
#[cfg(any(all(unix, not(target_os = "linux")), test))]
fn lsof_pids(output: &str, requested: &[IpAddr], port: u16) -> Option<Vec<u32>> {
    let mut records = LsofRecords::default();
    for line in output.strip_suffix('\n')?.split('\n') {
        let mut chars = line.chars();
        let tag = chars.next()?;
        let value = chars.as_str();
        match tag {
            'p' => {
                records.close_process(requested, port)?;
                records.pid = Some(value.parse().ok()?);
            },
            'f' => {
                records.close_file(requested, port)?;
                // A file belongs to the process named before it.
                records.pid?;
                records.file = Some(LsofFile::default());
            },
            't' => set_once(&mut records.file.as_mut()?.family, value)?,
            'n' => set_once(&mut records.file.as_mut()?.name, value)?,
            _ => {},
        }
    }
    records.close_process(requested, port)?;
    Some(records.pids)
}

/// `lsof -F` parsing state: the current process and file.
#[cfg(any(all(unix, not(target_os = "linux")), test))]
#[derive(Default)]
struct LsofRecords<'a> {
    pid: Option<u32>,
    /// Whether the current process listed a file.
    has_file: bool,
    file: Option<LsofFile<'a>>,
    pids: Vec<u32>,
}

/// One file record's `t` (family) and `n` (address) fields.
#[cfg(any(all(unix, not(target_os = "linux")), test))]
#[derive(Default)]
struct LsofFile<'a> {
    family: Option<&'a str>,
    name: Option<&'a str>,
}

#[cfg(any(all(unix, not(target_os = "linux")), test))]
impl LsofRecords<'_> {
    /// End the current file; `None` when it lacks a field or cannot be read.
    fn close_file(&mut self, requested: &[IpAddr], port: u16) -> Option<()> {
        let Some(file) = self.file.take() else {
            return Some(());
        };
        self.has_file = true;
        let (host, bound_port) = file.name?.rsplit_once(':')?;
        let family = file.family?;
        if bound_port.parse::<u16>().ok()? != port {
            return Some(());
        }
        let applicable = match (host, family) {
            ("*", "IPv4") => applies(Ipv4Addr::UNSPECIFIED.into(), requested),
            ("*", "IPv6") => applies(Ipv6Addr::UNSPECIFIED.into(), requested),
            ("*", _) => return None,
            _ => listed_applies(host, requested)?,
        };
        if applicable {
            self.pids.push(self.pid?);
        }
        Some(())
    }

    /// End the current process; `None` when it listed no file.
    fn close_process(&mut self, requested: &[IpAddr], port: u16) -> Option<()> {
        self.close_file(requested, port)?;
        if self.pid.take().is_some() && !std::mem::take(&mut self.has_file) {
            return None;
        }
        Some(())
    }
}

/// Set a field seen once per record; `None` when it repeats.
#[cfg(any(all(unix, not(target_os = "linux")), test))]
fn set_once<'a>(field: &mut Option<&'a str>, value: &'a str) -> Option<()> {
    field.replace(value).is_none().then_some(())
}

#[cfg(windows)]
fn platform(requested: &[IpAddr], port: u16, _tree: &[u32]) -> Option<Listening> {
    use std::os::windows::process::CommandExt;
    // No console window flashes for this probe.
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let mut listening = Listening::default();
    // Both listings are needed: either family can hold an applicable socket.
    // They share one budget.
    let deadline = Instant::now() + PROBE_BUDGET;
    for proto in ["TCP", "TCPv6"] {
        let mut netstat = std::process::Command::new("netstat");
        netstat
            .args(["-ano", "-p", proto])
            .creation_flags(CREATE_NO_WINDOW);
        let run = probe::run(&mut netstat, deadline, PROBE_CAP)?;
        if run.code != Some(0) || !run.stderr.is_empty() {
            return None;
        }
        let text = String::from_utf8_lossy(&run.stdout);
        listening.pids.extend(netstat_pids(&text, requested, port)?);
    }
    Some(listening)
}

/// The owning pids of `netstat -ano` rows listening on `port` at an address
/// that applies to `requested`; `None` when such a row cannot be read, or a
/// TCP row is cut off before its state and pid. Rows that are not TCP (the
/// title and column headings) are ignored.
#[cfg(any(windows, test))]
fn netstat_pids(output: &str, requested: &[IpAddr], port: u16) -> Option<Vec<u32>> {
    let mut pids = Vec::new();
    for row in output.lines() {
        let fields: Vec<&str> = row.split_whitespace().collect();
        if !fields
            .first()
            .is_some_and(|proto| proto.eq_ignore_ascii_case("tcp"))
        {
            continue;
        }
        // Proto, local and remote address, state (localized), pid.
        let [_, local, remote, _, .., pid] = fields.as_slice() else {
            return None;
        };
        if !remote.ends_with(":0") {
            continue;
        }
        let (host, bound_port) = local.rsplit_once(':')?;
        if bound_port.parse::<u16>().ok()? != port {
            continue;
        }
        if listed_applies(host, requested)? {
            pids.push(pid.parse().ok()?);
        }
    }
    Some(pids)
}

#[cfg(test)]
mod tests;
