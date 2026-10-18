use std::os::unix::fs::PermissionsExt;

use super::*;

fn executable(path: &Path) {
    std::fs::create_dir_all(path.parent().expect("parent")).expect("dirs");
    std::fs::write(path, b"#!/bin/sh\n").expect("write");
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
}

/// An installed adapter package under `prefix` and its `bin` link, as npm
/// lays them out.
fn installed_package(prefix: &Path) -> (PathBuf, PathBuf) {
    let package = prefix.join("lib/node_modules").join(ADAPTER_PACKAGE);
    let entry = package.join("dist/index.js");
    executable(&entry);
    std::fs::write(
        package.join("package.json"),
        serde_json::to_vec(&serde_json::json!({"name": ADAPTER_PACKAGE, "version": "0.88.0"}))
            .expect("json"),
    )
    .expect("manifest");
    let bin = prefix.join("bin").join(ADAPTER_BIN);
    std::fs::create_dir_all(bin.parent().expect("parent")).expect("dirs");
    std::os::unix::fs::symlink(&entry, &bin).expect("link");
    (bin, std::fs::canonicalize(entry).expect("real"))
}

/// A completed preparation as npm and the setup lay it out.
fn prepared(cache: &Path) -> PathBuf {
    let dir = version_dir(cache);
    let entry = prepared_entry(&dir);
    executable(&entry);
    let package = dir.join("node_modules").join(ADAPTER_PACKAGE);
    let manifest = serde_json::json!({"name": ADAPTER_PACKAGE, "version": ADAPTER_VERSION});
    std::fs::write(package.join("package.json"), manifest.to_string()).expect("manifest");
    let lock = serde_json::json!({"packages": {
        format!("node_modules/{ADAPTER_PACKAGE}"):
            {"version": ADAPTER_VERSION, "integrity": ADAPTER_INTEGRITY},
    }});
    std::fs::write(dir.join("package-lock.json"), lock.to_string()).expect("lock");
    std::fs::write(dir.join(READY_MARKER), ready_marker().to_string()).expect("marker");
    entry
}

/// A probe reading a version from a `<node>.version` file beside it.
fn read_probe(path: &Path) -> Option<Version> {
    let mut name = path.as_os_str().to_owned();
    name.push(".version");
    parse_version(&std::fs::read_to_string(PathBuf::from(name)).ok()?)
}

async fn probe(path: &Path) -> Option<Version> {
    read_probe(path)
}

/// npm's CLI script laid out beside the Node.js at `<prefix>/bin/node`.
fn npm_beside(prefix: &Path) -> PathBuf {
    let cli = prefix.join("lib/node_modules/npm/bin/npm-cli.js");
    executable(&cli);
    cli
}

fn node(path: &Path, version: &str) {
    executable(path);
    let mut name = path.as_os_str().to_owned();
    name.push(".version");
    std::fs::write(PathBuf::from(name), version).expect("version");
}

fn lookup<'a>(path: &'a OsStr, home: &'a Path, cache: &'a Path) -> Lookup<'a> {
    Lookup {
        search_path: Some(path),
        home: Some(home),
        cache,
        inherited_cli: false,
        system: false,
    }
}

#[test]
fn versions_parse_with_or_without_a_prefix() {
    assert_eq!(parse_version("v22.11.0\n"), Some((22, 11, 0)));
    assert_eq!(parse_version("20.20.1"), Some((20, 20, 1)));
    assert_eq!(parse_version("v23.0.0-nightly"), Some((23, 0, 0)));
    assert_eq!(parse_version("node"), None);
    assert_eq!(parse_version("v22"), None);
}

#[test]
fn only_the_presets_bare_program_is_discovered() {
    let mut spec = super::super::spec::preset("claude").expect("preset").spec();
    assert!(applies(&spec));
    spec.program = "/opt/tools/claude-agent-acp".into();
    assert!(!applies(&spec), "an explicit path is launched verbatim");
    let mut other = super::super::spec::AgentSpec {
        profile_id: "fixture".into(),
        display_name: "Fixture".into(),
        program: "fixture-agent".into(),
        args: Vec::new(),
    };
    assert!(!applies(&other));
    other.program = ADAPTER_BIN.into();
    assert!(!applies(&other), "another profile is launched verbatim");
}

