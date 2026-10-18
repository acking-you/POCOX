part of '../app_session_screen.dart';

// Drafts live for this ProviderScope, including navigation away from the screen.
// Hosts have separate stores; new conversations are also scoped by project.
final _composerDraftsProvider =
    ChangeNotifierProvider.family<_ComposerDrafts, String>(
      (ref, service) => _ComposerDrafts(),
    );

class _ComposerDraft {
  _ComposerDraft(this.threadId, this.project);

  String? threadId;
  String? project;
  bool sendPending = false;

  /// The head of [queue] was refused; the queue sends nothing more until the
  /// user retries or sends another message.
  bool queuePaused = false;

  /// Revision of what may still enter this draft asynchronously (see
  /// [AttachmentTicket]): it moves when the draft's view stops being an
  /// editable view of the same host — it turned read-only, its host
  /// connection was lost or replaced, or image support changed.
  int admission = 0;

  /// An ACP session being opened for this unsent draft ahead of its first
  /// message (see `_ensureAgentSession`). Completes when that attempt ended,
  /// whatever its outcome; only the attempt that set it clears it.
  Future<void>? preparing;

  /// The session opened for this draft and not used yet, valid only for the
  /// host generation [preparedGeneration] it was opened on. The draft keeps
  /// its new-conversation key until its first send adopts the session.
  String? preparedThread;
  int preparedGeneration = 0;

  /// Why the last automatic opening failed, and for which host generation:
  /// it is not retried by itself on that generation.
  ({String message, int generation})? prepareFailure;

  /// Session options chosen for this unsent draft (option id -> value id),
  /// for an engine whose options exist before its session
  /// ([AppCapabilities.draftOptions]). Applied to the session its first send
  /// creates, before that message is sent; nothing is sent for them before.
  final Map<String, String> options = {};

  (String?, String?) get key => (threadId, threadId == null ? project : null);
  TextEditingValue value = TextEditingValue.empty;
  final List<_Attachment> attachments = [];
  final List<_Queued> queue = [];

  /// Built-in tools picked for the next message (`tools/builtin_tools.dart`).
  final List<String> tools = [];

  bool get hasDraft => value.text.isNotEmpty || attachments.isNotEmpty;

  /// Moves when text joins this draft from outside its view (see
  /// [addToConversationDraft]); an open view shows the draft again.
  int outside = 0;
}

/// Hand [text] to conversation [threadId] on [service]: it joins that
/// conversation's draft as a paragraph of its own and is never sent. An open
/// view of the conversation shows it at once.
void addToConversationDraft(
  WidgetRef ref,
  String service,
  String threadId,
  String text,
) {
  final drafts = ref.read(_composerDraftsProvider(service));
  final draft = drafts.forThread(threadId);
  final previous = draft.value.text;
  final combined = previous.trim().isEmpty ? text : '$previous\n\n$text';
  draft.value = TextEditingValue(
    text: combined,
    selection: TextSelection.collapsed(offset: combined.length),
  );
  draft.outside += 1;
  drafts.save(draft, changed: true);
}

class _ComposerDrafts extends ChangeNotifier {
  final Map<(String?, String?), _ComposerDraft> _drafts = {};
  final Set<(String?, String?)> _badges = {};
  int nextAttachmentId = 0;
  int nextQueueId = 0;
  bool _disposed = false;

  // Keep even empty drafts stable while a picker or clipboard read is pending.
  _ComposerDraft forThread(String? id, {String? cwd}) {
    final project = cwd == null || cwd.trim().isEmpty ? null : cwd;
    final key = (id, id == null ? project : null);
    return _drafts.putIfAbsent(key, () => _ComposerDraft(id, project));
  }

  // Default discovery must keep pending pickers attached to the same draft.
  // An existing project draft wins; leave the unassigned draft reachable.
  _ComposerDraft? resolveProject(_ComposerDraft draft, String project) {
    final target = _drafts[(null, project)];
    if (target != null && !identical(target, draft)) {
      return draft.hasDraft || draft.queue.isNotEmpty ? null : target;
    }
    _drafts.remove(draft.key);
    _badges.remove(draft.key);
    // A session opened ahead runs in the old project; its cwd cannot move.
    if (draft.project != project) {
      draft.preparedThread = null;
      draft.prepareFailure = null;
    }
    draft.project = project;
    _drafts[draft.key] = draft;
    if (draft.hasDraft) _badges.add(draft.key);
    return draft;
  }

  Iterable<String> get projects => _drafts.keys
      .where((key) => key.$1 == null && key.$2 != null)
      .map((key) => key.$2!);

  bool hasDraft(String id) => _badges.contains((id, null));

  int queuedCount(String id) => _drafts[(id, null)]?.queue.length ?? 0;

  void save(_ComposerDraft draft, {bool changed = false}) {
    if (_disposed) return;
    final id = draft.key;
    _drafts[draft.key] = draft;
    final badgeChanged = draft.hasDraft ? _badges.add(id) : _badges.remove(id);
    // Keystrokes update the value without rebuilding the transcript.
    if (changed || badgeChanged) notifyListeners();
  }

  void adoptThread(_ComposerDraft draft, String id) {
    _drafts.remove(draft.key);
    _badges.remove(draft.key);
    draft.threadId = id;
    draft.preparedThread = null;
    draft.prepareFailure = null;
    save(draft, changed: true);
  }

  /// Sessions opened ahead for unsent drafts: they belong to those drafts'
  /// own views, not to the conversation list.
  Set<String> get preparedIds => {
    for (final draft in _drafts.values)
      if (draft.threadId == null && draft.preparedThread != null)
        draft.preparedThread!,
  };

  /// The host behind every draft of this service changed (connection lost
  /// or replaced, capabilities changed): attachments still being picked,
  /// read or uploaded were granted for a host that is gone.
  void revokeAdmissions() {
    for (final draft in _drafts.values) {
      draft.admission++;
    }
  }

  void attachmentChanged(_Attachment attachment) {
    if (_disposed) return;
    if (containsAttachment(attachment)) {
      notifyListeners();
    }
  }

  bool containsAttachment(_Attachment attachment) =>
      !_disposed &&
      _drafts.values.any((d) => d.attachments.contains(attachment));

  @override
  void dispose() {
    _disposed = true;
    _drafts.clear();
    super.dispose();
  }
}
