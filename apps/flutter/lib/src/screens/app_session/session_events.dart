part of '../app_session_screen.dart';

extension _SessionEvents on _AppSessionState {
  /// The bridge reports that the agent host became unreachable (its link went
  /// stale, the local host was replaced) or that a different host incarnation
  /// answered. Losing the host is handled like a dropped stream, so the
  /// bounded reconnect replaces the stale link instead of waiting on it; a
  /// replaced host means the transcript must be re-read.
  void _onAgentHostState(AppEvent e) {
    Map<dynamic, dynamic> raw = const {};
    try {
      final decoded = jsonDecode(e.raw);
      if (decoded is Map) raw = decoded;
    } catch (_) {}
    final known = _capsCache;
    final generation = raw['generation'];
    final lost = raw['connected'] == false || raw['replaced'] == true;
    final moved =
        lost ||
        (generation is int &&
            known != null &&
            known.negotiated &&
            generation != known.generation);
    // Whatever the previous connection still answers is not this one's.
    if (moved) _linkEpoch++;
    _updateState(_invalidateCaps);
    if (lost) {
      // The host attachments were granted for is gone (or another one
      // answers): nothing still being picked, read or uploaded may reach
      // whichever host the reconnect finds.
      _drafts.revokeAdmissions();
    }
    if (raw['connected'] == false) {
      _onStreamClosed();
      return;
    }
    if (raw['replaced'] == true) {
      // Not current until a reconnect re-reads the conversation. When none
      // can start now (debounced, backgrounded), the health check or the
      // return to the foreground starts it; one already running finds this
      // flag after its (now obsolete) reload and tries again.
      _updateState(() => _connectionLost = true);
      _autoReconnect();
      return;
    }
    // A history read of the previous generation was dropped: read again
    // from this one.
    if (moved && _historySyncing && _threadId != null && !_reconnecting) {
      unawaited(_resumeAndLoad());
    }
    _refreshAgentSettings();
    // Another generation may offer another model catalog.
    if (moved) unawaited(_ensureModels());
  }

  void _dropResolvedRequest(AppEvent e) {
    String? id;
    try {
      final raw = jsonDecode(e.raw);
      if (raw is Map) id = raw['requestId']?.toString();
    } catch (_) {}
    id ??= e.requestId;
    if (id == null || !_approvals.any((a) => a.requestId == id)) return;
    _updateState(() => _approvals.removeWhere((a) => a.requestId == id));
  }

