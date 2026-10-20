//! The entry point the app calls once per frame, as a leaf `dart:ffi` call
//! on buffers it owns: no allocation it must free, no lock, no callback.
use std::panic::{catch_unwind, AssertUnwindSafe};

use super::{frame, Frame, Out, Scene};

/// Larger buffers than these are refused as malformed.
const MAX_SCENE: u32 = 1 << 22;
const MAX_OUT: u32 = 1 << 24;

/// Computes one galaxy frame (see [`super::frame`] for the layouts).
/// Returns the number of values written to `out`; when `capacity` is too
/// small, minus the number needed (and `out` holds nothing usable); -1 for a
/// malformed scene or frame.
///
/// # Safety
///
/// `scene`, `frame` and `out` must be valid and aligned for `scene_len`,
/// `frame_len` and `capacity` elements for the duration of the call, and
/// `out` must not overlap the other two. The caller keeps ownership.
#[no_mangle]
pub unsafe extern "C" fn pocox_galaxy_frame_v1(
    scene: *const f64,
    scene_len: u32,
    frame_values: *const f64,
    frame_len: u32,
    out: *mut f32,
    capacity: u32,
) -> i64 {
    if scene.is_null() || frame_values.is_null() || scene_len > MAX_SCENE || capacity > MAX_OUT {
        return -1;
    }
    if out.is_null() && capacity > 0 {
        return -1;
    }
    // SAFETY: the caller guarantees the three regions as documented.
    let (scene, frame_values) = unsafe {
        (
            std::slice::from_raw_parts(scene, scene_len as usize),
            std::slice::from_raw_parts(frame_values, frame_len as usize),
        )
    };
    let out: &mut [f32] = if capacity == 0 {
        &mut []
    } else {
        // SAFETY: as above; `out` is writable and overlaps neither input.
        unsafe { std::slice::from_raw_parts_mut(out, capacity as usize) }
    };
    catch_unwind(AssertUnwindSafe(|| {
        let (Some(scene), Some(frame_values)) = (Scene::decode(scene), Frame::decode(frame_values))
        else {
            return -1;
        };
        let mut writer = Out::new(out);
        frame(&scene, &frame_values, &mut writer);
        if writer.fits() {
            writer.len() as i64
        } else {
            -(writer.len() as i64)
        }
    }))
    .unwrap_or(-1)
}
