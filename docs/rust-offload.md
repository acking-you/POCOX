# Rust offload: execution, diagnostics and session data

The 2026-10-21 implementation follows the priorities in the
[source review](rust-offload-review-2026-10-21.md). It moves blocking work,
log ownership, event projection, history ordering, send admission, attachment
processing and diff parsing into the existing `pocox_bridge` crate.
Flutter retains editable drafts, platform permissions, view lifecycle and
rendering. External Codex, ACP and OpenCode remain the model runtimes.

## Execution and logs

`engine/execution.rs` admits async bridge requests before moving synchronous
engine work onto blocking workers. Control, foreground reads, background
discovery, transfers and CPU transformations have independent budgets:

| Lane | Running | Waiting |
| --- | ---: | ---: |
| Control | 8 | 24 |
| Read | 8 | 24 |
| Background | 3 | 45 |
| Transfer | 2 | 6 |
| CPU | 2 | 6 |

An overloaded queue refuses work before dispatch. Cancelled waiting futures
release their admission; work already started finishes once. Queued calls
check the account/relay epoch again before execution. Existing engine checks
still guard connection identity and scoped uploads. This separates slow
discovery and uploads from interactive operations; it is not a claim that
arbitrary operating-system I/O can be cancelled.

Update snapshots read published memory. Persistence, installation and network
operations use async bridge entries. The synchronous composer and log commands
only touch bounded memory.

`engine/logging.rs` owns one 2 MiB / 2,000-line ring. Each message is limited
to 16 KiB plus its truncation marker. Flutter diagnostics enter the same ring;
the log page subscribes to coalesced invalidations only while open and asks
Rust for the filtered view. `engine/logging/disk.rs` uses a dedicated writer,
a non-blocking 256-entry / 4 MiB queue, timed flushes, 16 MiB file rotation,
64 MiB directory retention and six-hour expiry. Shutdown requests a flush
barrier with a two-second deadline. The viewer reports disk drops/write
failures; no logging failure recursively logs into its own sink.

## Session ownership

`engine/session_projection.rs` filters subscriptions by thread and topic,
decodes turn/client/activity metadata and combines adjacent compatible text
deltas over at most 16 ms / 64 KiB. Lifecycle events and approval requests are
ordering barriers. Complete item snapshots establish native text prefixes;
a reconnect that begins with a delta stays partial until history arrives.
Each subscription retains at most 512 prefixes / 16 MiB. A lagged stream
forwards retained requests and closes so the controller reloads history.

`engine/history_projection.rs` merges ordered identities and turn IDs, returning
indices into the caller's existing rows. Text and images are not copied back
to Rust for each merge. Shared IDs keep the live row, disjoint turns retain
their order, and older pages preserve their overlap anchors. Flutter checks
navigation/connection generations and retries projection when live identities
change while awaiting it. The input limit is 100,000 combined rows and 16 MiB
of identities.

`api/bridge/composer.rs` owns the queue's ordered command identities, exclusive
send lease, paused/unknown outcome state and attachment admission generation.
An old completion cannot release a newer lease. Resume does not authorize an
unknown command to be resent: only explicit Retry clears that protection.
Only the sending head may be accepted; an in-flight entry cannot be removed
or displaced. Queues admit at most 1,024 identities. Flutter keeps their text,
attachment previews, IME state and lifecycle orchestration. This is an
incremental controller boundary, not a complete native transcript/view state
machine. Explicit retry's latest-user-message comparison also runs in Rust;
a missing match is never proof that the earlier request did not arrive.

## Attachments and diff

`engine/attachments.rs` uses the Rust `image` library for header validation,
first-frame decoding, EXIF orientation, resizing, white alpha composition,
JPEG encoding and data URLs. Reads are capped at 32 MiB, decoded dimensions
at 32 megapixels and decoder allocations at 128 MiB. These are per-operation
limits, not a bound on total application RSS. Small supported images pass
through; larger images fit a 1,568-pixel edge and encode at JPEG quality 85.
Converted animations use their first frame.

Selected local file bodies stay behind opaque Rust handles through upload.
Four handles reserve at most 128 MiB of file payloads. A revoked or removed
attachment explicitly releases its handle; transfer completion releases its
reservation. The caller checks draft admission after reading and Rust checks
the original upload context. Platform-only URIs and clipboard inputs still
enter as bytes. Prepared images return preview bytes and their wire data URL.

`engine/git_diff.rs` parses display diffs, including incomplete streaming
hunks, Git-quoted UTF-8 paths, deletion paths and content starting with `---`
or `+++`. It computes line numbers and counts once, caches by content digest
within 8 MiB / 128 entries, and truncates display parsing at 16 MiB / 100,000
lines with a visible notice. History, live file-change events and working-tree
review share this representation. Native review indexing groups compact file
metadata; Flutter materializes references to its existing parsed sections.
The old Dart parser, history-ordering algorithm and image conversion pipeline
are removed from production code.

## Verification and remaining measurements

Core native tests exercise lane saturation/cancellation, log rotation/flush,
event barriers, reconnect prefixes, history overlap, unknown sends and stale
leases, image bounds/orientation/animation, diff headers and quoted paths.
Existing Flutter recovery, queue, attachment, pagination and review tests
exercise the new boundary through an injectable bridge. `native_offload_test`
additionally loads the actual compiled library and crosses FRB for composer
state, history ordering, review indexing, image preparation and file-handle
capacity/release. It uses temporary files and does not initialize hosting or
send model requests:

```sh
cargo build -p pocox_bridge --lib --locked
cd apps/flutter
POCOX_NATIVE_TEST_LIB="$PWD/../../target/debug/libpocox_bridge.dylib" \
  fvm flutter test --no-pub test/native_offload_test.dart
```

The filename above is for macOS; use the platform's library on other hosts.
The test is skipped in ordinary widget runs unless the path is supplied.

Verified on macOS on 2026-10-21: the full first-party Rust format check,
workspace clippy with warnings denied, workspace tests (970 passed, 29
ignored), Flutter dependency resolution/localization generation/format/analyze,
and the full Flutter suite (1,666 passed, 9 skipped). The native-library FRB
test passed separately. The skipped/ignored tests include opt-in live-service
checks; these results do not imply those services were exercised.
After the final log-capacity correction and test-helper extraction, bridge
clippy, four native log tests, Flutter analyze and 38 affected widget tests
passed again.

Real-device frame latency, RSS/GC, bridge byte counts, release size and
cross-platform acceptance still need measurement. No end-to-end speedup is
claimed. Markdown/highlighting, project indexing, Galaxy scratch reuse and
business-preference persistence remain the review's profiling-led follow-up;
UI rendering, audio tracks and platform permission flows stay in Flutter.
