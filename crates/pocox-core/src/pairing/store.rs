//! The device store: the only durable copy of the device secret.
//!
//! One record per canonical backend, OS environment and `POCOX_DEVICE_SCOPE`,
//! under a parent private to the OS account, so the desktop app and every CLI
//! installation of one account share an identity. Every read and write holds a
//! per-record lock across processes, and no network call ever happens under it:
//! the first request is made only after the secret is durably saved, and the
//! backend treats creation as idempotent.
//!
//! An unreadable record is an error, never a new device. Nothing here deletes a
//! record: logout keeps it, and a secret is replaced only after the backend
//! said it is dead, and only if it is still the one held.

use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use anyhow::{bail, Context, Result};
use base64::Engine as _;
use rand::RngCore as _;
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};

use super::backend::CanonicalBackend;
use super::tuple::{encode_tuple, DEVICE_SECRET_PREFIX};
use crate::device::DeviceMetadata;
use crate::provider::Secret;

/// Names a store separate from the default one: two values never share a
/// secret or a hardware key, so test devices can live on one computer.
pub const DEVICE_SCOPE_ENV: &str = "POCOX_DEVICE_SCOPE";

const FILE_VERSION: u32 = 1;
const MAX_RECORD_BYTES: u64 = 64 << 10;
/// Enough for every operation a device could plausibly have open; the oldest
/// finished ones go first.
const MAX_OPERATIONS: usize = 32;

/// Holds and durably replaces a record's bytes. Files by default; a platform
/// whose secure storage is not a file supplies its own through
/// [`install_platform_store`].
pub trait StoreBackend: Send + Sync {
    /// The bytes in `slot`, `None` when there are none. Anything else that
    /// stops them being read is an error, which never becomes a new device.
    fn read(&self, slot: &str) -> Result<Option<Vec<u8>>>;

    /// Durably replace the bytes in `slot`. Returning `Ok` is the promise that
    /// they survive a crash, since the first request follows at once.
    fn write(&self, slot: &str, bytes: &[u8]) -> Result<()>;
}

/// Private files under one directory.
struct FileBackend {
    root: PathBuf,
}

impl StoreBackend for FileBackend {
    fn read(&self, slot: &str) -> Result<Option<Vec<u8>>> {
        let path = self.root.join(format!("{slot}.json"));
        let file = match File::open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error).context("opening the device store"),
        };
        let mut bytes = Vec::new();
        std::io::Read::read_to_end(
            &mut std::io::Read::take(file, MAX_RECORD_BYTES + 1),
            &mut bytes,
        )
        .context("reading the device store")?;
        Ok(Some(bytes))
    }

    fn write(&self, slot: &str, bytes: &[u8]) -> Result<()> {
        crate::fs::write_private_atomic(&self.root.join(format!("{slot}.json")), bytes)
            .context("saving the device store")
    }
}

/// A platform's own secure storage, installed once at startup.
#[derive(Clone)]
struct Platform {
    lock_root: PathBuf,
    backend: Arc<dyn StoreBackend>,
}

static PLATFORM: Mutex<Option<Platform>> = Mutex::new(None);

/// Keep the device store in `backend` for the rest of this process, with its
/// lock files under `lock_root`, which must be private to the app. Mobile
/// platforms call this before any pairing call; desktops never need it.
pub fn install_platform_store(lock_root: PathBuf, backend: Arc<dyn StoreBackend>) {
    *PLATFORM.lock().unwrap_or_else(|poison| poison.into_inner()) = Some(Platform {
        lock_root,
        backend,
    });
}

/// Whether this platform's device store can hold anything yet, without creating
/// it: what a process checks before it has any reason to make one.
pub fn device_store_exists() -> bool {
    let installed = PLATFORM
        .lock()
        .unwrap_or_else(|poison| poison.into_inner())
        .is_some();
    installed || crate::paths::device_store_dir().is_ok_and(|root| root.is_dir())
}

/// Which record a process uses.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct StoreKey {
    backend: String,
    environment: String,
    scope: Option<String>,
}

