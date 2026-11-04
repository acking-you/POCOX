import 'package:flutter/material.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/glass.dart';

/// What stands in for a composer while a page only reads: the same pane of
/// glass, so the conversation passes beneath it blurred rather than showing
/// through between its controls.
class ReadOnlyFoot extends StatelessWidget {
  /// Creates the foot, no wider than the reading column's [maxWidth].
  const ReadOnlyFoot({super.key, required this.maxWidth, required this.child});

  /// The reading column's width.
  final double maxWidth;

  /// Its state and actions.
  final Widget child;

  /// The height of a control in it: a finger's target on touch.
  static double get controlHeight => isDesktop ? 42 : 44;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Glass(
            depth: GlassDepth.floating,
            borderRadius: BorderRadius.circular(
              isDesktop ? kComposerRadius : kTouchComposerRadius,
            ),
            lift: 0.7,
            child: Padding(padding: const EdgeInsets.all(8), child: child),
          ),
        ),
      ),
    ),
  );
}

/// A foot's one line: [lead] filling it and [actions] at its end. Where names
/// would crowd the lead, as on a phone, the actions keep their place as round
/// marks of the same height rather than dropping to a line of their own.
class ReadOnlyFootRow extends StatelessWidget {
  /// Creates the row.
  const ReadOnlyFootRow({
    super.key,
    required this.lead,
    this.actions = const [],
  });

  /// Below this width, at default text, the actions give up their names.
  static const double _namedWidth = 360;

  /// The state, or the main thing to do.
  final Widget lead;

  /// [ReadOnlyFootAction]s.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    if (actions.isEmpty) return lead;
    return LayoutBuilder(
      builder: (context, box) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        return _FootRoom(
          marksOnly: box.maxWidth / scale < _namedWidth,
          child: Row(
            children: [
              Expanded(child: lead),
              for (final action in actions) ...[
                const SizedBox(width: 6),
                action,
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Tells a row's actions whether their names fit.
class _FootRoom extends InheritedWidget {
  const _FootRoom({required this.marksOnly, required super.child});

  final bool marksOnly;

  @override
  bool updateShouldNotify(_FootRoom oldWidget) =>
      marksOnly != oldWidget.marksOnly;
}

/// A secondary control of a foot: its mark and name, or the mark alone on a
/// round plate where [ReadOnlyFootRow] has no room for the name, which then
/// serves as its tooltip.
class ReadOnlyFootAction extends StatelessWidget {
  /// Creates the action.
  const ReadOnlyFootAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  /// Its mark.
  final IconData icon;

  /// Its name.
  final String label;

  /// What it does; null while it cannot.
  final VoidCallback? onPressed;

  /// It is under way: progress takes the mark's place.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final height = ReadOnlyFoot.controlHeight;
    final scheme = Theme.of(context).colorScheme;
    final mark = busy
        ? const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(icon, size: 18);
    final room = context.dependOnInheritedWidgetOfExactType<_FootRoom>();
    if (room?.marksOnly ?? false) {
      return IconButton(
        tooltip: label,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          minimumSize: Size.square(height),
          fixedSize: Size.square(height),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: const CircleBorder(),
          foregroundColor: scheme.onSurface,
          backgroundColor: softWash(scheme, strength: 1.6),
          disabledBackgroundColor: softWash(scheme),
        ),
        icon: mark,
      );
    }
    return SizedBox(
      height: height,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: mark,
        label: Text(label, maxLines: 1),
      ),
    );
  }
}
