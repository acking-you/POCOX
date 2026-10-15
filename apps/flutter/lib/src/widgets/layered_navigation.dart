import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show DragStartBehavior, PointerCancelEvent, PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocket_codex/src/motion.dart';

/// The phone's navigation: a full-screen sidebar lying underneath the page,
/// revealed by sliding the page aside.
///
/// A horizontal drag anywhere on the page (past ordinary touch slop) moves it
/// with the finger; the sidebar beneath it brightens and settles into place
/// as it is uncovered. While the finger stays down the page rests wherever it
/// is held, endpoints included, and nothing settles. On release it completes
/// the direction the finger last clearly moved in — opening or closing —
/// however short the drag was; reversing by more than [directionHysteresis]
/// changes that direction, so tremor never flips it. Recognizing an opening
/// gives one light haptic, and a gesture that settles fully open one
/// completion haptic. Nested horizontal scrollables and text gestures win
/// the arena first, since deeper recognizers resolve first.
///
/// The sidebar stays mounted while hidden (offstage, tickers paused), so its
/// scroll position and expanded rows survive opening and closing. While it is
/// hidden it is not rebuilt either: the last widget it showed is kept until
/// it is about to be seen again.
class LayeredNavigation extends StatefulWidget {
  /// Creates the layered navigation over [body] with [sidebar] beneath.
  const LayeredNavigation({
    super.key,
    required this.sidebar,
    required this.body,
    this.sidebarLabel,
    this.onOpenChanged,
  });

  /// The full-screen navigation shown when open.
  final Widget sidebar;

  /// The page that slides aside.
  final Widget body;

  /// Accessibility name of the sidebar, announced when it opens.
  final String? sidebarLabel;

  /// Called once the sidebar has settled fully open (true) or closed (false).
  final ValueChanged<bool>? onOpenChanged;

  /// Logical pixels the finger must move back from its furthest point before
  /// a held drag's intended direction flips.
  static const double directionHysteresis = 16;

  /// Pointers that may drag it. A mouse drag is a text selection in a narrow
  /// desktop window, never navigation.
  static const Set<PointerDeviceKind> dragDevices = {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
  };

  /// The nearest layered navigation above [context], if any.
  static LayeredNavigationState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<LayeredNavigationState>();

  @override
  State<LayeredNavigation> createState() => LayeredNavigationState();
}