impl StoreKey {
    /// The key for `backend` in `environment` and `scope`.
    pub fn new(backend: &CanonicalBackend, environment: &str, scope: Option<String>) -> Self {
        Self {
            backend: backend.as_str().to_string(),
            environment: environment.to_string(),
            scope: scope.filter(|scope| !scope.is_empty()),
        }
    }

    /// The key this process uses for `backend`: its own OS environment and
    /// [`DEVICE_SCOPE_ENV`].
    pub fn current(backend: &CanonicalBackend) -> Self {
        let metadata = DeviceMetadata::current();
        let environment =
            format!("{}-{}", metadata.os, metadata.environment.as_deref().unwrap_or("native"));
        let scope = std::env::var(DEVICE_SCOPE_ENV)
            .ok()
            .map(|scope| scope.trim().to_string());
        Self::new(backend, &environment, scope)
    }

    /// The canonical backend this key is for.
    pub fn backend(&self) -> &str {
        &self.backend
    }

    /// The OS environment.
    pub fn environment(&self) -> &str {
        &self.environment
    }

    /// The explicit device scope.
    pub fn scope(&self) -> Option<&str> {
        self.scope.as_deref()
    }

    /// The opaque name of this key's record, safe for a file or a keychain
    /// account.
    pub fn slot(&self) -> String {
        let encoded = encode_tuple(&[
            b"pocox.device-store.v1",
            self.backend.as_bytes(),
            self.environment.as_bytes(),
            self.scope().unwrap_or_default().as_bytes(),
        ]);
        let digest = Sha256::digest(&encoded);
        digest[..20]
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }
}

/// The session an installation last saw for this identity, which tells another
/// installation its own JWT may be out of date. Holds nothing that authorizes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionMark {
    /// The device's id.
    pub device_id: String,
    /// The session generation.
    pub generation: i64,
}

/// What an installation's active account was when it started an operation, so
/// a result arriving later is never applied over a different account.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActiveAccount {
    /// `[account].provider`.
    #[serde(default)]
    pub provider: Option<String>,
    /// `[account].account_id`.
    #[serde(default)]
    pub account_id: Option<String>,
    /// `[account].login`.
    #[serde(default)]
    pub login: Option<String>,
}

/// What a durable operation does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OperationKind {
    /// Move this device into another group.
    Link,
    /// Move this device out of its group.
    Leave,
    /// Move another device out of this group.
    Remove,
    /// Take over a previous device's identity, with an overlap.
    Restore,
    /// Take over a compromised device's identity, with no overlap.
    Retake,
}

/// How far an operation has reached locally.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OperationState {
    /// Sent, or about to be; its result is not known yet.
    Pending,
    /// The backend committed it; local configuration has yet to catch up.
    Completed,
    /// It did not happen. Kept a while, so whoever started it can still hear
    /// why after another process read the result.
    Failed,
}

/// A membership change whose identity outlives a lost response or a restart.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StoredOperation {
    /// The id sent to the backend.
    pub id: String,
    /// What it does.
    pub kind: OperationKind,
    /// Which installation started it (a digest of its support directory).
    pub initiator: String,
    /// That installation's active account at the time.
    pub active_before: ActiveAccount,
    /// When it started (unix seconds).
    pub started_at: i64,
    /// How far it has reached.
    pub state: OperationState,
    /// Why it failed: the backend's code.
    #[serde(default)]
    pub error: Option<String>,
}

/// A device's record: its secret and the work it has outstanding.
#[derive(Clone)]
pub struct DeviceRecord {
    secret: Secret,
    /// Whether the backend has acknowledged this secret. Until it has, creating
    /// is the idempotent retry; afterward an unknown secret stays unknown.
    pub registered: bool,
    /// The session an installation last saw.
    pub session: Option<SessionMark>,
    /// Operations not yet caught up with.
    pub operations: Vec<StoredOperation>,
}

