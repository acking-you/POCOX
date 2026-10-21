import 'package:flutter/material.dart';
import 'package:pocox/src/glass_recipe.dart';
import 'package:pocox/src/motion.dart';
import 'package:pocox/src/widgets/glass.dart';

/// A small status capsule floating over content (history syncing, a turn
/// being read): it says what is happening without taking any room from what
/// lies beneath it, which therefore never moves when it comes or goes.
class FloatingStatus extends StatelessWidget {
  /// Creates a capsule saying [label].
  const FloatingStatus({
    super.key,
    required this.label,
    this.busy = false,
    this.icon,
    this.trailing = const [],
  });

  /// What is happening.
  final String label;

  /// Whether work is under way: a small spinner leads the label.
  final bool busy;

  /// A mark leading the label when nothing is under way.
  final IconData? icon;

  /// Controls after the label (retry, close).
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Glass(
      depth: GlassDepth.floating,
      borderRadius: BorderRadius.circular(999),
      lift: 0.6,
      padding: EdgeInsets.fromLTRB(12, 6, trailing.isEmpty ? 14 : 4, 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox.square(
              dimension: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: muted),
            )
          else if (icon != null)
            Icon(icon, size: 14, color: muted),
          if (busy || icon != null) const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(color: muted),
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}

/// Shows [child], or nothing, fading it in as it settles down from just
/// above and fading it out. A child with the same key changes in place.
class FloatingStatusSwitcher extends StatelessWidget {
  /// Creates the switcher.
  const FloatingStatusSwitcher({super.key, this.child});

  /// The status to show; null shows none.
  final Widget? child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: Motion.of(context, Motion.medium),
    reverseDuration: Motion.of(context, Motion.fast),
    switchInCurve: Motion.enter,
    switchOutCurve: Curves.easeIn,
    layoutBuilder: (current, previous) => Stack(
      alignment: Alignment.topCenter,
      children: [...previous, ?current],
    ),
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, -0.3),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    ),
    child: child ?? const SizedBox.shrink(key: ValueKey('no-status')),
  );
}
