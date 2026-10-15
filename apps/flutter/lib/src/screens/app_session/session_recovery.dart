part of '../app_session_screen.dart';

extension _SessionRecovery on _AppSessionState {
  void _subscribe() {
    final epoch = ++_subscriptionEpoch;
    _sub?.cancel();
    // Warm the quota with the subscription rather than on the first tap: the
    // sidebar shows it inline, and a popover that spins for a round-trip every
    // time reads as the app being slow. From here on `account/rateLimits/
    // updated` keeps it fresh, so this fetch happens once per connection.
    _loadQuota();
    _sub = ref
        .read(bridgeApiProvider)
        .appEvents(widget.serviceKey)
        // onError as well as onDone: the bridge errors the stream (rather than
        // closing it) when the service isn't connected yet, so treat both as a
        // dropped connection and auto-reconnect instead of waiting for the
        // periodic health check.
        .listen(
          _onEvent,
          onError: (_) {
            if (epoch == _subscriptionEpoch) _onStreamClosed();
          },
          onDone: () {
            if (epoch == _subscriptionEpoch) _onStreamClosed();
          },
        );
  }

  void _onStreamClosed() {
    if (!mounted) return;
    _linkEpoch++;
    // The socket may still be alive when the bridge closes a lagged event feed.
    // Both cases need a new subscription and a history read to recover gaps.
    _updateState(() {
      _streaming = false;
      _connectionLost = true;
      for (final item in _items) {
        if (item.type == 'imageGeneration') item.streaming = false;
      }
    });
    _publishLinkState(down: true);
    _autoReconnect();
  }

