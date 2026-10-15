part of '../app_session_screen.dart';

extension _SessionExternalWriter on _AppSessionState {
  bool _isActiveWriterError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('active writer') ||
        message.contains('native history is read-only');
  }

  void _cancelExternalWriterSubscription() {
    _externalHistoryTimer?.cancel();
    _externalHistoryTimer = null;
    _accessTimer?.cancel();
    _accessTimer = null;
    _accessChecking = false;
    _accessCheckAsked = false;
    _externalHistoryRevision = null;
    _externalHistoryLoading = false;
    _externalHistoryDirty = false;
    _externalWriterLegacy = false;
    _externalWriterReconnect?.cancel();
    _externalWriterReconnect = null;
    final sub = _externalWriterSub;
    _externalWriterSub = null;
    if (sub != null) unawaited(sub.cancel());
    if (_externalWriterMode) {
      _elapsedTicker?.cancel();
      _elapsedTicker = null;
      _turnStartedAt = null;
    }
    _externalWriterEpoch++;
  }

  /// Show [threadId] read-only. [follow] keeps its transcript live through
  /// the host meta stream; without it (a blocked session) history is read
  /// once.
  void _enterExternalWriterMode(String threadId, {bool follow = true}) {
    _cancelExternalWriterSubscription();
    // Read-only from now on (another writer, or a Guardian reviewer):
    // attachments still being picked or read for this view are refused.
    _revokeOnScreenAdmissions();
    final epoch = _externalWriterEpoch;
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
    _turnStartedAt = null;
    _updateState(() {
      _externalWriterMode = true;
      _externalWriterLiveness = null;
      _takingOver = false;
      _loading = _items.isEmpty;
      _historySyncing = true;
      _streaming = false;
      _elapsedSecs = 0;
      _error = null;
      _retry = null;
      _approvals.clear();
      _asyncQuestions.clear();
    });
    _loadGit();
    if (follow) _subscribeExternalWriter(threadId, epoch);
    // Read-only history does not need to wait for the slower ownership probe.
    _scheduleExternalHistory(threadId, epoch);
  }

  void _subscribeExternalWriter(String threadId, int epoch) {
    if (!mounted ||
        !_externalWriterMode ||
        _threadId != threadId ||
        epoch != _externalWriterEpoch) {
      return;
    }
    _externalWriterReconnect?.cancel();
    _externalWriterReconnect = null;
    final oldSub = _externalWriterSub;
    if (oldSub != null) unawaited(oldSub.cancel());
    _externalWriterSub = ref
        .read(bridgeApiProvider)
        .metaSessionEvents(widget.serviceKey, threadId)
        .listen(
          (update) => _applyExternalWriterUpdate(threadId, epoch, update),
          onError: (Object error, StackTrace stack) =>
              _externalWriterStreamLost(threadId, epoch, error),
          onDone: () => _externalWriterStreamLost(threadId, epoch, null),
          cancelOnError: true,
        );
  }

  void _applyExternalWriterUpdate(
    String threadId,
    int epoch,
    SessionFollowUpdate update,
  ) {
    if (!mounted ||
        !_externalWriterMode ||
        _threadId != threadId ||
        epoch != _externalWriterEpoch) {
      return;
    }
    final paginated = update.historyRevision != null;
    _externalWriterLegacy = !paginated;
    final followTail = _loading || _atBottom;
    final wasRunning = _externalWriterRunning;
    final willRun = const {
      'incomplete',
      'running',
    }.contains(update.liveness.turnState);
    final refreshDiff =
        !paginated &&
        _items
                .where((item) => item.type == 'fileChange')
                .map((item) => '${item.id}\u0000${item.text}')
                .join('\u0001') !=
            update.items
                .where((item) => item.itemType == 'fileChange')
                .map((item) => '${item.id}\u0000${item.text}')
                .join('\u0001');
    _updateState(() {
      _externalWriterLiveness = update.liveness;
      if (!paginated) {
        _replaceTranscriptItems(update.items);
        _historySyncing = false;
        _showingCachedHistory = false;
        _historyEpoch = null;
      }
      if (willRun && !wasRunning) _elapsedSecs = 0;
      if (!paginated || _items.isNotEmpty) _loading = false;
      _error = null;
      _retry = null;
    });
    if (willRun && !wasRunning) {
      _startElapsedTicker();
    } else if (!willRun && wasRunning) {
      _elapsedTicker?.cancel();
      _elapsedTicker = null;
      _turnStartedAt = null;
    }
    if (refreshDiff) _loadGit();
    if (paginated) {
      if (_externalHistoryRevision != update.historyRevision) {
        _externalHistoryRevision = update.historyRevision;
        _externalHistoryDirty = true;
      }
      // The host samples rollout revisions and liveness independently. A
      // completed turn can follow the final revision without another append.
      if (wasRunning != willRun) _externalHistoryDirty = true;
      if (_externalHistoryDirty) _scheduleExternalHistory(threadId, epoch);
    } else if (followTail) {
      _scrollToEnd(force: true);
    }
  }

  void _scheduleExternalHistory(String threadId, int epoch) {
    if (_externalWriterLegacy ||
        _externalHistoryLoading ||
        _externalHistoryTimer != null) {
      return;
    }
    _externalHistoryTimer = Timer(
      _items.isEmpty ? Duration.zero : const Duration(milliseconds: 750),
      () {
        _externalHistoryTimer = null;
        _refreshExternalHistory(threadId, epoch);
      },
    );
  }

  Future<void> _refreshExternalHistory(String threadId, int epoch) async {
    bool current() =>
        mounted &&
        _externalWriterMode &&
        _threadId == threadId &&
        _externalWriterEpoch == epoch;
    if (!current() || _externalWriterLegacy || _externalHistoryLoading) return;
    _externalHistoryLoading = true;
    _externalHistoryDirty = false;
    var succeeded = false;
    try {
      // Keep a user-requested prepend ahead of the background tail refresh.
      if (_historyLoad != null) await _historyLoad;
      if (!current()) return;
      final history = await ref
          .read(bridgeApiProvider)
          .appThreadRead(widget.serviceKey, threadId, includeTurnPages: false);
      if (!current() || _externalWriterLegacy) return;
      final followTail = _loading || _atBottom;
      final anchor = followTail ? null : _captureHistoryAnchor();
      _updateState(() {
        // ACP replay and native history use different item identities, even
        // when replay had no epoch. Replace only after a successful read.
        if ((_caps.isAcp || _historyEpoch != null) &&
            history.historyEpoch != null &&
            _historyEpoch != history.historyEpoch) {
          _replaceTranscriptItems(const []);
          _turnWindows.clear();
          _fetchedTurns.clear();
          _sequentialHistoryIds.clear();
          _historyGeneration++;
        }
        _historyEpoch = history.historyEpoch;
        _showingCachedHistory = false;
        _historySyncing = false;
        _turnSummaries = history.turns;
        _firstTurnId = history.firstTurnId;
        _hasOlder = history.hasOlder;
        _sequentialHistoryIds.addAll(history.items.map((item) => item.id));
        // Messages this view sent while it wrote are in the host's history
        // now (a release or another writer turned it read-only).
        _dropHostHeldLocalPrompts(history.items);
        for (final item in history.items) {
          final index = _itemIndex[item.id];
          if (index == null) continue;
          final existing = _items[index];
          if (!listEquals(existing.imageUrls, item.images)) {
            existing.imageUrls = item.images;
            existing.images = resolveImageUrls(item.images);
          }
          if (item.itemType == 'imageGeneration') {
            existing.streaming =
                item.turnId.isNotEmpty &&
                item.turnId == history.activeTurnId &&
                item.turnCompletedAt == null &&
                imageGenerationInProgress(item.text);
          }
          existing
            ..text = item.text
            ..title = item.title
            ..type = item.itemType
            ..turnId = item.turnId
            ..turnCompletedAt = item.turnCompletedAt
            ..turnDurationMs = item.turnDurationMs;
        }
        _spliceTranscriptItems(
          history.items,
          atStart: false,
          activeTurnId: history.activeTurnId,
        );
        for (final page in history.turnPages) {
          // An older read completed while this background refresh was queued.
          _turnWindows.putIfAbsent(page.turnId, () => page);
          _fetchedTurns.add(page.turnId);
          _spliceTranscriptItems(
            page.items,
            atStart: true,
            activeTurnId: history.activeTurnId,
          );
        }
        for (final item in _items) {
          if (item.type == 'imageGeneration' &&
              item.turnId != history.activeTurnId) {
            item.streaming = false;
          }
        }
        _cachedRows = null;
        _markTurnsLoaded();
        _loading = false;
        _branch = history.branch;
        _cwd ??= history.cwd;
        _error = null;
        _retry = null;
      });
      succeeded = true;
      if (followTail) {
        _scrollToEnd(force: true);
      } else if (anchor != null) {
        _restoreHistoryAnchor(anchor, _historyGeneration);
      }
    } catch (error) {
      if (current()) {
        // Retry on the next heartbeat or reconnect, even if the revision is unchanged.
        _externalHistoryDirty = true;
        _updateState(() {
          _loading = false;
          _historySyncing = false;
          _error = friendlyError(error);
          _retry = () => _refreshExternalHistory(threadId, epoch);
        });
      }
    } finally {
      if (current()) {
        _externalHistoryLoading = false;
        if (succeeded && _externalHistoryDirty) {
          _scheduleExternalHistory(threadId, epoch);
        }
      }
    }
  }

  void _externalWriterStreamLost(String threadId, int epoch, Object? error) {
    if (!mounted ||
        !_externalWriterMode ||
        _threadId != threadId ||
        epoch != _externalWriterEpoch ||
        _externalWriterReconnect != null) {
      return;
    }
    _externalWriterSub = null;
    _updateState(() {
      _loading = false;
      _error = error == null
          ? AppLocalizations.of(context).connectionLost
          : friendlyError(error);
      _retry = () => _retryExternalWriter(threadId, epoch);
    });
    _externalWriterReconnect = Timer(const Duration(seconds: 1), () {
      _externalWriterReconnect = null;
      _subscribeExternalWriter(threadId, epoch);
    });
  }

  void _retryExternalWriter(String threadId, int epoch) {
    _externalWriterReconnect?.cancel();
    _externalWriterReconnect = null;
    _updateState(() {
      _error = null;
      _retry = null;
      if (_items.isEmpty) _loading = true;
    });
    _subscribeExternalWriter(threadId, epoch);
  }

  Future<void> _takeOverExternalWriter() async {
    if (_guardianReadOnly) return;
    final threadId = _threadId;
    final liveness = _externalWriterLiveness;
    if (threadId == null ||
        liveness == null ||
        !liveness.allowsResume ||
        _takingOver) {
      return;
    }
    if (liveness.requiresTakeover) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) =>
            TakeoverDialog(holders: liveness.holders, hasTarget: true),
      );
      if (confirmed != true || !mounted || _threadId != threadId) return;
    }

    final l10n = AppLocalizations.of(context);
    final messenger = ToastMessenger.of(context);
    _updateState(() {
      _takingOver = true;
      _error = null;
      _retry = null;
    });
    try {
      ForceResumeReport? report;
      if (liveness.requiresTakeover) {
        report = await ref
            .read(bridgeApiProvider)
            .metaForceResume(widget.serviceKey, threadId);
        if (!report.resumed) {
          if (!mounted || _threadId != threadId) return;
          _updateState(() {
            _takingOver = false;
            _error = l10n.takeoverResumeFailed(report!.resumeError ?? '');
          });
          return;
        }
      }
      if (!mounted || _threadId != threadId) return;
      if (report != null) {
        final parts = <String>[
          l10n.takeoverResumed,
          if (report.killed.isNotEmpty)
            l10n.takeoverKilled(report.killed.length),
          if (report.stillHeld) l10n.takeoverStillHeld,
        ];
        messenger.notice(parts.join(' · '));
      }
      _cancelExternalWriterSubscription();
      _updateState(() {
        _externalWriterMode = false;
        _externalWriterLiveness = null;
        _takingOver = false;
      });
      await _resumeAndLoad();
    } catch (error) {
      if (!mounted || _threadId != threadId) return;
      _updateState(() {
        _takingOver = false;
        _error = friendlyError(error);
      });
    }
  }

  Widget _externalWriterAction(AppLocalizations l10n) {
    if (_guardianReadOnly) {
      return SafeArea(
        top: false,
        child: Padding(
          key: const Key('guardian-read-only'),
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.guardianReadOnly),
              if (_parentThreadId case final parent?)
                TextButton.icon(
                  key: const Key('open-parent-session'),
                  onPressed: () => _openThread(
                    parent,
                    _discoveredThreads[parent]?.cwd ??
                        _threads
                            .where((t) => t.id == parent)
                            .firstOrNull
                            ?.cwd ??
                        _cwd,
                  ),
                  icon: const Icon(Icons.subdirectory_arrow_left),
                  label: Text(l10n.parentSession),
                ),
            ],
          ),
        ),
      );
    }

    // The host decides a host-access session; its panel says how.
    if (_caps.hostAccess) return _accessPanelBar(l10n);

    final scheme = Theme.of(context).colorScheme;
    final liveness = _externalWriterLiveness;
    final canResume = liveness?.allowsResume ?? false;
    final hasCwd = _cwd?.trim().isNotEmpty ?? false;
    final stateControl = SizedBox(
      width: double.infinity,
      height: 46,
      child: canResume
          ? FilledButton.icon(
              key: const Key('chat-takeover-action'),
              onPressed: _takingOver ? null : _takeOverExternalWriter,
              icon: _takingOver
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bolt, size: 18),
              label: Text(
                liveness!.requiresTakeover
                    ? l10n.forceTakeover
                    : l10n.resumeSession,
              ),
            )
          : DecoratedBox(
              key: const Key('chat-read-only-action'),
              decoration: BoxDecoration(
                color: scheme.surfaceContainer,
                borderRadius: BorderRadius.circular(kPanelRadius),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      l10n.readOnlyViewing,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                stateControl,
                if (hasCwd) ...[
                  const SizedBox(height: 8),
                  _externalDiffButton(l10n),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The access panel in place of the composer, with the diff action.
  Widget _accessPanelBar(AppLocalizations l10n) {
    final hasCwd = _cwd?.trim().isNotEmpty ?? false;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _accessPanel(l10n),
                if (hasCwd) ...[
                  const SizedBox(height: 8),
                  _externalDiffButton(l10n),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _externalDiffButton(AppLocalizations l10n) => SizedBox(
    width: double.infinity,
    height: 42,
    child: OutlinedButton.icon(
      key: const Key('chat-external-diff-action'),
      onPressed: _diffLoading ? _cancelDiff : _showDiff,
      icon: _diffLoading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.difference_outlined, size: 18),
      label: Text(_diffLoading ? l10n.cancelDiffLoad : l10n.viewDiff),
    ),
  );
}
