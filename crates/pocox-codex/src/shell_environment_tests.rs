use std::{fs, os::unix::fs::PermissionsExt, path::PathBuf};

use super::*;

fn script(root: &Path, name: &str, body: &str) -> PathBuf {
    let path = root.join(name);
    fs::write(&path, format!("#!/bin/sh\n{body}\n")).expect("write script");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).expect("chmod");
    path
}

fn environment(root: &Path) -> Vec<(OsString, OsString)> {
    vec![
        ("HOME".into(), root.into()),
        ("ZDOTDIR".into(), root.into()),
        ("PATH".into(), "/usr/bin:/bin".into()),
    ]
}

#[test]
fn npm_codex_uses_shell_node_without_changing_controller_path() {
    let root = tempfile::tempdir().expect("tempdir");
    let node_dir = root.path().join("node with spaces");
    fs::create_dir(&node_dir).expect("node directory");
    script(&node_dir, "node", "printf node-ok");
    let codex = root.path().join("codex");
    fs::write(&codex, "#!/usr/bin/env node\n").expect("npm launcher");
    fs::set_permissions(&codex, fs::Permissions::from_mode(0o700)).expect("chmod");
    let shell = script(
        root.path(),
        "shell",
        r#"
        [ "$1" = '-ilc' ] || exit 9
        printf 'startup noise\n'
        printf 'startup warning\n' >&2
        export PATH="$HOME:$HOME/node with spaces:/usr/bin:/bin"
        eval "$2"
    "#,
    );
    let inherited = root.path().join("empty-bin").into_os_string();
    let mut env = environment(root.path());
    env.push(("PATH".into(), inherited.clone()));
    let parent_path = std::env::var_os("PATH");
    let broken = Command::new(&codex)
        .env("PATH", &inherited)
        .output()
        .expect("launcher");
    assert_eq!(broken.status.code(), Some(127));
    let resolved =
        resolve_path(&shell, &env, Some(&inherited), Duration::from_secs(3)).expect("PATH");
    let located = crate::process::locate_on_path(Some(&resolved)).expect("find shell Codex");
    assert_eq!(located, codex);
    let repaired =
        crate::process::build_command(&located, "ws://127.0.0.1:1", &[], None, Some(&resolved))
            .output()
            .expect("launcher");
    assert!(repaired.status.success());
    assert_eq!(repaired.stdout, b"node-ok");
    assert_eq!(std::env::var_os("PATH"), parent_path);
    assert!(!resolved.to_string_lossy().contains("startup"));
    assert!(std::env::split_paths(&resolved).any(|entry| entry == node_dir));
}

#[test]
fn preserves_inherited_tool_order_and_deduplicates_shell_entries() {
    let path =
        merge_path(Some(OsStr::new("/chosen/node:/bin")), OsStr::new("/other/node:/bin::/usr/bin"))
            .expect("PATH");
    assert_eq!(path, "/chosen/node:/bin:/other/node:/usr/bin");
    assert!(merge_path(None, OsStr::new("::")).is_err());
}

#[test]
fn rejects_failed_missing_empty_and_oversized_shell_output() {
    let root = tempfile::tempdir().expect("tempdir");
    let env = environment(root.path());
    for body in [
        "exit 2",
        "exit 0",
        "printf '\\n' > \"$POCOX_PATH_FILE\"",
        "/usr/bin/head -c 131072 /dev/zero > \"$POCOX_PATH_FILE\"",
    ] {
        let shell = script(root.path(), "shell", body);
        assert!(resolve_path(&shell, &env, None, Duration::from_secs(3)).is_err(), "{body}");
    }
    assert!(resolve_path(Path::new("relative-shell"), &env, None, Duration::from_secs(1)).is_err());
    assert!(resolve_path(&root.path().join("absent"), &env, None, Duration::from_secs(1)).is_err());
}

fn assert_stopped(pid_file: &Path) {
    let pid = fs::read_to_string(pid_file).expect("child started before probe returned");
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let output = Command::new("/bin/ps")
            .args(["-o", "stat=", "-p", pid.trim()])
            .output()
            .expect("process status");
        let status = String::from_utf8_lossy(&output.stdout);
        // Orphan reaping belongs to init; a zombie cannot execute or retain files.
        if !output.status.success() || status.trim().starts_with('Z') {
            return;
        }
        assert!(Instant::now() < deadline, "probe child {pid} still running: {status}");
        thread::sleep(Duration::from_millis(10));
    }
}

