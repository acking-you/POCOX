use super::*;

fn ips(list: &[&str]) -> Vec<IpAddr> {
    list.iter()
        .map(|ip| ip.parse().expect("an IP address"))
        .collect()
}

const HEADER: &str =
    "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout \
     inode\n";

/// A `/proc/net/tcp{,6}` table of `(local address, state, inode)` rows.
fn proc_table(rows: &[(&str, &str, u64)]) -> String {
    let mut table = HEADER.to_string();
    for (n, (local, state, inode)) in rows.iter().enumerate() {
        table.push_str(&format!(
            "{n:>4}: {local} 00000000:0000 {state} 00000000:00000000 00:00000000 00000000  \
             1000        0 {inode} 1\n"
        ));
    }
    table
}

#[test]
fn listen_hosts_name_their_addresses() {
    assert_eq!(requested("127.0.0.1"), Some(ips(&["127.0.0.1"])));
    assert_eq!(requested("[::1]"), Some(ips(&["::1"])));
    assert_eq!(requested("LocalHost"), Some(ips(&["127.0.0.1", "::1"])));
    assert_eq!(requested("codex.example"), None, "a name is not resolved here");
    // A scope cannot be matched against the listings, so a scoped host or a
    // link-local one without its zone cannot be told.
    for scoped in ["fe80::1%en0", "[fe80::1%en1]", "fe80::1%5", "[fe80::1]", "fe80::1", "::1%lo0"] {
        assert_eq!(requested(scoped), None, "{scoped}");
    }
    assert_eq!(requested(""), None);
}

/// Distinct loopback addresses and the two families are apart even on one
/// port number; wildcards apply as the module documents. Fixtures are in
/// little-endian word order.
#[cfg(target_endian = "little")]
#[test]
fn proc_net_rows_apply_by_address_family_state_and_port() {
    let v4 = proc_table(&[
        ("0100007F:4E20", "0A", 100),
        ("0200007F:4E20", "0A", 200),
        ("0100007F:4E20", "01", 300),
        ("00000000:1F90", "0A", 400),
        ("0300007F:4E20", "0A", 0),
    ]);
    let at =
        |table: &str, ip: &str, port| listening_inodes(table, &ips(&[ip]), port).expect("readable");
    assert_eq!(at(&v4, "127.0.0.1", 0x4E20), [100], "another loopback address is apart");
    assert_eq!(at(&v4, "127.0.0.2", 0x4E20), [200]);
    assert_eq!(at(&v4, "0.0.0.0", 0x4E20), [100, 200, 0], "a wildcard request reaches all");
    assert_eq!(at(&v4, "127.0.0.3", 0x4E20), [0], "a socket no one can be shown to hold");
    assert_eq!(at(&v4, "127.0.0.9", 0x1F90), [400], "the IPv4 wildcard takes every address");
    assert!(at(&v4, "::1", 0x4E20).is_empty(), "IPv4 listeners never take IPv6");
    assert!(at(&v4, "127.0.0.1", 1).is_empty());

    let v6 = proc_table(&[
        ("00000000000000000000000001000000:4E20", "0A", 600),
        ("00000000000000000000000000000000:1F90", "0A", 700),
        ("0000000000000000FFFF00000100007F:4E21", "0A", 800),
    ]);
    assert_eq!(at(&v6, "::1", 0x4E20), [600]);
    assert!(at(&v6, "127.0.0.1", 0x4E20).is_empty(), "a specific IPv6 listener");
    assert_eq!(at(&v6, "127.0.0.1", 0x1F90), [700], "the IPv6 wildcard may be dual-stack");
    assert_eq!(at(&v6, "::1", 0x1F90), [700]);
    assert_eq!(at(&v6, "127.0.0.1", 0x4E21), [800], "an IPv4-mapped listener is IPv4");
    assert!(at(&v6, "::1", 0x4E21).is_empty());
    assert_eq!(at(&v6, "::", 0x4E20), [600]);
    let both = [v4.as_str(), &v6[HEADER.len()..]].concat();
    let localhost = requested("localhost").expect("both loopbacks");
    assert_eq!(listening_inodes(&both, &localhost, 0x4E20), Some(vec![100, 600]));
}

