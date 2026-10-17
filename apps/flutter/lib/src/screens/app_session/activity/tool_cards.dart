part of '../activity_cards.dart';

/// One glyph in a message's hover action row.
///
/// A washed square on hover rather than a bare icon: the reference app's row of
/// actions reads as a set of small controls, and an icon that only changes ink
/// gives no target to aim at under a pointer.
class MessageAction extends StatefulWidget {
  const MessageAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<MessageAction> createState() => _MessageActionState();
}

class _MessageActionState extends State<MessageAction> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              // Off-state is the wash at zero alpha, not transparent: Material
              // lerps through transparent BLACK, which flashes a dark box.
              color: _hovered
                  ? scheme.surfaceContainerHigh
                  : scheme.surfaceContainerHigh.withValues(alpha: 0),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              widget.icon,
              size: 15,
              color: _hovered ? scheme.onSurface : onSurfaceMuted(scheme),
            ),
          ),
        ),
      ),
    );
  }
}

/// Collapses a run of same-type tool calls (e.g. several shell commands) into a
/// single low-chrome row ("Ran command ×3") that expands to the individual
/// [ActivityCard]s — so long tool sequences don't flood the transcript.
class GroupedActivityCard extends StatefulWidget {
  const GroupedActivityCard({super.key, required this.group});
  final ActivityGroup group;

  @override
  State<GroupedActivityCard> createState() => _GroupedActivityCardState();
}

class _GroupedActivityCardState extends State<GroupedActivityCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    final meta = activityMeta(widget.group.type, l10n);
    final n = widget.group.items.length;
    final anyStreaming = widget.group.items.any((i) => i.streaming);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          decoration: stepCardDecoration(scheme),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            mouseCursor: clickable,
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    meta.icon,
                    size: 17,
                    color: activityTint(widget.group.type, scheme),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${meta.label} ×$n',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const Spacer(),
                  if (anyStreaming)
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: muted,
                      ),
                    )
                  else
                    Icon(
                      _expanded ? AppIcons.expand_less : AppIcons.expand_more,
                      size: 18,
                      color: muted.withValues(alpha: 0.7),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 14, top: 1, bottom: 2),
            child: widget.group.items.length > 40
                ? _WorkSteps(items: widget.group.items, active: anyStreaming)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final it in widget.group.items)
                        it.type == 'fileChange'
                            ? FileChangeCard(item: it)
                            : ActivityCard(item: it),
                    ],
                  ),
          ),
      ],
    );
  }
}

/// A collapsible card for a tool / activity item (web search, command, file
/// edit, MCP/skill call, reasoning, …) so the user can see — and expand — what
/// the agent is doing, like Codex / Gemini.
class ActivityCard extends StatefulWidget {
  const ActivityCard({super.key, required this.item});
  final TranscriptItem item;

  @override
  State<ActivityCard> createState() => _ActivityCardState();
}

class _ActivityCardState extends State<ActivityCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final item = widget.item;
    final meta = activityMeta(item.type, l10n);
    final muted = scheme.onSurfaceVariant;
    final title = item.title.trim();
    final detail = item.text.trim();
    // Reasoning is prose the model wrote in Markdown (its summaries open with
    // a `**bold**` header); everything else here is literal output — a command
    // line, a tool payload, a diff — where a `*` means an asterisk and the
    // monospace column matters. Only the prose gets rendered as Markdown.
    final prose = item.type == 'reasoning';
    // One-line value: the title (command/query/tool) or a peek of the detail.
    final rawValue = title.isNotEmpty
        ? title
        : detail
              .split('\n')
              .firstWhere((s) => s.trim().isNotEmpty, orElse: () => '');
    final value = prose ? markdownPlainPreview(rawValue) : rawValue;
    // Expandable when there's detail or the value is long enough to truncate.
    final expandable = detail.isNotEmpty || value.length > 56;
    final body = [
      if (title.isNotEmpty) title,
      if (detail.isNotEmpty) detail,
    ].join('\n\n');

    // One idiom on every width: a soft card per step, its icon tinted by the
    // kind of work. (Desktop used to hang steps off a left rail; next to the
    // fold that read as stray lines rather than structure.)
    final doc = MediaQuery.sizeOf(context).width >= docLayoutWidth;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      decoration: stepCardDecoration(scheme),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            mouseCursor: clickable,
            onTap: expandable
                ? () => setState(() => _expanded = !_expanded)
                : null,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: doc ? 8 : 10,
              ),
              child: Row(
                children: [
                  Icon(
                    meta.icon,
                    size: doc ? 16 : 17,
                    color: activityTint(item.type, scheme),
                  ),
                  SizedBox(width: doc ? 9 : 10),
                  Text(
                    meta.label,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (value.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: prose
                            ? TextStyle(fontSize: 12.5, color: muted)
                            : TextStyle(
                                fontFamily: monoFontFamily,
                                fontFamilyFallback: monoCjkFallback,
                                fontSize: 12,
                                color: muted,
                              ),
                      ),
                    ),
                  ] else
                    const Spacer(),
                  if (item.streaming)
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: muted,
                      ),
                    )
                  else if (expandable)
                    Icon(
                      _expanded ? AppIcons.expand_less : AppIcons.expand_more,
                      size: 18,
                      color: muted.withValues(alpha: 0.7),
                    ),
                ],
              ),
            ),
          ),
          if (_expanded && body.isNotEmpty && !prose)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: StepBody(item: item),
            ),
          if (_expanded && body.isNotEmpty && prose)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              padding: const EdgeInsets.all(11),
              constraints: const BoxConstraints(maxHeight: 320),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: scheme.surfaceContainer.withValues(alpha: 0.6),
              ),
              child: SingleChildScrollView(
                child: MarkdownView(data: body, muted: true),
              ),
            ),
        ],
      ),
    );
  }
}
