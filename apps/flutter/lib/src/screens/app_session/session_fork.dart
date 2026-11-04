part of '../app_session_screen.dart';

class _ForkState {
  /// The conversation the open one branched from; never a spawning parent.
  String? source;

  /// A request awaits its answer, wherever the reader has gone since. It blocks
  /// a second one: an unanswered request may still create a session.
  bool pending = false;
}

extension _SessionFork on _AppSessionState {
  /// Whether the host can be asked at all: a Guardian review stays read-only,
  /// an unconnected host has nothing to ask, and one that says this session
  /// cannot be written or is gone has nothing to branch.
  bool get _forkReachable =>
      _caps.fork &&
      _threadId != null &&
      !_guardianReadOnly &&
      !_connectionLost &&
      !_reconnecting &&
      !(_caps.hostAccess &&
          _externalWriterMode &&
          const {
            'not_found',
            'host_stopped',
            'unsupported',
          }.contains(_accessReason));

  /// Another process holds this host-access session, or the host cannot rule
  /// that out. Handed back or never opened here, nobody else is known to.
  bool get _forkSourceHeld =>
      _caps.hostAccess &&
      _externalWriterMode &&
      !const {
        'owned',
        'released',
        'released_here',
        'not_opened',
      }.contains(_accessReason);

  /// Whether this conversation can branch. Reading it is enough where the
  /// provider takes a snapshot of a source that is held or changing; where it
  /// does not, that waits.
  bool get _canFork =>
      _forkReachable &&
      (_caps.forkBusySource || !(_streaming || _forkSourceHeld));

  /// The action for a finished turn's reply: the boundary needs the turn's
  /// real id from the host, so cached or still-syncing history offers nothing.
  /// A finished turn stays a boundary while a later one runs.
  VoidCallback? _forkTurnAction(TranscriptItem item) {
    if (!_canForkThrough(item)) return null;
    return () => unawaited(_forkConversation(throughTurnId: item.turnId));
  }

  bool _canForkThrough(TranscriptItem item) {
    if (!_forkReachable ||
        !_caps.forkThroughTurn ||
        (!_caps.forkBusySource && _forkSourceHeld) ||
        _historySyncing ||
        _showingCachedHistory ||
        item.type != 'agentMessage' ||
        item.turnId.isEmpty ||
        !_forkTurnEnded(item)) {
      return false;
    }
    return true;
  }

  bool _forkAllowed(String? throughTurnId) => throughTurnId == null
      ? _canFork
      : _items.any(
          (item) => item.turnId == throughTurnId && _canForkThrough(item),
        );

  /// Whether [item]'s turn is over. An ACP agent stamps no completion time, so
  /// every turn but the running one is; following another writer, the newest
  /// may still run there unless the host says otherwise. The host checks again.
  bool _forkTurnEnded(TranscriptItem item) {
    if (item.turnCompletedAt != null) return true;
    if (!_caps.hostAccess || item.streaming) return false;
    if (_streaming && (_turnId == null || _turnId == item.turnId)) return false;
    if (!_externalWriterMode || _access?.turn == 'idle') return true;
    final newest = _items.lastWhere(
      (it) => it.turnId.isNotEmpty,
      orElse: () => item,
    );
    return newest.turnId != item.turnId;
  }

  /// Branch the open conversation, then open the new one if this view is still
  /// where the request began. The source is only read: its writer, drafts,
  /// attachments and queue stay as they are, and nothing is sent.
  Future<void> _forkConversation({String? throughTurnId}) async {
    final source = _threadId;
    if (source == null || !_forkAllowed(throughTurnId) || _fork.pending) return;
    final service = widget.serviceKey;
    final link = _linkEpoch;
    final generation = _threadLoadGeneration;
    bool sameLink() => service == widget.serviceKey && link == _linkEpoch;
    final confirmed = await confirmFork(
      context,
      throughTurn: throughTurnId != null,
      running:
          _streaming || _externalWriterRunning || (_access?.running ?? false),
    );
    if (!confirmed ||
        !mounted ||
        _fork.pending ||
        !sameLink() ||
        generation != _threadLoadGeneration ||
        _threadId != source ||
        !_forkAllowed(throughTurnId)) {
      return;
    }

    final l10n = AppLocalizations.of(context);
    final messenger = ToastMessenger.of(context);
    final api = ref.read(bridgeApiProvider);

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
    // A host-access provider restores what it keeps itself; only Codex keeps
    // per-thread settings with the host.
    if (!_caps.hostAccess) {
      await copyForkSettings(api, service, source: source, fork: thread.id);
    }
    if (!mounted) return;
    if (!sameLink()) {
      _updateState(() => _fork.pending = false);
      messenger.notice(l10n.forkHostChanged);
      return;
    }
    _updateState(() {
      _fork.pending = false;
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
  Widget _forkFootButton(AppLocalizations l10n) => SizedBox(
    height: 42,
    child: TextButton.icon(
      key: const Key('chat-fork-action'),
      onPressed: _fork.pending || _takingOver
          ? null
          : () => unawaited(_forkConversation()),
      icon: _fork.pending
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(AppIcons.account_tree_outlined, size: 18),
      label: Text(l10n.forkConfirm),
    ),
  );

  /// Marks a forked conversation in the status line and leads to its source.
  Widget _forkSourceMark(AppLocalizations l10n, String source) {
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
    return IconButton(
      key: const Key('fork-source-mark'),
      tooltip: name.isEmpty ? l10n.forkedFromUnknown : l10n.forkedFrom(name),
      onPressed: () => _openThread(source, known?.cwd ?? _cwd),
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
