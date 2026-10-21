# Provider-native session history

Desktop **Local sessions** offers Codex, Claude, Grok and OpenCode. The independent
Claude/Grok/OpenCode bridge is currently enabled on macOS and Linux; Windows
returns an unsupported-platform error, and mobile omits these readers. On
supported platforms the latter two read history independently of any host,
including when their hosted agents are stopped. Visiting a session does not restore it through
`session/load`, send a prompt, authenticate, download a package or stop its
writer. The existing read-only transcript viewer handles messages, public
tool inputs/results and supported inline attachments.

The same readers serve foreign history through a host's meta service.
That path reads the host's configured provider data, never the remote
controller's filesystem. A historical inventory entry alone does not grant
write access: writing goes through a connected host's session access (below).

A native session is continued, never forked or copied, by opening it on a
running host that serves its provider: **Continue in <host>** in the viewer
(a native OpenCode host on OpenCode's shared history for OpenCode, never
one with a history of its own; a Claude ACP host for Claude; a Grok host on
the user's own Grok home, never a custom provider's, for Grok), or
**Host <provider> to continue** when none runs on this desktop. Rows show
whether the reader saw the session free, held idle or running elsewhere, or
cannot tell.

## Sources and bounds

| Provider | Source | Boundaries |
| --- | --- | --- |
| Claude | The official `claude-agent-sdk` installed beside the selected ACP adapter; only `listSessions`, `getSessionInfo` and `getSessionMessages` | No SDK download during browsing. Canonical branch reconstruction belongs to the SDK. A changed selected transcript is read again; this is not an incremental index. Sources over 64 MiB are rejected; the credential-free reader has a 256 MiB heap and bounded time/output. |
| Grok | `$GROK_HOME/sessions` (default `~/.grok`): `summary.json` and the ACP update log `updates.jsonl`, replayed with Grok's own rewind and turn rules ([Grok Build](grok-build.md#local-sessions)) | No agent started for browsing. Summaries over 256 KiB, lines over 8 MiB and logs over 500,000 lines are bounded; a page folds at most 32 MiB. Sessions can be renamed and deleted here, through Grok itself. |
| OpenCode | Existing SQLite database under `OPENCODE_DB`, or `XDG_DATA_HOME/opencode/opencode.db` / the normal HOME data directory | Read-only connections and transactions, no creation, migrations or runtime import. Recognized `session_message` v2 and legacy `message` + `part` schemas only; sessions come from OpenCode 2's `session_v2` when it exists, plus any 1.x `session` rows it did not copy. No disk-wide search for custom/channel databases. |

Claude uses the effective `CLAUDE_CONFIG_DIR` or HOME. The independent
desktop reader resolves this device's environment; a hosted reader uses
that agent's effective launch environment. A relative `OPENCODE_DB` resolves
under OpenCode's data directory. Missing or unsupported sources produce an
error, rather than an authoritative empty history. Mobile does not include
the independent SQLite reader.

Inventory requests contain at most 100 rows; transcript pages default to
20 turns. The view retains a contiguous window of at most 160 turns / about
32 MiB, with older history available explicitly. Bounded text, tool data,
images and page sizes have visible omission notices. Hidden reasoning,
signatures and private provider metadata are excluded. A file path inside
a native transcript does not authorize automatic file/image reads.

OpenCode orders v2 rows by sequence and legacy messages by timestamp plus
ID; legacy parts use their IDs. Reverted suffixes are excluded. For a
part-level revert, the reader conservatively omits the entire partially
reverted message, with a notice. OpenCode's total turn count stays unknown:
raw user-row counts cannot describe every partial or orphaned history.

Opaque source IDs keep provider roots distinct. Source generations change
on replacement or relevant history changes; old cursors cannot be applied
to a new source. The foreground viewer checks revisions every three
seconds, reads only on change, and stops following off-route or in the
background. Older-page loads preserve the reading position. A disjoint tail
or a replaced generation resets the retained window rather than inventing
continuity. Transient read failures keep already displayed messages.

## Session access

