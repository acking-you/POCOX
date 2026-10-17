part of '../activity_cards.dart';

/// Agent prose inside a turn's fold: the narration before a batch of work.
///
/// Indented and quieter than a reply, so opening a fold does not look like it
/// contains several answers.
class _PreambleProse extends StatelessWidget {
  const _PreambleProse({super.key, required this.item});
  final TranscriptItem item;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: MarkdownView(data: item.text, muted: true),
  );
}

/// "Compacting context…" / "Conversation compacted", per the item's state.
class _CompactionNotice extends StatelessWidget {
  const _CompactionNotice({super.key, required this.item});
  final TranscriptItem item;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SystemNotice(
      icon: AppIcons.compress,
      text: item.streaming ? l10n.compactingContext : l10n.compacted,
      active: item.streaming,
    );
  }
}

/// "Stopped" — the turn was cut short.
class _InterruptedNotice extends StatelessWidget {
  const _InterruptedNotice({super.key});

  @override
  Widget build(BuildContext context) => SystemNotice(
    icon: AppIcons.stop_circle_outlined,
    text: AppLocalizations.of(context).turnStopped,
  );
}

class _HistoryGapNotice extends StatelessWidget {
  const _HistoryGapNotice({super.key});

  @override
  Widget build(BuildContext context) => SystemNotice(
    icon: AppIcons.history_toggle_off,
    text: AppLocalizations.of(context).historyGapNotice,
  );
}

/// What an ACP host left out of an item. [reasons] is the item's text: a
/// comma-separated list of `images`, `diffs`, `input`, `locations`,
/// `content`, `plan` (too large to keep) or `unavailable` (could not be read
/// from the host). Unknown reasons still show the generic notice.
class ContentOmittedNotice extends StatelessWidget {
  const ContentOmittedNotice({super.key, required this.reasons});
  final String reasons;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final parts = reasons
        .split(',')
        .map((r) => r.trim())
        .where((r) => r.isNotEmpty)
        .toList();
    if (parts.contains('unavailable')) {
      return SystemNotice(
        icon: AppIcons.cloud_off_outlined,
        text: l10n.contentUnavailableNotice,
      );
    }
    final names = <String>[
      for (final part in parts)
        switch (part) {
          'images' => l10n.omittedImages,
          'diffs' => l10n.omittedDiffs,
          'input' => l10n.omittedInput,
          'locations' => l10n.omittedLocations,
          'plan' => l10n.omittedPlan,
          _ => l10n.omittedContent,
        },
    ];
    final unique = names.toSet().join(l10n.omittedSeparator);
    return SystemNotice(
      icon: AppIcons.content_cut,
      text: l10n.contentOmittedNotice(
        unique.isEmpty ? l10n.omittedContent : unique,
      ),
    );
  }
}

/// A three-dot "typing" indicator shown while the model is starting a reply.
class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key, required this.elapsed});

  /// Live elapsed-time label (the same value as the status-bar timer);
  /// empty leaves just the pulsing dots.
  final String elapsed;

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion: three steady dots still say "working".
    _c.loopUnlessReduced(context, rest: 0.5);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = signalColor(Theme.of(context).colorScheme);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          ...List.generate(3, (i) {
            return AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                // Stagger each dot's pulse.
                final t = (_c.value + i * 0.2) % 1.0;
                final o = 0.3 + 0.7 * (1 - (t - 0.5).abs() * 2).clamp(0.0, 1.0);
                return Padding(
                  padding: const EdgeInsets.only(right: 5),
                  child: Opacity(
                    opacity: o,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                );
              },
            );
          }),
          // The same live elapsed clock as the status bar, trailing the dots.
          if (widget.elapsed.isNotEmpty) ...[
            const SizedBox(width: 2),
            Text(
              widget.elapsed,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A centered, subtle system notice (e.g. "conversation compacted") so
/// lifecycle state changes are visible inline in the transcript.
class SystemNotice extends StatelessWidget {
  const SystemNotice({
    super.key,
    required this.icon,
    required this.text,
    this.active = false,
  });
  final IconData icon;
  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(child: Divider(color: muted.withValues(alpha: 0.3))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (active)
                  PulsingDot(
                    key: const Key('chat-compaction-progress'),
                    color: muted,
                    size: 8,
                  )
                else
                  Icon(icon, size: 13, color: muted),
                const SizedBox(width: 5),
                Text(text, style: TextStyle(fontSize: 11.5, color: muted)),
              ],
            ),
          ),
          Expanded(child: Divider(color: muted.withValues(alpha: 0.3))),
        ],
      ),
    );
  }
}
