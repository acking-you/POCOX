//! Durable restore overrides for remotely managed hosts. A stop intent is
//! committed before stopping its child, so an app crash cannot resurrect it
//! from stale controller preferences. Flutter reads these overrides before
//! planning restores; a local start replaces its name's previous stop intent.

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

use super::{
    host_names,
    host_profiles::{
        self,
        files::{write_private, Committed, FileLock},
        Runtime,
    },
};

/// Last explicit lifecycle choice for one host (local persistence only).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    /// Monotonic file revision at which this entry changed.
    pub revision: u64,
    /// Runtime to restore; `None` suppresses any old Flutter restore record.
    pub runtime: Option<Runtime>,
}

#[derive(Serialize, Deserialize)]
struct Ledger {
    version: u32,
    revision: u64,
    entries: BTreeMap<String, Entry>,
}

fn read(root: &Path) -> Result<Ledger> {
    let bytes = match std::fs::read(root.join("lifecycle.json")) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Ledger {
                version: 1,
                revision: 0,
                entries: BTreeMap::new(),
            })
        },
        Err(e) => return Err(e).context("reading host restore choices"),
    };
    let ledger: Ledger = serde_json::from_slice(&bytes).context("reading host restore choices")?;
    if ledger.version != 1 {
        bail!("unsupported host restore choices version; automatic restore is unavailable");
    }
    Ok(ledger)
}

/// Current persisted overrides. A read failure must block automatic restore,
/// never fall back to stale controller records.
pub fn entries() -> Result<BTreeMap<String, Entry>> {
    entries_in(&host_profiles::root()?)
}

fn entries_in(root: &Path) -> Result<BTreeMap<String, Entry>> {
    // Writers atomically replace the complete file, so readers need no lock.
    Ok(read(root)?.entries)
}

fn warnings() -> &'static Mutex<BTreeMap<(PathBuf, String), String>> {
    static WARNINGS: OnceLock<Mutex<BTreeMap<(PathBuf, String), String>>> = OnceLock::new();
    WARNINGS.get_or_init(Mutex::default)
}

/// A successful process operation may still need its restart choice repaired.
/// Keep that separate from the operation result, and never expose disk errors.
pub fn problem(name: Option<&str>) -> Result<Option<String>> {
    let root = host_profiles::root()?;
    if read(&root).is_err() {
        return Ok(Some(
            "Automatic restore is unavailable because its saved state cannot be read. The running \
             service is unaffected."
                .into(),
        ));
    }
    let name = name.map(host_names::canonical).transpose()?;
    Ok(warnings()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .iter()
        .find(|((directory, host), _)| {
            directory == &root && name.as_ref().is_none_or(|name| name == host)
        })
        .map(|(_, problem)| problem.clone()))
}

/// Record a completed start/apply without turning a running service into a
/// false failure. The status editor exposes the separate restart warning.
pub(super) fn record_running_in(root: &Path, name: &str, runtime: Runtime) {
    if let Err(error) = record_in(root, name, Some(runtime)) {
        tracing::warn!(%error, "service is running but its automatic restore choice was not saved");
        warnings().lock().unwrap_or_else(|p| p.into_inner()).insert(
            (root.to_owned(), host_names::canonical(name).unwrap_or_else(|_| name.into())),
            "The service is running, but its automatic restore choice could not be saved. Check \
             the host's storage before restarting the app."
                .into(),
        );
    }
}

/// Show a failed boot restore beside its host, to every controller, until the
/// next start or stop records a choice. The cause stays in the local log.
pub(super) fn record_restore_failure(name: &str) {
    let Ok(root) = host_profiles::root() else {
        return;
    };
    warnings().lock().unwrap_or_else(|p| p.into_inner()).insert(
        (root, host_names::canonical(name).unwrap_or_else(|_| name.into())),
        "This service could not be restored when the host started. Start it again; the host's log \
         has the cause."
            .into(),
    );
}