  void _onEvent(AppEvent e) {
    if (!mounted) return;
    // A rename — possibly from another device, since the server persists the
    // title — applies to whichever thread it names, so it has to be handled
    // BEFORE the other-thread guard below: a sidebar row's rename would
    // otherwise be dropped and the list would keep the old title until the
    // next reload (nothing polls `_loadThreads`).
    // The host deleted a session: whichever it names leaves the list, and
    // nothing said about it afterwards (a turn, a request, an access change)
    // acts on it again.
    if (e.kind == 'thread/deleted') {
      if (e.threadId case final thread?) _onThreadDeleted(thread);
      return;
    }
    if (e.threadId case final thread? when _isDeleted(thread)) return;
    if (e.kind == 'thread/name/updated') {
      _applyRemoteName(e);
      return;
    }
    // Another client of this app-server started, archived or restored a
    // session (broadcast to every connection): the host's `thread/list`
    // decides what the sidebar shows, so list again.
    if (e.kind == 'thread/started' ||
        e.kind == 'thread/archived' ||
        e.kind == 'thread/unarchived') {
      _scheduleThreadsRefresh();
    }
    // A pending request answered elsewhere (another device, the provider's own
    // UI) or withdrawn: drop its card. Carries the id in `raw` only.
    if (e.kind == 'serverRequest/resolved') {
      _dropResolvedRequest(e);
      return;
    }
    // The host's view of a session's access changed (a load finished, a
    // writer left, a turn ended): a following view asks again at once.
    if (e.kind == 'session/access/changed') {
      if (e.threadId case final thread?) _onAccessChanged(thread);
      return;
    }
    // The ACP host changed phase or generation (restart, crash, reconnect):
    // what the agent supports may have changed with it.
    if (e.kind == 'acp/host/state') {
      _onAgentHostState(e);
      return;
    }
    // The agent replaced this session's options / modes / usage.
    if (e.kind == 'acp/session/updated') {
      // A release by any controller withdraws write admission immediately.
      // Keep the draft and queue in their slot, even if close later fails.
      if (_caps.hostAccess && e.threadId == _threadId) {
        try {
          final raw = jsonDecode(e.raw);
          if (raw is Map &&
              (raw['admitted'] == false || raw['releasing'] == true)) {
            _onWriteWithdrawn(_threadId!);
          }
        } catch (_) {}
      }
      // Includes the session opened ahead for the shown draft.
      if (e.threadId == _agentSessionThread) _refreshAgentSettings();
      return;
    }
    // Ignore events belonging to another thread. Before this conversation has a
    // thread id (a brand-new conversation, pre-`thread/start`), the app session
    // is shared and another thread's turn may still be streaming, so drop any
    // thread-scoped event rather than letting it pollute the blank conversation
    // (append messages/approvals, flip `_streaming`/`_turnId`). Truly global
    // events (no threadId — e.g. account/rate-limit updates) always pass.
    if (e.threadId != null && e.threadId != _threadId) {
      // ...with one exception. A turn ending on ANOTHER thread changes that
      // thread's newest agent reply, which is exactly what its cached activity
      // summary holds. The cache is deliberately not auto-disposed, so without
      // this its row would show the previous reply for the rest of the session.
      // Dropping a cache entry can't pollute this conversation's state — the
      // reason the guard exists — so it is safe on this side of it.
      if (e.kind == 'turn/completed' || e.kind == 'turn/failed') {
        _invalidateSummary(e.threadId);
      }
      return;
    }
    // A deleted conversation shown here takes no request, even one that
    // names no thread.
    if (_threadId case final shown? when _isDeleted(shown)) {
      if (e.requestId != null || e.threadId != null) return;
    }
    // Server-initiated approval prompt (carries a request id to answer).
    if (e.requestId != null) {
      // A replay (reconnect, resume) re-announces a request already shown.
      if (_approvals.any((a) => a.requestId == e.requestId)) return;
      _updateState(() => _approvals.add(e));
      return;
    }
    if (e.kind == 'item/completed' &&
        e.itemType == 'agentMessage' &&
        e.itemId != null) {
      final questions = AsyncQuestionPrompt.fromEvent(e);
      if (questions != null &&
          !_answeredAsyncQuestions.contains('$_threadId:${e.itemId}')) {
        _updateState(() => _asyncQuestions[e.itemId!] = questions);
      }
    }
    // Status-bar feeds: token usage + quota updates carry their data in `raw`
    // (map_event is a generic passthrough, so no item fields are set).
    if (e.kind == 'thread/tokenUsage/updated') {
      final ctx = ContextStatus.fromRaw(e.raw);
      if (ctx != null) _updateState(() => _ctx = ctx);
      return;
    }
    if (e.kind == 'account/rateLimits/updated') {
      // codex v2 sends a sparse/rolling partial here — merge into the last full
      // snapshot rather than replace, or omitted windows would blank out.
      final r = RateLimits.fromRaw(e.raw);
      if (r != null) {
        _updateState(() => _rate = _rate == null ? r : _rate!.merge(r));
        _quotaRev.value++;
      }
      return;
    }
    // The server applied new effective thread settings — the authoritative
    // confirmation that a model / effort / permission / plan switch took
    // effect (possibly one this app just sent). Newer servers emit this with
    // the full snapshot whenever a turn's overrides change the settings.
    if (e.kind == 'thread/settings/updated') {
      final cfg = _parseSettingsUpdate(e.raw);
      if (cfg != null) _applyRuntime(cfg);
      return;
    }
    // The server substituted the model mid-turn (e.g. a policy or capacity
    // reroute): reflect it on the current turn's stamp so the transcript
    // records what actually handled the request.
    if (e.kind == 'model/rerouted') {
      String? to;
      try {
        final m = jsonDecode(e.raw) as Map<String, dynamic>;
        to = (m['toModel'] as String?)?.trim();
      } catch (_) {
        to = null;
      }
      if (to != null && to.isNotEmpty) {
        _updateState(() {
          _turnStampModel = to;
          _turnStampConfirmed = true;
          _turnRerouted = true;
        });
      }
      return;
    }
    // The agent edited files: refresh the working-tree-vs-main diff badge.
    if (e.kind == 'turn/diff/updated') {
      _loadGit();
      return;
    }
    // Compaction finished: reload the (now shorter) history.
    if (e.kind == 'thread/compacted') {
      _resumeAndLoad();
      return;
    }
    switch (e.kind) {
      case 'turn/started':
        _turnStateRevision++;
        _turnStartSeen();
        // A fresh turn supersedes any prior plan: re-enable the implement
        // prompt so a new plan (if this turn produces one) can offer it again.
        // Capture the turn id so the stop button can interrupt this turn.
        _updateState(() {
          _streaming = true;
          _turnId = _parseTurnId(e.raw);
          final prompt = _items.lastOrNull;
          if (_turnId != null &&
              prompt != null &&
              prompt.isUser &&
              prompt.id.startsWith('local-user-') &&
              prompt.turnId.isEmpty) {
            prompt.turnId = _turnId!;
            _cachedRows = null;
          }
          _implementDismissed = false;
          _pendingInterrupt = false;
          // A fresh turn hasn't produced output yet, so Esc undoes the send
          // until the first item lands.
          _outputStarted = false;
          _elapsed.value = 0;
          // Stamp what this turn runs with. A server that notifies settings
          // does so BEFORE turn/started, so a confirmed runtime is already
          // current here; otherwise fall back to what this app actually sent
          // (turn params override thread defaults, so on servers that never
          // notify, the sent value IS the effective one).
          final rt = _runtime;
          final confirmedRt = rt != null && rt.confirmedByUpdate;
          _turnStampModel = confirmedRt
              ? (rt.model ?? _sentModel)
              : (_sentModel ?? rt?.model);
          _turnStampEffort = confirmedRt
              ? rt.reasoningEffort
              : (_sentEffort ?? rt?.reasoningEffort);
          _turnStampConfirmed =
              _turnStampModel != null && _turnStampModel == rt?.model;
          _turnRerouted = false;
        });
        _startElapsedTicker();
        _scrollToEnd();
      case 'turn/completed':
        // The end of an earlier turn (reported late, e.g. by a recovery)
        // must not end the one running now.
        if (_endsAnotherTurn(e.raw) || _endsAnEndedTurn(e.raw)) return;
        _turnStateRevision++;
        _turnEnded(e.raw);
        // Terminal notifications can carry errors on failed or interrupted turns.
        final failure = _turnFailureText(e.raw);
        // A classified model failure is said by its card in the transcript,
        // never also by the error banner.
        final modelFailure = failure == null ? null : _modelFailure(e.raw);
        final ended = _parseTurnId(e.raw) ?? '';
        final interruption = _interruption(e.raw);
        _updateState(() {
          _streaming = false;
          _supplement = false;
          _turnId = null;
          for (final it in _items) {
            it.streaming = false;
          }
          final stopped =
              _pendingInterrupt || modelFailure?.code == 'cancelled';
          if (!stopped && modelFailure != null) {
            _showModelFailure(ended, modelFailure);
          }
          _finishTurn();
          // A turn the user stopped also ends as failed/aborted; show the
          // "stopped" marker rather than an error banner.
          if (interruption != null) {
            _showStop(interruption);
          } else if (stopped) {
            _addStoppedMarker(ended);
          } else if (modelFailure != null) {
            // Queued messages would only meet the same failure: they wait
            // for the user's Retry or next send.
            if (_queue.isNotEmpty) _draft.queuePaused = true;
          } else if (failure != null) {
            _error = _humanizeTurnError(failure);
            _retry = () => _send(retry: true);
          }
        });
        _maybeFlushQueue(); // send the next queued message, if any
        _loadGit(); // edits from the turn may have changed the diff
        // The turn just produced a new agent reply, so the cached one-line
        // summary now describes the turn BEFORE it. Drop it and let the
        // activity view re-read on its next build; without this the cache is
        // permanently stale for the thread the user is actually working in.
        _invalidateSummary(e.threadId);
      case 'turn/failed':
        if (_endsAnotherTurn(e.raw) || _endsAnEndedTurn(e.raw)) return;
        _turnStateRevision++;
        _turnEnded(e.raw);
        _updateState(() {
          _streaming = false;
          _supplement = false;
          _turnId = null;
          for (final it in _items) {
            it.streaming = false;
          }
          _finishTurn();
          // A turn the user stopped also ends as failed/aborted; show the
          // "stopped" marker rather than an error banner.
          if (_pendingInterrupt) {
            _addStoppedMarker(_parseTurnId(e.raw) ?? '');
          } else {
            _error = _humanizeTurnError(e.text);
            _retry = () => _send(retry: true);
          }
        });
        _maybeFlushQueue(); // send the next queued message, if any
        // An interrupted or failed turn can still have streamed a reply before
        // it stopped, so the cached summary is just as stale as on success.
        _invalidateSummary(e.threadId);
      default:
        _handleItemEvent(e);
    }
  }

