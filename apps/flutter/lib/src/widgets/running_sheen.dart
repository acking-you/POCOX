import 'package:flutter/material.dart';
import 'package:pocket_codex/src/motion.dart';

/// Marks [child] as live work: a faint steady wash of [color] and, while
/// ambient motion is allowed, a soft band of it sweeping from the leading to
/// the trailing edge every few seconds, so a running row is noticed from the
/// corner of the eye while its text stays still. With reduced motion only the
/// steady wash remains.
///
/// Painting only: the sweep repaints its own layer and never rebuilds or
/// relayouts [child]. Its ticker follows [TickerMode], so a row offstage
/// costs nothing. The caller clips it to the row's shape.
class RunningSheen extends StatefulWidget {
  /// Creates a sheen in [color] behind [child].
  const RunningSheen({super.key, required this.color, required this.child});

  /// The live signal colour.
  final Color color;

  /// The row content, painted above the sheen.
  final Widget child;

  @override
  State<RunningSheen> createState() => _RunningSheenState();
}

class _RunningSheenState extends State<RunningSheen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _c.loopUnlessReduced(context);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: _SheenPainter(
        _c,
        widget.color,
        still: !Motion.ambientAllowed(context),
        rtl: Directionality.of(context) == TextDirection.rtl,
        light: Theme.of(context).brightness == Brightness.light,
      ),
      child: RepaintBoundary(child: widget.child),
    ),
  );
}

class _SheenPainter extends CustomPainter {
  _SheenPainter(
    this.cycle,
    this.color, {
    required this.still,
    required this.rtl,
    required this.light,
  }) : super(repaint: cycle);

  final Animation<double> cycle;
  final Color color;
  final bool still;
  final bool rtl;
  final bool light;

  /// The share of each cycle the band travels; the rest is a pause, so the
  /// row breathes between sweeps instead of strobing.
  static const _travel = 0.55;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()..color = color.withValues(alpha: light ? 0.045 : 0.07),
    );
    final t = cycle.value / _travel;
    if (still || t >= 1 || size.width <= 0) return;
    final band = size.width * 0.45;
    final travelled = (size.width + band) * Curves.easeInOut.transform(t);
    final left = rtl ? size.width - travelled : travelled - band;
    final rect = Rect.fromLTWH(left, 0, band, size.height);
    final peak = color.withValues(alpha: light ? 0.12 : 0.16);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [peak.withValues(alpha: 0), peak, peak.withValues(alpha: 0)],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_SheenPainter old) =>
      old.cycle != cycle ||
      old.color != color ||
      old.still != still ||
      old.rtl != rtl ||
      old.light != light;
}