/// A corrupt ledger already disables every automatic restore. It must not
/// prevent stopping a live process. For a readable ledger, refusing a failed
/// write is necessary: its old start choice could otherwise resurrect it.
pub(super) fn record_stop_in(root: &Path, name: &str) -> Result<()> {
    match record_in(root, name, None) {
        Ok(_) => Ok(()),
        Err(error) if read(root).is_err() => {
            tracing::warn!(%error, "stopping service with automatic restore disabled by unreadable state");
            Ok(())
        },
        Err(error) => Err(error)
            .context("the service is still running because its stop preference could not be saved"),
    }
}

/// Revalidate the exact boot-time restore choice. None permits only an old
/// Flutter record that still has no newer local/remote override.
fn restore_choice(root: &Path, name: &str, expected: Option<u64>) -> Result<Option<Runtime>> {
    let ledger = read(root)?;
    let entry = ledger.entries.get(&host_names::canonical(name)?);
    match (entry, expected) {
        (None, None) => Ok(None),
        (Some(entry), Some(revision)) if entry.revision == revision => entry
            .runtime
            .clone()
            .map(Some)
            .context("this service was stopped; automatic restore was skipped"),
        _ => bail!("host restore choice changed; automatic restore was skipped"),
    }
}

/// Restore an observed choice under the normal lifecycle lease. A stop from
/// another controller after the boot snapshot prevents this queued restore.
/// Legacy runtime is accepted only locally and only in the absence of any
/// authoritative lifecycle record; remote HTTP never accepts it.
pub fn restore(name: &str, expected: Option<u64>, legacy: Option<Runtime>) -> Result<()> {
    use super::host_profiles::{Change, KeyChange, ProfileInput, RuntimeChange};
    let root = host_profiles::root()?;
    let choice = restore_choice(&root, name, expected)?;
    let saved = host_profiles::get_in(&root, name)?;
    if saved.problem.is_some() {
        bail!("saved host configuration is unavailable; automatic restore was skipped");
    }
    let runtime = saved
        .runtime
        .clone()
        .or(choice)
        .or(legacy)
        .context("no runtime to restore")?;
    super::host_start::start_configured_checked(
        Some(name),
        runtime,
        Change {
            input: ProfileInput {
                source: saved.source,
                protocol: saved.protocol,
                base_url: saved.base_url,
                model: saved.model,
                claude_env: None,
            },
            key: KeyChange::Keep,
            runtime: RuntimeChange::Keep,
        },
        Some(saved.revision),
        &|| restore_choice(&root, name, expected).map(drop),
    )?;
    super::management::enable_after_hosting();
    Ok(())
}

