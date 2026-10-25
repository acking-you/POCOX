import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart'
    show GestureBinding, PointerScrollEvent, PointerSignalEvent, kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/widgets/turn_preview_card.dart';

/// One turn on the minimap: where to jump, and what to show while hovering it.
@immutable
class TurnMinimapItem {
  /// Creates a minimap entry.
  const TurnMinimapItem({
    required this.rowIndex,
    required this.userText,
    this.assistantText,
    this.turnId = '',
    this.messageId = '',
  });

  /// Index of this turn's user message in the transcript's row list — what the
  /// list controller is asked to scroll to. `-1` for a turn the transcript
  /// hasn't loaded: the tick still marks where the turn sits in the
  /// conversation, but there is no row to scroll to until its items arrive.
  final int rowIndex;

  /// Id of the turn, so selecting a tick whose [rowIndex] is `-1` can fetch it.
  /// Empty when the caller derived entries from rows alone.
  final String turnId;

  /// Stable user-message id for read-only transcripts that have no turn ids.
  /// Keeps the same target across snapshot refreshes and row regrouping.
  final String messageId;

  /// The user's own message, one line, whitespace already collapsed.
  final String userText;

  /// The turn's final reply, for the preview's second block. Null when the turn
  /// produced no prose (tool calls only, or still running).
  final String? assistantText;
}

/// Below this many turns the rail says nothing a scrollbar doesn't, and the
/// corner arrows are the better affordance.
///
/// The rail earns its place by showing a conversation's *shape* — how many turns
/// there are and where you sit among them. At two or three ticks there is no
/// shape to show, and what is left is a hover-only target that steps one turn at
/// a time, which is exactly what the arrows already do with a visible label and a
/// touch-sized target. So below this, the arrows come back.
const int kTurnMinimapMinItems = 4;

/// Each turn's row on the rail. The geometry, ink and timing below follow
/// ChatGPT's conversation rail, so the two read the same: a ruler with one
/// mark per turn at a fixed pitch. A conversation longer than the rail's
/// height scrolls the marks rather than packing them.
const double _kRowExtent = 10;

/// A row's pointer target: the longest mark plus the gap to the preview, so
/// moving sideways into the card never crosses onto another turn.
const double _kRowWidth = 36;

/// The rail grows with the turn count up to this share of the height, or
/// [_kMaxRailHeight], whichever is less, and scrolls past it.
const double _kRailHeightFraction = 0.7;
const double _kMaxRailHeight = 640;

/// How far the marks fade out towards an edge with more turns beyond it.
const double _kEdgeFade = 40;

/// Left inset of the rail within the gutter. Exported because the transcript
/// needs it to tell whether the gutter can hold the rail at all — with less than
/// this there is nowhere for it to sit and the corner arrows keep the job.
const double kTurnMinimapRailInset = 12;

/// Invisible tolerance around the rail ends and the preview card.
const double _kRailHitPadding = 12;
const double _kPreviewHitPadding = 8;

/// Gutter at or above which the rail simply stays visible. Narrower than this
/// there isn't room for it to rest without crowding the text, so it fades in on
/// approach instead.
const double kTurnMinimapPersistentGutter = 48;

/// Preferred width of the hover preview card, the narrowest it may shrink to
/// before it stops being worth showing, and how far it may reach past the gutter
/// over the conversation.
///
/// It has to overhang somewhat — a readable card does not fit in a 60 px margin —
/// but a card that buries the text you are scanning defeats its own purpose, so
/// the overhang is bounded and the card narrows within that budget.
const double _kPreviewWidth = 320;
const double _kMinPreviewWidth = 150;
const double _kMaxPreviewOverhang = 160;

/// A mark is a 2 px line that grows from 6 px at rest to 26 px under the
/// pointer, its three neighbours on each side following part of the way.
const double _kTickHeight = 2;
const double _kTickWidth = 6;
const double _kMaxTickWidth = 26;

double _growth(int? distance) => switch (distance) {
  0 => 1,
  1 => 0.7,
  2 => 0.4,
  3 => 0.2,
  _ => 0,
};