  /// Attach to an existing thread for live events and turns, then load history.
  ///
  /// The read counts only for the conversation and host connection
  /// ([_linkEpoch]) it was asked of, and only while no newer load replaced
  /// it. A [displayOnly] refresh just shows what the host holds: it keeps
  /// the shown notice, settles no admission and does not drain the queue.
  Future<void> _resumeAndLoad({
    bool propagateErrors = false,
    bool displayOnly = false,
  }) async {
    // Guard: a stale event (e.g. thread/compacted from a prior thread) can
    // arrive after switching to a new, unsaved conversation — don't `_threadId!`
    // through a null here.
    if (_threadId == null || _externalWriterMode) return;
    if (_isDeleted(_threadId!)) {
      _showDeleted(_threadId!);
      return;
    }
    _updateState(() {
      _loading = _items.isEmpty;
      _historySyncing = true;
      _restoringSettings = true;
      if (!displayOnly) {
        _error = null;
        _retry = null;
      }
    });
    var restoringMetadata = false;
    final startTid = _threadId!;
    final generation = ++_threadLoadGeneration;
    final link = _linkEpoch;
    final turnStateRevision = _turnStateRevision;
    // An admission armed before this read began: the read's authoritative
    // answer settles it (see [_reconcileAwaitedStart]).
    final awaited = displayOnly ? null : _awaitedStart;
    final liveItems = <String, TranscriptItem>{};
    final partialItems = <String>{};
    _historyLiveItems = liveItems;
    _historyPartialItems = partialItems;
    bool current() =>
        mounted &&
        _threadId == startTid &&
        generation == _threadLoadGeneration &&
        link == _linkEpoch;
    // Still this conversation's latest load, but its connection moved and
    // nothing replaced it: the loading flags it raised are its own to drop
    // (the reconnect, or the next read, asks the current host again).
    bool abandoned() =>
        mounted &&
        _threadId == startTid &&
        generation == _threadLoadGeneration &&
        link != _linkEpoch;
    try {
      final api = ref.read(bridgeApiProvider);
      unawaited(
        api.appHistoryFocus(widget.serviceKey, startTid).catchError((_) {}),
      );
      if (_items.isEmpty) {
        final cached = await api.appHistoryCached(widget.serviceKey, startTid);
        if (!current()) return;
        if (cached != null) {
          final liveQuestions = Map.of(_asyncQuestions);
          _updateState(() {
            _replaceTranscriptItems(cached.items);
            _turnSummaries = cached.turns;
            _mergeHistoryLiveItems(liveItems, partialItems);
            _asyncQuestions.addAll(liveQuestions);
            _hasOlder = cached.hasOlder;
            _firstTurnId = cached.firstTurnId;
            _sequentialHistoryIds.addAll(cached.items.map((item) => item.id));
            for (final page in cached.turnPages) {
              _turnWindows[page.turnId] = page;
              _fetchedTurns.add(page.turnId);
              _spliceTranscriptItems(page.items, atStart: true);
            }
            _cwd ??= cached.cwd;
            _loading = false;
            _showingCachedHistory = true;
            _historyEpoch = cached.historyEpoch;
          });
          _scrollToEnd(force: true);
        }
      }
      await api.appHistorySyncPrepare(widget.serviceKey);
      if (!current()) return;
      // Native thread metadata (and with it the Guardian check below, which
      // fails closed) exists only for the Codex app-server. Other protocols
      // take the listing's metadata and are never sent a native call.
      final metadata = _caps.nativeMetadata
          ? await api.appThreadMetadata(widget.serviceKey, startTid)
          : _threads.where((t) => t.id == startTid).firstOrNull;
      if (!current()) return;
      _parentThreadId = metadata?.parentThreadId;
      if (metadata != null) _discoveredThreads[metadata.id] = metadata;
      if (metadata?.isGuardian ?? false) {
        _guardianReadOnly = true;
        _enterExternalWriterMode(startTid);
        return;
      }
      if (_caps.hostAccess) {
        // The host decides: the original session opens for writing here, or
        // this view follows it and says who holds it.
        if (!await _openHostSession(startTid, current)) return;
      } else {
        await api.appThreadResume(widget.serviceKey, startTid);
      }
      // An obsolete resume must not fan out into more history/config requests.
      if (!current()) return;
      // Reopening a host-access session (re)negotiates its per-session
      // options.
      if (_caps.hostAccess) {
        _invalidateCaps();
        _refreshAgentSettings();
      }
      // Read the thread history and its persisted config concurrently. The
      // config is best-effort (an unreachable host meta tunnel yields an
      // all-unset config and we fall back to the server / in-memory restore).
      final historyFuture = api.appThreadRead(widget.serviceKey, startTid);
      final persistedFuture = _loadPersistedConfig(startTid);
      final history = await historyFuture;
      if (!current()) return;
      final liveTurnChanged = turnStateRevision != _turnStateRevision;
      final activeTurnId = liveTurnChanged ? _turnId : history.activeTurnId;
      final liveQuestions = _asyncQuestions.entries
          .where((entry) => liveItems.containsKey(entry.key))
          .toList();
      final anchor = _items.isNotEmpty && !_atBottom
          ? _captureHistoryAnchor()
          : null;
      _updateState(() {
        _historyAppliedLink = link;
        _historySyncing = false;
        _showingCachedHistory = false;
        _historyEpoch = history.historyEpoch;
        _loading = false;
        _replaceTranscriptItems(history.items, activeTurnId: activeTurnId);
        _turnSummaries = history.turns;
        _hasOlder = history.hasOlder;
        _historyError = false;
        _fetchedTurns.clear();
        _turnWindows.clear();
        _sequentialHistoryIds
          ..clear()
          ..addAll(history.items.map((item) => item.id));
        _firstTurnId = history.firstTurnId;
        for (final page in history.turnPages) {
          _turnWindows[page.turnId] = page;
          _fetchedTurns.add(page.turnId);
          _spliceTranscriptItems(
            page.items,
            atStart: true,
            activeTurnId: activeTurnId,
          );
        }
        _mergeHistoryLiveItems(liveItems, partialItems);
        _asyncQuestions.addEntries(liveQuestions);
        _cachedRows = null;
        _loadingOlder = false;
        _historyLoad = null;
        _historyGeneration++;
        // Events received during the read are newer than its lifecycle snapshot.
        if (!liveTurnChanged) {
          final keepClock =
              _streaming &&
              history.running &&
              _turnId == activeTurnId &&
              _turnStartedAt != null;
          _streaming = history.running;
          _turnId = activeTurnId;
          // An admission armed before this read is settled by it either
          // way — running, the turn shows; idle, it ended unseen. A newer
          // admission (armed during the read, which may predate it) is left
          // to its own events or reconciliation, and a display-only refresh
          // settles none.
          if (awaited != null && identical(_awaitedStart, awaited)) {
            _turnStartSeen();
          }
          // A resumed turn has nothing in this composer to un-send with Esc.
          _outputStarted = history.running;
          if (!keepClock) {
            _elapsedTicker?.cancel();
            _elapsedTicker = null;
            _turnStartedAt = null;
            if (_streaming) {
              _elapsedSecs = 0;
              _startElapsedTicker();
            }
          }
        }
        if (!_streaming) {
          for (final item in _items) {
            item.streaming = false;
          }
        }
        // Seed the status gauge + branch chip + cwd from the thread metadata.
        // _cwd may be null if the thread was opened without it (e.g. a default
        // folder that codex resolved to a real path) — adopt the resolved cwd
        // so the git diff (which needs a concrete cwd) works.
        _branch = history.branch;
        _cwd ??= history.cwd;
        final tu = history.tokensUsed, cw = history.contextWindow;
        if (tu != null && cw != null && cw > 0) {
          _ctx = ContextStatus(tokensUsed: tu, contextWindow: cw);
        }
      });
      if (identical(_historyLiveItems, liveItems)) {
        _historyLiveItems = null;
        _historyPartialItems = null;
      }
      _restoreHistorySettings(
        history,
        const ThreadConfig(),
        _models.where((model) => model.id == history.model).firstOrNull,
      );
      _loadGit();
      // The subscribe-time quota fetch races the connection coming up (and
      // loses, on a cold open). A successful read proves the service is
      // reachable, so this is the attempt that actually lands.
      if (_rate == null) _loadQuota();
      if (anchor != null) {
        _restoreHistoryAnchor(anchor, _historyGeneration);
      } else {
        _scrollToEnd(force: true);
      }
      // A turn may have completed while we were disconnected: if the reload
      // landed idle with messages still queued, drain the backlog now (turn-end
      // events that would normally flush it were missed during the drop).
      final settingsRevision = _settingsRevision;
      final runtimeAt = _runtimeAt;
      restoringMetadata = true;
      // Connection/history recovery is complete. Optional metadata has its own
      // deadline and generation; sending still waits for settings restoration.
      unawaited(() async {
        try {
          final persisted = await persistedFuture.timeout(
            const Duration(seconds: 10),
            onTimeout: () => const ThreadConfig(),
          );
          if (!current()) return;
          // Restore the model from the server's own report first (the resume
          // response says what the thread actually runs with); fall back to the
          // persisted pick for older servers that don't report one. Resolve the id
          // against this service's model list.
          final restoredModelId = history.model ?? persisted.model;
          ModelInfo? restoredModel;
          if (restoredModelId != null) {
            try {
              final models = await _ensureModels().timeout(
                const Duration(seconds: 10),
              );
              restoredModel = models
                  .where((m) => m.id == restoredModelId)
                  .firstOrNull;
            } catch (_) {
              // Model list unavailable — leave the model unchanged.
            }
          }
          if (!current()) return;
          if (_settingsRevision == settingsRevision &&
              _runtimeAt == runtimeAt) {
            _restoreHistorySettings(history, persisted, restoredModel);
          }
        } finally {
          if (current()) {
            _updateState(() => _restoringSettings = false);
            if (!displayOnly) _maybeFlushQueue();
            _offerHeldQueue();
          } else if (abandoned()) {
            _updateState(() => _restoringSettings = false);
          }
        }
      }());
    } catch (e) {
      if (!current()) return;
      _historySyncing = false;
      if (_caps.externalWriterMonitor && _isActiveWriterError(e)) {
        _enterExternalWriterMode(startTid);
        return;
      }
      _updateState(() {
        _loading = false;
        // A display-only refresh leaves the notice it was started for.
        if (!displayOnly || _error == null) {
          _error = friendlyError(e);
          _retry = _resumeAndLoad;
        }
      });
      if (propagateErrors) rethrow;
    } finally {
      if (current() && !restoringMetadata) {
        _updateState(() => _restoringSettings = false);
      } else if (abandoned() && !restoringMetadata) {
        _updateState(() {
          _historySyncing = false;
          _restoringSettings = false;
          _loading = false;
        });
      }
      if (identical(_historyLiveItems, liveItems)) {
        _historyLiveItems = null;
        _historyPartialItems = null;
      }
    }
  }

