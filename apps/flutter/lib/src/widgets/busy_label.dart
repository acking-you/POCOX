import 'package:flutter/material.dart';
import 'package:pocox/src/motion.dart';

/// A button's label that turns into a small spinner beside [busyLabel] while
/// the button's own action runs, the button resizing smoothly between the
/// two, so a long operation reads as working rather than frozen.
///
/// The spinner takes the button's foreground colour. The button itself stays
/// disabled while it works; give it its working colours as its disabled ones
/// (`disabledBackgroundColor` / `disabledForegroundColor`) meanwhile, so it
/// reads as busy rather than greyed out like the controls waiting on it.
class BusyLabel extends StatelessWidget {
  /// Creates the label; [busy] shows the spinner and [busyLabel].
  const BusyLabel({
    super.key,
    required this.label,
    required this.busyLabel,
    required this.busy,
    this.icon,
  });

  /// The idle label.
  final String label;

  /// What runs, while [busy] ("Starting…").
  final String busyLabel;

  /// Whether the button's action runs.
  final bool busy;

  /// A mark leading the idle label.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color = DefaultTextStyle.of(context).style.color;
    // A lead before the text, which is free to wrap on a narrow button, as
    // the icon buttons' labels are.
    Widget line(String key, Widget? lead, String text) => lead == null
        ? Text(text, key: ValueKey(key))
        : Row(
            key: ValueKey(key),
            mainAxisSize: MainAxisSize.min,
            children: [
              lead,
              const SizedBox(width: 8),
              Flexible(child: Text(text)),
            ],
          );
    final content = busy
        ? line(
            'busy',
            SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 1.8, color: color),
            ),
            busyLabel,
          )
        : line('idle', icon == null ? null : Icon(icon, size: 18), label);
    return Semantics(
      liveRegion: busy,
      child: Motion.resize(
        context,
        duration: Motion.fast,
        child: AnimatedSwitcher(
          duration: Motion.of(context, Motion.fast),
          switchInCurve: Motion.enter,
          switchOutCurve: Curves.easeIn,
          child: content,
        ),
      ),
    );
  }
}
