import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/motion.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/glass.dart';

/// Where the control that opened a popover sits, in global coordinates.
///
/// Pickers are opened from many call sites that only hold their screen's
/// context, not the button's. Rather than thread a key through every one, the
/// app records the control under each pointer press (the outermost
/// button-sized box in the hit path) and, for keyboard activation, falls back
/// to the focused control. A popover then opens from that control, the way a
/// desktop menu does, instead of as a dialog in the middle of the window.
abstract final class PopoverAnchor {
  static Rect? _pressed;
  static DateTime _pressedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static bool _installed = false;

  /// Start recording presses. Idempotent; called once from `main`.
  static void install() {
    if (_installed) return;
    _installed = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  static void _onPointer(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    final binding = WidgetsBinding.instance;
    final result = HitTestResult();
    binding.hitTestInView(result, event.position, event.viewId);
    Rect? best;
    for (final entry in result.path) {
      final target = entry.target;
      if (target is! RenderBox || !target.hasSize || !target.attached) {
        continue;
      }
      final size = target.size;
      if (size.width < 16 || size.height < 16) continue;
      if (size.width > 420 || size.height > 96) {
        if (best != null) break;
        continue;
      }
      best = target.localToGlobal(Offset.zero) & size;
    }
    _pressed = best;
    _pressedAt = DateTime.now();
  }

  /// The control that most plausibly opened what is about to show, or null
  /// when none is known (then callers fall back to a centred surface).
  static Rect? current() {
    final recent =
        DateTime.now().difference(_pressedAt) < const Duration(seconds: 2);
    if (recent && _pressed != null) return _pressed;
    final focus = FocusManager.instance.primaryFocus;
    final rect = focus?.context == null ? null : focus!.rect;
    if (rect != null && rect.width <= 420 && rect.height <= 96) return rect;
    return null;
  }
}

/// Open [builder] as a floating panel attached to [anchor]: below it when
/// there is room, otherwise above, aligned to the control's nearer edge and
/// kept inside the window. Clicking outside or pressing Escape dismisses it;
/// the page behind is neither dimmed nor blurred.
Future<T?> showPopover<T>({
  required BuildContext context,
  required Rect anchor,
  required WidgetBuilder builder,
  double maxWidth = 380,
  double maxHeight = 560,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push<T>(
    _PopoverRoute<T>(
      anchor: anchor,
      builder: builder,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      dismissLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
    ),
  );
}

class _PopoverRoute<T> extends PopupRoute<T> {
  _PopoverRoute({
    required this.anchor,
    required this.builder,
    required this.maxWidth,
    required this.maxHeight,
    required this.capturedThemes,
    required this.dismissLabel,
  });

  final Rect anchor;
  final WidgetBuilder builder;
  final double maxWidth;
  final double maxHeight;
  final CapturedThemes capturedThemes;
  final String dismissLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => dismissLabel;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 360);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final layout = _PopoverLayout(
      anchor: anchor,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      padding: MediaQuery.paddingOf(context),
    );
    // The entrance grows from the control's side.
    final above = layout.opensAbove(MediaQuery.sizeOf(context));
    final curve = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeIn,
    );
    final panel = Glass(
      depth: GlassDepth.overlay,
      borderRadius: BorderRadius.circular(kPanelRadius),
      child: builder(context),
    );
    return capturedThemes.wrap(
      MediaQuery.removePadding(
        context: context,
        removeTop: true,
        removeBottom: true,
        removeLeft: true,
        removeRight: true,
        child: CustomSingleChildLayout(
          delegate: layout,
          child: FadeTransition(
            opacity: curve,
            child: ScaleTransition(
              alignment: above ? Alignment.bottomCenter : Alignment.topCenter,
              scale: Tween<double>(begin: 0.94, end: 1).animate(
                CurvedAnimation(
                  parent: animation,
                  curve: Motion.spring,
                  reverseCurve: Curves.easeIn,
                ),
              ),
              child: panel,
            ),
          ),
        ),
      ),
    );
  }
}

class _PopoverLayout extends SingleChildLayoutDelegate {
  _PopoverLayout({
    required this.anchor,
    required this.maxWidth,
    required this.maxHeight,
    required this.padding,
  });

  final Rect anchor;
  final double maxWidth;
  final double maxHeight;
  final EdgeInsets padding;

  static const double _gap = 8;
  static const double _margin = 12;

  double _below(Size size) =>
      size.height - padding.bottom - anchor.bottom - _gap - _margin;
  double _aboveSpace() => anchor.top - padding.top - _gap - _margin;

  /// Whether the panel opens above [anchor] in a window of [size].
  bool opensAbove(Size size) {
    final below = _below(size);
    return below < math.min(maxHeight, 320) && _aboveSpace() > below;
  }

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final size = constraints.biggest;
    final room = opensAbove(size) ? _aboveSpace() : _below(size);
    return BoxConstraints(
      maxWidth: math.min(maxWidth, size.width - 2 * _margin),
      maxHeight: math.max(120, math.min(maxHeight, room)),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final above = opensAbove(size);
    final y = above
        ? anchor.top - _gap - childSize.height
        : anchor.bottom + _gap;
    // Hang from the control's nearer edge so the panel reads as its own.
    final fromLeft = anchor.center.dx <= size.width / 2;
    final x = fromLeft ? anchor.left : anchor.right - childSize.width;
    return Offset(
      x.clamp(
        _margin,
        math.max(_margin, size.width - childSize.width - _margin),
      ),
      y.clamp(
        padding.top + _margin,
        math.max(
          padding.top + _margin,
          size.height - padding.bottom - childSize.height - _margin,
        ),
      ),
    );
  }

  @override
  bool shouldRelayout(_PopoverLayout old) =>
      anchor != old.anchor ||
      maxWidth != old.maxWidth ||
      maxHeight != old.maxHeight ||
      padding != old.padding;
}
