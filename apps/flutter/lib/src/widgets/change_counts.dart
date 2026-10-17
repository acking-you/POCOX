import 'package:flutter/material.dart';
import 'package:pocket_codex/src/theme.dart';

/// A change's size as "+added −removed" in the addition and removal colours,
/// with tabular figures so counts line up and hold still as they change.
class ChangeCounts extends StatelessWidget {
  /// Creates the counts of [added] and [removed] lines.
  const ChangeCounts({
    super.key,
    required this.added,
    required this.removed,
    this.fontSize = 11.5,
    this.fontWeight,
    this.gap = 4,
  });

  /// Lines added.
  final int added;

  /// Lines removed.
  final int removed;

  /// Size of both figures.
  final double fontSize;

  /// Weight of both figures; the ambient weight when null.
  final FontWeight? fontWeight;

  /// Space between the two figures.
  final double gap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    TextStyle style(Color color) => TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('+$added', style: style(additionColor(scheme))),
        SizedBox(width: gap),
        Text('−$removed', style: style(scheme.error)),
      ],
    );
  }
}