/// Persist one choice while the caller holds the host's lifecycle lease.
/// A failure before commit prevents the caller's destructive operation. A
/// committed record with uncertain durability permits it, with a warning.
pub(super) fn record_in(root: &Path, name: &str, runtime: Option<Runtime>) -> Result<Entry> {
    let name = host_names::canonical(name)?;
    let _lock = FileLock::acquire(root)?;
    let mut ledger = read(root)?;
    ledger.revision = ledger
        .revision
        .checked_add(1)
        .context("host restore revision exhausted")?;
    let entry = Entry {
        revision: ledger.revision,
        runtime,
    };
    ledger.entries.insert(name.clone(), entry.clone());
    let committed = write_private(&root.join("lifecycle.json"), &serde_json::to_vec(&ledger)?)?;
    let key = (root.to_owned(), name);
    let mut warnings = warnings().lock().unwrap_or_else(|p| p.into_inner());
    match committed {
        Committed::Durable => {
            warnings.remove(&key);
        },
        Committed::Uncertain => {
            warnings.insert(
                key,
                "The automatic restore choice was saved, but may not survive a system crash. \
                 Check the host's storage."
                    .into(),
            );
        },
    }
    Ok(entry)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stop_is_durable_and_only_a_later_start_of_its_name_replaces_it() {
        let root = tempfile::tempdir().expect("temp");
        let runtime = Runtime::OpenCode {
            binary: None,
            separate_history: false,
        };
        // A legacy record without an override restores; a remote stop blocks it.
        assert!(restore_choice(root.path(), "old-pref", None)
            .expect("legacy")
            .is_none());
        record_in(root.path(), "old-pref", None).expect("remote stop");
        assert!(restore_choice(root.path(), "old-pref", None).is_err());
        record_in(root.path(), "Other", Some(runtime.clone())).expect("other start");
        let start = record_in(root.path(), "My Host", Some(runtime.clone())).expect("start");
        assert_eq!(
            restore_choice(root.path(), "my-host", Some(start.revision)).expect("current"),
            Some(runtime.clone())
        );
        let stopped = record_in(root.path(), "my-host", None).expect("stop before effect");
        // A boot snapshot from before the stop, or of the stop, restores nothing.
        assert!(restore_choice(root.path(), "my-host", Some(start.revision)).is_err());
        assert!(restore_choice(root.path(), "my-host", Some(stopped.revision)).is_err());
        // Simulate a crash before the caller stopped its child or wrote UI prefs.
        let reopened = entries_in(root.path()).expect("reopen");
        assert_eq!(reopened["my-host"], stopped);
        assert_eq!(reopened["other"].runtime, Some(runtime.clone()));
        let started = record_in(root.path(), "MY HOST", Some(runtime)).expect("local restart");
        assert!(started.revision > stopped.revision);
        assert_eq!(entries_in(root.path()).expect("read")["my-host"], started);
    }

    #[test]
    fn concurrent_writers_preserve_other_hosts() {
        let root = tempfile::tempdir().expect("tempdir");
        std::thread::scope(|scope| {
            for n in 0..8 {
                let root = root.path();
                scope.spawn(move || record_in(root, &format!("host-{n}"), None).expect("record"));
            }
        });
        let entries = entries_in(root.path()).expect("read");
        assert_eq!(entries.len(), 8);
        assert_eq!(entries.values().map(|e| e.revision).max(), Some(8));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(root.path().join("lifecycle.json"))
                    .expect("metadata")
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn corrupt_ledger_never_allows_fallback_or_overwrite() {
        let root = tempfile::tempdir().expect("tempdir");
        let path = root.path().join("lifecycle.json");
        std::fs::write(&path, b"broken").expect("write");
        assert!(entries_in(root.path()).is_err());
        assert!(record_in(root.path(), "stop", None).is_err());
        assert!(record_stop_in(root.path(), "stop").is_ok());
        record_running_in(root.path(), "manual-start", Runtime::OpenCode {
            binary: None,
            separate_history: false,
        });
        assert!(restore_choice(root.path(), "manual-start", None).is_err());
        assert_eq!(std::fs::read(path).expect("unchanged"), b"broken");
    }

    #[test]
    fn committed_stop_allows_cleanup_even_when_directory_sync_fails() {
        use host_profiles::files::{fail_dir_sync_once, SyncFault};
        let root = tempfile::tempdir().expect("temp");
        record_in(
            root.path(),
            "running",
            Some(Runtime::OpenCode {
                binary: None,
                separate_history: false,
            }),
        )
        .expect("start");
        fail_dir_sync_once(SyncFault::Lifecycle);
        record_stop_in(root.path(), "running").expect("committed stop permits child cleanup");
        assert!(entries_in(root.path()).expect("read")["running"]
            .runtime
            .is_none());
        let key = (root.path().to_owned(), "running".into());
        assert!(warnings().lock().expect("lock").contains_key(&key));
        // A later durable choice clears only this host's warning.
        record_stop_in(root.path(), "running").expect("durable");
        assert!(!warnings().lock().expect("lock").contains_key(&key));
        fail_dir_sync_once(SyncFault::Lifecycle);
        record_running_in(root.path(), "running", Runtime::OpenCode {
            binary: None,
            separate_history: false,
        });
        assert!(entries_in(root.path()).expect("read")["running"]
            .runtime
            .is_some());
        assert!(warnings().lock().expect("lock").contains_key(&key));
    }
}
