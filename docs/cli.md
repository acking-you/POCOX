# `pocox` CLI

The `pocox` binary hosts this computer's Codex and services, connects to other
devices' services and maintains relay workers. A working `codex` on `PATH` is
needed only on a machine that hosts Codex. For a step-by-step walkthrough in
hosted-account mode, see the [usage guide](usage.md).

## Install

```bash
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/acking-you/POCOX/main/scripts/install.sh | sh
```

```powershell
# Windows (PowerShell)
irm https://raw.githubusercontent.com/acking-you/POCOX/main/scripts/install.ps1 | iex
```

`POCOX_VERSION` pins a tag, `POCOX_BIN_DIR` sets the install directory and
`POCOX_NO_MODIFY_PATH=1` skips the PATH step. From source:
`cargo run -p pocox-cli -- --help`.

## Commands

| Command | Does |
| --- | --- |
| `login [--web]`, `logout`, `account` | hosted-account sign-in with GitHub, sign-out, current account and transport |
| `init [--relay <host:port>] [--key <32B>]` | save a self-host relay and shared key to `~/.config/pocox/config.toml` (0600) |
| `serve [--allow-remote-management]` | start or reuse `codex app-server` and register it as `…:app:<name>`; with the flag, run the managed host other devices can configure ([details](remote-device-management.md#cli-host)) |
| `connect` | subscribe to a remote app-server and print the `codex --remote …` command |
| `api serve`, `api connect` | publish this machine's Codex login as a Responses API proxy, or subscribe to one and print a `model_providers` snippet |
| `services list`, `services default set` | discover services; record the default device for later commands |
| `services share`, `unshare`, `connect`, `disconnect` | share a loopback port with your devices, or connect to a shared service ([agent tools](agent-tools.md)) |
| `open <link-or-key>` | connect a shared service and open it in the browser |
| `tools status`, `enable`, `disable`, `ask`, `requests`, `allow`, `deny`, `config` | the agent tools switch, consent requests and copied MCP entries ([agent tools](agent-tools.md)) |
| `status`, `stop` | list or stop POCOX-managed runtimes |
| `codex start`, `stop`, `status` | manage the local `codex app-server` directly |
| `pb register`, `subscribe`, `status`, `diagnostics`, `restart` | low-level relay workers; `pb restart --role <register\|subscribe> --key <exact-key>` replaces one worker ([recovery](relay-worker-recovery.md)) |
| `remote-hint`, `version` | print the client-side `codex --remote` invocation; build and runtime versions |

Run `pocox <command> --help` for every flag.

New workers honor `[pb_mapper] path = "auto"` and `allow_direct = true` in
`config.toml`; missing fields keep relay-only subscriptions and no incoming
direct access. See [direct connections](relay-worker-recovery.md#direct-connections)
for relay prerequisites, lifetime and restart behavior.

## Hosted account

Sign in once on every device with the same GitHub account; no relay address or
key is needed. Run your own backend with [`deploy/`](../deploy/README.md).

```bash
pocox login                 # GitHub device flow
pocox serve                 # host: publish this machine's Codex
pocox services list         # another device: list your services
pocox connect               # attach to the default app-server
codex --remote ws://127.0.0.1:28080
```

## Self-host

An explicit `--relay` always selects self-host mode, even when signed in.
Relay precedence is `--relay` > saved config > `$PB_MAPPER_SERVER`.

```bash
pocox init    --relay relay.example.com:7666   # save relay + 32-byte key
pocox serve   --relay relay.example.com:7666   # host
pocox connect --relay relay.example.com:7666   # client
codex --remote ws://127.0.0.1:28080
pocox api serve   --relay relay.example.com:7666
pocox api connect --device my-host --relay relay.example.com:7666
```

Self-host keys are `pcx:<device>:<kind>:<name>`; see
[architecture](architecture.md#service-keys).
