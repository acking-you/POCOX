//! A device store whose bytes a platform adapter holds, reached across the
//! bridge.
//!
//! The store's file lock is held across each call, and the other side can stop
//! answering for good: on Android, Back at the root destroys the Flutter engine
//! while this process and its statics live on. So a wait is bounded and the
//! lock released with an error, which a reinstalled adapter can recover from.
//!
//! The call itself stays alive on a thread of its own after a timeout, because
//! dropping it would make the bridge log the answer it was carrying, and that
//! can be the secret. A write that timed out may still land, so nothing else
//! goes to this adapter until it answers: an older record arriving after a
//! newer one would replace it. That also bounds the threads a silent adapter
//! can hold to one.

use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use pocox_core::pairing::StoreBackend;

use crate::engine::runtime;

/// Longer than a keychain or a file takes, and short enough that a screen
/// waiting on it still has something to say.
const WAIT: Duration = Duration::from_secs(10);

/// A call the adapter answers later.
pub type NativeCall<T> = Pin<Box<dyn Future<Output = T> + Send>>;

/// The adapter's answer to a read: the record, or why it cannot be read.
pub type ReadAnswer = std::result::Result<Option<String>, String>;

/// Reads a slot through the adapter.
pub type ReadFn = dyn Fn(String) -> NativeCall<ReadAnswer> + Send + Sync;
/// Durably writes a slot through the adapter, answering with any failure.
pub type WriteFn = dyn Fn(String, String) -> NativeCall<Option<String>> + Send + Sync;

/// A [`StoreBackend`] over a platform adapter's calls.
pub struct NativeStore {
    read: Box<ReadFn>,
    write: Box<WriteFn>,
    wait: Duration,
    /// One call at a time, so a call still out is one that was given up on.
    turn: Mutex<()>,
    outstanding: Arc<AtomicBool>,
}

/// Marks the call answered when it ends, however it ends.
struct Answered(Arc<AtomicBool>);

impl Drop for Answered {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

impl NativeStore {
    /// A store over these calls. Neither may fail by panicking.
    pub fn new(read: Box<ReadFn>, write: Box<WriteFn>) -> Self {
        Self::with_wait(read, write, WAIT)
    }

    fn with_wait(read: Box<ReadFn>, write: Box<WriteFn>, wait: Duration) -> Self {
        Self {
            read,
            write,
            wait,
            turn: Mutex::new(()),
            outstanding: Arc::new(AtomicBool::new(false)),
        }
    }

    fn ask<T: Send + 'static>(&self, make: impl FnOnce() -> NativeCall<T>) -> Result<T> {
        let _turn = self
            .turn
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if self.outstanding.load(Ordering::SeqCst) {
            bail!("the device store has not answered an earlier request");
        }
        self.outstanding.store(true, Ordering::SeqCst);
        let answered = Answered(Arc::clone(&self.outstanding));
        let call = make();
        let (answer, answers) = mpsc::sync_channel(1);
        // Not a task: the threads that would run one may all be here, waiting on the
        // store's lock or on this very answer.
        runtime::runtime().spawn_blocking(move || {
            let _answered = answered;
            let _ = answer.send(futures::executor::block_on(call));
        });
        answers
            .recv_timeout(self.wait)
            .map_err(|_| anyhow!("the device store did not answer in time"))
    }
}

impl StoreBackend for NativeStore {
    fn read(&self, slot: &str) -> Result<Option<Vec<u8>>> {
        match self.ask(|| (self.read)(slot.to_string()))? {
            Ok(value) => Ok(value.map(String::into_bytes)),
            Err(error) => bail!("the device store cannot be read: {error}"),
        }
    }

