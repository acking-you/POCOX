part of '../app_session_screen.dart';

class _ForkState {
  /// The conversation the open one branched from; never a spawning parent.
  String? source;

  /// A request awaits its answer, wherever the reader has gone since. It blocks
  /// a second one: an unanswered request may still create a session.
  bool pending = false;

  /// What the host says each conversation branched from, null for none.
  /// `thread/list` names no source, only `thread/read` does, and a source never
  /// changes, so each conversation is asked once.
  final Map<String, String?> origins = {};

  /// A sweep of [origins] is under way.
  bool sweeping = false;
}

/// How many of the newest conversations are asked for their source, and how
/// many at once: each is a small read, but over a relay tunnel they add up. An
/// older fork is still marked once it is opened.
const int _forkSweepLimit = 200;
const int _forkSweepWorkers = 4;

extension _SessionFork on _AppSessionState {
  /// Whether this conversation can branch. Reading it is enough: a held source
  /// forks just as an ordinary one does, while a Guardian review stays
  /// read-only and an unconnected host has nothing to ask.
  bool get _canFork =>
      _caps.fork &&
      _threadId != null &&
      !_guardianReadOnly &&
      !_connectionLost &&
      !_reconnecting;

  /// The action for a message of a finished turn, the user's or the agent's:
  /// the boundary is the whole turn. It needs the turn's real id from the host,
  /// so cached or still-syncing history offers nothing.
  VoidCallback? _forkTurnAction(TranscriptItem item) {
    if (!_canFork ||
        _historySyncing ||
        _showingCachedHistory ||
        (item.type != 'agentMessage' && item.type != 'userMessage') ||
        item.turnId.isEmpty ||
        !_turnFinished(item)) {
      return null;
    }
    return () => unawaited(_forkConversation(throughTurnId: item.turnId));
  }

  /// Whether [item]'s turn has ended. An older host records no completion time,
  /// but with nothing running every turn it has listed is over. A running turn
  /// cannot be a boundary: Codex refuses it.
  bool _turnFinished(TranscriptItem item) {
    if (item.turnCompletedAt != null) return true;
    if (!_streaming && !_externalWriterRunning) return true;
    return _items.any(
      (other) => other.turnId == item.turnId && other.turnCompletedAt != null,
    );
  }

  /// The conversation [thread] branched from, once the host has said.
  String? _originOf(ThreadMeta thread) =>
      thread.forkedFromId ?? _fork.origins[thread.id];

  /// Ask the host which of [listed] are forks, so the list can show each under
  /// its source. A failed read ends the sweep; the next listing asks again.
  Future<void> _readForkOrigins(List<ThreadMeta> listed) async {
    if (!_caps.fork || !_caps.nativeMetadata || _fork.sweeping) return;
    final queue = [
      for (final thread in listed.take(_forkSweepLimit))
        if (thread.forkedFromId == null &&
            !_fork.origins.containsKey(thread.id))
          thread.id,
    ];
    if (queue.isEmpty) return;
    final api = ref.read(bridgeApiProvider);
    final service = widget.serviceKey;
    final link = _linkEpoch;
    bool current() =>
        mounted && service == widget.serviceKey && link == _linkEpoch;
    var found = false;
    Future<void> worker() async {
      while (queue.isNotEmpty && current()) {
        final id = queue.removeLast();
        try {
          final origin = (await api.appThreadMetadata(
            service,
            id,
          ))?.forkedFromId;
          _fork.origins[id] = origin;
          found = found || origin != null;
        } catch (_) {
          queue.clear();
        }
      }
    }

    _fork.sweeping = true;
    try {
      await Future.wait([for (var i = 0; i < _forkSweepWorkers; i++) worker()]);
    } finally {
      _fork.sweeping = false;
    }
    if (found && mounted) _updateState(() {});
  }

