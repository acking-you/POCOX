# POCOX agent guide

Rules for people and coding agents in this repository (`CLAUDE.md` links
here). Before changing a subsystem, also read its doc in
[docs/README.md](docs/README.md): those rules are as binding as this file.

## What POCOX is

POCOX (**PO**cket **CO**de**X**) puts every device a user owns in their pocket.
It is a medium, not a harness: users keep the vendors' own apps and CLIs, and
POCOX follows and takes over their sessions and exposes each machine's
services to the user's other devices. Hosts (the desktop app or
`pocox serve --allow-remote-management`; plain `serve` hosts Codex only) run
the installed Codex (`codex app-server`), OpenCode (`opencode serve`) and
ACP agents (Claude Code adapter, Grok Build, custom). Devices meet on a
pb-mapper relay, either self-hosted with a shared key (`pcx:<device>:<kind>:<name>`)
or through a GitHub-signed account whose `pocox-backend` credential is scoped
to `pcxu:<user>:…` and stays off the data path. Controllers are the Flutter
apps (via `flutter_rust_bridge`) and the CLI ([architecture](docs/architecture.md)).

## Repository map

```
apps/flutter/    Flutter app, FVM-pinned 3.44.0; lib/src/rust is FRB-generated
crates/          first-party Rust workspace (table below)
deploy/          hosted backend deployment unit and config examples
deps/codex       submodule, acking-you/codex `pocox`: app-server wire reference
deps/grok-build  submodule, acking-you/grok-build `pocox`: Grok source reference
docs/            subsystem docs and ADRs
scripts/         install scripts, CI gate (ci_affected.py), packaging, release
vendor/pagable/  excluded provenance copy; not a dependency, keep unchanged
```

| Crate | Owns |
| --- | --- |
| `pocox-core` | config, `state.toml`, paths, errors, service keys, device identity and platform; dependency-light |
| `pocox-codex` | spawning and supervising external `codex app-server`, local JSON-RPC envelopes, rollouts |
| `pocox-pb` | pb-mapper SDK wrappers: relay sessions, register/subscribe/status, publish, credentials |
| `pocox-api-proxy` | `/v1/responses` HTTP + WebSocket proxy reusing the host's `codex login` |
| `pocox-host-svc` | host meta service, native history readers, ACP host, OpenCode client |
| `pocox-cli` | the `pocox` binary ([commands](docs/cli.md)) |
| `pocox_bridge` | FRB library (`crates/pocox-bridge`): hosting engine, sessions, agent tools, updates |
| `pocox-account-proto` | backend wire types and `pcxu:` namespacing |
| `pocox-auth`, `pocox-store` | GitHub login and session tokens; SQLite persistence for the backend |
| `pocox-backend` | the deployable account backend ([deploy](deploy/README.md)) |

Prefer a new module in an existing crate over a new crate: crates are cheap,
boundaries are not.

## Product rules

Contracts: changing one needs an explicit decision, never a side effect.