/// State of a [LayeredNavigation]; open and close it from inside either layer
/// through [LayeredNavigation.maybeOf].
class LayeredNavigationState extends State<LayeredNavigation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(vsync: this)
    ..addStatusListener(_onStatus);
  final FocusScopeNode _sidebarScope = FocusScopeNode(
    debugLabel: 'LayeredNavigation sidebar',
  );

  /// Where the sidebar is headed: open, or opening by a committed action.
  bool _target = false;

  /// The last settled state reported through `onOpenChanged`.
  bool _settledOpen = false;
  bool _dragging = false;

  /// Whether the current drag started closed: only those give haptics.
  bool _dragFromClosed = false;

  /// Where a release of the current drag goes: open, closed, or (before the
  /// finger has moved) back to where it started.
  bool? _intentOpen;

  /// The drag's signed travel in the opening direction, and its furthest
  /// point along the intended direction, in logical pixels.
  double _travel = 0;
  double _extreme = 0;
  bool _openingFelt = false;

  /// A gesture-driven open in flight, owed a completion haptic.
  bool _completionOwed = false;

  /// The current drag's pointer was cancelled by the system (a call, the OS
  /// claiming the gesture). An accepted drag reports that as an ordinary end,
  /// so a Listener above the recognizer marks it first.
  bool _pointerCancelled = false;
  double _width = 1;
  Widget? _shownSidebar;

  /// Whether the sidebar is open or committed to opening. Mirrors
  /// `ScaffoldState.isDrawerOpen` for callers that close it before acting.
  bool get isOpen => _target;

  /// Open progress, 0 (page in place) to 1 (sidebar full screen).
  @visibleForTesting
  double get progress => _progress.value;

  /// Open the sidebar.
  void open() => _settle(true);

  /// Close the sidebar.
  void close() => _settle(false);

  bool get _hidden =>
      _progress.value == 0 && !_dragging && !_progress.isAnimating && !_target;

  double get _sign =>
      Directionality.of(context) == TextDirection.rtl ? -1.0 : 1.0;

  void _settle(bool open, {bool gesture = false}) {
    if (!mounted) return;
    setState(() {
      _target = open;
      _dragging = false;
      _completionOwed = open && gesture && _dragFromClosed;
    });
    final goal = open ? 1.0 : 0.0;
    final full = Motion.of(context, Motion.slow);
    final remaining = (goal - _progress.value).abs();
    if (full == Duration.zero || remaining == 0) {
      _progress.value = goal;
      // Setting a value fires no completed/dismissed status of its own.
      _onSettled(open);
      return;
    }
    _progress.animateTo(
      goal,
      duration: Duration(
        milliseconds: math.max(120, (full.inMilliseconds * remaining).round()),
      ),
      curve: Motion.enter,
    );
  }

  void _onStatus(AnimationStatus status) {
    // `animateTo` ends "completed" whichever way it went, so the value, not
    // the status, says where it stopped.
    if (_dragging || status.isAnimating) return;
    final value = _progress.value;
    if (value == 1 && _target) _onSettled(true);
    if (value == 0 && !_target) _onSettled(false);
  }

  void _onSettled(bool open) {
    if (!mounted) return;
    if (open && _completionOwed) {
      _completionOwed = false;
      HapticFeedback.mediumImpact();
    }
    if (open) _sidebarScope.requestFocus();
    // Rebuild so the hidden sidebar goes offstage and the page takes input.
    setState(() {});
    if (open == _settledOpen) return;
    _settledOpen = open;
    widget.onOpenChanged?.call(open);
  }

  void _dragStart(DragStartDetails _) {
    _pointerCancelled = false;
    _progress.stop();
    setState(() {
      _dragging = true;
      _dragFromClosed = !_target;
      _intentOpen = null;
      _travel = 0;
      _extreme = 0;
      _openingFelt = false;
    });
  }

  void _dragUpdate(DragUpdateDetails d) {
    if (!_dragging) return;
    final dx = _sign * d.delta.dx;
    _progress.value += dx / _width;
    _travel += dx;
    final intent = _intentOpen;
    if (intent == null) {
      // The first update carries the slop the recognizer waited for, so its
      // sign is already a clear direction.
      if (dx != 0) _setIntent(dx > 0);
    } else if (intent) {
      _extreme = math.max(_extreme, _travel);
      if (_travel < _extreme - LayeredNavigation.directionHysteresis) {
        _setIntent(false);
      }
    } else {
      _extreme = math.min(_extreme, _travel);
      if (_travel > _extreme + LayeredNavigation.directionHysteresis) {
        _setIntent(true);
      }
    }
  }

  void _setIntent(bool open) {
    _intentOpen = open;
    _extreme = _travel;
    // One light haptic per drag, when it is first recognized as an opening.
    if (open && _dragFromClosed && !_openingFelt) {
      _openingFelt = true;
      HapticFeedback.lightImpact();
    }
  }

  void _dragEnd(DragEndDetails _) {
    if (!_dragging) return;
    if (_pointerCancelled) return _dragCancel();
    _settle(_intentOpen ?? _target, gesture: true);
  }

  /// A drag taken away mid-way returns to where it started, owing no
  /// completion haptic.
  void _dragCancel() {
    _pointerCancelled = false;
    if (!_dragging) return;
    _settle(_target);
  }

  void _onPointerCancel(PointerCancelEvent _) {
    if (_dragging) _pointerCancelled = true;
  }

  @override
  void dispose() {
    _progress.dispose();
    _sidebarScope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hidden = _hidden;
    if (!hidden || _shownSidebar == null) _shownSidebar = widget.sidebar;
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    // The page's drag must outlive its own gesture, or it is cancelled; with
    // the keyboard up the page belongs to the composer.
    final pageDrag = _dragging || (!_target && !keyboardUp);
    final dim = Theme.of(context).brightness == Brightness.dark ? 0.55 : 0.32;

    final sidebar = Offstage(
      offstage: hidden,
      child: TickerMode(
        enabled: !hidden,
        // Escape is resolved upward from the focused node, so the action
        // sits above the scope the focus moves into.
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) => close(),
            ),
          },
          child: ExcludeFocus(
            excluding: !_target,
            child: FocusScope(
              node: _sidebarScope,
              child: Semantics(
                container: true,
                explicitChildNodes: true,
                scopesRoute: true,
                namesRoute: widget.sidebarLabel != null,
                label: widget.sidebarLabel,
                child: Listener(
                  onPointerCancel: _onPointerCancel,
                  child: GestureDetector(
                    // Closing: a leftward drag anywhere on the open sidebar.
                    // Vertical drags still scroll its list; the arena hands a
                    // drag to whichever axis it moves along first.
                    supportedDevices: LayeredNavigation.dragDevices,
                    dragStartBehavior: DragStartBehavior.down,
                    onHorizontalDragStart: _dragStart,
                    onHorizontalDragUpdate: _dragUpdate,
                    onHorizontalDragEnd: _dragEnd,
                    onHorizontalDragCancel: _dragCancel,
                    child: _shownSidebar,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return PopScope(
      canPop: !_target,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) close();
      },
      child: LayoutBuilder(
        builder: (context, box) {
          _width = math.max(1, box.maxWidth);
          return AnimatedBuilder(
            animation: _progress,
            builder: (context, page) {
              final t = _progress.value;
              // The sidebar rises out of shade and drifts in under the page.
              final under = (1 - t) * _width * 0.06 * -_sign;
              return Stack(
                fit: StackFit.expand,
                children: [
                  Transform.translate(
                    offset: Offset(under, 0),
                    child: Transform.scale(
                      scale: 0.97 + 0.03 * t,
                      child: sidebar,
                    ),
                  ),
                  IgnorePointer(
                    child: ColoredBox(
                      color: Colors.black.withValues(
                        alpha: hidden ? 0 : dim * (1 - t),
                      ),
                    ),
                  ),
                  Transform.translate(
                    offset: Offset(_sign * t * _width, 0),
                    child: _PageSurface(
                      lift: math.min(1, t * 4),
                      // The shadow fades out as the page leaves, or its blur
                      // would leave a seam along the open sidebar's edge.
                      shade: math.min(1, t * 4) * math.min(1, (1 - t) * 6),
                      leadingEdge: _sign,
                      // Fully aside, the page paints nothing (its state stays).
                      child: Offstage(
                        offstage: t == 1 && !_dragging,
                        child: page,
                      ),
                    ),
                  ),
                ],
              );
            },
            // Built once per parent build, not per animation frame. Its
            // wrappers keep one shape at every progress, so the page's state
            // (drafts, scroll, focus nodes) never remounts.
            child: Listener(
              onPointerCancel: _onPointerCancel,
              child: GestureDetector(
                // Opening: a horizontal drag anywhere on the page. It only
                // joins the arena where the page itself is hit, and the
                // page's own horizontal scrollables and text gestures, being
                // deeper, resolve first; vertical drags stay the list's.
                excludeFromSemantics: true,
                supportedDevices: LayeredNavigation.dragDevices,
                // Track the finger from touch-down, slop included.
                dragStartBehavior: DragStartBehavior.down,
                onHorizontalDragStart: pageDrag ? _dragStart : null,
                onHorizontalDragUpdate: pageDrag ? _dragUpdate : null,
                onHorizontalDragEnd: pageDrag ? _dragEnd : null,
                onHorizontalDragCancel: pageDrag ? _dragCancel : null,
                child: _PageGate(moved: !hidden || _target, child: widget.body),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Takes the page out of input, focus and semantics while it is moved aside.
class _PageGate extends StatelessWidget {
  const _PageGate({required this.moved, required this.child});

  final bool moved;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: moved,
    child: ExcludeSemantics(
      excluding: moved,
      child: ExcludeFocus(excluding: moved, child: child),
    ),
  );
}

/// The page while it slides: a lifted sheet with a rounded, shadowed leading
/// edge, so it reads as a layer above the sidebar rather than a scroll.
class _PageSurface extends StatelessWidget {
  const _PageSurface({
    required this.lift,
    required this.shade,
    required this.leadingEdge,
    required this.child,
  });

  /// 0 in place, 1 fully lifted.
  final double lift;

  /// Shadow strength, 0 to 1.
  final double shade;

  /// 1 when the leading edge is on the left.
  final double leadingEdge;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final radius = Radius.circular(28 * lift);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.all(radius),
        boxShadow: [
          if (shade > 0)
            BoxShadow(
              color: Colors.black.withValues(
                alpha: (dark ? 0.6 : 0.22) * shade,
              ),
              blurRadius: 28,
              offset: Offset(-6 * leadingEdge, 0),
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.all(radius),
        clipBehavior: lift > 0 ? Clip.antiAlias : Clip.none,
        child: child,
      ),
    );
  }
}
