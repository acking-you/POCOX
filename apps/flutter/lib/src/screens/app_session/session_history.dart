part of '../app_session_screen.dart';

extension _SessionHistory on _AppSessionState {
  /// Whether to offer the "implement this plan" choice — shown after a plan-mode
  /// turn has produced its proposal, until the user implements or steers past it.
  ///
  /// We deliberately do NOT key on a typed `plan` item: codex delivers the
  /// proposal inconsistently — sometimes a `plan` item, sometimes a plain agent
  /// message (it can even surface literal `<proposed_plan>` tags), and a re-plan
  /// after "keep planning" typically arrives as a plain message. Keying on the
  /// last `plan` item then points at a stale earlier plan with the new steering
  /// message after it, so the choice never re-appears. Instead: the thread is in
  /// plan mode (`_planActive`), no turn is running, the user hasn't dismissed,
  /// and the latest content item is the model's — i.e. the user hasn't steered
  /// since (the last non-reasoning item isn't their message). Normal multi-step
  /// turns also emit `plan` checklists but run in default mode (`_planActive`
  /// false), so they never trigger this. Derived from the timeline, so it
  /// survives leave/restart until the user acts.
  bool get _planReady {
    if (_streaming || _implementDismissed || !_planActive || _items.isEmpty) {
      return false;
    }
    for (final it in _items.reversed) {
      if (it.type == 'reasoning') continue; // trailing reasoning isn't a steer
      // A failed turn proposed nothing.
      return it.type != 'userMessage' && it.type != 'modelError';
    }
    return false;
  }

  /// Whether the host-meta snapshot says another process still has a live turn.
  bool get _externalWriterRunning =>
      _externalWriterMode &&
      const {
        'incomplete',
        'running',
      }.contains(_externalWriterLiveness?.turnState);

  /// Show the "typing" indicator while a local turn is waiting for its reply,
  /// or throughout an external writer's turn. The latter stays visible even as
  /// transcript snapshots arrive so read-only viewers can tell the feed is
  /// still live rather than looking at a static history dump.
  bool get _showTyping =>
      _externalWriterRunning ||
      (_streaming &&
          (_items.isEmpty || !_items.last.isAgent || _items.last.text.isEmpty));

  /// The newest plan snapshot for the turn that is currently running. A plan
  /// from an older turn must not reappear while a newer user request is still
  /// waiting for its own plan, so only consider plan items after the latest
  /// user message.
  TranscriptItem? get _runningPlan {
    if (!_streaming && !_externalWriterRunning) return null;
    var latestUser = -1;
    for (var i = _items.length - 1; i >= 0; i--) {
      if (_items[i].isUser) {
        latestUser = i;
        break;
      }
    }
    for (var i = _items.length - 1; i > latestUser; i--) {
      final item = _items[i];
      if (item.type == 'plan' && parsePlan(item.text).steps.isNotEmpty) {
        return item;
      }
    }
    return null;
  }

  /// The timeline collapsed for display. Computed at build time so the flat
  /// `_items` upsert path is untouched.
  ///
  /// Three collapses, in the order they apply:
  ///
  /// * A turn's prose, which arrives as several `agentMessage` items, becomes one
  ///   [AgentTurn] — one reply, one block.
  /// * Every run of consecutive activity items becomes one [TurnWork], folded
  ///   behind a duration. This is type-BLIND on purpose: a real turn alternates
  ///   command / reasoning / search, so the old same-type-only rule collapsed
  ///   nothing and left the answer buried under a wall of tool rows.
  /// * Inside a [TurnWork], same-type neighbours stay grouped (see
  ///   [TurnWork.groups]) so expanding shows "思考 ×2", not four loose rows.
  ///
  /// User messages and standalone notices are never folded.
  List<Object> get _rows {
    if (_cachedRows != null && _rowSources.length == _items.length) {
      var unchanged = true;
      for (var i = 0; i < _items.length; i++) {
        final (item, type, turn) = _rowSources[i];
        if (!identical(item, _items[i]) ||
            type != item.type ||
            turn != item.turnId) {
          unchanged = false;
          break;
        }
      }
      if (unchanged) return _cachedRows!;
    }
    _rowSources = [for (final item in _items) (item, item.type, item.turnId)];
    final rows = buildHistoryRows(
      _items,
      turns: _turnSummaries,
      windows: _turnWindows,
      sequentialIds: _sequentialHistoryIds,
    );
    final keys = rows.map(_rowKey).toSet();
    _lastWork = rows.whereType<TurnWork>().lastOrNull;
    _rowAnchors.removeWhere((key, _) => !keys.contains(key));
    _indexRows(rows);
    return _cachedRows = rows;
  }