  void _restoreHistorySettings(
    ThreadHistory history,
    ThreadConfig persisted,
    ModelInfo? restoredModel,
  ) {
    _updateState(() {
      // Restore the thread's plan mode authoritatively: prefer the server's
      // collaborationMode if it ever exposes it, else our per-thread memory.
      // (The old "last item is plan" guess was wrong — the model's reply
      // usually isn't a plan item — which left plan mode stuck on.) Don't
      // clobber a pending toggle the user set before a drop/reload.
      final tid = _threadId;
      // The server-reported runtime config (model / effort / permissions the
      // thread actually runs with) — ground truth for the status-bar model
      // indicator. Absent on older servers that don't report it.
      if (history.model != null ||
          history.approvalPolicy != null ||
          history.sandboxMode != null ||
          history.reasoningEffort != null) {
        _runtime = ThreadRuntimeConfig(
          model: history.model,
          modelProvider: history.modelProvider,
          reasoningEffort: history.reasoningEffort,
          approvalPolicy: history.approvalPolicy,
          approvalsReviewer: history.approvalsReviewer,
          serviceTier: history.serviceTier,
          sandboxMode: history.sandboxMode,
          collaborationMode: history.collaborationMode,
          confirmedByUpdate: history.configConfirmed,
        );
        _runtimeAt = DateTime.now();
      }
      // Permission mode: the server's reported approval+sandbox pair wins
      // when it maps onto one of our presets; else the persisted pick (an
      // unmapped server combo still shows raw in the runtime sheet).
      final serverPreset = (history.approvalPolicy == null)
          ? null
          : PermissionMode.values
                .where(
                  (m) =>
                      m.approval == history.approvalPolicy &&
                      m.sandbox == history.sandboxMode &&
                      m.reviewer == (history.approvalsReviewer ?? 'user'),
                )
                .firstOrNull;
      final persistedMode = persisted.permissionMode == null
          ? null
          : PermissionMode.values
                .where((m) => m.name == persisted.permissionMode)
                .firstOrNull;
      final restoredMode = serverPreset ?? persistedMode;
      if (restoredMode != null) _mode = restoredMode;
      _serviceTier ??= history.serviceTier ?? persisted.serviceTier;
      if (restoredModel != null) _model = restoredModel;
      final serverCollab = history.collaborationMode;
      final restored = serverCollab != null
          ? serverCollab == 'plan'
          : (persisted.planMode ??
                (tid != null &&
                    (_AppSessionState._planByThread[_threadKey(tid)] ??
                        false)));
      final hadPendingToggle = _plan != _planActive;
      _planActive = restored;
      if (!hadPendingToggle) _plan = _planActive;
      // A reported runtime model makes even a null effort authoritative.
      // Only older servers without runtime metadata need the persisted value.
      // A pending pick (_effort) is left untouched — the chip shows
      // `_effort ?? _effortActive`, so it survives a drop/reload unclobbered.
      final serverEffort = ReasoningEffort.fromWire(history.reasoningEffort);
      _effortActive = history.model != null || history.configConfirmed
          ? serverEffort
          : serverEffort ??
                ReasoningEffort.fromWire(persisted.reasoningEffort) ??
                (tid != null
                    ? _AppSessionState._effortByThread[_threadKey(tid)]
                    : null);
      // Drop a restored effort the restored model can't run (mirrors the guard
      // in _pickModel/_seedDefaults) so a stale persisted pairing never asserts
      // an unsupported level on the next turn.
      final guardModel = _model;
      final guardEffort = _effortActive;
      if (guardModel != null &&
          guardEffort != null &&
          !guardModel.supportedReasoningEfforts.contains(guardEffort.wire)) {
        _effortActive = ReasoningEffort.fromWire(
          guardModel.defaultReasoningEffort,
        );
      }
    });
  }

