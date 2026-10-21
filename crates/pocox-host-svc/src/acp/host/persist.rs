//! The coalescing, bounded queue of session-record writes (see the parent
//! module docs).

use super::*;

/// Pending session-record writes and flush waiters.
pub(super) type Queue = Arc<Mutex<(Pending, Vec<oneshot::Sender<()>>)>>;
/// Applies a batch of changes (blocking).
pub(super) type Apply = Arc<dyn Fn(Vec<Change>) + Send + Sync>;

/// The coalescing, bounded persistence queue (see the module docs).
pub(super) struct Persist {
    pub(super) queue: Queue,
    /// Wakes the worker; capacity one, so wake-ups coalesce too.
    pub(super) wake: mpsc::Sender<()>,
}

impl Persist {
    pub(super) fn spawn(apply: Apply) -> Self {
        let queue: Queue = Arc::default();
        let (wake, signals) = mpsc::channel(1);
        tokio::spawn(persist_loop(queue.clone(), signals, apply));
        Self {
            queue,
            wake,
        }
    }

    pub(super) fn submit(&self, change: impl FnOnce(&mut Pending)) {
        change(&mut lock(&self.queue).0);
        let _ = self.wake.try_send(());
    }

    /// Wait up to `limit` until everything submitted so far is applied.
    pub(super) async fn flush(&self, limit: Duration) -> bool {
        let (done, wait) = oneshot::channel();
        lock(&self.queue).1.push(done);
        let _ = self.wake.try_send(());
        matches!(tokio::time::timeout(limit, wait).await, Ok(Ok(())))
    }

    #[cfg(test)]
    pub(super) fn pending(&self) -> usize {
        lock(&self.queue).0.len()
    }
}

/// Apply pending writes until the queue's owner is gone. Each round takes
/// everything pending, applies it as one batch, then answers the flushes
/// that were waiting for it.
async fn persist_loop(queue: Queue, mut wake: mpsc::Receiver<()>, apply: Apply) {
    while wake.recv().await.is_some() {
        loop {
            let (changes, flushed) = {
                let mut queue = lock(&queue);
                (queue.0.take(), std::mem::take(&mut queue.1))
            };
            if changes.is_empty() && flushed.is_empty() {
                break;
            }
            if !changes.is_empty() {
                let apply = apply.clone();
                let _ = tokio::task::spawn_blocking(move || apply(changes)).await;
            }
            for done in flushed {
                let _ = done.send(());
            }
        }
    }
}
