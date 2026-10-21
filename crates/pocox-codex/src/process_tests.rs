use std::{
    collections::HashMap,
    ffi::{OsStr, OsString},
    path::Path,
};

use super::*;

/// Collect the explicitly-set environment overrides on a `Command`.
/// `get_envs` yields only what we set via `.env(..)`, not the
/// inherited parent environment, so this isolates our injection.
fn explicit_envs(command: &Command) -> HashMap<OsString, Option<OsString>> {
    command
        .get_envs()
        .map(|(k, v)| (k.to_owned(), v.map(ToOwned::to_owned)))
        .collect()
}

#[test]
fn locate_binary_prefers_an_existing_explicit_path() {
    // An explicit path that exists is used verbatim (here, the test binary).
    let exe = std::env::current_exe().expect("current exe");
    assert_eq!(locate_binary(Some(exe.to_str().expect("utf8 path"))), Some(exe.clone()));
    // A missing explicit path resolves to nothing, so the UI can prompt.
    assert_eq!(locate_binary(Some("/definitely/not/here/codex-xyz")), None);
    // A blank override is treated as "not given" → PATH lookup (which may or
    // may not find codex on the test host); assert only that it doesn't panic.
    let _ = locate_binary(Some("   "));
}

#[test]
fn build_command_omits_subcommand_for_bundled_app_server() {
    let args = |bin: &str| -> Vec<String> {
        build_command(Path::new(bin), "ws://127.0.0.1:1", &[], None, None)
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect()
    };
    // External `codex` exposes app-server as a subcommand.
    assert_eq!(args("codex"), ["app-server", "--listen", "ws://127.0.0.1:1"]);
    // The bundled standalone binary IS the app-server — no subcommand.
    assert_eq!(args("codex-app-server"), ["--listen", "ws://127.0.0.1:1"]);
    assert_eq!(args("codex-app-server.exe"), ["--listen", "ws://127.0.0.1:1"]);
}

#[test]
fn child_log_filter_only_silences_spans_when_a_level_is_set() {
    // Unset / blank: codex's own default is already quiet, so touching
    // RUST_LOG would start filtering something nobody asked to filter.
    assert_eq!(child_log_filter(None), None);
    assert_eq!(child_log_filter(Some(OsStr::new("   "))), None);

    // A level IS set: keep it, and append the span silencer. A later
    // directive wins in EnvFilter, so the append is what takes effect.
    assert_eq!(
        child_log_filter(Some(OsStr::new("info"))).as_deref(),
        Some("info,codex_app_server::app_server_tracing=warn"),
        "at info, FmtSpan::FULL writes an enter+exit line PER REQUEST — measured at 45.8 MB for \
         20 thread/list calls"
    );
    // The user's other directives survive; only the span module is muted.
    assert_eq!(
        child_log_filter(Some(OsStr::new("warn,codex_core=debug"))).as_deref(),
        Some("warn,codex_core=debug,codex_app_server::app_server_tracing=warn")
    );
    // Already handled — don't stack a duplicate directive.
    assert_eq!(
        child_log_filter(Some(OsStr::new("info,codex_app_server::app_server_tracing=warn"))),
        None
    );
}

#[test]
fn build_command_applies_the_span_filter_it_computed() {
    let command = build_command(Path::new("codex"), "ws://127.0.0.1:1", &[], None, None);
    let set = explicit_envs(&command)
        .get(&OsString::from("RUST_LOG"))
        .and_then(|v| v.clone());
    // Mirrors the ambient env, so this holds on a clean machine and under a
    // developer's exported RUST_LOG alike.
    match child_log_filter(std::env::var_os("RUST_LOG").as_deref()) {
        Some(expected) => assert_eq!(set, Some(OsString::from(expected))),
        None => assert_eq!(set, None),
    }
}