  /// Turn a raw turn-failure string into what the user sees. An empty/absent
  /// message falls back to the generic notice; a Windows-sandbox helper failure
  /// (an embedded/自带 host that can't spawn its command sandbox) is rewritten
  /// into actionable guidance — switch to no-sandbox Full mode, or use an
  /// external host — instead of the raw "windows sandbox: spawn setup refresh".
  String _humanizeTurnError(String? message) {
    final l10n = AppLocalizations.of(context);
    final text = message?.trim() ?? '';
    if (text.isEmpty) return l10n.turnFailed;
    return isSandboxHelperFailure(text) ? l10n.sandboxHelperUnavailable : text;
  }

  /// Return failed-turn errors and explicit interrupted-turn errors. A normal
  /// interruption has no error and must not display a failure banner.
  String? _turnFailureText(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final turn = m['turn'];
      if (turn is! Map) return null;
      final err = turn['error'];
      if (turn['status'] != 'failed' &&
          !(turn['status'] == 'interrupted' && err != null)) {
        return null;
      }
      return (err is Map && err['message'] is String)
          ? err['message'] as String
          : '';
    } catch (_) {
      return null;
    }
  }

  /// A terminal `turn.error` the host classified (a string `code`, a bool
  /// `retryable` and the failure's own `itemId`), or null for an
  /// unclassified one, which keeps the banner.
  ModelFailure? _modelFailure(String raw) {
    try {
      final m = jsonDecode(raw);
      final err = m is Map && m['turn'] is Map ? m['turn']['error'] : null;
      if (err is! Map ||
          err['code'] is! String ||
          err['retryable'] is! bool ||
          err['itemId'] is! String ||
          (err['itemId'] as String).isEmpty) {
        return null;
      }
      return ModelFailure.parse(err);
    } catch (_) {
      return null;
    }
  }

  /// Show [failure] until the host's own item arrives. The card takes that
  /// item's ID and exact prompt, so the item — live, in a history read or
  /// a follow page, merged by ID — replaces it instead of adding a second
  /// one; the ended turn is only a fallback when no prompt was named. Call
  /// inside a `_updateState`.
  void _showModelFailure(String ended, ModelFailure failure) {
    final id = failure.itemId;
    if (_itemIndex.containsKey(id)) return;
    _itemIndex[id] = _items.length;
    _items.add(
      TranscriptItem(
        id: id,
        type: 'modelError',
        text: failure.encode(),
        turnId: failure.turnId.isNotEmpty ? failure.turnId : ended,
      ),
    );
    _historyLiveItems?[id] = _items.last;
  }

  /// The host's identity of an interrupted turn's stop row
  /// (`turn.interruption`: its `interrupted` item and exact prompt), or null
  /// from a host that does not name it.
  ({String itemId, String turnId})? _interruption(String raw) {
    try {
      final m = jsonDecode(raw);
      final turn = m is Map ? m['turn'] : null;
      if (turn is! Map || turn['status'] != 'interrupted') return null;
      final stop = turn['interruption'];
      if (stop is! Map) return null;
      final item = stop['itemId'], prompt = stop['turnId'];
      if (item is! String || item.isEmpty) return null;
      return (itemId: item, turnId: prompt is String ? prompt : '');
    } catch (_) {
      return null;
    }
  }

  /// Show the stop the host named, whoever stopped the turn, under the
  /// host's own item ID: its `interrupted` row — live, in a history read
  /// or a follow page, early or late — is then the same row, never a second.
  /// An Esc undo still shows none. Call inside a `_updateState`.
  void _showStop(({String itemId, String turnId}) stop) {
    _pendingInterrupt = false;
    if (_suppressStopMarker) {
      _suppressStopMarker = false;
      return;
    }
    if (_itemIndex.containsKey(stop.itemId)) return;
    _itemIndex[stop.itemId] = _items.length;
    _items.add(
      TranscriptItem(id: stop.itemId, type: 'interrupted', turnId: stop.turnId),
    );
    _historyLiveItems?[stop.itemId] = _items.last;
  }

  /// A host that does not name its stop row (see [_interruption]):
  /// drop each local stopped marker whose turn the host now reports stopped
  /// itself (an `interrupted` item of the same turn), however that item
  /// arrived: live, in a history read or a follow page. Returns whether
  /// anything was dropped; the caller rebuilds what depends on the list.
  bool _dropHostedStops() {
    final hosted = {
      for (final i in _items)
        if (i.type == 'interrupted' &&
            !i.id.startsWith('local-stopped-') &&
            i.turnId.isNotEmpty)
          i.turnId,
    };
    if (hosted.isEmpty) return false;
    final before = _items.length;
    _items.removeWhere((i) {
      final drop =
          i.id.startsWith('local-stopped-') && hosted.contains(i.turnId);
      if (drop) _historyLiveItems?.remove(i.id);
      return drop;
    });
    if (_items.length == before) return false;
    _rebuildItemIndex();
    _cachedRows = null;
    return true;
  }

  /// While the next turn is awaited, a repeated terminal event of a turn
  /// this view already saw end (a recovery re-announcing it) is not the new
  /// turn's end: it must neither release the queue nor reset anything.
  bool _endsAnEndedTurn(String raw) {
    if (!_awaitingTurnStart) return false;
    final ended = _parseTurnId(raw);
    return ended != null && _endedTurns.contains(ended);
  }

  /// A turn of this view ended: remember it, stop awaiting a start, and
  /// re-read the agent's session state, which may still name it as running
  /// and so hold the controls it gates.
  void _turnEnded(String raw) {
    final ended = _parseTurnId(raw);
    if (ended != null && !_endedTurns.contains(ended)) {
      _endedTurns.add(ended);
      if (_endedTurns.length > 256) _endedTurns.removeAt(0);
    }
    _turnStartSeen();
    if (_caps.sessionConfig) _refreshAgentSettings();
    // Access read while it ran (or not read at all) may be releasable now.
    final thread = _threadId;
    if (thread != null) unawaited(_refreshWriteAccess(thread));
  }

  /// The admitted turn has not announced itself yet (see
  /// [_awaitingTurnStart]).
  void _expectTurnStart(_ComposerDraft draft, String threadId) {
    _armTurnStart(_AwaitedStart(draft: draft, threadId: threadId));
  }

  void _armTurnStart(_AwaitedStart awaited) {
    _awaitedStart = awaited;
    _turnStartTimer?.cancel();
    _turnStartTimer = Timer(_AppSessionState._turnStartGrace, () {
      if (mounted && identical(_awaitedStart, awaited)) {
        unawaited(_reconcileAwaitedStart(awaited));
      }
    });
  }

  /// Whether [awaited] is still this view's admission: the same token (a
  /// newer admission replaces it), draft and thread. A history reload of the
  /// same conversation keeps it; leaving the conversation drops it.
  bool _ownsAwaitedStart(_AwaitedStart awaited) =>
      mounted &&
      identical(_awaitedStart, awaited) &&
      identical(_draft, awaited.draft) &&
      _threadId == awaited.threadId;

  /// The admitted turn's events never arrived: reload the conversation. Only
  /// an authoritative history of this conversation from the current host
  /// connection, read after the admission, releases it (see
  /// [_resumeAndLoad]): running, the turn is shown and followed; idle, it
  /// ended unseen and the reload's completion lets the queue continue. A
  /// failed, obsolete, cached-only or display-only reload, one of a host
  /// connection lost or replaced meanwhile (the reconnect's own reload
  /// answers instead), or one overtaken by live turn events, releases
  /// nothing, and a still-owned admission is asked again after another grace
  /// period; elapsed time alone never releases it.
  Future<void> _reconcileAwaitedStart(_AwaitedStart awaited) async {
    if (!_ownsAwaitedStart(awaited)) return;
    await _resumeAndLoad();
    if (_ownsAwaitedStart(awaited)) _armTurnStart(awaited);
  }

  void _turnStartSeen() {
    _awaitedStart = null;
    _turnStartTimer?.cancel();
    _turnStartTimer = null;
  }

  /// Whether a terminal event names a turn other than the one this view
  /// tracks as running. Its items stop streaming; the running turn, its Stop
  /// target and the queue are left alone.
  bool _endsAnotherTurn(String raw) {
    final ended = _parseTurnId(raw);
    final current = _turnId;
    if (ended == null || current == null || ended == current) return false;
    _updateState(() {
      for (final it in _items) {
        if (it.turnId == ended) it.streaming = false;
      }
    });
    return true;
  }

  /// Pull the turn id out of a turn/started event's raw params, tolerating
  /// `{turnId}`, `{turn:{id}}`, or `{id}` shapes.
  String? _parseTurnId(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final direct = m['turnId'] ?? m['id'];
      if (direct is String && direct.isNotEmpty) return direct;
      final turn = m['turn'];
      if (turn is Map && turn['id'] is String) return turn['id'] as String;
    } catch (_) {}
    return null;
  }

  /// Whether [turn] is known to have ended: it is not the turn running here,
  /// and this view saw its end or holds history the server stamped with its
  /// completion. A turn with neither may only not have announced its start.
  bool _endedHere(String? turn) {
    if (turn == null || turn.isEmpty) return false;
    if (_streaming && (_turnId == null || _turnId == turn)) return false;
    return _endedTurns.contains(turn) ||
        _items.any((it) => it.turnId == turn && it.turnCompletedAt != null);
  }

  /// Where a step that completed after its [turn] ended belongs: after that
  /// turn's last step, ahead of its answer and what is shown after it, so the
  /// answer stays last. Null (append) for a message or a row that stands
  /// alone, and when the view holds nothing of that turn.
  int? _lateItemSlot(TranscriptItem item, String turn) {
    if (item.isMessage || item.standsAlone) return null;
    final last = _items.lastIndexWhere((it) => it.turnId == turn);
    if (last < 0) return null;
    var at = last + 1;
    while (at > 0 &&
        _items[at - 1].turnId == turn &&
        (_items[at - 1].isAgent || _items[at - 1].standsAlone)) {
      at--;
    }
    return at;
  }

  /// The turn an `item/*` event names by its explicit `turnId`; never an item's
  /// own `id`, which [_parseTurnId] accepts for turn events.
  String? _itemEventTurn(String raw) {
    try {
      final m = jsonDecode(raw);
      final turn = m is Map ? m['turnId'] : null;
      if (turn is String && turn.isNotEmpty) return turn;
    } catch (_) {}
    return null;
  }

  /// Upsert a tool/activity or message item from an `item/*` event.
  void _handleItemEvent(AppEvent e) {
    final id = e.itemId, type = e.itemType;
    if (id == null || type == null) return;
    // The user's own message is shown optimistically on send; ignore the
    // server echo so it isn't duplicated.
    if (type == 'userMessage') return;
    // An omission notice is state of the item it belongs to: re-sent empty,
    // the content fits again and the notice goes away (never added).
    if (type == 'contentOmitted' && (e.text ?? '').isEmpty) {
      // Keep a deletion in the live overlay even if the old snapshot has
      // not displayed this notice yet. A later nonempty event replaces it.
      _historyLiveItems?[id] = TranscriptItem(
        id: id,
        type: type,
        title: '',
        text: '',
        turnId: _parseTurnId(e.raw) ?? _turnId ?? '',
      );
      _historyPartialItems?.remove(id);
      if (_itemIndex.containsKey(id)) {
        _updateState(() {
          _items.removeAt(_itemIndex[id]!);
          _rebuildItemIndex();
        });
      }
      return;
    }
    // A turn that ended can still report on its items: a process the agent
    // left running in the background streams its output, and finally ends,
    // under the turn that started it, and history omits it until it ends.
    // For a row this view never held, its output would only add a row after
    // that turn's answer that spins for as long as the process lives; its
    // completion is kept, inside that turn ([_lateItemSlot]). While a history
    // read is in flight the view does not know yet what ended, so events then
    // are kept for the read to merge.
    String? lateTurn;
    if (!_itemIndex.containsKey(id) && _historyLiveItems == null) {
      final itemTurn = _itemEventTurn(e.raw);
      if (_endedHere(itemTurn)) {
        if (e.kind != 'item/completed') return;
        lateTurn = itemTurn;
      }
    }
    final kind = e.kind.toLowerCase();
    // v2 mixes `.../delta` and `.../outputDelta` casing. Progress and patch
    // snapshots are also mid-flight updates even though their names do not say
    // "started". Treat all of them as active so richer tool rows keep their
    // spinner until the eventual item/completed snapshot arrives.
    final isDelta = kind.contains('delta');
    final running =
        kind.contains('started') ||
        isDelta ||
        kind.endsWith('/progress') ||
        kind.endsWith('/patchupdated');
    _updateState(() {
      // Any agent-side item (reasoning, a tool call, or reply text) means the
      // turn has begun producing output: past this point Esc interrupts rather
      // than undoing the send.
      _outputStarted = true;
      final idx = _itemIndex[id];
      // A pre-existing row can also have missed deltas while disconnected.
      // Only a full snapshot received during this read establishes its prefix.
      if (isDelta &&
          (idx == null || _historyLiveItems?.containsKey(id) == false)) {
        _historyPartialItems?.add(id);
      } else if (!isDelta) {
        _historyPartialItems?.remove(id);
      }
      if (idx == null) {
        final item = TranscriptItem(
          id: id,
          type: type,
          title: e.title ?? '',
          text: e.text ?? '',
          images: resolveImageUrls(e.images),
          imageUrls: e.images,
          streaming: type == 'agentMessage' ? true : running,
          // The live turn this item belongs to, so a reply that streams in as
          // several items groups the same way it will after a reload.
          turnId: _parseTurnId(e.raw) ?? _turnId ?? '',
        );
        final at = lateTurn == null ? null : _lateItemSlot(item, lateTurn);
        if (at == null) {
          _items.add(item);
          _itemIndex[id] = _items.length - 1;
        } else {
          _items.insert(at, item);
          _rebuildItemIndex();
        }
      } else {
        final it = _items[idx];
        it.type = type;
        if (it.turnId.isEmpty) it.turnId = _parseTurnId(e.raw) ?? _turnId ?? '';
        if ((e.title ?? '').isNotEmpty) it.title = e.title!;
        if (isDelta) {
          it.text += e.text ?? '';
        } else if ((e.text ?? '').isNotEmpty || !it.isAgent) {
          it.text = e.text ?? '';
        }
        if (!listEquals(it.imageUrls, e.images) &&
            (!isDelta || e.images.isNotEmpty)) {
          it.imageUrls = e.images;
          it.images = resolveImageUrls(e.images);
        }
        // Output after its turn ended updates the row without setting it
        // spinning again; its completion settles it.
        if (!it.isAgent) it.streaming = running && !_endedHere(it.turnId);
      }
      _historyLiveItems?[id] = _items[_itemIndex[id]!];
      if (type == 'interrupted') _dropHostedStops();
    });
    _scrollToEnd();
  }

  /// Begin ticking the running turn's elapsed clock once a second so the status
  /// bar counts up live. Only the labels showing it listen, so a tick costs
  /// two text repaints, never a rebuild of the conversation.
  void _startElapsedTicker() {
    _turnStartedAt = DateTime.now();
    _elapsedTicker?.cancel();
    _elapsedTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final started = _turnStartedAt;
      if (!mounted || started == null) return;
      _elapsed.value = DateTime.now().difference(started).inSeconds;
    });
  }

  /// Stop the elapsed ticker and append a per-turn duration footnote (用时 X,
  /// hover → 完成于 HH:MM:SS), stamped with the model/effort the turn actually
  /// ran with so a switch is verifiable per response. Local-only; call inside
  /// a `_updateState`.
  void _finishTurn() {
    _elapsedTicker?.cancel();
    _elapsedTicker = null;
    final started = _turnStartedAt;
    _turnStartedAt = null;
    if (started == null) return;
    final now = DateTime.now();
    final id = 'local-turndur-${_localSeq++}';
    _itemIndex[id] = _items.length;
    _items.add(
      TranscriptItem(
        id: id,
        type: 'turnDuration',
        title: _fmtElapsed(now.difference(started).inSeconds),
        text: _fmtClock(now),
        // Resolve to the display name now (the cached list can change later);
        // an unlisted id stays raw — still truthful.
        model: _modelDisplayLabel(_turnStampModel),
        effortWire: _turnStampEffort,
        modelConfirmed: _turnStampConfirmed,
        modelRerouted: _turnRerouted,
      ),
    );
    _historyLiveItems?[id] = _items.last;
  }

  /// Stopwatch-format an elapsed-second count. Shared with the turn-work fold
  /// (see [formatElapsed]) so a turn's footnote and its fold cannot disagree
  /// about how long the same turn took.
  String _fmtElapsed(int secs) => formatElapsed(secs);

  /// Wall-clock `HH:MM:SS` for a completion timestamp.
  String _fmtClock(DateTime t) {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
  }
}

