# Architecture

POCOX runs beside the agents already installed on each computer and connects a
user's devices through a [pb-mapper](https://github.com/acking-you/pb-mapper)
relay. It is a medium, not a harness: the vendors' own apps and CLIs stay the
source of truth, and POCOX never bundles a model runtime. This page names the
moving parts; each subsystem's rules live in its own doc (see the
[docs index](README.md)), and crate ownership is in
[AGENTS.md › Repository map](../AGENTS.md#repository-map).

## Pieces

- **Host** — the desktop app, or the CLI's managed host
  (`pocox serve --allow-remote-management`). It runs or attaches to the
  installed agents: Codex through `codex app-server` (JSON-RPC over
  WebSocket), OpenCode through `opencode serve` (HTTP + SSE), and Claude Code,
  Grok Build or any other agent through ACP over stdio. Beside them it serves a
  meta service (session inventory, history, files), a management entry, shared
  loopback ports and, optionally, a Responses API proxy that reuses the host's
  `codex login`.
- **Relay** — pb-mapper. Hosts register each service under a key; other
  devices subscribe to it and get a local TCP endpoint. The app reaches its
  own in-app hosts over loopback, never through the relay; a CLI `connect`
  creates a network subscription even on the same computer. Remote subscriptions
  default to the relay and can opt into authenticated P2P direct connections;
  see [connection paths](relay-worker-recovery.md#direct-connections).
- **Controllers** — the Flutter apps (iOS, Android, macOS, Windows, Linux),
  which reach Rust through `flutter_rust_bridge`, and the CLI (for example
  `pocox connect` followed by `codex --remote`).
- **Agent tools** — a local `pocox` MCP server that lets a harness list the
  user's devices and services, share a port and connect to another device's
  shared port or Responses API, with the user's consent ([agent tools](agent-tools.md)).
- **Account backend (optional)** — `pocox-backend` signs devices in with GitHub
  and vends short-lived relay credentials. It is not on the data path
  ([deploy](../deploy/README.md)).

## Service keys

Every service is published as `pcx:<device>:<kind>:<name>` (self-host) or
`pcxu:<user>:…` (hosted account). Kinds:

| Kind | Service |
| --- | --- |
| `app` | Codex app-server remote control |
| `api` | Responses API proxy on the host's Codex login |
| `acp` | `/acp/v1` gateway in front of a host-owned ACP agent |
| `opencode` | `/opencode/v1` gateway in front of a native OpenCode host |
| `meta` | session inventory, history, files and per-thread settings |
| `host` | device management, online even with no running service |
| `port` | a loopback port shared with the user's other devices |

Keys and their segments are defined in `crates/pocox-core/src/service.rs`.

## Two ways to connect

- **Self-host** — every device shares one relay address and a 32-byte
  `MSG_HEADER_KEY` and registers `pcx:` keys directly. An explicit `--relay`
  always selects this mode.
- **Hosted account** — devices sign in with GitHub; the backend gives each
  account a relay credential confined to its own `pcxu:<user>:…` namespace.
  Devices then talk to the relay directly, the relay's administrator key never
  reaches a client, and accounts cannot see each other.

## Where things run

| Concern | Owner |
| --- | --- |
| Agent processes, logins and history | the agent's own installation on the host |
| Hosting lifecycle, restore records, model-service profiles | the host's state directory (one owning app per state, see [remote device management](remote-device-management.md)) |
| Drafts, queues, cached history | the controller ([composer](composer-turns.md), [history cache](session-cache-sync.md)) |
| Relay credentials | the account backend or the shared key in `config.toml` |
