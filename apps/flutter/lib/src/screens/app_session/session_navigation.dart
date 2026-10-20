part of '../app_session_screen.dart';

extension _SessionNavigation on _AppSessionState {
  // Track whether we're pinned to the bottom so streaming auto-follows only
  // when the user hasn't scrolled up to read earlier messages.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final atBottom = position.pixels >= position.maxScrollExtent - 80;
    if (atBottom != _atBottom) _updateState(() => _atBottom = atBottom);
    // Anything that moved the offset off the end (a drag, the wheel, the
    // keyboard, the scrollbar) lets go of it; layout holds it otherwise.
    if (_scroll.stickToEnd && position.pixels < position.maxScrollExtent - 1) {
      _scroll.stickToEnd = false;
    }
    // Publish the visible rows for the turn minimap. Straight onto the notifier
    // — no _updateState — so a scroll frame repaints ticks, not the transcript.
    final range = _visibleRowRange();
    _visibleRows.value = range;
    // Reading towards history not loaded yet fetches it. Only user scrolling
    // triggers this; a jump reads what lies above its target itself.
    if (position.userScrollDirection != ScrollDirection.idle &&
        !_loadingOlder &&
        !_historyError) {
      final rows = _rows;
      if (range != null) {
        // A couple of rows beyond the screen, so the gap is usually filled
        // before the reader reaches it.
        for (
          var i = math.max(0, range.$1 - 2);
          i <= math.min(range.$2 + 2, rows.length - 1);
          i++
        ) {
          if (rows[i] case final HistoryGap gap) {
            _loadGap(gap);
            return;
          }
        }
      }
      // Prefetch while the reader still has a screen or so of history above
      // them, so the next page is usually in place before they reach the top
      // and the "load older" row is never something they have to press. It
      // lands above them without moving anything on screen.
      final prefetchBand = math.max(600.0, position.viewportDimension * 1.5);
      final nearTop =
          position.pixels <= position.minScrollExtent + prefetchBand ||
          (range != null && range.$1 <= 3);
      if (!_startsAtBeginning &&
          position.userScrollDirection == ScrollDirection.forward &&
          nearTop) {
        _loadAtTop();
      }
    }
  }

  void _repinForKeyboard() {
    if (isDesktop || !_inputFocus.hasFocus || !_atBottom) return;
    _scrollToEnd(force: true);
  }

  /// Jump the transcript to the previous ([next] false) or next ([next] true)
  /// conversation turn — i.e. the nearest user message above/below the current
  /// viewport top — placing it at the top so its whole exchange is in view.
  /// User messages are never grouped, so each is its own row.
  void _gotoAdjacentTurn({required bool next}) {
    if (!_scroll.hasClients) return;
    final rows = _rows;
    final turns = _turnMinimapItems(rows);
    if (rows.isEmpty || turns.isEmpty) return;
    final anchor = _visibleRowRange()?.$1 ?? 0;
    final visibleTurn = _rowItems(
      rows[anchor.clamp(0, rows.length - 1)],
    ).firstOrNull?.turnId;
    var current = turns.indexWhere((turn) => turn.turnId == visibleTurn);
    if (current < 0) {
      current = turns.lastIndexWhere(
        (turn) => turn.rowIndex >= 0 && turn.rowIndex <= anchor,
      );
    }
    if (current < 0) return;
    final entry = turns[current];
    final target = next
        ? current + 1
        : entry.rowIndex < 0 || entry.rowIndex < anchor
        ? current
        : current - 1;
    if (target >= 0 && target < turns.length) {
      _selectTurn(turns[target]);
    } else if (!next) {
      _loadAtTop(reveal: true);
    }
  }

  Iterable<TranscriptItem> _rowItems(Object row) => switch (row) {
    TranscriptItem() => [row],
    TurnWork() => row.items,
    ActivityGroup() => row.items,
    AgentTurn() => row.items,
    _ => const [],
  };

  /// One minimap entry per turn: the user's message, and how the turn answered.
  ///
  /// When the server enumerated the thread's turns, every one of them gets a
  /// tick — including turns whose items aren't loaded, which the rail is meant
  /// to show because it represents the whole conversation's shape. Loaded turns
  /// resolve to their real row so selecting one scrolls; the rest carry a
  /// `rowIndex` of -1 and are fetched on selection.
  List<TurnMinimapItem> _turnMinimapItems(List<Object> rows) {
    final locale = Localizations.localeOf(context);
    if (_minimapLocale == locale &&
        identical(rows, _minimapRows) &&
        identical(_turnSummaries, _minimapTurns) &&
        identical(_items.lastOrNull?.text, _minimapLastText)) {
      return _minimapEntries;
    }
    _minimapLocale = locale;
    _minimapRows = rows;
    _minimapTurns = _turnSummaries;
    _minimapLastText = _items.lastOrNull?.text;
    return _minimapEntries = _buildTurnMinimapItems(rows);
  }

  String _requestPreview(String text) {
    final request = ApprovalReviewRequest.parse(text);
    return request == null
        ? previewWithoutFileRefs(text, '')
        : '${request.tool} · ${request.summary}';
  }

  String _replyPreview(String text) {
    final result = ApprovalReviewResult.parse(text);
    if (result == null) return _collapseWhitespace(text);
    final l10n = AppLocalizations.of(context);
    return _collapseWhitespace(
      '${result.outcome == 'allow' ? l10n.reviewAllowed : l10n.reviewDenied} · ${result.rationale}',
    );
  }

  List<TurnMinimapItem> _buildTurnMinimapItems(List<Object> rows) {
    if (_turnSummaries.isEmpty) return _turnMinimapItemsFromRows(rows);
    // Where each loaded turn's user message ended up among the rows.
    final rowOfTurn = <String, int>{};
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row is TranscriptItem && row.isUser) {
        rowOfTurn.putIfAbsent(row.turnId, () => i);
      }
    }
    final out = <TurnMinimapItem>[];
    for (final turn in _turnSummaries) {
      final row = rowOfTurn[turn.turnId];
      final user = _collapseWhitespace(_requestPreview(turn.userText));
      // A loaded turn's reply comes from the rows, which carry the whole turn;
      // the skeleton's own summary answers for turns not scrolled back to.
      final reply = row != null
          ? _finalReplyAfter(rows, row)
          : (_collapseWhitespace(turn.assistantText).isEmpty
                ? null
                : _replyPreview(turn.assistantText));
      out.add(
        TurnMinimapItem(
          rowIndex: row ?? -1,
          turnId: turn.turnId,
          userText: user,
          assistantText: reply,
        ),
      );
    }
    final snapshotIds = _turnSummaries.map((turn) => turn.turnId).toSet();
    out.addAll(
      _turnMinimapItemsFromRows(rows).where(
        (turn) => turn.turnId.isEmpty || !snapshotIds.contains(turn.turnId),
      ),
    );
    return out;
  }

  /// A row saying history continues above, which doubles as the loading state
  /// while the previous page is in flight.
  ///
  /// Tappable as well as scroll-triggered: when the loaded page is shorter than
  /// the viewport there is nothing to scroll, so reaching the top by scrolling
  /// is impossible and this row is the only way back.
  Widget _olderHistoryHeader(AppLocalizations l10n) => SizedBox(
    key: const ValueKey('history-header'),
    height: isDesktop ? 36 : 44,
    child: Center(
      child: _startsAtBeginning
          ? Text(
              l10n.historyStart,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          : SizedBox(
              key: const Key('chat-older-history'),
              child: _historyAction(
                key: _loadingOlder
                    ? null
                    : const Key('chat-older-history-load'),
                loading: _loadingOlder && _historyFromTop,
                failed: _historyError && _historyFromTop,
                icon: AppIcons.history_rounded,
                iconSize: 16,
                label: l10n.olderHistoryHint,
                onPressed: _loadingOlder
                    ? null
                    : () => _loadAtTop(reveal: true),
              ),
            ),
    ),
  );

  /// A quiet history action: loading, a retry after a failure, or [label]
  /// with its [icon].
  Widget _historyAction({
    Key? key,
    required bool loading,
    required bool failed,
    required IconData icon,
    required double iconSize,
    required String label,
    required VoidCallback? onPressed,
  }) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return TextButton.icon(
      key: key,
      style: TextButton.styleFrom(
        foregroundColor: theme.colorScheme.onSurfaceVariant,
        textStyle: theme.textTheme.labelSmall,
      ),
      onPressed: onPressed,
      icon: loading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(failed ? AppIcons.refresh_rounded : icon, size: iconSize),
      label: Text(
        loading
            ? l10n.historyLoading
            : failed
            ? l10n.historyRetry
            : label,
      ),
    );
  }

  Key _rowKey(Object row) => ValueKey(switch (row) {
    TurnWork() => 'w:${row.items.first.id}',
    ActivityGroup() => 'g:${row.items.first.id}',
    AgentTurn() => 't:${row.items.first.id}',
    TranscriptItem() => row.id,
    HistoryGap() => 'gap:${row.turnId}:${row.continuation}',
    _ => throw StateError('Unknown transcript row'),
  });

  /// Jump to a turn the rail selected, fetching it first when the transcript
  /// hasn't loaded it yet.
  Future<void> _selectTurn(TurnMinimapItem item) async {
    final navigation = ++_turnNavigation;
    final generation = _historyGeneration;
    if (item.rowIndex >= 0) {
      _updateState(() {
        _navigatingTurn = null;
        _navigationLoading = false;
      });
      _scrollToRow(item.rowIndex);
      return;
    }
    _updateState(() {
      _navigatingTurn = item;
      _navigationLoading = true;
    });
    // Keep the current reading position until the latest target is ready.
    await _loadTurn(item.turnId, navigation: navigation);
    if (!mounted ||
        _historyGeneration != generation ||
        navigation != _turnNavigation) {
      return;
    }
    // Its row exists now that its items are in; re-derive to find where.
    final row = _turnMinimapItems(
      _rows,
    ).where((entry) => entry.turnId == item.turnId).firstOrNull;
    _updateState(() {
      _navigationLoading = false;
      if (row != null && row.rowIndex >= 0) _navigatingTurn = null;
    });
    if (row != null && row.rowIndex >= 0) _scrollToRow(row.rowIndex);
  }

  Future<void> _openTurnOutline() async {
    final items = _turnMinimapItems(_rows);
    final visible = _visibleRowRange()?.$1 ?? 0;
    var current = 0;
    for (var i = 0; i < items.length; i++) {
      if (items[i].rowIndex >= 0 && items[i].rowIndex <= visible) current = i;
    }
    final generation = _historyGeneration;
    final item = await showTurnOutline(context, items: items, current: current);
    if (mounted && generation == _historyGeneration && item != null) {
      // Rows can shift while the outline is open; resolve the stable identity.
      final target = _turnMinimapItems(_rows)
          .where(
            (entry) => item.messageId.isNotEmpty
                ? entry.messageId == item.messageId
                : entry.turnId == item.turnId,
          )
          .firstOrNull;
      if (target != null) await _selectTurn(target);
    }
  }

  /// Rail entries derived from the loaded rows alone — the shape for a thread
  /// whose history arrived whole, so the rows already cover every turn.
  List<TurnMinimapItem> _turnMinimapItemsFromRows(List<Object> rows) {
    final out = <TurnMinimapItem>[];
    final seen = <String>{};
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row is! TranscriptItem || !row.isUser) continue;
      if (row.turnId.isNotEmpty && !seen.add(row.turnId)) continue;
      // The raw text can be wire machinery (an attachment block, an IDE context
      // fragment); the same cleaner the sidebar and title bar use resolves it,
      // so all three agree on what a turn is called.
      //
      // The placeholder is passed EMPTY on purpose. A sidebar row must say
      // something, so there it becomes "[file]" — but on the rail that produced
      // a card whose headline was the word "file" above the reply, which named
      // the attachment instead of the turn. With nothing to head the card, the
      // reply speaks for the turn by itself.
      //
      // When neither half has anything to show the tick stays; it just has no
      // preview.
      out.add(
        TurnMinimapItem(
          rowIndex: i,
          turnId: row.turnId,
          messageId: row.id,
          userText: _collapseWhitespace(_requestPreview(row.text)),
          assistantText: _finalReplyAfter(rows, i),
        ),
      );
    }
    return out;
  }

  /// The last reply of the turn starting at [userRow] — its conclusion, not the
  /// preamble it opened with. Null when the turn produced no prose.
  String? _finalReplyAfter(List<Object> rows, int userRow) {
    String? last;
    for (var i = userRow + 1; i < rows.length; i++) {
      final row = rows[i];
      if (row is TranscriptItem && row.isUser) break;
      last = switch (row) {
        AgentTurn() => row.text,
        TranscriptItem(isAgent: true) => row.text,
        _ => last,
      };
    }
    final text = _replyPreview(last ?? '');
    return text.isEmpty ? null : text;
  }

  /// Flatten a message to one line, so a preview shows its opening words rather
  /// than the first line of a code block.
  String _collapseWhitespace(String text) =>
      (text.length > 600 ? text.substring(0, 600) : text)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

  /// The space beside the conversation column, which is where the turn rail
  /// lives. Zero on a window narrow enough that the column fills it.
  double _gutterWidth(double available) =>
      math.max(0, (available - _AppSessionState._kColumnWidth) / 2);

  /// How many turns the rail would have ticks for.
  ///
  /// Counts the whole thread's turns when the server enumerated them, so a long
  /// conversation gets its rail immediately instead of only after enough of it
  /// has been scrolled back into memory. Falls back to the loaded user messages
  /// for a thread that arrived whole.
  int get _turnCount {
    final ids = _turnSummaries.map((turn) => turn.turnId).toSet();
    var unknown = 0;
    for (final item in _items.where((item) => item.isUser)) {
      if (item.turnId.isEmpty) {
        unknown++;
      } else {
        ids.add(item.turnId);
      }
    }
    return ids.length + unknown;
  }

  /// Whether the gutter rail can take turn navigation over at [available] width,
  /// so the corner arrows can stand down rather than offer the same thing twice.
  ///
  /// Answered from the transcript's own laid-out width, not a MediaQuery: the
  /// conversation sits between two collapsible panes, so the window size says
  /// nothing useful about how much room it actually got.
  ///
  /// The turn count is part of the question, not just the width: the rail hides
  /// itself below [kTurnMinimapMinItems], so without this a three-turn
  /// conversation on a wide window would get NO turn navigation — the rail gone
  /// by its own rule and the arrows stood down in deference to it.
  bool _railOwnsTurnNav(double available) =>
      isDesktop &&
      _gutterWidth(available) > kTurnMinimapRailInset &&
      _turnCount >= kTurnMinimapMinItems;

  /// The turn rail, plus the corner cluster that defers to it — one layout pass
  /// for both, since the same width decides whether the rail has a gutter and
  /// therefore whether the arrows are still needed.
  Widget _turnNavOverlay() => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final rail = _railOwnsTurnNav(width);
      return Stack(
        children: [
          if (rail)
            Positioned.fill(
              child: TurnMinimap(
                items: _turnMinimapItems(_rows),
                onOpenOutline: _openTurnOutline,
                visibleRange: _visibleRows,
                gutterWidth: _gutterWidth(width),
                onSelect: _selectTurn,
              ),
            ),
          // Without the rail, the turn jumps fold into a faint handle at the
          // edge, which opens when touched. Two turns is enough for stepping
          // to mean something, a lower bar than the rail's: the arrows carry
          // a label and do not need a shape to read.
          if (!rail && _turnCount >= 2)
            Positioned.fill(
              child: DraggableNavigation(
                label: AppLocalizations.of(context).moveTurnNavigation,
                child: TurnNavigationHandle(
                  label: AppLocalizations.of(context).showTurnNavigation,
                  scroll: _scroll,
                  controls: _turnButtons(),
                ),
              ),
            ),
          // Jump-to-latest is about the conversation rather than a corner, so
          // it centres over the column, where every other chat app puts its
          // scroll-down pill.
          Positioned(
            left: 0,
            right: 0,
            bottom: 14,
            child: Center(child: _jumpToLatest()),
          ),
        ],
      );
    },
  );

  Widget _navButton(Key key, IconData icon, String tip, VoidCallback onTap) =>
      IconButton(
        key: key,
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        iconSize: 20,
        padding: const EdgeInsets.all(6),
        constraints: BoxConstraints(
          minWidth: isDesktop ? 34 : 44,
          minHeight: isDesktop ? 34 : 44,
        ),
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        onPressed: onTap,
        icon: Icon(icon),
      );

  /// The turn jumps: the outline, and a step to the previous or next turn.
  ///
  /// Where the left-gutter [TurnMinimap] carries turn navigation, it does the
  /// same job better *once there is a conversation shape to show*: the arrows
  /// can only step, one turn per click, with no sense of how many turns exist
  /// or what you will land on. They stay for the cases the rail can't serve —
  /// touch, windows too narrow to hold a gutter, and conversations short
  /// enough that a handful of ticks says less than a labelled button (see
  /// [kTurnMinimapMinItems]).
  List<Widget> _turnButtons() {
    final l10n = AppLocalizations.of(context);
    return [
      _navButton(
        const Key('nav-turn-outline'),
        AppIcons.format_list_numbered,
        l10n.conversationOutline,
        _openTurnOutline,
      ),
      _navButton(
        const Key('nav-prev-turn'),
        AppIcons.keyboard_arrow_up,
        l10n.prevTurn,
        () => _gotoAdjacentTurn(next: false),
      ),
      _navButton(
        const Key('nav-next-turn'),
        AppIcons.keyboard_arrow_down,
        l10n.nextTurn,
        () => _gotoAdjacentTurn(next: true),
      ),
    ];
  }

  /// Back to the latest message, offered while the reader is above it: a
  /// small pill of floating glass, animated while the conversation runs.
  Widget _jumpToLatest() => FloatingStatusSwitcher(
    child: _atBottom
        ? null
        : JumpToLatestButton(
            key: const ValueKey('jump-to-latest'),
            running: _streaming || _externalWriterRunning,
            onPressed: () => _scrollToEnd(force: true),
          ),
  );
}