#[test]
fn unreadable_proc_rows_cannot_be_told() {
    let ours = ips(&["127.0.0.1"]);
    assert_eq!(listening_inodes(HEADER, &ours, 0x4E20), Some(vec![]), "nothing listens");
    let short = format!("{HEADER}   0: 0100007F:4E20 00000000:0000 0A\n");
    assert_eq!(listening_inodes(&short, &ours, 0x4E20), None);
    for local in ["0100007:4E20", "0100007F:ZZZZ", "0100007G:4E20", "0100007F"] {
        let table = proc_table(&[(local, "0A", 1)]);
        assert_eq!(listening_inodes(&table, &ours, 0x4E20), None, "{local}");
    }
    let inode = proc_table(&[("0100007F:4E20", "0A", 1)]).replace(" 1 1\n", " x 1\n");
    assert_eq!(listening_inodes(&inode, &ours, 0x4E20), None);
}

/// `lsof -F ftn` records, one field per line.
const LSOF: &[&str] = &[
    "p10",
    "f5",
    "tIPv4",
    "n127.0.0.1:18080",
    "p20",
    "f6",
    "tIPv4",
    "n127.0.0.2:18080",
    "p30",
    "f7",
    "tIPv6",
    "n[::1]:18080",
    "p40",
    "f8",
    "tIPv6",
    "n*:18080",
    "p50",
    "f9",
    "tIPv4",
    "n*:18080",
];

/// `lines` as lsof prints them, each ending in a newline.
fn lsof(lines: &[&str]) -> String {
    lines.iter().map(|line| format!("{line}\n")).collect()
}

#[test]
fn lsof_records_apply_by_address_and_family() {
    let listing = lsof(LSOF);
    let at = |ip: &str| lsof_pids(&listing, &ips(&[ip]), 18080).expect("readable");
    assert_eq!(at("127.0.0.1"), [10, 40, 50], "not 127.0.0.2's or [::1]'s holder");
    assert_eq!(at("127.0.0.2"), [20, 40, 50]);
    assert_eq!(at("::1"), [30, 40], "not the IPv4 wildcard's holder");
    assert_eq!(at("0.0.0.0"), [10, 20, 40, 50]);
    assert_eq!(at("::"), [30, 40]);
    let other_port = lsof(&["p7", "f3", "tIPv4", "n127.0.0.1:18081"]);
    assert_eq!(lsof_pids(&other_port, &ips(&["127.0.0.1"]), 18080), Some(vec![]));
    // Several files of one process, and unknown fields, are read.
    let two =
        lsof(&["p7", "f3", "tIPv4", "n127.0.0.2:18080", "f4", "tIPv6", "n[::1]:18080", "Lme"]);
    assert_eq!(lsof_pids(&two, &ips(&["::1"]), 18080), Some(vec![7]));
    for bad in [
        lsof(&["p7", "f3", "tIPv4", "n127.0.0.x:18080"]),
        lsof(&["p7", "f3", "tIPv4", "n127.0.0.1"]),
        lsof(&["pX", "f3", "tIPv4", "n127.0.0.1:18080"]),
        lsof(&["p7", "f3", "tunix", "n*:18080"]),
    ] {
        assert_eq!(lsof_pids(&bad, &ips(&["127.0.0.1"]), 18080), None, "{bad:?}");
    }
}

/// A listing cut off or missing a field inside a record cannot be read,
/// even after a complete record of the owner and whatever the cut record's
/// address would have been.
#[test]
fn partial_lsof_records_cannot_be_told() {
    let owned = ["p10", "f5", "tIPv4", "n127.0.0.1:18080"];
    let ours = ips(&["127.0.0.1"]);
    let partial: &[&[&str]] = &[
        &["p42", "f3", "tIPv4"],
        &["p42", "f3", "n127.0.0.1:18080"],
        &["p42", "f3"],
        &["p42"],
        &["p42", "tIPv4", "n127.0.0.1:18080"],
        &["p42", "f3", "tIPv4", "tIPv4", "n127.0.0.1:18080"],
        &["p42", "f3", "tIPv4", "n127.0.0.1:18080", "n127.0.0.2:18080"],
        &["p42", "f3", "tIPv4", "f4", "tIPv4", "n127.0.0.2:18080"],
        &["p42", "f3", "tIPv4", "n127.0.0.1:18080", ""],
    ];
    for record in partial {
        let listing = lsof(&[&owned[..], record].concat());
        assert_eq!(lsof_pids(&listing, &ours, 18080), None, "{record:?}");
    }
    // A file before any process names no holder, even ahead of a complete
    // record. (After a record it is that process's next file, read below.)
    let orphan = lsof(&[&["f3", "tIPv4", "n127.0.0.1:18080"][..], &owned[..]].concat());
    assert_eq!(lsof_pids(&orphan, &ours, 18080), None);
    let complete = lsof(&owned);
    assert_eq!(lsof_pids(&complete, &ours, 18080), Some(vec![10]));
    // A second complete file of the same process is read as its own.
    let second = lsof(&[&owned[..], &["f3", "tIPv4", "n127.0.0.1:18080"]].concat());
    assert_eq!(lsof_pids(&second, &ours, 18080), Some(vec![10, 10]));
    // Cut off within its last line, without the final newline.
    let cut = complete.strip_suffix('\n').expect("terminated");
    assert_eq!(lsof_pids(cut, &ours, 18080), None);
    assert_eq!(lsof_pids(&complete[..complete.len() - 4], &ours, 18080), None);
    // A complete record of another endpoint is read, and does not count.
    let unrelated = lsof(&[&owned[..], &["p42", "f3", "tIPv6", "n[::1]:18080"]].concat());
    assert_eq!(lsof_pids(&unrelated, &ours, 18080), Some(vec![10]));
}

