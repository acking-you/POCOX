<!--
Thanks for the patch! Fill in the sections below — short bullets are fine.
PR description, commits and code stay in English
(`AGENTS.md` › Workflow and communication).
-->

## Summary

<!--
What changes, and why. Cite files as `path:line` (e.g.
`crates/pocox-cli/src/main.rs:42`). Keep the *why* here; commit
messages can stay short.
-->

## Type of change

<!-- Tick all that apply. -->

- [ ] `feat` — new user-visible behaviour
- [ ] `fix` — bug fix
- [ ] `docs` — documentation / comments only
- [ ] `refactor` — no behaviour change
- [ ] `deps` — submodule or dependency bump
- [ ] `ci` — workflow / tooling
- [ ] other (please describe):

## Userspace impact

<!--
`AGENTS.md` › Product rules: once a CLI flag, on-disk layout or wire-protocol field
is documented it is part of the contract. If you're changing one of
these, call it out explicitly and write a migration note.
-->

- [ ] Changes a `pocox` CLI flag, subcommand or output format
- [ ] Changes the on-disk layout (`state.toml`, paths under
      `pocox-core::paths`)
- [ ] Changes a wire-protocol field (codex app-server JSON-RPC,
      Responses API proxy, pb-mapper key shape)
- [ ] Changes the FRB API surface in
      `crates/pocox-bridge/src/api/`
- [ ] None of the above

If any of the above are ticked, describe the migration / compatibility
plan here:

## Tested

<!--
The commands below are `AGENTS.md` › Verification. Tick the ones you ran
locally; if anything was skipped, say why.
-->

- [ ] `cargo fmt --check -p …` (the full package list in `AGENTS.md` › Verification)
- [ ] `cargo clippy --workspace --all-targets -- -D warnings`
- [ ] `cargo test --workspace --locked`
- [ ] `dart format --output=none --set-exit-if-changed lib test integration_test` (run from `apps/flutter`)
- [ ] `fvm flutter analyze` (run from `apps/flutter`)
- [ ] `fvm flutter test` (run from `apps/flutter`)
- [ ] `flutter_rust_bridge_codegen generate` (only if `crates/pocox-bridge/src/api/` changed)
- [ ] Manual flow exercised (describe):

## Screenshots

<!--
Required when this changes what users see: screenshots or a video of the
running app (`AGENTS.md` › Workflow and communication). Otherwise delete this
section.
-->

## Linked issues

<!--
Use `Closes #123` / `Refs #123`. If this ships a roadmap item (see
`AGENTS.md` › Roadmap), call it out here.
-->

## Sync checklist

- [ ] Changed behaviour is reflected in its doc under `docs/`, and
      user-visible changes in `CHANGELOG.md`.
- [ ] A shipped roadmap item is removed from `AGENTS.md` › Roadmap.
- [ ] Public items added in this PR have doc comments
      (`missing_docs = "deny"`).
- [ ] No new `unwrap()` in non-test code; an unavoidable panic is an
      `expect("…")` that says why it cannot fail.
- [ ] No formatting / lint / rewrite commands were run against `deps/`.
