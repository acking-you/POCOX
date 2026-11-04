# Forking conversations

**Fork conversation** creates a new, persistent conversation that inherits a
source's context and then goes its own way. It works on an ordinary conversation
and on one another process holds: forking only reads the source, so it never
evicts or signals a writer, resumes the source, answers its approvals or sends a
prompt. Drafts, attachments and queued messages stay with the source.

It is available for Codex, through the installed app-server's own `thread/fork`.
Claude, Grok and OpenCode report no fork capability and offer nothing yet; a
rendered transcript is never replayed as if it were model context.

## Where it is offered

| Place | Action | Boundary |
| --- | --- | --- |
| Conversation menu on a computer, context sheet on a phone | **Fork conversation** | the source's latest saved state |
| Read-only footer of a held conversation | **Fork**, beside the existing takeover or read-only state | the source's latest saved state |
| Session viewer (`/sessions/view`) | **Fork**, beside resume or the read-only state | the source's latest saved state |
| Any message of a finished turn, the user's or the agent's (hover on desktop, long press on touch) | **Fork through this turn** | the whole turn, inclusive |

Codex forks at turn boundaries, so every message of a turn offers the same one. A
turn offers itself only with a real host turn id once it has ended, so a running
turn or cached history has no action. An older host records no completion time;
with nothing running, every turn it lists has ended.
A Guardian review forks nowhere: the view hides the action, and the bridge refuses
before sending anything, because Codex itself would accept it.

A confirmation states the boundary and that both conversations share a working
folder, so a fork isolates history, not files. While the request is out the context
card and sheet say so, as do a phone's top bar and the status line, and the action
is not offered again. Once in the fork, the card and sheet lead with a row back to
the source, and the status line carries a mark for it where no card stands. That
link is `forkedFromId`, read from `thread/read` and kept apart
from `parentThreadId`: a fork is its own conversation, not a spawned agent, and
never nests under its source.

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
  result after the host connection moved is not adopted.
- **Failure never falls back** to takeover or to resuming the original.

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
  a fresh fork's list preview and file-link authorization therefore see inherited
  content. A missing ancestor leaves the fork's own records readable.
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
