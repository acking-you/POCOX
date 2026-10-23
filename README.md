<p align="center">
  <img src="assets/logo/poster.png" alt="POCOX poster" width="100%" />
</p>

<h1 align="center">POCOX</h1>

<p align="center">
  <strong>PO</strong>cket&nbsp;<strong>CO</strong>de<strong>X</strong> · <em>Every device, in your pocket.</em>
</p>

<p align="center">
  <a href="CHANGELOG.md"><img alt="status: work in progress" src="https://img.shields.io/badge/status-WIP-626C7E"></a>
  <a href="https://github.com/acking-you/POCOX/releases"><img alt="latest release" src="https://img.shields.io/github/v/release/acking-you/POCOX?color=355ACF&label=release"></a>
  <a href="https://www.rust-lang.org"><img alt="rust" src="https://img.shields.io/badge/built%20with-Rust-355ACF.svg"></a>
  <a href="https://flutter.dev"><img alt="flutter" src="https://img.shields.io/badge/UI-Flutter-355ACF.svg"></a>
  <a href="LICENSE"><img alt="license" src="https://img.shields.io/badge/license-Apache--2.0-355ACF.svg"></a>
</p>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">中文</a>
</p>

> [!WARNING]
> POCOX is under active development: APIs, on-disk layout and protocols can
> change without notice. Bug reports and design feedback are welcome.

POCOX puts every device you own in your pocket. Keep using your agents the way
their makers ship them; POCOX follows their sessions on each computer and lets
your phone, tablet or another machine pick them up.

## Works with

<table>
  <tr>
    <td align="center" width="25%"><a href="docs/app-server-protocol-sync.md"><img src="assets/readme/codex.svg" width="36" alt=""><br><b>Codex</b></a><br><sub>native app-server</sub></td>
    <td align="center" width="25%"><a href="docs/acp-agents.md"><img src="assets/readme/claude.svg" width="36" alt=""><br><b>Claude Code</b></a><br><sub>ACP adapter</sub></td>
    <td align="center" width="25%"><a href="docs/opencode-native.md"><img src="assets/readme/opencode.svg" width="36" alt=""><br><b>OpenCode</b></a><br><sub>native server</sub></td>
    <td align="center" width="25%"><a href="docs/grok-build.md"><img src="assets/readme/grok.svg" width="36" alt=""><br><b>Grok Build</b></a><br><sub>ACP with Grok extensions</sub></td>
  </tr>
</table>

Any other ACP agent can be hosted from a program and its arguments
([ACP agents](docs/acp-agents.md)).

## What it does

- **Image attachments** — send images inline and keep a project-scoped host
  copy for the agent's image tools ([attachments](docs/composer-turns.md#attachments)).

- **Every session on the machine** — list and follow live the sessions Codex,
  Claude Code, Grok Build and OpenCode run, including ones started in their own
  apps and CLIs ([native history](docs/native-agent-history.md), with its
  platform limits).
- **Any service, on every device** — reach each computer's agents from your
  other devices and share a dev server or an API; agents can share ports and
  connect ports or APIs themselves through the `pocox` tools
  ([agent tools](docs/agent-tools.md)).
- **Agents on any desktop** — macOS, Windows and Linux host several agents side
  by side, each with its own model service
  ([hosting](docs/hosting-configuration.md)).
- **Reach from anywhere** — iOS, Android, desktop apps and a CLI steer turns,
  answer approvals, browse history and review changes ([app](docs/app-ui.md)).
- **Share a subscription** — publish a computer's Codex login as an
  OpenAI-compatible Responses API for devices without Codex ([CLI](docs/cli.md)).
- **Manage your other computers** — add, configure and stop another desktop's
  services from your phone ([remote management](docs/remote-device-management.md)).

Planned: agents that work with your other devices' shells and files directly.

## How it works

Each computer runs the POCOX app or CLI beside its agents, and devices reach
each other's services through a [pb-mapper](https://github.com/acking-you/pb-mapper)
relay, with a shared key (self-host) or a GitHub sign-in (hosted account).
See [architecture](docs/architecture.md).

## Get started

Download the apps from [Releases](https://github.com/acking-you/POCOX/releases),
or install the CLI:

```bash
curl -fsSL https://raw.githubusercontent.com/acking-you/POCOX/main/scripts/install.sh | sh
```

```bash
pocox login     # on every device, with the same GitHub account
pocox serve     # on the computer that has Codex
pocox connect   # on another device, then run the printed codex --remote command
```

Windows install, self-host and every command: [CLI](docs/cli.md) ·
step by step: [usage guide](docs/usage.md) · your own backend:
[deploy](deploy/README.md). Releases after 0.6.0 start fresh: settings from
earlier releases are not migrated ([changelog](CHANGELOG.md)).

## Documentation

| | |
| --- | --- |
| **Use** | [Usage guide](docs/usage.md) · [CLI](docs/cli.md) · [Deploy](deploy/README.md) · [Architecture](docs/architecture.md) |
| **Agents** | [Codex protocol](docs/app-server-protocol-sync.md) · [ACP agents](docs/acp-agents.md) · [OpenCode](docs/opencode-native.md) · [Grok Build](docs/grok-build.md) · [Hosting](docs/hosting-configuration.md) |
| **Sessions** | [Native history](docs/native-agent-history.md) · [History cache](docs/session-cache-sync.md) · [Guardian](docs/guardian-sessions.md) · [File links](docs/session-file-links.md) · [Images](docs/native-image-generation.md) · [Voice](docs/live-voice.md) |
| **App** | [UI](docs/app-ui.md) · [Composer](docs/composer-turns.md) · [Agent tools](docs/agent-tools.md) · [Galaxy](docs/galaxy-geometry.md) · [Updates](docs/app-updates.md) |
| **Devices** | [Remote management](docs/remote-device-management.md) · [Relay recovery](docs/relay-worker-recovery.md) · [Connection lifecycle](docs/harness-connection-lifecycle.md) |
| **Releases** | [macOS](docs/macos-release.md) · [Linux AppImage](docs/linux-appimage.md) · [Changelog](CHANGELOG.md) |

All pages: [docs index](docs/README.md).

## Contributing

Build, test and PR steps are in [CONTRIBUTING.md](CONTRIBUTING.md); coding and
design rules for people and agents are in [AGENTS.md](AGENTS.md).

## License

[Apache License 2.0](LICENSE). Submodules under `deps/` keep their own licenses.