#[tokio::test]
async fn an_installed_script_runs_on_a_new_enough_node_with_the_cli_passed_to_the_child() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();
    let home = root.join("home");
    let cache = root.join("cache");
    // The inherited PATH has an old Node.js (the user's default) and the
    // adapter; a manager has 22.
    let (bin, entry) = installed_package(&root.join("global"));
    node(&root.join("old/node"), "v20.20.1");
    node(&home.join(".nvm/versions/node/v22.23.2/bin/node"), "v22.23.2");
    node(&home.join(".nvm/versions/node/v18.0.0/bin/node"), "v18.0.0");
    executable(&home.join(".local/bin/claude"));
    let path = std::env::join_paths([root.join("old"), root.join("global/bin")]).expect("path");
    let env = detect_with(&lookup(&path, &home, &cache), probe).await;
    let adapter = env.adapter.clone().expect("adapter");
    assert_eq!(adapter.bin, bin);
    assert_eq!(adapter.entry.as_deref(), Some(entry.as_path()));
    assert_eq!(adapter.source, AdapterSource::Installed);
    let node22 = home.join(".nvm/versions/node/v22.23.2/bin/node");
    assert_eq!(env.node.as_ref().map(|n| &n.path), Some(&node22));
    let launch = env.launch(&["--flag".into()]).expect("launch");
    assert_eq!(launch.program, node22);
    assert_eq!(launch.args, vec![entry.to_str().expect("utf8").to_string(), "--flag".into()]);
    assert_eq!(launch.source, bin, "the record stays keyed by the adapter");
    assert_eq!(launch.env, vec![(
        OsString::from(CLI_ENV),
        home.join(".local/bin/claude").into_os_string()
    )]);
    let status = env.status();
    assert!(status.ready);
    assert_eq!((status.adapter, status.runtime, status.cli), ("installed", "found", "found"));
    assert_eq!(status.runtime_version.as_deref(), Some("22.23.2"));
    assert!(!status.can_prepare);
}

#[tokio::test]
async fn an_inherited_cli_variable_is_kept_and_not_overridden() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();
    let (_, _) = installed_package(&root.join("global"));
    node(&root.join("global/bin/node"), "v22.11.0");
    executable(&root.join("global/bin/claude"));
    let path = std::env::join_paths([root.join("global/bin")]).expect("path");
    let mut look = lookup(&path, root, root);
    look.inherited_cli = true;
    let env = detect_with(&look, probe).await;
    assert_eq!(env.cli, Cli::Inherited);
    assert!(env.launch(&[]).expect("launch").env.is_empty());
    assert_eq!(env.status().cli_path, None);
}

#[tokio::test]
async fn a_wrapper_adapter_runs_directly_and_needs_no_node() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();
    executable(&root.join("bin").join(ADAPTER_BIN));
    executable(&root.join("bin/node"));
    let path = std::env::join_paths([root.join("bin")]).expect("path");
    let mut env = inspect_with(&lookup(&path, root, root), async |_: &Path| {
        panic!("a wrapper must not probe unrelated Node installations")
    })
    .await;
    // Even a previously captured inspection failure cannot block a wrapper.
    env.inspection_error = Some(process::OutputError::Timeout);
    let launch = env.launch(&["a b".into()]).expect("launch");
    assert_eq!(launch.program, root.join("bin").join(ADAPTER_BIN));
    assert_eq!(launch.args, vec!["a b".to_string()]);
    assert_eq!(launch.env, Vec::new(), "no CLI found: the SDK's bundled one is used");
    let status = env.status();
    assert!(status.ready);
    assert_eq!((status.runtime, status.cli), ("notNeeded", "missing"));
}

#[tokio::test]
async fn a_script_with_only_old_node_reports_the_version_and_is_not_started() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();
    let (_, _) = installed_package(&root.join("global"));
    node(&root.join("global/bin/node"), "v20.20.1");
    let path = std::env::join_paths([root.join("global/bin")]).expect("path");
    let env = detect_with(&lookup(&path, root, root), probe).await;
    assert_eq!(env.too_old, Some((20, 20, 1)));
    let error = env.launch(&[]).expect_err("too old");
    assert!(matches!(error, Missing::Runtime(_)));
    assert!(error.to_string().contains("20.20.1"));
    let status = env.status();
    assert!(!status.ready);
    assert_eq!(status.runtime, "tooOld");
    assert!(!status.can_prepare, "an adapter exists: nothing to prepare");
}

#[tokio::test]
async fn without_an_adapter_preparation_is_offered_only_with_node_and_npm() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();
    let cache = root.join("cache");
    // The native CLI alone is never mistaken for the adapter.
    executable(&root.join("bin/claude"));
    node(&root.join("prefix/bin/node"), "v22.11.0");
    let path = std::env::join_paths([root.join("bin"), root.join("prefix/bin")]).expect("path");
    let env = detect_with(&lookup(&path, root, &cache), probe).await;
    assert_eq!(env.adapter, None);
    assert_eq!(env.launch(&[]), Err(Missing::Adapter));
    assert!(!env.can_prepare(), "no npm beside this Node.js");
    let cli = npm_beside(&root.join("prefix"));
    let env = detect_with(&lookup(&path, root, &cache), probe).await;
    assert_eq!(
        env.npm,
        Some(Npm {
            node: root.join("prefix/bin/node"),
            cli,
        })
    );
    let status = env.status();
    assert!(!status.ready && status.can_prepare);
    assert_eq!(status.adapter, "missing");
    assert!(status.problem.expect("problem").contains(ADAPTER_PACKAGE));
}

