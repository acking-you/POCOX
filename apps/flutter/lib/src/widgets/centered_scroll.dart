import 'dart:math' as math;

import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Scrolls a list laid out on both sides of a centre sliver (a
/// [CustomScrollView] with `center`), with a range that is exactly its
/// content.
///
/// Rows added above the centre grow upward and rows added below it grow
/// downward, so content arriving on either side of what is on screen never
/// moves it. The centre itself is moved with [rebase], a change of
/// coordinates rather than a scroll.
///
/// A centre viewport never ends its range above zero, so a tail shorter than
/// the viewport would leave blank room to scroll into. [tailExtent] (the
/// laid-out extent of the centre sliver, which must end the list) lets the
/// range end where the content does, decided during layout.
///
/// [stickToEnd] holds the offset at that end through every layout, so
/// content growing at the end (a streaming reply, a resized composer) is
/// never a frame behind. [settle] brings an offset placed past the content
/// (a jump near either end) inside it before the frame paints.
class CenteredScrollController extends ScrollController {
  /// Creates a controller. Its offset is relative to the centre, so it is
  /// never restored from page storage.
  CenteredScrollController({super.debugLabel}) : super(keepScrollOffset: false);

  /// The centre sliver's laid-out scroll extent, or null before layout.
  double? Function()? tailExtent;

  /// Whether every layout pins the offset to the end of the content.
  bool stickToEnd = false;

  bool _settling = false;

  /// Clamp the offset into the content at this frame's layout.
  void settle() {
    if (_settling) return;
    _settling = true;
    SchedulerBinding.instance.addPostFrameCallback((_) => _settling = false);
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// Set the offset to [pixels] as a change of coordinates: nothing is
  /// notified, a drag or fling carries on from the new value, and an
  /// animation towards a target in the old coordinates stops where it is.
  ///
  /// Call it together with the change that moves the centre, before the
  /// next layout, so both are laid out in the same frame.
  void rebase(double pixels) {
    if (!hasClients) return;
    final position = this.position;
    if (position is _CenteredScrollPosition && position.hasPixels) {
      position.rebase(pixels);
    }
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _CenteredScrollPosition(
    this,
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

class _CenteredScrollPosition extends ScrollPositionWithSingleContext {
  _CenteredScrollPosition(
    this._owner, {
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  final CenteredScrollController _owner;

  void rebase(double value) {
    if (activity is DrivenScrollActivity) goIdle();
    correctBy(value - pixels);
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final tail = _owner.tailExtent?.call();
    final end = tail == null
        ? maxScrollExtent
        : math.max(minScrollExtent, tail - viewportDimension);
    final target = _owner.stickToEnd
        ? end
        : _owner._settling
        ? clampDouble(pixels, minScrollExtent, end)
        : null;
    if (target != null && (target - pixels).abs() > 0.01) {
      // Lay out again at the corrected offset, in this same frame.
      correctPixels(target);
      return false;
    }
    return super.applyContentDimensions(minScrollExtent, end);
  }
}

/// Centres [sliver] in a column at most [maxWidth] wide, keeping at least
/// [minGutter] on either side.
///
/// The insets are worked out from the width the sliver is laid out at, so a
/// width that changes every frame (a side pane sliding) only lays the column
/// out again; nothing above it rebuilds, and while the column keeps its
/// width its rows are not laid out again either.
class SliverColumn extends SingleChildRenderObjectWidget {
  /// Creates a centred column around [sliver].
  const SliverColumn({
    super.key,
    required this.maxWidth,
    this.minGutter = 0,
    required Widget sliver,
  }) : super(child: sliver);

  /// The widest the column may be.
  final double maxWidth;

  /// The least space kept on each side.
  final double minGutter;

  @override
  RenderSliverColumn createRenderObject(BuildContext context) =>
      RenderSliverColumn(maxWidth, minGutter);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSliverColumn renderObject,
  ) {
    renderObject
      ..maxWidth = maxWidth
      ..minGutter = minGutter;
  }
}

/// The render object of a [SliverColumn].
class RenderSliverColumn extends RenderSliverEdgeInsetsPadding {
  /// Creates the column's render object.
  RenderSliverColumn(this._maxWidth, this._minGutter);

  /// The widest the column may be.
  double get maxWidth => _maxWidth;
  double _maxWidth;
  set maxWidth(double value) {
    if (value == _maxWidth) return;
    _maxWidth = value;
    markNeedsLayout();
  }

  /// The least space kept on each side.
  double get minGutter => _minGutter;
  double _minGutter;
  set minGutter(double value) {
    if (value == _minGutter) return;
    _minGutter = value;
    markNeedsLayout();
  }

  EdgeInsets _padding = EdgeInsets.zero;

  @override
  EdgeInsets? get resolvedPadding => _padding;

  @override
  void performLayout() {
    final side = math.max(
      _minGutter,
      (constraints.crossAxisExtent - _maxWidth) / 2,
    );
    _padding = EdgeInsets.symmetric(horizontal: side);
    super.performLayout();
  }
}
