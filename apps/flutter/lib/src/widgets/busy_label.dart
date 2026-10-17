import 'package:flutter/material.dart';
import 'package:pocket_codex/src/motion.dart';

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
    final Widget content = busy
        ? Row(
            key: const ValueKey('busy'),
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  color: color,
                ),
              ),
              const SizedBox(width: 8),
              // Free to wrap on a narrow button, as the icon buttons' are.
              Flexible(child: Text(busyLabel)),
            ],
          )
        : icon == null
        ? Text(label, key: const ValueKey('idle'))
        : Row(
            key: const ValueKey('idle'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 8),
              Flexible(child: Text(label)),
            ],
          );
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
