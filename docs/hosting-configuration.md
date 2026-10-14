# Hosting configuration

The hosting editor (`apps/flutter/lib/src/hosting/host_editor_page.dart`) is one
page for creating a local host and for editing a running one. Each host has a
saved configuration for its instance name on this device: a **model service**
(where its agent sends model requests) and, optionally, a **desired runtime**
(Codex executable, port and proxy, an OpenCode executable, or an ACP program
and arguments).

## Sources

| Agent | Existing configuration | Official account | Custom provider | Required |
| --- | --- | --- | --- | --- |
| Codex (native app-server) | yes | yes | OpenAI Responses | base URL |
| OpenCode (native `opencode serve`) | yes | no | OpenAI Responses, Anthropic Messages, OpenAI Chat Completions | base URL, model, key |
| Claude preset (`profile_id` `claude`) | yes | no | Anthropic Messages | base URL, key |
| Any other ACP agent | yes (only choice) | no | no | — |

Only these mappings exist (`host_config_supported`, which takes the engine
for native OpenCode). Native OpenCode's existing configuration is its own
configuration and sign-ins (`opencode.json`, `opencode auth login`), unchanged;
a custom provider is added by the bridge for that host only, with its key in
private host storage (live evidence per API in
[Native OpenCode](opencode-native.md#verification)). There is no official
account for it.
The former OpenCode ACP preset's custom provider routes are removed. ACP has
no provider schema, so no protocol support is invented for other agents. A saved source or
custom API that an agent cannot use is shown as incompatible and blocks saving
until another one is chosen; the editor never swaps it for a supported one.

- **Existing configuration** launches the agent exactly as before. A missing
  saved record means this, so hosts and restore records from earlier versions
  are unchanged. For Codex the page reports what `CODEX_HOME` already provides,
  so reusing it is a visible, deliberate choice.
- **Official account** (Codex only) launches with `-c model_provider="openai"
  -c openai_base_url="" -c chatgpt_base_url="https://chatgpt.com/backend-api/"`.
  Sign-in runs in place on a private loopback
  `codex app-server` (`crates/pocket-codex-bridge/src/engine/codex_login.rs`)
  started with the editor's codex binary and proxy and the same official
  route. Each attempt owns its session; cancel, timeout, a new attempt or
  closing the page closes only that session, never another one. An attempt is
  reserved before its child starts and keeps its reservation until its own
  child stopped (the limit of four counts attempts still opening); quitting
  closes admission, and an attempt that finishes opening afterwards stops its
  own child. A sign-in child whose stop fails (or whose close is still in
  progress) stays in the attempt table until its exit is seen and keeps a
  place in the limit; the close fails, closing the same attempt again (the
  bridge call; the panel itself does not repeat it) tries exactly that child
  again, and a new sign-in is refused while kept children fill the limit. A
  quit tries them all again and fails (the app stays open) while an attempt is
  still opening after 10 s or a sign-in child did not exit. A stop signals
  only what the launch spawned (see "Identity, save and apply"), waits for it
  to exit and forces it if needed. Before any login request the server's
  effective configuration is read back (`config/read`), its port must still
  be held by the attempt's own server, and it is stopped and refused unless it
  routes to the official provider (no other `model_provider`, base URL,
  headers or auth).
  Success is
  the server's `account/login/completed` for this attempt's `loginId` with a
  ChatGPT account; an existing `auth.json` or API key is shown as a configured
  credential, not as a completed sign-in. A failed status refresh is shown
  and retried.
- **Custom provider** takes a base URL, an API type, a default model and an
  API key.
  - Codex: `-c model_providers.pcx_host_<hex(name)>_<authority>.*` with
    `wire_api = "responses"` and `env_key = "POCKET_CODEX_PROVIDER_KEY"`
    (`crates/pocket-codex-codex/src/provider_launch.rs`). The record's random
    authority generation is part of the id, which makes an accidental match
    unlikely; a layer naming it anyway is caught by the effective-route check
    below.
  - Claude: `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY` and optional
    `ANTHROPIC_MODEL` in the child environment and in each session's
    `_meta.claudeCode.options.{env,settings}`; other routing variables,
    including `ANTHROPIC_CUSTOM_HEADERS`, are reset.
  - Native OpenCode: a host-only provider in the child's
    `OPENCODE_CONFIG_CONTENT`, restricted with `enabled_providers` and
    selected as `model` / `small_model`. Its models are every model the
    gateway lists at start and Apply, plus the default model; if the list
    cannot be read, only the default model is registered and the host
    reports it ([gateway models](opencode-native.md#hosting)).

### Effective route

- **Codex.** After an official or custom host's app-server is ready (and
  after every watchdog restart), its effective configuration is read back
  with `config/read`, which includes managed configuration and requirements.
  The host is stopped and the start refused when that configuration selects
  another provider or model, another base URL or key variable, or adds
  headers, query parameters, a bearer token or auth to our provider
  (`verify_effective`). An adopted app-server is not checked (it is never
  ours to launch).
The model here is the **provider default** for new sessions, not the only
model a provider offers (native OpenCode lists the gateway's models). It is
not a per-conversation choice: each session's own model/effort controls still
decide that, and this page persists none of them.

The `api:<name>` service of a Codex host is a separate official Responses API
proxy that always uses the host's official Codex sign-in. It is not a proxy
for the custom provider configured here.

## Keys and storage

Records live in `<state>/hosting/profiles.json`; each key in its own
`<state>/hosting/keys/<hex(name)>.<generation>.key`, named by the record. A
key must be one printable ASCII token (no whitespace, quotes or
backslashes). A save writes the new key file and replaces the record
atomically. A staged save (Start, or Apply) also pins its old and new key in
the record file until it finishes or rolls back; pins never expire by age
(their time is diagnostic only), so an interleaved save of the same name
never deletes a key another stage may still restore, whatever the clock
does. Unreferenced, unpinned key files are removed only under the lock,
after an authoritative read and only after the record write was made
durable; a record renamed into place whose directory could not be synced
counts as committed but defers that cleanup. A key file that cannot be made
durable fails its save before the record changes. A read that found no
record file answers with that absent snapshot, even if a writer creates one
before the read finishes. A corrupt or unreadable file stops the cleanup.
The first creation of the hosting directory itself is not synced into its
parent. A start launches exactly the provider its
own stage committed, never a later save. Files are 0600, writers in several
processes are serialised by `hosting/profiles.lock`, and unreadable records
are reported, never resolved to another provider. Keys reach only the
child's environment, never argv, status, diagnostics or the record.

A Codex host launched with a key never keeps its raw output. Its stdout and
stderr are piped into the app instead of written by the child, and the
per-host codex log on disk (`codex-logs/codex-<name>.log`) receives only
fixed notices (`pocket_codex_core::redact::{OUTPUT_WITHHELD, ADDR_IN_USE}`):
that output was withheld, and that a line reported an address in use (the
line itself is not kept). The app's log viewer, and so log exports, show
only those notices for such a host, whatever the split of the key across
lines or reads. An ACP agent's stderr is drained and discarded for every
agent; its stdout is the ACP protocol and is not filtered. Errors the app
builds (watchdog restart errors, failed stops) still pass through the line
redactor (`Redactor::text`) as defence in depth; they carry no child output.
`Redactor`'s `Debug` shows only how many forms it holds. Hosts without a key
log their output as before.

The editor never shows a stored key:
leaving the field empty keeps it, typing replaces it, and "Remove stored key"
(or leaving the custom source) deletes it. A new host never inherits a key
left by an earlier host of the same name.

Every save carries the revision it was read at; a save over a newer revision
is refused. Records carry an `authority` generation that changes with the
source, URL, protocol, model or key (not with a runtime-only save); ACP
session stores are keyed by it, so history made through one provider is never
adopted through another.

## Identity, save and apply

Records, conflicts and lifecycle leases key on one canonical name
(`engine/host_names.rs`, the relay key's sanitised form); a stop by any
spelling resolves the host table's own key. Every start, stop, apply and
watchdog restart holds that name's lease (`engine/host_lease.rs`) from its
first check to its last effect; a restart also checks that the host is still
the incarnation it watches, and skips the round when the lease is busy.
A launch's identity (pid and start time) is captured when it spawns. It
owns its endpoint only when every process holding a listening socket that
connections to the listen address reach is that spawned process or a
descendant of it (at most 32 parent hops, none started before it): a shim
or wrapper that stays in front of codex is supported, matching arguments
alone never are (`core::process::endpoint_owner_under`, `core::listener`).
Only sockets on that port that apply to the listen address count: the same
address, its family's wildcard, and the IPv6 wildcard for an IPv4 address
(it may be dual-stack); `localhost` means both loopbacks, and another host
name, or a scoped (link-local) address, cannot be attributed. A listener on
another address or family that only shares the port number is ignored, as is
a scoped listener for an ordinary address. The holders come from
`/proc/net/tcp{,6}` and the tree's `/proc/<pid>/fd` on Linux, `lsof` on
macOS (only listeners this user may inspect are visible) and `netstat -ano`
on Windows. A check's tools share a 3 s budget and at most 4 MiB of output
per stream; each run then takes up to 0.5 s to stop the tool's process group
and finish reading, so a check takes at most about 3.5 s (`lsof`) or 4 s
(Windows' two `netstat` runs). A timeout, overflow, failure exit, warning, a
listing cut off inside a record or an unreadable applicable row means the
owner cannot be told (only `lsof`'s silent exit 1 is "nothing listens"). It is checked during the port wait, again after `/readyz` (an
earlier owner that merely still runs is not enough), and again after the
effective-route request (start, watchdog restart and sign-in). Each check
is a point-in-time observation: two that see the same holder do not prove
that every request between them reached it. A foreign holder, nothing
listening, a launcher that exited (its child is then not attributed) or an
owner that cannot be told fails the launch. Only owned processes are signalled; an
adopted app-server, or a process that took the port, is left running.

An owned process whose stop fails is kept in a ledger
(`serve_lifecycle::NATIVE`) until its exit is seen. Meanwhile the host is
listed with "its codex did not exit; stop the host again" (its record may
be gone; the card shows "Did not stop") and its Stop is the retry; the name
stays a Codex host for every other provider, so an ACP host cannot start
under it; a stop of the name (whichever provider hosted it last) never
reports success while one runs; a new start of that name and a watchdog
relaunch try it again first and refuse while it runs; readiness,
effective-route, registration and commit failures keep their child there
too. Apply never starts after a failed stop.

Quitting sets a fence first: a start that has not recorded its host yet
tears it down itself. Admission then closes (native OpenCode's too), ACP
agents and sign-in servers stop, the quit waits up to the lease bound
(120 s) for operations in progress, stops every native OpenCode and Codex
host under its own lease, and stops what the ledger kept. An OpenCode
startup still stopping counts as something that may still run. When anything it owns may still run (a host still busy, a kept
codex, a sign-in child) the quit fails with what remains: the app stays
open, shows the reason with "Quit again" (`quit_status.dart`), and a later
quit retries. What it cannot see (a process this app never identified) is
not claimed.

On macOS every native quit (Cmd+Q, the application menu, the Dock, an Apple
Event) takes the same path as the tray's Quit: `NativeQuitGate`
(`apps/flutter/macos/Runner/AppDelegate.swift`) cancels the request and
hands it to Dart over `pocket_codex/app_quit` (`lib/src/native_quit.dart`),
and the app exits only after the cleanup succeeded and Dart approved the
next terminate. A quit arriving before Dart listens is held and run once it
does; repeated quits join the one in progress; a failed cleanup keeps the
app open with its reason. Because the request is cancelled, a logout or
shutdown is cancelled too while hosts are stopping. Closing the window only
hides it to the tray. Signals and Force Quit bypass the gate, and if Dart
never finishes starting, a native quit stays held (Force Quit is the
escape). On one Mac, Cmd+Q with a running native OpenCode host stopped its
owned `opencode serve` and exited with status 0, without a manual signal.

- **Prepare ACP environment** installs the missing Claude adapter into the
  app cache and refreshes the environment panel. It does not save configuration,
  start or restart hosting, or enable automatic hosting. Existing hosts expose
  the same progress, cancellation and retry controls.
- **Start** (new host) commits the configuration and starts that revision as
  one operation (`engine/host_start.rs`); a failed start restores the
  previous saved configuration. A name already hosting is refused.
- **Save** writes the model service and, when edited, the desired runtime.
  Nothing that runs changes. A running native host's binary, port and proxy
  and a running ACP agent's program and arguments (including a generic agent
  without a preset or restore record, read from what it runs) can be saved
  this way. The page shows both what runs (`HostConfig.active`) and what is
  saved, and says when they differ.
- **Apply** is explicit and confirmed: the dialog says the host restarts and
  open connections drop, while conversation drafts, attachments and queues
  are kept. The incarnation is taken when Apply is pressed, before the
  confirmation and the save of pending edits; a host replaced meanwhile, or a
  newer save, is refused rather than retargeted. Everything the launch needs
  is validated before the stop. If the new start fails, the previous runtime
  is started again: Codex with its previous spawn options and provider, an
  ACP agent with the exact launch it ran (resolved program, adapter, provider
  launch, session source), native OpenCode with its prepared previous launch,
  never a fresh lookup. The page says so; if that fails too, it reports both
  errors and that the host is stopped. An adopted `codex app-server` is never
  restarted. Stopping a native OpenCode host ends the controller event
  streams it serves, so open views see the host reconnecting, reconnect to
  the new incarnation and reopen their session without a manual disconnect.

The editor loads the saved configuration before anything that depends on it
can be saved or applied, offers a retry when the read fails, keeps edits when
a later read arrives (offering it instead), keeps one model-service draft and
one agent form per agent choice (switching back restores it, and leaving asks
about edits in any of them), never lets a detection begun before a running
host's runtime was filled replace it, and asks before leaving with unsaved
runtime, provider or key edits (back, Close, the page menu, breadcrumbs and
shortcuts). A host that stopped or was replaced is not operated on by its old
name. Cancel on Claude's adapter preparation stops only the run this page
started; a run joined from another caller is not cancelled by it.

## Evidence gaps

- Claude Code settings-tier precedence is taken from the adapter source only;
  our session `settings` replace the adapter's `modelConfig` for that session.
- A quit whose host operation outlives the lease bound fails instead of
  stopping it; the app stays open. The quit itself is tested only in parts
  (its state is process-wide).
- Endpoint ownership is checked at the port wait, after `/readyz` and after
  the effective-route request, not continuously, and is not bound to the
  connection that carried the requests. On macOS another user's listener
  may be invisible to `lsof`; one that held a more specific address than
  ours could then go unnoticed. An IPv6 wildcard listener someone else holds
  refuses an IPv4 endpoint even when it is IPv6-only. A check may delay a
  startup or watchdog deadline by up to its bound (about 3.5 s, 4 s on
  Windows). A pipe kept open by a process the tool moved out of its own
  process group is never signalled; that run cannot be read and its reader
  thread stays blocked until the pipe closes. A shim that exits after
  handing off (its child reparented) is not supported: such a launch fails.
  `state.toml` records the port-wait pid.
- `codex start` / `serve` on the CLI now fail, instead of adopting, when a
  process this launch did not start holds the address, and when the
  listener list cannot be read (no `lsof` on a Unix other than Linux), and
  when `--host` is a name other than `localhost` or a scoped (link-local)
  address. Whether released Codex supports a named listen host at all is not
  established here (the pinned upstream documents `ws://IP:PORT`).
- The sign-in panel ignores a failed close (it does not repeat it); the
  kept child is retried by a later close of that attempt or the quit.

### What was verified

All on one Mac (macOS, native profile build), with the full Rust (743
passed, 14 ignored) and Flutter (1326 passed, 5 existing skips) suites,
format checks, clippy and Flutter analysis passing:

- native Codex with a custom Responses provider: real replies from two
  models across a save and an explicit apply, the applied model reported;
- the former OpenCode ACP preset's custom routes (since removed) with
  Responses and Anthropic Messages against real models, and Chat Completions
  against a local fixture;
- the official `api:` Responses proxy over HTTP/SSE and WebSocket through a
  public relay, reusing an existing sign-in without changing its bytes;
- save leaving a host running, stale save/apply refused, apply starting a
  new incarnation with the key kept, for native and Claude hosts; official
  sign-in start, cancel and close (the browser sign-in was not completed).

Observed with the former ACP preset: OpenCode did not keep a conversation's
chosen model across a host restart.

The ACP preset evidence above is not evidence for native OpenCode. Native
OpenCode hosting was verified separately with the later suites (latest:
Rust 815 passed, 24 ignored; Flutter 1503 passed, 5 skipped) and macOS Debug
builds:
custom Chat Completions and Anthropic Messages providers answered, Apply
reconnected the open conversation, existing configuration was restored in
the same original session, and Cmd+Q and relaunch restored hosting and
history. On the current build a custom Anthropic Messages host listed every
model the gateway returned and a non-default listed model answered; applying
existing configuration then replaced the catalog in the running app, cleared
the draft's stale model choice, kept its text unsent, and an explicit send
answered. A
Responses request reached the provider but the model was refused (HTTP 403,
region), so no Responses reply is recorded; see
[Native OpenCode](opencode-native.md#verification).

Not exercised: completing an interactive OAuth sign-in, other platforms,
hosted-account mode, generic provider compatibility and effort options.

## Entry points

The editor is the one place a host's model service is set. Manage and its
host cards, the home and welcome entries, Settings ("Hosting and model
service") and the custom-provider row of Codex setup open it. The last two
are not about one host: `hosting/host_picker.dart` opens a new-host editor
when nothing runs and otherwise lets the user pick a running host by its own
identity (or a new one). The chat's setup banner opens exactly its own
host's editor, and skips a host launched with its own custom provider.
Opening, picking, cancelling and leaving save, start, stop and sign in
nothing; leaving returns to the page it was opened from, and unsaved edits
ask first. One entry runs at a time per originating page: further
activations while it reads the hosts, shows the picker or has the editor
open do nothing, and a read answered after that page was covered by
another, left or closed opens nothing; cancelling, a failed read and
leaving the editor all release it. Hosting stays desktop-only; elsewhere
Codex setup says so.

Codex setup now configures Codex itself (`CODEX_HOME`): its ChatGPT sign-in
(the shared sign-in panel) and the prompt option, used by hosts on
"Existing configuration". Its former global custom-provider form is
replaced by the per-host flow. A provider that Codex's own `config.toml`
already selects is still reported, read-only. The bridge's
`codexSetupProvider` call and the on-disk format are unchanged. The final
entry guards and picker copy passed l10n generation, format,
analysis and the full Flutter suite. In the macOS profile app, Settings
and Codex setup opened the selected running ACP or native host, and the
new-host choice opened the same editor. Repeated selection opened one
editor; Escape cancelled the picker and allowed re-entry; closing returned
to the originating page; unsaved changes offered Continue editing or
Discard. Existing sessions and the empty draft/attachment/queue state were
preserved across the backed-up app update, and the original configuration
bytes remained unchanged. The chat setup-banner ownership and custom-host
bypass were covered by widget tests; the already-configured manual native
host did not display that banner.
