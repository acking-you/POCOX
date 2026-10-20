# Galaxy frame geometry

The galaxy (`/galaxy`, `apps/flutter/lib/src/tools/galaxy/`) draws every device
as a star and its services as orbiting planets on a turning, perspective disk.
Its per-frame geometry is computed in Rust (`crates/pocket-codex-bridge/src/engine/galaxy/`),
following proxy-everything's `galaxy-geometry` crate: one bounded leaf
`dart:ffi` call per frame on buffers the app owns. The Dart painter only issues
draw calls.

## What Rust computes

Per frame, in drawing order (`engine::galaxy::frame`):

- the background stars' positions and twinkle;
- the plane's glow (its oval and blur) and the guide circles, split where they
  pass behind the camera;
- every star's projection, sorted far to near, its radius (with its breath),
  opacity (selection dimming, depth fade) and every orbit split into the runs
  behind and in front of its star;
- every planet's orbit position (with the spiral-out entrance), projection,
  radius, opacity, ripple progress and whether it is behind its star;
- the links' curves and particles;
- label placement: ranking, collision with placed labels and stars, and the
  on-screen check.

Dart keeps the camera's easing, hit testing on the drawn bodies, the fading
ghosts of removed bodies (rare and short) and all painting: colours, shaders,
blurs, text.

## The call

`GalaxyGeometry` (`galaxy_painter.dart`) encodes the scene (systems, planets,
links, label sizes, star layers, entrance and ripple times) only when the
scene, a body's motion or the label styles change. Each frame writes 13 values
(size, camera, clock, still, selection, hover, focus) and calls
`pocox_galaxy_frame_v1(scene, frame, out)`: native buffers allocated with
`package:ffi`, the result read in place as a `Float32List` view (stars go to
`drawRawPoints` without a copy). A short output buffer gets the length it
needs and the call is repeated. A malformed buffer returns -1 and draws
nothing for that frame. The function allocates only what it computes, takes
no lock, makes no callback and catches panics.

The library is the one the app already loaded for flutter_rust_bridge
(`loadExternalLibrary`); Apple platforms link the bridge with `-force_load`, so
the export is always present. Where the library is not loaded (`flutter test`)
`computeFrameInDart` (`galaxy_frame.dart`), a step-for-step port, fills the
same buffer, and `test/galaxy_frame_parity_test.dart` compares the two on the
built library (16 camera, clock and selection combinations over 18 devices,
within 1e-3 relative).

## Look

The draw calls are unchanged. Widget-test captures of the galaxy before and
after (light, dark, the details panel, a phone) are pixel-identical in dark
and differ in 2 of 1.3 million pixels by 1/255 in light (float rounding).
Equally ranked labels keep their drawing order on both ends (a stable sort);
Dart's own sort, used before, is not stable past 32 elements, so ties between
labels of the same rank and size may resolve differently than before.

## Measurements

`integration_test/galaxy_performance_test.dart` animates synthetic scenes for
8 s after a 3 s warm-up and reports `FrameTiming` percentiles. Profile mode on
an Apple Silicon Mac (macOS 27), 800×600 window at 2×; "typical" is 5 devices
and 25 services, "busy" 24 devices and 192 services. Two runs each; build is
the UI thread (where the painter runs), raster the GPU thread.

| Scene | UI build avg (µs) before → after | UI build p99 (µs) before → after | Raster avg (µs) before → after |
|---|---|---|---|
| typical, dark | 571, 558 → 425, 440 | 695, 691 → 526, 566 | 3141, 3082 → 3076, 3085 |
| typical, light | 522, 520 → 398, 402 | 614, 615 → 496, 492 | 3402, 3389 → 3421, 3375 |
| busy, dark | 2146, 2159 → 1342, 1357 | 2860, 2882 → 1511, 1521 | 6593, 6689 → 6508, 6609 |
| busy, light | 2192, 2156 → 1441, 1418 | 2852, 2881 → 1617, 1589 | 9474, 9375 → 9383, 9449 |

UI-thread time per frame fell by about 23 % in the typical scene and 35 % in
the busy one (47 % at p99). Raster time did not change: the remaining cost is
drawing (blurred glows, gradient planets, text), which stays on the GPU thread
and dominates the frame. Not measured: other platforms, phones, larger windows.

```sh
cd apps/flutter
FLUTTER_XCODE_ARCHS=arm64 FLUTTER_XCODE_ONLY_ACTIVE_ARCH=YES \
fvm flutter drive --profile -d macos \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/galaxy_performance_test.dart \
  --dart-define=PCX_GALAXY_PERF=true
```

On a Mac whose Xcode `strip` breaks Rust proc-macro dylibs (Xcode 27), add
`CARGO_PROFILE_RELEASE_STRIP=false CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=false`
for the local profile build; release CI is unaffected. Remove
`build/macos/Build/Products/Profile` between profile runs.
