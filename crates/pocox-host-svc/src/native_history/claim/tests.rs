use std::{
    io::{BufRead, Write},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

use super::*;

const WAIT: Duration = Duration::from_secs(10);

struct Worker(Child);
impl Drop for Worker {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn worker(source: &Path, session: &str, result: &Path, gate: Option<&Path>) -> Worker {
    let mut command = Command::new(std::env::current_exe().expect("test executable"));
    command
        .args(["--exact", "native_history::claim::tests::claim_child", "--test-threads=1"])
        .env("POCOX_CLAIM_SOURCE", source)
        .env("POCOX_CLAIM_SESSION", session)
        .env("POCOX_CLAIM_RESULT", result)
        .stdin(Stdio::piped())
        .stdout(Stdio::null());
    if let Some(gate) = gate {
        command.env("POCOX_CLAIM_GATE", gate);
    }
    Worker(command.spawn().expect("isolated test process"))
}

fn result(path: &Path) -> String {
    let deadline = Instant::now() + WAIT;
    loop {
        if let Ok(value) = fs::read_to_string(path) {
            if matches!(value.as_str(), "owned" | "busy") {
                return value;
            }
        }
        assert!(Instant::now() < deadline, "claim fixture reported a result");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn claim_child() {
    let Some(source) = std::env::var_os("POCOX_CLAIM_SOURCE") else { return };
    let session = std::env::var("POCOX_CLAIM_SESSION").expect("session");
    let output = std::env::var_os("POCOX_CLAIM_RESULT").expect("result path");
    if let Some(gate) = std::env::var_os("POCOX_CLAIM_GATE") {
        let deadline = Instant::now() + WAIT;
        while !Path::new(&gate).exists() {
            assert!(Instant::now() < deadline, "parent released race gate");
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    let claim = SessionClaim::acquire(Path::new(&source), &session);
    let state = match &claim {
        Ok(_) => "owned",
        Err(ClaimError::Busy) => "busy",
        Err(error) => panic!("claim fixture failed: {error}"),
    };
    fs::write(output, state).expect("result");
    if claim.is_ok() {
        let mut command = String::new();
        std::io::stdin()
            .lock()
            .read_line(&mut command)
            .expect("release");
        assert_eq!(command.trim(), "release");
    }
}

#[test]
fn independent_hosts_exclude_each_other_and_crashes_release_the_claim() {
    let fixture = tempfile::tempdir().expect("fixture");
    let source = fixture.path().join("source");
    fs::create_dir(&source).expect("source");
    let report = fixture.path().join("result");
    let mut owner = worker(&source, "session", &report, None);
    assert_eq!(result(&report), "owned");
    assert!(matches!(SessionClaim::acquire(&source, "session"), Err(ClaimError::Busy)));
    let other = SessionClaim::acquire(&source, "other-session").expect("separate session");
    owner.0.kill().expect("stop only the fixture owner");
    owner.0.wait().expect("reap fixture");
    let successor = SessionClaim::acquire(&source, "session").expect("crash releases OS lock");
    assert!(claim_path(&source, "session").expect("path").is_file());
    drop((other, successor));
}

#[test]
fn racing_processes_have_one_winner_and_normal_release_allows_the_successor() {
    let fixture = tempfile::tempdir().expect("fixture");
    let source = fixture.path().join("history.db");
    fs::write(&source, "native data must not change").expect("native source");
    let gate = fixture.path().join("gate");
    let a_result = fixture.path().join("a");
    let b_result = fixture.path().join("b");
    let mut a = worker(&source, "session", &a_result, Some(&gate));
    let mut b = worker(&source, "session", &b_result, Some(&gate));
    fs::write(gate, "go").expect("race gate");
    let (a_state, b_state) = (result(&a_result), result(&b_result));
    assert!(matches!((a_state.as_str(), b_state.as_str()), ("owned", "busy") | ("busy", "owned")));
    let owner = if a_state == "owned" { &mut a } else { &mut b };
    owner
        .0
        .stdin
        .take()
        .expect("input")
        .write_all(b"release\n")
        .expect("release");
    let deadline = Instant::now() + WAIT;
    loop {
        if let Some(status) = owner.0.try_wait().expect("wait") {
            assert!(status.success());
            break;
        }
        assert!(Instant::now() < deadline, "released owner exited");
        std::thread::sleep(Duration::from_millis(10));
    }
    let _next = SessionClaim::acquire(&source, "session").expect("successor");
    assert_eq!(fs::read_to_string(source).expect("source"), "native data must not change");
}

#[cfg(unix)]
#[test]
fn source_aliases_share_the_claim_and_redirected_lock_storage_is_refused() {
    use std::os::unix::fs::{symlink, PermissionsExt};
    let fixture = tempfile::tempdir().expect("fixture");
    let source = fixture.path().join("source");
    fs::create_dir(&source).expect("source");
    let alias = fixture.path().join("alias");
    symlink(&source, &alias).expect("alias");
    let claim = SessionClaim::acquire(&source, "session").expect("owner");
    assert!(matches!(SessionClaim::acquire(&alias, "session"), Err(ClaimError::Busy)));
    let path = claim_path(&source, "session").expect("path");
    assert_eq!(fs::metadata(&path).expect("metadata").permissions().mode() & 0o777, 0o600);
    drop(claim);
    fs::remove_file(&path).expect("remove only unheld fixture lock");
    let target = fixture.path().join("do-not-touch");
    fs::write(&target, "unchanged").expect("target");
    symlink(&target, &path).expect("redirected lock");
    assert!(matches!(SessionClaim::acquire(&source, "session"), Err(ClaimError::Unavailable)));
    assert_eq!(fs::read_to_string(target).expect("target"), "unchanged");
}
