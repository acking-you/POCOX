# Harness connection lifecycle

## Failure and ownership

The affected macOS host reached its existing 256-descriptor soft limit with
more than 200 TCP sockets. Most were relay data legs and their loopback legs
to Codex or the OpenCode gateway. New-process probes still reached the local
harnesses, while POCOX could no longer open configuration files, create sockets,
or spawn Claude's runtime inspection process. Restarting the same installed
build reproduced growth from 78 descriptors to the limit.

The user confirmed another device had the services page open. The accumulated
Codex connections contained the initial probe exchange and no subsequent
heartbeat traffic. Current diagnostic subscribers completed and released 20
probe connections on the same relay. This identifies abandoned incoming probe
connections as the resource consumer; it does not establish the exact remote
client version or why that device failed to close them. A suspended mobile
client and an older client that does not finish teardown must both be tolerated.

A generic pb-mapper TCP data tunnel defaults to a one-hour idle deadline.
That is too long for frequently refreshed harness probes: each abandoned
incoming stream retains a relay socket and a local socket, plus an accepted
socket when POCOX itself hosts the gateway. TCP keepalive cannot identify an
abandoned application session while the relay TCP peer is still alive.

## Lifecycle policy

The controller owns a transient SDK `Connection` directly. Scope exit cancels
it on errors, and normal completion calls `stop()` and waits for its listener
and streams. Probe handles never share ownership with live session tunnels.
Codex probes send a WebSocket close frame on success and RPC failure and allow
one additional second for the handshake. Drop remains the cancellation fallback.
The app-server ends the connection on reading that frame without echoing one
(upstream `run_websocket_inbound_loop`), which the WebSocket library reports as
a reset. `AppClient::close` records the close as its own first, so the 15-second
watchdog probes log nothing; a reset of a connection this side did not close is
still reported.

The publisher is also responsible for reclaiming abandoned streams, even when
the controller has not been upgraded. `Client::register_with_idle_timeout` in
pb-mapper scopes an idle deadline to that registration's data-forwarding futures;
it does not mutate the process environment or the wire protocol. Activity in
**either** direction resets it; control registration and half-close draining
retain their existing behavior. No relay-server upgrade is required.

| Service | No-traffic deadline | Relevant live-traffic contract |
| --- | --- | --- |
| Codex app-server | 90 seconds | WebSocket ping every 15 seconds; liveness deadline 20 seconds |
| OpenCode gateway | 90 seconds | Ordinary requests have a 30-second budget; long commands are host-owned; SSE keepalive |
| ACP, meta, device management | 180 seconds | ACP session loading allows 120 seconds (client budget 150); SSE keepalive |
| Responses API, shared ports, unknown keys | SDK default | Generic/long-running traffic has no harness heartbeat contract |

Service matching accepts both self-hosted `pcx:` and account-scoped `pcxu:`
keys. Active turns remain host-owned when an idle controller disconnects. This
policy bounds idle retention; it is not a global admission limit against an
arbitrary number of simultaneously active clients. Descriptor limits are unchanged.

## Failure reporting and recovery

Process inspection retains spawn, permission, missing executable, timeout,
unsuccessful exit and output failures without exposing child stderr or arguments.
Claude reports an unavailable inspection instead of telling the user to install
Node or an adapter when the process has exhausted file/socket handles. OpenCode
retains the inspection cause. Gateway clients distinguish local exhaustion and
timeouts from ordinary transport failure. Stored bridge errors display their
cause without an `AnyhowException(...)` wrapper or Rust backtrace.

A local allocation failure does not prove that Codex is unhealthy, so watchdogs
defer that probe instead of restarting a healthy child. Management keeps its
previously granted listener during descriptor exhaustion; explicit disable,
account changes, corrupt settings and permission denial still withdraw access.

## Verification

The SDK regression opens 12 encrypted probes and intentionally leaves them
open. Publisher reclamation must close them while active traffic, an unrelated
registration with default behavior, and new connections continue to work.
Existing SDK cancellation and half-close tests remain in place. POCOX tests
cover close handshakes after successful and timed-out probes, error-chain
classification, Claude inspection recovery, management authority, service policy,
and stringified UI errors. Live desktop acceptance additionally exercises each
harness and observes descriptor counts under the original soft limit.

Live regression on the public relay: ten completed OpenCode info requests were
left connected with their subscriber handle still held. The publisher closed all
ten at 90.0 seconds and the app's numeric descriptors fell from 97 to 67, without
changing the 256 soft limit. The validation build uses the current development
branch's installation-specific device identity, so this controlled load—not an
assumption that the old phone kept selecting the new identity—establishes recovery.
