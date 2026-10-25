# POCOX docs

Each page owns one subsystem: what it does, its limits and the rules a change
must keep. Start with [architecture](architecture.md); contributor rules are in
[AGENTS.md](../AGENTS.md).

## Use

| Page | Covers |
| --- | --- |
| [Usage guide](usage.md) · [中文](usage.zh-CN.md) | sign in with GitHub, host Codex, drive it from another device |
| [CLI](cli.md) | every `pocox` command, hosted-account and self-host flows |
| [Deploy the backend](../deploy/README.md) | run `pocox-backend` and the relay for hosted accounts |
| [Architecture](architecture.md) | hosts, relay, controllers, service keys, connection modes |

## Agents and hosting

| Page | Covers |
| --- | --- |
| [App-server protocol sync](app-server-protocol-sync.md) | the pinned Codex protocol, session inventory, submodule bumps |
| [ACP agents](acp-agents.md) · [ADR 0003](adr/0003-generic-acp-agents.md) | generic ACP hosting and the Claude preset |
| [Native OpenCode](opencode-native.md) · [ADR 0004](adr/0004-opencode-v2-dialect.md) | `opencode serve` hosting, 1.x/2.x wires, session access |
| [Grok Build](grok-build.md) | the Grok preset, its account, extensions and leader following |
| [Hosting configuration](hosting-configuration.md) | the hosting editor, model services, keys, apply and restore |
| [Remote device management](remote-device-management.md) | managing another computer, the CLI managed host, device identity |
| [Harness updates](harness-updates.md) | each computer's agent versions, updating them and restarting their services |
| [macOS shell PATH](macos-shell-path.md) | how GUI hosts find Codex and Node on macOS |

## Sessions and history

| Page | Covers |
| --- | --- |
| [Provider-native history](native-agent-history.md) | Local sessions for Codex, Claude, Grok and OpenCode, session access |
| [History cache and sync](session-cache-sync.md) | controller disk cache, history windows, monitoring |
| [Guardian sessions](guardian-sessions.md) | automatic approval reviews and session hierarchy |
| [Session file links](session-file-links.md) | previews and downloads of files named in a conversation |
| [Native image generation](native-image-generation.md) | generated images in live and read-only views |
| [Live voice](live-voice.md) | voice calls and composer dictation |

## App

| Page | Covers |
| --- | --- |
| [App UI](app-ui.md) | design system, layouts, transcript, review, fonts, branding |
| [Composer and turns](composer-turns.md) | drafts, sending, queueing, supplements, retries |
| [Agent tools](agent-tools.md) | the `pocox` MCP server, consent, shared ports, the galaxy |
| [Galaxy geometry](galaxy-geometry.md) | Rust frame geometry and sprite drawing |
| [App updates](app-updates.md) | signed release manifests, installers, the app's network proxy |

## Relay and runtime

| Page | Covers |
| --- | --- |
| [Relay worker recovery](relay-worker-recovery.md) | offline startup, worker restarts, credential renewal |
| [Harness connection lifecycle](harness-connection-lifecycle.md) | probe teardown and idle stream reclamation |
| [Rust offload](rust-offload.md) | what runs in Rust instead of Dart, and its bounds |
| [Native text performance](rust-text-performance.md) | syntax highlighting and Galaxy measurements |

## Releases

| Page | Covers |
| --- | --- |
| [macOS distribution](macos-release.md) | signing, notarization, icons |
| [Linux AppImage](linux-appimage.md) | packaging and the offline startup check |
| [Changelog](../CHANGELOG.md) | notable changes per release |

## Historical notes

Point-in-time records; their numbers and line references belong to the
commit they were written against: [Rust offload review](rust-offload-review-2026-10-21.md),
[session switching investigation](session-switching-stability.md) (Chinese),
[CLI verification against an old relay](cli-verification.md) (Chinese),
[early design specs and plans](superpowers/).