impl std::fmt::Debug for DeviceRecord {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DeviceRecord")
            .field("registered", &self.registered)
            .field("session", &self.session)
            .field("operations", &self.operations)
            .finish_non_exhaustive()
    }
}

impl DeviceRecord {
    /// The device secret.
    pub fn secret(&self) -> &str {
        self.secret.expose()
    }
}

#[derive(Serialize, Deserialize)]
struct OnDisk {
    version: u32,
    secret: String,
    #[serde(default)]
    registered: bool,
    #[serde(default)]
    session: Option<SessionMark>,
    #[serde(default)]
    operations: Vec<StoredOperation>,
}

/// A device secret: the prefix plus 32 random bytes in unpadded base64url.
pub fn generate_secret() -> Secret {
    let mut bytes = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    let body = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes);
    Secret::new(format!("{DEVICE_SECRET_PREFIX}{body}"))
}

/// Whether `secret` has the shape of a device secret.
pub fn secret_is_well_formed(secret: &str) -> bool {
    secret
        .strip_prefix(DEVICE_SECRET_PREFIX)
        .is_some_and(|body| {
            base64::engine::general_purpose::URL_SAFE_NO_PAD
                .decode(body)
                .is_ok_and(|bytes| bytes.len() == 32)
        })
}

fn decode(bytes: &[u8]) -> Result<DeviceRecord> {
    if bytes.len() as u64 > MAX_RECORD_BYTES {
        bail!("the device store cannot be read: it is too large");
    }
    // Parse errors can quote the input, which holds the secret.
    let disk: OnDisk = serde_json::from_slice(bytes)
        .map_err(|_| anyhow::anyhow!("the device store cannot be read: it is damaged"))?;
    if disk.version != FILE_VERSION {
        bail!("the device store cannot be read: it has unsupported version {}", disk.version);
    }
    if !secret_is_well_formed(&disk.secret) {
        bail!("the device store cannot be read: it holds no valid secret");
    }
    Ok(DeviceRecord {
        secret: Secret::new(disk.secret),
        registered: disk.registered,
        session: disk.session,
        operations: disk.operations,
    })
}

fn encode(record: &DeviceRecord) -> Result<Vec<u8>> {
    serde_json::to_vec(&OnDisk {
        version: FILE_VERSION,
        secret: record.secret.expose().to_string(),
        registered: record.registered,
        session: record.session.clone(),
        operations: record.operations.clone(),
    })
    .context("encoding the device store")
}

/// Holds a record's lock until dropped.
struct Locked(File);

impl Drop for Locked {
    fn drop(&mut self) {
        // At once rather than on close, which Windows may delay.
        let _ = self.0.unlock();
    }
}

/// One record of the device store.
#[derive(Clone)]
pub struct DeviceStore {
    key: StoreKey,
    lock_path: PathBuf,
    backend: Arc<dyn StoreBackend>,
}

impl std::fmt::Debug for DeviceStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DeviceStore")
            .field("key", &self.key)
            .finish_non_exhaustive()
    }
}

impl DeviceStore {
    /// The record for `key` in this platform's device store.
    pub fn open(key: StoreKey) -> Result<Self> {
        let platform = PLATFORM
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .clone();
        if let Some(platform) = platform {
            return Self::with_backend(&platform.lock_root, platform.backend, key);
        }
        if cfg!(any(target_os = "ios", target_os = "android")) {
            // The default directory would be inside what these platforms back up.
            bail!("this platform's device store is not installed");
        }
        let root = crate::paths::device_store_dir()?;
        let new = !root.is_dir();
        let store = Self::at(&root, key)?;
        if new {
            exclude_from_backup(&root);
        }
        Ok(store)
    }

    /// The record for `key` in private files under `root`.
    pub fn at(root: &Path, key: StoreKey) -> Result<Self> {
        crate::fs::private_dir(root).context("preparing the device store")?;
        let backend = Arc::new(FileBackend {
            root: root.to_path_buf(),
        });
        Self::with_backend(root, backend, key)
    }

