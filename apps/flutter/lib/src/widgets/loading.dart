import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/motion.dart';

/// Drives the sweep for the skeleton shapes ([SkeletonBox]) beneath it, so a
/// screen waiting on data reads as "content is coming" rather than as a frozen
/// grey block.
///
/// The sweep is painted BY each box, as a gradient fill, rather than masked
/// over the subtree. A `ShaderMask` looks like the obvious tool and isn't:
/// `BlendMode.srcATop` keeps the *destination's* alpha, so the shimmer's own
/// alphas never reach the screen — the highlight can only tint a shape whose
/// opacity is already fixed, which is why the previous sweep was imperceptible.
class Shimmer extends StatefulWidget {
  /// Wraps [child]; every [SkeletonBox] inside it shares this sweep.
  const Shimmer({super.key, required this.child});

  /// The skeleton content to animate.
  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1250),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced-motion users keep the skeleton and lose the movement: the shape
    // is what says "loading", the sweep is only polish.
    _c.loopUnlessReduced(context, rest: 0.5);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, child) => _ShimmerPhase(phase: _c.value, child: child!),
    child: widget.child,
  );
}

/// Carries the current sweep position down to the skeleton shapes.
class _ShimmerPhase extends InheritedWidget {
  const _ShimmerPhase({required this.phase, required super.child});

  /// 0→1 across one sweep.
  final double phase;

  static double? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ShimmerPhase>()?.phase;

  @override
  bool updateShouldNotify(_ShimmerPhase old) => old.phase != phase;
}

/// A rounded placeholder shape. Inside a [Shimmer] it carries the animated
/// sweep; on its own it falls back to a flat tint, so a stray use is dull
/// rather than broken.
class SkeletonBox extends StatelessWidget {
  /// Creates a placeholder box.
  const SkeletonBox({super.key, this.width, this.height = 14, this.radius = 7});

  /// Width (null = fill available).
  final double? width;

  /// Height in logical pixels.
  final double height;

  /// Corner radius.
  final double radius;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final base = onSurface.withValues(alpha: 0.10);
    final highlight = onSurface.withValues(alpha: 0.28);
    final phase = _ShimmerPhase.maybeOf(context);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: phase == null ? base : null,
        // A band wide enough to register as light travelling across the shape;
        // the sweep runs from off one edge to off the other, so each box is
        // plain at the extremes and brightest as the band crosses it.
        gradient: phase == null
            ? null
            : LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [base, highlight, base],
                stops: const [0.15, 0.5, 0.85],
                transform: _SlideGradient(Curves.easeInOut.transform(phase)),
              ),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Slides a gradient horizontally from off-shape left to off-shape right as
/// [t] goes 0→1.
class _SlideGradient extends GradientTransform {
  const _SlideGradient(this.t);
  final double t;
  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues((t * 2 - 1) * bounds.width, 0, 0);
}

/// A quiet initial-history state: after a short delay, a label with a small
/// spinner fades in. Fast cache hits never flash a loading shape, and no mock
/// conversation stands in for the real one.
class ChatLoadingSkeleton extends StatelessWidget {
  /// Creates the loading state.
  const ChatLoadingSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: _DelayedFadeIn(
        delay: const Duration(milliseconds: 250),
        hidden: const SizedBox.shrink(),
        child: Semantics(
          liveRegion: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Reduced motion keeps the label alone, perfectly still.
              if (Motion.ambientAllowed(context)) ...[
                SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: muted,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Text(
                AppLocalizations.of(context).historyLoading,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows [child] only once [delay] has passed, fading it in, so a wait that
/// ends at once never flashes a placeholder and one that only just outlasts
/// the delay does not pop. [hidden] holds the place meanwhile; [child] is not
/// built before it shows, so a hidden sweep never ticks.
class _DelayedFadeIn extends StatefulWidget {
  const _DelayedFadeIn({
    required this.delay,
    required this.hidden,
    required this.child,
  });

  final Duration delay;
  final Widget hidden;
  final Widget child;

  @override
  State<_DelayedFadeIn> createState() => _DelayedFadeInState();
}

class _DelayedFadeInState extends State<_DelayedFadeIn> {
  bool _visible = false;
  late final Timer _delay = Timer(widget.delay, () {
    if (mounted) setState(() => _visible = true);
  });

  @override
  void initState() {
    super.initState();
    _delay;
  }

  @override
  void dispose() {
    _delay.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: _visible ? 1 : 0,
    duration: Motion.of(context, Motion.slow),
    curve: Motion.enter,
    child: _visible ? widget.child : widget.hidden,
  );
}

/// A shimmer skeleton mimicking a list (services / sessions) while it loads.
class ListLoadingSkeleton extends StatelessWidget {
  /// Creates a list skeleton with [rows] placeholder rows.
  const ListLoadingSkeleton({super.key, this.rows = 6});

  /// Number of placeholder rows.
  final int rows;

  @override
  Widget build(BuildContext context) => Shimmer(
    child: ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: rows,
      itemBuilder: (c, i) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(
          children: [
            const SkeletonBox(width: 22, height: 22, radius: 11),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  SkeletonBox(width: double.infinity, height: 12),
                  SizedBox(height: 7),
                  SkeletonBox(width: 120, height: 10),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The sessions sidebar while its first listing is on its way: after a short
/// delay, quiet rows under project headings fade in, so a listing that
/// answers at once never flashes a placeholder.
class ConversationListSkeleton extends StatelessWidget {
  /// Creates the skeleton; [touch] lays it out with touch-sized rows.
  const ConversationListSkeleton({super.key, this.touch = false});

  /// Touch-sized rows rather than pointer-sized ones.
  final bool touch;

  // Each group: its heading's width, then its rows' title widths (fractions
  // of the row), uneven the way real titles are.
  static const _groups = [
    (84.0, [0.78, 0.56, 0.68]),
    (64.0, [0.62, 0.84]),
    (96.0, [0.5, 0.72, 0.6]),
  ];

  // A pointer row: the title, its time at the end of the line.
  static Widget _pointerRow(double title) => SizedBox(
    height: 34,
    child: Row(
      children: [
        Expanded(
          child: FractionallySizedBox(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: title,
            child: const SkeletonBox(height: 10, radius: 5),
          ),
        ),
        const SizedBox(width: 14),
        const SkeletonBox(width: 22, height: 8, radius: 4),
      ],
    ),
  );

  // A touch row: the title, its time on the line below.
  static Widget _touchRow(double title) => SizedBox(
    height: 58,
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FractionallySizedBox(
          widthFactor: title,
          child: const SkeletonBox(height: 11, radius: 5.5),
        ),
        const SizedBox(height: 9),
        const SkeletonBox(width: 52, height: 8, radius: 4),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[
      for (final (heading, titles) in _groups) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 16, 10, 10),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: SkeletonBox(width: heading, height: 9, radius: 4.5),
          ),
        ),
        for (final title in titles)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(28, 0, 10, 0),
            child: touch ? _touchRow(title) : _pointerRow(title),
          ),
      ],
    ];
    return Semantics(
      label: AppLocalizations.of(context).conversationsLoading,
      liveRegion: true,
      child: ExcludeSemantics(
        child: _DelayedFadeIn(
          delay: const Duration(milliseconds: 180),
          hidden: const SizedBox.expand(),
          child: Shimmer(
            child: ListView(
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              children: rows,
            ),
          ),
        ),
      ),
    );
  }
}
