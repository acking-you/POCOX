# Composer, drafts and turns

This document holds the controller-side rules (Flutter and the bridge) for
drafts, sending, queueing, supplements and retries that every engine shares.
The composer and its state machine live in
`apps/flutter/lib/src/screens/app_session/` (`session_composer.dart`,
`composer_drafts.dart`, `session_send.dart`, `session_queue.dart`,
`session_supplement.dart`, `attachment_gate.dart`, `expanded_composer.dart`,
`message_editor.dart`, `session_draft_options.dart`); permission presets are
in `apps/flutter/lib/src/app_modes.dart`; the native composer controller is
`crates/pocox-bridge/src/api/bridge/composer.rs` (Dart side
`lib/src/composer_control.dart`, `lib/src/bridge/rust_composer.dart`).
Engine wire details stay in [ACP agents](acp-agents.md#turns-and-permissions),
[Native OpenCode](opencode-native.md#sending) and
[Grok Build](grok-build.md#supplements); layout and styling are in
[Flutter app UI](app-ui.md).

## Composer

- Compact by default; resizable with mouse, touch and accessibility actions.
  Its minimum height persists with the UI preferences (`composerHeight`,
  `lib/src/ui_prefs.dart`) and has an explicit reset.
- It grows and shrinks with wrapped text up to the viewport cap, then scrolls
  internally. Automatic sizing never overwrites the saved minimum.
- Mobile Return inserts a newline. Desktop Enter sends and Shift+Enter inserts
  a newline. IME composition never submits.
- Queue and Stop are separate controls.
- The expanded editor shares the draft and returns focus and selection to the
  compact input. It previews the draft live as Markdown (beside the source
  from 900 px, a tab away below) and never sends.
- New-conversation views focus the project and the input.
- Composer dictation types at the cursor and never sends:
  [live voice](live-voice.md#composer-dictation).

## Drafts

- Draft text, selection, attachments and pending queues are scoped to the host
  and conversation (host and project before the first send) for the app
  session, and survive navigation.
- The sidebar marks conversations with a draft or queued messages
  (`session_conversations.dart`).
- A queue resumes when its conversation is active. Queue draining preserves
  newer drafts: a queued send never replaces what is in the composer.
- An upload completing after navigation updates its original draft.
- Editable conversations can reuse a user message in a separate editor
  (`message_editor.dart`). Adding it preserves the draft's existing text and
  attachments, never sends automatically and never rewrites history.
  Read-only views expose no edit action.

## Turn modes and options

- New conversations default to `approvalsReviewer: auto_review` with
  on-request approval and the workspace sandbox (`PermissionMode.autoReview`).
  Manual, read-only and full-access presets remain; the persisted `auto` tag
  keeps its manual-review meaning.
- Offer Fast only when the model catalog advertises support, and explicitly
  send `default` when switching it off.
- While an option change of the shown conversation is being saved, every send
  path (button, Enter, queue, supplement, Retry) and that conversation's
  options wait. The draft stays, and nothing is sent automatically when the
  save ends. A save of a conversation left meanwhile neither holds nor
  releases the one shown now.

## New conversations and draft sessions

- A new ACP or OpenCode conversation needs a project folder. A send without
  one opens the folder picker and sends nothing (no optimistic copy). Codex
  may still work outside a project.
- A server thread or session is created only for a draft that is sent: Codex
  and native OpenCode create it on the first send. ACP agents with a project
  prepare their session ahead without sending, one attempt per draft, and the
  first send waits for that same attempt
  ([model, effort and mode](acp-agents.md#model-effort-and-mode)).
- A session that could not be created returns its message to the composer.
- Draft model/agent/variant choices stay on the draft. An ACP draft reads its
  cached draft settings with an empty thread id; OpenCode reads its project's
  defaults asynchronously through `app_draft_session_settings`
  ([draft options](opencode-native.md#draft-options)).
- Draft choices are applied to the created session before the message is
  sent. They never mutate host-wide defaults, and a config change is never
  sent with an empty id.

## Queue and Supplement

- A composer send while a turn runs queues for a new turn by default.
- The optional Supplement control adds input to the running turn: Codex uses
  `turn/steer` with the expected turn id and retains the draft on rejection.
  Other engines offer it only when their capability is negotiated; their
  outcome mapping is in the engine docs linked above.
- A supplement outcome is one of: added to the expected turn, made the next
  queued turn (only the exactly unchanged input; changed input stays in the
  composer), or unknown. An unknown outcome is reported and never retried or
  turned into a prompt.
- Before any draft, attachment or queue change, a supplement answer must still
  own its input: the same service, host connection and generation,
  conversation view, draft and request. Leaving the conversation drops the
  request, so returning to the same session does not revive it.
- An answer that no longer owns its input leaves the draft, its attachments,
  the queue and any newer request's mode, notice, Retry and lock untouched,
  and sends nothing. Only when nothing newer owns the same view does it show
  a notice; an added input then gets a display-only refresh that keeps the
  notice, settles no admission and drains nothing.
- An owned answer takes exactly its sent snapshot out of the draft (edits and
  attachments added since stay). After a history load since the request, the
  host's history shows the input instead of a local copy.

## Admission and turn end

- An admitted turn holds the queue until its `turn/started` arrives. If none
  arrives within 20 s (`_turnStartGrace`), the conversation is reloaded and
  only the host's history may release it, as running or ended. Elapsed time
  alone never releases it.
- The wait is owned by its admission token (draft, thread). Only an
  authoritative history reload of that conversation, from the current host
  connection and begun after the admission, settles it.
- Failed, cached, display-only, obsolete or overtaken reloads release nothing,
  and neither does a read answered after its connection was lost or replaced
  (the screen's link epoch, which a capability re-read does not move). The
  reconciliation retries, and the reconnect's own reload answers instead.
- A turn's end releases every control it gated in the same session: the bridge
  clears a cached `runningTurnId` that still names the ended turn, and the
  screen re-reads agent settings.
- A repeated end of an already-ended turn is ignored. A stale end (an older
  turn's end after a newer start) never clears the running turn.

## Failures and Retry

- A message ID or client id is not an idempotency key. No protocol gives the
  host a request identity to deduplicate by, and history is bounded and
  shared with other writers, so no history answer proves whether a send
  arrived.
- Only the host's listed pre-admission refusals, or a failure before the turn
  request was sent, are definite; those are retried as they are.
- Any other failure is uncertain. The message stays queued and marked, and is
  sent again only by the user's explicit Retry; it can still be edited or
  removed. Delivery is at most once without user action, not exactly once.
- A failed queued message keeps its text and attachments, first in its paused
  queue. Its Retry is offered again after a reload, reconnect or reopening.
- Every retry re-sends its own captured content. The native duplicate check is
  bound to its thread and connection; a missing match is never proof that the
  earlier request did not arrive.
- Engine-specific failure cards and Retry eligibility (for example OpenCode's
  model failures) are in the engine docs.

## Ownership of a send

- Every step of a send (model list, session start, turn dispatch, answer)
  belongs to the service and connection it began on. Nothing is dispatched on
  a moved connection.
- An answer arriving after the connection moved adopts nothing: an ordinary
  message returns to its draft with the reason (not sent, or unknown whether
  it arrived); a queued one stays queued as refused or uncertain.
- A session created for a draft is still adopted by that draft after
  navigation.
- Each send releases only its own composer lock.

## Attachments

- Prepared images also have a best-effort host copy under
  `<session cwd>/.pocket-attachments/<upload id>/<filename>`. A new draft uses
  its selected project (within the host's configured roots), or the host's
  validated default when none is selected. Existing sessions use the host's
  verified cwd, including sessions outside the browse roots. Missing projects
  and redirected attachment directories fail without writing elsewhere.
- Picker paths, drop, platform URIs and clipboard bytes share this pipeline.
  Capture the account/relay context before reading or processing; recheck the
  original draft's admission before uploading. Send, Queue and Supplement wait
  for the mirror. Upload failure preserves inline images, shows a retryable
  warning, and allows sending without a host path; retrying just the mirror
  does not decode the image again.
- The additive `POST /uploads/images/{name}?thread=...` route resolves an
  existing session; `?project=...` selects a new draft's directory. Omit both
  to prepare the default. The legacy `/uploads/{name}` route retains its
  configured uploads directory for every filename. Older hosts without the new
  route keep inline-image sending, with the mirror warning.
- The prompt carries the host paths in an `Attached images` block and refers
  to available image tools, without assuming a particular skill is installed.
  This does not add model vision or bypass negotiated image-input capabilities.
  Live and read-only transcripts hide the block and avoid duplicate chips
  beside inline thumbnails; path-only history retains explicit file actions.

- Failed attachments stay removable and retryable and block sending until
  resolved, except the optional image mirror described above.
- Picker, drop and paste pass one admission boundary (`AttachmentGate`,
  `attachment_gate.dart`), gated on negotiated capabilities. A late result
  (picker, clipboard, file read before upload) is re-admitted through its
  `AttachmentTicket` against the original draft's admission revision, which
  moves when that view turns read-only, its host is lost or replaced, or
  image support goes away.

## Native composer controller

Queue identity and order, the exclusive send lease, paused and unknown
outcomes, and attachment admission generations are owned in Rust; Flutter
keeps the editable text, attachment previews, IME state and lifecycle
orchestration. Only explicit Retry permits an unknown send again. Limits and
details: [Rust offload › Session ownership](rust-offload.md#session-ownership).