    /// The record for `key` in `backend`, locked under `lock_root`.
    pub fn with_backend(
        lock_root: &Path,
        backend: Arc<dyn StoreBackend>,
        key: StoreKey,
    ) -> Result<Self> {
        crate::fs::private_dir(lock_root).context("preparing the device store")?;
        Ok(Self {
            lock_path: lock_root.join(format!("{}.lock", key.slot())),
            key,
            backend,
        })
    }

    /// Which record this is.
    pub fn key(&self) -> &StoreKey {
        &self.key
    }

    fn lock(&self) -> Result<Locked> {
        let file = crate::fs::private_options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&self.lock_path)
            .context("opening the device store's lock")?;
        file.lock().context("locking the device store")?;
        Ok(Locked(file))
    }

    fn load(&self) -> Result<Option<DeviceRecord>> {
        self.backend
            .read(&self.key.slot())?
            .map(|bytes| decode(&bytes))
            .transpose()
    }

    fn save(&self, record: &DeviceRecord) -> Result<()> {
        self.backend.write(&self.key.slot(), &encode(record)?)
    }

    /// The record, or `None` when this device has no secret here.
    pub fn read(&self) -> Result<Option<DeviceRecord>> {
        let _lock = self.lock()?;
        self.load()
    }

    /// The record, creating a secret when there is none. Saved before this
    /// returns, so a first request can retry with the same secret after any
    /// failure, and concurrent processes end with one secret.
    pub fn ensure_secret(&self) -> Result<DeviceRecord> {
        let _lock = self.lock()?;
        if let Some(record) = self.load()? {
            return Ok(record);
        }
        let record = new_record();
        self.save(&record)?;
        Ok(record)
    }

    /// Replace `dead`, which the backend said is superseded or unknown, with a
    /// new unregistered secret. If another process already replaced it, keep
    /// that one, so nothing here can discard a live identity.
    pub fn replace_dead_secret(&self, dead: &str) -> Result<DeviceRecord> {
        let _lock = self.lock()?;
        let record = match self.load()? {
            Some(record) if record.secret() != dead => return Ok(record),
            _ => new_record(),
        };
        self.save(&record)?;
        Ok(record)
    }

    /// Change the record under its lock, saving only when it changed. `None`
    /// when there is no record to change.
    pub fn update<T>(&self, change: impl FnOnce(&mut DeviceRecord) -> T) -> Result<Option<T>> {
        let _lock = self.lock()?;
        let Some(mut record) = self.load()? else {
            return Ok(None);
        };
        let before = encode(&record)?;
        let result = change(&mut record);
        prune(&mut record);
        if encode(&record)? != before {
            self.save(&record)?;
        }
        Ok(Some(result))
    }
}

