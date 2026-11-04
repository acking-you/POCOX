# Forking conversations

**Fork conversation** creates a new, persistent conversation that inherits a
source's context and then goes its own way. It works on an ordinary conversation
and on one another process holds: forking only reads the source, so it never
evicts or signals a writer, resumes the source, answers its approvals or sends a
prompt. Drafts, attachments and queued messages stay with the source.

Each provider forks with its own native operation; a rendered transcript is never
replayed as if it were model context. What each one offers follows what it was
verified to do:

| Provider | Operation | Latest state | Through a turn | Held or running source |
| --- | --- | --- | --- | --- |
| Codex | `thread/fork` | yes | yes | snapshot |
| Grok (from 1.0.45; verified on 1.0.70) | `_x.ai/session/fork` | yes | yes, unless compacted after it | snapshot |
| Claude (adapter 0.89.1, CLI 2.1.316) | ACP `session/fork` | yes | no | snapshot |
| OpenCode 1.x (verified on 1.19.5) | `POST /session/{id}/fork` | yes | yes | refused, except a boundary before a running turn |
| OpenCode 2.x | none used | no | no | no |
| Custom ACP agents | none used | no | no | no |

Capabilities say this: `fork`, `forkThroughTurn` and `forkBusySource`. A custom
agent that advertises `session/fork` reports none of them: ACP's fork is unstable,
and nothing shows that an unknown agent's only reads its source. OpenCode 2.x stays
off because no 2.x build was at hand to verify it against. Its shared background
server also needs its own answer, since a session it forks is written by the same
server every client uses, and this host could not write the result while a client
stays connected.

## Where it is offered