/// A scoped listener never counts for an ordinary endpoint, applies to a
/// wildcard request, and cannot be told for the address it names.
#[test]
fn scoped_listeners_are_never_attributed_across_interfaces() {
    let scoped = lsof(&["p60", "f3", "tIPv6", "n[fe80::1%en0]:18080"]);
    let at = |listing: &str, ip: &str| lsof_pids(listing, &ips(&[ip]), 18080);
    assert_eq!(at(&scoped, "::1"), Some(vec![]));
    assert_eq!(at(&scoped, "127.0.0.1"), Some(vec![]));
    assert_eq!(at(&scoped, "::"), Some(vec![60]));
    assert_eq!(at(&scoped, "fe80::1"), None, "its interface cannot be compared");
    let localhost = requested("localhost").expect("both loopbacks");
    assert_eq!(lsof_pids(&scoped, &localhost, 18080), Some(vec![]));
    let netstat = "  TCP    [fe80::1%5]:18080      [::]:0      LISTENING       60\n";
    assert_eq!(netstat_pids(netstat, &localhost, 18080), Some(vec![]));
    assert_eq!(netstat_pids(netstat, &ips(&["::"]), 18080), Some(vec![60]));
    assert_eq!(netstat_pids(netstat, &ips(&["fe80::1"]), 18080), None);
}

fn probed(code: Option<i32>, stdout: &str, stderr: &str) -> probe::Probed {
    probe::Probed {
        code,
        stdout: stdout.as_bytes().to_vec(),
        stderr: stderr.as_bytes().to_vec(),
    }
}

/// A listing on success, empty only for the no-match exit, and nothing at
/// all for an error, partial output or a warning.
#[test]
fn lsof_runs_are_read_only_on_their_documented_outcomes() {
    let ours = ips(&["127.0.0.1"]);
    let listing = "p7\nf3\ntIPv4\nn127.0.0.1:18080\n";
    assert_eq!(lsof_listing(&probed(Some(0), listing, ""), &ours, 18080), Some(vec![7]));
    assert_eq!(lsof_listing(&probed(Some(1), "", ""), &ours, 18080), Some(vec![]));
    for (code, out, err) in [
        (Some(1), listing, ""),
        (Some(1), "", "lsof: status error"),
        (Some(0), "", ""),
        (Some(0), listing, "lsof: WARNING"),
        (Some(2), "", ""),
        (None, "", ""),
    ] {
        let run = probed(code, out, err);
        assert_eq!(lsof_listing(&run, &ours, 18080), None, "{code:?} {out:?} {err:?}");
    }
}

/// The same outcomes through a real bounded run, plus the ones only a run
/// has: a tool printing without end, and one that does not finish.
#[cfg(unix)]
#[test]
fn lsof_shaped_runs_are_bounded_and_classified() {
    use std::time::Duration;
    let ours = ips(&["127.0.0.1"]);
    let read = |script: &str, budget: Duration| {
        let mut sh = std::process::Command::new("/bin/sh");
        sh.args(["-c", script]);
        let deadline = std::time::Instant::now() + budget;
        probe::run(&mut sh, deadline, 1024).and_then(|run| lsof_listing(&run, &ours, 18080))
    };
    let roomy = Duration::from_secs(10);
    assert_eq!(read("exit 1", roomy), Some(vec![]), "no match");
    assert_eq!(read("printf 'p7\\nf3\\ntIPv4\\nn127.0.0.1:18080\\n'", roomy), Some(vec![7]));
    assert_eq!(read("echo 'lsof: status error' >&2; exit 1", roomy), None, "error");
    assert_eq!(read("exit 2", roomy), None);
    assert_eq!(read("while :; do echo p7; done", roomy), None, "oversize");
    let started = std::time::Instant::now();
    assert_eq!(read("sleep 30", Duration::from_millis(300)), None, "timeout");
    assert!(started.elapsed() < Duration::from_secs(4), "{:?}", started.elapsed());
}