fn ready_startup_probe(shell: &Path, root: &Path) -> Probe {
    let child = Command::new(shell)
        .args(["-ilc", "exit 0"])
        .env_clear()
        .envs(environment(root))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .expect("startup probe");
    let probe = Probe(child);
    // Test cleanup after startup separately from the scheduler's launch latency.
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if fs::read_to_string(root.join("child.pid"))
            .ok()
            .is_some_and(|pid| pid.trim().parse::<u32>().is_ok())
        {
            return probe;
        }
        assert!(Instant::now() < deadline, "startup child did not become ready");
        thread::sleep(Duration::from_millis(10));
    }
}

fn assert_probe_times_out(mut probe: Probe) {
    let start = Instant::now();
    let result = probe.wait(Duration::from_millis(100));
    assert!(result
        .expect_err("timeout")
        .to_string()
        .contains("timed out"));
    assert!(start.elapsed() < Duration::from_secs(2));
    drop(probe);
}

#[test]
fn path_probe_timeout_does_not_require_startup_to_finish() {
    let root = tempfile::tempdir().expect("tempdir");
    let shell = script(root.path(), "shell", "exec /bin/sleep 60");
    let result = resolve_path(&shell, &environment(root.path()), None, Duration::ZERO);
    assert!(result
        .expect_err("timeout")
        .to_string()
        .contains("timed out"));
}

#[test]
fn timeout_kills_foreground_and_background_startup_children_only() {
    let root = tempfile::tempdir().expect("tempdir");
    script(root.path(), "helper", "echo $$ > \"$HOME/child.pid\"\nexec /bin/sleep 60");
    // A separate group must survive every cleanup.
    let sentinel = Command::new("/bin/sleep")
        .arg("60")
        .process_group(0)
        .spawn()
        .expect("sentinel");
    let mut sentinel = Probe(sentinel);
    for body in [
        "trap '' TERM\n\"$HOME/helper\"",
        "trap '' TERM\n/bin/sleep 60 &\necho $! > \"$HOME/child.pid\"\nwait",
        "echo $$ > \"$HOME/child.pid\"\ntrap '' TERM\nwhile :; do :; done",
    ] {
        let shell = script(root.path(), "shell", body);
        assert_probe_times_out(ready_startup_probe(&shell, root.path()));
        assert_stopped(&root.path().join("child.pid"));
        assert!(sentinel.0.try_wait().expect("sentinel status").is_none());
        fs::remove_file(root.path().join("child.pid")).expect("remove pid");
    }
}

#[test]
fn successful_and_failed_shells_do_not_leave_background_children() {
    let root = tempfile::tempdir().expect("tempdir");
    for status in [0, 2] {
        let shell = script(
            root.path(),
            "shell",
            &format!(
                r#"
            /bin/sleep 60 &
            echo $! > "$HOME/child.pid"
            /usr/bin/printenv PATH > "$POCOX_PATH_FILE"
            exit {status}
        "#
            ),
        );
        let result = resolve_path(&shell, &environment(root.path()), None, Duration::from_secs(3));
        assert_eq!(result.is_ok(), status == 0);
        assert_stopped(&root.path().join("child.pid"));
    }
}

#[test]
fn real_zsh_startup_is_isolated_and_its_blocked_child_is_terminated() {
    let zsh = Path::new("/bin/zsh");
    if !zsh.exists() && !cfg!(target_os = "macos") {
        return;
    }
    let root = tempfile::tempdir().expect("tempdir");
    fs::write(
        root.path().join(".zshrc"),
        "export PATH=\"$HOME/custom node:/usr/bin:/bin\"\nprint banner\n",
    )
    .expect("zshrc");
    let path = resolve_path(zsh, &environment(root.path()), None, Duration::from_secs(3))
        .expect("zsh PATH");
    assert_eq!(std::env::split_paths(&path).next(), Some(root.path().join("custom node")));
    fs::write(root.path().join(".zshrc"), "/bin/sleep 60 &\necho $! > \"$HOME/child.pid\"\nwait\n")
        .expect("blocking zshrc");
    assert_probe_times_out(ready_startup_probe(zsh, root.path()));
    assert_stopped(&root.path().join("child.pid"));
}