#[test]
fn oversized_log_is_discarded_leaving_nothing_behind() {
    let dir = tempfile::tempdir().expect("tempdir");
    let log = dir.path().join("codex-default.log");

    // Under the cap: left byte-for-byte, so a tailer's offset stays valid.
    std::fs::write(&log, b"small").expect("write");
    discard_log_if_oversized(&log);
    assert_eq!(std::fs::read(&log).expect("read"), b"small");

    // Over the cap: gone, and NOT rotated to a sibling. Nothing reads bytes
    // from before the current run, so a kept generation would just be a
    // second copy of the disk-space problem.
    std::fs::write(&log, vec![b'x'; (MAX_LOG_BYTES + 1) as usize]).expect("write big");
    discard_log_if_oversized(&log);
    assert!(!log.exists(), "the oversized file is removed");
    assert_eq!(
        std::fs::read_dir(dir.path()).expect("dir").count(),
        0,
        "no .1 (or any other) copy is left holding the bytes"
    );

    // A missing file is a no-op, not an error — the first-ever spawn.
    discard_log_if_oversized(&log);
    assert!(!log.exists());
}

#[test]
fn build_command_injects_proxy_env_when_set() {
    let command = build_command(
        Path::new("codex"),
        "ws://127.0.0.1:18080",
        &[],
        Some("http://127.0.0.1:11111"),
        None,
    );
    let envs = explicit_envs(&command);

    // Look up case-insensitively: Windows env keys are case-insensitive,
    // so the upper/lowercase writes collapse to one entry there, while on
    // unix both survive. Either way each logical var must carry the value.
    let lookup = |name: &str| -> Option<Option<OsString>> {
        envs.iter().find_map(|(k, v)| {
            k.to_str()
                .is_some_and(|k| k.eq_ignore_ascii_case(name))
                .then(|| v.clone())
        })
    };
    for key in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY"] {
        assert_eq!(
            lookup(key),
            Some(Some(OsString::from("http://127.0.0.1:11111"))),
            "expected {key} to carry the proxy value"
        );
    }
}

#[test]
fn build_command_leaves_proxy_env_untouched_without_proxy() {
    let command = build_command(Path::new("codex"), "ws://127.0.0.1:18080", &[], None, None);
    let envs = explicit_envs(&command);

    // No PROXY var is set when none was asked for; the child inherits the
    // parent's. RUST_LOG is deliberately excluded from this claim — it is
    // capped independently of the proxy (see `child_log_filter`), because an
    // unfiltered child grows its log file without bound.
    for key in [
        "HTTPS_PROXY",
        "https_proxy",
        "HTTP_PROXY",
        "http_proxy",
        "ALL_PROXY",
        "all_proxy",
        "NO_PROXY",
        "no_proxy",
    ] {
        assert!(
            !envs.contains_key(&OsString::from(key)),
            "{key} must not be set when proxy is None"
        );
    }
}

#[test]
fn resolve_auto_port_returns_a_bindable_free_port() {
    // It must hand back a concrete (non-zero) port for the `--port 0` case…
    let port = resolve_auto_port("127.0.0.1").expect("resolve a free port");
    assert_ne!(port, 0, "auto-select must resolve to a concrete port, not 0");
    // …and the listener must have been released, so codex can bind it next.
    std::net::TcpListener::bind(("127.0.0.1", port))
        .expect("the resolved port should be free to bind");
}

#[test]
fn ws_host_port_parses_websocket_urls_only() {
    assert_eq!(ws_host_port("ws://127.0.0.1:18080"), Some(("127.0.0.1".to_string(), 18080)));
    // Trailing path is ignored (authority only).
    assert_eq!(ws_host_port("ws://0.0.0.0:9000/foo"), Some(("0.0.0.0".to_string(), 9000)));
    // Unix sockets and missing/garbage ports have no TCP endpoint.
    assert_eq!(ws_host_port("unix:///tmp/codex.sock"), None);
    assert_eq!(ws_host_port("ws://127.0.0.1"), None);
    assert_eq!(ws_host_port("ws://127.0.0.1:notaport"), None);
}