const NETSTAT: &str = "\nActive Connections\n\n  Proto  Local Address          Foreign Address        \
                       State           PID\n\
    TCP    127.0.0.1:18080        0.0.0.0:0              LISTENING       10\n\
    TCP    127.0.0.2:18080        0.0.0.0:0              LISTENING       20\n\
    TCP    127.0.0.1:18080        127.0.0.1:50000        ESTABLISHED     10\n\
    TCP    [::1]:18080            [::]:0                 ABHÖREN         30\n\
    TCP    0.0.0.0:18080          0.0.0.0:0              LISTENING       50\n\
    TCP    [::]:18080             [::]:0                 LISTENING       40\n\
    TCP    [fe80::1%5]:18080      [::]:0                 LISTENING       60\n\
    TCP    127.0.0.1:18081        0.0.0.0:0              LISTENING       7\n";

#[test]
fn netstat_rows_apply_by_address_and_family() {
    let at = |ip: &str| netstat_pids(NETSTAT, &ips(&[ip]), 18080).expect("readable");
    assert_eq!(at("127.0.0.1"), [10, 50, 40]);
    assert_eq!(at("127.0.0.2"), [20, 50, 40]);
    assert_eq!(at("::1"), [30, 40], "not the scoped listener's holder");
    assert_eq!(at("::"), [30, 40, 60]);
    for bad in [
        "  TCP    127.0.0.1:180800       0.0.0.0:0      LISTENING       7\n",
        "  TCP    127.0.0.x:18080        0.0.0.0:0      LISTENING       7\n",
        "  TCP    127.0.0.1:18080        0.0.0.0:0      LISTENING       x\n",
    ] {
        assert_eq!(netstat_pids(bad, &ips(&["127.0.0.1"]), 18080), None, "{bad:?}");
    }
}

/// A TCP row cut off before its state or pid cannot be read, after a
/// complete row of the owner too; heading rows stay ignored.
#[test]
fn truncated_netstat_rows_cannot_be_told() {
    let owned = "  TCP    127.0.0.1:18080        0.0.0.0:0              LISTENING       10\n";
    let ours = ips(&["127.0.0.1"]);
    assert_eq!(netstat_pids(owned, &ours, 18080), Some(vec![10]));
    for cut in [
        "  TCP    127.0.0.1:18080        0.0.0.0:0              LISTENING\n",
        "  TCP    127.0.0.2:18080        0.0.0.0:0\n",
        "  TCP    127.0.0.1:18080\n",
        "  TCP\n",
    ] {
        assert_eq!(netstat_pids(&format!("{owned}{cut}"), &ours, 18080), None, "{cut:?}");
    }
    let headed = format!(
        "\nActive Connections\n\n  Proto  Local Address  Foreign Address  State  PID\n{owned}"
    );
    assert_eq!(netstat_pids(&headed, &ours, 18080), Some(vec![10]));
}

/// A port this process listens on at 127.0.0.1 is held by it for that
/// address, the IPv4 wildcard and `localhost`, and for no other address or
/// family; once closed, nothing holds it. Real sockets, the platform's own
/// source.
#[test]
fn a_real_listener_is_attributed_only_for_the_addresses_it_takes() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let me = std::process::id();
    // Without its source (lsof, /proc, netstat) callers attribute nothing;
    // every supported platform ships one.
    let at = |host: &str| {
        holders(&requested(host).expect("an address"), port, &[me])
            .expect("the platform's listener source is readable")
    };
    for reaching in ["127.0.0.1", "0.0.0.0", "localhost"] {
        let held = at(reaching);
        assert_eq!(held.pids, [me], "{reaching}");
        assert!(!held.unattributed, "{reaching}");
    }
    for elsewhere in ["127.0.0.2", "::1", "::"] {
        let free = at(elsewhere);
        assert!(free.is_empty(), "{elsewhere}: {free:?}");
    }
    drop(listener);
    let free = at("127.0.0.1");
    assert!(free.is_empty(), "{free:?}");
}