  List<TranscriptItem> _historyItems(
    List<ThreadItem> items,
    String? activeTurnId,
  ) {
    final result = <TranscriptItem>[];
    for (final item in items) {
      if (item.itemType == 'userMessage') {
        if (isContextFragment(item.text)) continue;
        if (result.isNotEmpty &&
            result.last.isUser &&
            result.last.text.trim() == item.text.trim() &&
            listEquals(result.last.imageUrls, item.images)) {
          continue;
        }
      }
      result.add(
        _transcriptItemOf(
          item,
          activeTurnId,
          compacting:
              item.itemType == 'contextCompaction' &&
              item.title == 'inProgress',
        ),
      );
    }
    return result;
  }

  void _restoreHistoryQuestions(List<ThreadItem> items) {
    _asyncQuestions.clear();
    for (final item in items) {
      final questions = AsyncQuestionPrompt.parse(item.id, item.questionsJson);
      if (questions != null &&
          !_answeredAsyncQuestions.contains('$_threadId:${item.id}')) {
        _asyncQuestions[item.id] = questions;
      }
    }
  }

  void _installHistory(List<TranscriptItem> items) {
    _items
      ..clear()
      ..addAll(items);
    _rebuildItemIndex();
    _dropHostedStops();
    _cachedRows = null;
  }

  void _replaceTranscriptItems(List<ThreadItem> items, {String? activeTurnId}) {
    _restoreHistoryQuestions(items);
    _installHistory(_historyItems(items, activeTurnId));
  }

  /// [item] as the transcript shows it. It streams while it is a compaction
  /// in progress ([compacting]) or an image the running turn
  /// ([activeTurnId]) is still generating.
  TranscriptItem _transcriptItemOf(
    ThreadItem item,
    String? activeTurnId, {
    bool compacting = false,
  }) => TranscriptItem(
    id: item.id,
    type: item.itemType,
    title: item.title,
    text: item.text,
    diff: item.diff,
    images: resolveImageUrls(item.images),
    imageUrls: item.images,
    streaming: compacting || _generatingImage(item, activeTurnId),
    turnId: item.turnId,
    turnCompletedAt: item.turnCompletedAt,
    turnDurationMs: item.turnDurationMs,
  );

  /// Whether [item] is an image the running turn [activeTurnId] is still
  /// generating.
  bool _generatingImage(ThreadItem item, String? activeTurnId) =>
      item.itemType == 'imageGeneration' &&
      item.turnId.isNotEmpty &&
      item.turnId == activeTurnId &&
      item.turnCompletedAt == null &&
      imageGenerationInProgress(item.text);

  /// Text-only deltas mutate the same objects and need no reorder. A new row,
  /// replacement or newly assigned turn invalidates an in-flight native merge.
  List<(TranscriptItem, String)> _historyShape(
    Iterable<TranscriptItem> items,
  ) => [for (final item in items) (item, item.turnId)];

