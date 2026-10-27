import 'package:flutter/material.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/desktop_theme.dart';
import 'package:pocox/src/widgets/glass.dart';

/// A whole number in a range, stepped by one: the value between a minus and
/// a plus in the same recessed track as [GlassSegmented], so a count reads
/// as a setting rather than a form field. A bound disables its step.
class GlassStepper extends StatelessWidget {
  /// Creates the stepper for [value] in [min]–[max].
  const GlassStepper({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.semanticLabel,
    this.decreaseKey,
    this.increaseKey,
    this.height = 34,
  });

  /// The number shown.
  final int value;

  /// The smallest allowed value.
  final int min;

  /// The largest allowed value.
  final int max;

  /// Called with the stepped value; null disables both steps.
  final ValueChanged<int>? onChanged;

  /// What the number counts, for screen readers.
  final String? semanticLabel;

  /// The keys of the minus and plus steps.
  final Key? decreaseKey, increaseKey;

  /// The control's height before text scaling.
  final double height;

  static const double _inset = 3;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scaled = MediaQuery.textScalerOf(context).scale(height);
    final radius = BorderRadius.circular(scaled / 2);
    final change = onChanged;
    Widget step(IconData icon, int to, Key? stepKey) {
      final enabled = change != null && to >= min && to <= max;
      return SizedBox.square(
        dimension: scaled - 2 * _inset,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: stepKey,
            mouseCursor: enabled ? clickable : SystemMouseCursors.basic,
            customBorder: const CircleBorder(),
            onTap: enabled ? () => change(to) : null,
            child: Icon(
              icon,
              size: 16,
              color: enabled
                  ? scheme.onSurface
                  : scheme.onSurfaceVariant.withValues(alpha: 0.38),
            ),
          ),
        ),
      );
    }

    return Semantics(
      label: semanticLabel,
      value: '$value',
      increasedValue: value < max ? '${value + 1}' : null,
      decreasedValue: value > min ? '${value - 1}' : null,
      onIncrease: change != null && value < max
          ? () => change(value + 1)
          : null,
      onDecrease: change != null && value > min
          ? () => change(value - 1)
          : null,
      child: ExcludeSemantics(
        child: Container(
          height: scaled,
          padding: const EdgeInsets.all(_inset),
          decoration: BoxDecoration(
            color: glassTrackColor(scheme),
            borderRadius: radius,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              step(AppIcons.remove, value - 1, decreaseKey),
              // Wide enough for the largest value, so stepping never
              // shifts the buttons.
              ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: MediaQuery.textScalerOf(context).scale(30),
                ),
                child: Text(
                  '$value',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              step(AppIcons.add, value + 1, increaseKey),
            ],
          ),
        ),
      ),
    );
  }
}
