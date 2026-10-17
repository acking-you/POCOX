import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pocket_codex/src/text_measure.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';

/// One padded block inside a hosting editor [GroupCard] section, inset like
/// the card's own header.
class EditorBlock extends StatelessWidget {
  /// Creates a block around [child].
  const EditorBlock({super.key, required this.child});

  /// The block's content.
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.fromLTRB(18, 14, 18, 16), child: child);
}

/// A line of state under the control it belongs to: what was detected, a
/// change waiting to be applied, a problem. Explanations of what a control
/// is for belong in its [InfoTip] or [FocusHelp], not here.
class EditorNote extends StatelessWidget {
  /// Creates a note.
  const EditorNote(this.text, {super.key, this.color});

  /// The note.
  final String text;

  /// Its colour; muted by default.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = helpTextStyle(Theme.of(context));
    return Text(
      text,
      style: color == null ? style : style.copyWith(color: color),
    );
  }
}

/// Whether a [SegmentedButton] of [labels] fits side by side in [width],
/// each label on one line beside the selected segment's check mark.
bool segmentsFitAcross(
  BuildContext context,
  double width,
  List<String> labels,
) {
  final style = Theme.of(context).textTheme.labelLarge;
  // Any segment may be the selected one, with Material's 18 px check mark,
  // its icon padding (12 + 16) and gap (8).
  final segment = labels.fold<double>(
    0,
    (widest, label) => math.max(
      widest,
      12 + 16 + 18 + 8 + measureTextLine(context, label, style).width,
    ),
  );
  // The segments plus the outer and dividing borders.
  return labels.length * segment + labels.length + 1 <= width;
}
