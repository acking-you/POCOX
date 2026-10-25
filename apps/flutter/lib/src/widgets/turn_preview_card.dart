import 'package:flutter/material.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/glass.dart';

/// The turn rail's floating preview: what the user asked, and how the turn
/// answered — a one-line heading over up to three lines of the reply.
class TurnPreviewCard extends StatelessWidget {
  /// Creates the card; at least one of [question] and [reply] has text.
  const TurnPreviewCard({
    super.key,
    required this.question,
    required this.reply,
    required this.width,
  });

  /// The user's message, trimmed; empty for an attachment-only turn.
  final String question;

  /// The turn's final reply, trimmed; empty when it produced no prose.
  final String reply;

  /// Resolved width — the preferred one, or less where the gutter is tight.
  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme.bodyMedium?.copyWith(
      fontFamilyFallback: uiCjkFallback,
    );
    // Glass over the prose it previews: the hairline keeps its edge on a
    // light page, the blur keeps the text beneath from competing.
    return SizedBox(
      key: const Key('turn-minimap-preview'),
      width: width,
      child: Glass(
        depth: GlassDepth.overlay,
        borderRadius: BorderRadius.circular(12),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // An attachment-only turn has no words of its own to head the
            // card, so the reply stands alone rather than under an empty line.
            if (question.isNotEmpty)
              Text(
                question,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.45,
                  color: scheme.onSurface,
                ),
              ),
            if (reply.isNotEmpty) ...[
              if (question.isNotEmpty) const SizedBox(height: 4),
              Text(
                reply,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: text?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
