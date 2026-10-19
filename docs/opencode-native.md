# Native OpenCode

OpenCode is POCOX's third engine, beside native Codex app-server and
generic ACP agents. The host runs the user's installed `opencode serve` and
speaks OpenCode's own v1 HTTP + SSE API; controllers reach it through the
relay under `pcx:<device>:opencode:<name>` (`pcxu:<user>:…` in account
mode). Nothing is bundled: a missing `opencode` is an installation/path
error.

It replaces the former `opencode acp` preset, whose model-catalog plugin and
custom provider routes are removed. Saved records of that preset are dropped
when preferences load and are never relaunched as a generic ACP agent.

## Versions

Each OpenCode major version speaks its own native wire. The host reads
`opencode --version` once and picks that version's `Wire` implementation
(`opencode/wire/`), called through a closed `match`. The host, fold,
gateway, bridge and Flutter read the 1.x shapes either way.

| | 1.x (1.19.3 tested) | 2.x (2.0.32 tested) |
| --- | --- | --- |
| Database | `opencode db path` | `opencode debug paths db` |
| Routes | `/…` with `?directory=` | `/api/…`; project reads take `location[directory]` |
| Busy | `/session/status` | listed by `/api/session/active`; all others idle |
| Model and agent | in every prompt | set on the session, only when changed |
| Turn start and end | `session.status` | `session.execution.*`, mapped onto the same busy and idle status |
| Live events | every event invalidates its session | step, tool, permission and form boundaries; token deltas are dropped |
| Models | connected providers' models | `/api/model` (`/api/provider` lists only configured providers) |
| Attachments | file parts | `files` with the image's data URI; OpenCode checks the base64 and detects the type from the bytes |
| Image input | `capabilities.input.image` | `"image"` in the model's `capabilities.input` |
| Custom provider | `provider` block in `OPENCODE_CONFIG_CONTENT` | the same block; 2.x runs each `@ai-sdk/*` package as its own built-in one |
| Local sessions | `session` with `message`/`part` or `session_message` | `session_v2` with `session_message` |

A version outside the tested range still starts, with a notice in its
host's status. One that cannot report its database cannot be hosted.
OpenCode 2 prefers `OPENCODE_PASSWORD` to `OPENCODE_SERVER_PASSWORD`, so the
host removes both inherited names before injecting its private password.

2.x has no `bash` tool and asks before reading `.env` by default; a message
ID may be used only once. Configured commands appear shortly after the
server starts. 2.x keeps a prompt's attachments as bytes (`data`, `mime`),
not URLs; history turns them back into data URIs. It uses the same database
file as 1.x and, on first open, copies every session into `session_v2` and
`session_message`, leaving the 1.x tables frozen, so Local sessions reads
`session_v2` whenever it exists.

