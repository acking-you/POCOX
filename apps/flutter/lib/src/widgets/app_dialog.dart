import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Show a modal dialog in the app's own idiom: the page behind softly blurs
/// and dims, and the dialog rises into place with a short scale + fade
/// instead of Material's plain fade.
///
/// A drop-in for [showDialog]: same builder, same result. Use it for every
/// modal question (confirmations, short forms); pickers and information
/// anchored to a control use `showAdaptivePanel(anchored: true)` instead.
///
/// A [fullscreen] surface (`Dialog.fullscreen`) covers the whole window,
/// status bar and home indicator included, and keeps its own safe areas; it
/// rises into place rather than scaling, since it has no edges to grow from.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool fullscreen = false,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push<T>(
    _AppDialogRoute<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      fullscreen: fullscreen,
    ),
  );
}

class _AppDialogRoute<T> extends DialogRoute<T> {
  _AppDialogRoute({
    required super.context,
    required super.builder,
    super.barrierDismissible,
    super.barrierLabel,
    super.themes,
    required this.fullscreen,
  }) : super(barrierColor: Colors.transparent, useSafeArea: !fullscreen);

  final bool fullscreen;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 150);

  @override
  Widget buildModalBarrier() {
    final light = Theme.of(navigator!.context).brightness == Brightness.light;
    final fade = CurvedAnimation(parent: animation!, curve: Curves.easeOut);
    return Stack(
      fit: StackFit.expand,
      children: [
        // The blur is display-only; taps fall through to the barrier.
        IgnorePointer(
          child: AnimatedBuilder(
            animation: fade,
            builder: (context, _) {
              final t = fade.value;
              return BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 12 * t, sigmaY: 12 * t),
                child: ColoredBox(
                  color: Colors.black.withValues(
                    alpha: (light ? 0.14 : 0.4) * t,
                  ),
                ),
              );
            },
          ),
        ),
        super.buildModalBarrier(),
      ],
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curve = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    if (fullscreen) {
      return FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.04),
            end: Offset.zero,
          ).animate(curve),
          child: child,
        ),
      );
    }
    return FadeTransition(
      opacity: curve,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.95, end: 1).animate(curve),
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.015),
            end: Offset.zero,
          ).animate(curve),
          child: child,
        ),
      ),
    );
  }
}