/// The marks' ink: at rest, for the turns on screen, and the one pointed at
/// (full strength).
const double _kRestInk = 0.28;
const double _kCurrentInk = 0.6;

/// The card waits this long on first approach, so sweeping past the rail
/// doesn't flash one; once open it follows the pointer at once, and a card
/// closed less than [_kPreviewSkipDelay] ago reopens without the wait.
const Duration _kPreviewDelay = Duration(milliseconds: 200);
const Duration _kPreviewSkipDelay = Duration(milliseconds: 300);

/// Marks change length with a quick spring; colour switches at once, so the
/// pointed-at mark is the strongest from the first frame.
const Duration _kTickMotion = Duration(milliseconds: 160);
const Curve _kTickCurve = _SampledCurve([
  0,
  0.398,
  0.682,
  0.843,
  0.925,
  0.972,
  1.004,
  1.008,
  1.003,
  1.0015,
  1,
]);

/// A left-gutter overview with one mark per turn: hover to preview, click to
/// jump, press and drag to scrub through the conversation.
///
/// This replaces a pair of prev/next arrows in the bottom-right corner. Those
/// could only step, one turn at a time, with no indication of how many turns
/// there were, where in them you currently sat, or what you would land on — so
/// finding a particular exchange in a long conversation meant clicking blind and
/// reading after each jump. The rail shows the whole conversation's shape at
/// once and makes any turn one click away.
///
/// Pointer-only and desktop-only by construction: it is a hover affordance, and
/// a 2 px tick is not a touch target. Compact layouts keep the arrows.
class TurnMinimap extends StatefulWidget {
  /// Creates the rail.
  const TurnMinimap({
    super.key,
    required this.items,
    required this.visibleRange,
    required this.gutterWidth,
    required this.onSelect,
    this.onOpenOutline,
  });

  /// The turns, in transcript order.
  final List<TurnMinimapItem> items;

  /// The transcript's currently visible row range, as `(first, last)`. Listened
  /// to rather than read so scrolling repaints only the ticks — the transcript
  /// itself must not rebuild on every scroll frame.
  final ValueListenable<(int, int)?> visibleRange;

  /// Space between the window edge and the centred conversation column. The rail
  /// lives here; when there is none it goes inert.
  final double gutterWidth;

  /// Jump to this turn.
  final ValueChanged<TurnMinimapItem> onSelect;

  /// Opens the exact, searchable index without loading transcript pages.
  final VoidCallback? onOpenOutline;

  @override
  State<TurnMinimap> createState() => _TurnMinimapState();
}

/// A primary press on the rail: a click, or a scrub once it crosses a turn.
class _Press {
  _Press(this.pointer, this.origin) : target = origin;

  final int pointer;

  /// The turn pressed, which a click selects.
  final TurnMinimapItem origin;

  /// The turn under the press now.
  TurnMinimapItem target;

  /// The last turn shown while scrubbing.
  TurnMinimapItem? shown;
  bool scrubbing = false;
}

class _TurnMinimapState extends State<TurnMinimap> {
  /// The turn the pointer, the keyboard or a press is on, or null when none
  /// is. It takes the rail's one strong mark and, while [_previewOpen], the
  /// preview card.
  int? _active;
  bool _previewOpen = false;

  /// Counts openings, so the card fades in once rather than per turn crossed.
  int _openings = 0;
  Timer? _previewDelay;

  /// Running for a moment after the card closes; see [_kPreviewSkipDelay].
  Timer? _skipDelay;

  /// Whether the pointer is anywhere over the rail, its card or its button.
  bool _hovering = false;

  /// Where the pointer rests over the marks, so a wheel turning them under a
  /// still pointer moves [_active] along.
  double? _hoverY;
  _Press? _press;
  TurnMinimapItem? _pressedCard;

  final _focus = FocusNode(debugLabel: 'turn-minimap');
  final _rail = ScrollController();
  double _railHeight = 0;

  /// The first on-screen turn the rail last scrolled into view. The rail
  /// follows the transcript only when that changes, so a reader who scrolled
  /// the marks is not pulled back on every frame.
  int? _revealed;
  bool _revealScheduled = false;
  List<int> _loadedIndices = [];

