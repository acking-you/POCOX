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

### Process-owned local routing

`engine::local_services` is the authority for the current process's Codex,
Responses API, ACP, OpenCode and companion meta listeners. Hosting registers
exact service keys, loopback addresses and a lifetime token under its resolved
account/relay context, after `host_owner::require()`. Device labels, OS,
hostnames and shared files never establish local ownership. Another POCOX
process, including a CLI host, has no entry in this registry and follows the
existing remote path.

`service_connection::Target` selects that record before relay credential
resolution, discovery, subscription or probes. Every controller uses the
existing WebSocket/HTTP/SSE clients against the actual listener, with no
forwarding socket. An API subscription is for clients outside the app, so it
keeps the chosen loopback port: for this process's own API each connection is
forwarded to the listener the host owns at that moment
(`runtime::local_forward`), which survives host restarts and their new
ephemeral ports, and a stopped host refuses instead of falling back. Remote
publication remains independent and follows the existing publication policy.
Local routing does not bypass protocol readiness, session admission, allowed
roots, write ownership or the OpenCode gateway's private native credentials.

The home screen restores configured hosting before remote discovery and can
open a selected local service as soon as its listener is registered, while
publication and the remaining configured host restores finish independently.
OpenCode registers its local routes only after native readiness, its initial
catalog request and gateway startup. Each completed host restore refreshes the
picker's local inventory without relay discovery, including an already open
picker. A failed local handshake tries the next candidate; remote discovery is
deferred until no local candidate can connect. Local hosts the user hid do not
make a start local-only, and once the relay was asked the local inventory is
read again, since an account or relay reset leaves it unknown until the next
resolution. Once a local start has landed, the relay is asked once behind
the open conversation so the picker lists the other devices; rendering a
local conversation never waits for it. Local startup and switching use the
connection's real handshake once; probes still perform real protocol
requests when requested.
The services page keeps local hosts visible while remote discovery is pending
or failing. This removes the controller's relay dependency; the existing
account credential requirements for starting/publishing a host still apply.

Stopping a host invalidates its token before listener teardown and closes its
controller sessions/streams. A known stopped key stays retired for this process,
so a failed local request never silently falls back to the relay. An in-place
Codex restart (watchdog or harness update) restarts only the app-server child,
so only its route is suspended, before the child is signalled. A suspended
route reads as restarting, not stopped: it keeps its key (nothing else can host
it), stays in local discovery, refuses new connections with a retryable error,
and its subscription rows are alive but not ready, so views show the restart
under way. Its host's companion services keep admitting requests (a meta read
or write while the child restarts resolves the meta route directly), while a
stopped app-server still never reaches a surviving meta service. A new
generation is issued only after readiness checks, and a child that does not
exit is admitted again. Clients from before the restart stay retired and
reconnect to the new generation. A restart whose respawn fails leaves the route
restarting; starting the host again then retires the entry and starts fresh
rather than reporting whatever holds the port as running. The API proxy and
meta service keep running and keep their routes. Reusing the port cannot
revive an old client. A forwarded API connection checks its target again once
dialled, so a host stopped meanwhile (or a reused port) is never bridged, and
concurrent subscriptions to one API share its forward. A full app restart rebuilds
the registry from new host starts, never from persisted port numbers. Account
or relay changes invalidate outgoing sessions and subscriptions. Retried meta
reads/writes retain their original endpoint lifetime and stop on retirement;
they do not replay against a replacement host.
Codex, ACP and OpenCode republication stays bound to the host's startup
account/relay context. Changing that context requires restarting the host;
neither manual republication nor automatic recovery publishes its old listeners
under a new context. Starting a Codex or ACP host that runs under another
context is that restart (stop, then start under the current one) rather than a
reuse reporting success; while the current context cannot be resolved
(offline), a live host is kept. OpenCode refuses a second start of a running
host.

Local subscriptions report `Local` / **Local direct** / **本机直连** and the
actual endpoint (or the chosen port of a forwarded API), with no fabricated SDK
counters, relay phases or P2P stages. The connection sheet shows two steps,
this device's listener and the session; the session step still depends on a
successful protocol handshake. Healthy local link watches refresh every three
seconds; remote recovery keeps its existing fast sampling and backoff.

### Remote connection ownership

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

Local-routing fixtures exchange real loopback WebSocket/HTTP/SSE traffic for
Codex, ACP, OpenCode and meta while a relay trap must receive no connection.
They check session reuse, protocol permission failures, stop/restart invalidation,
same-port meta retry rejection, a forwarded API port that follows a restarted
host and refuses while it is stopped, a changed context restarting a Codex host
instead of reusing it, and fresh processes reopening the same isolated hosting
state. UI tests cover pending relay discovery/publication, local session
resume, hidden local hosts, device identity separation and truthful local
connection steps.

Live regression on the public relay: ten completed OpenCode info requests were
left connected with their subscriber handle still held. The publisher closed all
ten at 90.0 seconds and the app's numeric descriptors fell from 97 to 67, without
changing the 256 soft limit. The validation build uses the current development
branch's installation-specific device identity, so this controlled load—not an
assumption that the old phone kept selecting the new identity—establishes recovery.
