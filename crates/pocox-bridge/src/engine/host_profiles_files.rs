//! Files of the host configuration store: private atomic writes, key file
//! names, the cross-process lock and unreferenced-key cleanup (see the
//! parent module docs).

use std::fs::{File, OpenOptions};
use std::path::{Path, PathBuf};

use anyhow::{anyhow, Context, Result};

fn hex(name: &str) -> String {
    name.bytes().map(|b| format!("{b:02x}")).collect()
}

/// The key file name of `name` for `generation` (`None`: the version-1
/// name, `<hex>.key`).
pub(super) fn key_file_name(name: &str, generation: Option<&str>) -> String {
    match generation {
        Some(generation) => format!("{}.{generation}.key", hex(name)),
        None => format!("{}.key", hex(name)),
    }
}

pub(super) fn key_path(root: &Path, file: &str) -> PathBuf {
    root.join("keys").join(file)
}

/// Whether `file` is one of `name`'s key file names (and nothing that could
/// leave the key directory).
pub(super) fn valid_key_ref(name: &str, file: &str) -> bool {
    let Some(rest) = file.strip_prefix(&hex(name)) else {
        return false;
    };
    match rest {
        ".key" => true,
        rest => rest
            .strip_prefix('.')
            .and_then(|r| r.strip_suffix(".key"))
            .is_some_and(|generation| uuid::Uuid::parse_str(generation).is_ok()),
    }
}

/// Create `dir` (and parents), `0700` on Unix.
pub(in crate::engine) fn private_dir(dir: &Path) -> Result<()> {
    std::fs::create_dir_all(dir).context("creating the host configuration directory")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
            .context("restricting the host configuration directory")?;
    }
    Ok(())
}

pub(in crate::engine) fn private_options() -> OpenOptions {
    let options = OpenOptions::new();
    #[cfg(unix)]
    let options = {
        use std::os::unix::fs::OpenOptionsExt as _;
        let mut options = options;
        options.mode(0o600);
        options
    };
    options
}

/// How far a successful [`write_private`] got.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(in crate::engine) enum Committed {
    /// Renamed into place and the directory synced.
    Durable,
    /// Renamed into place (readers see it), but the directory sync failed,
    /// so it may not survive a crash. Callers must treat it as committed.
    Uncertain,
}

/// Replace `file` with `bytes` atomically, `0600` on Unix. An error means
/// the file was not replaced; once the rename happened the result is
/// [`Committed`], never an error.
pub(in crate::engine) fn write_private(file: &Path, bytes: &[u8]) -> Result<Committed> {
    let dir = file
        .parent()
        .ok_or_else(|| anyhow!("no parent directory"))?;
    // A directory created here is durable only once its parent is synced.
    let created = !dir.is_dir();
    private_dir(dir)?;
    let staging = dir.join(format!(".{}.tmp", uuid::Uuid::new_v4()));
    let written = (|| -> std::io::Result<()> {
        use std::io::Write as _;
        let mut out = private_options()
            .write(true)
            .create_new(true)
            .open(&staging)?;
        out.write_all(bytes)?;
        out.sync_all()?;
        std::fs::rename(&staging, file)
    })();
    if let Err(error) = written {
        let _ = std::fs::remove_file(&staging);
        return Err(error).context("writing the host configuration");
    }
    // The rename is durable only once the directory (and a directory
    // created for it) is.
    let synced = sync_dir(dir, file).and_then(|()| match dir.parent() {
        Some(parent) if created => sync_dir(parent, dir),
        _ => Ok(()),
    });
    match synced {
        Ok(()) => Ok(Committed::Durable),
        Err(error) => {
            tracing::warn!(%error, "syncing the host configuration directory failed");
            Ok(Committed::Uncertain)
        },
    }
}

