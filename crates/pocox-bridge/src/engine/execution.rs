//! Admission and execution of blocking engine calls made by async bridge APIs.
//!
//! Network waits must not occupy FRB's CPU-sized pool. Separate budgets keep
//! background discovery and file transfers from delaying session controls.
use std::sync::Arc;

use anyhow::{anyhow, Result};
use once_cell::sync::Lazy;
use tokio::{runtime::Handle, sync::Semaphore};

use super::{runtime, transport};

/// Work classes with independent running and queued budgets.
#[derive(Clone, Copy)]
pub enum Lane {
    /// User actions, including sending, approvals and stopping a turn.
    Control,
    /// Foreground session and filesystem reads.
    Read,
    /// Discovery, reachability probes and speculative history reads.
    Background,
    /// Large uploads and downloads.
    Transfer,
    /// Image processing and other CPU-heavy transformations.
    Cpu,
}

struct Queue {
    active: Arc<Semaphore>,
    admitted: Arc<Semaphore>,
}

impl Queue {
    fn new(active: usize, pending: usize) -> Self {
        Self {
            active: Arc::new(Semaphore::new(active)),
            admitted: Arc::new(Semaphore::new(active + pending)),
        }
    }

    async fn run<T: Send + 'static>(
        &self,
        handle: &Handle,
        work: impl FnOnce() -> Result<T> + Send + 'static,
    ) -> Result<T> {
        // Reject before starting any side effect. Dropping a queued future
        // releases admission; started operations finish exactly once.
        let admitted = self
            .admitted
            .clone()
            .try_acquire_owned()
            .map_err(|_| anyhow!("native work queue is full; retry the operation"))?;
        let active = self.active.clone().acquire_owned().await?;
        handle
            .spawn_blocking(move || {
                let (_admitted, _active) = (admitted, active);
                work()
            })
            .await?
    }
}

static CONTROL: Lazy<Queue> = Lazy::new(|| Queue::new(8, 24));
static READ: Lazy<Queue> = Lazy::new(|| Queue::new(8, 24));
static BACKGROUND: Lazy<Queue> = Lazy::new(|| Queue::new(3, 45));
static TRANSFER: Lazy<Queue> = Lazy::new(|| Queue::new(2, 6));
static CPU: Lazy<Queue> = Lazy::new(|| Queue::new(2, 6));

/// Run a synchronous engine operation outside FRB and Tokio async workers.
/// Queued work is refused if its account/relay changed before it could start.
pub async fn run<T: Send + 'static>(
    lane: Lane,
    work: impl FnOnce() -> Result<T> + Send + 'static,
) -> Result<T> {
    let epoch = transport::epoch();
    let queue = match lane {
        Lane::Control => &CONTROL,
        Lane::Read => &READ,
        Lane::Background => &BACKGROUND,
        Lane::Transfer => &TRANSFER,
        Lane::Cpu => &CPU,
    };
    let handle = Handle::try_current().unwrap_or_else(|_| runtime::runtime().handle().clone());
    queue
        .run(&handle, move || {
            anyhow::ensure!(
                transport::is_current(epoch),
                "connection context changed; retry the operation"
            );
            work()
        })
        .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn saturated_background_does_not_block_control_and_cancel_releases_admission() {
        let background = Queue::new(1, 1);
        let control = Queue::new(1, 0);
        let occupied = background.active.clone().acquire_owned().await.unwrap();
        let handle = Handle::current();
        let mut queued = Box::pin(background.run(&handle, || Ok(())));
        assert!(futures::poll!(&mut queued).is_pending());
        let extra = background.admitted.clone().try_acquire_owned().unwrap();
        assert!(background.run(&Handle::current(), || Ok(())).await.is_err());
        assert_eq!(control.run(&Handle::current(), || Ok(7)).await.unwrap(), 7);
        drop(extra);
        drop(queued);
        drop(occupied);
        assert_eq!(background.admitted.available_permits(), 2);
    }
}