  /// Manually compact the conversation after a confirm.
  Future<void> _compact() async {
    if (_guardianReadOnly || !_caps.compact) return;
    final tid = _threadId;
    if (tid == null) return;
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l10n.compact),
        content: Text(l10n.compactConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(l10n.compact),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(bridgeApiProvider).appCompact(widget.serviceKey, tid);
      // The server emits thread/compacted, which reloads history.
    } catch (e) {
      if (mounted) {
        final msg = friendlyError(e);
        final lost = _looksDisconnected(msg);
        _updateState(() {
          _error = msg;
          if (lost) _connectionLost = true;
        });
        if (lost) _publishLinkState(down: true);
      }
    }
  }

  /// Publish whether this conversation's link is down, so the services list
  /// agrees with what the transcript is showing.
  ///
  /// Called from every place the local flags move. Kept as one helper because
  /// the two used to drift: the flags lived only in this widget, so a service
  /// could read "online" in the list while this screen said "reconnecting".
  ///
  /// A reconnect in progress counts as down — the link genuinely isn't carrying
  /// traffic yet, and the alternative is a green row next to a spinner.
  void _publishLinkState({required bool down}) {
    final notifier = ref.read(observedDisconnectedProvider.notifier);
    final current = notifier.state;
    final has = current.contains(widget.serviceKey);
    if (down == has) return;
    notifier.state = down
        ? {...current, widget.serviceKey}
        : ({...current}..remove(widget.serviceKey));
    // The cached probe answered before the link changed, so it would otherwise
    // keep reporting the stale verdict for as long as the cache lives.
    ref.invalidate(appReachableProvider(widget.serviceKey));
  }

  /// Re-establish the connection automatically, with a few backoff retries.
  /// Shows a "reconnecting" state while trying; only surfaces the manual
  /// "disconnected" banner if every attempt fails. Idempotent — concurrent
  /// triggers (stream close + health tick) collapse into one attempt.
  /// [reload] re-reads the thread history after reconnecting (to catch events
  /// missed while the socket was down). Pass `false` from the send-failure path
  /// so the just-added optimistic message and a pending plan toggle survive for
  /// the retry.
  Future<void> _autoReconnect({bool reload = true}) async {
    if (!mounted || !_foreground || _reconnecting) return;
    // Debounce: a flapping socket (connect succeeds then drops) could otherwise
    // spin reconnect attempts. The periodic health check is the backstop.
    if (_reconnectCooldown?.isActive ?? false) return;
    _reconnectCooldown = Timer(const Duration(seconds: 3), () {});
    final epoch = ++_reconnectEpoch;
    final elapsed = Stopwatch()..start();
    bool current() => mounted && _foreground && epoch == _reconnectEpoch;
    void record(String stage, int attempt, [Object? error]) {
      final detail = error == null ? '' : ' error=${friendlyError(error)}';
      LogManager.instance.record(
        'controller.recovery',
        'service=${widget.serviceKey} stage=$stage attempt=$attempt '
            'elapsed_ms=${elapsed.elapsedMilliseconds}${detail.substring(0, math.min(512, detail.length))}',
        level: error == null ? 'INFO' : 'WARN',
      );
    }

    if (mounted) {
      _updateState(() {
        _reconnecting = true;
        _connectionLost = false;
        _error = null;
        _retry = null;
      });
      _publishLinkState(down: true);
    }
    final api = ref.read(bridgeApiProvider);
    for (var attempt = 0; attempt < 4; attempt++) {
      if (!current()) return;
      try {
        record('connect', attempt + 1);
        // Let the bridge retain a live socket if only its event subscription ended.
        await api.appConnect(widget.serviceKey, appLocalPort);
        if (!current()) return;
        _connectionLost = false;
        // A reconnect may reach a different agent generation.
        _invalidateCaps();
        _subscribe();
        if (reload && _threadId != null) {
          if (_externalWriterMode) {
            _externalHistoryDirty = true;
            await _refreshExternalHistory(_threadId!, _externalWriterEpoch);
          } else {
            await _resumeAndLoad(propagateErrors: true);
          }
        }
        if (!current()) return;
        // The connection moved while its read was out (another generation,
        // or lost/replaced): that read applied nothing, so this attempt is
        // not ready — ask the current host again rather than report it.
        if (reload &&
            _threadId != null &&
            !_externalWriterMode &&
            _historyAppliedLink != _linkEpoch) {
          throw StateError('history read outlived its host connection');
        }
        record('history-ready', attempt + 1);
        // Re-list too, not just the open transcript. `_loadThreads` runs once at
        // initState and is best-effort: if the host wasn't reachable then (it
        // restarted, or the app opened first), the failure was swallowed and
        // the pane stayed empty FOREVER — nothing else re-lists except sending
        // a message. A reconnect is exactly the moment the data became
        // available, so this is where it has to be retried.
        unawaited(
          _loadThreads().then((_) {
            if (mounted &&
                !_reconnecting &&
                !api.appIsConnected(widget.serviceKey)) {
              _onStreamClosed();
            }
          }),
        );
        // Same reasoning for the other cold-open loads: a reconnect is the
        // moment their data became reachable. Both are no-ops once settled —
        // the cwd seed won't override a folder the user picked, and the quota
        // just refreshes.
        if (_openLoadRetries.containsKey(_kCwdSeed)) {
          unawaited(_seedDefaultCwd());
        }
        if (_rate == null) unawaited(_loadQuota());
        unawaited(_ensureModels());
        _loadGit(); // the working tree may have moved on while we were away
        // Content loaders retain old data on failure. A timed-out RPC can
        // therefore close this new connection without throwing out of them.
        if (_connectionLost || !api.appIsConnected(widget.serviceKey)) {
          throw StateError('app-server event feed closed during reconnect');
        }
        if (mounted) {
          _updateState(() {
            _reconnecting = false;
            _connectionLost = false;
            _error = null;
          });
          _publishLinkState(down: false);
        }
        record('ready', attempt + 1);
        _maybeFlushQueue();
        _offerHeldQueue();
        return;
      } catch (error) {
        if (!current()) return;
        record('retry', attempt + 1, error);
        if (attempt < 3) {
          await Future<void>.delayed(Duration(seconds: 1 << attempt));
        }
      }
    }
    // Out of retries: fall back to the manual banner.
    if (current()) {
      record('exhausted', 4);
      _updateState(() {
        _reconnecting = false;
        _connectionLost = true;
        _error = AppLocalizations.of(context).connectionLost;
        _retry = _autoReconnect;
      });
      _publishLinkState(down: true);
    }
  }
}