  void _indexLoadedRows() {
    _loadedIndices =
        [
          for (var i = 0; i < widget.items.length; i++)
            if (widget.items[i].rowIndex >= 0) i,
        ]..sort(
          (a, b) =>
              widget.items[a].rowIndex.compareTo(widget.items[b].rowIndex),
        );
  }

  @override
  void initState() {
    super.initState();
    _indexLoadedRows();
    widget.visibleRange.addListener(_scheduleReveal);
    _rail.addListener(_followWheel);
    _scheduleReveal();
  }

  @override
  void dispose() {
    widget.visibleRange.removeListener(_scheduleReveal);
    _previewDelay?.cancel();
    _skipDelay?.cancel();
    _rail.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(TurnMinimap old) {
    super.didUpdateWidget(old);
    if (!identical(old.visibleRange, widget.visibleRange)) {
      old.visibleRange.removeListener(_scheduleReveal);
      widget.visibleRange.addListener(_scheduleReveal);
    }
    if (identical(old.items, widget.items)) return;
    _indexLoadedRows();
    _scheduleReveal();
    final active = _active;
    if (active == null) return;
    final item = old.items.elementAtOrNull(active);
    if (item != null && (item.turnId.isNotEmpty || item.messageId.isNotEmpty)) {
      final index = _indexOf(item);
      _active = index < 0 ? null : index;
    } else {
      // A turn was removed (a rewind, a reload) — an index past the end would
      // otherwise resolve to nothing and leave a stuck preview.
      _active = _clampIndex(active);
    }
    if (_active == null) _previewOpen = false;
  }

  /// [index] pulled back inside the current turn list, or null when there are no
  /// turns left to point at.
  int? _clampIndex(int? index) {
    if (index == null || index < widget.items.length) return index;
    return widget.items.isEmpty ? null : widget.items.length - 1;
  }

  /// Where the rail sits: [kTurnMinimapRailInset] from the window's left edge,
  /// whatever the gutter is doing.
  ///
  /// It used to be placed relative to the conversation column instead, hugging
  /// its left edge — which tracked the column outward as the window widened and
  /// left the rail floating in the middle of empty margin. This is an index of
  /// the whole conversation, so it belongs at the frame where a scrollbar would
  /// be, not attached to the prose.
  double get _railLeft => kTurnMinimapRailInset;

  /// Width of the pointer target: a row, or what the gutter leaves of one.
  /// Zero (inert) when the gutter can't hold it.
  ///
  /// The cap is what keeps the target off the text: the column is centred, so a
  /// target that grew with the gutter would eventually reach under the prose and
  /// swallow clicks meant for it.
  double get _hitWidth => math.max(
    0,
    math.min(_kRowWidth, widget.gutterWidth.floorToDouble() - _railLeft),
  );

  bool get _persistent => widget.gutterWidth >= kTurnMinimapPersistentGutter;

  double get _railOffset => _rail.hasClients ? _rail.offset : 0;

  /// The turn whose row is at [y], measured from the top of the visible rail.
  ///
  /// [y] is held inside the rail: the padded ends, and a press drifting past
  /// them, read the turn at that edge.
  int? _indexAt(double y) {
    final count = widget.items.length;
    if (count == 0) return null;
    final inside = y.clamp(0.0, math.max(0.0, _railHeight - 1));
    return ((inside + _railOffset) / _kRowExtent).floor().clamp(0, count - 1);
  }

  /// The turns on screen, as a `(first, last)` span of rail indices: from the
  /// one containing the viewport's first row, even when its user message has
  /// scrolled offscreen, to the one containing its last. Unloaded turns have
  /// no row to compare against.
  (int, int)? _currentSpan((int, int)? range) {
    if (range == null || _loadedIndices.isEmpty) return null;
    final first =
        _turnAtRow(range.$1) ??
        (widget.items[_loadedIndices.first].rowIndex <= range.$2
            ? _loadedIndices.first
            : null);
    if (first == null) return null;
    final last = _turnAtRow(range.$2) ?? first;
    return (math.min(first, last), math.max(first, last));
  }

  /// The loaded turn whose user message is the last at or above [row].
  int? _turnAtRow(int row) {
    var low = 0;
    var high = _loadedIndices.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (widget.items[_loadedIndices[middle]].rowIndex <= row) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low > 0 ? _loadedIndices[low - 1] : null;
  }

  int _indexOf(TurnMinimapItem item) => widget.items.indexWhere((entry) {
    if (item.messageId.isNotEmpty) return entry.messageId == item.messageId;
    if (item.turnId.isNotEmpty) return entry.turnId == item.turnId;
    return identical(entry, item);
  });

  /// Jump to [item] as it stands in the latest list: monitoring can shift rows
  /// between a press and its release.
  void _select(TurnMinimapItem item) {
    final index = _indexOf(item);
    if (index >= 0) widget.onSelect(widget.items[index]);
  }

  /// Point at turn [index], or at nothing. The marks answer at once; the card
  /// opens [now] or after [_kPreviewDelay] unless one is already showing.
  void _point(int? index, {bool now = false}) {
    if (index == null) return _close();
    final open = _previewOpen || now || _skipDelay != null;
    if (index == _active && open == _previewOpen) return;
    setState(() {
      _active = index;
      if (open && !_previewOpen) {
        _previewOpen = true;
        _openings++;
      }
    });
    if (_previewOpen) {
      _previewDelay?.cancel();
      _previewDelay = null;
      return;
    }
    _previewDelay ??= Timer(_kPreviewDelay, () {
      _previewDelay = null;
      if (!mounted || _active == null) return;
      setState(() {
        _previewOpen = true;
        _openings++;
      });
    });
  }

  void _close() {
    _previewDelay?.cancel();
    _previewDelay = null;
    if (_previewOpen) {
      _skipDelay?.cancel();
      _skipDelay = Timer(_kPreviewSkipDelay, () => _skipDelay = null);
    }
    if (_active == null && !_previewOpen) return;
    setState(() {
      _active = null;
      _previewOpen = false;
    });
  }

  void _hoverAt(double y) {
    _hoverY = y;
    if (_press == null) _point(_indexAt(y));
  }

  void _followWheel() {
    final y = _hoverY;
    if (y != null && _press == null) _point(_indexAt(y));
  }

  /// Keep the first turn on screen in view on the rail, after the frame so a
  /// scroll published mid-layout never moves the marks during it.
  void _scheduleReveal() {
    if (_revealScheduled) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      // A rail under the pointer holds still: the reader is driving it, and a
      // click near an edge must not slide the marks out from under them.
      if (!mounted || _hovering || _press != null) return;
      final first = _currentSpan(widget.visibleRange.value)?.$1;
      if (first == null || first == _revealed) return;
      _revealed = first;
      _reveal(first);
    });
  }

  /// Scroll the marks the least that brings turn [index] clear of the edge
  /// fades.
  void _reveal(int index) {
    if (!_rail.hasClients) return;
    final position = _rail.position;
    final view = position.viewportDimension;
    final margin = math.max(
      0.0,
      math.min(_kEdgeFade, (view - _kRowExtent) / 2),
    );
    final top = index * _kRowExtent - margin;
    final bottom = (index + 1) * _kRowExtent + margin;
    var offset = position.pixels;
    if (top < offset) {
      offset = top;
    } else if (bottom > offset + view) {
      offset = bottom - view;
    }
    offset = offset.clamp(position.minScrollExtent, position.maxScrollExtent);
    if (offset != position.pixels) _rail.jumpTo(offset);
  }

  void _onPointerDown(PointerDownEvent event, double y) {
    if (event.buttons != kPrimaryButton || _press != null) return;
    final index = _indexAt(y);
    if (index == null) return;
    _press = _Press(event.pointer, widget.items[index]);
    _point(index, now: true);
  }

  void _onPointerMove(PointerMoveEvent event, double y) {
    final press = _press;
    if (press == null || press.pointer != event.pointer) return;
    // Only the pointer's height counts: drifting sideways or past an end
    // keeps scrubbing rather than dropping the press.
    final index = _indexAt(y);
    if (index == null || index == _active) return;
    final item = widget.items[index];
    press
      ..scrubbing = true
      ..target = item;
    _point(index, now: true);
    // A loaded turn is shown as the press crosses it. One not loaded yet is
    // fetched only if the press ends there, so a sweep never queues pages.
    if (item.rowIndex >= 0) {
      press.shown = item;
      widget.onSelect(item);
    }
  }

  void _onPointerUp(PointerUpEvent event, {required bool inside}) {
    final press = _press;
    if (press == null || press.pointer != event.pointer) return;
    _press = null;
    if (!press.scrubbing) {
      // Released off the rail, the click was let go of.
      if (inside) _select(press.origin);
    } else {
      setState(() {});
      if (!identical(press.target, press.shown)) _select(press.target);
    }
    if (!_hovering) _close();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    final press = _press;
    if (press == null || press.pointer != event.pointer) return;
    _press = null;
    if (press.scrubbing) setState(() {});
    if (!_hovering) _close();
  }

  /// The wheel scrolls the marks when there are more than fit.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_rail.hasClients) return;
    final position = _rail.position;
    if (position.maxScrollExtent <= position.minScrollExtent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final delta = (event as PointerScrollEvent).scrollDelta.dy;
      _rail.jumpTo(
        (position.pixels + delta).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  void _leave() {
    _hoverY = null;
    setState(() => _hovering = false);
    // A press keeps its target wherever the pointer wanders until it ends.
    if (_press == null) _close();
  }

  void _step(int delta) {
    final base = _active ?? _currentSpan(widget.visibleRange.value)?.$1;
    _stepTo(
      base == null ? 0 : (base + delta).clamp(0, widget.items.length - 1),
    );
  }

  void _stepTo(int index) {
    _point(index, now: true);
    _reveal(index);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _step(1);
      case LogicalKeyboardKey.arrowUp:
        _step(-1);
      case LogicalKeyboardKey.home:
        _stepTo(0);
      case LogicalKeyboardKey.end:
        _stepTo(widget.items.length - 1);
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.space:
        final active = _active;
        if (active != null) _select(widget.items[active]);
      case LogicalKeyboardKey.escape:
        _focus.unfocus();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _onFocusChange(bool focused) {
    if (focused) {
      _stepTo(_active ?? _currentSpan(widget.visibleRange.value)?.$1 ?? 0);
    } else if (!_hovering) {
      _close();
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.length < kTurnMinimapMinItems) {
      return const SizedBox.shrink();
    }
    final hitWidth = _hitWidth;
    // No gutter to live in: rather than reach over the text, the rail stands
    // down entirely and the transcript keeps its own scrollbar.
    if (hitWidth <= 0) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        // The rail is centred vertically and grows with the turn count until
        // it reaches its cap, after which the marks scroll.
        final cap = math.min(
          _kMaxRailHeight,
          constraints.maxHeight * _kRailHeightFraction,
        );
        final railHeight = math.min(widget.items.length * _kRowExtent, cap);
        final railTop = (constraints.maxHeight - railHeight) / 2;
        _railHeight = railHeight;
        final engaged = _hovering || _active != null || _focus.hasFocus;
        return Focus(
          focusNode: _focus,
          onKeyEvent: _onKey,
          onFocusChange: _onFocusChange,
          child: MouseRegion(
            opaque: false,
            hitTestBehavior: HitTestBehavior.deferToChild,
            cursor: clickable,
            onEnter: (_) => setState(() => _hovering = true),
            onExit: (_) => _leave(),
            child: AnimatedOpacity(
              opacity: _persistent || engaged ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              // Every target lives in the viewport, since a short rail can
              // have a preview taller than itself. Empty space stays
              // pass-through.
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  _marks(railHeight, railTop),
                  _railTarget(railHeight, railTop, hitWidth),
                  if (widget.onOpenOutline != null)
                    _outlineButton(railHeight, railTop, engaged),
                  ?_preview(railHeight, railTop),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The marks: a lazy list, so a 10,000-turn conversation builds only the
  /// rows in view. Purely visual — [_railTarget] takes the pointer.
  Widget _marks(double railHeight, double railTop) {
    final scheme = Theme.of(context).colorScheme;
    final motion = (_press?.scrubbing ?? false)
        ? Duration.zero
        : Motion.of(context, _kTickMotion);
    return Positioned(
      left: _railLeft,
      top: railTop,
      width: _kRowWidth,
      height: railHeight,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _rail,
          builder: (context, child) => _fadeEdges(child!, railHeight),
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(
              context,
            ).copyWith(scrollbars: false, overscroll: false),
            // Each scroll frame repaints the marks through the visible range
            // alone, so following a streaming reply never rebuilds the
            // transcript.
            child: ValueListenableBuilder<(int, int)?>(
              valueListenable: widget.visibleRange,
              builder: (context, range, _) {
                // While a turn is pointed at, it alone is marked.
                final span = _active == null ? _currentSpan(range) : null;
                return ListView.builder(
                  key: const Key('turn-minimap-rail'),
                  controller: _rail,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: EdgeInsets.zero,
                  itemExtent: _kRowExtent,
                  itemCount: widget.items.length,
                  itemBuilder: (context, i) => _mark(i, span, scheme, motion),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _mark(int i, (int, int)? span, ColorScheme scheme, Duration motion) {
    final active = _active;
    final distance = active == null ? null : (i - active).abs();
    final ink = distance == 0
        ? 1.0
        : span != null && i >= span.$1 && i <= span.$2
        ? _kCurrentInk
        : _kRestInk;
    return Align(
      alignment: Alignment.centerLeft,
      child: TweenAnimationBuilder<double>(
        tween: Tween(
          end: _kTickWidth + (_kMaxTickWidth - _kTickWidth) * _growth(distance),
        ),
        duration: motion,
        curve: _kTickCurve,
        builder: (context, width, child) =>
            SizedBox(width: width, height: _kTickHeight, child: child),
        child: DecoratedBox(
          key: ValueKey('turn-minimap-tick-$i'),
          decoration: BoxDecoration(
            color: scheme.onSurface.withValues(alpha: ink),
          ),
        ),
      ),
    );
  }

  /// Fades the marks out towards an edge with turns scrolled past it.
  Widget _fadeEdges(Widget child, double railHeight) {
    final hidden = widget.items.length * _kRowExtent - railHeight;
    final top = math.min(_kEdgeFade, _railOffset);
    final bottom = math.min(_kEdgeFade, hidden - _railOffset);
    if (railHeight <= 0 || (top <= 0 && bottom <= 0)) return child;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: const [
          Color(0x00000000),
          Color(0xFF000000),
          Color(0xFF000000),
          Color(0x00000000),
        ],
        stops: [
          0,
          math.max(0, top) / railHeight,
          1 - math.max(0, bottom) / railHeight,
          1,
        ],
      ).createShader(bounds),
      child: child,
    );
  }

  Widget _railTarget(double railHeight, double railTop, double hitWidth) {
    final size = Size(_railLeft + hitWidth, railHeight + 2 * _kRailHitPadding);
    double y(Offset local) => local.dy - _kRailHitPadding;
    return Positioned(
      left: 0,
      top: railTop - _kRailHitPadding,
      width: size.width,
      height: size.height,
      child: MouseRegion(
        onEnter: (event) => _hoverAt(y(event.localPosition)),
        onHover: (event) => _hoverAt(y(event.localPosition)),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) =>
              _onPointerDown(event, y(event.localPosition)),
          onPointerMove: (event) =>
              _onPointerMove(event, y(event.localPosition)),
          onPointerUp: (event) => _onPointerUp(
            event,
            inside: (Offset.zero & size).contains(event.localPosition),
          ),
          onPointerCancel: _onPointerCancel,
          onPointerSignal: _onPointerSignal,
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  /// The way into the searchable outline, labelled with where the reader is.
  /// It shows with the rail's preview rather than at rest, leaving the marks
  /// alone in the margin.
  Widget _outlineButton(
    double railHeight,
    double railTop,
    bool engaged,
  ) => Positioned(
    left: 0,
    top: railTop + railHeight + 14,
    child: AnimatedOpacity(
      opacity: engaged ? 1 : 0,
      duration: Motion.fast,
      child: ValueListenableBuilder<(int, int)?>(
        valueListenable: widget.visibleRange,
        builder: (context, range, _) => TextButton(
          key: const Key('turn-minimap-outline'),
          onPressed: widget.onOpenOutline,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            minimumSize: const Size(40, 32),
            textStyle: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(fontSize: 10),
          ),
          child: Text(
            '${(_currentSpan(range)?.$1 ?? 0) + 1} / ${widget.items.length}',
          ),
        ),
      ),
    ),
  );

  /// The hover card beside its mark, centred on it and kept inside the
  /// viewport, so it holds still while the pointer travels into it.
  Widget? _preview(double railHeight, double railTop) {
    final active = _active;
    if (active == null || !_previewOpen) return null;
    final item = widget.items.elementAtOrNull(active);
    if (item == null) return null;
    // A turn with neither a message nor a reply to show gets no card: an empty
    // one would only cover the conversation it is meant to help you find.
    if (item.userText.trim().isEmpty &&
        (item.assistantText?.trim().isEmpty ?? true)) {
      return null;
    }
    // The card is allowed to overhang the gutter — it has to be readable, and a
    // 320 px card cannot fit a 60 px margin — but not by so much that it buries
    // the conversation. Past this it narrows instead, and if it cannot stay
    // legible at all the tick simply doesn't preview.
    final room =
        widget.gutterWidth - _railLeft - _kRowWidth + _kMaxPreviewOverhang;
    final width = math.min(_kPreviewWidth, room);
    if (width < _kMinPreviewWidth) return null;
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _rail,
        builder: (context, card) => CustomSingleChildLayout(
          delegate: _PreviewLayout(
            left: _railLeft + _kMaxTickWidth,
            anchor:
                railTop +
                ((active + 0.5) * _kRowExtent - _railOffset).clamp(
                  0.0,
                  railHeight,
                ),
          ),
          child: card,
        ),
        child: TweenAnimationBuilder<double>(
          key: ValueKey(_openings),
          tween: Tween(begin: 0, end: 1),
          duration: Motion.of(context, Motion.fast),
          builder: (context, opacity, card) =>
              Opacity(opacity: opacity, child: card),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) {
              final active = _active;
              _pressedCard = active == null
                  ? null
                  : widget.items.elementAtOrNull(active);
            },
            onTapCancel: () => _pressedCard = null,
            onTap: () {
              final item = _pressedCard;
              _pressedCard = null;
              if (item != null) _select(item);
            },
            child: Padding(
              // The gap from the longest mark is part of the card's target:
              // moving sideways latches the preview instead of scanning the
              // neighbouring turns on the way.
              padding: const EdgeInsets.fromLTRB(
                _kRowWidth - _kMaxTickWidth,
                _kPreviewHitPadding,
                _kPreviewHitPadding,
                _kPreviewHitPadding,
              ),
              child: TurnPreviewCard(
                question: item.userText.trim(),
                reply: item.assistantText?.trim() ?? '',
                width: width,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Places the card at [left], centred on [anchor] and clamped inside the
/// viewport.
class _PreviewLayout extends SingleChildLayoutDelegate {
  const _PreviewLayout({required this.left, required this.anchor});

  final double left;
  final double anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    left,
    (anchor - childSize.height / 2).clamp(
      0.0,
      math.max(0.0, size.height - childSize.height),
    ),
  );

  @override
  bool shouldRelayout(_PreviewLayout old) =>
      old.left != left || old.anchor != anchor;
}

/// A curve given by samples at even steps from 0 to 1, joined linearly — how
/// CSS `linear()` easings are written.
class _SampledCurve extends Curve {
  const _SampledCurve(this.samples);

  final List<double> samples;

  @override
  double transformInternal(double t) {
    final scaled = t * (samples.length - 1);
    final i = scaled.floor().clamp(0, samples.length - 2);
    return samples[i] + (samples[i + 1] - samples[i]) * (scaled - i);
  }
}
