import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocket_codex/src/motion.dart';

/// A small solid status dot used to convey availability at a glance (e.g. a
/// service is online / a subscription is alive). [color] carries the meaning;
/// use [PulsingDot] instead for an active / running state.
class StatusDot extends StatelessWidget {
  /// Creates a status dot of [size] px in [color].
  const StatusDot({super.key, required this.color, this.size = 9});

  /// Dot colour (green = healthy, red = down, etc.).
  final Color color;

  /// Diameter in logical pixels.
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// A continuously pulsing dot, used to signal an in-flight / running state so
/// active sessions are perceptible before they're opened. Several rendered at
/// once read as "many things happening".
class PulsingDot extends StatefulWidget {
  /// Creates a pulsing dot of [size] px in [color].
  const PulsingDot({super.key, required this.color, this.size = 9})
    : orbit = false;

  /// A running indicator that turns: an arc travelling round a faint ring,
  /// about a solid core. Rotation reads as "working" at a glance in a dense
  /// list, where a few pixels of breathing halo do not. With reduced motion it
  /// is a still ring and core, so callers say "running" in words beside it.
  const PulsingDot.orbit({super.key, required this.color, this.size = 12})
    : orbit = true;

  /// Whether this is the turning [PulsingDot.orbit] form.
  final bool orbit;

  /// Dot colour (defaults to the caller's choice; usually the "working" colour).
  final Color color;

  /// Diameter in logical pixels.
  final double size;

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.orbit ? 1000 : 1100),
  );

  @override
  void didUpdateWidget(PulsingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.orbit == widget.orbit) return;
    _c
      ..stop()
      ..duration = Duration(milliseconds: widget.orbit ? 1000 : 1100);
    _syncMotion();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotion();
  }

  void _syncMotion() {
    // Reduced motion keeps the dot (it still says "running") at full
    // strength, without the pulse.
    if (Motion.ambientAllowed(context)) {
      if (!_c.isAnimating) _c.repeat(reverse: !widget.orbit);
    } else {
      _c
        ..stop()
        ..value = widget.orbit ? 0 : 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.orbit) {
      // Repaint only: the painter listens to the controller, so a turning
      // frame never rebuilds or relayouts the row around it.
      return RepaintBoundary(
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _OrbitPainter(
            _c,
            widget.color,
            still: !Motion.ambientAllowed(context),
          ),
        ),
      );
    }
    return _pulse();
  }

  Widget _pulse() => AnimatedBuilder(
    animation: _c,
    builder: (context, _) {
      // A solid core with a soft ring breathing around it — the ring moves,
      // the dot doesn't, so it reads as "live" without flickering.
      final t = Curves.easeInOut.transform(_c.value);
      return SizedBox(
        width: widget.size,
        height: widget.size,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Container(
              width: widget.size + 6 * t,
              height: widget.size + 6 * t,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: 0.22 * (1 - t) + 0.06),
              ),
            ),
            Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                color: widget.color,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter(this.turn, this.color, {required this.still})
    : super(repaint: turn);

  final Animation<double> turn;
  final Color color;
  final bool still;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final center = size.center(Offset.zero);
    final stroke = math.max(1.4, side * 0.13);
    final radius = side / 2 - stroke / 2;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      // Still, the whole ring carries the state; turning, it is the track.
      ..color = color.withValues(alpha: still ? 0.5 : 0.18);
    canvas
      ..drawCircle(center, radius, ring)
      ..drawCircle(center, side * 0.17, Paint()..color = color);
    if (still) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      turn.value * 2 * math.pi - math.pi / 2,
      math.pi * 0.62,
      false,
      ring
        ..color = color
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_OrbitPainter old) =>
      old.turn != turn || old.color != color || old.still != still;
}

/// A dot + label pill for service availability rows. Set [pulsing] for an
/// active state (renders a [PulsingDot] instead of a [StatusDot]); set [filled]
/// to wrap the dot+label in a status-tinted rounded pill (used on the card-style
/// service rows, where a bare dot+text would float without weight).
class StatusChip extends StatelessWidget {
  /// Creates a status chip.
  const StatusChip({
    super.key,
    required this.color,
    required this.label,
    this.pulsing = false,
    this.filled = false,
    this.wrap = false,
  });

  /// Colour shared by the dot and (subtly) the label.
  final Color color;

  /// Short status text (localised by the caller).
  final String label;

  /// Whether to animate the dot (running / in-flight states).
  final bool pulsing;

  /// Whether to draw a status-tinted rounded background behind the dot+label.
  final bool filled;

  /// Whether a label too long for the available width wraps onto further
  /// lines (it may name a device or host). Needs a bounded width.
  final bool wrap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isLight = scheme.brightness == Brightness.light;
    // Filled pills speak in the status colour itself (shifted towards the
    // text pole for contrast); the bare dot+label stays muted.
    final labelColor = filled
        ? Color.lerp(color, scheme.onSurface, 0.35)!
        : scheme.onSurfaceVariant;
    final text = Text(
      label,
      style: TextStyle(
        fontSize: 11.5,
        color: labelColor,
        fontWeight: filled ? FontWeight.w600 : FontWeight.w400,
        letterSpacing: 0.1,
      ),
    );
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        pulsing
            ? PulsingDot(color: color, size: 8)
            : StatusDot(color: color, size: 8),
        const SizedBox(width: 6),
        if (wrap) Flexible(child: text) else text,
      ],
    );
    if (!filled) return row;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
      decoration: BoxDecoration(
        // A wash of the status colour: enough to read as a pill in both
        // themes without shouting over the card content.
        color: color.withValues(alpha: isLight ? 0.12 : 0.18),
        // A wrapped label would turn a full pill into a blob.
        borderRadius: BorderRadius.circular(wrap ? 12 : 999),
      ),
      child: row,
    );
  }
}
