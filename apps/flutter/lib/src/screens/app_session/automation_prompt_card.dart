import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/automation_prompt.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/motion.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/markdown_view.dart';

/// An automation's turn, on the side the user's turns take: a quiet capsule
/// naming the automation and when it ran, which opens into the instructions
/// it sent.
class AutomationPromptCard extends StatefulWidget {
  /// Creates the card for [prompt].
  const AutomationPromptCard({super.key, required this.prompt});

  /// The automation's prompt.
  final AutomationPrompt prompt;

  @override
  State<AutomationPromptCard> createState() => _AutomationPromptCardState();
}

class _AutomationPromptCardState extends State<AutomationPromptCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final prompt = widget.prompt;
    final at = prompt.at;
    final when = at == null
        ? null
        : DateFormat.Hm(
            Localizations.localeOf(context).toLanguageTag(),
          ).format(at);
    final duration = Motion.of(context, Motion.medium);
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Material(
              color: userBubbleColor(scheme),
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: const Key('automation-prompt-toggle'),
                mouseCursor: clickable,
                onTap: prompt.instructions.isEmpty
                    ? null
                    : () => setState(() => _open = !_open),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(AppIcons.schedule, size: 15, color: muted),
                      const SizedBox(width: 8),
                      Text(
                        l10n.automationRun,
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Flexible(
                        child: Text(
                          ' · ${prompt.automation}${when == null ? '' : ' · $when'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: muted,
                          ),
                        ),
                      ),
                      if (prompt.instructions.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        AnimatedRotation(
                          turns: _open ? 0.5 : 0,
                          duration: duration,
                          child: Icon(
                            AppIcons.expand_more,
                            size: 16,
                            color: muted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            AnimatedSize(
              duration: duration,
              curve: Motion.move,
              alignment: Alignment.topRight,
              child: _open
                  ? Container(
                      margin: const EdgeInsets.only(top: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: userBubbleColor(scheme),
                        borderRadius: BorderRadius.circular(kUserBubbleRadius),
                      ),
                      child: MarkdownView(
                        data: prompt.instructions,
                        dense: true,
                        keepLineBreaks: true,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}
