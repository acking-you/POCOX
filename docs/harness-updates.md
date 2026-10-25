# Harness updates

Every computer that hosts reports the external harnesses it can run (Codex,
native OpenCode, the `claude` CLI behind the Claude preset, Grok Build): the
installed version, the newest version its vendor publishes, and how it
updates. On request, or by that computer's own setting, it updates a harness
with the vendor's own installer and then restarts the services that run it
on the new version. Code: `crates/pocox-bridge/src/engine/harnesses/`; UI:
`apps/flutter/lib/src/harnesses/`.

## Per device

Each computer answers for itself and keeps its own settings in its hosting
state (`<state>/hosting/harnesses.json`; the CLI managed host's under
`managed-host/hosting`): an automatic update switch per harness (off by
default) and **Restart services after updating** (on by default). Settings
keep harness names a newer version added. Only the app that owns the hosting
state ([one desktop app per hosting state](remote-device-management.md#one-desktop-app-per-hosting-state))
checks on a schedule, updates or writes settings.

- **This computer**: Services › this computer › **Agents on this computer**,
  under local hosting. A second app on the same hosting state shows nothing.
- **Another computer**: the same card under its management panel, through
  its `host:` entry (management must be allowed on that computer). An older
  POCOX without these routes shows no card.
- Phones host nothing and have no card of their own.

Management routes (loopback-only, admission-checked like the rest of
`/manage/v1`): `GET /manage/v1/harnesses`, `POST …/harnesses/check`,
`POST …/harnesses/{kind}/update`, `PUT …/harnesses/settings`. Requests name a
harness kind and setting only; the executable, the installer and its
arguments are the host's own. Answers carry versions and codes, never child
output, paths or proxy values; texts are the controller's.

## Detection and versions

Each harness is found exactly as hosting finds it (saved path, then the
child `PATH`, then its preset's locations) and asked for `--version`, bounded
in time and output (`pocox_core::process::bounded`). Only harnesses this
platform can host are listed: Codex everywhere, the others where owned agent
processes can be supervised (not Windows).

| Harness | How it updates | Newest version from |
| --- | --- | --- |
| Codex, npm/bun/pnpm global package | `npm install -g @openai/codex` (`bun install -g`, `pnpm add -g`) | npm `@openai/codex` `latest` |
| Codex, Homebrew cask (macOS) | `brew upgrade --cask codex` | `formulae.brew.sh` cask `codex` |
| Codex, standalone installer | `install.sh` / `install.ps1` with `CODEX_NON_INTERACTIVE=1` | GitHub `openai/codex` latest release (`rust-v` tag) |
| OpenCode 1.x / 2.x | `opencode upgrade` | npm `opencode-ai` / `@opencode/cli` `latest`, within the installed major |
| `claude` CLI (native or npm) | `claude update` (its own channel) | `downloads.claude.ai` channel, or npm `@anthropic-ai/claude-code` dist-tag |
| `claude` CLI, Homebrew cask | `brew upgrade --cask claude-code` | cask `claude-code` |
| Grok Build | `grok update` | `grok update --check --json` |

Codex mirrors upstream's install context and update commands
(`codex-rs/install-context`, `tui/src/update_action.rs`), judged from the
executable POCOX launches: the package behind the npm/bun/pnpm shim, a
`/opt/homebrew` or `/usr/local` path on macOS, or a release under
`$CODEX_HOME/packages/standalone`. Anything else is `unmanaged` and not
updated. The package manager is looked up beside the shim first, then on the
child `PATH`. OpenCode's 1.x and 2.x lines are separate packages; moving from
one to the other is OpenCode's own migration, never offered as an update.
The Claude preset without a native `claude` uses the CLI its adapter bundles
(`bundled`), which follows the adapter POCOX pins. Grok installed with WinGet
is updated by WinGet (`winget`).

A check runs a minute after the host starts and then every six hours; reading
a computer whose last check is older starts one, and **Check for updates**
runs one at once (a check already running is joined). Versions compare as
semver; prereleases sort below their release.

## Network proxy

Newest-version lookups use the app's HTTP client, so the computer's
**Application network proxy** applies ([app updates](app-updates.md#application-network-proxy)).
Installers and Grok's own check get the same proxy as `HTTPS_PROXY`,
`HTTP_PROXY` and `ALL_PROXY` (and lower-case forms; `NO_PROXY` keeps
loopback direct unless inherited) in their environment only, never in argv or
logs; a `socks5://` proxy is passed as `socks5h://`. Without a saved proxy the
child inherits the environment as before. Tools that ignore these variables
(npm does not speak SOCKS; Windows PowerShell's `irm` uses the system proxy)
keep their own behaviour.

## Updating and restarting

One update runs at a time per computer. It looks the harness up again, runs
its installer in a temporary directory with no console window (at most 15
minutes; output beyond 16 MiB stops it), reads the version again, and records
the outcome: `done`, or `failed` with `tool_missing`, `in_use`, `permission`,
`timed_out` or `failed` (from its exit and output). The installer's last
lines stay in that computer's diagnostics with the proxy withheld. An
installer that succeeded but left the same version installed is reported as
such, not as an update (OpenCode 1.x exits 0 even when it fails).

With restarting on, every running service of that harness restarts on the
installed version, keeping everything else as it ran: Codex respawns its
app-server on the same port with the same arguments and environment (the
watchdog's restart), an ACP agent restarts in place from its captured launch,
and an owned OpenCode server starts again from its prepared launch. No
pending saved configuration is applied. Relay registrations stay where the
engine keeps them (Codex, ACP); OpenCode withdraws and publishes its keys
again. Each restart holds the instance's lifecycle lease (waiting up to 30 s)
and names the incarnation it saw, so a service restarted or replaced
meanwhile (`changed`) or held by another operation (`busy`) is left alone.
An adopted Codex app-server (`adopted`) and a host attached to OpenCode's
background server (`shared_server`) are not this app's to restart. Services
restart only when the version changed; with restarting off they are listed as
`disabled` and keep the old version until they restart.

On Windows a running executable cannot be replaced, so Codex app-servers
are stopped in place (lease held, port and relay keys kept) before the
installer runs and started again afterwards, whatever its outcome. Other
running copies of the harness (a terminal session, its desktop app) can still
hold files; the update then fails with `in_use`.

The app polls the computer every second while it checks or updates, then
refreshes that computer's services. A lost answer is reported as unknown and
the state read again; nothing is sent again by itself. Updates ask for
confirmation, naming the services that restart.

## Limits

- A timed-out installer on Windows is stopped, but what it started (npm under
  `cmd.exe`) may finish by itself; on Unix its whole process group is stopped.
- An update's result is kept in memory: after the host restarts, the card
  shows the installed version but not the last update.
- Automatic updates run after a scheduled check, one harness at a time, and
  only while the app that owns hosting runs.
- Not verified here: real installers against the vendors' registries on every
  platform; the logic is covered by unit and widget tests with fixtures.