- **External agents only.** Never compile, link, bundle or launch a model
  runtime. Agents run as the user's installed executables, resolved from an
  explicit path, saved configuration, then `PATH`; a missing one is an
  installation error, never a fallback. First-party crates use local wire
  envelopes, not `codex-*` crates ([rules](docs/app-server-protocol-sync.md#dependency-rules)).
- **Built-in engine** stays a disabled "Not implemented yet / 暂未实现"
  option. The bridge `embedded` field stays: status reports false, an explicit
  true fails before side effects, legacy auto-host restores external Codex.
- **Responses API proxy**: HTTP POST and WebSocket GET on `/v1/responses` both
  forward requests, auth, streams and errors; verify both after Codex or hosting changes.
- **Don't break userspace.** Documented CLI flags, on-disk layout and wire
  fields: add, don't mutate; version a break with a migration note. The
  `pocox` naming baseline is a deliberate fresh install: no legacy aliases or
  migrations. Prose says POCOX; identifiers say `pocox` (`POCOX_*`,
  `pocox://auth`, Linux launcher `pocox-app`); relay prefixes stay `pcx:`/`pcxu:`.
- **Isolation.** The relay administrator key never reaches a client; an
  account sees only its namespace; model keys and account tokens never reach
  argv, logs or status (the relay key's `init --key` is the argv exception).
- **One owner per hosting state.** Only the process holding
  `hosting/owner.lock` (CLI: `managed-host/owner.lock`) hosts or writes hosting
  state; new hosting services call `host_owner::require()` first.
- **No guessed locality** from hostname, OS, label or shared filesystem; reach
  an in-app host through its loopback endpoint. **No unadmitted writes**: a
  read-only view never resumes, takes over or answers for another writer.

## Engineering principles

- Understand the whole flow and data ownership first; fix the structure, not
  the symptom; delete code and tests the change makes obsolete.
- KISS / YAGNI: a trait needs two real implementations, a knob a real user.
- Mirror upstream behaviour (Codex, pb-mapper, OpenCode, Grok) instead of
  layering heuristics; adopt a proven library when it clearly beats ours.
- Tests cover capabilities and real failure, state and security boundaries,
  not wording or glue. Critique code, not people.

## Rust code

First-party Rust follows the
[Google Rust Style Guide](https://google.github.io/styleguide/rustguide.html)
(on top of the [Rust Style Guide](https://doc.rust-lang.org/style-guide/) and
[API Guidelines](https://rust-lang.github.io/api-guidelines/)). Its Chromium-
and Fuchsia-only rules do not apply (we use Tokio, threads and module trees),
and our crates are application code. Project specifics:

- **Format** with `rustfmt.toml`, which applies the guide's settings
  (`imports_granularity = "Module"`, so one module per `use`;
  `hex_literal_case = "Lower"`; `max_width = 100`). Nightly is pinned for
  rustfmt only: no unstable language features.
- **Errors**: `Option` for plain absence, `Result` for recoverable failures,
  panics only for bugs. No `unwrap()` outside tests; an unavoidable panic is
  `expect("why it cannot fail")`. Match instead of check-then-unwrap; never
  `catch_unwind`.
- **`unsafe`** is forbidden (`#![forbid(unsafe_code)]`) outside FRB-generated
  code and the bridge's existing FFI; new uses need a safe wrapper, a
  `// SAFETY:` comment, review justification and a Cargo feature.
- **Ownership and APIs**: borrow before cloning; `Rc`/`Arc` only when unique
  ownership is unreasonably complex; take `&str`, `&[T]`, `Option<&T>`; enums
  over unclear `bool`s; newtypes and named fields over tuples; std traits and
  `#[derive]` over bespoke methods; `#[must_use]` where ignoring is a bug.
- **Imports and naming**: no glob imports except `use super::*` in tests and
  `pub use` re-exports; traits imported locally; free functions called through
  their module (`mem::take`); std naming (`as_`/`to_`/`into_`, `new`/`try_new`,
  `*Ext`); no obscure abbreviations.
- **Clarity**: annotate `parse()`/`into()`/`collect()` results; plain loops
  over long combinator chains; `format!` over `+`; explanatory `assert!`
  messages; `tracing` instead of `println!` except requested CLI output.
- **Docs and shape**: every public item documented (`missing_docs = "deny"`),
  with panics and invariants; English comments that explain intent. Files stay
  at or below 1,000 lines, split by responsibility into child modules with
  re-exports (never `include!`); non-leaf modules are declarations and
  re-exports; nesting at most three levels.

## Dart and Flutter

- `flutter analyze` (`flutter_lints`) and `dart format` are the baseline;
  follow [Effective Dart](https://dart.dev/effective-dart) beyond them.
- The 1,000-line limit applies; private library parts are fine for
  state-owned session behaviour and stateless bridge mixins, with lifecycle
  and state ownership kept in one place.
- `lib/src/rust` and localizations are generator-owned; after editing
  `crates/pocox-bridge/src/api/` run `flutter_rust_bridge_codegen generate`.
- `pubspec-desktop.yaml` adds the desktop font and must keep `pubspec.yaml`'s
  dependencies ([fonts](docs/app-ui.md#fonts)). UI rules:
  [app UI](docs/app-ui.md), [composer and turns](docs/composer-turns.md).

## Verification

Run all of this before calling a change done. CI scopes the same commands to
affected crates (`scripts/ci_affected.py`) and runs everything when manifests,
the lockfile, `deps/`, `.github/` or `scripts/` change.

```bash
# The -p list covers every workspace member; add new crates here and in ci.yml.
cargo fmt --check \
  -p pocox-core -p pocox-codex -p pocox-pb \
  -p pocox-api-proxy -p pocox-host-svc -p pocox-cli \
  -p pocox_bridge -p pocox-account-proto -p pocox-store \
  -p pocox-auth -p pocox-backend
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --locked

cd apps/flutter   # first time: fvm install 3.44.0 --setup
fvm flutter pub get
dart format --output=none --set-exit-if-changed lib test integration_test
fvm flutter analyze
fvm flutter test
```

Never run `cargo fmt --all` or any formatter or linter inside `deps/` or
`vendor/`. Avoid parallel duplicate Rust builds, watch disk space, and clean
only reproducible build artifacts.

## Dependencies and submodules

- pb-mapper is a Cargo Git dependency on its `pocox` branch, pinned by
  `Cargo.lock`: push SDK fixes there, run `cargo update -p pb-mapper`, commit
  the lockfile. Builds stay `--locked`.
- `git submodule update --init --recursive` materialises `deps/`. Fork
  branches take upstream by merge, never by rebasing published history.
- `deps/codex` bumps follow [protocol sync](docs/app-server-protocol-sync.md)
  (verified pointer, dependency audit); `deps/grok-build` is a reference only
  ([Grok Build](docs/grok-build.md)). Changes under `vendor/` need the full
  Rust CI gate.
- When behaviour changes, update its doc in the same change and note
  user-visible changes in [CHANGELOG.md](CHANGELOG.md).

## Roadmap

Image attachment mirrors use the selected session/project, retain the legacy
upload route and respect draft admission; see
[attachment rules](docs/composer-turns.md#attachments).

Shipped work lives in the changelog and git history. Open, described only as
planned until it ships:

- **Typed JSON-RPC client**: local types for `pocox-codex::protocol`, checked
  against the upstream schema, instead of `serde_json::Value`.
- **Session takeover for Claude and OpenCode**: an explicit, confirmed continue
  while another client holds the session idle, once no running turn or
  written data can be lost. Until then, no override.
- **Operating other devices**: agents using the user's other devices' shells
  and files, likely through the `pocox` MCP server.

## Workflow and communication

Restate the task, confirm the problem and its userspace impact, read the
subsystem doc, plan against concrete files and functions, change, verify, then
hand off what changed (`path:line`), assumptions, risks and what was not
verified. Reply in the user's language and lead with findings. Code, comments,
commits (Conventional Commits) and PR text are English. Stop and ask when an
assumption could break userspace or lose data.
