use std::os::unix::fs::PermissionsExt;

use super::{
    super::claude::{prepared_entry, ADAPTER_INTEGRITY},
    *,
};

/// A stand-in `node` that behaves like `node --require hook npm-cli.js install
/// --prefix <stage> …`: `$6` is the staging directory. `body` runs after it
/// lays out the package with `version` and `integrity`.
fn fake_node(dir: &Path, version: &str, integrity: &str, body: &str) -> PathBuf {
    let script = format!(
        r#"#!/bin/sh
stage="$6"
pkg="$stage/node_modules/{ADAPTER_PACKAGE}"
mkdir -p "$pkg/dist"
printf '%s' "$PATH" > "$stage/../seen-path"
printf '%s' "$npm_config_cache" > "$stage/../seen-cache"
printf '%s ' "$@" > "$stage/../seen-args"
printf 'console.log(1)' > "$pkg/dist/index.js"
printf '{{"name":"{ADAPTER_PACKAGE}","version":"{version}"}}' > "$pkg/package.json"
printf '{{"packages":{{"node_modules/{ADAPTER_PACKAGE}":{{"version":"{version}","integrity":"{integrity}"}}}}}}' > "$stage/package-lock.json"
{body}
"#
    );
    let node = dir.join("bin/node");
    std::fs::create_dir_all(node.parent().expect("parent")).expect("dirs");
    std::fs::write(&node, script).expect("write");
    std::fs::set_permissions(&node, std::fs::Permissions::from_mode(0o755)).expect("chmod");
    node
}

fn job(root: &Path, node: PathBuf) -> Prepare {
    Prepare {
        node,
        npm_cli: root.join("npm-cli.js"),
        cache: root.join("cache"),
        path: Some(OsString::from("/usr/bin:/bin")),
        timeout: Duration::from_secs(20),
    }
}

fn leftovers(cache: &Path) -> Vec<String> {
    std::fs::read_dir(package_root(cache))
        .map(|entries| {
            entries
                .flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|name| name.starts_with(".stage-"))
                .collect()
        })
        .unwrap_or_default()
}

#[tokio::test]
async fn a_verified_install_is_marked_and_moved_into_place_once() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();
    let node = fake_node(root, ADAPTER_VERSION, ADAPTER_INTEGRITY, "exit 0");
    let job = job(root, node);
    let (_tx, rx) = watch::channel(false);
    let stages = std::sync::Mutex::new(Vec::new());
    let entry = prepare(&job, |s| stages.lock().expect("lock").push(s), rx.clone())
        .await
        .expect("prepared");
    assert_eq!(entry, prepared_entry(&version_dir(&job.cache)));
    assert_eq!(prepared_adapter(&job.cache), Some(entry.clone()));
    assert_eq!(*stages.lock().expect("lock"), vec![Stage::Installing, Stage::Verifying]);
    assert!(leftovers(&job.cache).is_empty());
    let root_dir = package_root(&job.cache);
    let args = std::fs::read_to_string(root_dir.join("seen-args")).expect("args");
    assert!(args.contains(&format!("{ADAPTER_PACKAGE}@{ADAPTER_VERSION}")), "pinned, never latest");
    assert!(args.contains("--ignore-scripts"));
    let path = std::fs::read_to_string(root_dir.join("seen-path")).expect("path");
    assert!(
        path.starts_with(&format!("{}:", root.join("bin").display())),
        "node dir first: {path}"
    );
    assert_eq!(
        std::fs::read_to_string(root_dir.join("seen-cache")).expect("cache"),
        root_dir.join("npm-cache").display().to_string()
    );

    // A completed preparation is not run again.
    std::fs::remove_file(root_dir.join("seen-args")).expect("rm");
    let again = prepare(&job, |_| {}, rx).await.expect("prepared");
    assert_eq!(again, entry);
    assert!(!root_dir.join("seen-args").exists(), "npm did not run again");
}

#[tokio::test]
async fn a_mismatched_or_failed_install_is_rejected_and_cleaned_up() {
    for (version, integrity, body, expected) in [
        ("0.90.0", ADAPTER_INTEGRITY, "exit 0", SetupError::Corrupt("locked version")),
        (ADAPTER_VERSION, "sha512-other", "exit 0", SetupError::Corrupt("integrity")),
        (
            ADAPTER_VERSION,
            ADAPTER_INTEGRITY,
            "rm \"$pkg/dist/index.js\"",
            SetupError::Corrupt("no entry script"),
        ),
        (ADAPTER_VERSION, ADAPTER_INTEGRITY, "exit 7", SetupError::Install("7".into())),
    ] {
        let dir = tempfile::tempdir().expect("tempdir");
        let root = dir.path();
        let job = job(root, fake_node(root, version, integrity, body));
        let (_tx, rx) = watch::channel(false);
        assert_eq!(prepare(&job, |_| {}, rx).await, Err(expected));
        assert_eq!(prepared_adapter(&job.cache), None);
        assert!(!version_dir(&job.cache).exists(), "nothing partial is left in place");
        assert!(leftovers(&job.cache).is_empty(), "the staging directory is removed");
    }
}