Opening a conversation on a connected Claude or Grok ACP host or native OpenCode host
asks that host for the session's access (`app_session_open`). There is no
separate dialog and no Take Over step: the host decides from fresh evidence,
and the view follows its answer.

- **Write.** The host admitted the session for this host (`owned`): the
  composer is live at once. When the host had to load it first, that happens
  in the same open, and only from a fresh check that found no other writer.
- **Follow.** Another writer holds it, or the host cannot tell: the
  transcript follows live and read-only, and a panel names the reason and the
  next step. Unsent drafts, attachments and queued messages stay; a queue is
  held, and when writing becomes possible the user is offered to send it.
- **Blocked.** The session cannot be written here at all (`unsupported`,
  `not_found`): the view stays read-only with the reason. For OpenCode,
  `not_found` also means deleted: from the host's event, or, for a deletion
  by another process that sends no event, from an access check or follow
  read the same host answers with `session_not_found`. The view then stays
  terminal, with no Check now or Continue here.

| Reason | Shown as | Next step |
| --- | --- | --- |
| `external_running` | the named client is running a turn here | follows live; opens by itself when the host reports it free |
| `external_idle` | the named client still has the session open; no turn runs | close it there; an idle native Claude client still holds the session until it really closes or exits |
| `external_open` | a Grok terminal client has the session open; whether a turn runs there is not recorded (`external_running` or `external_idle` while it is followed live through Grok's leader) | close it there; opens by itself when it is no longer registered |
| `external_source_open` | another OpenCode process has this history source open; which session or turn it writes is unknown (turn unknown). The holder is `opencode_service` when it is OpenCode 2's background server beside this host's own server, and `opencode_client` when another client is connected to the background server this host attached to (the turn is then known) | close or release it there (`opencode service stop` for the background server; for a client, its terminal app, desktop app or browser tab), then **Check now** |
| `pocox_host` | another POCOX host writes it | **Open in <host>** only when that host's service key is known |
| `transition` | the session is changing hands | wait; never taken as free; a later free answer opens by itself only where the host keeps an admission (see `not_opened`) |
| `host_stopped` | this host is not running | **Open host** for a local host |
| `released_here` | handed back by this host | **Continue here** is the only way back |
| `not_opened` | the host holds no admission for the session (OpenCode only: never opened there, or forgotten by a host restart or to make room) | **Check now** opens it when that fresh check finds no writer and no running turn; **Continue here**; background checks never open it |
| `source_unknown` | the host cannot inspect other clients | **Check now** |

Rules the UI keeps:

- Recent writes, unfinished text or quiet time never mean "running" or
  "free", and never grant write access. Writing returns only through a fresh
  admission the host reports with no other writer (`writer: none`).
- While following, the view asks again every 3 s for the first minute and
  every 15 s afterwards, only in the foreground on the visible route, and the
  host may push `session/access/changed`; **Check now** asks immediately.
- Background checks (the timer and host events) open a session only when the
  host still keeps an admission for it and reports no other writer. An
  explicit **Check now** additionally opens a `not_opened` session through a
  fresh `appSessionOpen` when its own answer, asked after the press, reports
  no writer and an idle turn. A session handed back here (`released_here`)
  opens only through **Continue here**, whatever a check answers or has in
  flight, and other blocked reasons stay read-only.
- When a written view turns read-only, each host user message the view did
  not show before replaces the earliest optimistic copy of its turn. Host
  messages already shown confirm nothing, so reading the same history again
  changes nothing and a message the host does not show yet stays. Matching is
  by turn and host item ID, never by text, so a repeated message stays.
- **Hand back to other clients** (the conversation menu) releases this
  host's writer and shows `released_here`; nothing reacquires that session
  by itself.
- When the host withdraws admission (another controller handed it back, or
  the session is closing), every connected view follows at once and keeps its
  drafts and queues.
- There is no "continue anyway" override.

The scope of a write is stated once in the status tooltip: POCOX hosts
exclude each other; a native client of the same provider is not blocked by
POCOX and must stay closed while POCOX writes.

**This is not a provider-wide lease.** Installed Claude SDK/headless 2.1.296
accepted two simultaneous same-UUID writers in an isolated test, and
installed OpenCode 1.19.0 accepted two engines writing one session (aborting
one did not stop the other). No broad process kill, native lock deletion or
copied branch is presented as an original-session takeover.

## Code and verification

- `crates/pocox-host-svc/src/native_history/`: concrete provider
  readers, public projection, bounded helper execution and owner probes.
- `crates/pocox-host-svc/src/acp/host/native_history.rs`: foreign
  session inventory/history without ACP admission.
- `apps/flutter/lib/src/screens/app_session/session_access.dart` and
  `session_access_panel.dart`: automatic open, follow, re-check and hand
  back.
- `crates/pocox-bridge/src/engine/native_sessions.rs` and
  `api/bridge/native_sessions.rs`: independent desktop source cache and
  typed list/page/revision APIs.
- `apps/flutter/lib/src/screens/local_sessions/` and
  `local_session_view/`: provider inventory, bounded history windows and
  foreground following. Remote routes retain their separate source type.

The complete Rust suite (794 passed, 20 ignored opt-in fixtures) and Flutter
format/analyze/tests (1432 passed, five existing skips) passed for the safe-transfer
update. The macOS profile build passed and the mobile pubspec was restored
byte-for-byte.
Reader tests cover source/cursor isolation, partial writes, bounded output,
reverts, orphan prefixes, known schemas, no database creation/migration,
owner identity mismatches and conservative lease refusal. UI tests cover
provider changes, older pages, following and the absence of native resume.
The actual existing OpenCode database test exercised legacy messages and
tools; v2 coverage is a schema fixture, not a claim of live v2 acceptance.

On one Mac, the latest app opened the originally failing Claude session
through Local sessions and displayed its prompt, tools and final answer.
With both app-owned ACP hosts stopped, it displayed the actual OpenCode
legacy database's messages and tool results. A separate, disposable Claude
CLI wrote 23 replies; the viewer identified its external owner, followed a
24th reply without navigation, and loaded the older page back to the first
message. Only the fixture's own stdin was closed after testing; the viewer
remained read-only after exit. A new conversation then prepared automatically
and returned the requested marker through the real Claude model route.

The safe-transfer extension has separate evidence: installed Claude ACP 0.89.1
and CLI 2.1.296, three task-owned adapters, isolated config/work directories and
a deterministic loopback Messages endpoint. The application gateway released
its original writer; two hosts competed for the same UUID, exactly one acquired,
its verified native child replied, and the old host could not send. Final
release removed the native owner and freed the POCOX claim. Regular regressions
cover failed close, stale host/source, uncertain load, claim contention and
process identity. This is not a claim of a provider-wide lock or arbitrary
external-client termination.

Automatic session access has its own evidence on one Mac (latest suites:
Rust 815 passed, 24 ignored; Flutter 1503 passed, 5 skipped). An opt-in host test with the
installed Claude adapter and CLI, against a deterministic loopback model
endpoint, released an original Claude session and let exactly
one of two contending hosts acquire it. Against a real `opencode serve`, opt-in
tests admitted the exact original session, detected another process holding
the database, and refused a second POCOX server on the same source; a bridge
test released and reopened a session and kept the original history across
Apply. In the macOS app, a native OpenCode host reopened the same original
session after Apply and after a quit and relaunch, and it answered each time
(see [Native OpenCode](opencode-native.md#verification)). Remote controllers,
several controllers on one session and other platforms are not covered.

The evidence below predates automatic session access and used the former
explicit Session control dialog and OpenCode ACP preset; it is not evidence
for the automatic flow or for native OpenCode hosting.

The updated native app also released and reacquired one task-owned Claude UUID,
retained an unsent draft through both operations, sent it and displayed the real
model reply. The first native history read after release replaces ACP replay
identities without duplicate messages; failed reads retain the previous display.
A running turn offered no release action. An admitted OpenCode session continued
on its existing (ACP) engine and returned a real reply. Chinese control dialogs were
checked in light/dark at desktop and the native minimum window width. No external
user session was resumed or stopped in these checks.

These checks do not establish other-platform UI support, every future
SDK/database schema or exclusivity against independent native clients.
