//! Read-only identity checks for external session owners.

use std::{ffi::OsString, path::PathBuf};

use sysinfo::{Pid, ProcessRefreshKind, ProcessStatus, ProcessesToUpdate, System, UpdateKind};

/// A live process identity. Missing fields or an inaccessible process yield no
/// identity rather than an assumption that its session is free.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProcessIdentity {
    /// Operating-system process id.
    pub pid: u32,
    /// Process creation time in Unix seconds; use only for identity checks.
    pub started: u64,
    /// Resolved executable image, not a mutable process title.
    pub executable: PathBuf,
    /// Resolved current working directory.
    pub cwd: PathBuf,
}

/// Inspect exactly one process without signaling it or reading its environment.
pub fn process_identity(pid: u32) -> Option<ProcessIdentity> {
    let mut system = System::new();
    system.refresh_processes_specifics(
        ProcessesToUpdate::Some(&[Pid::from_u32(pid)]),
        true,
        ProcessRefreshKind::new()
            .with_exe(UpdateKind::Always)
            .with_cwd(UpdateKind::Always),
    );
    let process = system.process(Pid::from_u32(pid))?;
    if matches!(process.status(), ProcessStatus::Zombie | ProcessStatus::Dead) {
        return None;
    }
    Some(ProcessIdentity {
        pid,
        started: process.start_time(),
        executable: process.exe()?.canonicalize().ok()?,
        cwd: process.cwd()?.canonicalize().ok()?,
    })
}

/// One live process's argument list, to recognize a known server by how it
/// was started. Never its environment.
pub fn process_arguments(pid: u32) -> Option<Vec<OsString>> {
    let mut system = System::new();
    system.refresh_processes_specifics(
        ProcessesToUpdate::Some(&[Pid::from_u32(pid)]),
        true,
        ProcessRefreshKind::new().with_cmd(UpdateKind::Always),
    );
    Some(system.process(Pid::from_u32(pid))?.cmd().to_vec())
}

/// Whether the same live process still belongs to an unreplaced supervisor's
/// process tree. Missing parents or changed creation times fail closed. This
/// is an observation, not a permission to signal an arbitrary process.
pub fn is_process_descendant(pid: u32, started: u64, root: u32, root_started: u64) -> bool {
    let mut system = System::new();
    system.refresh_processes_specifics(ProcessesToUpdate::All, true, ProcessRefreshKind::new());
    let root = Pid::from_u32(root);
    let live = |process: &sysinfo::Process| {
        !matches!(process.status(), ProcessStatus::Zombie | ProcessStatus::Dead)
            && process.thread_kind().is_none()
    };
    if started == 0
        || root_started == 0
        || !system
            .process(root)
            .is_some_and(|p| live(p) && p.start_time() == root_started)
    {
        return false;
    }
    system.process(Pid::from_u32(pid)).is_some_and(|p| {
        live(p) && p.start_time() == started && super::descends(&system, p, root, root_started)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn own_identity_is_stable_and_resolves_the_actual_image() {
        let first = process_identity(std::process::id()).expect("own identity");
        assert_eq!(first, process_identity(std::process::id()).expect("same process"));
        assert_eq!(process_arguments(std::process::id()), Some(std::env::args_os().collect()));
        assert_eq!(
            first.executable,
            std::env::current_exe()
                .expect("exe")
                .canonicalize()
                .expect("path")
        );
        assert_eq!(
            first.cwd,
            std::env::current_dir()
                .expect("cwd")
                .canonicalize()
                .expect("path")
        );
        assert!(first.started > 0);
    }

    #[cfg(unix)]
    #[test]
    fn ancestry_rejects_replaced_identities_and_exited_children() {
        struct Child(std::process::Child);
        impl Drop for Child {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        let owner = process_identity(std::process::id()).expect("owner");
        let mut child = Child(
            std::process::Command::new("/bin/sleep")
                .arg("30")
                .spawn()
                .expect("child"),
        );
        let started = super::super::process_start_time(child.0.id()).expect("child identity");
        assert!(is_process_descendant(child.0.id(), started, owner.pid, owner.started));
        assert!(!is_process_descendant(child.0.id(), started + 1, owner.pid, owner.started));
        assert!(!is_process_descendant(child.0.id(), started, owner.pid, owner.started + 1));
        assert!(!is_process_descendant(owner.pid, owner.started, child.0.id(), started));
        child.0.kill().expect("kill owned fixture");
        child.0.wait().expect("reap");
        assert!(!is_process_descendant(child.0.id(), started, owner.pid, owner.started));
    }
}
