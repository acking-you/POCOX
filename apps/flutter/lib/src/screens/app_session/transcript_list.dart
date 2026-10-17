part of '../app_session_screen.dart';

/// Where the transcript is anchored: the row it is laid out around.
///
/// The conversation is one [CustomScrollView] whose centre sliver starts at
/// that row. Rows above it are laid out upward from it, rows from it
/// downward, so history arriving on either side of what is on screen never
/// moves it, and the end (or a jumped-to turn) is exact the moment it
/// becomes the centre — however much of the conversation has been measured.
/// A single list instead keyed its measured heights by index: every page of
/// history shifted them all, and the view lurched until they were measured
/// again.
class _TranscriptGeometry {
  _TranscriptGeometry(this.scroll) {
    scroll.tailExtent = () {
      final sliver = centerKey.currentContext?.findRenderObject();
      return sliver is RenderSliver ? sliver.geometry?.scrollExtent : null;
    };
  }

  final CenteredScrollController scroll;

  /// The rows above the centre, nearest first, then the header.
  final above = ListController();

  /// The centre row onward, then the typing indicator and the end inset.
  final below = ListController();

  /// The centre sliver; its laid-out extent ends the scroll range.
  final centerKey = GlobalKey(debugLabel: 'transcript-center');

  /// The centre row: its key, its items (which survive a regrouping that
  /// changes the key) and where it last was. Null is the first row.
  ({Key key, List<String> items, int hint})? center;

  /// Moves with [center], so both lists start afresh for the new split.
  int epoch = 0;

  /// Each row's index by key, by anchor key and by the items it shows.
  Map<Key, int> rowOfKey = const {};
  Map<Key, int> rowOfAnchor = const {};
  Map<String, int> rowOfItem = const {};

  void reset() {
    center = null;
    epoch++;
  }

  void dispose() {
    above.dispose();
    below.dispose();
  }
}

/// What the reader is looking at: the first row on screen (past a gap), its
/// top in the viewport, and the rows between it and the centre, whose
/// heights alone place it.
typedef _TranscriptAnchor = ({
  Key key,
  List<String> items,
  double top,
  List<Key> path,
});

