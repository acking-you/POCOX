//! Standalone native frame allocation probe; no runtime, host or model access.
//! The fixture has three systems, three planets, one link and two background
//! stars. It includes only the geometry module, so it builds without the crate:
//!
//! ```sh
//! rustc --edition=2021 -O crates/pocox-bridge/examples/galaxy_allocations.rs -o /tmp/probe
//! ```
use std::{
    alloc::{GlobalAlloc, Layout, System},
    sync::atomic::{AtomicUsize, Ordering},
    time::Instant,
};
struct Counter;
static ALLOCS: AtomicUsize = AtomicUsize::new(0);
static BYTES: AtomicUsize = AtomicUsize::new(0);
// SAFETY: every allocation delegates unchanged to System; counters never
// allocate.
unsafe impl GlobalAlloc for Counter {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        ALLOCS.fetch_add(1, Ordering::Relaxed);
        BYTES.fetch_add(l.size(), Ordering::Relaxed);
        // SAFETY: the allocator caller supplies a valid layout.
        unsafe { System.alloc(l) }
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        // SAFETY: the allocator caller owns p with layout l.
        unsafe { System.dealloc(p, l) }
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
        ALLOCS.fetch_add(1, Ordering::Relaxed);
        BYTES.fetch_add(n, Ordering::Relaxed);
        // SAFETY: the allocator caller owns p and supplies a valid new size.
        unsafe { System.realloc(p, l, n) }
    }
}
#[global_allocator]
static ALLOCATOR: Counter = Counter;
#[path = "../src/engine/galaxy/mod.rs"]
mod galaxy;
use galaxy::{ffi::pocox_galaxy_frame_v1, VERSION};
fn scene() -> Vec<f64> {
    let mut s = vec![VERSION, 3.0, 3.0, 1.0, 1.0];
    // Systems: x, y, z, home, online, first planet, planet count, label.
    s.extend([0.0, 0.12, 0.0, 1.0, 1.0, 0.0, 2.0, 60.0, 15.0]);
    s.extend([3.4, 0.0, -1.2, 0.0, 1.0, 2.0, 1.0, 48.0, 15.0]);
    s.extend([-2.8, 0.0, 2.5, 0.0, 0.0, 3.0, 0.0, 30.0, 15.0]);
    // Planets: system, ring, radius, phase, period, size, tilt axis, tilt,
    // appeared, rippled, label, strong label.
    let planet = |system: f64, ring: f64, phase: f64| {
        [
            system,
            ring,
            0.62,
            phase,
            90.0,
            0.105,
            0.4,
            0.1,
            f64::NAN,
            f64::NAN,
            40.0,
            14.0,
            44.0,
            15.0,
        ]
    };
    s.extend(planet(0.0, 0.0, 0.3));
    s.extend(planet(0.0, 0.0, 3.4));
    s.extend(planet(1.0, 0.0, 1.0));
    // A link from the second device's port to home.
    s.extend([2.0, 0.0]);
    // One star layer with one bucket of two stars.
    s.extend([0.3, 1.0, 0.5, 2.0, 0.1, 0.2, 0.9, 0.8]);
    s
}

/// Camera at rest over the disk, 1440 × 900, nothing selected.
fn frame(time: f64) -> Vec<f64> {
    vec![1440.0, 900.0, 0.6, 0.52, 9.0, 0.0, 0.0, 0.0, time, 0.0, -1.0, -1.0, -1.0]
}

fn main() {
    let s = scene();
    let f = frame(12.5);
    let mut out = vec![0f32; 1 << 16];
    // SAFETY: all input/output regions remain live, aligned and disjoint.
    let mut call = || unsafe {
        pocox_galaxy_frame_v1(
            std::hint::black_box(s.as_ptr()),
            s.len() as u32,
            std::hint::black_box(f.as_ptr()),
            f.len() as u32,
            std::hint::black_box(out.as_mut_ptr()),
            out.len() as u32,
        )
    };
    assert!(call() > 0);
    ALLOCS.store(0, Ordering::Relaxed);
    BYTES.store(0, Ordering::Relaxed);
    let now = Instant::now();
    for _ in 0..1000 {
        std::hint::black_box(call());
    }
    let elapsed = now.elapsed();
    let a = ALLOCS.load(Ordering::Relaxed);
    let b = BYTES.load(Ordering::Relaxed);
    println!(
        "frames=1000 alloc_or_realloc_per_frame={} requested_bytes_per_frame={} mean_us={:.2}",
        a / 1000,
        b / 1000,
        elapsed.as_micros() as f64 / 1000.0
    );
}
