import 'package:flutter/material.dart';

/// [lead] with its [action] at the end of the row, or under it when the row
/// is too narrow for both: the action keeps its natural size and the text its
/// width, instead of either being squeezed.
class ActionRow extends StatelessWidget {
  /// Creates the row.
  const ActionRow({super.key, required this.lead, required this.action});

  /// What the row is about (a title and its description, a state line).
  final Widget lead;

  /// The row's control.
  final Widget action;

  /// The narrowest width that still holds both side by side.
  static const double _minWidth = 420;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth >= _minWidth) {
        return Row(
          children: [
            Expanded(child: lead),
            const SizedBox(width: 16),
            action,
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [lead, const SizedBox(height: 10), action],
      );
    },
  );
}