#[tokio::test]
async fn preparation_uses_a_later_node_with_npm_when_the_first_has_none() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();
    let cache = root.join("cache");
    // The first compatible Node.js on PATH has no npm; a later one does.
    node(&root.join("bare/bin/node"), "v22.11.0");
    node(&root.join("old/bin/node"), "v20.20.1");
    npm_beside(&root.join("old"));
    node(&root.join("paired/bin/node"), "v23.1.0");
    let cli = npm_beside(&root.join("paired"));
    let path = std::env::join_paths([
        root.join("bare/bin"),
        root.join("old/bin"),
        root.join("paired/bin"),
    ])
    .expect("path");
    let env = detect_with(&lookup(&path, root, &cache), probe).await;
    assert_eq!(
        env.node.as_ref().map(|n| &n.path),
        Some(&root.join("bare/bin/node")),
        "the first compatible one still runs an adapter"
    );
    assert_eq!(
        env.npm,
        Some(Npm {
            node: root.join("paired/bin/node"),
            cli,
        }),
        "an old Node.js with npm is not a preparation pair"
    );
    assert!(env.can_prepare());

    // With an adapter installed, nothing further is probed for npm.
    let (_, _) = installed_package(&root.join("global"));
    let path = std::env::join_paths([
        root.join("bare/bin"),
        root.join("paired/bin"),
        root.join("global/bin"),
    ])
    .expect("path");
    let probed = std::cell::Cell::new(0);
    let counting = async |path: &Path| {
        probed.set(probed.get() + 1);
        read_probe(path)
    };
    let env = detect_with(&lookup(&path, root, &cache), counting).await;
    assert_eq!(env.npm, None);
    assert_eq!(probed.get(), 1);
}

#[tokio::test]
async fn a_prepared_copy_is_used_only_with_its_marker_and_after_installed_ones() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();
    let cache = root.join("cache");
    node(&root.join("bin/node"), "v22.11.0");
    let path = std::env::join_paths([root.join("bin")]).expect("path");
    let entry = prepared(&cache);
    let env = detect_with(&lookup(&path, root, &cache), probe).await;
    let adapter = env.adapter.clone().expect("prepared");
    assert_eq!(
        (adapter.source, adapter.entry.as_deref()),
        (AdapterSource::Prepared, Some(entry.as_path()))
    );
    assert_eq!(env.launch(&[]).expect("launch").program, root.join("bin/node"));

    // A partial or foreign preparation is ignored.
    std::fs::write(version_dir(&cache).join(READY_MARKER), b"{\"version\":\"latest\"}")
        .expect("marker");
    assert_eq!(prepared_adapter(&cache), None);
    std::fs::remove_file(version_dir(&cache).join(READY_MARKER)).expect("rm");
    assert_eq!(prepared_adapter(&cache), None);

    // An installed adapter wins over a prepared one.
    let entry = prepared(&cache);
    assert_eq!(prepared_adapter(&cache), Some(entry));
    let (bin, _) = installed_package(&root.join("global"));
    let path = std::env::join_paths([root.join("bin"), root.join("global/bin")]).expect("path");
    let env = detect_with(&lookup(&path, root, &cache), probe).await;
    assert_eq!(env.adapter.expect("adapter").bin, bin);
}

#[test]
fn a_stale_marker_over_a_changed_installation_is_not_prepared() {
    let dir = tempfile::tempdir().expect("tempdir");
    let cache = dir.path().join("cache");
    let entry = prepared(&cache);
    assert_eq!(prepared_adapter(&cache), Some(entry));
    let version = version_dir(&cache);
    std::fs::remove_file(
        version
            .join("node_modules")
            .join(ADAPTER_PACKAGE)
            .join("package.json"),
    )
    .expect("rm");
    assert_eq!(prepared_adapter(&cache), None, "no manifest");
    assert_eq!(check_installation(&version), Err("no manifest"));
    prepared(&cache);
    let lock = serde_json::json!({"packages": {
        format!("node_modules/{ADAPTER_PACKAGE}"):
            {"version": ADAPTER_VERSION, "integrity": "sha512-other"},
    }});
    std::fs::write(version.join("package-lock.json"), lock.to_string()).expect("lock");
    assert_eq!(prepared_adapter(&cache), None, "a lock naming another tarball");
}