/// Parse a `thread/settings/updated` notification's raw params into a
/// runtime config. The payload's `threadSettings` carries the full effective
/// snapshot: `model`, `modelProvider`, `effort`, `approvalPolicy`,
/// `sandboxPolicy` (camelCase-tagged object) and `collaborationMode`
/// (`{mode, settings}`). Null on any shape surprise — never guess.
ThreadRuntimeConfig? _parseSettingsUpdate(String raw) {
  try {
    final params = jsonDecode(raw) as Map<String, dynamic>;
    final s = params['threadSettings'];
    if (s is! Map<String, dynamic>) return null;
    String? str(Object? v) => (v is String && v.isNotEmpty) ? v : null;
    // Sandbox: `{"type": "readOnly"}` → the kebab wire string the app speaks.
    String? sandbox;
    final sp = s['sandboxPolicy'];
    final tag = sp is Map<String, dynamic> ? str(sp['type']) : str(sp);
    if (tag != null) {
      sandbox = switch (tag) {
        'readOnly' => 'read-only',
        'workspaceWrite' => 'workspace-write',
        'dangerFullAccess' => 'danger-full-access',
        'externalSandbox' => 'external-sandbox',
        _ => tag,
      };
    }
    // Approval: a plain string, or the externally-tagged granular object.
    final ap = s['approvalPolicy'];
    final approval = ap is Map<String, dynamic>
        ? (ap.keys.isEmpty ? null : ap.keys.first)
        : str(ap);
    // Collaboration mode: `{mode: "plan"|"default", …}` or a bare string.
    final cm = s['collaborationMode'];
    final collab = cm is Map<String, dynamic> ? str(cm['mode']) : str(cm);
    return ThreadRuntimeConfig(
      model: str(s['model']),
      modelProvider: str(s['modelProvider']),
      reasoningEffort: str(s['effort']),
      approvalPolicy: approval,
      approvalsReviewer: s['approvalsReviewer'] == 'guardian_subagent'
          ? 'auto_review'
          : str(s['approvalsReviewer']),
      serviceTier: str(s['serviceTier']),
      sandboxMode: sandbox,
      collaborationMode: collab,
      confirmedByUpdate: true,
    );
  } catch (_) {
    return null;
  }
}