  Future<List<TranscriptItem>?> _projectHistory(
    ThreadHistory history,
    Map<String, TranscriptItem> live,
    Set<String> partial,
    bool Function() current,
  ) async {
    final api = ref.read(bridgeApiProvider);
    var base = _historyItems(history.items, history.activeTurnId);
    final order = history.turns.map((turn) => turn.turnId).toList();
    for (final page in history.turnPages) {
      base = await mergeHistoryItems(
        api,
        base,
        _historyItems(page.items, history.activeTurnId),
        turnOrder: order,
        olderPage: true,
      );
      if (!current()) return null;
    }
    while (current()) {
      final overlay = live.values.toList();
      final incomplete = Set.of(partial);
      final byId = {for (final item in base) item.id: item};
      for (final item in overlay) {
        final snapshot = byId[item.id];
        if (snapshot == null || incomplete.contains(item.id)) continue;
        if (item.turnId.isEmpty) item.turnId = snapshot.turnId;
        item.turnCompletedAt ??= snapshot.turnCompletedAt;
        item.turnDurationMs ??= snapshot.turnDurationMs;
        byId[item.id] = item;
      }
      final shape = _historyShape(overlay);
      final merged = await mergeHistoryItems(
        api,
        [for (final item in base) byId[item.id]!],
        overlay,
        turnOrder: order,
        olderPage: false,
      );
      if (!current()) return null;
      if (!listEquals(shape, _historyShape(live.values)) ||
          !setEquals(incomplete, partial)) {
        continue;
      }
      return merged
          .where(
            (item) => item.type != 'contentOmitted' || item.text.isNotEmpty,
          )
          .toList();
    }
    return null;
  }

  /// Drop optimistic user messages (`local-user-*`) that [items], read from
  /// the host, newly hold under the same turn: each host user message not
  /// shown yet confirms the earliest local copy of its turn. One already
  /// shown confirms nothing, so a repeated read drops nothing more and an
  /// unconfirmed local copy stays. Identity is the turn and the host's item
  /// id, never the text, so a repeated message stays. Call before splicing
  /// [items].
  void _dropHostHeldLocalPrompts(List<ThreadItem> items) {
    final held = <String, int>{};
    final seen = <String>{};
    for (final item in items) {
      if (item.itemType != 'userMessage' ||
          item.turnId.isEmpty ||
          item.id.isEmpty ||
          // Never shown, so it would confirm again on every read.
          isContextFragment(item.text) ||
          _itemIndex.containsKey(item.id) ||
          !seen.add(item.id)) {
        continue;
      }
      held.update(item.turnId, (n) => n + 1, ifAbsent: () => 1);
    }
    if (held.isEmpty) return;
    final before = _items.length;
    _items.removeWhere((item) {
      if (!item.isUser || !item.id.startsWith('local-user-')) return false;
      final left = held[item.turnId] ?? 0;
      if (left == 0) return false;
      held[item.turnId] = left - 1;
      return true;
    });
    if (_items.length == before) return;
    _rebuildItemIndex();
    _cachedRows = null;
  }

  /// Resolve a page against the latest live identities without copying bodies
  /// to Rust. Re-run only when ordering changed during the worker's await.
  Future<List<TranscriptItem>?> _projectSplice(
    List<ThreadItem> items, {
    required bool atStart,
    required bool Function() current,
    String? activeTurnId,
    List<String>? turnOrder,
    bool replace = false,
    bool refresh = false,
  }) async {
    final api = ref.read(bridgeApiProvider);
    while (current()) {
      final shape = _historyShape(_items);
      final existing = replace ? <TranscriptItem>[] : List.of(_items);
      final byId = {for (final item in existing) item.id: item};
      final fresh = _historyItems(
        items,
        activeTurnId,
      ).where((item) => item.id.isNotEmpty).toList();
      if (refresh) {
        final refreshed = {for (final item in fresh) item.id: item};
        for (var i = 0; i < existing.length; i++) {
          final old = existing[i];
          final next = refreshed[old.id];
          if (next != null) {
            next
              ..held = old.held
              ..model = old.model
              ..effortWire = old.effortWire
              ..modelConfirmed = old.modelConfirmed
              ..modelRerouted = old.modelRerouted;
            existing[i] = next;
          }
        }
      }
      final merged = await mergeHistoryItems(
        api,
        existing,
        [for (final item in fresh) refresh ? item : byId[item.id] ?? item],
        turnOrder: turnOrder ?? _turnSummaries.map((turn) => turn.turnId),
        olderPage: atStart,
      );
      if (!current()) return null;
      if (!listEquals(shape, _historyShape(_items))) continue;
      return merged;
    }
    return null;
  }

