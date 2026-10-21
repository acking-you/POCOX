part of '../app_session_screen.dart';

/// One composer attachment. An IMAGE is processed locally (EXIF-bake /
/// downscale / re-encode on the Rust CPU queue) and travels inline as a
/// data URL; a FILE is uploaded to the HOST over the meta tunnel and travels
/// as a path reference in the turn text (codex's native document workflow —
/// its input protocol has no document slot). Either kind shows a spinner chip
/// until [ready].
class _Attachment {
  _Attachment.image({required this.id, required this.name}) : isFile = false;
  _Attachment.file({required this.id, required this.name}) : isFile = true;
  final int id;
  final String name;
  final bool isFile;
  ProcessedImage?
  processed; // image: null while native preparation is still working
  String? hostPath; // file: null while the upload is still in flight
  XFile? source;
  Uint8List? sourceBytes;
  String? error;

  /// The draft it was admitted into and the admission it holds; an upload
  /// re-checks it after reading the file (see [AttachmentTicket]).
  _ComposerDraft? draft;
  AttachmentTicket? ticket;

  /// Whether this attachment is sendable.
  bool get ready =>
      error == null && (isFile ? hostPath != null : processed != null);
}

/// A message the user composed while a turn was already running. It isn't sent
/// immediately — it waits in [_AppSessionState._queue] and fires as its own turn
/// once the running (and any earlier queued) turns finish (codex-cli parity).
/// The composer draft is snapshotted whole (text + its ready attachments) so the
/// entry can be sent verbatim later, or handed back to the composer on Esc.
class _Queued {
  _Queued({
    required this.id,
    required this.text,
    required this.attachments,
    this.tools = const [],
  });
  final int id;
  final String text; // the raw composer text, as typed
  final List<_Attachment> attachments;

  /// Built-in tools picked for it.
  final List<String> tools;

  /// Being sent: it stays first in the queue until the host admits it, so a
  /// refusal keeps its place; meanwhile it cannot be dequeued or discarded.
  late final ComposerControl control;
  bool get inFlight => control.state.byId[id]?.inFlight ?? false;
  set inFlight(bool value) => control.apply(
    value ? ComposerAction.beginQueued : ComposerAction.endQueued,
    id: id,
  );

  /// Its send failed in a way that leaves open whether the host admitted
  /// it (the request or its answer was lost). It stays first, the queue
  /// holds behind it, and it is never sent again by itself — not after a
  /// reload, reconnect or turn end: only the user's explicit Retry sends it
  /// again (see `_resendUncertain`); the user may also edit (tap) or remove
  /// it.
  bool get uncertain => control.state.byId[id]?.uncertain ?? false;
  void fail({required bool uncertain}) => control.apply(
    uncertain ? ComposerAction.unknown : ComposerAction.refused,
    id: id,
  );
  void retryUnknown() => control.apply(ComposerAction.retryUnknown, id: id);

  /// Why its last send failed, while it is held at the head of a paused
  /// queue: the Retry its banner offered is offered again after a reload,
  /// reconnect or reopening cleared that banner (see `_offerHeldQueue`).
  String? failure;

  /// One-line preview for the queued-messages strip.
  String get preview {
    final t = text.trim();
    if (t.isNotEmpty) return t;
    return attachments.isEmpty ? '' : attachments.first.name;
  }
}

/// One admitted turn whose `turn/started` has not arrived (see
/// `_AppSessionState._awaitedStart`): the draft and thread it was sent from.
/// The instance itself is the admission's token.
class _AwaitedStart {
  _AwaitedStart({
    required this.draft,
    required this.threadId,
    required this.clientId,
  });
  final _ComposerDraft draft;
  final String threadId;

  /// The sent message's client id: only the start that names it (or one
  /// from a host that names no sender) is this admission's.
  final String clientId;
}

/// The host connection a send began on was lost or replaced before the send
/// completed (see `_AppSessionState._linkEpoch`).
class _LinkMoved implements Exception {
  const _LinkMoved();
}

/// The host refused a draft's option choice before its first message was
/// sent (see `_applyDraftOptions`): nothing of the message reached the host.
class _DraftOptionsRefused implements Exception {
  const _DraftOptionsRefused(this.message);

  /// Why, safe to show.
  final String message;
}

/// The picked model is not in the current host's model list (the host was
/// replaced with another configuration): checked before anything of the
/// message is sent, so it is handled like a refused draft option.
class _ModelWithdrawn extends _DraftOptionsRefused {
  const _ModelWithdrawn(super.message);
}

/// The exact wire content of one send (text with file references, image
/// data URLs), kept by its retry.
class _Resend {
  const _Resend({required this.text, required this.images, this.clientId});
  final String text;
  final List<String> images;

  /// The client id its first send gave it, so a retry shows in that copy;
  /// null for a message not sent yet (it gets a new one).
  final String? clientId;
}

/// One entry in an option-picker bottom sheet (model / permission / effort).
class _PickerOption<T> {
  const _PickerOption({
    required this.value,
    required this.icon,
    required this.label,
    this.description,
  });
  final T value;
  final IconData icon;
  final String label;
  final String? description;
}

/// Esc while renaming: leave the title edit without committing.
class _CancelTitleEditIntent extends Intent {
  const _CancelTitleEditIntent();
}

/// What an agent option change applies to: the service, conversation and the
/// load, capability and connection generations it was offered under.
typedef _AgentTarget = ({
  String service,
  String thread,
  int load,
  int caps,
  int link,
});
