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
| `login [--web \| --resume] [--backend <url>]`, `logout`, `account` | hosted-account sign-in with GitHub or back to the session set aside for pairing, sign-out, current account and transport |
| `pair`, `pair join`, `pair restore [--ask] [--retake]`, `pair start-over` | sign in without GitHub: show this device's code, join another device's group, recover a previous device, or leave a replaced identity behind ([details](#pairing-codes)) |
| `pair rotate`, `pair pause`, `pair resume`, `pair leave` | replace or pause this device's code; move it out of its group |
| `devices`, `devices remove <id>`, `devices allow <id> --request <id>`, `devices deny <id> --request <id>` | list the linked devices, remove one, answer a recovery request |
| `init [--relay <host:port>] [--key <32B>]` | save a self-host relay and shared key to `config.toml` (0600) in POCOX's config directory (`~/.config/pocox` on Linux, `~/Library/Application Support/io.github.acking-you.pocox` on macOS) |
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

New workers use the relay over TCP unless `config.toml` opts in under
`[pb_mapper]`: `path = "auto"` and `allow_direct = true` for direct (P2P) paths,
`port_mapping` for asking the router to help them, `relay_transport = "quic"`
for the carrier. See [direct connections](relay-worker-recovery.md#direct-connections)
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

## Pairing codes

A device can sign in with no GitHub account. Each device has one long-lived code,
and devices linked by those codes count as one user.

```bash
pocox pair                  # on the first device: show its code, ask to set it up, wait for a link
pocox pair join             # on the next device: type the code, or pipe it to stdin
pocox devices               # list the group
```

A code is read from a prompt or stdin, never the command line, where other accounts
and shell history could read it. Everything that changes membership shows what it
does and asks first; without a terminal, `--yes` is that answer and the command
otherwise changes nothing. `--backend <url>` chooses a backend, which must be
`https://` or on this computer. `--no-wait` makes `pocox pair` return after showing
the code. Only `pocox pair`, `pair join` and `pair restore` start an identity; anything
else on a device with none says so and changes nothing, including `pair pause`.

A change the backend has yet to finish when the command stops waiting, or when you press
Ctrl-C, exits with code **75**: neither done nor failed. Do not repeat it. `pocox devices`
and `pocox pair` show changes still under way and any that turned out not to happen.

| Situation | Do |
| --- | --- |
| Reinstalled, with the device store intact | `pocox pair`: same device, same code |
| Reinstalled without it, holding a code from the group | `pocox pair restore`, then pick the device you were (`--device <id>` off a terminal) |
| Reinstalled without it, holding no code | `pocox pair restore --ask`; a linked device runs `pocox devices`, compares the matching id and allows it |
| Suspect someone has this device's code, on this device | `pocox pair pause`, then `pocox devices remove <id>` for anything you do not recognise |
| Suspect someone has a device's identity, and you have replaced that device | On the replacement, not yet set up, with a code from the group: `pocox pair restore --retake`. Old access ends at once and the code changes |
| Told another device took this identity over | `pocox pair start-over` starts as a new device; `pocox pair restore` then recovers one you had |
| This device was removed | `pocox pair` asks to continue, as a device of its own; returning to the group takes a new code |
| A code leaked | `pocox pair pause` at once; `pocox pair rotate` once 24 hours have passed since it was issued |

The identity lives in a private device store outside `config.toml`, shared by every
POCOX installation of this OS account and backend, so moving one moves them all.
`POCOX_DEVICE_SCOPE=<name>` keeps a separate identity, for testing several devices
on one computer. `config.toml` holds one session, so give each scope its own home too,
or they sign each other out: `HOME=<dir> POCOX_DEVICE_SCOPE=<name> pocox …` on macOS and
Linux. On Windows the configuration directory follows the account, so use a separate
Windows account. `pocox logout` signs this
installation out and leaves the identity and its group alone: `pocox pair` resumes it. To
end a device's access, remove it from another device. Moving to pairing sets a GitHub
session aside, and `pocox login --resume` brings it back, with the backend it was on;
`--backend <url>` names one when several are set aside. It refuses to replace a GitHub
session already here.

A running `pocox serve` or relay worker on your account notices within a minute that its
device was removed or moved, or that this installation moved to or from pairing, and
stops. Removal ends new connections; one already open may last until an end closes it.
`pocox serve --allow-remote-management` stops its hosts the same way and starts them
again after a move you confirmed, including one made by a command in another terminal, or
after you continue on a removed device. A worker that slept past its key's end registers
again with the next one. An explicit `--relay` depends on none of this.

Details are in [the design](pairing-code-login.md).

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