    fn write(&self, slot: &str, bytes: &[u8]) -> Result<()> {
        let value = String::from_utf8(bytes.to_vec()).context("encoding the device store")?;
        match self.ask(|| (self.write)(slot.to_string(), value))? {
            Some(error) => bail!("the device store cannot be saved: {error}"),
            None => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::time::Instant;

    use pocox_core::pairing::{CanonicalBackend, DeviceStore, StoreKey};
    use tokio::sync::oneshot;

    use super::*;

    fn key() -> StoreKey {
        StoreKey::new(
            &CanonicalBackend::parse("https://backend.example").expect("backend"),
            "test-native",
            None,
        )
    }

    fn store(lock_root: &Path, native: NativeStore) -> DeviceStore {
        DeviceStore::with_backend(lock_root, Arc::new(native), key()).expect("store")
    }

    /// An adapter that keeps its record in memory and answers at once.
    fn working() -> NativeStore {
        let held = Arc::new(Mutex::new(None::<String>));
        let reads = Arc::clone(&held);
        NativeStore::with_wait(
            Box::new(move |_| {
                let value = reads.lock().expect("held").clone();
                Box::pin(async move { Ok(value) })
            }),
            Box::new(move |_, value| {
                *held.lock().expect("held") = Some(value);
                Box::pin(async { None })
            }),
            Duration::from_secs(5),
        )
    }

    fn never_answering(wait: Duration) -> NativeStore {
        NativeStore::with_wait(
            Box::new(|_| Box::pin(std::future::pending())),
            Box::new(|_, _| Box::pin(std::future::pending())),
            wait,
        )
    }

    fn engine_runtime() {
        runtime::init(std::env::temp_dir()).expect("runtime");
    }

    #[test]
    fn a_silent_adapter_lets_go_of_the_lock_and_a_new_one_takes_over() {
        engine_runtime();
        let root = tempfile::tempdir().expect("root");
        let silent = store(root.path(), never_answering(Duration::from_millis(100)));
        let started = Instant::now();
        let error = silent.read().expect_err("no answer");
        assert!(format!("{error:#}").contains("in time"), "{error:#}");
        assert!(started.elapsed() < Duration::from_secs(2), "the wait is bounded");
        // An error, never an empty store that would become a new device.
        assert!(silent.ensure_secret().is_err());

        // The lock was released, and the engine's next adapter just works.
        let reinstalled = store(root.path(), working());
        let created = reinstalled.ensure_secret().expect("works");
        let again = reinstalled.read().expect("read").expect("record");
        assert_eq!(created.secret(), again.secret());
    }

    #[test]
    fn nothing_overtakes_a_write_that_may_still_land() {
        engine_runtime();
        let root = tempfile::tempdir().expect("root");
        let (release, released) = oneshot::channel::<()>();
        let released = Mutex::new(Some(released));
        let native = NativeStore::with_wait(
            Box::new(|_| Box::pin(async { Ok(None) })),
            Box::new(move |_, _| {
                let released = released.lock().expect("released").take();
                Box::pin(async move {
                    if let Some(released) = released {
                        let _ = released.await;
                    }
                    None
                })
            }),
            Duration::from_millis(100),
        );
        let store = store(root.path(), native);
        store
            .ensure_secret()
            .expect_err("the write outlasts the wait");
        let error = store.read().expect_err("it is still out");
        assert!(format!("{error:#}").contains("earlier request"), "{error:#}");

        release.send(()).expect("still waiting");
        let deadline = Instant::now() + Duration::from_secs(5);
        while store.read().is_err() {
            assert!(Instant::now() < deadline, "its answer clears the way");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn a_callback_that_panics_is_an_error_and_not_a_wedged_store() {
        engine_runtime();
        let root = tempfile::tempdir().expect("root");
        let native = NativeStore::with_wait(
            Box::new(|_| Box::pin(async { panic!("a Dart exception") })),
            Box::new(|_, _| Box::pin(async { None })),
            Duration::from_secs(5),
        );
        let store = store(root.path(), native);
        let started = Instant::now();
        store.read().expect_err("no answer");
        assert!(started.elapsed() < Duration::from_secs(2), "it did not sit out the wait");
    }
}