  /// Fetch the page of history before what's shown, keeping the reading
  /// position: the list corrects its own offset when content is prepended.
  Future<void> _loadOlder({bool reveal = false}) async {
    if (_loadingOlder || !_hasOlder || _threadId == null) return;
    await _startHistoryLoad(fromTop: true, reveal: reveal);
  }

  bool get _startsAtBeginning {
    if (!_hasOlder) return true;
    if (_firstTurnId == null ||
        _items.isEmpty ||
        _turnSummaries.firstOrNull?.turnId != _firstTurnId) {
      return false;
    }
    final first = _turnSummaries.indexWhere(
      (turn) => turn.turnId == _items.first.turnId,
    );
    if (first < 0) return false;
    for (var i = 0; i < first; i++) {
      if (!_isEmptyLoadedTurn(_turnSummaries[i].turnId)) return false;
    }
    final id = _items.first.turnId;
    return _turnWindows.containsKey(id) ||
        _items.any((item) => item.turnId == id && item.isUser);
  }

  bool _isEmptyLoadedTurn(String turnId) {
    final window = _turnWindows[turnId];
    return window != null && window.items.isEmpty && !window.hasMore;
  }

  Future<void> _loadAtTop({bool reveal = false}) async {
    if (_loadingOlder || _startsAtBeginning) return;
    if (_turnWindows.isNotEmpty && _items.isNotEmpty) {
      final first = _turnSummaries.indexWhere(
        (turn) => turn.turnId == _items.first.turnId,
      );
      var previous = first - 1;
      while (previous >= 0 &&
          _isEmptyLoadedTurn(_turnSummaries[previous].turnId)) {
        previous--;
      }
      if (previous >= 0) {
        await _loadTurn(
          _turnSummaries[previous].turnId,
          fromTop: true,
          reveal: reveal,
        );
        return;
      }
    }
    await _loadOlder(reveal: reveal);
  }

  Future<void> _loadGap(HistoryGap gap, {bool reveal = false}) async {
    if (_loadingOlder || _threadId == null) return;
    await _startHistoryLoad(
      turnId: gap.turnId,
      loadMore: gap.continuation,
      reveal: reveal,
    );
  }

  /// Fetch one turn's items, for jumping to a turn not yet scrolled back to.
  Future<void> _loadTurn(
    String turnId, {
    bool fromTop = false,
    int? navigation,
    bool reveal = false,
  }) async {
    final generation = _historyGeneration;
    while (_historyLoad != null) {
      await _historyLoad;
      if (!mounted ||
          _historyGeneration != generation ||
          (navigation != null && navigation != _turnNavigation)) {
        return;
      }
    }
    if (turnId.isEmpty || _threadId == null || _fetchedTurns.contains(turnId)) {
      return;
    }
    // A tail-only page may have marked the turn loaded without its user row.
    if (_items.any((item) => item.turnId == turnId && item.isUser)) return;
    await _startHistoryLoad(turnId: turnId, fromTop: fromTop, reveal: reveal);
  }

  Future<void> _startHistoryLoad({
    String? turnId,
    bool loadMore = false,
    bool fromTop = false,
    bool reveal = false,
  }) {
    _historyError = false;
    _historyTarget = (turnId, loadMore);
    _historyFromTop = fromTop;
    // The fetch is in flight before anything can throw, and only it clears
    // its own mark once it has finished: a rebuild that could not be
    // scheduled, or a fetch that failed at once, never leaves "loading" with
    // nothing loading or a finished load still marked.
    late final Future<void> load;
    load =
        _fetchHistory(
          _threadId!,
          _historyGeneration,
          turnId,
          loadMore,
          reveal,
          _scrollIntent,
          _turnNavigation,
        ).whenComplete(() {
          if (mounted && identical(_historyLoad, load)) {
            _updateState(() {
              _historyLoad = null;
            });
          }
        });
    _updateState(() {
      _historyLoad = load;
    });
    return load;
  }