extension _TranscriptList on _AppSessionState {
  /// Index [rows] for the lists' lookups and follow the centre row.
  void _indexRows(List<Object> rows) {
    final ofKey = <Key, int>{};
    final ofAnchor = <Key, int>{};
    final ofItem = <String, int>{};
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      ofKey[_rowKey(row)] = i;
      ofAnchor[_anchorKey(row)] = i;
      for (final item in _rowItems(row)) {
        ofItem[item.id] = i;
      }
    }
    final list = _list
      ..rowOfKey = ofKey
      ..rowOfAnchor = ofAnchor
      ..rowOfItem = ofItem;
    final center = list.center;
    if (center == null) return;
    final at = _locateRow(center.key, center.items);
    if (at == null) {
      // The centre row is gone: its old split means nothing now.
      list.epoch++;
      return;
    }
    if (at != center.hint || _rowKey(rows[at]) != center.key) {
      list.center = _centerOf(rows, at);
    }
  }

  ({Key key, List<String> items, int hint}) _centerOf(
    List<Object> rows,
    int index,
  ) => (key: _rowKey(rows[index]), items: _itemIds(rows[index]), hint: index);

  /// The ids of the items [row] shows.
  List<String> _itemIds(Object row) => [
    for (final item in _rowItems(row)) item.id,
  ];

  /// The row with [key], or else the one now showing any of [items].
  int? _locateRow(Key key, List<String> items) {
    final byKey = _list.rowOfKey[key];
    if (byKey != null) return byKey;
    for (final id in items) {
      final row = _list.rowOfItem[id];
      if (row != null) return row;
    }
    return null;
  }

  /// Index of the centre row in [rows].
  int _centerIndex(List<Object> rows) {
    final center = _list.center;
    if (center == null || rows.isEmpty) return 0;
    return (_locateRow(center.key, center.items) ?? center.hint).clamp(
      0,
      rows.length - 1,
    );
  }

  /// Make row [index] the centre, its top [top] pixels below the viewport's
  /// top. Call inside a state update, so the new split and the new offset
  /// are laid out together and nothing on screen moves in between.
  void _recenterOn(List<Object> rows, int index, double top) {
    _list
      ..center = _centerOf(rows, index)
      ..epoch += 1;
    _scroll.rebase(-top);
  }

  Widget _transcriptList(AppLocalizations l10n) {
    final rows = _rows;
    final center = _centerIndex(rows);
    final below = rows.length - center;
    final typing = _showTyping;
    final list = _list;
    Widget row(Object r) =>
        KeyedSubtree(key: _anchorKey(r), child: _transcriptRow(r));
    return CustomScrollView(
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(),
      center: list.centerKey,
      slivers: [
        SliverColumn(
          maxWidth: _AppSessionState._kColumnWidth,
          minGutter: 16,
          sliver: SuperSliverList.builder(
            key: ValueKey(('transcript-above', list.epoch)),
            listController: list.above,
            delayPopulatingCacheArea: true,
            // Growing upward: the row just above the centre first, on to the
            // conversation's start, then the header that says whether more
            // history lies above, then the top inset.
            itemCount: center + 2,
            itemBuilder: (context, i) => i < center
                ? row(rows[center - 1 - i])
                : i == center
                ? _olderHistoryHeader(l10n)
                : const SizedBox(height: 12),
            findChildIndexCallback: (key) {
              if (key == const ValueKey('history-header')) return center;
              final at = list.rowOfAnchor[key];
              return at != null && at < center ? center - 1 - at : null;
            },
            extentEstimation: (i, width) => i != null && i < center
                ? _estimateRowExtent(rows[center - 1 - i], width)
                : 44,
          ),
        ),
        SliverColumn(
          key: list.centerKey,
          maxWidth: _AppSessionState._kColumnWidth,
          minGutter: 16,
          sliver: SuperSliverList.builder(
            key: ValueKey(('transcript-below', list.epoch)),
            listController: list.below,
            delayPopulatingCacheArea: true,
            itemCount: below + (typing ? 1 : 0) + 1,
            itemBuilder: (context, i) {
              if (i < below) return row(rows[center + i]);
              if (typing && i == below) {
                return ValueListenableBuilder<int>(
                  valueListenable: _elapsed,
                  builder: (context, secs, _) => TypingIndicator(
                    key: _externalWriterRunning
                        ? const Key('chat-external-output-indicator')
                        : null,
                    elapsed: _fmtElapsed(secs),
                  ),
                );
              }
              // The end keeps clear of what floats over the transcript's foot.
              return SizedBox(height: 12 + _composerOverlay);
            },
            findChildIndexCallback: (key) {
              final at = list.rowOfAnchor[key];
              return at != null && at >= center ? at - center : null;
            },
            extentEstimation: (i, width) => i != null && i < below
                ? _estimateRowExtent(rows[center + i], width)
                : 44,
          ),
        ),
      ],
    );
  }

  /// A first guess at a row's height before it is laid out, near enough
  /// that the scrollbar does not lurch as rows are measured. Constant time:
  /// it is asked for every row whenever a list starts afresh.
  double _estimateRowExtent(Object row, double width) {
    double prose(int chars, double chrome) =>
        math.min(6000, chrome + 26 * (chars * 8 / math.max(width, 160)).ceil());
    return switch (row) {
      HistoryGap() => 44,
      TurnWork() || ActivityGroup() => 52,
      AgentTurn() => prose(
        row.items.fold(0, (n, item) => n + item.text.length),
        24,
      ),
      TranscriptItem(isUser: true) => prose(row.text.length * 4 ~/ 3, 52),
      TranscriptItem(isAgent: true) => prose(row.text.length, 24),
      _ => 72,
    };
  }

  /// The visible range in row indices, across both sides of the centre;
  /// the header, insets and typing indicator are not rows.
  (int, int)? _visibleRowRange() {
    final rows = _rows;
    if (rows.isEmpty) return null;
    final center = _centerIndex(rows);
    final below = rows.length - center;
    int? first;
    int? last;
    void see(int row) {
      first = math.min(first ?? row, row);
      last = math.max(last ?? row, row);
    }

    final above = _list.above.isAttached ? _list.above.visibleRange : null;
    if (above != null && above.$1 < center) {
      see(center - 1 - above.$1);
      see(center - 1 - math.min(above.$2, center - 1));
    }
    final shown = _list.below.isAttached ? _list.below.visibleRange : null;
    if (shown != null && shown.$1 < below) {
      see(center + shown.$1);
      see(center + math.min(shown.$2, below - 1));
    }
    final from = first;
    final to = last;
    return from == null || to == null ? null : (from, to);
  }

  /// Where [row]'s top is in the viewport, if it is laid out.
  double? _rowTop(Object row) {
    final box = _rowAnchors[_rowKey(row)]?.currentContext?.findRenderObject();
    final viewport = _scroll.hasClients
        ? _scroll.position.context.notificationContext?.findRenderObject()
        : null;
    if (box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        viewport is! RenderBox ||
        !viewport.attached) {
      return null;
    }
    return box.localToGlobal(Offset.zero, ancestor: viewport).dy;
  }

  /// The rows whose heights place row [index] relative to the centre: from
  /// the centre down to it, or from it down to the centre.
  List<Key> _pathToCenter(List<Object> rows, int index) {
    final center = _centerIndex(rows);
    final from = math.min(center, index);
    final to = math.max(center, index);
    return [for (var i = from; i <= to; i++) _rowKey(rows[i])];
  }

  /// Capture at response time, so scrolling during a slow request is
  /// respected.
  _TranscriptAnchor? _captureHistoryAnchor() {
    final rows = _rows;
    final visible = _visibleRowRange();
    if (visible == null || rows.isEmpty) return null;
    var index = visible.$1;
    while (index < rows.length - 1 && rows[index] is HistoryGap) {
      index++;
    }
    final row = rows[index];
    final top = _rowTop(row);
    if (top == null) return null;
    return (
      key: _rowKey(row),
      items: _itemIds(row),
      top: top,
      path: _pathToCenter(rows, index),
    );
  }

  /// Keep [anchor] where it was after the transcript changed.
  ///
  /// Usually there is nothing to do: what arrived lies beyond the anchor, or
  /// beyond the centre, and the lists grow away from it. When it landed
  /// between the two, the anchor becomes the centre at its old place, laid
  /// out in the same frame as the change.
  void _restoreHistoryAnchor(_TranscriptAnchor anchor, int generation) {
    if (!mounted || generation != _historyGeneration) return;
    final rows = _rows;
    final index = _locateRow(anchor.key, anchor.items);
    if (index == null) return;
    if (listEquals(_pathToCenter(rows, index), anchor.path)) return;
    _scroll.stickToEnd = false;
    _updateState(() => _recenterOn(rows, index, anchor.top));
    _syncScrollAfterLayout();
  }

  /// Refresh what follows the offset (the at-bottom flag, the rail's range)
  /// once a change of coordinates, which notifies no one, is laid out.
  void _syncScrollAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _onScroll();
    });
  }

  /// Scroll to the latest message. Auto-follow only when already pinned to the
  /// bottom (so reading earlier messages isn't interrupted); [force] overrides
  /// that (e.g. right after the user sends or taps the jump button).
  ///
  /// At the end, layout holds the offset there ([CenteredScrollController]
  /// `stickToEnd`) until the reader scrolls away, so a growing reply or a
  /// keyboard opening never shows a frame out of place.
  void _scrollToEnd({bool force = false}) {
    if (!force && !_atBottom) return;
    if (!force) {
      if (_scroll.stickToEnd) return;
      final intent = _scrollIntent;
      final generation = _historyGeneration;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            generation == _historyGeneration &&
            intent == _scrollIntent &&
            _atBottom &&
            _scroll.hasClients) {
          _scroll.stickToEnd = true;
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
      return;
    }
    _scroll.stickToEnd = true;
    final rows = _rows;
    final last = rows.lastOrNull;
    if (!_scroll.hasClients ||
        (last != null && _anchorKey(last).currentContext == null)) {
      // Where an end never laid out lies is only an estimate. Make the last
      // row the centre instead: the conversation is laid out upward from it
      // and the end is exact in this very frame, however long it is.
      if (last != null) {
        _updateState(() {
          _recenterOn(rows, rows.length - 1, 0);
          _atBottom = true;
        });
      }
    } else {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    }
    _syncScrollAfterLayout();
  }

  /// Scroll a turn's user message to the top of the viewport. Shared by the
  /// minimap and the compact prev/next buttons so both land identically.
  ///
  /// The row becomes the centre, so it lands exactly wherever it is, loaded
  /// or measured or not; the history just above it is then read ahead of the
  /// reader, who will most likely scroll back from there.
  void _scrollToRow(int index) {
    final rows = _rows;
    if (index < 0 || index >= rows.length) return;
    _scrollIntent++;
    _scroll
      ..stickToEnd = false
      ..settle();
    // The opening turn keeps the conversation's start in view above it.
    final top = index == 0 && _startsAtBeginning
        ? 12 + (isDesktop ? 36.0 : 44.0)
        : 12.0;
    final key = _rowKey(rows[index]);
    _updateState(() {
      _recenterOn(rows, index, top);
      // Until the landing is laid out and measured, it is not the end: a
      // refresh arriving meanwhile must not pull the reader back there.
      _atBottom = false;
    });
    _syncScrollAfterLayout();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loadingOlder || _historyError) return;
      final rows = _rows;
      final at = _list.rowOfKey[key];
      if (at == null) return;
      if (at > 0 && rows[at - 1] is HistoryGap) {
        _loadGap(rows[at - 1] as HistoryGap);
      } else if (at == 0 && !_startsAtBeginning) {
        _loadAtTop();
      }
    });
  }
}
