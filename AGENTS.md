# POCOX Agent Guide

> This document is the contract between human contributors, AI coding
> agents (Claude Code, Codex CLI, etc.) and the project itself. Read it
> before touching code.

## 1. Project intent

POCOX (from **PO**cket **CO**de**X**) aims to put every device a user owns
in their pocket: the agents, services and subscriptions on each computer,
reachable from any other device. It is a medium, not a harness: users keep
(and are encouraged to keep) the vendors' own apps and CLIs, while POCOX
discovers, follows and takes over their sessions and exposes each machine's
services. Concretely, it turns the upstream
[`codex app-server`](https://github.com/openai/codex) protocol into a
portable, multi-device experience, and additionally exposes the host's
Codex login as a relay-reachable Responses API endpoint for any device:

- A **pure-Rust CLI** (`pocox`) supervises a local
  `codex app-server` process on the machine that already has Codex
  installed.
- The same CLI ships an in-process **Responses API proxy** that reuses
  the host's `codex login` (ChatGPT account or `CODEX_ACCESS_TOKEN`)
  to serve OpenAI-compatible `/v1/responses` HTTP + WebSocket traffic,
  letting devices *without* Codex installed drive the same model
  through the relay.
- The CLI uses [`pb-mapper`](https://github.com/acking-you/pb-mapper)
  to **register** either service on a relay under
  `pcx:<device>:<kind>:<name>` keys, or to **subscribe** to remote
  ones, materialising them as local TCP endpoints.
- A **Flutter front-end** (under `apps/flutter`, driven through
  `flutter_rust_bridge`) consumes the app-server JSON-RPC protocol
  directly to give every platform a native UI without re-implementing
  the model runtime.

Two ways to wire devices together, both first-class:

- **Self-host** — every device shares one relay address plus a 32-byte
  `MSG_HEADER_KEY`, and talks to the relay directly under `pcx:…` keys.
  Selected by an explicit `--relay`.
- **Hosted account** — the optional `pocox-backend` runs once on a
  server; devices sign in with GitHub, and the backend hands each account a
  short-lived relay credential confined to its own `pcxu:<user>:…`
  namespace. Devices then talk to the relay **directly**: the relay's
  administrator key never reaches a client, accounts stay isolated from
  each other, and the backend is not on the data path.

The repository deliberately does **not** vendor a model runtime; the
user-supplied `codex` binary (and its login state) is the source of
truth.

## 2. Repository layout

```
apps/flutter/              # Flutter UI (FRB-driven, FVM-locked at 3.44.0)
assets/logo/               # Project artwork (poster.png, logo.png)
crates/                    # all first-party Rust crates; see §3 for who owns what
deploy/                    # hosted-backend deployment unit + config examples
deps/
  codex/                   # acking-you/codex fork, branch `pocox`
                           # (git submodule) = upstream openai/codex main +
                           # our adaptations; see §8
  grok-build/              # acking-you/grok-build, branch `pocox` (git
                           # submodule) = the fork's pristine `upstream`
                           # mirror of Grok Build; a source reference, see §8.3
docs/                      # design notes, protocol references, CLI verification
scripts/                   # install scripts, local CI, CI affected-surface gate
vendor/pagable/             # registry source with a 32-bit size-assertion fix
```

`Cargo.toml` is a workspace root; every crate under `crates/` is a
workspace member (see the `members` list for the canonical set).
The Codex submodule under `deps/` is kept **out** of the workspace via the
`exclude` list and retains its upstream lints/profiles. Cargo fetches pb-mapper
from its dedicated `pocox` Git branch; `Cargo.lock` pins the exact commit
and its registry dependencies. No pb-mapper, kanal, or uni-stream submodules
or local dependency patches are needed.

`vendor/pagable` retains the former ARMv7 patch for provenance. It is excluded
and is no longer a dependency or Cargo patch. Keep its runtime source unchanged;
the provenance and patch scope are recorded in its `README.pocox.md`.
Changes under `vendor/` require the full Rust CI gate and must stay outside
first-party formatting and lint rewrites.

## 3. Crate responsibilities

Shared / host side:

| Crate                       | Owns                                                                                           |
| --------------------------- | ---------------------------------------------------------------------------------------------- |
| `pocox-core`         | configuration schema, on-disk `state.toml`, well-known paths, error types, `service::{ServiceId, ServiceKind, sanitize_component, default_device_id}` for `pcx:<device>:<kind>:<name>` relay keys — small, dependency-light |
| `pocox-codex`        | spawning / supervising / inspecting the external `codex app-server` child process, compatible JSON-RPC wire envelopes |
| `pocox-pb`           | async wrappers around the Git-pinned `pb-mapper` client SDK: `RelaySession` (address + credential), register / subscribe / status, `publish` (and the one name-conflict failure a caller must not retry), admin credential issuance, and credential keep-alive |
| `pocox-api-proxy`    | local Responses API proxy: forwards `/v1/responses` (HTTP + WS) to ChatGPT's Codex backend, reusing the host's `codex login`; shared by the CLI worker and the in-app host |
| `pocox-host-svc`     | host-side meta service — remote-viewable codex sessions, per-thread config, attachment upload — published on the relay as a third `meta:<name>` service |
| `pocox-cli`          | user-facing `pocox` binary; account (`login` / `logout` / `account`), setup (`init`), high-level `serve` / `connect` / `api {serve,connect}` / `services {list,default set}` / `status` / `stop`, low-level `codex {start,stop,status}`, `pb {register,subscribe,status}`, `remote-hint`, `version` |
| `pocox_bridge`       | `cdylib + staticlib` consumed by Flutter via `flutter_rust_bridge`; auto-generated bindings live in `lib/src/rust` of the Flutter app |

Hosted-account mode (all optional — self-host never touches these):

| Crate                        | Owns                                                                                           |
| ---------------------------- | ---------------------------------------------------------------------------------------------- |
| `pocox-account-proto` | wire types and `pcxu:<user>:…` key namespacing shared between the backend and its CLI/app clients |
| `pocox-auth`          | GitHub device-flow + web auth-code login, session JWTs, refresh tokens                            |
| `pocox-store`         | SQLite persistence (users, refresh tokens, device flows) for the backend                          |
| `pocox-backend`       | the deployable binary: GitHub-login HTTP API + `/v1/relay` credential vending; see [`deploy/`](deploy/README.md) |

When in doubt, prefer adding a new module to an existing crate over
introducing a new crate. Crates are free; *boundaries* are not.

## 4. Engineering principles

We follow Linus Torvalds–style engineering. In short:

1. **Don't break userspace.** Once a CLI flag, on-disk layout or
   wire-protocol field is documented, it is part of the contract. Add,
   don't mutate. If a breaking change is unavoidable, version it
   explicitly and write a migration note.
2. **KISS / YAGNI.** Avoid speculative abstractions. Add a trait when
   there are at least two real implementations. Add a config knob when
   there is at least one real user who needs it.
3. **Critique code, not people.** Be technical, be direct, be kind.
4. **Faithful upstream behaviour > local heuristics.** If the upstream
   `codex` or `pb-mapper` does something a particular way, mirror it
   instead of layering on top a fragile compatibility shim.

## 5. Code-editing rules

- Comments are written in **English**. Add a comment only when intent is
  non-obvious; obvious code does not need narration.
- Public items are documented (`missing_docs = "deny"` is on at the
  workspace level). When you add a public function, write a doc comment.
- No `unwrap()` / `expect()` in non-test code without a `// reason: ...`
  follow-up. `clippy::unwrap_used` is `warn` and we treat it as `deny` in
  reviews.
- `unsafe` is forbidden by default — crate roots carry
  `#![forbid(unsafe_code)]`. The sanctioned exception is
  `pocox_bridge`, whose `flutter_rust_bridge`-generated code emits
  `unsafe`. If you really need it elsewhere, justify it in review and gate
  it behind a Cargo feature.
- Keep functions short and modules shallow. Refactor when nesting
  goes past three levels.
- Keep handwritten Rust and Dart files at or below 1,000 lines. Split by
  cohesive responsibility (lifecycle, sessions, routes, widgets, tests),
  never by arbitrary line ranges or by compressing code and docs. Preserve
  public imports and visibility. Rust uses child modules and re-exports,
  not `include!`. Dart may use private library parts for state-owned session
  behavior and stateless bridge mixins; keep lifecycle and state ownership
  in one place. Prefer modules over new crates or runtime dispatch layers.
  Generated bindings and localizations remain generator-owned.
- Prefer `tracing` over `println!`/`eprintln!` for anything that is not
  CLI output the user explicitly asked for.
- File paths in handoff messages and change descriptions follow `path:line`
  citations (e.g. `crates/pocox-cli/src/main.rs:42`).

## 6. Workflow checklist

Use this as the default loop for any non-trivial change:

1. **Intake.** Restate the task in your own words. Confirm the problem
   exists. Note any potential for breaking userspace.
2. **Context gathering.** Locate the files that need to change. Stop as
   soon as you can name them; aim for ~5–8 tool calls in the first pass.
3. **Exploration.** When ≥3 steps or multiple files are involved, walk
   dependencies, surface assumptions, and write down the output
   contract (files changed, expected behaviour, tests touched).
4. **Plan.** Produce a multi-step plan that references concrete files
   and functions before you edit anything.
5. **Execute.** Make the change. On failure, diagnose and adjust; if
   blocked, ask the user.
6. **Verify.** Run the verification commands below and reflect:
   maintainability, tests, performance, security, backward
   compatibility. Fix issues before handoff.
7. **Hand off.** Summarise the change, cite `path:line`, list
   assumptions, state risks and next steps.

## 7. Verification commands

Run these (the full set) before claiming a task is done. CI runs the
same commands but **scopes them to the surfaces your change touches**: a
gate (`scripts/ci_affected.py`, stdlib-only) computes which crates are
affected from the diff and runs fmt/clippy/test only when a first-party
crate changed (clippy on the changed crates, test on them plus their
workspace dependents; a cross-cutting change — root manifest, lockfile,
`rustfmt.toml`, `.cargo/`, `deps/`, toolchain — falls back to the whole
workspace), and the Flutter job only when `apps/flutter/` changed. A
change under `.github/` or `scripts/` forces the full Rust suite plus
Flutter. So locally you always run everything below; CI may legitimately
skip jobs your change does not touch.
The upstream/submodule code under `deps/` is deliberately outside this
workspace's formatting and linting contract: do not run rustfmt,
clippy or other rewrite/lint commands against `deps/` unless the task is
an intentional submodule bump or upstream contribution. In particular,
do **not** run `cargo fmt --all`; use the explicit first-party package
list below so path/patch dependencies under `deps/` are never rewritten.

```bash
# Rust workspace — the -p list must cover every workspace member in
# `Cargo.toml`; add new crates here (and in ci.yml) when you create them.
cargo fmt --check \
  -p pocox-core -p pocox-codex -p pocox-pb \
  -p pocox-api-proxy -p pocox-host-svc -p pocox-cli \
  -p pocox_bridge -p pocox-account-proto -p pocox-store \
  -p pocox-auth -p pocox-backend
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --locked

# Flutter front-end (requires `fvm install 3.44.0 --setup` once)
cd apps/flutter
fvm flutter pub get
dart format --output=none --set-exit-if-changed lib test integration_test
fvm flutter analyze
fvm flutter test
```

Optional but encouraged for crates touching FFI or the protocol layer:

```bash
cargo doc --workspace --no-deps
flutter_rust_bridge_codegen generate    # after editing crates/pocox-bridge/src/api/
```

### Fonts (desktop-only Noto Sans SC)

Chinese renders thin and unevenly weighted on Windows with Flutter's default
fonts, so **desktop** builds bundle **Noto Sans SC** (`apps/flutter/assets/fonts/`,
SIL OFL 1.1). To keep the ~17 MB out of the Android/iOS artifacts, the font is
declared only in `apps/flutter/pubspec-desktop.yaml`, **not** the default
`pubspec.yaml`:

- `pubspec.yaml` — the default used by mobile, `flutter test`, and local dev.
  No font. Source of truth for dependencies.
- `pubspec-desktop.yaml` — a copy of `pubspec.yaml` **plus** a `fonts:` block.
  The desktop release jobs (`app-windows` / `app-linux` / `app-macos` in
  `.github/workflows/release.yml`) `cp pubspec-desktop.yaml pubspec.yaml` before
  building. **Keep its dependencies in sync with `pubspec.yaml`.**

`lib/src/fonts.dart` sets the primary family to `Noto Sans SC` only on desktop
(gated on `defaultTargetPlatform`, so `flutter test` — forced to android — takes
the mobile branch); mobile/web use the OS CJK font (PingFang SC / Noto Sans CJK).
To preview the bundled font locally on desktop:

```bash
cp apps/flutter/pubspec-desktop.yaml apps/flutter/pubspec.yaml
(cd apps/flutter && fvm flutter pub get && fvm flutter run -d windows)
git checkout -- apps/flutter/pubspec.yaml   # restore before committing
```

## 8. Working with submodules

`deps/codex` and `deps/grok-build` are git submodules pinned to specific
commits. `deps/pb-mapper` (plus the `deps/kanal` and `deps/uni-stream` forks it
pulled in transitively) is gone. pb-mapper is a Cargo Git dependency on
`https://github.com/acking-you/pb-mapper`, branch `pocox`; `Cargo.lock`
pins its exact commit. Push SDK fixes to that branch, then run
`cargo update -p pb-mapper` here and commit the resulting lockfile after
verification. Normal builds use `--locked` and do not automatically follow
branch updates. After pulling this repo, materialise the submodules with:

```bash
git submodule update --init --recursive
```

### 8.1 External Codex only; built-in engine is unimplemented

**All platforms must run Codex as an external executable. Do not compile,
link, bundle, or launch the Codex model runtime in POCOX.** The UI
reserves a disabled **Built-in engine / 内置引擎** option marked **Not
implemented yet / 暂未实现**. Do not re-enable it through a Cargo feature,
target-specific dependency, build script, or release packaging step without
an explicit change to this product requirement.

- First-party crates may depend directly on upstream **protocol crates only**
  (`codex-app-server-protocol` / `codex-protocol`). No direct dependencies on
  `codex-app-server`, `codex-core`, `codex-arg0`, `codex-config`, runtime
  extensions, or executable/helper crates, even as optional dependencies.
- Upstream protocol crates currently have their own transitive support
  dependencies. Audit the resolved graph on every submodule bump; do not
  claim these are a standalone, dependency-free schema. The graph must not
  include `codex-app-server`, `codex-core`, `codex-arg0`, `codex-exec`,
  `codex-tui`, `codex-windows-sandbox`, or `codex-goal-extension`.
- Keep the external spawn/supervision/readiness/logging path. Resolve the
  binary from an explicit path, saved configuration, then `PATH`. Missing
  Codex must produce an installation/path error; never fall back to a bundled
  runtime.
- Keep the existing bridge `embedded` field/argument for compatibility:
  status reports false, explicit true starts fail before side effects, and
  legacy auto-host preferences restore through external Codex. Users who
  previously relied on embedded hosting must install Codex or select its path.
- Do not build or package upstream Windows sandbox helpers. The installed
  external Codex owns its runtime, sandbox helpers, and version.
- Keep the standalone Responses API proxy functional: both HTTP POST and
  WebSocket GET on `/v1/responses` must forward requests, host authentication,
  streaming events, and upstream errors without requiring an embedded engine.
  Verify both transports when changing Codex dependencies or hosting.
- Avoid parallel duplicate Rust builds and monitor disk space during local
  verification. Prefer reusing build caches; only remove reproducible build
  artifacts when cleanup is needed, never user data or source directories.

### 8.2 Updating the protocol submodule

`deps/codex` remains pinned to the `pocox` branch of
`git@github.com:acking-you/codex.git`. Its historical host-integration shims
are not built into this application. Do not add new runtime shims for this
project. Continue to merge upstream into the shared fork branch rather than
rebasing published history, and record the verified submodule pointer here.

After a protocol bump:

1. Inspect the protocol manifests and run `cargo metadata --format-version 1`
   / `cargo tree -p pocox_bridge` to verify the dependency restriction
   above on all targets/features.
2. Mirror any still-required upstream WebSocket fork patches exactly and
   regenerate `Cargo.lock` without unrelated dependency upgrades.
3. Keep `sqlx` compatible with the protocol graph's transitive
   `libsqlite3-sys` version: Cargo permits only one native sqlite3 linker.
4. Keep the root Rust toolchain at or above the protocol crates' compiler
   floor and keep CI/release toolchains in sync.
5. Run the full first-party verification in §7 and build the desktop UI.
   Never run formatting or lint rewrites inside `deps/codex` for a routine
   application change.


### 8.3 Grok Build reference source

`deps/grok-build` tracks the `pocox` branch of
`git@github.com:acking-you/grok-build.git`, cut from that fork's `upstream`
branch (pure `Synced from monorepo` commits; its root `SOURCE_REV` names the
SpaceXAI monorepo commit). Keep `pocox` for POCOX's maintenance; bring
upstream syncs in by merging `upstream` into it, never by rebasing
published history. It is a reference, not a dependency: it is excluded from
the Cargo workspace, nothing links its crates, and Grok runs only as the
user's installed `grok` (§8.1 applies to it as to Codex). First-party code
mirrors the rules it needs (the session store layout and replay in
`host-svc/src/native_history/grok/`, the model configuration in
`host-svc/src/acp/grok.rs`) and cites the upstream files. When the pin
moves, re-read those files and the ACP surface (`xai-grok-shell/src/agent/
mvp_agent/acp_agent.rs`), then run the opt-in `grok_live` tests. Never run
formatting or lint rewrites inside `deps/grok-build`.

## 9. Roadmap (rough)

The order below is our current best guess; it is not a contract.

1. **CLI bootstrap (done).** `pocox version`, configuration
   loading, basic logging, command-line schema + dispatcher.
2. **Codex process manager (done).** `pocox codex
   start|stop|status` spawning the user's local `codex app-server`,
   persisting PID / listen URL metadata to `state.toml`, surfacing
   logs.
3. **pb-mapper register / subscribe (done).** `pocox pb
   register` and `pocox pb subscribe` re-using the upstream
   `local::server::run_server_side_cli` /
   `local::client::run_client_side_cli` helpers.
4. **Combined `serve` / `connect` flow (done).** `pocox serve`
   starts or reuses the local app-server, registers it with a relay and
   tracks the daemonised pb-mapper worker in `state.toml`;
   `pocox connect` subscribes on the client side and prints the
   matching `codex --remote ...` command.
5. **Multi-device service selection + direct API proxy (done).**
   POCOX service keys use `pcx:<device>:<service>:<name>`;
   clients can discover services, set a local default target and choose
   app-server or direct Responses API proxy flows independently.
6. **Hosted account mode (done).** Optional `pocox-backend`:
   GitHub login (device flow + web auth-code), SQLite-backed sessions,
   and `/v1/relay`, which vends each account a short-lived pb-mapper
   credential scoped to its own `pcxu:<user>:…` namespace. Clients then
   register/connect against the relay **directly** — the backend holds the
   administrator key and stays off the data path. It previously brokered
   every byte on its own port; direct connect removed that hop, so backend
   availability is no longer a prerequisite for two of a user's own devices
   to talk. Self-host stays the escape hatch behind `--relay`.
   Deployment unit lives in [`deploy/`](deploy/README.md).
7. **External Codex only (2026-09-13).** All desktop hosts use an installed
   external `codex`. The former embedded runtime is removed from builds and
   packaging; **Built-in engine** is a disabled, unimplemented placeholder.
   The bridge uses local wire envelopes: upstream protocol crates also pull in
   runtime support and are not linked into application artifacts (see §8.1).
   macOS GUI hosts resolve the login-shell PATH lazily in the Codex worker path;
   only Codex children receive it. Preserve inherited tool precedence, never
   mutate the process environment, and clean up the probe's owned process group.
   Native macOS host checks are part of the required CI result.
8. **App-server protocol sync (2026-09-24).** Codex fork merged upstream main
   `c098f97e5` at `c08819510`; CLI and UI share the acknowledged initialization handshake.
   Resume responses restore collaboration mode, opaque `fileId` image references
   keep a visible unavailable preview without host file reads, and paginated
   item timestamps remain distinct from whole-turn duration. Rust requires 1.95+.
   Flutter reads v2 accounts and current thread model/effort, and answers
   asynchronous questions with `turn/steer` while running or `turn/start` when idle.
   **Strongly-typed JSON-RPC client (next).** Replace the
   `serde_json::Value` surface in `pocox-codex::protocol` with
   local types verified against the upstream wire schema, without importing
   its runtime dependency graph.
9. **Mobile footprint and connection recovery (2026-09-25).** Keep protocol
   envelopes local to avoid importing the upstream protocol crate's interpreter,
   database, and TLS dependencies. Resolve remote follow tunnels off the async
   worker; preserve failed monitoring refreshes for heartbeat/reconnect recovery.
   Open bounded 20-item tails, with older history available through normal pages.
10. **Flutter UI evolution.** `apps/flutter` consumes the bridge via
   `flutter_rust_bridge`. P1 shipped: onboarding (relay+key, `pcx1:`
   import/export, persisted to `config.toml` 0600), service discovery,
   API-service subscribe (local OpenAI-compatible endpoint), settings,
   responsive Material 3 (light/dark). P2 shipped: app-server remote
   control (threads, live event stream, approvals, attachments,
   per-thread config). P3 shipped: chat-first home — `/` resolves a
   host (last used → locally hosted → first reachable), auto-connects,
   and opens the latest session with all sessions in the sidebar; the
   services hub lives on at `/manage`; desktop auto-restores hosting on
   boot (`ui_state.json`). P4 adds structured Guardian review history,
   a searchable turn directory, bounded long-step browsing, and coordinated
   initial-load / continuation / navigation / monitoring feedback. The composer
   grows and shrinks with text, preserving the manually resized minimum height.
   Conversation drafts survive navigation during the app session, with sidebar
   draft/queue indicators, an expanded editor, explicit height reset, separate
   Queue/Stop controls, IME-safe desktop sending, and retryable attachments.
   New-session views focus on the project and input. Project headings reveal
   one new-conversation action on hover/keyboard focus, with right-click menus
   and touch long-press sheets. Unsent drafts are isolated by host and project;
   a server thread is created only on first send.
   Mobile messages offer long-press copy, text selection and native sharing.
   Editable conversations can reuse a user message in a separate editor;
   adding it preserves existing draft text and attachments and never sends
   automatically or rewrites history. Read-only views expose no edit action.
11. **Persistent controller history (2026-09-25).** The App owns a configurable
    512 MB disk cache shared across hosts, reusable after restart. Independent
    meta `/history/v1` routes reconcile bounded windows and UTF-8 text prefixes
    through the user-requested `SessionHistorySource` trait; Codex is the first
    production adapter. Show cached history before connection, keep stale state
    visibly read-only, and prefetch running tails only in the foreground. See
    [`docs/session-cache-sync.md`](docs/session-cache-sync.md) for scope and limits.

12. **Controller turn modes (2026-09-25).** New conversations default to
    `approvalsReviewer: auto_review` with on-request approval and the workspace
    sandbox. Retain manual, read-only and full-access presets; the existing
    persisted `auto` tag keeps its manual-review meaning. Offer Fast only when
    the model catalog advertises support and explicitly send `default` when
    switching it off. Running composer sends queue for a new turn by default;
    the optional Supplement control uses `turn/steer` with an expected turn id
    and retains the draft on rejection. Queue draining preserves newer drafts.

13. **Native image results (2026-09-26).** Plan mode lives under Advanced settings
    on desktop and mobile; explicit saved Plan sessions remain supported. Render
    native `imageGeneration` items as visible outputs with generation/loading,
    failure, preview and retry states. Recognize the exact rollout extension kind
    `image_gen.generation`; only its artifact path authorizes a generated-image
    read. Refresh image references when monitoring another writer, keep loading
    state bounded by the confirmed active turn ID, and scope image bytes to
    host/thread. Bound inline results before FRB transport and render native
    images in the read-only viewer too.
    See [`docs/native-image-generation.md`](docs/native-image-generation.md).

14. **Session file links (2026-09-26).** Explicit Preview / Download actions
    resolve files against the selected host and session in live and read-only
    views. Local session viewers read this device directly; service-backed views
    require a shared-filesystem challenge or an in-process host before local reads.
    Remote previews are bounded; downloads stream to disposable controller
    files before native desktop/mobile saving. Preserve legacy Host Files
    downloads through root-confined `/fs/read` only on a missing new route.
    Keep automatic image authorization
    separate from explicit conversation-link reads. Remote localhost web links
    explain pb-mapper mapping and never open the controller's loopback address.
    See [`docs/session-file-links.md`](docs/session-file-links.md).

When you ship a milestone, update `README.md` (Status table) **and**
this file's roadmap so the source of truth stays in sync.

15. **Relay recovery and maintenance (2026-10-03).** Network workers retain pending
    registrations/subscriptions through offline startup. Runtime diagnostics report
    the SDK actually loaded by each worker; an older worker reports unknown.
    `pb restart --role <register|subscribe> --key <exact-key>` verifies process
    identity and credentials before replacing that worker, preserving local Codex,
    API proxy and host supervisor processes. See `docs/relay-worker-recovery.md`.

16. **Low-latency relay and protocol sync (2026-10-04).** SDK 0.6.0 uses a shared
    per-leg data key with disjoint directional nonce prefixes, without data-key
    derivation, extra setup round trips or frame bytes. `deps/codex` merges the
    freshly pulled upstream main `afb436df8b` at `beaefbdf0` (0.2.7 corrects the
    stale local pin in 0.2.6). Aggregated command output, persisted truncation
    markers and future error variants retain their existing display behavior;
    interrupted turns may carry an explicit error. Native app-server tracking
    excludes Linux thread IDs and recognizes replaced executables; worker identity
    survives boot-time clock corrections. On 2026-10-08 `deps/codex` moved to
    `b360f3350`, a clean merge of upstream main `b38942ce7`; the app-server wire
    surface is unchanged apart from optional fields. See
    `docs/app-server-protocol-sync.md`.

16. **Cached history and touch feedback (2026-10-04).** Local session lists
    explain mobile filesystem unavailability, empty desktop history and retryable
    scan failures. Opening restores retained sequential and selected-turn windows
    locally within the memory budget; preserve real gaps and source generations.
    Streaming writes a separate 100-item checkpoint, never the full display view.
    Explicit history loads reveal and briefly highlight new rows; scroll loads
    preserve the reading anchor and short-page edge gestures can load history.
    Compact navigation is draggable and reads unloaded turns from the full
    directory. Mobile message press feedback remains until menu dismissal and
    respects reduced motion. See `docs/session-cache-sync.md`.

18. **Live voice controls (2026-10-05).** Voice threads persist the upstream
    `threadSource: pocox-voice` classification independently of their title.
    Client-owned WebRTC carries microphone/output audio; the existing bridge
    carries app-server signaling, with upstream V3 and its V1 voice catalog.
    Keep backend handoffs and approvals on the ordinary Codex path. End capture
    on call stop, navigation, backgrounding, failure and disposal; never silently
    restart it. Read canonical speech history through bounded `thread/timeline/list`
    pages. No system speech or extra speech provider is implemented. Touch message
    feedback starts only when long press wins over scrolling. See
    `docs/live-voice.md`.

21. **Composer dictation (2026-10-08).** The composer microphone runs on the
    same upstream V3 realtime path as live voice: an ephemeral
    `pocox-dictation` thread, kept open in the background with no
    microphone until a take attaches one, then transcript deltas typed at the
    cursor. It uses only the host's default realtime model and never speaks.
    It yields to a live call, ends its take on navigation, and never sends.
    chatgpt.com's transcription endpoints are not used (Cloudflare refuses
    non-official clients). On iOS and Android (2026-10-16) the line exists
    only during a take, because an open media link takes the device's audio
    from other apps; the realtime endpoint refuses a send-only offer's audio.
    Ended calls and takes give the audio back: an iOS observer of WebRTC's
    audio engine deactivates the session with `notifyOthersOnDeactivation`,
    and Android requests transient focus. See `docs/live-voice.md` ›
    Composer dictation.

19. **Recovery and cache boundaries (2026-10-05).** Scope CLI watchdog stops to
    their own listener; retain pending meta registrations across startup outages.
    Credential refresh tasks follow account/backend/deadline changes and stop on
    logout. Mobile reconnects discard obsolete completions, recover on foreground
    return and restore optional metadata separately; sends wait for settings.
    Live transcript tails have independent item/thread/byte bounds and indexed
    updates. Cache byte accounting is invalidated under the cross-process lock
    before mutations; atomic data/manifest writes and quota reservations remain.
    Worker transition history survives worker exit, and controller recovery stages
    appear in the existing exportable logs.

20. **Guardian session hierarchy (2026-10-06).** Display native automatic approval
    progress and results in the parent conversation, keyed by review ID. Restore
    persisted assessments through the host history adapter without changing Codex
    page cursors. Preserve explicit parent links in session inventories, with
    children collapsed by default (including Active) and ancestors retained
    during filtering. Manual folds take precedence over automatic reveals and
    survive running-state updates and inventory refresh. Open Guardian
    sessions read-only, with navigation to the parent; never resume or take over
    a reviewer. See `docs/guardian-sessions.md`.

22. **macOS distribution and theme switching (2026-10-09).** Release app jobs
    require Developer ID signatures and accepted, stapled Apple notarization
    for DMG and ZIP downloads. Never fall back to unsigned publication. Keep
    signing credentials out of source and build steps. Theme snapshot capture
    is optional; applying the preference must survive capture failures and
    release builds without debug-only render getters. Keep the blue Dock icon
    fixed across themes (the bundle AppIcon). The menu bar shows the mark as a
    one-colour template glyph (`assets/tray/tray_template.png`, 2026-10-17),
    which AppKit paints in the bar's own colour like every other status item;
    never the colour tile or the transparent splash glyph there. See
    `docs/macos-release.md`.

23. **Generic ACP agents (2026-10-10, PR #99).** Hosting can launch any ACP v1
    stdio agent configured as program + argv, passed verbatim (no shell);
    the Claude adapter is the built-in preset (OpenCode is a native engine,
    item 29). The service kind is `acp:<name>`. Codex and OpenCode use their
    native engines; other agents use the generic ACP engine and host
    lifecycle. The host (`host-svc/src/acp/`)
    is the agent's only ACP client and owns its process group. Lifecycle rules: one lifecycle
    lock; exits (stdout close or leader exit seen unreaped via `waitid`
    `WNOWAIT`) go to a single supervisor task; restarts are bounded; group
    signals are sent before reaping; `stop` is final, bounded and cuts a
    pending handshake short and joins a stop in progress; Windows hosting
    stays disabled. One ownership table (`serve_acp::owners`) holds every
    owned agent from before its launch until its cleanup finished, retiring
    ones included; app quit (`serve_acp::stop_all`) closes its barrier and
    stops everything still in it, so overlapping quits and ordinary stops all
    wait for process cleanup, and agent processes are stopped before relay
    keys are withdrawn. Re-publication results install only into the same
    host incarnation, context and unchanged registration slot.
    Controllers reach the host through the versioned `/acp/v1` HTTP + SSE
    gateway. Snapshots are scoped to a generation and host incarnation
    (`hostId`) and carry a sequence watermark; `reset` forces a resync, and
    running turns are re-installed from the host's fold (`acp::Replica`)
    before later deltas apply. The bridge dispatches every session call
    through `engine::session_engine` by key kind, never by provider name.
    Codex stays the native engine. Rules to preserve:
    - Capabilities are conservative until negotiated, and Flutter gates every
      control on them — attachments too, at one admission boundary
      (`attachment_gate.dart`) for picker, drop and paste; a late result
      (picker, clipboard, file read before upload) is re-admitted through its
      `AttachmentTicket` against the original draft's admission revision,
      which moves when that view turns read-only, its host is lost or
      replaced, or image support goes away. Health comes from an open event
      stream only (never from a snapshot); an unreachable or refusing host
      emits `acp/host/state {"connected": false}` and Flutter reconnects.
    - Permissions are answered with the agent's exact option ids.
    - Session cwds are admitted by the host and immutable; the stored cwd
      wins on reopen and stays authoritative, while a pending load/resume
      grants no new authority until it succeeds (failure revokes it).
    - Session stores are keyed by a keyed digest of the resolved program +
      argv (`acp/<hex(name)>/<source>.json`, `acp/source-key`); a changed
      invocation inherits nothing. Writes are queued under the state lock,
      coalesced per session and bounded; corrupt files are quarantined.
    - Every prompt dispatch and `session/cancel` of a host goes through one
      dispatch lane that re-checks the running turn; cancel names its turn.
      The bridge sends `hostId` + generation (`acp::Identity`) with every
      mutation and the host refuses stale ones; the fields are optional on
      the wire, so this guards stale bridge views, not arbitrary callers.
    - Peer frames with a deadline are delivered (written and flushed), never
      queued, or the connection is closed (`CloseReason::Stalled`). Prompt
      (30 s) and control (10 s) budgets start before the dispatch lane; a
      control exchange that cannot complete closes the generation, so no
      consumed permission or cancel is left unanswered on a live connection.
    - Transcript bounds count every retained byte and hold within one turn;
      at most 32 transcripts, busy ones never evicted (refuse instead); item
      ordinals are never reused; agent ids are compared exactly (long ones
      by digest); gaps, truncation and dropped content are shown.
    - Live user messages name their sender: a prompt or supplement carries
      the sending view's random `clientId`, echoed on `turn_started` /
      `supplement` (`null` when none). That view keeps its one copy (its
      optimistic copy, or the host's item if that came first); every other
      view shows the host's item live. Never an idempotency key; recoveries
      and older hosts show user messages through history reads only.
    - Recovery completes ended turns before announcing successors; item
      events carry `turnId`; an unreadable running fold stays
      unsynchronized and is retried, never folded from a bare update; an
      image-prompt turn is begun only from the host's fold. History reads
      are accepted only from the view's `hostId` + generation and current
      connection. Synthetic notice/gap ids start with `#`; an empty
      `contentOmitted` notice removes the row.
    - Codex and ACP claim instance names in one shared table, held
      until the host's cleanup (including stop-all) has finished.
    - Bridge ACP connections and relay meta tunnels are owned by the
      transport context (account + relay, or relay + key). One revision
      (`transport::epoch`) is captured before a resolution reads the
      configuration and is checked atomically when it is observed and when
      a connection or tunnel registers; a stale resolution never becomes
      current. Registry entries own their workers (one winner per key).
      Answers apply only to the connection (`acp::Link`) that asked.
    - Pending-reopen titles keep "no signal" apart from an explicit clear.
    - History is only what the host retained.
    - The mock agent stays a Cargo example (built by `cargo test`, never
      shipped).
    - The ACP engine was exercised on macOS through a public relay with
      independent host/controller processes, using the since-removed
      OpenCode 1.18.35 ACP preset: live streaming, session
      inventory/configuration, permission rejection/approval, cancellation,
      meta file previews, reconnect and process-restart history recovery.
      That is evidence for the ACP engine only. The opt-in
      `acp_live_remote_control` test is ignored in ordinary CI; it requires
      explicit disposable fixtures and credentials. Two processes on one
      Mac do not establish acceptance on a second physical device or OS.
    - The opt-in, ignored
      `engine::hosting_live_tests::hosting_live_coexistence` hosts two native
      Codex and two ACP hosts in one process, with native handshakes only (no
      native model prompt). Each stop, restart or recreation must leave every
      other host unchanged. It runs on one Mac only.

    See `docs/acp-agents.md` and ADR-0003.

24. **Hosting and agent controls (2026-10-11, PR #99).** New hosts are picked
    from an agent icon grid in two sections: built-in presets (Codex,
    native OpenCode, Claude adapter; launch templates, not bundled runtimes) and
    saved configurations (saved, then custom, which creates one);
    marks are bundled glyphs chosen by the engine or the explicit ACP profile
    id (`Capabilities.profile_id`), never by a host's instance name. Remote
    ACP entries also read the existing `/acp/v1/info` profile before connecting
    (2026-10-21), through a temporary tunnel closed after the read. Discovery
    identities grant no capabilities; refresh and transport changes invalidate
    them, and an open phone host sheet updates as identities arrive. Hosting is
    platform-gated only (desktop), in self-host and account mode; the
    manage page, home hero and host switcher always offer it, for zero, one
    or many hosts. Several Codex and ACP hosts coexist with unique default
    names and an automatic port beside another Codex host. Codex restore
    records are per name (`autoHostCodex`, legacy `autoHost` still written as
    its first entry); stopping a host forgets only its own record. At most 16 restore records per
    kind and 50 saved agents; a host beyond that runs and a notice says it will
    not be restored (a refused saved agent is reported, not shown as saved).
    Preference changes made during the initial load are replayed onto the
    loaded file; the store's `ready` and the per-record verdicts are decided
    there, never on the interim state the provider's `future` may resolve to. An open option menu is bound to the conversation, load,
    capability and connection generation it opened for. ACP config
    options render model → effort (`thought_level`) → mode, searchable when
    long, with full labels in tooltips/semantics and pending/failed states;
    each answer's complete option set replaces the old one, a `mode` option
    hides legacy modes, and value ids stay opaque (`provider/model/with/slashes`).
    A new ACP conversation automatically opens its session for the chosen
    project without sending; the first send waits for that same attempt.
    Only a completion for the same service, project, draft and conversation
    is adopted. Native Codex keeps
    its own model/effort path and lazy thread creation.

25. **Composer recovery, usable Claude preset, ACP supplements (2026-10-12,
    PR #99).** A turn's end releases every control it gated in the same
    session: the host re-announces the session state after `turn_ended`, the
    bridge clears a cached `runningTurnId` that still names the ended turn,
    and the screen re-reads agent settings. An admitted turn holds the queue
    until its `turn/started` arrives (or, after 20 s, the host's history says
    it runs or ended — elapsed time alone never releases it); a repeated end
    of an already-ended turn is ignored. The wait is owned by its admission
    token (draft, thread); only an authoritative history reload of that
    conversation from the current host connection, begun after the
    admission, settles it (running or idle) — failed, cached, display-only,
    obsolete or overtaken reloads, and any read answered after its
    connection was lost or replaced (the screen's link epoch, which a
    capability re-read does not move), release nothing; the reconciliation
    retries and the reconnect's own reload answers instead. A stale end
    (`turn_ended` of an older turn after a newer start) never clears the
    bridge's running turn. A failed queued message keeps its text and
    attachments first in its paused queue, and its Retry is offered again
    after a reload, reconnect or reopening. Only the host's listed
    pre-admission refusals (or a failure before `turn/start` was sent) are
    definite and retried as is; any other failure is uncertain: ACP has no
    request identity and history is bounded and shared, so no history answer
    resolves it, and it is sent again only by the user's explicit Retry. A
    send's every step (model list, session start, turn dispatch, answer)
    belongs to the service and connection it began on: nothing is dispatched
    on a moved connection, and an answer arriving after it moved adopts
    nothing — an ordinary message returns to its draft with the reason, a
    queued one stays queued (refused or uncertain). A session created for a
    draft is still adopted by it after navigation. Every retry re-sends its
    own captured content, the native duplicate check is bound to its thread
    and connection, and each send releases only its own composer lock.
    The Claude preset's bare `claude-agent-acp` is resolved by
    `host-svc/src/acp/claude.rs` (adapter on the child PATH, global install
    and version-manager directories, then the app's prepared copy with a
    current marker and a consistent installation; Node.js >= 22 found by a
    `node --version` probe bounded in time and output that runs in its own
    process group, reaped or group-killed; npm is taken only beside a
    compatible Node.js, possibly a later one than the runtime; the native
    `claude` passed only through the child's `CLAUDE_CODE_EXECUTABLE`, an
    inherited value kept). A package script runs as `node <script> argv…`
    through the additive `AgentHost::create_launching`; `HostOptions`, the
    spec, its argv and the session record key (the adapter path) stay what
    they were. An explicit path or any other program is launched verbatim;
    the native CLI is never spoken to.
    Claude hosting inherits allowlisted environment variables (including the
    macOS login shell) and exposes per-host overrides for credentials, model
    aliases, reasoning/output and network controls. Secrets stay in private
    host storage, with no readback or new login flow. Save and explicit restart
    remain separate. Preparation displays measured package bytes and speed,
    never a made-up percentage or download total.
    A missing adapter can be prepared by **Prepare ACP environment**, without
    saving, starting or restarting hosting, or by an explicit Start that
    announced it for the same agent and environment from an open editor
    (`acp/claude_setup.rs`, bridge `engine/claude_setup.rs`): exactly
    `@agentclientprotocol/claude-agent-acp@0.89.1` with scripts off into
    `<state>/acp-runtime/claude-agent-acp`; reuse and install share one
    consistency check of marker, lockfile entry (version and recorded
    integrity, not a re-hash), manifest and entry script; cancellation is
    checked before npm starts and before publishing; marked and renamed
    atomically; one preparation at a time, detection runs off the state lock,
    cancel stops only its own npm group. Restoring a host never prepares. ACP
    supplements use `_session/steering` with
    `idleBehavior: promptRequired`, offered only when the agent advertised
    top-level `_meta.steering.supported`; `injected` (naming the expected
    turn) adds the input to that turn, `promptRequired` makes it the next
    queued turn, anything else — including an answer arriving after the
    connection or host changed — is an unknown outcome that is never retried
    or turned into a prompt. Ownership (service, host connection and
    generation, thread view, draft and request) is checked before any draft,
    attachment or queue change: an answer that no longer owns its input
    leaves all of it — and a newer request's mode, notice, Retry and lock —
    untouched; only when nothing newer owns the same view does it show a
    notice, and an added input then gets a display-only refresh that keeps
    the notice, settles no admission and drains nothing. An owned answer
    takes exactly its snapshot, and after a history load since, the host's
    history shows it instead of a local copy. The full Rust and Flutter
    suites pass; on one Mac a live run prepared the pinned adapter into the
    app cache beside a compatible Node.js, and the real Claude adapter
    answered, took an injected supplement and queued one turn when idle
    (`promptRequired`). See `docs/acp-agents.md`.

26. **Per-host model service and hosting editor (2026-10-12, PR #99).** One
    responsive `UtilityPage` editor (`apps/flutter/lib/src/hosting/`) creates
    and edits hosts; `LocalHostDialog` remains as a typedef. Each instance name
    saves, per canonical name (`engine/host_names.rs`), a model service and
    optional desired runtime (`engine/host_profiles.rs`): existing
    configuration (a missing record, so older hosts are unchanged), official
    account (Codex only, `model_provider="openai"`, `openai_base_url` cleared,
    `chatgpt_base_url` reset) or a custom provider. Only real mappings: Codex →
    Responses (`pcx_host_<hex>_<authority>`, `env_key`); Claude preset →
    Anthropic Messages (`ANTHROPIC_*` env and session settings, custom
    headers reset, key required); native OpenCode → Responses, Anthropic
    Messages or Chat Completions (item 29); other ACP agents →
    existing configuration only (the former OpenCode ACP custom routes and
    catalog plugin are removed). An unsupported
    saved source or API stays visible and blocks saving. Codex hosts read
    their effective configuration back (`config/read`) after start and every
    watchdog restart and refuse a managed or foreign override; the private
    sign-in server is checked the same way before any login request. The
    model is the provider default, never per-session persistence. Keys are one
    printable token, commit atomically under a cross-process lock (0600) and
    never appear in argv, status or records; staged saves pin the keys they
    may restore and never expire by age, cleanup needs the lock, an
    authoritative read and a durable record write, an absent read answers the
    absent snapshot, and a start launches what its stage committed. A keyed
    Codex host's raw output is never kept: its log and viewer get fixed
    notices only (`pocox_core::redact`); ACP stderr is discarded. An
    authority generation keys ACP session stores. Every start, stop, apply and
    watchdog restart holds the name's lifecycle lease (restarts also check the
    incarnation); quitting fences new hosts, closes admission and waits up to
    the lease bound, and fails, keeping the app open with "Quit again", while
    anything it owns may still run. A launch's identity is captured at spawn;
    it owns its endpoint only while every holder of a listening socket its
    listen address reaches (same address and family, applicable wildcards;
    `core::listener`: `/proc`, `lsof`, `netstat`, tools bounded in time and
    output, any failure "cannot be told") is that process or its descendant,
    observed at the port wait, after `/readyz` and after the effective-route
    request (point-in-time checks, not proof of every request). An owned
    process whose stop failed stays in a ledger until its exit is seen: its host stays listed with the reason and
    a Stop retry, the name stays Codex's (no ACP host takes it), and Stop,
    Apply, quit and relaunch fail meanwhile. A new host is saved and
    started as one operation. Saving changes nothing that runs; an explicit,
    confirmed apply names the incarnation taken before confirmation and the
    revision saved, validates before stopping, restores the previous runtime on
    failure (an ACP agent's exact captured launch) and reports a failed
    restore, and never signals an adopted app-server. Official sign-in runs on
    an owned private loopback app-server per attempt (`engine/codex_login.rs`):
    attempts are reserved before spawn until their child stopped, refused
    after quit begins, and stopped by waiting for process exit; a child that
    did not exit keeps its place in the limit and is retried by closing that
    attempt again or by quit. The editor
    gates on the authoritative load (the ACP baseline includes the instance
    name and save toggle),
    keeps per-choice model-service and agent drafts, ignores detections older
    than a prefill, cancels only the adapter preparation it started (a joined
    page may stop waiting; a replaced run is never its result), and asks
    before leaving with unsaved edits. The `api:` proxy is a separate official
    Responses service. Evidence gaps and the supported matrix are in
    `docs/hosting-configuration.md`. Settings ("Hosting and model service"),
    Codex setup and the chat's setup banner reach the same editor
    (`hosting/host_picker.dart`: a running host picked by its identity, or a
    new one; the chat opens its own host); opening it saves, starts and signs
    in nothing. Codex setup keeps Codex's own sign-in and prompt option; its
    global custom-provider form is replaced by that per-host flow (the bridge
    call and on-disk config are unchanged). One entry runs per originating
    page, and a host-list read answered after that page was covered or
    closed opens nothing. Rust passed (743, 14 ignored); Flutter passed l10n,
    format, analyze and 1326 tests (5 existing skips), and the macOS profile
    build passed. Real models answered through native Responses, the
    since-removed OpenCode ACP routes (Responses, Anthropic Messages), and the
    official proxy (HTTP/SSE and WebSocket, public relay); Chat Completions
    only against a local fixture. Interactive OAuth completion, other platforms,
    hosted-account mode and effort options are not exercised. Native UI
    checks covered Settings and Codex setup entries to running and new
    hosts, repeated selection, keyboard cancellation, return navigation
    and unsaved-change protection.

27. **Sidebar refinement (2026-10-13).** Selected conversations use neutral
    surfaces. Running rows combine a rotating indicator with a faint sweep;
    reduced motion uses a static mark and label. Hierarchy controls preserve
    keyboard/RTL semantics and 44px touch targets. Narrow sidebars and large
    text put metadata below titles. Paint-only animation respects TickerMode
    and releases its controllers on disposal.

28. **Provider-native history and ACP first use (2026-10-14, PR #99).**
    Desktop Local sessions selects Codex, Claude or OpenCode without starting
    an ACP connection. Provider-native history reuses the read-only viewer,
    bounded pages, source generations and foreground revision polling.
    Claude uses the installed official SDK's read-only exports; OpenCode
    uses a desktop-only, read-only SQLite reader for known v2/legacy schemas.
    Native history navigation never calls session/load, resumes a writer or
    downloads a runtime. Claude owners require matching native session ID,
    PID, start time, executable and cwd; unavailable evidence stays unknown.
    Independent local views stay read-only and continue a session only by
    opening it on a running host of its provider. Connected hosts decide
    session access with fresh ownership, source and native-child checks, plus
    a POCOX cross-process claim retained through uncertain cleanup (item 29
    replaces the explicit Session control dialog with automatic access).
    Native clients do not honor that claim; never describe it as a
    provider-wide lease. Release by any controller withdraws write admission
    while keeping drafts and queues.
    Keep remote host roots separate from the controller's filesystem.
    ACP new conversations prepare automatically, with one attempt per draft
    and no extra setup click. The directory picker supports a typed host path
    even with no saved projects; native selection is limited to the host
    computer. See [provider-native history](docs/native-agent-history.md).

29. **Native OpenCode and automatic session access (2026-10-15).** OpenCode
    is a third engine: the host owns the installed `opencode serve` and speaks
    its v1 HTTP + SSE API; the service kind is `opencode:<name>`, protocol
    `opencode-http`, provider `opencode`. Several OpenCode hosts may run, one
    per real database source across POCOX processes (item 33); its model
    service is OpenCode's own configuration and sign-ins, or a per-host
    custom provider (Responses, Anthropic Messages, Chat Completions; no
    official account, plugin or ACP route), and its desired runtime is the
    executable and its history (`HostRuntime.opencode`); restore starts with
    both as saved. The
    `opencode acp` preset, catalog plugin and custom routes are removed; their
    saved records are dropped on load, never relaunched as generic agents.
    Rules to preserve:
    - A new ACP or OpenCode conversation needs a project folder: a send
      without one opens the folder picker and sends nothing (no optimistic
      copy); a session that could not be created returns its message to
      the composer. Codex may still work outside a project.
    - Draft sessions are created on first send; draft model/agent/variant
      choices stay on the draft (ACP reads its cached draft settings with an
      empty thread id; OpenCode reads its project's asynchronously through
      `app_draft_session_settings`), are applied to the created session
      before the message, and never mutate host-wide defaults or send a
      config change with an empty id.
    - Models, agents, variants and commands are per project
      (`app_draft_session_settings`, `app_command_list_for_project`; a real
      session resolves its own directory). OpenCode's model is a session
      option: with `session_config` the Codex model menu, effort and Plan
      are off and a turn sends no model, effort or collaboration mode. FRB
      reads of these settings are async (`app_session_settings_refresh`;
      ACP keeps the cached sync path): coalesce, drop answers for a moved
      project/thread/link, never let an older answer replace a newer choice.
    - The Codex setup gate applies only to a Codex app-server, never to
      OpenCode or ACP hosts.
    - `/` commands only write `/name ` text; the host interprets exact known
      names. Permissions keep the option-id card; questions add `multiple`
      and `isOther`, and cancel means reject. A message ID is not an
      idempotency key: uncertain sends stay queued for explicit Retry.
    - Session access (`app_session_open` / `_access` / `_release`) is
      automatic for Claude ACP and OpenCode hosts. Write only from a fresh
      no-owner admission; otherwise follow with the reason code. Recent
      writes or quiet time never mean running or free. Another OpenCode
      process on the source is `external_source_open` (turn unknown). An
      idle native Claude client still holds its session. `released_here`
      suppresses reacquisition until Continue here. No override.
    - The host retains at most 256 sessions and evicts only idle ones
      OpenCode confirms idle with no pending request (released first, then
      least recently used); an unverifiable directory is skipped and fails
      the open only when no directory is safe. A session without a
      retained admission (never admitted, evicted, or after a host restart)
      is `not_opened`: background checks never open it; an explicit Check
      now opens it afresh when its own answer says no writer and idle, and
      Continue here opens it; `released_here` still waits for Continue here.
    - Only a 404 `session_not_found` from the session metadata route of the
      same host identity evicts that controller thread (ancillary
      `native_request_failed` 404s keep the cache). OpenCode events are
      process-local, so an access check or follow read answered that way
      also counts as deletion (another process deleted it): access becomes
      blocked `not_found` without recheck and the follow ends.
      `thread/deleted` drops it from the list, and the view treats the ID as
      terminal for its events, follow checks and settings reads; a replaced
      host identity and other errors stay failures.
    - An abort answered `false` ends the turn only on a fresh idle status.
    - Follow history replaces the optimistic copies of messages sent here
      only by host user messages it newly shows in the same turn (never by
      text); re-reading the same history changes nothing.
    - Session UI gates on capabilities (`hostAccess`, `draft_options`,
      `commands`, `question_multiple`, `permission_feedback`), not names.
    - A custom provider's model is its default, not the only model: start
      and Apply read the gateway's `/models` with the saved key (Anthropic
      paging, OpenAI list; bounded, no redirects) and register every ID and
      name plus the default. A failed read keeps only the default model with
      a host warning; applying again retries. Never import provider options.
    - Apply prepares before it stops and relaunches the previous prepared
      launch on failure. Stopping a host ends its controller SSE streams
      explicitly (they outlive the listener), so views reconnect to the new
      incarnation instead of holding a stale stream.
    - Quit (`serve_stop_all`) closes OpenCode admission and stops each host
      under its lease; a failed stop or pending startup cleanup fails the
      quit. macOS native quits go through `NativeQuitGate` to the same path.
    - Model failures are classified by the host from bounded fields into a
      fixed reason; the provider's message is never published. One inline
      card per failure, keyed by the host's item and exact prompt turn;
      Change model sends nothing; Retry resends the exact original prompt
      only on explicit action and is withheld for a truncated, attachment-
      missing or non-inline-image copy. Option saves hold every send path
      and never auto-send when they end.
    - `reasoningOutput` only for a completed message with reasoning and no
      separate text: shown in full with its source note, never split or
      relabelled. Mixed text/reasoning is unchanged.
    - A session created by a first send re-reads its access read-only after
      that send and at each turn's end until releasable (busy or failed reads
      do not stand); latest writable answer for the same view only, no
      polling, never reacquires a handed-back session.
    - Verified on one Mac (OpenCode 1.19.0): Rust 831 passed/24 ignored,
      Flutter 1557 passed/5 skipped, real-server and bridge lifecycle tests.
      The final macOS build (`127debfc…`): a new conversation's first reply
      arrived, Hand back appeared without reopening, Release/Continue here
      kept the session ID and draft with no duplicate history or automatic
      send. An earlier build of this round: a region-refused model's card,
      Change model without sending (newer draft kept), explicit Retry of the
      original prompt answered, and a full reasoning-only reply in existing
      history inspected without sending (read-only viewer by tests only).
      Build `4011bbdb…`: a source held by another process
      stayed read-only and, once free, opened only on Check now and
      answered; Release showed the sent message once with only Continue
      here, which kept the draft unsent; an official-CLI deletion in another
      process became terminal and left the list, another session answered.
      An earlier build of this round showed per-project model names for one
      model ID, agents and commands across Alpha/Beta switches without
      sending, and a first send and an existing session's agent change
      answered; extra variants, retention and `false` abort by tests only.
      Earlier builds: no-project picker, native catalog reply, custom Chat
      Completions and Anthropic Messages replies, a 110-model gateway list
      with a non-default model answering, Apply reconnect and back to
      existing configuration (draft kept unsent), clean Cmd+Q, relaunch
      restore, close to tray. Not verified: a successful Responses reply
      (provider refused the model; further testing waived), live attachment
      Retry and cancellation identity (tests only), draft
      attachments across Apply in the app (tests only), relay/multi-controller
      use, other platforms. Former ACP-preset evidence is not native evidence.
    See [Native OpenCode](docs/opencode-native.md) and
    [session access](docs/native-agent-history.md#session-access).

30. **Phone layered navigation (2026-10-15).** Below 720 px the sessions list
    lies under the conversation (`widgets/layered_navigation.dart`): a
    touch/stylus horizontal drag anywhere on the page (past touch slop; the
    page's own horizontal scrollables and text gestures win first) moves it
    aside with the finger and rests wherever it is held. Release completes
    the direction the finger last clearly moved in, however short (a 16 px
    reversal flips it; no distance or velocity threshold); the open sidebar
    closes the same way. One light haptic when a gesture settles open
    (2026-10-18: the earlier recognition tick and medium completion felt
    busy); recognition, the menu control and closing drags are silent.
    Opening parks focus on the sidebar scope itself
    (`requestScopeFocus`), never on its search field, so a swipe never
    raises the keyboard. The sidebar stays
    mounted offstage (scroll, folds, search kept; not rebuilt while hidden);
    the page keeps its state and leaves input, focus and semantics while
    moved. Back and Escape close it first; a system pointer cancel returns
    the drag to where it started, with no completion haptic. Mouse drags and
    an open keyboard leave the page alone. Close it through
    `LayeredNavigation.maybeOf` (`isOpen`/`close`), not `Scaffold` drawers.
    Touch-only polish: tonal new-conversation pill, 14 px row/search
    radius, 22 px composer radius with a quieter idle edge. Touch tablets
    (>= 720 px) keep a 480 px chat and give the inline sidebar the rest (up to
    520 px), so the default 280 px pane fits at 834 px; saved widths still
    apply. Desktop layout is unchanged. Widget tests mock haptics and
    cover system pointer cancel. Historical: an iPhone 15 / iOS 17.5
    simulator run of an earlier edge/threshold build on the real relay
    (unsent draft, no send or session write) checked edge drag, threshold
    release, reverse-drag cancel, close, list scroll kept across
    close/reopen, multiline draft retention, Chinese pinyin commit, Return
    as newline, input after a cancelled drag, keyboard-up edge ignored,
    light/dark. The user accepted the current content drag, hold and release
    behaviour on the installed iOS app. No instrumented haptic feel,
    physical-phone haptics or tablet check is claimed.
    Responsive pass: phone layouts reflow by measured room instead of
    squeezing. Service capability rows below 440 px (text-scaled) put status
    and actions under the title and provider; the action keeps its overflow
    beside it. An agent's options, or a phone's Codex model chip, take a line
    above the attach/send row when their labels do not fit beside it (the
    model alone on a second line when sharing would halve a label), but only
    while at least 420/520 px stay above the keyboard; otherwise they rejoin
    the toolbar and scroll. Option segments keep their state across moves.
    A Codex permission label that fits on neither line moves up beside the
    model. Pending requests share the transcript's slot (each group at most
    45 % of the screen, scrolling), so approve and send stay reachable; on
    touch the chat pane and sidebar keep a minimum height and scroll in
    landscape or with the keyboard. Touch sidebar heading buttons are 44 px;
    host switcher names take two lines. Settings lists subscriptions by service key, never the internal composite
    identity. `test/responsive_layout_test.dart` covers 320 px at 2.0 text
    (en/zh), 393 px at default text, keyboard, landscape and tablet sanity
    with real fonts.

31. **Remote device management, default project, status (2026-10-16).** A
    desktop host that allows it publishes one management-only `host` key
    (`pcx:<device>:host:<name>`): never a chat entry, and its device stays
    listed after the last service stops. The switch is local-only. Another
    device adds, edits, applies and stops services there: installed Codex,
    native OpenCode, the Claude preset or a saved configuration only (no
    remote path/argv; discovery never installs or signs in). Save names the
    revision, Apply the revision and incarnation, Stop the incarnation; a
    conflict keeps edits for an explicit reload, a lost answer refreshes and
    never resends, and secrets are write-only (keep/remove/replace). Restore
    overrides are authoritative on cold start. Each host has a default
    project folder: an automatic one is display-only (sent as no cwd, created
    by the host on first use), an explicit one seeds new conversations, and
    the view adopts the folder the host reports. The status page is concise,
    with diagnostics expandable and copyable. The chat host switcher has
    Refresh services; Add service rows show name and status, with paths under
    Details. Covered by widget tests with the fake bridge; the parent agent
    verified phone add, edit and apply against the real desktop host, and the
    user accepted the current functionality on the installed desktop and iOS
    apps. No physical-phone haptics or other platforms are claimed. See
    `docs/remote-device-management.md`.

CLI `serve --allow-remote-management` reuses the same native Rust hosting and
management engine through `pocox_bridge::headless`, with Flutter bindings
disabled for CLI builds. Keep ordinary `serve` unchanged. Managed CLI hosts own
their lifecycle, profiles and process lock under `state/managed-host`, separate
from desktop restore records; honor saved remote stops across supervisor restarts.
The management entry remains online with no running services. Keep `--device`
consistent across every managed engine and entry; never change the process
environment to select it. See `docs/remote-device-management.md#cli-host`.

Host platform metadata is published through the existing meta, management and
Responses API listeners (`GET /host/device`); the management device view embeds
the same metadata. Keep OS/architecture/WSL detection in `pocox-core`.
Never infer locality from hostname, OS, device label or shared filesystem.
The services UI keeps an independent local target before hosting starts and
assigns only this process's exact owned service keys to it; remote metadata
reads are lazy, context-scoped and never replace missing metadata with the
controller's platform. Explicit device names stay stable; existing key formats
remain supported. Stable `hostId` and persisted default relay
keys distinguish OS environments and independent installation directories;
`instanceId` identifies only the publisher process. Keep identity persistence
and naming in core, shared by desktop and CLI publishers; explicit `--device`
remains an override. An unreadable identity blocks only publishing under the
default name, never app startup. Show `hostname (source)` from the generated
segment everywhere a device is named (`deviceLabel`), adding a short stable ID
only where two installations would read the same; never merge by hostname. A
managed supervisor survives a service that cannot be restored and a status
report it cannot save. Document the one-time hostname-default migration and
shared/cloned-state limits in `docs/remote-device-management.md`.

32. **Visual refresh (2026-10-16).** Calm graphite neutrals with ink-black
    primary actions and the logo's blue as the one, sparse signal colour: no
    purple, no hue cast in greys or shadows, a backdrop lit only by white (a
    multi-hue backdrop and iris accents proved tiring, 2026-10-17), and the
    blue-and-white app icon unchanged; Lucide icons through `AppIcons`;
    Google Sans Flex + Geist Mono (Windows keeps Segoe UI; desktop CJK keeps
    Noto Sans SC). Desktop pages are layered: navigation lies on a lit neutral
    backdrop (`AppBackdrop`), content on an inset rounded sheet
    (`ContentSheet`), and floating controls (composer, navigation cluster,
    toasts, minimap, turn progress) are translucent `Glass` (`GlassDepth`
    chrome / floating / overlay: lit rim, blur, outer-only shadows); the
    transcript scrolls beneath the composer. The macOS title strip is 60 pt
    (native `titleStripHeight`, `WindowChrome.barHeight`), traffic lights
    centred on the sheet bars. Modals use `showAppDialog` (blurred, dimmed
    backdrop; `fullscreen: true` for full-window editors, which keep their
    own safe areas); pickers and information opened from a control are
    desktop popovers anchored to it (`widgets/popover.dart`,
    `showAdaptivePanel(anchored:)`, `showChoicePanel`, `showInfoPanel`) and
    bottom sheets on touch. Fields are filled and borderless until focused;
    segmented choices use `GlassSegmented`; motion uses `Motion.spring` /
    `Motion.emphasized`, and desktop routes fade. One mark per row: a hosted
    chat service is its host's row, project headings carry no folder glyph,
    composer context is text separated by dots. User and agent messages
    render as Markdown, user messages keeping their typed line breaks; the
    expanded editor previews the draft live (beside the source from 900 px,
    a tab away below) and never sends.

33. **Quiet forms and several OpenCode hosts (2026-10-16).** Forms show
    names and values at rest: labels sit inside filled fields
    (`FieldBorder`), what a field is for appears under it only while it has
    focus (`FocusHelp`), and a section's or control's explanation sits behind
    an info mark (`InfoTip`, `InfoTitle`, `GroupCard.info`) or a tooltip.
    Visible lines under a control are state only (detected, taken, pending,
    failed) in `helpTextStyle`; field errors wrap. OpenCode hosts are no
    longer one per device: each picks OpenCode's shared default database
    (one host at a time; every older record) or a history of its own
    (`separateHistory`, `OPENCODE_DB=pocox-<canonical name>.db` in
    OpenCode's data directory), and a new host beside a shared one defaults
    to its own. Only a shared-history host continues Local sessions or writes
    the older `autoHostOpenCode` record; restore brings back every own-history
    host and at most one shared one; a remote add chooses on the host and a
    remote edit keeps the choice. Instance names are unique per device by
    canonical identity: every new-host editor (local and remote) says so under
    the field and refuses Start without a bridge call, and a bridge refusal
    maps to the same words; a relay-level conflict keeps its own message.
    The real-server bridge test runs a second own-history host beside the
    first and still refuses a second shared one; in the macOS app a second
    own-history host ran beside the shared one, connected with an empty
    session list and stopped alone (no message sent). Remote add and edit are
    covered by tests only. See [Native OpenCode](docs/opencode-native.md#hosting).
    The Codex setup page lists ChatGPT sign-in and custom provider as two
    rows, each with its control at the end of the row (`ActionRow`) and an
    "in use" mark on the method Codex runs on; there is no disclosure, and a
    phone says where sign-in and hosting happen instead of offering them. The
    state names the credential in words and reports an unreadable
    `config.toml`. Chinese strings use full-width punctuation.

34. **Anchored transcript and the review sidebar (2026-10-17).** The
    transcript is one `CustomScrollView` around a centre row
    (`widgets/centered_scroll.dart`, `screens/app_session/transcript_list.dart`):
    rows above it lay out upward, so a page or a gap filled above never moves
    what is on screen, and the end or a jumped-to turn is exact in the frame it
    becomes the centre, measured or not. Layout holds the end
    (`stickToEnd`) until the reader scrolls, touches or selects. Never return
    to one index-keyed list (every page shifted its measured extents) or to
    post-frame anchor jumps. A jump reads the turn or page just above its
    landing ahead of the reader; a fully read turn is never fetched again.
    The in-flight history future is the only loading mark (`_historyLoad`,
    `_loadingOlder` derives from it and only its own completion clears it), so
    a rebuild that throws or an immediate failure cannot strand "loading".
    Sync and navigation status float over the transcript top
    (`FloatingStatus`); loading fades in; the turn clock and sidebar motion
    no longer rebuild the transcript. Narrow and touch layouts fold turn
    navigation into a faint `TurnNavigationHandle` (opens on touch, folds after
    5 s or a scroll); wide desktops keep the rail. While above the latest message,
    the jump-to-latest button shows a blue moving ring when the conversation
    runs here or through a followed writer (2026-10-21). Its arrow and hit target
    stay still, its action still returns to and follows the end, and reduced
    motion keeps a steady ring; hidden and idle controls do not animate. The review
    (`lib/src/review/`) replaces the diff sheet: a resizable right sidebar
    from 1100 px, an overlay panel below that, its own page on phones (back or
    swipe right). It shows this conversation's edits (every edit of a file in
    order, or one step from its change card) or the working tree against its
    upstream, with lazy diffs, gap expansion and a whole-file view with the
    changes marked, read through `/fs/thread-file` (root-confined `/fs/read`
    only for older hosts). A working tree never read says so with a retry,
    never "no changes". Codex Desktop `<heartbeat>` automation prompts render
    as a capsule opening into their instructions; blank replies leave no row.
    A user attachment whose temp file is gone is served from the rollout's
    inline copy (`rollout::inline_user_image`); host images are cached per host
    and thread (64 MiB). Dark-mode favicons sit on a light plate. The
    read-only foot (takeover, read-only, Guardian, host access) is the
    composer's glass card, over the same fade. The Codex new-conversation view
    shows the Codex mark like the other engines; theme switches spread from
    the pressed control. Verified: Flutter suite (1636 passed, 6 skipped), the
    touched Rust crates; on the macOS app and an iOS 27 simulator connected
    through a local pb-mapper relay to the Mac's Codex host (the public relay
    was unreachable): history paging and jumps, the review sidebar and phone
    page (workspace and session sources, whole file, retry, swipe back), the
    navigation handle and a turn jump, theme switching. Not verified: other
    platforms, a physical phone, frame-timing measurements.
    When the relay cannot list services, a desktop still restores its hosts
    and opens its own host over loopback (a toast says other devices cannot
    reach it), and the services page keeps this computer's hosts under a
    relay problem card (`RelayProblem`: cause in words, retry, the raw error
    folded and copyable) with the relay marked unreachable and its tunnels
    not connected. A relay name resolving only to 198.18.0.0/15 is named as
    a proxy's or VPN's unrouted virtual address (`relay_diagnosis.dart`); the
    app never resolves around the system DNS. Lit buttons clip their sheen to
    the capsule (`LitFace`).
    Hosting operations report on their own control: Start, Save, Restart and
    Stop become a spinner with what runs ("Starting…") in their working
    colours (`widgets/busy_label.dart`), a running line crosses the action
    bar, and the outcome is pinned above the actions, never at the end of the
    scrolled form; a finished start or stop closes the editor with one toast
    naming the host (a restore warning rides in it). The start had no jank to
    fix: measured on the macOS app, no frame took over 40 ms and the UI thread
    never paused over 100 ms during a 1–2 s start; it only looked frozen.
    Until the host first lists its conversations the sessions sidebar shows a
    delayed skeleton (`ConversationListSkeleton`) that cross-fades into the
    list (the open conversation's own metadata is no listing; exhausted
    retries end it), and the home cross-fades between splash, hero and chat
    by phase. A test holding an operation pending pumps bounded
    frames: its progress never settles. Verified: Flutter suite (1641 passed,
    6 skipped); on the macOS app a real Codex start and stop (busy button,
    running line, toasts) and the skeleton on a host switch; on the iOS 27
    simulator a cold start and host switches with the rebuilt app.
    On phones every engine's new-conversation view (`agent_welcome.dart`)
    uses the room above the composer: the project identity centred (its mark
    dropped when short), other recent projects and Choose folder in one
    horizontal row just above the composer, and mode chips such as Fast on
    the model's toolbar line instead of a line of their own. Covered by
    `responsive_layout_test.dart` (320 px at 2.0 text, 393 px); checked on the
    iOS 27 simulator with a Codex host (Flutter suite 1642 passed, 6 skipped).

35. **Session takeover for Claude and OpenCode (planned, not started).** An
    explicit, confirmed action to continue a Claude ACP or native OpenCode
    session on this host while another client holds it idle, once the host
    can show that no turn runs there and nothing already written can be
    lost. Until it ships, item 29's rules stand: write only from a fresh
    no-owner admission, no override.

36. **Phone polish and worktree projects (2026-10-18).** A long-pressed
    message darkens by the theme's neutral pressed layer in its own outline
    (`kUserBubbleShape` for user bubbles), with no accent outline; its menu
    uses muted icons. A sidebar row's fold control sits inside the row's
    plate (`SessionTreeRow.builder` receives the title inset), so a selected
    parent is one shape. Codex Desktop managed worktrees
    (`<root>/worktrees/<4 hex>/<repository>[/<subfolder>]`) list under the
    checkout they came from (`ProjectIndex`, matched by repository name,
    subfolder and `gitInfo.originUrl`, now on `ThreadMeta.originUrl`);
    without exactly one such checkout a repository's worktrees share one
    project. A worktree row still opens in its own folder.
    Phone overflows found by a sweep at 393/375/360/320 px and ×1.0–2.0 text
    (en/zh) are fixed: the status bar measures its line (`_statusFit`: the
    model name shortens, then the branch name, then the model chip and clock
    give way; state and change counts always show), the narrow services
    device list scrolls, local session rows stack status and action under a
    narrow title, and picker footers use `OverflowBar`
    (`test/chat_status_bar_test.dart`, `test/phone_pages_overflow_test.dart`).

37. **Standard session state and protocol sync (2026-10-18).** `deps/codex`
    points at `35eabb7013`, a clean merge of upstream main `8d9f6466f` (356
    commits after `b38942ce7`). The host's Codex session routes ask the
    colocated app-server first (`host-svc/src/codex_inventory.rs`, one shared
    read-only `app_server::CodexReader`): `/sessions` lists through
    `thread/list` (every provider, the conversation list's source kinds),
    `/sessions?running_only=true` reads `thread/loaded/list` + `thread/read`,
    and liveness and force-resume consult `Thread.status`. A thread that
    app-server has loaded is its own: joined by a plain `thread/resume`, never
    evicted, even while a turn runs. Only threads it reports `notLoaded` fall
    back to rollout + `lsof` probes (another process, such as Codex Desktop or
    the TUI, writes them); an unfinished turn nobody holds is reported
    interrupted, as the app-server reads it, never as running. When the
    app-server does not answer, the file-only inventory stands in; this
    device's own Local sessions (no app-server) stay file-only. Controllers
    follow the broadcast `thread/status/changed` for running state and re-list
    on `thread/started` / `thread/archived` / `thread/unarchived`;
    `LocalSession` gains `name` and `status` (defaulted, so older hosts parse
    unchanged). Codex compresses rollouts idle for a week to `.jsonl.zst`
    (most sessions on the development Mac): every rollout reader accepts
    both, a compressed rollout's last turn is `unknown` (never decoded for
    listing), and history review offsets address decoded bytes. File-backed
    `imageGeneration` items (`fileId` instead of `result`) keep their saved
    path or the unavailable state; experimental read-state and item lookup
    methods are not used. Verified: Rust 847 passed / 25 ignored, Flutter
    suite, and the opt-in `codex_inventory_live` test against installed Codex
    0.161.0 (a compressed rollout listed and read, a loaded thread `idle`,
    joined with nothing evicted). Not verified live: an `active` thread
    (needs a model turn) or a controller app build. See
    `docs/app-server-protocol-sync.md`.

38. **POCOX brand (2026-10-18).** The product is called POCOX, spelled out of
    **PO**cket **CO**de**X**: prose, UI strings, app display names (iOS/macOS
    `CFBundleDisplayName`, Android label, window and tray titles, Linux
    desktop entries, the Windows installer name), CLI and backend messages.
    Since 2026-10-21 all first-party identifiers use `pocox`: crates and
    directories (`pocox-*`, bridge `pocox_bridge`), the Dart package, app IDs,
    config/state paths, `POCOX_*` variables, `~/pocox`, `pocox://auth`, provider
    names and release assets. This is an explicitly incompatible fresh-install
    baseline: do not add legacy-name aliases or migrate old data. The CLI is
    `pocox`; the Linux desktop launcher is `pocox-app` so both can coexist.
    Relay key prefixes (`pcx:` / `pcxu:`) remain protocol abbreviations.
    External Codex and pb-mapper fork branches are `pocox`; renaming does not
    advance their pinned commits. The repository is `acking-you/POCOX`.
    The README poster is regenerated at 2x from the app's own fixture screens
    by `test/gen_poster_test.dart`.

39. **Operating other devices (planned, not started).** Agents working with the
    user's other devices themselves (their shells, their files), so one
    conversation reaches everything in the pocket. Until it ships, describe it
    only as planned. It can reuse item 40's MCP server.

40. **Agent tools and the galaxy (2026-10-18).** One `pocox` MCP server,
    `services` (read) and `connect` (share, stop sharing, connect, disconnect),
    served by the process that owns the machine's relay registrations (the app
    or the CLI host) over stateless Streamable HTTP on 127.0.0.1 (17863 app,
    17864 CLI host, saved), built on `rmcp` (desktop targets only). Shared
    ports are the `port` kind keyed by port number; a share publishes only
    after its first port answers on 127.0.0.1 or ::1. Each device's management
    entry gains `/services/v1` (catalog, event stream, the user's answers and
    shares); the app follows every device's stream. Consent for an agent's
    first share, and for its connections to another device's Responses API
    (which spend that device's model account), per conversation (or token)
    is asked on all the user's devices, the agent's own included, while the
    call waits (110 s hosted, 18 s otherwise); connecting a shared port needs
    none. Harness elicitation and multi round-trip prompts are never used
    for it, because a harness may answer them itself. An answer covers what
    was shown: Allow once admits that exact request only; Allow in this
    conversation and Deny apply to the owner's sharing, or connecting, and
    settle its other requests of that kind. Agents never see consent
    requests or conversation ids, and every share and connection re-checks
    the switch and the caller's
    token right before it publishes or connects. Every call carries a bearer
    token (per hosted Codex or OpenCode instance, committed only once the
    host is recorded; per ACP session for agents advertising
    `mcpCapabilities.http`, carried over on a reopen the agent accepted; per
    copied entry; one for the CLI, sent only after the endpoint's
    `/local/v1/hello` proof); tokens are kept as digests, revocations are
    saved before they apply, and no token reaches a command line (copied
    entries are configuration, never shell commands). Requests with an
    Origin or a foreign Host are refused, by the endpoint and the management
    entry alike. POCOX's own ports cannot be shared. Agents' shares and
    connections end with their harness or token, after 24 h, when the switch
    goes off or the account or relay changes; Keep sharing, the user sharing
    the same port, and the user's own shares last until stopped. Ownership
    is the token and conversation, not the token alone. The switch (on by
    default; off while its file is unreadable) lives in `agent-tools.json`,
    not `config.toml`; off refuses MCP calls but keeps the user's surface.
    Consent holds for agents that reach POCOX only through the tools; a
    same-user program with loopback access can act as the user, and the
    harness's sandbox is that boundary (never claim otherwise). Hosted Codex,
    Claude and native OpenCode get the server at launch and run every tool
    without their own prompt (Codex `tools.<name>.approval_mode = "approve"`,
    Claude `allowedTools`; OpenCode never asks), so POCOX's consent is the one
    gate; others get a copied entry (`pocox tools config`). The composer's
    **+ › Built-in tools** offers the host catalog's `builtin` list (one
    source, `agent_tools/builtin.rs`, where new tools are added); picked tools
    go with the next message as a `<pocox_tools>` block shown as chips, and a
    gated one (Share a port) is granted to that conversation before its turn
    (`/services/v1/grants`), as Allow in this conversation, and ends like
    that answer. CLI:
    `pocox services share|unshare|connect|disconnect|list --json`, `pocox
    open`, `pocox tools …`. App: app-wide consent prompts and share notices
    (phones connect announced shares right away; desktops when opened, and a
    share's connection ends with it), share cards at the agent's tool call,
    Shared with you, the phone's in-app browser (loopback pages only; Flutter
    deep linking is off on iOS and Android, sign-in callbacks keep their own
    handler) with Send to agent (draft only), Share and open for localhost
    links, Settings
    › Agent tools, and the galaxy (`/galaxy`, ⌘2): a turning perspective
    disk of device star systems and orbiting services, light and dark, with
    list mode, keyboard focus and reduced motion. See `docs/agent-tools.md`
    (Trust boundary; Verification lists what was exercised).

40. **One desktop app per hosting state (2026-10-19).** The desktop app claims
    `<state-dir>/hosting/owner.lock` once, at bridge start
    (`engine/host_owner.rs`): an exclusive OS lock held until the process
    exits, never a pid file (the pid inside only names the holder). A copy
    started while another runs stays a controller for its whole run (no
    takeover when the first quits): `host_owner::require()` refuses every
    non-stop lifecycle lease, an explicit stop's restore record, management
    (no supervisor, no setting write) and the agent tools (not served; switch
    and tokens refused). So it never adopts, stops or re-registers the first
    app's services, nor changes what that app restores or serves. Flutter
    skips restore, explains on the home hero, the services page and every
    hosting-editor entry, and disables the agent tools switches
    (`hostingOwnedElsewhere`). Any new hosting service calls `require()`
    before it binds, publishes or writes hosting state. The CLI supervisor
    shares the lock code in its own directory (`managed-host/owner.lock`).
    See `docs/remote-device-management.md`.

### UI and history maintenance (2026-09-13)

- Keep shared colors, typography, and control shapes in `theme.dart` /
  `desktop_theme.dart`; use the shared `UtilityPage` shell for secondary pages.
  Compact layouts need reachable touch targets and readable text, not a scaled
  desktop screenshot. Validate light/dark at phone, tablet, and desktop widths.
- History cursors and idle snapshots belong to the bridge session. Cache at
  most eight thread snapshots / approximately 32 MiB, validate metadata before
  reuse, and invalidate in-memory snapshots on live changes or reconnect.
  Persistent controller windows use the separate configurable disk quota and
  survive reconnect; send manifests only for bytes still retained. Source
  replacement invalidates disk windows and queued checkpoints. Never turn a
  failed request into an authoritative end-of-history result.
- Timeline jumps create independent ascending turn windows. Show missing
  history between those windows at its actual position; a tail cursor does not
  mean there is more history above a fully loaded first turn. Use the exhausted
  turn-summary cursor to confirm the oldest boundary. Hovering the timeline
  must not trigger network reads; explicit selection and approaching a gap
  load one bounded page, with cached pages and in-flight requests reused.
  Coalesce adjacent missing ranges into one action without losing the next
  cursor. A monitoring refresh must not resurrect an exhausted window.
- Continuation across FRB uses `delta_only=true`: send only newly read items,
  merge by item ID, and return an empty exhausted page without another RPC.
  Opening a turn still returns its cached prefix. Monitoring reads use
  `include_turn_pages=false`; do not retransmit selected windows already held
  by Flutter. Preserve the cumulative/default response for older callers.
- Initial history uses a delayed static loading label, without mock conversation
  shimmer or overlapping outgoing/incoming transcripts. Supplementary loads
  keep the existing content visible. Show feedback only at the requested gap,
  top boundary, or selected turn; cancellation and new scroll intent must win
  over late anchor restoration. Background tail updates must remain quiet.
- Limit minimap tick density by available height. Keep the exact active marker
  and all turns reachable through a lazy searchable directory and keyboard.
  Long work lists use a bounded lazy viewport with explicit step ranges; never
  animate the height of hundreds of steps. Appends must preserve the reader's
  selected range, and a manually expanded group must stay open when it finishes.
- Guardian review history is display-only: recognize the explicit request
  envelope and the complete assessment schema, show outcome/risk/authorization/
  rationale, and retain exact original copy plus lazy detail expansion. Never
  turn a historical model assessment into an interactive approval or execute
  command text extracted for presentation. Unknown formats keep normal rendering.
- Keep the composer compact by default, resizable with mouse/touch and
  accessibility actions, and persist its minimum height with the UI preferences.
  Grow and shrink with wrapped text up to the viewport cap, then scroll internally;
  automatic sizing must not overwrite the saved minimum. Keep draft text,
  selection, attachments, and pending queues scoped to the host and conversation
  (host and project before first send) for the app session; a queue resumes when its conversation is active. An upload
  completing after navigation must update its original draft. Failed attachments
  remain removable/retryable and block sending until resolved. Mobile Return
  inserts a newline; desktop Enter sends and Shift+Enter inserts a newline, while
  IME composition must never submit. The expanded editor shares the draft and
  returns focus and selection to the compact input.
- Branding uses the same blue/neutral palette as the UI. The mark has one
  source: the vector drawing and `MarkStyle` palettes in
  `apps/flutter/test/gen_icon_test.dart` (blue tile for launchers, the
  Windows/Linux tray and README art; a one-colour template glyph for the macOS
  menu bar; theme surfaces for splash and the in-app glyph). When changing
  it, run `REGEN_ICONS=1 fvm flutter test test/gen_icon_test.dart`, then
  `fvm dart run flutter_launcher_icons` and
  `fvm dart run flutter_native_splash:create`, for every platform; keep both
  logo copies in sync and the splash colours equal to the `MarkStyle` tiles.
  The README poster is composed by `test/gen_poster_test.dart` from that mark,
  the POCOX wordmark and the app's own galaxy, Local sessions and chat screens
  rendered with fixture data (never a real session); rerun it with
  `REGEN_ICONS=1` when the mark, the galaxy or the
  chat design changes.
- Transcript rows must remain lazy and keyed. Preserve the visible message
  when prepending history (the centre anchor does this by construction, item
  34), and do not rescan the rest of a turn per item when grouping rows. Pagination failures require an explicit retry instead of a
  scroll-triggered request loop.
  Steering messages can split one physical turn into several work groups:
  show its total duration once, and animate only its current active group.
  Missing duration is not evidence of a running turn.
- Render the initial history before optional saved configuration and model
  discovery finish. Late metadata must not overwrite a user's new selection.
  Timeline selection jumps directly to the selected turn; only the latest
  selection may move the viewport, and prepend anchoring must not fight it.
- Connect to an in-app host through its registered loopback endpoint. Do not
  relay a device's own traffic or perform relay health probes to resolve that
  endpoint. Keep remote relay connections as a first-class path.
- Monitor other writers with `follow?metadata_only=true`: emit liveness and an
  opaque rollout revision, then coalesce bounded app-server history refreshes.
  Preserve loaded prefixes and reading position. Keep the legacy full-snapshot
  endpoint compatible, but never use it for a new client's normal monitoring.
  Cache lifecycle scan positions for append-only rollouts so polling does not
  repeatedly scan hundreds of MiB; invalidate on replacement or truncation.
- Discover running sessions in the background via `/sessions?running_only=true`.
  The host reports its app-server's active threads from `Thread.status`, and
  probes ownership in a batch only for threads that app-server has not loaded,
  reading lifecycle data only for held files. Controllers apply the broadcast
  `thread/status/changed` between polls.
  Polls must not overlap; preserve status across transient failures and give
  newer app-server events precedence over an older snapshot. Unopened sessions
  must enter and leave the Active section automatically on desktop and mobile.
- Negotiate Zstd/Gzip for host HTTP responses and permessage-deflate for
  app-server WebSockets. Compression is optional and requires peer support;
  keep uncompressed peers compatible and never buffer SSE just to compress it.
  Verify large payload round trips and actual peer negotiation separately.
- Reproduce long-history issues with the opt-in native integration test:
  `fvm flutter test integration_test/local_history_performance_test.dart -d macos
  --dart-define=POCOX_LIVE_UI=true --dart-define=POCOX_HISTORY_THREAD_IDS=<id1>,<id2>`.
  It reads existing sessions on the configured host, records open/navigation
  times and RSS, and switches repeatedly without sending turns or taking over.
- Reference: T3 Code's [virtualized timeline and scroll anchoring](https://github.com/pingdotgg/t3code/blob/cfeaca41ae27bdf2c203158d378c87c7308fea2a/apps/web/src/components/chat/MessagesTimeline.tsx)
  and [pagination state tests](https://github.com/pingdotgg/t3code/blob/cfeaca41ae27bdf2c203158d378c87c7308fea2a/packages/client-runtime/src/state/threads-pagination.test.ts).

41. **Harness connection lifecycle (2026-10-18).** Temporary probes own and
    await their SDK connections; Codex probes close their WebSocket handshake
    (the app-server ends the stream without echoing Close; that completes the
    probe's own close and is not logged as a reset).
    Publishers reclaim idle app/OpenCode streams after 90s and ACP/meta/host
    streams after 180s, with activity in either direction renewing the deadline.
    Keep generic port and Responses API timeouts unchanged. Local descriptor
    exhaustion is not proof of a dead harness or revoked management grant;
    preserve healthy services and report inspection failures accurately.
    See `docs/harness-connection-lifecycle.md`.

42. **OpenCode 2 wire (2026-10-19).** The native client speaks each OpenCode
    major through one `Wire` implementation (`opencode/wire/`), chosen once
    from `--version` and dispatched statically; everything above it reads
    1.x shapes. Untested versions start with a notice. 2.x receives images
    as `files`; custom providers and Local sessions read 2.x databases (from
    `session_v2`). A 2.x host on the shared history with OpenCode's own
    configuration attaches to OpenCode's background server
    (`opencode serve --service`, `opencode/service.rs`). It starts that
    server only through `opencode service start`, never stops or signals
    it, and stop and quit only detach. It writes only while no process other
    than this one is connected to that server (item 29's rule; takeover
    stays item 35). It gets no agent tools. A replaced server is attached
    again, a stopped one is reported, and `service set disabled true` keeps
    an own server. The server's password is read only from its private
    registration file, into `Secret`. A new custom-provider host, which
    cannot use that server, defaults to its own history while the server is
    on (editor and remote add). See `docs/opencode-native.md#versions`.

43. **Grok Build (2026-10-20).** `grok agent --no-leader stdio` is a built-in
    ACP preset (profile `grok`, Grok's mark from lobe-icons, MIT),
    located on the child PATH then `~/.grok/bin`.
    Model services: existing configuration; Grok account (the user's Grok
    home with API-key and endpoint variables removed, never blanked; device
    sign-in, status and sign-out in place through a private, short-lived
    `grok` that opens no session); or a custom provider (Responses,
    Anthropic Messages, Chat Completions) in a Grok home of the host's own,
    whose `config.toml` POCOX rewrites each start with `[model.*]` tables
    naming `POCOX_GROK_PROVIDER_KEY` as `env_key` (the key is never written)
    and only the provider's models allowed. Local sessions reads
    `$GROK_HOME/sessions` with Grok's own listing, rewind and turn rules, and
    renames or deletes through Grok while no Grok terminal client or POCOX
    host holds the session. Terminal clients registered in
    `active_sessions.json` are owners (turn unknown: access reason
    `external_open`); `grok agent stdio` registers nowhere, so an editor's
    ACP Grok must be closed by the user. A POCOX Grok host is its session's
    own writer and re-verifies before each prompt. From Grok 1.0.45
    (`_meta.grokShell` + `agentVersion`) the host uses Grok's own
    extensions (`acp/host/grok.rs`): prompts carry `_meta.promptId`, Grok's
    `_x.ai/queue/changed` and `turn_completed` name running and ended
    turns, and a turn Grok starts by itself (stranded interjection, loop,
    schedule, goal) is opened and followed like a prompt turn. Supplements
    are `_x.ai/interject`, sent only while Grok reports the turn running;
    as in Grok's own client a stop discards an unmerged one and a turn
    ending first runs it as Grok's own turn; it is never retried.
    `_x.ai/queue/interject` (send now) is not steering. Rename, context use,
    questions (`ask_user_question`, the question card) and plan approval
    (`exit_plan_mode`) map to POCOX's controls; any ACP agent's
    `available_commands_update` feeds the `/` list and `/compact`. A
    supplement is held until Grok's next model response (`streamStartMs`
    changes) and recorded there, so the reply it arrived during never
    splits; a message the agent moved past is completed when the next item
    begins. Tool rows follow `_meta["x.ai/tool"].kind`; a result Grok
    reports only as `rawOutput` (MCP calls) is the call's output, so a
    `pocox.connect` share shows its card. Plan mode is
    `session/set_mode` (default/plan offered when Grok lists none); the
    Permission option (ask/auto/always-approve) is host-wide, sent as
    `_x.ai/yolo_mode_changed` and in every session request's `_meta`; Auto
    falls back to asking where Grok's auto gate is off. Images are sent
    though Grok advertises none; `_x.ai/billing` feeds the usage window;
    Fast pairs a model with its `<name> Fast` partner. Hosts keep
    `--no-leader` (the host owns its agent process). A terminal client's
    session that runs through Grok's leader is followed live, read-only
    (`native_history/grok/leader.rs`): connect only to the home's running
    `leader.sock` (never start one) while a verified registration exists;
    stdio, no capabilities, leader protocol 1 only; only `_x.ai/session/info`
    (subscribes) and `_x.ai/sessions/list`, never `initialize`,
    `session/load`, a prompt or any answer (interactions are the user's
    client's; a driver-only request means it left: leave); leave within a
    second of the registration ending. Live updates past the log's highest
    `eventId` extend the last turn (at once if subscribed idle, else once the
    log reaches the first one received); running state from the roster,
    `queue/changed` and `turn_completed` gives `external_running` /
    `external_idle`. Local sessions follows through
    `app_native_session_follow`. See [Grok Build](docs/grok-build.md).

44. **App updates (2026-10-20).** The bridge's `engine::updates` checks GitHub
    Releases quietly (20 s after start, then at most every six hours, also across
    restarts) and installs only what the release's Ed25519-signed manifest
    (`release-manifest.json`, written and signed by the release workflow's last
    `manifest` job, `scripts/release_manifest.py`) names, by size and SHA-256. The
    key's private half lives only in the `UPDATE_SIGNING_KEY` secret and the
    maintainer's backup; never commit it. macOS also requires the staged bundle's
    Developer ID team, notarization, identifier and version before a detached
    helper swaps it in after the app quits through its normal path. Windows
    installs run the installer quietly, AppImages replace themselves, `.deb` and
    Android packages go to the system's installer, portable archives to Downloads,
    iOS to the release page. Flutter only renders the engine's state
    (`lib/src/updates/`) and does the app's part: quit, the Android installer
    channel, opening the page. One toast per new version; no dialogs. Development
    builds stop after verification unless a `POCOX_UPDATE_*` test override is
    set. The CLI keeps updating through its install scripts. See
    `docs/app-updates.md`.

45. **Galaxy geometry in Rust (2026-10-20).** The galaxy's per-frame geometry
    (stars, plane, projections, depth order, orbit runs, planet positions and
    sizes, links, label placement) comes from the bridge's `engine::galaxy`
    through one leaf `dart:ffi` call, `pocox_galaxy_frame_v1`, on native
    buffers the app owns (`galaxy_frame.dart`); the painter only draws. The scene
    is re-encoded only when it, a body's motion (`GalaxyView.revision`) or the
    label styles change. `computeFrameInDart` is the step-for-step Dart port used
    where the library is not loaded (`flutter test`); change both together, and
    keep `test/galaxy_frame_parity_test.dart` (opt-in, built library) passing.
    Measured on one Mac in profile mode: UI-thread time per frame down about a
    quarter (typical) to a third (busy scene), raster unchanged by that move
    (item 46 cuts it). See `docs/galaxy-geometry.md`.

46. **Galaxy glows and spheres from cached images (2026-10-20).** The galaxy
    draws its blurred glows, halos, contact shadows, lit bodies, rims,
    specular points, spikes, particles and the plane's glow as sprites from
    one atlas (`galaxy_sprites.dart`, `drawRawAtlas`), in the vector painter's
    order and each layer at its own opacity. `paintSphere` builds a sphere
    through `SphereLayers`; `CanvasSphereLayers` paints the cards' spheres, the
    vector fallback and the atlas cells alike, so a layer changes in one place.
    White coverage images are coloured when drawn; sharp layers are bucketed
    by on-screen size, soft ones scaled up. Keep the atlas bounded (512×2048;
    0.3–0.55 MB measured at 2×) and never rebuilt every frame. Measured on one
    Mac (Skia on Metal, profile, 2×): raster −49 % (busy, dark), −65 % (busy,
    light), −12 to −25 % typical; UI build −32 to −37 % busy, +20–40 µs
    typical; total footprint not higher. Cached edges move by sub-pixel
    resampling; zoomed in, the plane's glow keeps the blur the test renderer
    collapses. iOS/Android (Impeller) not measured. See
    `docs/galaxy-geometry.md`.

47. **Linux AppImage packaging (2026-10-21).** `scripts/package_appimage.sh`
    collects the Flutter bundle's native dependencies with pinned linuxdeploy
    and its GTK resource plugin, then uses a static AppImage runtime. Web auth
    uses the system browser but its native plugin still links WebKit; bundle
    that dependency too. Release packaging and the AppImage regression workflow
    share the script and a clean, offline Ubuntu 22.04 startup check. Keep the
    existing artifact name for installed updaters. A packaging-only refresh
    reuses the signed release's portable bundle, replaces only its AppImage and
    re-signs the manifest while preserving all other assets and source identity.
    See `docs/linux-appimage.md`.

48. **Application proxy and mobile Codex setup (2026-10-21).** The app's
    `[network].proxy` is independent of hosted runtime proxies and relay TCP.
    `engine::network` builds outbound HTTP clients for updates, the account
    backend and bounded avatar/favicon reads. HTTP(S) and authenticated SOCKS5
    are supported; SOCKS5 resolves names remotely. Explicit settings bypass
    loopback, override environment proxies and never fall back to direct on
    failure; clearing restores the default environment behavior. Each operation
    reads current settings; in-flight transfers keep their client. The editor
    masks credentials and summaries/debug output omit them. Update signatures,
    size and hash checks remain mandatory. Mobile Codex setup never reads local
    Codex state or offers its local prompt mutation. See `docs/app-updates.md`.

## 10. Communication conventions

- Reply in whatever language the person you are talking to is using.
  This file does not mandate one.
- Lead with findings before summaries.
- Cite files as `path:line`.
- State assumptions explicitly. If an assumption could change the
  design or risk breakage/data loss, **stop and ask**.

- Further reference: T3 Code's [bounded work list and long-message folding](https://github.com/pingdotgg/t3code/blob/af2baccd100604f9885d6af97a5fa99622dd1c4f/apps/web/src/components/chat/MessagesTimeline.tsx)
  preserves scroll anchors and virtualizes expanded activity. Our adaptive tick
  sampling and step-range controls are POCOX adaptations, not claimed
  upstream behavior. Guardian format is defined by
  `deps/codex/codex-rs/core/src/guardian/prompt.rs`.
