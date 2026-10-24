# Relay worker recovery and maintenance

## Direct connections

POCOX follows pb-mapper's dedicated `pocox` branch, currently locked to
`e371902f8365a3c05c4d4c001b6ae1212bfc67d3` (SDK 0.7.0 plus live direct stages
and recovery history), with its `p2p` feature.
The SDK requires Rust 1.99.1 or later; local builds and CI/release formatting use
the root's `nightly-2026-08-21` pin, while CI compiles with current stable Rust.
The relay server is a test-only dependency, never
embedded into the shipping app or CLI.

**Settings › Connection path** has two independent preferences, saved as soon
as they are chosen:

- **Connect to other devices**: **Relay only** (the default) or
  **P2P first** for outgoing subscriptions.
- **Accept direct connections** (off by default, desktop only) for
  incoming connections to newly published services.

The same preferences live in each installation's `config.toml` and apply to
both account and self-host modes, including CLI workers:

```toml
[pb_mapper]
path = "auto"              # opt in; "relay_only" is the default
allow_direct = true         # opt in; false is the default
```

Default values are not written, so only an opt-in appears in `config.toml`.
Existing configurations retain their path preferences, including installations
that have never enabled direct connections.

Preferences are captured when a tunnel starts. Saving them does not interrupt
active work. Reconnect a session (or restart the app for cached auxiliary
tunnels) to apply a changed outgoing preference; restart hosting to republish
services with changed incoming permission. Settings says so under the control
that changed, for as long as it differs from what the page opened with. CLI
`pb restart` applies the saved preferences to exactly one selected worker.
Share strings still carry only relay/key; importing one does not enable direct
access.

The relay must also support and enable direct coordination, with a public UDP
STUN listener in addition to its TCP relay listener. For example:

```sh
pb-mapper server --port 7666 --enable-direct \
  --direct-listen 0.0.0.0:10811 --direct-advertise PUBLIC_IP:10811
```

POCOX delegates negotiation, authenticated peer selection and fallback to the
SDK. Older relays/hosts, blocked UDP and unsuitable NATs use the relay. Fallback
happens only before direct commit; application requests are never replayed after
commit. Existing service idle deadlines, namespace isolation, credential
redaction and the app's own-host loopback shortcut remain in effect.

Established direct connections belong to their endpoints: relay loss and
credential revocation prevent new setups but do not terminate those connections.
Stopping the owning subscription or host closes its direct data paths. Logout
and account/relay changes retain their existing owner invalidation.

Settings polls local SDK counters while a subscription list or its details are
on screen. Each subscription carries one status chip: **P2P direct**, **Via
relay**, **Direct n · Relay m**, **Idle** (no data connection open), **Relay
only** (opened with that preference) or dropped. A saved Auto preference or a
historical direct success is never presented as a live direct connection.
Relay-only tunnels display their policy without inventing active connection
counts. Pressing a subscription opens its details (a popover on desktop, a
sheet on touch): local address, active direct and relay connections,
cumulative fallbacks and the most recent SDK reason. The bridge reports the
path as a typed enum and the counters as `u32`. CLI diagnostics include the
same SDK `direct` counters.

### Watching a link recover

Every tunnel reports how it is doing as it happens, not just "retrying". The
SDK records, on control-path transitions only (never per packet):

- the phase its relay link entered last (resolving, connecting, handshake,
  ready, backoff) and the time to its next attempt;
- the direct attempt in flight and its stage: **negotiating** (does the other
  side offer direct), **discovering** (STUN for the public address, then the
  session grant), **punching** (QUIC through both NATs) and **committing** (the
  other side opens its service);
- the last 16 events — relay ready, relay failed (and why), network changed,
  P2P established (setup time) and fell back to the relay (the stage it left) —
  with consecutive repeats folded into one entry.

A tunnel is listed while it is still coming up (not yet *ready*), so its very
first relay phases and P2P attempt are visible. Lists poll every 3 s, every
500 ms while any tunnel is coming up, recovering or trying a direct path, and
a connection sheet or tunnel details on screen every 400 ms.

