# Galaxy frame geometry and drawing

The galaxy (`/galaxy`, `apps/flutter/lib/src/tools/galaxy/`) draws every device
as a star and its services as orbiting planets on a turning, perspective disk.
Its per-frame geometry is computed in Rust (`crates/pocket-codex-bridge/src/engine/galaxy/`),
following proxy-everything's `galaxy-geometry` crate: one bounded leaf
`dart:ffi` call per frame on buffers the app owns. The Dart painter only issues
draw calls, and draws the glows and spheres from images rendered once
([below](#drawing-from-cached-images)), as proxy-everything does.

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
ghosts of removed bodies (rare and short) and all painting: colours, cached
images, strokes, text.

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

## Drawing from cached images

Most of a frame's raster time went into blurs and gradients: every star had up
to three blurred glows and two gradient spikes, every sphere a blurred glow
(dark) or contact shadow (light), a radial-gradient body, a sweep-gradient rim
and a blurred specular point, every link particle a blur, and the plane one
large blurred oval. Leaving out just those layers (a temporary ablation build)
cut raster time by 62 % (busy, dark) and 67 % (busy, light).

`GalaxySprites` (`galaxy_sprites.dart`) renders each of those layers once into
one atlas image and draws them with `drawRawAtlas`, in the order the vector
painter would:

- `paintSphere` (`planet_glyph.dart`) builds a sphere from layers through
  `SphereLayers`. `CanvasSphereLayers` draws them as vectors (the service cards
  and list rows, and the fallback); the galaxy's sprites draw them from the
  atlas, whose cells are painted by the same `CanvasSphereLayers` code.
- Opacity stays per layer. A faded planet is four sprites (glow or shadow,
  body, rim, specular point), each at its own alpha, so it is as translucent as
  before; a sphere baked into one image would hide its glow behind its body.
- Glows, halos, shadows, rims, specular points, spikes and particles are white
  coverage images coloured when drawn (`BlendMode.modulate`), so one image
  serves every colour and alpha. Bodies are rendered per colour and theme.
- Sizes: sharp layers (bodies, rims, spikes) are rendered per size bucket,
  four per octave of on-screen pixels, and drawn at most 16 % smaller than
  rendered. Soft layers use two buckets per octave and, above 16 px (32 px for
  shadows), are scaled up, which a blur survives. A rim or spike keeps its
  width relative to its size, rounded to an eighth of an octave (±4 %). A
  spike image is turned a quarter for the upright spike.
- The plane's glow is one image of its shape relative to its blur (rounded to
  1/32 octave), rendered with an 8 px blur and stretched to the frame's oval;
  it is rendered again only when that shape changes.
- Sprites are submitted in runs between the vector draws (orbits, link curves,
  rings, ripples, share dashes, labels), about three `drawRawAtlas` calls per
  star system. Those vector draws, the guide circles and the starfield are
  unchanged; the fading spheres of removed services use the sprites too.
- A layer is painted as vectors in the frame that first asks for it; the next
  frame renders the atlas again: the previous image as it was and the new
  cells packed bottom-left on a skyline. A change of theme starts afresh.
- `toImageSync` rasterizes when an image is first drawn, so a failure (a lost
  GPU context) surfaces as a `PictureRasterizationException` from the draw:
  the images are dropped, that frame loses those sprites, and the galaxy
  paints vectors for 600 frames before making images again.

Memory: the atlas is at most 512×2048 pixels (4 MB). Measured at 2×, it and the
plane's image held 0.3–0.55 MB (the harness reports `sprite_kb`). Image
heights are rounded up (64 rows; 16 px for the plane's), so a replaced image
leaves one the GPU can reuse rather than one of a new size. A full atlas
starts afresh at most every 600 frames, and what does not fit meanwhile is
painted as vectors, so it never rebuilds every frame. Sharp layers over 128 px
(only zoomed ghosts) are painted as vectors.

## Look

Moving the geometry to Rust left the draw calls unchanged: widget-test
captures of the galaxy before and after (light, dark, the details panel, a
phone) were pixel-identical in dark and differed in 2 of 1.3 million pixels by
1/255 in light (float rounding). Equally ranked labels keep their drawing order
on both ends (a stable sort); Dart's own sort, used before, is not stable past
32 elements, so ties between labels of the same rank and size may resolve
differently than before.

The cached images are not pixel-identical. `test/galaxy_sprites_test.dart`
compares sprite-drawn spheres and glows with vectors at radii 1.2–26 and
opacities 1, 0.62 and 0.3, in both themes at 2×: fewer than 0.1 % of channels
differ by more than 8/255, all on anti-aliased edges. Widget-test captures
(`galaxy_test.dart` with `PCX_UI_PREVIEW_DIR`, at 1×) before and after:

| Capture | Pixels that differ | by more than 2/255 | by more than 8/255 | Worst |
|---|---|---|---|---|
| light | 25 % | 0.10 % | 663 | 82/255 |
| dark | 41 % | 0.12 % | 654 | 41/255 |
| details panel, light | 74 % | 16 % | 342 | 48/255 |
| details panel, dark | 75 % | 46 % | 302 | 35/255 |
| phone (3× layout captured at 1×) | 4.3 % | 0.15 % | 215 | 48/255 |

- Most differing pixels differ by 1/255: the 8-bit rounding of large soft glows.
- The pixels beyond 8/255 are anti-aliased edges of bodies and thin rims. A
  cached image drawn at a sub-pixel position moves an edge by a fraction of a
  pixel (a rim on a small planet is about a pixel wide, so its pixels move
  most). Crops of the worst pixels at 8×, side by side, look the same.
- With the camera on a planet (the details panel), most of the frame differs
  by 2–4/255: the plane's glow, whose blur there exceeds 200 px. The test
  renderer's own blur collapses at that size (the same oval's centre goes from
  0.875 to 1.0 alpha when only its scale grows from a 100 px to a 200 px blur),
  while the cached glow keeps its specified softness at every zoom, so close up
  the plane's glow is up to 4/255 softer and dimmer than before. Whether
  Metal's blur collapses the same way was not checked.
- The phone capture samples a 3× layout's images down three times; on a phone
  they are drawn at their own scale.

## Measurements

`integration_test/galaxy_performance_test.dart` animates synthetic scenes for
8 s after a 3 s warm-up and reports `FrameTiming` percentiles, the process's
resident memory, the sprite images' size and the sample's wall-clock window.
Profile mode on an Apple Silicon Mac (macOS 27, Skia on Metal: macOS does not
use Impeller by default), 800×600 window at 2× on the built-in 120 Hz display;
"typical" is 5 devices and 25 services, "busy" 24 devices and 192 services. Two
runs each; build is the UI thread (where the painter runs), raster the raster
thread.

Geometry in Rust (PR #137):

| Scene | UI build avg (µs) before → after | UI build p99 (µs) before → after | Raster avg (µs) before → after |
|---|---|---|---|
| typical, dark | 571, 558 → 425, 440 | 695, 691 → 526, 566 | 3141, 3082 → 3076, 3085 |
| typical, light | 522, 520 → 398, 402 | 614, 615 → 496, 492 | 3402, 3389 → 3421, 3375 |
| busy, dark | 2146, 2159 → 1342, 1357 | 2860, 2882 → 1511, 1521 | 6593, 6689 → 6508, 6609 |
| busy, light | 2192, 2156 → 1441, 1418 | 2852, 2881 → 1617, 1589 | 9474, 9375 → 9383, 9449 |

UI-thread time per frame fell by about 23 % in the typical scene and 35 % in
the busy one (47 % at p99). Raster time did not change.

Cached images:

| Scene | UI build avg (µs) before → after | UI build p99 (µs) before → after | Raster avg (µs) before → after | Raster p99 (µs) before → after |
|---|---|---|---|---|
| typical, dark | 423, 427 → 465, 458 | 617, 514 → 691, 668 | 3283, 2981 → 2753, 2769 | 4406, 3653 → 3698, 3812 |
| typical, light | 383, 449 → 448, 423 | 529, 940 → 652, 618 | 3411, 3731 → 2714, 2607 | 4348, 9738 → 3581, 3571 |
| busy, dark | 1355, 1433 → 923, 971 | 1563, 1597 → 1089, 1420 | 6311, 6804 → 3219, 3430 | 7174, 8007 → 3981, 4761 |
| busy, light | 1440, 1470 → 914, 920 | 1644, 1601 → 1049, 1091 | 8967, 9577 → 3216, 3349 | 10044, 10823 → 3742, 4228 |

Raster time per frame fell by 49 % (busy, dark) and 65 % (busy, light), and by
12 % and 25 % in the typical scene; the busy scene now costs about what the
typical one did. UI-thread time fell by a third in the busy scene (fewer draw
calls to record) and rose by 20–40 µs in the typical one (the sprites'
bookkeeping). The 9.7 ms typical-light p99 before is one disturbed run (the
Mac was in use). Both before runs and the after runs used the same harness
except that the window was placed on the main display explicitly only for the
after runs; every run drew at 2× and 120 Hz.

Memory, one run each with `footprint` sampled every second (its total is
what Activity Monitor shows; IOAccelerator is the GPU's share), averaged over
each scene's sample window:

| Scene | Footprint (MB) before → after | GPU (MB) before → after | Sprite images (KB) |
|---|---|---|---|
| typical, dark | 420 → 411 | 10.4 → 14.0 | 547 |
| typical, light | 428 → 425 | 11.8 → 14.1 | 547 |
| busy, dark | 443 → 440 | 18.7 → 18.4 | 419 |
| busy, light | 468 → 425 | 19.9 → 18.4 | 291 |

The total did not grow. The GPU's share grew by 2–4 MB in the typical scenes,
which run first, and not in the busy ones (before the images' sizes were
rounded, it grew by up to 6 MB). Resident memory at the end of a scene varies
by up to 30 MB between runs of the same code and shows no difference either
way.

Not measured: other platforms (iOS and Android draw with Impeller, where blurs
and atlases cost differently), phones, larger windows.

```sh
cd apps/flutter
FLUTTER_XCODE_ARCHS=arm64 FLUTTER_XCODE_ONLY_ACTIVE_ARCH=YES \
fvm flutter drive --profile -d macos \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/galaxy_performance_test.dart \
  --dart-define=PCX_GALAXY_PERF=true
```

The harness keeps its window on top of the main display: macOS stops drawing a
covered window, and another display may run at another pixel ratio and
refresh rate (a run on a 60 Hz 1× display is not comparable). Check that every
scene reports `"ratio":2.0` and about 1000 frames. On a Mac whose Xcode
`strip` breaks Rust proc-macro dylibs (Xcode 27), add
`CARGO_PROFILE_RELEASE_STRIP=false CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=false`
for the local profile build; release CI is unaffected. Remove
`build/macos/Build/Products/Profile` between profile runs.