#[tokio::test]
async fn cancelling_stops_only_its_own_npm_and_removes_the_stage() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();
    // The child records its own pid and hangs.
    let body = "echo $$ > \"$stage/../npm-pid\"\nsleep 30 &\nwait";
    let job = job(root, fake_node(root, ADAPTER_VERSION, ADAPTER_INTEGRITY, body));
    let (tx, rx) = watch::channel(false);
    let pid_file = package_root(&job.cache).join("npm-pid");
    let watcher = {
        let pid_file = pid_file.clone();
        tokio::spawn(async move {
            while !pid_file.exists() {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            tx.send_replace(true);
            tx
        })
    };
    assert_eq!(prepare(&job, |_| {}, rx).await, Err(SetupError::Cancelled));
    let _tx = watcher.await.expect("watcher");
    let pid: i32 = std::fs::read_to_string(&pid_file)
        .expect("pid")
        .trim()
        .parse()
        .expect("number");
    assert!(
        nix::sys::signal::kill(nix::unistd::Pid::from_raw(pid), None).is_err(),
        "npm was stopped and reaped"
    );
    assert!(leftovers(&job.cache).is_empty());
    assert_eq!(prepared_adapter(&job.cache), None);
}

#[tokio::test]
async fn a_cancel_before_the_start_runs_nothing() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();
    let job = job(root, fake_node(root, ADAPTER_VERSION, ADAPTER_INTEGRITY, "exit 0"));
    let (tx, rx) = watch::channel(false);
    tx.send_replace(true);
    assert_eq!(prepare(&job, |_| {}, rx).await, Err(SetupError::Cancelled));
    assert!(!package_root(&job.cache).join("seen-args").exists(), "npm never started");
    assert!(leftovers(&job.cache).is_empty());
    assert_eq!(prepared_adapter(&job.cache), None);
}

#[tokio::test]
async fn a_cancel_after_npm_finished_publishes_nothing() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();
    let job = job(root, fake_node(root, ADAPTER_VERSION, ADAPTER_INTEGRITY, "exit 0"));
    let (tx, rx) = watch::channel(false);
    // Cancelled exactly at the boundary between installing and verifying.
    let on_stage = |stage| {
        if stage == Stage::Verifying {
            tx.send_replace(true);
        }
    };
    assert_eq!(prepare(&job, on_stage, rx).await, Err(SetupError::Cancelled));
    assert!(package_root(&job.cache).join("seen-args").exists(), "npm did run");
    assert!(!version_dir(&job.cache).exists(), "nothing was put in place");
    assert!(leftovers(&job.cache).is_empty(), "the staging directory is removed");
    assert_eq!(prepared_adapter(&job.cache), None);
}

#[tokio::test]
async fn a_prepared_copy_that_changed_since_is_not_reused() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();
    let job = job(root, fake_node(root, ADAPTER_VERSION, ADAPTER_INTEGRITY, "exit 0"));
    let (_tx, rx) = watch::channel(false);
    let entry = prepare(&job, |_| {}, rx).await.expect("prepared");
    assert_eq!(prepared_adapter(&job.cache), Some(entry));
    let dir = version_dir(&job.cache);
    let manifest = dir
        .join("node_modules")
        .join(ADAPTER_PACKAGE)
        .join("package.json");
    let original = std::fs::read(&manifest).expect("manifest");
    std::fs::write(&manifest, format!(r#"{{"name":"{ADAPTER_PACKAGE}","version":"0.90.0"}}"#))
        .expect("write");
    assert_eq!(prepared_adapter(&job.cache), None, "a changed manifest");
    std::fs::write(&manifest, original).expect("restore");
    assert!(prepared_adapter(&job.cache).is_some());
    std::fs::remove_file(dir.join("package-lock.json")).expect("rm");
    assert_eq!(prepared_adapter(&job.cache), None, "a missing lockfile");
}

#[tokio::test]
async fn the_time_limit_stops_it() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();
    let mut job = job(root, fake_node(root, ADAPTER_VERSION, ADAPTER_INTEGRITY, "sleep 30"));
    job.timeout = Duration::from_millis(300);
    let (_tx, rx) = watch::channel(false);
    assert_eq!(prepare(&job, |_| {}, rx).await, Err(SetupError::Timeout));
    assert!(leftovers(&job.cache).is_empty());
}

#[tokio::test]
async fn an_invalid_directory_in_the_way_is_moved_aside_and_a_valid_winner_is_kept() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = dir.path();
    let job = job(root, fake_node(root, ADAPTER_VERSION, ADAPTER_INTEGRITY, "exit 0"));
    // An interrupted earlier attempt left files but no marker.
    let target = version_dir(&job.cache);
    std::fs::create_dir_all(target.join("node_modules")).expect("dirs");
    std::fs::write(target.join("node_modules/partial"), b"x").expect("write");
    let (_tx, rx) = watch::channel(false);
    let entry = prepare(&job, |_| {}, rx).await.expect("prepared");
    assert_eq!(prepared_adapter(&job.cache), Some(entry));
    let aside: Vec<_> = std::fs::read_dir(package_root(&job.cache))
        .expect("read")
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with(".invalid-"))
        .collect();
    assert_eq!(aside.len(), 1, "kept aside, not deleted");
    assert!(aside[0].path().join("node_modules/partial").exists());

    // A staging directory finishing after a valid winner leaves the winner.
    let late = package_root(&job.cache).join(".stage-late");
    std::fs::create_dir_all(&late).expect("dirs");
    let kept = install_into_place(&job.cache, &late).expect("winner");
    assert_eq!(Some(kept), prepared_adapter(&job.cache));
    assert!(late.exists(), "the loser is left for its owner to remove");
}