#[test]
fn provider_variables_are_allowlisted_private_and_preserved_verbatim() {
    let root = tempfile::tempdir().expect("tempdir");
    let shell = script(
        root.path(),
        "shell",
        r#"
        printf 'startup noise with a secret'
        export ANTHROPIC_BASE_URL='https://provider.invalid/api'
        export ANTHROPIC_AUTH_TOKEN='quotes " = spaces
second line'
        export UNRELATED_SECRET='not requested'
        eval "$2"
        [ "$(/bin/ls -l "$POCOX_ENV_FILE" | /usr/bin/cut -c1-10)" = -rw------- ] || exit 8
    "#,
    );
    let before = std::env::var_os("ANTHROPIC_AUTH_TOKEN");
    let result = resolve_variables(
        &shell,
        &environment(root.path()),
        &["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"],
        Duration::from_secs(3),
    )
    .expect("variables");
    assert_eq!(result, vec![
        ("ANTHROPIC_BASE_URL".into(), "https://provider.invalid/api".into()),
        ("ANTHROPIC_AUTH_TOKEN".into(), "quotes \" = spaces\nsecond line".into()),
    ]);
    assert_eq!(std::env::var_os("ANTHROPIC_AUTH_TOKEN"), before);
}

#[test]
fn a_complete_inherited_set_skips_shell_and_preserves_empty_values() {
    let env = vec![
        ("ANTHROPIC_BASE_URL".into(), "".into()),
        ("ANTHROPIC_AUTH_TOKEN".into(), "token".into()),
    ];
    let result = resolve_variables(
        Path::new("must-not-start"),
        &env,
        &["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN"],
        Duration::ZERO,
    )
    .expect("inherited");
    assert_eq!(result, env, "an explicit empty endpoint also wins; no token is imported");
}

#[test]
fn provider_probe_rejects_bad_output_and_never_leaks_values_in_errors() {
    let root = tempfile::tempdir().expect("tempdir");
    for body in [
        "printf 'UNEXPECTED\\0secret-value\\0' > \"$POCOX_ENV_FILE\"",
        "printf 'ANTHROPIC_AUTH_TOKEN\\0secret-value' > \"$POCOX_ENV_FILE\"",
        "/usr/bin/head -c 131072 /dev/zero > \"$POCOX_ENV_FILE\"",
        "exit 2",
    ] {
        let shell = script(root.path(), "shell", body);
        let error = resolve_variables(
            &shell,
            &environment(root.path()),
            &["ANTHROPIC_AUTH_TOKEN"],
            Duration::from_secs(3),
        )
        .expect_err("invalid");
        assert!(!format!("{error:#}").contains("secret-value"));
    }
    assert!(
        resolve_variables(Path::new("/bin/sh"), &[], &["X;touch nope"], Duration::ZERO).is_err()
    );
}

#[test]
fn zshenv_supplies_provider_variables_without_a_login_flow() {
    let zsh = Path::new("/bin/zsh");
    if !zsh.exists() && !cfg!(target_os = "macos") {
        return;
    }
    let root = tempfile::tempdir().expect("tempdir");
    fs::write(
        root.path().join(".zshenv"),
        "export ANTHROPIC_BASE_URL=https://provider.invalid\nexport \
         ANTHROPIC_AUTH_TOKEN=test-token\n",
    )
    .expect("zshenv");
    let values = resolve_variables(
        zsh,
        &environment(root.path()),
        &["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN"],
        Duration::from_secs(3),
    )
    .expect("zshenv");
    assert_eq!(values.len(), 2);
    assert_eq!(values[1].1, "test-token");
}

#[test]
fn partial_inheritance_survives_shell_unsets_and_wins_over_shell_values() {
    let root = tempfile::tempdir().expect("tempdir");
    let names = &["ANTHROPIC_MODEL", "CLAUDE_CODE_EFFORT_LEVEL"];
    let mut env = environment(root.path());
    env.push(("ANTHROPIC_MODEL".into(), "parent-model".into()));
    for (body, effort) in [
        ("unset ANTHROPIC_MODEL; eval \"$2\"", None),
        (
            "export ANTHROPIC_MODEL=shell-model CLAUDE_CODE_EFFORT_LEVEL=high; eval \"$2\"",
            Some("high"),
        ),
    ] {
        let shell = script(root.path(), "shell", body);
        let result: std::collections::BTreeMap<_, _> =
            resolve_variables(&shell, &env, names, Duration::from_secs(3))
                .expect("merged variables")
                .into_iter()
                .collect();
        assert_eq!(
            result.get(OsStr::new("ANTHROPIC_MODEL")),
            Some(&OsString::from("parent-model"))
        );
        assert_eq!(
            result.get(OsStr::new("CLAUDE_CODE_EFFORT_LEVEL")),
            effort.map(OsString::from).as_ref()
        );
    }
}