/// A restored backup on another computer would be a clone of this bearer
/// identity. Time Machine is the one desktop backup with a standard way to opt
/// out; a failure leaves the store where any other home directory backup would
/// find it.
fn exclude_from_backup(root: &Path) {
    #[cfg(target_os = "macos")]
    {
        let root = root.to_string_lossy();
        if super::hint::tools::run("/usr/bin/tmutil", &["addexclusion", &root]).is_err() {
            tracing::debug!("the device store could not be excluded from Time Machine");
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = root;
}

fn new_record() -> DeviceRecord {
    DeviceRecord {
        secret: generate_secret(),
        registered: false,
        session: None,
        operations: Vec::new(),
    }
}

/// Keep the list bounded, giving up finished operations before open ones.
fn prune(record: &mut DeviceRecord) {
    while record.operations.len() > MAX_OPERATIONS {
        let oldest = record
            .operations
            .iter()
            .position(|operation| operation.state != OperationState::Pending)
            .unwrap_or(0);
        record.operations.remove(oldest);
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;
    use std::process::Command;

    use super::*;

    fn key(scope: Option<&str>) -> StoreKey {
        StoreKey::new(
            &CanonicalBackend::parse("https://backend.example").expect("backend"),
            "macos-native",
            scope.map(str::to_string),
        )
    }

    fn file_of(root: &Path, key: &StoreKey) -> PathBuf {
        root.join(format!("{}.json", key.slot()))
    }

    /// Run in a child process by the test below: creates once and reports the
    /// secret it got.
    #[test]
    fn child_process_creating_a_secret() {
        let Ok(root) = std::env::var("POCOX_TEST_STORE_ROOT") else {
            return;
        };
        let report = std::env::var("POCOX_TEST_STORE_REPORT").expect("report path");
        let store = DeviceStore::at(Path::new(&root), key(None)).expect("store");
        let record = store.ensure_secret().expect("ensure");
        std::fs::write(report, record.secret()).expect("report");
    }

    #[test]
    fn processes_creating_at_once_end_with_one_secret() {
        let root = tempfile::tempdir().expect("root");
        let exe = std::env::current_exe().expect("test binary");
        let children: Vec<_> = (0..6)
            .map(|index| {
                let report = root.path().join(format!("report-{index}"));
                let child = Command::new(&exe)
                    .args(["--exact", "pairing::store::tests::child_process_creating_a_secret"])
                    .env("POCOX_TEST_STORE_ROOT", root.path().join("store"))
                    .env("POCOX_TEST_STORE_REPORT", &report)
                    .stdout(std::process::Stdio::null())
                    .spawn()
                    .expect("child");
                (child, report)
            })
            .collect();
        let mut secrets = HashSet::new();
        for (mut child, report) in children {
            assert!(child.wait().expect("wait").success());
            secrets.insert(std::fs::read_to_string(report).expect("report"));
        }
        assert_eq!(secrets.len(), 1, "every process holds the one saved secret");
        let saved = DeviceStore::at(&root.path().join("store"), key(None))
            .expect("store")
            .read()
            .expect("read")
            .expect("record");
        assert!(secrets.contains(saved.secret()));
    }

    #[test]
    fn explicit_scopes_never_share_a_secret() {
        let root = tempfile::tempdir().expect("root");
        let secret = |scope: Option<&str>| {
            DeviceStore::at(root.path(), key(scope))
                .expect("store")
                .ensure_secret()
                .expect("ensure")
                .secret()
                .to_string()
        };
        let plain = secret(None);
        let one = secret(Some("one"));
        let two = secret(Some("two"));
        assert_ne!(plain, one);
        assert_ne!(one, two);
        assert_eq!(one, secret(Some("one")), "a scope keeps its secret");
    }

    #[test]
    fn a_damaged_store_is_an_error_and_is_left_alone() {
        let root = tempfile::tempdir().expect("root");
        let store = DeviceStore::at(root.path(), key(None)).expect("store");
        let path = file_of(root.path(), store.key());
        for damaged in [
            b"not json".to_vec(),
            br#"{"version":99,"secret":"x"}"#.to_vec(),
            br#"{"version":1,"secret":"pcxd1_short"}"#.to_vec(),
            vec![b'x'; (MAX_RECORD_BYTES + 2) as usize],
        ] {
            std::fs::write(&path, &damaged).expect("damage");
            let error = store.ensure_secret().expect_err("never a new device");
            assert!(!format!("{error:#}").contains("pcxd1_short"), "errors quote nothing");
            assert!(store.read().is_err());
            assert!(store.update(|_| ()).is_err());
            assert_eq!(std::fs::read(&path).expect("kept"), damaged, "kept for a repair");
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_store_it_may_not_read_is_an_error_and_files_are_private() {
        use std::os::unix::fs::PermissionsExt as _;

        let root = tempfile::tempdir().expect("root");
        let store = DeviceStore::at(&root.path().join("store"), key(None)).expect("store");
        store.ensure_secret().expect("ensure");
        let path = file_of(&root.path().join("store"), store.key());
        let mode = |path: &Path| {
            std::fs::metadata(path)
                .expect("metadata")
                .permissions()
                .mode()
                & 0o777
        };
        assert_eq!(mode(&path), 0o600);
        assert_eq!(mode(&root.path().join("store")), 0o700);
        // A directory in its place fails like any other unreadable store, also
        // for a process with the privileges to ignore file modes.
        std::fs::remove_file(&path).expect("remove");
        std::fs::create_dir(&path).expect("directory");
        assert!(store.ensure_secret().is_err(), "never a new device");
    }

    #[test]
    fn a_dead_secret_is_replaced_once_and_a_live_one_never() {
        let root = tempfile::tempdir().expect("root");
        let store = DeviceStore::at(root.path(), key(None)).expect("store");
        let first = store.ensure_secret().expect("ensure").secret().to_string();
        store
            .update(|record| record.registered = true)
            .expect("update");
        let second = store.replace_dead_secret(&first).expect("replace");
        assert_ne!(second.secret(), first);
        assert!(!second.registered, "a new secret starts unregistered");
        let again = store
            .replace_dead_secret(&first)
            .expect("another process replacing the same dead secret");
        assert_eq!(again.secret(), second.secret(), "the live secret stays");
    }

    #[test]
    fn updates_survive_reopening_and_stay_bounded() {
        let root = tempfile::tempdir().expect("root");
        let store = DeviceStore::at(root.path(), key(None)).expect("store");
        assert_eq!(store.update(|_| 1).expect("update"), None, "no record to change");
        store.ensure_secret().expect("ensure");
        let operation = |id: String, state| StoredOperation {
            error: None,
            id,
            kind: OperationKind::Link,
            initiator: "here".into(),
            active_before: ActiveAccount::default(),
            started_at: 1,
            state,
        };
        store
            .update(|record| {
                record
                    .operations
                    .push(operation("open".into(), OperationState::Pending));
                for index in 0..MAX_OPERATIONS + 4 {
                    record
                        .operations
                        .push(operation(format!("done-{index}"), OperationState::Completed));
                }
            })
            .expect("update");
        let reopened = DeviceStore::at(root.path(), key(None)).expect("store");
        let record = reopened.read().expect("read").expect("record");
        assert_eq!(record.operations.len(), MAX_OPERATIONS);
        assert!(record
            .operations
            .iter()
            .any(|operation| operation.id == "open"));
    }

    #[test]
    fn a_platform_backend_holds_the_only_copy_outside_its_lock_directory() {
        #[derive(Default)]
        struct Memory(Mutex<std::collections::HashMap<String, Vec<u8>>>);
        impl StoreBackend for Memory {
            fn read(&self, slot: &str) -> Result<Option<Vec<u8>>> {
                Ok(self.0.lock().expect("memory").get(slot).cloned())
            }

            fn write(&self, slot: &str, bytes: &[u8]) -> Result<()> {
                self.0
                    .lock()
                    .expect("memory")
                    .insert(slot.into(), bytes.to_vec());
                Ok(())
            }
        }
        let locks = tempfile::tempdir().expect("locks");
        let memory = Arc::new(Memory::default());
        let store =
            DeviceStore::with_backend(locks.path(), memory.clone(), key(None)).expect("store");
        let secret = store.ensure_secret().expect("ensure").secret().to_string();
        for entry in std::fs::read_dir(locks.path()).expect("list") {
            let bytes = std::fs::read(entry.expect("entry").path()).expect("read");
            assert!(!String::from_utf8_lossy(&bytes).contains(&secret));
        }
        let again = DeviceStore::with_backend(locks.path(), memory, key(None)).expect("store");
        assert_eq!(again.read().expect("read").expect("record").secret(), secret);
    }

    #[test]
    fn neither_debug_form_prints_the_secret() {
        let root = tempfile::tempdir().expect("root");
        let store = DeviceStore::at(root.path(), key(None)).expect("store");
        let record = store.ensure_secret().expect("ensure");
        assert!(secret_is_well_formed(record.secret()));
        assert!(!format!("{record:?} {store:?}").contains(DEVICE_SECRET_PREFIX));
    }
}
