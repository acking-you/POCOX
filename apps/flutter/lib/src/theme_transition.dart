import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:pocket_codex/src/motion.dart';

/// A whole-window light/dark switch that spreads from where it was asked for.
///
/// The last frame is frozen as an image, the new theme is applied underneath
/// at once (`MaterialApp` does not lerp it: half the colours are chosen by
/// brightness and would flip midway), and the old frame is then wiped away
/// by a soft-edged circle growing from the control that was pressed, until
/// it covers the window. Every pixel changes exactly once, in one motion.
///
/// Install [ThemeTransitionHost] once, around the app's content, and switch
/// through [ThemeTransition.run]. A switch the system makes, which has no
/// call site, cross-fades the same frozen frame instead.
abstract final class ThemeTransition {
  static final _boundary = GlobalKey();
  static final _snapshot = ValueNotifier<_Snapshot?>(null);

  // Where the last pointer was released, in global coordinates: the control
  // a switch was chosen on, however many layers (a menu, a sheet) it closed.
  static Offset? _lastTap;
  static DateTime? _lastTapAt;

  /// Capture the current frame, then run [apply] (which changes the theme).
  /// The change still happens, without the reveal, when there is nothing to
  /// capture or motion is reduced.
  static void run(BuildContext context, VoidCallback apply) {
    _freeze(context, reveal: true);
    apply();
  }

  /// Freeze the frame before the system's own brightness change repaints it,
  /// so that change cross-fades instead of snapping.
  static void systemChange(BuildContext context) =>
      _freeze(context, reveal: false);

  /// Show the current frame as the leaving snapshot: revealed from the
  /// pressed control, or cross-faded without [reveal].
  static void _freeze(BuildContext context, {required bool reveal}) {
    try {
      final boundary = _boundary.currentContext?.findRenderObject();
      final animate = Motion.of(context, Motion.slow) > Duration.zero;
      if (!animate || boundary is! RenderRepaintBoundary) return;
      if (!boundary.attached || boundary.size.isEmpty) return;
      // Flutter's debugNeedsPaint getter throws when assertions are disabled.
      if (kDebugMode && boundary.debugNeedsPaint) return;
      final image = boundary.toImageSync(
        pixelRatio: MediaQuery.devicePixelRatioOf(context),
      );
      final origin = reveal
          ? boundary.globalToLocal(_origin(context, boundary))
          : null;
      _snapshot.value?.image.dispose();
      _snapshot.value = _Snapshot(image, origin);
    } catch (_) {
      // Image capture is optional; it must never prevent the theme change.
    }
  }

  /// The pressed control: the last release if it was just now, else the
  /// centre of [context]'s box, else the window's centre.
  static Offset _origin(BuildContext context, RenderBox window) {
    final at = _lastTapAt;
    if (_lastTap != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(seconds: 2)) {
      return _lastTap!;
    }
    final box = context.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      return box.localToGlobal(box.size.center(Offset.zero));
    }
    return window.localToGlobal(window.size.center(Offset.zero));
  }
}

class _Snapshot {
  _Snapshot(this.image, this.origin);

  final ui.Image image;

  /// Where the reveal starts, in the host's coordinates; null cross-fades.
  final Offset? origin;
}

/// Hosts the frame [ThemeTransition] captures and the snapshot leaving it.
class ThemeTransitionHost extends StatelessWidget {
  /// Wraps [child], the app's routed content.
  const ThemeTransitionHost({super.key, required this.child});

  /// The app content.
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerUp: (e) {
      if (e.kind == PointerDeviceKind.trackpad) return;
      ThemeTransition._lastTap = e.position;
      ThemeTransition._lastTapAt = DateTime.now();
    },
    child: Stack(
      textDirection: TextDirection.ltr,
      fit: StackFit.passthrough,
      children: [
        RepaintBoundary(key: ThemeTransition._boundary, child: child),
        ValueListenableBuilder<_Snapshot?>(
          valueListenable: ThemeTransition._snapshot,
          builder: (context, snapshot, _) => snapshot == null
              ? const SizedBox.shrink()
              : _LeavingSnapshot(key: ObjectKey(snapshot), snapshot: snapshot),
        ),
      ],
    ),
  );
}

class _LeavingSnapshot extends StatefulWidget {
  const _LeavingSnapshot({super.key, required this.snapshot});
  final _Snapshot snapshot;

  @override
  State<_LeavingSnapshot> createState() => _LeavingSnapshotState();
}

class _LeavingSnapshotState extends State<_LeavingSnapshot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(
    vsync: this,
    // A reveal travels the whole window, so it gets longer than a fade.
    duration: Duration(
      milliseconds: widget.snapshot.origin == null ? 320 : 560,
    ),
  );
  late final _curve = CurvedAnimation(
    parent: _progress,
    curve: Curves.easeInOutCubic,
  );

  @override
  void initState() {
    super.initState();
    _progress.forward().whenComplete(() {
      if (!mounted) return;
      final snapshot = widget.snapshot;
      if (identical(ThemeTransition._snapshot.value, snapshot)) {
        ThemeTransition._snapshot.value = null;
        snapshot.image.dispose();
      }
    });
  }

  @override
  void dispose() {
    _curve.dispose();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Positioned.fill(
    // Never intercept input: the new theme underneath is already live.
    child: IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(painter: _SnapshotPainter(widget.snapshot, _curve)),
      ),
    ),
  );
}

/// The old frame, minus a soft-edged circle of radius growing with
/// [progress] around the snapshot's origin (or faded out, without one).
class _SnapshotPainter extends CustomPainter {
  _SnapshotPainter(this.snapshot, this.progress) : super(repaint: progress);

  final _Snapshot snapshot;
  final Animation<double> progress;

  /// Width of the reveal's soft edge.
  static const _feather = 56.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final t = progress.value;
    final origin = snapshot.origin;
    void frame({double opacity = 1}) => paintImage(
      canvas: canvas,
      rect: rect,
      image: snapshot.image,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.none,
      opacity: opacity,
    );
    if (origin == null) return frame(opacity: 1 - t);
    // Far enough to clear the farthest corner, edge included.
    final reach = [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ].map((c) => (c - origin).distance).reduce(math.max);
    final radius = (reach + _feather) * t;
    canvas.saveLayer(rect, Paint());
    frame();
    final outer = radius + _feather;
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.dstOut
        ..shader = ui.Gradient.radial(
          origin,
          outer,
          const [Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
          [0, radius / outer, 1],
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SnapshotPainter old) =>
      !identical(old.snapshot, snapshot) || old.progress != progress;
}