/// Sync `dir`, which holds `file` (named for the test hook).
fn sync_dir(dir: &Path, file: &Path) -> std::io::Result<()> {
    #[cfg(test)]
    if FAIL_DIR_SYNC
        .with(|f| f.get())
        .is_some_and(|fault| fault.matches(dir, file))
    {
        FAIL_DIR_SYNC.with(|f| f.set(None));
        return Err(std::io::Error::other("injected directory sync failure"));
    }
    #[cfg(not(test))]
    let _ = file;
    #[cfg(unix)]
    File::open(dir)?.sync_all()?;
    #[cfg(not(unix))]
    let _ = dir;
    Ok(())
}

/// The store's cross-process lock; released when dropped.
pub(in crate::engine) struct FileLock(File);

impl FileLock {
    pub(in crate::engine) fn acquire(root: &Path) -> Result<Self> {
        private_dir(root)?;
        let file = private_options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(root.join("profiles.lock"))
            .context("opening the host configuration lock")?;
        file.lock().context("locking the host configuration")?;
        Ok(Self(file))
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

/// Remove `name`'s key files other than those in `keep`. Callers hold the
/// store lock and read `keep` from the authoritative record file.
pub(super) fn sweep_keys(root: &Path, name: &str, keep: &[&str]) {
    let Ok(entries) = std::fs::read_dir(root.join("keys")) else { return };
    for entry in entries.flatten() {
        let Some(file) = entry.file_name().to_str().map(str::to_string) else { continue };
        if valid_key_ref(name, &file) && !keep.contains(&file.as_str()) {
            if let Err(error) = std::fs::remove_file(entry.path()) {
                tracing::warn!(%error, "removing an unused host key file failed");
            }
        }
    }
}

/// Which directory sync a test makes fail.
#[cfg(test)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(in crate::engine) enum SyncFault {
    /// The record file's directory, after `profiles.json` was renamed.
    Record,
    /// The key directory, after a key file was renamed into it.
    Key,
    /// The lifecycle ledger after its atomic rename.
    Lifecycle,
}

#[cfg(test)]
impl SyncFault {
    fn matches(self, dir: &Path, file: &Path) -> bool {
        match self {
            Self::Record => file.ends_with("profiles.json"),
            Self::Key => dir.ends_with("keys") && file.extension().is_some_and(|e| e == "key"),
            Self::Lifecycle => file.ends_with("lifecycle.json"),
        }
    }
}

/// What runs once after a read found no record file.
#[cfg(test)]
type AbsentHook = Box<dyn FnOnce(&Path)>;

#[cfg(test)]
thread_local! {
    static FAIL_COMMIT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static FAIL_DIR_SYNC: std::cell::Cell<Option<SyncFault>> = const { std::cell::Cell::new(None) };
    static AFTER_ABSENT: std::cell::RefCell<Option<AbsentHook>> =
        const { std::cell::RefCell::new(None) };
}

/// Test hook: make this thread's next record commit fail.
#[cfg(test)]
pub(super) fn fail_commit_once() {
    FAIL_COMMIT.with(|f| f.set(true));
}

/// Test hook: make this thread's next directory sync of `fault`'s kind
/// fail.
#[cfg(test)]
pub(in crate::engine) fn fail_dir_sync_once(fault: SyncFault) {
    FAIL_DIR_SYNC.with(|f| f.set(Some(fault)));
}

/// Test hook: run `then` once, on this thread, right after a read found no
/// record file (as another process committing one would).
#[cfg(test)]
pub(super) fn on_absent_check(then: impl FnOnce(&Path) + 'static) {
    AFTER_ABSENT.with(|f| *f.borrow_mut() = Some(Box::new(then)));
}

#[cfg(test)]
pub(super) fn after_absent_check(root: &Path) {
    if let Some(then) = AFTER_ABSENT.with(|f| f.borrow_mut().take()) {
        then(root);
    }
}

#[cfg(test)]
pub(super) fn fail_next_commit() -> bool {
    FAIL_COMMIT.with(|f| f.replace(false))
}
