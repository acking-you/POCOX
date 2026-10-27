import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocox/src/motion.dart';

/// A slim, rounded progress track.
///
/// With a [value] it fills to that measured fraction, easing between
/// readings. Without one the work is honestly indeterminate: a soft band
/// eases across the track, held still as a hatch when the platform asks for
/// reduced motion. Nothing is estimated in between. The motion is
/// paint-only and follows [TickerMode].
class ProgressTrack extends StatefulWidget {
  /// Creates a track filled with [color].
  const ProgressTrack({
    super.key,
    required this.color,
    this.value,
    this.height = 6,
    this.semanticsLabel,
  });

  /// The measured fraction, from 0 to 1; null while it is not known.
  final double? value;

  /// The fill, or the band while indeterminate.
  final Color color;

  /// The track's thickness.
  final double height;

  /// What assistive technology reads, with the percentage once measured;
  /// null leaves the track out of the semantics tree for callers that
  /// announce progress themselves.
  final String? semanticsLabel;

  @override
  State<ProgressTrack> createState() => _ProgressTrackState();
}

class _ProgressTrackState extends State<ProgressTrack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );

  void _sync() {
    if (widget.value == null && Motion.ambientAllowed(context)) {
      if (!_sweep.isAnimating) _sweep.repeat();
    } else {
      _sweep.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ProgressTrack old) {
    super.didUpdateWidget(old);
    if ((old.value == null) != (widget.value == null)) _sync();
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final value = widget.value?.clamp(0.0, 1.0);
    final _Mode mode = value != null
        ? _Mode.measured
        : Motion.ambientAllowed(context)
        ? _Mode.sweep
        : _Mode.hatch;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final track = RepaintBoundary(
      child: TweenAnimationBuilder<double>(
        // While indeterminate the fill rests at zero, so the first reading
        // grows from the start instead of jumping in.
        tween: Tween(end: value ?? 0),
        duration: Motion.of(context, Motion.slow),
        curve: Motion.move,
        builder: (context, shown, _) => SizedBox(
          height: widget.height,
          width: double.infinity,
          child: CustomPaint(
            painter: _TrackPainter(
              _sweep,
              mode: mode,
              fraction: shown,
              fill: widget.color,
              track: scheme.surfaceContainerHighest,
              rtl: rtl,
            ),
          ),
        ),
      ),
    );
    final label = widget.semanticsLabel;
    if (label == null) return ExcludeSemantics(child: track);
    return Semantics(
      label: label,
      value: value == null ? null : '${(value * 100).round()}%',
      child: ExcludeSemantics(child: track),
    );
  }
}

enum _Mode { measured, sweep, hatch }

class _TrackPainter extends CustomPainter {
  _TrackPainter(
    this.cycle, {
    required this.mode,
    required this.fraction,
    required this.fill,
    required this.track,
    required this.rtl,
  }) : super(repaint: mode == _Mode.sweep ? cycle : null);

  final Animation<double> cycle;
  final _Mode mode;
  final double fraction;
  final Color fill;
  final Color track;
  final bool rtl;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final radius = Radius.circular(size.height / 2);
    final whole = RRect.fromRectAndRadius(Offset.zero & size, radius);
    canvas.drawRRect(whole, Paint()..color = track);
    switch (mode) {
      case _Mode.measured:
        if (fraction <= 0) return;
        final width = math.max(size.width * fraction, size.height);
        final left = rtl ? size.width - width : 0.0;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(left, 0, width, size.height),
            radius,
          ),
          Paint()..color = fill,
        );
      case _Mode.hatch:
        canvas
          ..save()
          ..clipRRect(whole);
        final stripe = Paint()
          ..color = fill.withValues(alpha: 0.4)
          ..strokeWidth = 2;
        for (var x = -size.height; x < size.width + size.height; x += 7) {
          canvas.drawLine(
            Offset(x, size.height),
            Offset(x + size.height, 0),
            stripe,
          );
        }
        canvas.restore();
      case _Mode.sweep:
        canvas
          ..save()
          ..clipRRect(whole)
          // A faint steady wash keeps the track reading as live between
          // passes of the band.
          ..drawRRect(whole, Paint()..color = fill.withValues(alpha: 0.12));
        final band = math.max(size.width * 0.32, 24.0);
        final travelled =
            (size.width + band) * Curves.easeInOut.transform(cycle.value);
        final left = rtl ? size.width - travelled : travelled - band;
        final rect = Rect.fromLTWH(left, 0, band, size.height);
        canvas
          ..drawRRect(
            RRect.fromRectAndRadius(rect, radius),
            Paint()
              ..shader = LinearGradient(
                colors: [
                  fill.withValues(alpha: 0.2),
                  fill,
                  fill.withValues(alpha: 0.2),
                ],
              ).createShader(rect),
          )
          ..restore();
    }
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.cycle != cycle ||
      old.mode != mode ||
      old.fraction != fraction ||
      old.fill != fill ||
      old.track != track ||
      old.rtl != rtl;
}
