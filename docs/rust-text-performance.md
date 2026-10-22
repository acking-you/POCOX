# Native text processing and Galaxy measurements

Measured on 2026-10-21 after the [controller offload](rust-offload.md).
Syntax highlighting runs on Rust CPU workers and Galaxy reuses frame scratch.
A native Markdown parser was measured too and **not adopted**: its parse was
faster, but whole Markdown widget frames were not, and an asynchronous parse
showed an uncached message's raw source for at least one frame. Markdown
parsing, styles, layout, selection and platform interactions remain in Flutter.

## Method and results

Host: Apple M3 Pro, 12 logical CPUs, 36 GiB RAM, macOS 27.0.1, Flutter 3.44.0,
Rust nightly-2026-06-01, Xcode 27. The committed integration harnesses ran in
the actual macOS profile app with the native library loaded. Text comparisons
alternate the old Dart implementation and the native round trip within one run;
the old grammar implementation is a dev-only fixture. These are synthetic
reply/code workloads, not a representative sample of every user session.

Performance was collected before main's package rename in PR #143. The changes
were then rebased onto `1fdcca10` and the functional gates rerun under the `pocox`
names. [Raw measurements](performance/render-2026-10-21.json) retain sample
sizes, p95, frame metrics, RSS and display settings. Failed profile experiments
that reported zero raster work are excluded. Both harnesses now require actual
raster work and keep the profile window visible on top; they do not override
the test view's pixel metrics.

All times below are microseconds. The rejected native Markdown candidate
included the FRB request, Comrak parse, JSON return and adaptation into the
existing renderer's nodes.
Highlighting includes FRB, semantic token generation and Flutter TextSpan
construction; it is not a Rust-only microbenchmark.
Reported source sizes describe the reusable fixture before its per-sample
suffix. Parsing uses 100 samples after 10 warm-ups; highlighting uses 50 after
10 warm-ups. This excludes the one-time cold grammar-catalog initialization.

| Markdown source (UTF-16 units) | Dart p50 / p95 | Rejected native round trip p50 / p95 | Tree JSON bytes |
|---|---:|---:|---:|
| 1,655 | 560 / 889 | 172 / 302 | 5,559 |
| 8,359 | 2,404 / 2,584 | 598 / 700 | 28,366 |

| Cold highlighting | Source units | Dart p50 / p95 | Native + spans p50 / p95 |
|---|---:|---:|---:|
| Rust | 1,080 | 904 / 1,434 | 592 / 681 |
| Rust | 12,960 | 25,430 / 31,840 | 6,732 / 13,783 |
| TypeScript | 1,380 | 2,102 / 2,861 | 2,711 / 3,329 |
| TypeScript | 16,560 | 54,665 / 61,138 | 14,996 / 31,678 |
| Dart | 840 | 467 / 500 | 423 / 437 |
| Dart | 10,080 | 13,076 / 13,918 | 4,764 / 5,080 |

Long-code p50 improves by 2.7–3.8×. The short TypeScript example is slower;
there is no all-input speedup claim. Native work no longer occupies the UI
isolate. Cached token lookup is usually 0–5 µs. This is not directly comparable
to the legacy warm path, which cached entire TextSpans; the new widget separately
memoizes its spans and can recolor tokens without another native parse.

Syntect's pure-Rust fancy-regex backend was also tried: the 16,560-unit
TypeScript sample took about 96 ms in the native candidate versus 55 ms in Dart.
It was rejected. The chosen Oniguruma backend adds a native C dependency to the
Flutter bridge. Syntect and two-face are optional Flutter-feature
dependencies; the headless CLI does not acquire them. A 62-unit inline preview
already takes only 47 µs p50 / 74 µs p95 in Dart and stays there.

### Whole Markdown widget (why Markdown stays in Dart)

Both paths below use the same native highlighter, renderer, streaming workload
and 2× display in one profile run. The candidate reused the previous formatted
tree while a streamed parse was pending, but a new or uncached message showed
its raw source until the asynchronous parse returned.

| Source units | Parser | Build p50 / p95 | Sum of build work per source update |
|---|---|---:|---:|
| 1,655 | Dart | 4,905 / 7,145 | 46,687 |
| 1,655 | Rust | 4,979 / 7,297 | 48,486 |
| 8,359 | Dart | 23,607 / 32,570 | 102,594 |
| 8,359 | Rust | 24,358 / 33,474 | 105,885 |

Layout dominates this workload; the native path is roughly 3% higher at the
large sample's median. Raster time remains about 0.5–1.1 ms. The parse gain
does **not** establish a whole-page, frame-rate or input-latency gain, so the
synchronous Dart parser stays: it formats a message on its first frame, and
widget tests exercise the parser that ships.
Driver update duration also does not measure when an async parse becomes
visible. RSS samples include different cache/allocation histories, so they do
not establish a memory reduction. The profile harness app grew from 107.2 MB
to 111.6 MB with both native parsers; it contained both comparators and this is
not a shipping release-size measurement. Phones and other desktop platforms
have not been profiled.

### Galaxy

The actual `GalaxyFrameBuffer.compute` FFI path ran 1,100 times per scene,
discarding the first 100 samples. The geometry probe always uses a 1440×900
camera, the same encoded scene, and the same animation sequence, independently
of the profile window's display settings.