A session keeps reconnecting for as long as it is on screen, waiting 1, 2, 4,
8, 15 and then 30 s between attempts; after four failures the banner also offers
to try at once, and **Retry now** cuts any wait short. A reconnect keeps a live
tunnel — the SDK recovers its relay link and direct paths itself — and only a
failed attempt rebuilds the tunnel too. While it reconnects, the session's status
bar says where it stands (for example *Punching through NAT*, *Fell back to
the relay while punching*, *Retrying in 8s*) beside three dots for relay, P2P
and session. Tapping the bar, or the small path mark beside it (P2P, relay or
recovering), opens the connection sheet: the three steps live, the attempt
number and last error, and the tunnel's recent events. Tunnel details show the
same stage and history for any subscription, and the galaxy draws a link trying
a direct path as a dashed beam and one recovering its relay link as an amber
dashed arc.

Agent-tool connections are kept until they expire or are ended: when one's
tunnel ends, POCOX reopens it at the same local port (backing off from 2 s to a
minute) instead of dropping it, and the galaxy says so. See
[agent tools](agent-tools.md) for lifetimes.
An occupied local port leaves the connection waiting for recovery; it never
silently moves to another address. Ending the connection or changing accounts
revokes pending recovery, and a late completion cannot replace a newer connection.

Validation covers direct TCP, compatibility fallback without publisher/relay
support, temporary-credential isolation, exactly one backend dial, coordinator
loss and endpoint stop. The automated fixtures run on loopback; they do not
establish traversal between two independent Internet NATs.

## Worker recovery

Detached CLI network workers retain their SDK handles while the relay or DNS is
unavailable, including when startup takes longer than the interactive 30-second
readiness deadline. Their local service process is independent. A permanent relay
rejection still fails the worker. Account credential bootstrap retries transient
backend failures; the worker owns and cancels its refresh tasks on exit.

The pinned pb-mapper SDK refreshes relay DNS through the OS resolver, shares bounded
setup capacity across mappings in one process, uses network-change hints and
protocol deadlines, and preserves healthy data connections. It cannot bridge an
unavailable physical link or resume a data socket that has already reset.

Inspect one recorded worker:

```sh
pocox pb diagnostics --role register --key pcx:device:api:default
```

Output includes PID liveness and, for a recent matching worker, its actual SDK
version, recovery state, failure/timing information and setup counts. Snapshot
files contain no credentials or application payload. PID/start-time validation and
a 30-second freshness bound prevent a stale snapshot from impersonating a running
worker. `runtime: null` / `unknown` means this worker cannot report fresh diagnostics;
the installed binary's version is never substituted for the running worker's SDK.
`pocox status` also displays the running SDK version.

After installing an updated CLI, replace exactly one network worker:

```sh
pocox pb restart --role register --key pcx:device:api:default
```

Both selectors are required. The command checks the executable (`pocox`),
worker subcommand, key,
endpoint and relay before sending a signal; it refuses a host supervisor or
another process at a reused PID. It resolves credentials before stopping the
worker and refuses a relay/account change. A restart replaces this mapping's
connections, while its local Codex/API process and other worker records remain
intact. There is no implicit all-workers operation. A worker embedded inside the
host/UI process must be upgraded with that owner; this command cannot restart it.

Protocol/source verification does not upgrade an already-running process. In
particular, a deployment that must preserve a Codex app-server mapping must leave
its worker and host untouched, report their old/unknown runtime SDK honestly,
and upgrade them only during a separately authorized maintenance window.

## Host and controller recovery

The account-mode CLI host retains its meta registration even when the initial
30-second readiness wait expires. The SDK continues retrying transient outages;
permanent relay rejection remains a failure. The Codex watchdog stops only the
process matching its own listener, even when another host last updated the shared
runtime record.

The App owns its credential renewal task by support directory, account and backend.
A changed issued expiry replaces the schedule; logout or self-host transport stops
it. Unchanged expiries outside the renewal margin are normal. Failed renewals retry
after one minute, and shortened deadlines are honored.

Controller reconnect checks cancellation after network awaits and on navigation or
backgrounding. Foreground return checks the connection immediately. History and
transport can be ready while optional metadata is still loading; sending waits for
settings restoration. Optional config and model waits each have a ten-second bound.
The Logs page includes `controller.recovery` stages, attempts, elapsed monotonic
milliseconds and failure details, and its existing Copy action exports them.

CLI diagnostics also include `events`: the last 32 state transitions across worker
restarts, with process identity, UTC epoch milliseconds and elapsed milliseconds
within that process. They are stored beside the worker log as `*.events.json` with
private permissions and retained after worker exit. Repeated heartbeat snapshots
do not add duplicate transitions. Event history does not assert current liveness;
only the fresh, identity-checked `runtime` snapshot does.