  Future<void> _fetchHistory(
    String tid,
    int generation,
    String? turnId,
    bool loadMore,
    bool reveal,
    int intent,
    int navigation,
  ) async {
    bool current() => mounted && _historyGeneration == generation;
    try {
      final api = ref.read(bridgeApiProvider);
      final older = turnId == null
          ? await api.appThreadOlderPage(widget.serviceKey, tid)
          : null;
      var turn = turnId == null
          ? null
          : await api.appThreadTurnPage(
              widget.serviceKey,
              tid,
              turnId,
              loadMore: loadMore,
            );
      if (!current()) return;
      final items = older?.items ?? turn!.items;
      final arrived = items
          .where((item) => !_itemIndex.containsKey(item.id))
          .map((item) => item.id)
          .toSet();
      if (turn != null && loadMore) {
        final prefix = _turnWindows[turnId]?.items ?? const <ThreadItem>[];
        final known = prefix.map((item) => item.id).toSet();
        turn = TurnItemsPage(
          turnId: turn.turnId,
          items: [...prefix, ...turn.items.where((item) => known.add(item.id))],
          hasMore: turn.hasMore,
        );
      }
      final projected = await _projectSplice(
        items,
        atStart: !(turn != null && loadMore),
        current: current,
      );
      if (projected == null || !current()) return;
      final anchor = _captureHistoryAnchor();
      _updateState(() {
        // A continuation is the later part of a turn already showing its
        // start; everything else reads backwards.
        _installHistory(projected);
        if (turnId == null) {
          _hasOlder = older!.hasOlder;
          _sequentialHistoryIds.addAll(items.map((item) => item.id));
        } else {
          _fetchedTurns.add(turnId);
          _turnWindows[turnId] = turn!;
        }
        _cachedRows = null;
        _markTurnsLoaded();
      });
      // Explicit load -> reveal the first new row; passive paging -> keep the
      // current anchor. A new scroll/navigation intent always wins over either.
      if (reveal && intent == _scrollIntent && navigation == _turnNavigation) {
        final rowIndex = _rows.indexWhere(
          (row) => _rowItems(row).any((item) => arrived.contains(item.id)),
        );
        if (rowIndex >= 0) {
          final arrival = _historyArrivalRevision + 1;
          _updateState(() {
            _historyArrivalRow = _rowKey(_rows[rowIndex]);
            _historyArrivalRevision = arrival;
          });
          // The highlight plays once: a row scrolled away and back is the
          // same history, not a new arrival (no rebuild needed to forget it).
          Timer(const Duration(milliseconds: 1600), () {
            if (_historyArrivalRevision == arrival) _historyArrivalRow = null;
          });
          _scrollToRow(rowIndex);
        }
        if (mounted && current() && navigation == _turnNavigation) {
          final l10n = AppLocalizations.of(context);
          showToast(
            context,
            arrived.isEmpty
                ? l10n.historyAlreadyVisible
                : l10n.historyLoaded(arrived.length),
          );
        }
      } else if (anchor != null) {
        _restoreHistoryAnchor(anchor, generation);
      }
    } catch (_) {
      if (current()) _updateState(() => _historyError = true);
    }
  }

  GlobalKey _anchorKey(Object row) =>
      _rowAnchors.putIfAbsent(_rowKey(row), GlobalKey.new);

  /// A turn is navigable once its opening user row is present.
  void _markTurnsLoaded() {
    final arrived = _items.where((i) => i.isUser).map((i) => i.turnId).toSet();
    if (arrived.isEmpty) return;
    _turnSummaries = [
      for (final turn in _turnSummaries)
        arrived.contains(turn.turnId) && !turn.loaded
            ? TurnSummary(
                turnId: turn.turnId,
                userText: turn.userText,
                assistantText: turn.assistantText,
                loaded: true,
              )
            : turn,
    ];
  }
}