  /// A conversation's forks, newest first.
  List<ThreadMeta> _forksOf(String source) {
    final known = {
      for (final thread in _discoveredThreads.values) thread.id: thread,
      for (final thread in _threads) thread.id: thread,
    };
    return [
      for (final thread in known.values)
        if (_originOf(thread) == source) thread,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  /// Branch the open conversation, then open the new one if this view is still
  /// where the request began. The source is only read: its writer, drafts,
  /// attachments and queue stay as they are, and nothing is sent.
  Future<void> _forkConversation({String? throughTurnId}) async {
    final source = _threadId;
    if (source == null || !_canFork || _fork.pending) return;
    final confirmed = await confirmFork(
      context,
      throughTurn: throughTurnId != null,
      running: _streaming || _externalWriterRunning,
    );
    if (!confirmed || !mounted || _fork.pending || _threadId != source) return;

    final l10n = AppLocalizations.of(context);
    final messenger = ToastMessenger.of(context);
    final api = ref.read(bridgeApiProvider);
    final service = widget.serviceKey;
    final link = _linkEpoch;
    final generation = _threadLoadGeneration;
    bool sameLink() => service == widget.serviceKey && link == _linkEpoch;

    _updateState(() => _fork.pending = true);
    final ThreadForkResult result;
    try {
      result = await api.appThreadFork(
        service,
        source,
        throughTurnId: throughTurnId,
      );
    } catch (error) {
      if (mounted) _updateState(() => _fork.pending = false);
      messenger.error('${l10n.forkFailed}: ${friendlyError(error)}');
      return;
    }
    final thread = result.thread;
    if (thread == null) {
      if (mounted) {
        _updateState(() => _fork.pending = false);
        if (sameLink()) _loadThreads();
      }
      messenger.error(l10n.forkOutcomeUnknown);
      return;
    }
    // Nothing adopts a session created through a connection that moved since.
    if (!mounted || !sameLink()) {
      if (mounted) _updateState(() => _fork.pending = false);
      messenger.notice(l10n.forkHostChanged);
      return;
    }
    await copyForkSettings(api, service, source: source, fork: thread.id);
    if (!mounted) return;
    if (!sameLink()) {
      _updateState(() => _fork.pending = false);
      messenger.notice(l10n.forkHostChanged);
      return;
    }
    _updateState(() {
      _fork.pending = false;
      _fork.origins[thread.id] = source;
      // The host lists a fork only once it has a turn of its own.
      _discoveredThreads[thread.id] = thread;
      if (!_threads.any((known) => known.id == thread.id)) {
        _threads = [thread, ..._threads];
      }
    });
    _loadThreads();
    if (!result.boundaryConfirmed) {
      messenger.error(l10n.forkBoundaryUnconfirmed);
    } else if (_threadId == source && generation == _threadLoadGeneration) {
      messenger.notice(forkCreatedMessage(l10n, result));
      _openThread(thread.id, thread.cwd.isEmpty ? _cwd : thread.cwd);
    } else {
      // The reader moved on while this ran; a late result never moves them.
      messenger.offer(
        forkCreatedMessage(l10n, result),
        action: l10n.forkReadyOpen,
        onAction: () {
          if (mounted && sameLink()) _openThread(thread.id, thread.cwd);
        },
      );
    }
  }

  /// The read-only footer's way to keep working from this conversation.
  Widget _forkFootButton(AppLocalizations l10n) => ReadOnlyFootAction(
    key: const Key('chat-fork-action'),
    icon: AppIcons.account_tree_outlined,
    label: l10n.forkConfirm,
    busy: _fork.pending,
    onPressed: _fork.pending || _takingOver || !_canFork
        ? null
        : () => unawaited(_forkConversation()),
  );

  /// What a fork's source is called, and the way back to it.
  ({String label, VoidCallback open}) _forkOrigin(
    AppLocalizations l10n,
    String source,
  ) {
    final known =
        _threads.where((thread) => thread.id == source).firstOrNull ??
        _discoveredThreads[source];
    final name =
        known?.title ??
        (known == null
            ? ''
            : previewWithoutFileRefs(
                known.preview,
                l10n.fileOnlyMessage,
              ).trim().split('\n').first.trim());
    return (
      label: name.isEmpty ? l10n.forkedFromUnknown : l10n.forkedFrom(name),
      open: () => _openThread(source, known?.cwd ?? _cwd),
    );
  }

  /// The mark a fork carries wherever it is named: a glyph on a plate, read at
  /// a glance where a word in a row's small print was not.
  Widget _forkBadge(AppLocalizations l10n, {Key? key, double size = 18}) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: l10n.forkedTag,
      child: Semantics(
        label: l10n.forkedTag,
        child: Container(
          key: key,
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: softWash(scheme, strength: 1.6),
            shape: BoxShape.circle,
          ),
          child: Icon(
            AppIcons.account_tree_outlined,
            size: size * 0.67,
            color: scheme.onSurface,
          ),
        ),
      ),
    );
  }

  /// [name] behind the mark when [thread] is a fork.
  Widget _withForkBadge(
    ThreadMeta thread,
    Widget name,
    AppLocalizations l10n,
  ) => _originOf(thread) == null
      ? name
      : Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _forkBadge(l10n, key: Key('fork-mark-${thread.id}'), size: 17),
            const SizedBox(width: 6),
            Flexible(child: name),
          ],
        );

  /// The title strip's way back to a fork's source.
  Widget _stripForkOrigin(AppLocalizations l10n, String source) {
    final scheme = Theme.of(context).colorScheme;
    final origin = _forkOrigin(l10n, source);
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 8),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const Key('strip-fork-source'),
          mouseCursor: clickable,
          borderRadius: BorderRadius.circular(kControlRadius),
          hoverColor: softWash(scheme),
          onTap: origin.open,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Text(
              origin.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      ),
    );
  }

  /// What heads a fork's transcript in place of "start of conversation": where
  /// the history above its own turns came from.
  Widget _forkHistoryHead(AppLocalizations l10n, String source) {
    final scheme = Theme.of(context).colorScheme;
    final origin = _forkOrigin(l10n, source);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: TextButton.icon(
        key: const Key('history-fork-source'),
        style: TextButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
          textStyle: Theme.of(context).textTheme.bodySmall,
        ),
        onPressed: origin.open,
        icon: const Icon(AppIcons.account_tree_outlined, size: 14),
        label: Text(origin.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  /// Marks a forked conversation in the status line, where no card says so, and
  /// leads to its source.
  Widget _forkSourceMark(AppLocalizations l10n, String source) {
    final origin = _forkOrigin(l10n, source);
    return IconButton(
      key: const Key('fork-source-mark'),
      tooltip: origin.label,
      onPressed: origin.open,
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        minimumSize: const Size(22, 22),
        fixedSize: const Size(22, 22),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(
        AppIcons.account_tree_outlined,
        size: 13,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