OpenCode 2's terminal app, `opencode run` and desktop app share one
background server (`opencode serve --service`) that keeps running after they
exit. A 2.x host on the shared history with OpenCode's own configuration
attaches to that server instead of starting its own, and writes while no
other client is connected to it
([OpenCode 2's background server](#opencode-2s-background-server)). A host
that keeps its own server beside it (a custom provider) follows read-only
while it runs: the access names it (holder `opencode_service`, from its
arguments) and says to stop it with `opencode service stop` or to give the
host its own history.

Not covered on 2.x yet: token-by-token text (replies appear at text and
tool boundaries), and forms with number, boolean or external fields (they
can only be rejected).

## Hosting

- **Several hosts, one per history source.** Each host owns its own
  `opencode serve` process, and a device can run several, like Codex and
  ACP hosts, each under its own instance name. One host at a time serves a
  given database across Pocket processes (a claim keyed by its canonical
  path, `opencode_already_hosted` when taken), so each host chooses its
  **history**:
  - *Shared with OpenCode* (the default, and what every record saved before
    the choice existed means): OpenCode's default database, the sessions the
    OpenCode terminal app shows and Local sessions reads. One host at a time.
  - *This host only* (`separateHistory`): the host's own database,
    `OPENCODE_DB=pocket-codex-<canonical name>.db`, which OpenCode resolves
    in its data directory beside its default database (a digest replaces a
    very long name). Detection, the claim and the server all use it; the
    same instance name finds the same history again. OpenCode's
    configuration, `auth.json` sign-ins, snapshots and logs stay shared;
    what OpenCode keeps in its database (sessions, and its newer account and
    integration records) does not.

  The editor's OpenCode tile always starts a new host: a free name
  (`opencode`, `opencode-2`, …) and, beside a host serving the shared
  history, *This host only*. Choosing *Shared* while another host serves it
  says so under the choice, and Start is refused with that reason before
  anything starts. A remote add picks the same way on the host computer (a
  remote edit keeps the saved choice). Changing the history of a running
  host is a runtime edit: saved, then applied with a restart.
- **Instance names are unique per device**, compared as the relay compares
  them (`My Host` and `my-host` are one instance). A new host's editor —
  Codex, OpenCode, ACP, and the remote editor — shows a taken name under
  the field and refuses Start without asking the bridge; a refusal from the
  bridge (a host that appeared meanwhile) says the same. A name published on
  the relay by another computer keeps its own relay message.
- **Desired runtime:** the executable and the history (`HostRuntime.opencode`,
  kind `opencode` with `binary` and `separateHistory`). The editor detects it (`opencode_detect`:
  path, version, problem) and offers a path override with Browse and
  re-detect. A detection problem (not found, a version that cannot be
  read or used) is said before anything starts; a running host without a
  connected provider says so on its details page.
- **Model service:** OpenCode's own
  configuration (providers, keys and sign-ins in `opencode.json` and
  `opencode auth login`, unchanged), or a custom provider for this host only:
  OpenAI Responses, Anthropic Messages or OpenAI Chat Completions, with a
  base URL, default model and key (`host_config_supported(engine: "opencode")`;
  the editor honors its `modelRequired` / `keyRequired`). It uses the shared
  model-service form: a stored key is never read back and is kept, replaced
  or removed; Save changes nothing that runs, and Apply restarts this host.
  No official account, plugin or ACP route.
- **Gateway models.** The model entered is the default, not the only model.
  Each start and Apply of a custom-provider host asks the gateway for its
  models with the saved key (`GET <base URL>/models`; Anthropic Messages with
  `x-api-key` and `after_id` paging, the OpenAI APIs with a bearer token and
  one list) and registers every returned ID and name with the host's
  provider; entries marked retired are skipped. The default model is always
  kept, even when the list omits it (an alias may still be callable). Only
  IDs and names are taken, never provider options, headers or overrides; the
  read is bounded (15 s, 4 MiB, 32 pages, 4096 models) and follows no
  redirects. When the list cannot be read, the host still starts with only
  the default model and its details page says so; applying the configuration
  again retries. **Refresh** re-reads OpenCode's catalog only; it does not
  query the gateway again and keeps that warning.
- **Apply** prepares the new launch before stopping the running host, and
  restarts the previous launch (executable and model service) when the new
  one fails. Stopping a host ends every controller event stream it serves,
  so no controller keeps a stale stream to the old incarnation: the bridge
  reports the host as reconnecting (`acp/host/state {"connected": false}`),
  withdraws pending permission cards, and the screen reconnects to the new
  incarnation and reopens the same original session ID without a manual
  disconnect. Drafts, attachments and queues are kept.
- **Quit** stops native OpenCode hosts with the other owned hosts
  (`serve_stop_all`): admission closes first, each host stops under its
  lifecycle lease, and a host that did not stop, or a startup still
  stopping, fails the quit and keeps the app open with "Quit again". On
  macOS every native quit (Cmd+Q, menu, Dock) takes this path
  ([Hosting configuration](hosting-configuration.md#identity-save-and-apply)).
  Closing the window hides the app to the tray and leaves hosts running.
- **Restore on launch:** every host with a bridge restore record, with its
  saved model service and desired runtime (`host_config_get`, stored key
  kept); an unreadable configuration restores nothing rather than replace
  it. Hosts with their own history all restore; at most one host on the
  shared history does, never beside a running one. The older single UI
  record (`autoHostOpenCode`: name, optional executable) is written only for
  a host on the shared history and follows the same rule.
- **New conversations need a project folder.** OpenCode creates a session
  only in a folder: without one the welcome asks for it, and a send opens
  the folder picker instead of sending (nothing is shown as sent; button,
  desktop Enter and queue alike). Choosing a folder moves the draft (text,
  attachments, draft options) there and sends it once; when that project
  already holds an unsent draft, both stay in the composer unsent.
  Cancelling keeps everything. A session that could not be created returns
  the message to the composer with Retry (an ordinary send of what the
  composer holds), and New conversation clears that banner. The same holds
  for ACP agents; Codex still works outside a project.
- **Host details** show the version, connected providers, model count,
  default model and agents from the host status. The default model is the
  custom provider's captured default; on existing configuration (inherited)
  it is currently unknown, since no global selection is queried.
  **Refresh**, offered for a
  healthy host too because models and sign-ins change outside Pocket, asks
  that running host by name (`opencode_refresh`) to re-read OpenCode's
  catalog; a read that fails is kept as the status problem, and a result
  from a host restarted meanwhile is discarded. The provider catalog is
  read through a field whitelist: `/provider` options can hold credentials.

## Capabilities

The host reports protocol `opencode-http`, provider `opencode`. The session
UI is driven by capabilities, not by engine name:

| Capability | Meaning in the UI |
| --- | --- |
| `draft_options` | model / agent / variant chips work on an unsent draft |
| `commands` | the `/` command list above the composer |
| `question_multiple` | questions may allow several answers |
| `permission_feedback` | a permission answer may carry text (off for now) |
| `session_config`, `permission_options`, `steer`, `rename` | as for ACP agents |

The host reports a model catalog together with session and draft options.
The options carry the model, so the composer shows them (model, agent,
variant) instead of the Codex model menu, and a turn sends no model, effort
or collaboration mode of its own.

The Codex setup banner and send guard apply only to a Codex app-server: an
OpenCode host (its own configuration and sign-ins, or a custom provider)
never waits on Codex's sign-in, even where it also reports local history.

## Draft options

A new conversation creates its OpenCode session on first send, not ahead.
Its option chips read the defaults of a new session in the draft's project
(`app_draft_session_settings`; OpenCode offers each project its own models
and agents) and keep the user's choices on the draft itself. Drafts are per
project, so a choice made in one project is neither shown nor applied in
another, and switching projects sends nothing. What a chip shows is exactly
what the first send applies:

- Only a chosen model's variants are offered (values grouped by model).
  Choosing a model resets its variant, as the host does, so a newly chosen
  model shows its default (no variant) until a variant is chosen; a variant
  chosen for another model is dropped, even one of the same name.
- Choosing the value an option shows without a choice (the default model,
  the default variant) records no choice.
- Nothing is sent for these choices and no host-wide default changes.

On the first send the session is created, the choices are applied to it
(model first, then variant, then the rest), and only then is the message
sent. If the host refuses a choice, the message is not sent: it returns to
the composer (before anything typed since), its sent copy is withdrawn and
the refusal is shown. From then on the conversation shows the session's own
options, and choices that were not applied are not applied later behind
the user's back; sending again sends the message with the options shown.

OpenCode v1 selects model, variant and agent per message; the bridge keeps
the session's pending choices for its next prompt.

Draft and session settings are read from the host asynchronously
(`app_draft_session_settings`, `app_session_settings_refresh`), since
OpenCode answers them from its HTTP catalog; ACP agents keep their cached
state. The composer and menus stay usable while a read runs. A refresh of
the same session or draft keeps what is shown; options of another session,
draft or project are never shown meanwhile. An answer for a view, project
or connection that has since changed is dropped, and requests made while a
read runs coalesce into one following read, so an older answer never
replaces a newer choice. A read that fails (an unreachable host or
gateway) is reported as a failure, not as empty settings: the same session
or draft keeps what is shown, its menus and choices, and the next refresh
asks again; another session, draft or project shows none of the previous
one's. A send applies its draft's choices after reading that project's
defaults again, before the message.

## Commands

With `commands`, typing `/` at the start of the composer lists the host's
commands for the shown project (`app_command_list_for_project`: name,
description, source, hints), prefix matches first; a list answered for a
project the view has left is not shown. OpenCode's models come from the same
project's session or draft settings (above), not from the generic composer
model menu (`app_model_list_for_project`), which is off whenever
`session_config` is negotiated. Arrow keys move, Tab or Enter picks, Escape
closes; picking writes `/name ` into the draft and sends nothing. The message is sent as
typed; the host recognizes exact known command names, and any other `/text`
is ordinary text.

## Permissions and questions

Permission requests use the ACP permission card: the offered options in
their order (a localized label when one has no name), answered by option id,
with the patterns an "always" answer allows. Questions use the existing
question card, with multiple choice and a free-text "Other…" where allowed.
Cancel answers the question as rejected. A request resolved elsewhere
removes its card.

## Sending

The default send while a turn runs is the local queue. **Supplement** sends
into the running turn (`prompt_async`) when `steer` is negotiated. A message
ID is not an idempotency key, so a send whose outcome is uncertain stays
queued and marked and is sent again only by an explicit Retry.

Cancel clears the host's running turn when OpenCode confirms the abort. If
OpenCode answers `false`, the turn counts as ended only when a fresh status
read right after it reports the session idle; a failed read, a busy status
or a transport error leaves the turn uncertain, and exact-turn checks stay.

A model failure is classified by the host from bounded fields only (error
name, HTTP status, the provider's error code) into a fixed reason such as
region unavailable, authentication, quota, rate limit or context length;
the provider's own message, which can echo requests or secrets, is never
shown. The failure (`modelError`) is one inline card with the
localized reason, the failed model and the next step, never a reply and
never also the error banner. A terminal-only failure gets a card under the
host's own `itemId` and exact prompt `turnId` (a supplement's own prompt,
not the running turn's), so the item arriving later, live or in a history or
follow read, replaces it by ID. A failure pauses the queue. Only the
conversation's last row in a writable, idle view offers actions: **Change
model** opens the session's own model option and sends nothing; **Retry**
sends the failed prompt's message again as a new turn with the model
selected now and leaves the draft and attachments alone. While a model or
other option change of the shown conversation is being saved, every send
(button, Enter, queue, supplement, Retry) and that conversation's options
wait; the draft stays, and nothing is sent when the save ends. A refused
change says so and keeps the previous model; a save of a conversation left
meanwhile neither holds nor releases the one shown now. Retry is withheld
when that message is not here exactly as sent: not loaded (a supplement
sent from this view), truncated (`#input:<id>`), missing attachments
(`#attachments:<id>`), or carrying a non-inline image, so a partial copy is
never sent as if whole; editing the message or a new send remains. A
stopped turn's terminal names its stop row
(`turn.interruption = {itemId, turnId}`, the supplement's own prompt when a
supplement was stopped): that row is shown under the host's ID whoever
stopped the turn, so the item and later reads are the same row. A host that
does not name it keeps the local marker for a Stop pressed here, which gives
way to the host's `interrupted` item of the same turn.

A completed message whose output is reasoning with no separate text part
(`reasoningOutput`) is shown in full, live and read-only, with a note that
the model returned it as reasoning without a separate answer. No answer is
extracted from it and no boundary is guessed; a message that also has text
shows its reasoning as before.

## Session access

Opening an existing OpenCode session resolves its access through the host,
as for Claude ACP hosts ([session access](native-agent-history.md#session-access)).
OpenCode's events and status are process-local, and its TUI exposes no TCP
server by default, so another OpenCode process on the same database cannot
be observed per session: the host reports `external_source_open` and the
view follows read-only until that process closes or releases the source and
the user checks again. A session this host never admitted then reports
`not_opened`, so the recovery is the explicit **Check now**, not a background
check. Quiet time never grants write access.

The host retains admission state for at most 256 sessions. To open or
create another it forgets one (released sessions first, then the least
recently used), and only one that OpenCode reports idle with no pending
permission or question; a running turn or unapplied options are never
forgotten. Candidates are checked per project directory: a directory whose
state cannot be verified (a failed status or request read, or a pending
request without a valid session ID) is skipped and the next safe directory
is tried; the open or create fails only when no directory is safe.
A session the host holds no admission for reports `not_opened`: one it never
admitted (for example while another process held the source), one it forgot
here, or any session after the host restarted. It never regains write
access by a background check. A view following it says the host is not
keeping it open; **Check now** opens it afresh when that check finds no
writer and no running turn, and **Continue here** opens it explicitly. A
forgotten released session stays handed back until **Continue here**. Drafts
and queues stay. Navigating to a session still opens it as before.

A conversation created by its first send was never opened here, so its
access is read after that send and again at each turn's end until the host
says it can be handed back: an answer read while the turn ran, or a failed
read, does not stand, and **Hand back** appears without reopening. The read
has no side effects, never opens the session or decides a send, and adds no
polling; only the latest writable answer for the same view, connection and
session applies, and after Hand back, a follow or a switch it reacquires
nothing.

When the bridge reconciles its open sessions and the host answers that one
was deleted, only that session leaves the controller. Deletion needs a 404
`session_not_found` from the session's own metadata route, answered by the
current host identity; a 404 from an ancillary route
(`native_request_failed`) keeps the cache like any other failure. Its
pending requests are withdrawn, a running turn ends as failed, and the
bridge sends `thread/deleted`. The conversation
list drops it (a later listing that still names it does not bring it back);
a view showing it stops following and checking it, shows that the session
is no longer on the host, and opens it no more, while its unsent draft and
queue stay in their slot. Nothing said about it afterwards (an answer still
in flight, a turn, a request, an access change or a host refresh) acts on
it: no access, open, history or settings read follows. The other sessions
keep reconciling. Any other error, or a different host answering, remains a
failure and the cache is kept.

OpenCode's events are process-local, so a deletion by another process (for
example the official CLI) sends nothing on this server's event stream. The
same exact 404 answered to an access check or a follow read is therefore
also a deletion, with the same withdrawal and `thread/deleted`: the access
answer becomes `not_found`, blocked and not re-checked, and the follow ends.
A replaced host identity answering instead is a reconnect error, not a
deletion.

## Local history

Desktop Local sessions reads OpenCode's database directly and read-only
([provider-native history](native-agent-history.md)). A session there is
continued by opening it on the running OpenCode host (**Continue in
<host>**), or by hosting OpenCode first.

## OpenCode 2's background server

Proposed 2026-10-19. The user chose option A (below), and it was implemented
on 2026-10-20. Option B, takeover, stays deferred (AGENTS.md item 35).

**What OpenCode 2 does.** From the 2.0.32 source
(`packages/cli/src/server-process.ts`, `services/service-config.ts`,
`packages/client/src/effect/service.ts`). The marked facts were also seen on
the official build, with an isolated HOME and XDG root and a port of the
probe's own:

- The first client starts `opencode serve --service` (through
  `Service.ensure`, detached). The service runs from the home directory and
  keeps running until `opencode service stop`. It listens on 49374 (0xC0DE)
  for release channels, unless `opencode service set port` changes that. It
  holds the database. *Seen:* it was the database's only holder, and with no
  client connected it held only its listening socket.
- Discovery is one file, `<state>/service.json`. The state directory comes
  from `opencode debug paths state`; other channels use
  `service-<channel>.json`. The file holds `{id, version, url, pid,
  password}` with mode 0600. Requests authenticate as Basic
  `opencode:<password>`, and `/api/info` answers `{version, pid, urls}`.
  *Seen:* the file had mode 0600, the pid matched, and a wrong password got
  401. The password is also saved in `<config>/service.json`.
- The service can be replaced. These stop it (SIGTERM, then SIGKILL) and
  start a new one with a new id and pid: a TUI of another version
  (`mismatch: "replace"`), `service restart`, and `service set` of port,
  password, hostname, cors or env. `opencode service start` reuses any
  compatible running service and never replaces one.
- The service's environment is the one of the client that started it, plus
  `service set env`. A later client's `OPENCODE_CONFIG_CONTENT` never
  reaches it.
- `opencode service set disabled true` stops the service. Clients then run a
  private `serve --stdio`, which holds the database only while they are open,
  as 1.x did. *Seen:* the TUI's private server held the database and exited
  with the TUI.
- Each session has one engine. Input goes through a per-session inbox
  (`session.inbox.enqueued` / `delivered`), and only one execution per
  session runs at a time. Every client sees every session's turns. *Seen:*
  one client's `/api/event` received another client's `opencode run`, from
  `session.execution.started` to `succeeded`.
- The server keeps no list of its clients, and nothing tells which session a
  client is showing. From outside, only process-level facts are visible.
  *Seen:* an open TUI kept one established loopback connection to the
  service (its event stream) after two idle minutes, and none once it
  exited. With remote access (`opencode service set remote`, `pair
  --remote`), remote clients are proxied inside the service's own process.
  Its `/api/info` `urls` then list the remote address.

**1. Attach instead of spawn.** This applies to a 2.x host on the shared
history with the inherited model service:

- If `opencode service get disabled` prints `true`, the host runs its own
  server, as today. The user's clients then use private servers, and holder
  evidence works unchanged.
- Otherwise the host reads the registration. It attaches when `/api/info`,
  asked with that password, answers the same pid and the host's major
  version, and that pid is the only holder of the canonical database. If no
  service is running, the host first runs `opencode service start`. It runs
  it with the plain inherited environment: the child PATH only, and no POCOX
  password, agent tools or configuration, since the service outlives POCOX
  and serves every client.
- A service of another major version, or one on another database, is refused
  with that reason. The host does not fall back to a server of its own,
  which would be a second engine on the history.
- The POCOX source claim is still taken, so there is one Pocket host per
  source.
- This mirrors an adopted Codex app-server (AGENTS.md items 26 and 37). The
  host joins a server it did not start and never signals it.

**2. Lifecycle.** An attached host owns no process.

- **Stop and quit** detach: they close the event stream, withdraw the relay
  keys and release the claim. The service keeps running, as after any
  OpenCode client exits. Nothing goes into the process ledger or
  `pending_cleanup`, and a detach never fails a quit.
- **Apply** to the same configuration detaches and attaches again, with no
  restart. Apply to a custom provider or to its own history detaches, then
  starts the host's own server, as today.
- **Watchdog.** The event stream ends, or the registration changes (id, pid
  or url): either way, it is a new engine generation. The host re-reads and
  re-validates the registration as at attach and reports `transition`
  meanwhile. Running turns become uncertain and are recovered from
  `/api/session/active`, as on a reconnect. After the user's
  `opencode service stop`, the host stays reconnecting and says so. Only an
  explicit Start, Apply or restore starts the service again.
- **Status** reports the service's pid. A new `OpenCodeStatus` field,
  `backgroundServer` (serde default false), says the server is OpenCode's own
  and that Stop detaches. `alive` means a healthy attachment, not that the
  pid runs.
- **Agent tools** are not given to an attached host. OpenCode's `mcp.add` is
  server-wide, so it would hand the host's token to every client of the
  service, remote ones included. The host's status says so.

**3. Custom providers.** Their `OPENCODE_CONFIG_CONTENT` cannot reach a
shared service, and `service set env` would change it for every client. So
they keep a server of their own. On the shared history, that is a second
engine beside the service, so the host follows read-only while the service
runs, as today. Recommendation: while the service is enabled, the editor
selects *This host only* for a new custom-provider host and says why.

**4. Session access.**

What the server can show:

- every session's running turn and its end;
- queued and delivered input;
- pending permissions and forms.

Since one engine runs each session, a send from POCOX and a send from the TUI
are queued in order. They are not two engines writing at once, as with 1.x
servers.

What it cannot show: which sessions a client has open. An idle TUI, desktop
window or browser tab is not visible over HTTP. Only "a client process is
connected" can be observed.

- **A. Write only when no other client is connected** (recommended). This
  keeps item 29's rule ("write only from a fresh no-owner admission"); only
  the evidence changes. A session is writable only when a fresh inspection
  finds all of these:
  - the registration still names the attached instance;
  - the service is the only holder of the database;
  - every established connection to the service's port comes from this
    process;
  - `/api/info` lists only loopback URLs, so no remote access or wildcard
    bind.

  Another connected process reports `external_source_open` with its pid.
  Unlike today, it also carries the session's real turn state from the
  server. A remote or unattributable peer is `source_unknown`. Once the TUI,
  desktop app and browser tabs close, the service stays, and sessions become
  writable through the existing **Check now** and open flow.

  Limits: a client that connects only per request, with no event stream, is
  invisible between requests. This is evidence of possible writers, not a
  lease, as today. A race between the check and a send is queued by the
  server's inbox; it does not create a second engine.
- **B. Continue while another client is connected.** This is the takeover
  of AGENTS.md item 35. It would need all of these:
  - per session, no running turn and no pending input, permission or form
    on the server;
  - an explicit confirmation that names the connected process, for example
    "OpenCode (pid …) is connected and may be showing this session; what you
    send appears there";
  - an admission per session and per connection, revoked by any turn or
    input from elsewhere;
  - never automatic, and never stopping the other client.

  Not proposed for implementation; item 35 stays deferred.

**5. The password.**

- It is read only from the registration file. Never from
  `<config>/service.json`, never through `service get password`, and never
  through a child's argv or environment.
- It is read only after checking that the file is a regular file owned by
  this user, with no group or other permission bits.
- It is decoded straight into `Secret`. A decode failure gives a fixed
  message, because serde errors can quote values.
- It is used only in the private client's `Authorization` header. It never
  appears in logs, status, `ServeStatus`, controller answers, records or
  errors.
- It is re-read only at attach and re-attach, and dropped at detach.
- The URL must be loopback HTTP with no credentials, the same check
  `listening` makes.

**Verification, if approved.** The opt-in `opencode_native` live tests, on
2.0.32 with an isolated root and the test's own `service set port`:

- attach to a running service, and to none (the host starts it);
- write with no other client;
- follow with an idle TUI (run under a pty) connected, and become writable
  once it exits;
- attach again after `service restart`;
- never stop the service on host stop or quit.

1.19.3 keeps its own server, unchanged, and so does 2.x with `disabled`. The
AGENTS.md §7 checks also apply.

**Decision (2026-10-19):** option A, as above; B stays deferred.

**As implemented** (`opencode/service.rs`, `Server::attach`, the
`serve_opencode` watchdog):

- Attaching refuses a service whose `/api/info` lists a non-loopback URL.
  It does not check this again at each admission: OpenCode restarts the
  service to change remote access or its hostname, and the host checks
  the replacement when it attaches again.
- A connected client is shown in one of two ways, both read-only. While
  another client's turn runs: `external_running`, holder `opencode`.
  Otherwise: `external_source_open`, holder `opencode_client`, with the
  session's turn (a turn this host started stays this host's).
- The watchdog reads the registration every 2 s.
  - A replaced service is attached again under the host's lease. Controllers
    reconnect to the new incarnation, as after Apply.
  - A stopped service is reported in the host's status ("OpenCode's background
    server stopped"). The host attaches again once a client starts a new one.
- Host details show the server as "OpenCode's background server (shared,
  without POCOX tools)" (`OpenCodeStatus.backgroundServer`).
- Not done: the editor still lets a new custom-provider host choose the
  shared history (point 3's recommendation).

**Verified (2026-10-20)** on official 1.19.3 and 2.0.32, with isolated roots
and the test's own port. The new `opencode_native` live test, on 2.0.32:

- `disabled` keeps an own server;
- with none running, the host started the service and attached;
- a second Pocket host on the source was refused;
- a prompt was answered with no other client;
- the idle terminal app under a pty made the session follow
  (`opencode_client`, idle), refused a rename, and wrote again after the
  app exited;
- `service restart` was seen as a replacement and attached again;
- stopping the host left the service running until `service stop`.

On 1.19.3 the host keeps its own server. The other three live tests passed
on both versions.

The bridge acceptance test passed on both versions. On 2.0.32 it ran through
the background server: start, source singleton, a prompt, release and
reopen, and Apply keeping history and the service. After `service restart`
the watchdog attached the host again by itself, with a new incarnation and
service pid. Stop left the service running.

Also passed: the Rust workspace (905 passed, 26 ignored), clippy, and the
Flutter suite (1658 passed, 7 skipped). Not verified: the macOS app, a
relay or second device, and other platforms.

## Verification

OpenCode 2 (2026-10-19), against the official OpenCode 1.19.3 and 2.0.32
builds on one Mac, with disposable data and a local deterministic model:
the three real-server host tests (lifecycle and an outside database holder;
gateway admission and closed routes; turns with a supplement, a permission,
a question, a command and cancel) and the bridge hosting acceptance test
(start, source singleton, local connect, a prompt to a completed turn,
release and reopen, Apply keeping history, stop) passed on both. Unit tests
cover 2.x frames, catalogs, history, forms and prompt selection.

OpenCode 2 attachments, custom providers and Local sessions (2026-10-19),
same builds and fixtures: the real-server and bridge acceptance tests passed
again on both versions; the lifecycle test's prompt now carries a PNG, which
the model received and history returned, and the catalog reported the
model's image input. Through the bridge on 2.0.32, a custom-provider host
for each of OpenAI Responses, Anthropic Messages and OpenAI Chat Completions,
pointed at a local gateway, listed the gateway's models, offered images, and
completed a turn whose image reached the gateway. The Local sessions reader
read databases 2.0.32 created (an image prompt; a failed turn, its error
shown once) and a 1.19.3 database after 2.0.32 upgraded it (sessions from
both versions).

Several hosts (2026-10-16): the real bridge lifecycle test also starts a
second host with its own history beside the first, reads its status and
stops it alone, while a second host on the shared database is still refused
(`opencode_already_hosted`). In the macOS app, beside running Claude, Codex
and shared-history OpenCode hosts, the OpenCode tile offered `opencode-2`
with *This host only*; a typed `OpenCode` and the shared choice were each
refused before anything started; `opencode-2` then ran its own
`opencode serve` on `pocket-codex-opencode-2.db`, connected with an empty
session list, and stopped alone. No message was sent. Rust 855 passed (24
ignored); remote add and edit by tests only.

On one Mac with installed OpenCode 1.19.0, the full Rust (831 passed, 24
ignored) and Flutter (1557 passed, 5 skipped, plus 160 focused) suites
passed with format, clippy and analysis, and a coherent macOS build (source
hash `127debfc…`) was run against the user's real configuration, database
and sign-ins. With this round's Rust:

- Three opt-in integration tests against a real `opencode serve` passed:
  source ownership (a second Pocket server is refused, another process
  holding the database is detected), exact original-session admission and
  the gateway's closed mutation routes, the host's live stream, options,
  permissions, questions, commands and cancellation, and a stopped host
  ending its controller event streams.
- A real bridge lifecycle test (138 s) covered local probing, catalog refresh in the
  same incarnation, meta services, a prompt, release and reopen, the
  one-host-per-source rule, apply with original history kept, stop and quit.
- Session retention and a `false` abort are covered by tests only.

In the final app build (`127debfc…`), a new conversation's first send
created a session with `opencode/mimo-v2.6-flash-free`, which replied in
9.4 s. **Hand back** was offered without reopening; **Release** and
**Continue here** kept the same session ID and an unsent draft, sent
nothing, and the history showed each message once. Busy-first and
failed-first access reads are covered by tests only.

In an earlier build of this round (`1a8cb671…`):

- A model refused by its provider (`opencode/muse-spark-1.3-contributor-free`,
  HTTP 403, region) showed one inline region card. **Change model** opened
  the model option directly; choosing `opencode/mimo-v2.6-flash-free` sent
  nothing and kept a newer unsent draft. **Retry** then sent the original
  prompt unchanged and received the reply in 4.4 s.
- A reasoning-only reply was shown in full (803 characters), with its
  reasoning note, when existing history was inspected without sending; the
  dedicated read-only viewer is covered by tests only.
- Release and Continue here after reopening kept the history without
  duplicates and the draft unsent.
- Retry of truncated or attachment-missing messages and stop-row identity
  are covered by tests only.

In an earlier build (`4011bbdb…`), against the user's inherited host
configuration and a disposable session:

- With another OpenCode process holding the source, the session stayed
  read-only (`external_source_open`). Once that process closed, the view did
  not open it by itself; one **Check now** opened the original ID, and a
  message there received a real reply.
- **Release** showed the user's message once and offered only **Continue
  here**. **Continue here** kept an unsent draft and sent nothing.
- The official OpenCode CLI, in another process, deleted that session. The
  view showed it as no longer on the host, with no Continue, Check, composer
  or error, and its sidebar row was removed. Another original session still
  received a real reply.
- This covers desktop-local access and follow recovery only; no relay or
  multi-device run was repeated. Only the disposable session was deleted.

In an earlier build of this round, with two real projects (Alpha, Beta) whose
OpenCode configurations give the same model ID different names and each
their own agent and command:

- The draft showed the native model, agent and variant options, not the
  Codex model menu. Switching Alpha → Beta → Alpha showed each project's own
  model name for the same ID, kept each draft's choices, and listed each
  project's own commands; switching projects and picking a command sent
  nothing.
- Alpha's first explicit send created one session with its project agent
  and received the expected reply.
- An existing session switched to Beta's project agent and the next message
  received the expected reply with that agent.
- The model offered only its default variant, so other variant choices are
  covered by tests only.

These app checks ran on earlier builds of this branch and were not repeated
on the final one:

- A send without a project (desktop Enter) opened the folder picker and
  showed nothing as sent; cancelling kept the draft; choosing the worktree
  created exactly one session. The user's own running turn was cancelled, a
  new conversation started, and the original reopened with its history. A
  model chosen from the native catalog answered.
- A per-host custom provider with OpenAI Chat Completions answered after
  Save and Apply. Apply reconnected the open conversation without a manual
  disconnect. Restoring existing configuration and applying again answered
  in the same original session ID.
- A per-host custom provider with Anthropic Messages, pointed at the user's
  existing Anthropic-compatible gateway, answered a message sent in the app;
  OpenCode's own record shows the turn finished normally with no error.
- The same gateway's host listed all 110 model IDs the gateway returned,
  with none omitted, and a non-default model chosen in the conversation
  answered.
- Applying existing configuration to that host in the running app (same app
  process, new `opencode serve`) cleared the draft's previously chosen
  gateway model back to the default, replaced the offered models with the
  inherited catalog without an app restart, and kept the draft text unsent.
  An explicit send then received a real reply. Draft attachments across
  Apply are covered by tests only.
- Cmd+Q stopped the owned `opencode serve` and the app exited with status 0,
  with no manual signal. After relaunch, automatic hosting and history
  restored, and the same original session ID answered. Closing the window
  kept the app and host running; reopening showed the history.

Not verified:

- OpenAI Responses: a request reached the provider's `/responses` endpoint,
  but the only model tried was refused by the provider (HTTP 403, region),
  so no successful Responses reply is recorded. The UI recovered to ready;
  further live Responses testing was waived and none was run with the
  model-failure card.
- Controllers through a relay, several controllers on one host, a second
  physical device, hosted-account mode and platforms other than macOS.
- Evidence from the removed `opencode acp` preset is not evidence for this
  engine.
