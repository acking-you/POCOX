//! Files that only their owner may read: relay keys, tokens, host state.
//!
//! Every crate that persists such a file starts from [`private_options`], so
//! the creation mode is decided once instead of in a `#[cfg(unix)]` block at
//! each call site.

use std::fs::OpenOptions;
use std::io::{self, Write as _};
use std::path::Path;
use std::time::Duration;

/// [`OpenOptions`] whose newly created files are `0o600` on Unix. Other
/// platforms inherit the profile directory's ACL. The caller still chooses the
/// access and creation flags; the mode only applies when a file is created.
#[must_use]
pub fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    owner_only(&mut options);
    options
}

#[cfg(unix)]
fn owner_only(options: &mut OpenOptions) {
    use std::os::unix::fs::OpenOptionsExt as _;
    options.mode(0o600);
}

#[cfg(not(unix))]
fn owner_only(_options: &mut OpenOptions) {}

/// Create `dir` private to its owner, tightening one that already exists:
/// `0700` on Unix, and on Windows an ACL naming only the owner when it is
/// created. A failure to set that ACL is logged, since the user profile's own
/// ACL still excludes other users.
pub fn private_dir(dir: &Path) -> io::Result<()> {
    let existed = dir.is_dir();
    std::fs::create_dir_all(dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let _ = existed;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    #[cfg(windows)]
    if !existed {
        restrict_to_owner(dir);
    }
    #[cfg(not(any(unix, windows)))]
    let _ = existed;
    Ok(())
}

#[cfg(windows)]
fn restrict_to_owner(dir: &Path) {
    use std::os::windows::process::CommandExt as _;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let (Ok(domain), Ok(user)) = (std::env::var("USERDOMAIN"), std::env::var("USERNAME")) else {
        tracing::warn!("cannot name this account; the directory keeps its inherited permissions");
        return;
    };
    let root = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".to_string());
    let status = std::process::Command::new(format!("{root}\\System32\\icacls.exe"))
        .arg(dir)
        .args(["/inheritance:r", "/grant:r", &format!("{domain}\\{user}:(OI)(CI)F")])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .creation_flags(CREATE_NO_WINDOW)
        .status();
    if !status.is_ok_and(|status| status.success()) {
        tracing::warn!(
            "could not restrict a private directory; it keeps its inherited permissions"
        );
    }
}

/// Atomically replace `path` with `bytes` in a private file, durable once this
/// returns. The previous contents stay whole through every failure: nothing is
/// removed ahead of the rename.
pub fn write_private_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "a file needs a directory"))?;
    let pending = parent.join(format!(".{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = private_options()
            .write(true)
            .create_new(true)
            .open(&pending)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        replace_retrying(REPLACE_ATTEMPTS, Duration::from_millis(50), || {
            std::fs::rename(&pending, path)
        })?;
        // Windows offers no directory handle to flush; its rename is journaled.
        #[cfg(unix)]
        std::fs::File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&pending);
    }
    result
}

/// Windows refuses to replace a file that a scanner or backup tool briefly has
/// open, which POSIX never does, so it gets a bounded number of tries.
const REPLACE_ATTEMPTS: u32 = if cfg!(windows) { 100 } else { 1 };

fn replace_retrying(
    attempts: u32,
    pause: Duration,
    mut rename: impl FnMut() -> io::Result<()>,
) -> io::Result<()> {
    let mut left = attempts;
    loop {
        left = left.saturating_sub(1);
        match rename() {
            Err(error) if left > 0 && is_transient_sharing_error(&error) => {
                std::thread::sleep(pause);
            },
            other => return other,
        }
    }
}

/// `ERROR_ACCESS_DENIED`, `ERROR_SHARING_VIOLATION` and `ERROR_LOCK_VIOLATION`.
fn is_transient_sharing_error(error: &io::Error) -> bool {
    error.kind() == io::ErrorKind::PermissionDenied
        || matches!(error.raw_os_error(), Some(5 | 32 | 33))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_replacement_the_system_refuses_for_a_moment_still_lands() {
        let mut tries = 0;
        replace_retrying(5, Duration::ZERO, || {
            tries += 1;
            if tries < 3 {
                Err(io::Error::from_raw_os_error(32))
            } else {
                Ok(())
            }
        })
        .expect("a passing sharing violation");
        assert_eq!(tries, 3);
        let mut tries = 0;
        replace_retrying(5, Duration::ZERO, || {
            tries += 1;
            Err(io::Error::from(io::ErrorKind::NotFound))
        })
        .expect_err("not a sharing error");
        assert_eq!(tries, 1, "only a sharing error is worth another try");
    }

    #[test]
    fn a_failed_replacement_keeps_the_old_contents_and_leaves_nothing_behind() {
        let dir = tempfile::tempdir().expect("dir");
        let path = dir.path().join("record");
        write_private_atomic(&path, b"one").expect("write");
        write_private_atomic(&path, b"two").expect("replace");
        assert_eq!(std::fs::read(&path).expect("read"), b"two");
        // A directory cannot be replaced by a file on any platform.
        let blocked = dir.path().join("blocked");
        std::fs::create_dir(&blocked).expect("directory");
        write_private_atomic(&blocked, b"three").expect_err("refused");
        let names: Vec<_> = std::fs::read_dir(dir.path())
            .expect("list")
            .map(|entry| entry.expect("entry").file_name())
            .collect();
        assert_eq!(names.len(), 2, "no temporary file stays: {names:?}");
    }

    #[test]
    fn created_files_are_private_to_their_owner() {
        let path = std::env::temp_dir().join(format!("pocox-private-{}", std::process::id()));
        let _ = std::fs::remove_file(&path);
        private_options()
            .write(true)
            .create_new(true)
            .open(&path)
            .expect("create");
        #[cfg(unix)]
        let mode = {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::metadata(&path)
                .expect("metadata")
                .permissions()
                .mode()
        };
        std::fs::remove_file(&path).expect("remove");
        #[cfg(unix)]
        assert_eq!(mode & 0o777, 0o600, "group and others get nothing");
    }
}