#[tokio::test]
async fn node_probes_are_bounded_and_deduplicated() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();
    let mut dirs = Vec::new();
    for index in 0..12 {
        let bin = root.join(format!("n{index}"));
        node(&bin.join("node"), "v20.0.0");
        dirs.push(bin);
    }
    // The same file reached twice is probed once.
    std::os::unix::fs::symlink(root.join("n0"), root.join("again")).expect("link");
    dirs.insert(1, root.join("again"));
    let path = std::env::join_paths(&dirs).expect("path");
    let probed = std::cell::Cell::new(0);
    let counting = async |path: &Path| {
        probed.set(probed.get() + 1);
        read_probe(path)
    };
    let env = detect_with(&lookup(&path, root, root), counting).await;
    assert_eq!(env.node, None);
    assert_eq!(probed.get(), MAX_NODE_PROBES);
}

fn script(dir: &Path, name: &str, body: &str) -> PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).expect("write");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    path
}

fn alive(pid: i32) -> bool {
    nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None).is_ok()
}

fn pid_in(file: &Path) -> i32 {
    std::fs::read_to_string(file)
        .expect("pid")
        .trim()
        .parse()
        .expect("number")
}

#[tokio::test]
async fn the_real_probe_reads_a_version_and_gives_up_on_silence() {
    let dir = tempfile::tempdir().expect("tempdir");
    let answers = script(dir.path(), "node", "echo v22.4.1");
    assert_eq!(node_version(&answers).await, Some((22, 4, 1)));
    let fails = script(dir.path(), "fails", "exit 3");
    assert_eq!(node_version(&fails).await, None);
    // A leader that never answers is stopped at the bound, with its group.
    let pid = dir.path().join("silent-pid");
    let silent =
        script(dir.path(), "silent", &format!("echo $$ > '{}'\nexec sleep 30", pid.display()));
    let started = std::time::Instant::now();
    assert_eq!(node_version(&silent).await, None);
    assert!(started.elapsed() < NODE_PROBE_TIMEOUT + Duration::from_secs(2));
    assert!(!alive(pid_in(&pid)), "the silent leader was stopped and reaped");
}

#[tokio::test]
async fn a_descendant_holding_the_output_neither_stalls_the_probe_nor_survives_it() {
    let dir = tempfile::tempdir().expect("tempdir");
    let pid = dir.path().join("descendant-pid");
    // The leader answers and exits; its background child keeps stdout open.
    let leaves = script(
        dir.path(),
        "node",
        &format!("sleep 30 &\necho $! > '{}'\necho v22.4.1\nexit 0", pid.display()),
    );
    // An unrelated process outside the probe's group.
    let mut unrelated = std::process::Command::new("/bin/sleep")
        .arg("30")
        .spawn()
        .expect("unrelated");
    let started = std::time::Instant::now();
    assert_eq!(node_version(&leaves).await, Some((22, 4, 1)));
    assert!(started.elapsed() < NODE_PROBE_TIMEOUT, "no wait for an end that never comes");
    let descendant = pid_in(&pid);
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while alive(descendant) && std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(!alive(descendant), "the probe's own group was cleaned up");
    assert_eq!(unrelated.try_wait().expect("status"), None, "an unrelated process survives");
    unrelated.kill().expect("kill");
    unrelated.wait().expect("reap");
}

#[tokio::test]
async fn malformed_or_oversized_output_is_not_a_version() {
    let dir = tempfile::tempdir().expect("tempdir");
    let garbage = script(dir.path(), "garbage", "echo not-a-version");
    assert_eq!(node_version(&garbage).await, None);
    // A version line followed by far more than a version prints.
    let huge = script(dir.path(), "huge", "echo v22.4.1\nhead -c 4096 /dev/zero | tr '\\0' x");
    assert_eq!(node_version(&huge).await, None);
    let binary = script(dir.path(), "binary", "printf 'v22.4.1\\377\\376'");
    assert_eq!(node_version(&binary).await, None, "not UTF-8");
}

#[tokio::test]
async fn exhausted_inspection_is_retryable_and_does_not_claim_node_is_missing() {
    let dir = tempfile::tempdir().expect("temp");
    let root = dir.path();
    node(&root.join("bin/node"), "v22.23.2");
    npm_beside(root);
    let path = root.join("bin").into_os_string();
    let env = inspect_with(&lookup(&path, root, root), async |_: &Path| {
        Err(process::OutputError::Spawn(process::SpawnError::FileLimit))
    })
    .await;
    assert!(matches!(env.launch(&[]), Err(Missing::Inspection(_))));
    assert!(!env.can_prepare());
    assert_eq!(env.status().runtime, "unavailable");
    assert_eq!(env.status().adapter, "unavailable");
    let recovered = detect_with(&lookup(&path, root, root), probe).await;
    assert_eq!(recovered.status().runtime, "found");
    assert!(recovered.can_prepare());
}
