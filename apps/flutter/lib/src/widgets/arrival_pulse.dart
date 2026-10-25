import 'package:flutter/material.dart';

import '../desktop_theme.dart';

/// Highlights where the reader just arrived — newly revealed history, or the
/// message a turn jump landed on — without replacing the stateful subtree.
///
/// It paints a wash of [color] behind [child] that fades out over 1.4 s:
/// held at full strength for the first [hold] of that time, then easing out
/// along [curve]. Each new non-null [revision] plays it again.
class ArrivalPulse extends StatefulWidget {
  const ArrivalPulse({
    super.key,
    required this.revision,
    required this.child,
    this.color,
    this.borderRadius = const BorderRadius.all(Radius.circular(kControlRadius)),
    this.hold = 0,
    this.curve = Curves.linear,
  });

  final int? revision;
  final Widget child;

  /// The wash at full strength; the theme's primary at 12% by default.
  final Color? color;
  final BorderRadius borderRadius;

  /// Share of the pulse spent at full strength before it fades.
  final double hold;
  final Curve curve;

  @override
  State<ArrivalPulse> createState() => _ArrivalPulseState();
}

class _ArrivalPulseState extends State<ArrivalPulse>
    with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  bool _initialized = false;

  void _play() {
    if (widget.revision != null && !MediaQuery.disableAnimationsOf(context)) {
      _fade.reverse(from: 1);
    } else {
      _fade.reset();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized || MediaQuery.disableAnimationsOf(context)) _play();
    _initialized = true;
  }

  @override
  void didUpdateWidget(ArrivalPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) _play();
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  /// Strength of the wash, from 1 at the start to 0 at rest.
  double get _strength {
    final elapsed = 1 - _fade.value;
    final hold = widget.hold;
    if (elapsed < hold) return 1;
    return 1 - widget.curve.transform((elapsed - hold) / (1 - hold));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _fade,
    builder: (context, child) {
      final color =
          widget.color ??
          Theme.of(context).colorScheme.primary.withValues(alpha: 0.12);
      return DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: color.a * _strength),
          borderRadius: widget.borderRadius,
        ),
        child: child,
      );
    },
    child: widget.child,
  );
}