| Scene | Geometry p50 before → after | p95 before → after | Scene / output bytes |
|---|---:|---:|---:|
| 5 devices, 25 services, dark | 48 → 28 | 53 → 30 | 11,872 / 19,432 |
| 5 devices, 25 services, light | 48 → 27 | 51 → 28 | 11,872 / 19,432 |
| 24 devices, 192 services, dark | 225 → 125 | 255 → 144 | 32,024 / 75,404 |
| 24 devices, 192 services, light | 224 → 125 | 244 → 144 | 32,024 / 75,404 |

Geometry p50 falls by 42–44%. A standalone allocator probe of the actual Rust
module (3 systems, 3 planets, 1 link, 2 stars; 1,000 warmed frames) records
**66 → 5 allocation/reallocation calls and 18,296 → 600 requested bytes per
frame**. Requested allocation bytes are neither retained memory nor RSS.
Scene decoding still allocates; the existing FFI buffers and ABI are unchanged.

Full-window before/after frame metrics are not comparable: the earlier run
used 800×600 at 1×, the final run 1200×868 at 2×. No raster improvement is
claimed. The final busy scene averages 875 µs UI and 3.78–3.83 ms raster per
frame, with about 1,000 actual drawn frames per 8.3-second window. The earlier
[Galaxy rendering work](galaxy-geometry.md) has its own separate measurements.

## Ownership and bounds

- `engine/syntax.rs` returns exclusive UTF-16 ends and nine semantic roles with
  bold/italic bits. Flutter supplies theme colors. Input limits are 20,000
  UTF-16 units, 80,000 UTF-8 bytes and 4,096 bytes per line. Unknown grammars,
  oversize inputs and failures stay plain. The 100 ms budget is checked between
  lines; it cannot preempt one regex evaluation. The grammar catalog is loaded
  once. No source text is retained by Rust.
- `api/bridge/text_render.rs` uses the bounded CPU execution lane. Native
  highlighting accepts at most 32 inputs / 1 MiB per request. The Flutter
  scheduler runs two batches of up to 16, deduplicates requests, bounds pending
  work to 512 entries / 2 MiB, and releases queued work when its last reader
  leaves. The token LRU weighs source and token bytes within 2 MiB. Code blocks,
  both diff surfaces and file previews share it. Unicode/source is preserved.
- `engine/galaxy/scratch.rs` retains thread-local working vectors and circle
  samples without a global lock. Retained heap capacity above 1 MiB is dropped
  after a frame. This is a retention threshold, not a peak-allocation cap.
  Plane runs stream into the caller's output; fixed link/particle temporaries
  use stack arrays. Depth/label ties retain their original ordering.

Libraries: [Syntect 5.3](https://docs.rs/syntect/5.3.0/syntect/) and
[two-face 0.5.2](https://docs.rs/two-face/0.5.2/two_face/).

## Reproduction and validation

```sh
cd apps/flutter
FLUTTER_XCODE_MACOSX_DEPLOYMENT_TARGET=12.0 \
FLUTTER_XCODE_ARCHS=arm64 FLUTTER_XCODE_ONLY_ACTIVE_ARCH=YES \
CARGO_PROFILE_RELEASE_STRIP=false CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=false \
fvm flutter drive --profile -d macos \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/render_performance_test.dart \
  --dart-define=POCOX_RENDER_PERF=true
```

Use `galaxy_performance_test.dart` and `POCOX_GALAXY_PERF=true` for Galaxy.
The Xcode settings above only work around this local profile toolchain; they
do not change release deployment targets. The allocation probe is independent
of Flutter and uses the production geometry module:

```sh
rustc --edition=2021 -O crates/pocox-bridge/examples/galaxy_allocations.rs \
  -o /tmp/pocox-galaxy-allocations
/tmp/pocox-galaxy-allocations
```

Rust tests cover all registered syntax names, Unicode offsets and plain
fallbacks for unknown, oversized and pathological input. Flutter tests cover
shared batches, cancellation, bounds, failed workers, stale completions, theme
changes and readable fallbacks. The opt-in `native_render_test.dart` loads the
real library and checks that highlight tokens cross FRB and keep Unicode in
the painted spans. `galaxy_frame_parity_test.dart` compares
native output to the Dart geometry reference over 16 camera cases.

Run those real-library checks together with the controller acceptance test:

```sh
cargo build -p pocox_bridge --lib --locked
cd apps/flutter
POCOX_NATIVE_TEST_LIB="$PWD/../../target/debug/libpocox_bridge.dylib" \
POCOX_BRIDGE_LIBRARY="$PWD/../../target/debug/libpocox_bridge.dylib" \
  fvm flutter test --no-pub test/native_offload_test.dart \
    test/native_render_test.dart test/galaxy_frame_parity_test.dart
```

The library filename is macOS-specific; supply the corresponding platform
library elsewhere. After the native Markdown path was removed (2026-10-22):
first-party formatting, workspace clippy with warnings denied, bridge tests
(391 passed, 12 ignored), Flutter analyze/format and the full Flutter suite
(1,660 passed, 10 skipped) pass, and the three real-library test files above
pass with the rebuilt `libpocox_bridge.dylib`. Because Oniguruma is a C
dependency that ordinary CI builds only for Linux and macOS hosts, the app was
also built through Cargokit on GitHub runners: Android debug APKs for
arm64-v8a, armeabi-v7a and x86_64 (NDK r26d), iOS release without signing,
and Windows release. Ignored/skipped live-service tests were not exercised.
Native acceptance and profile runs supplement these tests; none of them
establishes mobile performance.
