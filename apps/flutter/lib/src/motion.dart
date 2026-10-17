import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Shared motion tokens.
///
/// Three durations and two curves cover the app: a hover or press answers in
/// [Motion.fast], a panel opening or a row expanding takes [Motion.medium],
/// and a page or the theme changing takes [Motion.slow]. Entrances decelerate
/// ([Motion.enter]); things that move in place ease both ways
/// ([Motion.move]). One vocabulary keeps the app feeling like a single object
/// instead of a dozen widgets each timed by hand.
abstract final class Motion {
  /// Hover, press, small state swaps.
  static const fast = Duration(milliseconds: 120);

  /// Panels, expanding rows, the sidebar sliding.
  static const medium = Duration(milliseconds: 220);

  /// Page transitions and the whole-window theme change.
  static const slow = Duration(milliseconds: 320);

  /// Things arriving: decelerate into place.
  static const Curve enter = Curves.easeOutCubic;

  /// Things moving or resizing in place.
  static const Curve move = Curves.easeInOutCubic;

  /// Arrivals that should feel physical rather than tweened: a quick start
  /// that settles slowly (Material's emphasized decelerate).
  static const Curve emphasized = Cubic(0.05, 0.7, 0.1, 1);

  /// A damped spring with a whisper of overshoot, for things that are
  /// released — a pressed control springing back, a selection gliding to a
  /// new row.
  static const Curve spring = _SpringCurve();

  /// [d], or zero when the platform asks for reduced motion — the state still
  /// changes, it just doesn't travel.
  static Duration of(BuildContext context, Duration d) =>
      _reduced(context) ? Duration.zero : d;

  /// Animate a child's size, or lay it out directly with reduced motion.
  /// A zero-duration AnimatedSize can notify layout from its own layout pass.
  static Widget resize(
    BuildContext context, {
    required Widget child,
    Duration duration = medium,
    AlignmentGeometry alignment = Alignment.center,
    Curve curve = move,
  }) {
    final effective = of(context, duration);
    if (effective == Duration.zero) return child;
    return AnimatedSize(
      duration: effective,
      alignment: alignment,
      curve: curve,
      child: child,
    );
  }

  /// Whether looping, purely decorative motion (pulses, typing dots) may run.
  static bool ambientAllowed(BuildContext context) => !_reduced(context);

  static bool _reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// Ambient loops (sheens, pulses, typing dots, shimmer).
extension AmbientLoop on AnimationController {
  /// Loop while [context] allows ambient motion ([Motion.ambientAllowed]);
  /// otherwise rest at [rest], a frame that still says what the motion says.
  /// Call from `didChangeDependencies`, so a changed preference applies.
  void loopUnlessReduced(
    BuildContext context, {
    double rest = 0,
    bool reverse = false,
  }) {
    if (Motion.ambientAllowed(context)) {
      if (!isAnimating) repeat(reverse: reverse);
    } else {
      stop();
      value = rest;
    }
  }
}

/// The step response of an under-damped spring (damping ratio 0.72), scaled
/// so it settles at 1 by the end of the animation: it overshoots by about 3%
/// and comes back, which reads as a physical release rather than a tween.
class _SpringCurve extends Curve {
  const _SpringCurve();

  static const double _zeta = 0.72;
  static const double _omega = 9.5;

  @override
  double transformInternal(double t) {
    final wd = _omega * math.sqrt(1 - _zeta * _zeta);
    final decay = math.exp(-_zeta * _omega * t);
    final x =
        1 -
        decay * (math.cos(wd * t) + (_zeta * _omega / wd) * math.sin(wd * t));
    // Pin the end exactly: the residual at t = 1 is under 0.1%.
    return t >= 1 ? 1 : x;
  }
}

/// Desktop pages cross-fade instead of Material's mobile zoom, which reads as a
/// phone animation inside a desktop window. Every desktop page shares one
/// frame (the backdrop, the sidebar, the sheet), so a fade leaves that frame
/// still and only the content changes; the content then settles in with its
/// own entrance (see `EntranceMotion`). Mobile keeps each platform's native
/// transition (Cupertino swipe-back on iOS).
const appPageTransitions = PageTransitionsTheme(
  builders: {
    TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: _DesktopPageTransitionsBuilder(),
    TargetPlatform.windows: _DesktopPageTransitionsBuilder(),
    TargetPlatform.linux: _DesktopPageTransitionsBuilder(),
  },
);

class _DesktopPageTransitionsBuilder extends PageTransitionsBuilder {
  const _DesktopPageTransitionsBuilder();

  @override
  Duration get transitionDuration => Motion.medium;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Motion._reduced(context)) return child;
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOut,
        reverseCurve: Curves.easeIn,
      ),
      child: child,
    );
  }
}