| Place | Action | Boundary |
| --- | --- | --- |
| Conversation menu on a computer, context sheet on a phone | **Fork conversation** | the source's latest saved state |
| Read-only footer of a held conversation (the access panel's, for Claude and Grok) | **Fork**, beside the existing takeover or read-only state | the source's latest saved state |
| Session viewer (`/sessions/view`) | **Fork**, beside resume or the read-only state | the source's latest saved state |
| Any message of a finished turn, the user's or the agent's (hover on desktop, long press on touch) | **Fork through this turn** | the whole turn, inclusive |

Codex forks at turn boundaries, so every message of a turn offers the same one. A
turn offers itself only with a real host turn id once it has ended, so a running
turn or cached history has no action. An older host records no completion time;
with nothing running, every turn it lists has ended.
An ACP agent stamps no completion time, so there it is every turn but the running
one, and not the newest while following a writer whose turn may still run. The host
checks again.
A Guardian review forks nowhere: the view hides the action, and the bridge refuses
before sending anything, because Codex itself would accept it.

A confirmation states the boundary and that both conversations share a working
folder, so a fork isolates history, not files. While the request is out the context
card and sheet say so, as do a phone's top bar and the status line, and the action
is not offered again. Once in the fork, the card and sheet lead with a row back to
the source, and the status line carries a mark for it where no card stands. That
link is `forkedFromId`, read from `thread/read` and kept apart
from `parentThreadId`: a fork is its own conversation, not a spawned agent,
even though the list groups it under its source.

A fork keeps its place in the family:

- It carries a mark wherever it is named: its list row, the title strip, a phone's
  top bar.
- The list shows it under its source, in the session tree spawned agents use, and
  the family moves with its newest member, so a fork in use today does not lie
  under an old source. Forks stand open by default; the source's fold control hides
  them, and a source no longer listed leaves the fork as a row of its own.
- A fork's transcript opens with a link to its source in place of "start of
  conversation", and the title strip, the card and the sheet lead there too.
- A source's card and sheet list its forks.

`forkedFromId` is what says so, and `thread/list` leaves it null: only `thread/read`
names a source. So after each listing the app asks the host about the newest 200
conversations it has not asked about yet, four at a time without turns. A source
never changes, so each is asked once per run, and an older fork is marked once it
is opened. The bridge names a fresh fork by the conversation it inherited.

## Rules

- **The serving host does it.** The request goes over the connection serving the
  source, so a remote session forks on that host against that host's history.
  `path` is never sent, so a controller's files cannot be involved. A session read
  from this device's disk forks only on a Codex host this app runs here, never on a
  connected service elsewhere. Fresh source metadata is read at request time.
- **Snapshot of a changing source.** A fork sees what the source has saved. A turn
  running in another process is frozen as `interrupted` in the branch while the
  original keeps running, and later source output never reaches the branch. Text
  still in the other process's memory is not included. `lastTurnId` naming a
  running turn is refused by Codex.
- **Effective settings.** Codex keeps the source's approval policy, permissions
  and model on the branch by its own rules; nothing here passes an override. The
  host's per-thread settings are copied to the new id too, because plan mode lives
  only there. A goal carries over without continuing (`deferGoalContinuation`):
  only the next explicit turn acts on it.
- **Outcomes.** A refusal (`invalid request`, an unknown method on an older Codex)
  means nothing was created, and is reported. A lost answer or another server
  error may follow a created thread, so it is reported as unknown and never
  retried. While a request is unanswered the action stays disabled.
- **Boundary check.** An older server may ignore a `lastTurnId` it does not know
  and fork everything. The branch's newest turn is compared with the selection;
  on a mismatch the conversation stays in the list and is not opened as if it were
  the selection.
- **Late answers.** A result after navigation offers **Open** and moves no one. A
  result after the host connection moved is not adopted, and a settings read
  awaiting its answer cannot write its result through the changed connection.
- **Confirmation.** A confirmation belongs to the conversation view and host
  connection that opened it. Navigation, a reload or reconnect invalidates it;
  the provider's current fork and turn-boundary restrictions are checked again
  before dispatch.
- **Failure never falls back** to takeover or to resuming the original.

## Claude, Grok and OpenCode

The request goes through the host's gateway (`POST /acp/v1/sessions/fork`,
`POST /opencode/v1/fork`) with the host identity the view shows, and runs on that
host against its own store. The host checks the source exists and its folder is
there before asking: Grok's fork leaves an empty session directory behind for a
source it cannot find. The new session holds nothing until it is opened, when it
goes through the ordinary [session access](native-agent-history.md#session-access).

**Grok.** `_x.ai/session/fork` copies the stored session under a new id and takes
`targetPromptIndex`, inclusive. It copies files without a lock, and the source can
be running.

- A running turn freezes at what is stored: the prompt without a reply, or a tool
  call Grok answers "was cancelled" when the fork loads. The tool never runs in the
  fork. Text still streaming in the other process is not included.
- Grok tells the model the conversation is a fork, that its files are shared and
  that it inherits no shells, subagents, loops, workflows or goal.
- A boundary is a counted prompt, from the session's log: a replayed turn knows its
  index, a live turn is found by its prompt id (which is the host's turn id), and an
  unadmitted session's turn by the reader's id. It must have ended. An index past
  the end is not refused by Grok, which copies everything, so the host counts the
  prompts stored afterwards before calling the boundary confirmed.
- A boundary before a compaction is refused. Grok rewrites what came before a
  compaction into a summary and does not undo that in a fork's copy, so the model
  would keep a summary of what the fork must not know.
- A fork's summary records `parent_session_id` with `session_kind: fork`, so the
  listing names its source after a restart.
- From its source, Grok also registers a fork with its backend for a signed-in
  account, from a spawned task and without content (`cwd`, parent id, model, agent
  id). A provider's key signs nothing in, and nothing arrived at a loopback
  `GROK_CODE_BACKEND_URL`, also with a fake local sign-in. A real account was not
  tried; expect this on the Grok account.

**Claude.** The adapter's `session/fork` calls the SDK's `forkSession`, which writes
a new transcript with fresh UUIDs and `<title> (fork)`, and starts without undo
history. It takes the session's own project folder and refuses another.

- A running turn freezes the same way: the CLI answers an unanswered prompt with a
  synthetic "No response requested" when the fork loads, and an unfinished tool call
  with an "interrupted" result. The tool never runs in the fork.
- Latest state only. The adapter's boundary is `_meta.jetbrains.air.fork`, a private
  extension of another client, so it is not used and `forkThroughTurn` is false.
- The transcript's `forkedFrom` is not in the SDK's listing, so the **Fork** tag
  stays with forks this view created.
- An error answer from the adapter is reported as unknown, since it does not tell
  what the SDK had already written.

**OpenCode 1.x.** `POST /session/{id}/fork` copies messages one at a time under new
ids, in the session's project, and titles the copy `<title> (fork #n)`.

- `messageID` is exclusive, so a boundary is the next user message's id, and the
  last turn has none. An id it does not know is not refused: it compares ids and
  copies accordingly. So the host walks real history to find the boundary, and
  compares the copy's newest user message with the turn's creation time afterwards.
- A running turn is refused, unless the boundary comes before it. The copy would keep
  an empty assistant message with no end, and a tool "running" forever. The model
  would still see "[Tool execution was interrupted]", but no view could show the
  copy as finished.
- A held source is refused (`source_held`), and the footer offers nothing. The fork
  would be written by this host's server beside another engine, the same write
  `create` refuses, and the result could not be written here until the holder closes.
  A probe with a second server on one database showed the source's rows unchanged
  and the other engine's turn invisible to this server. `not_opened` and
  `released_here` are not held: the check is the host's own fresh evidence.
- It records no source (`parentID` stays empty, correctly: a fork is no subagent), so
  the mark and the **Fork** tag stay with forks this view created.

## Storage

Forks of paginated threads, the default for current Codex, copy nothing. The
branch's rollout holds its own records plus a `history_base` naming the parent
rollout and how many of its bytes are inherited. So:

- Histories are independent, but the branch needs the source's file. Codex refuses
  `thread/delete` on a source with such a fork (`forked history still references
  it`), and removing the file by hand makes the branch unresumable. POCOX exposes
  no Codex delete; another client's refusal comes from Codex.
- `pocox_codex::rollout` follows `history_base` through active and archived
  sessions, stopping each ancestor at its inherited byte count. Read-only views,
  a fresh fork's list preview, file-link authorization and inline image recovery
  therefore see inherited content, without reading the source's later additions.
  A missing ancestor leaves the fork's own records readable.
- Live views page through `thread/turns/list` and `thread/items/list`, which
  resolve the same chain on the server.

## Verification

`engine::thread_fork_live_tests` is the opt-in acceptance, with real external
processes and a local model endpoint:

```bash
POCOX_TEST_CODEX_BINARY="$(command -v codex)" cargo test -p pocox_bridge --lib \
  --locked thread_fork_live -- --ignored
```

With Codex 0.166.0, one process held a session while a second forked it: the
source's bytes did not change and the holder stayed alive. Model requests showed
the branch keeping the source's context and each side's later turns staying out of
the other. A turn held mid-flight in the other process came through as
`interrupted`, the original then finished, and the branch ran its own turn. A
second host with its own Codex home could not find the session.

A second opt-in test, `a_fork_over_the_relay_runs_on_the_serving_host`, forks
through a real local relay and a separately started `pocox serve`: the session and
its fork were written in that host's Codex home, and nothing on the controller. Its
environment variables are in the test.

`integration_test/fork_remote_test.dart` runs the same path from the real screen on
macOS: the conversation menu, the confirmation, the real bridge and relay, opening
the fork with its inherited conversation, a prompt from the composer, and back to
the source without the fork's turn. It is gated on `--dart-define`s and needs a host
with a local model fixture.

Windows reports no rollout holders, so the check that a host does not keep the
source open does not apply there. Other Codex versions are checked at request
time, not assumed.

The other providers' opt-in acceptance runs the real executables in throwaway homes
against a local model endpoint, whose requests show what each conversation really
carries:

```bash
POCOX_TEST_GROK="$HOME/.grok/bin/grok" cargo test -p pocox-host-svc --test fork_live \
  grok -- --ignored --nocapture
POCOX_TEST_NODE=<node 22+> POCOX_TEST_CLAUDE_ADAPTER=<adapter dist/index.js> \
  POCOX_TEST_CLAUDE_CLI="$(command -v claude)" cargo test -p pocox-host-svc \
  --test fork_live claude -- --ignored --nocapture
POCOX_OPENCODE_BIN="$(command -v opencode)" cargo test -p pocox-host-svc \
  --test opencode_native native_fork -- --ignored --nocapture
```

On one Mac (2026-11-02), with Grok 1.0.70, adapter 0.89.1 with CLI 2.1.316, and
OpenCode 1.19.5:

- Grok and Claude: one host wrote a session while a second, which never loaded it,
  forked it. The source's stored bytes did not change, and its writer kept writing.
  Model requests showed the fork carrying the source's context and each side's later
  turns staying out of the other. The fork opened through its own admission and
  answered. A reply held mid-stream froze as described above and later reached only
  the source. Grok's fork also ran over the real gateway, and through a live, a
  replayed and a reader's turn id.
- OpenCode: the same on one server, plus the refusals: a running turn, an unknown
  message, an assistant message and a held database (an outside process holding it
  open) each created nothing.
- Probes outside the suite added the tool-call cases, and that a second Claude or
  OpenCode writer's process kept running undisturbed.

`acp/host/fork_tests.rs`, the bridge's `a_fork_separates_a_refusal_from_a_lost_answer`
tests and `apps/flutter/test/fork_host_access_test.dart` cover the same rules in the
regular suites.

Not verified: these three through a relay or from a second device (they use the same
gateway routes the real-gateway run did), Grok's fork on a signed-in account, a held
terminal client of Grok or Claude rather than a second host's agent, a real session
over Grok's compaction, the macOS app, and other platforms.
