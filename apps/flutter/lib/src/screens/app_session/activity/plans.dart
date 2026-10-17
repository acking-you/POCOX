part of '../activity_cards.dart';

/// One parsed plan step.
typedef PlanStep = ({String status, String text});

/// The explanatory lead-in and checklist encoded in one plan item.
typedef ParsedPlan = ({String explanation, List<PlanStep> steps});

final _planStepPattern = RegExp(r'^\s*-\s*\[(.)\]\s?(.*)$');

/// In plan mode the model wraps its proposal in `<proposed_plan>…</proposed_plan>`
/// and codex doesn't always strip the tags, so they leak into the rendered
/// message. Detect them and return the text without the wrapper tags plus an
/// `isPlan` flag the UI uses to badge the message as a plan. Streaming-safe:
/// strips whichever tag has arrived so far (the open tag leads the content).
({bool isPlan, String text}) readProposedPlan(String raw) {
  final open = RegExp(r'<\s*proposed_plan\s*>', caseSensitive: false);
  if (!open.hasMatch(raw)) return (isPlan: false, text: raw);
  final close = RegExp(r'<\s*/\s*proposed_plan\s*>', caseSensitive: false);
  return (
    isPlan: true,
    text: raw.replaceAll(open, '').replaceAll(close, '').trim(),
  );
}

/// Split a plan item's text into its lead-in prose and its checklist steps.
ParsedPlan parsePlan(String text) {
  final explanation = <String>[];
  final steps = <PlanStep>[];
  for (final line in text.split('\n')) {
    final match = _planStepPattern.firstMatch(line);
    if (match != null) {
      final mark = match.group(1)!;
      final status = mark == 'x'
          ? 'completed'
          : mark == '~'
          ? 'in_progress'
          : 'pending';
      steps.add((status: status, text: match.group(2)!.trim()));
    } else if (line.trim().isNotEmpty) {
      explanation.add(line);
    }
  }
  return (explanation: explanation.join('\n'), steps: steps);
}

/// Compact live checklist pinned above the composer while a turn is active.
class TurnProgressTracker extends StatefulWidget {
  const TurnProgressTracker({
    super.key,
    required this.steps,
    required this.changedFiles,
    required this.added,
    required this.removed,
    required this.compact,
    this.onViewDiff,
  });

  final List<PlanStep> steps;
  final int changedFiles;
  final int added;
  final int removed;
  final bool compact;
  final VoidCallback? onViewDiff;

  @override
  State<TurnProgressTracker> createState() => _TurnProgressTrackerState();
}

class _TurnProgressTrackerState extends State<TurnProgressTracker> {
  bool _expanded = true;

  int get _currentStep {
    final active = widget.steps.indexWhere((s) => s.status == 'in_progress');
    if (active >= 0) return active + 1;
    final done = widget.steps.where((s) => s.status == 'completed').length;
    return (done + 1).clamp(1, widget.steps.length);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: !_expanded
              ? const SizedBox.shrink()
              : Glass(
                  key: const Key('turn-progress-panel'),
                  depth: GlassDepth.floating,
                  lift: 0.6,
                  borderRadius: BorderRadius.circular(kPanelRadius),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 210),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final step in widget.steps) _step(step),
                        ],
                      ),
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 4),
        Glass(
          key: const Key('turn-progress-summary'),
          depth: GlassDepth.floating,
          lift: 0.6,
          borderRadius: BorderRadius.circular(999),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The labels give way (ellipsis) before the pill outgrows a
              // narrow conversation.
              Flexible(
                child: InkWell(
                  mouseCursor: clickable,
                  customBorder: const StadiumBorder(),
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
                    child: _summary(l10n, scheme),
                  ),
                ),
              ),
              if (widget.onViewDiff != null) ...[
                SizedBox(
                  height: 22,
                  child: VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: scheme.outlineVariant,
                  ),
                ),
                IconButton(
                  key: const Key('turn-progress-diff'),
                  tooltip: l10n.viewDiff,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 34,
                    height: 30,
                  ),
                  onPressed: widget.onViewDiff,
                  icon: const Icon(AppIcons.difference_outlined, size: 16),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// The pill's face: which step is running, what the turn has changed so
  /// far and whether the checklist is open.
  Widget _summary(AppLocalizations l10n, ColorScheme scheme) {
    final muted = scheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            color: signalColor(scheme),
          ),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            l10n.turnProgressStep(_currentStep, widget.steps.length),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: muted),
          ),
        ),
        if (widget.changedFiles > 0) ...[
          Text('  ·  ', style: TextStyle(color: muted)),
          if (!widget.compact) ...[
            Flexible(
              child: Text(
                l10n.envFilesChanged(widget.changedFiles),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: muted),
              ),
            ),
            const SizedBox(width: 5),
          ],
          ChangeCounts(added: widget.added, removed: widget.removed, gap: 3),
        ],
        const SizedBox(width: 3),
        Icon(
          _expanded ? AppIcons.expand_less : AppIcons.expand_more,
          size: 16,
          color: muted,
        ),
      ],
    );
  }

  Widget _step(PlanStep step) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    final icon = switch (step.status) {
      'completed' => Icon(
        AppIcons.check_circle_outline,
        size: 15,
        color: muted,
      ),
      'in_progress' => SizedBox(
        width: 15,
        height: 15,
        child: CircularProgressIndicator(
          strokeWidth: 1.8,
          color: signalColor(scheme),
        ),
      ),
      _ => Icon(AppIcons.circle_outlined, size: 15, color: muted),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: icon),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              step.text,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.3,
                color: step.status == 'completed' ? muted : scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A status-iconed checklist for a `plan` item (codex `update_plan`). The
/// summarizer encodes the plan as an optional explanation plus `- [x|~| ] step`
/// lines; this renders each step with a completed / in-progress / pending icon.
class PlanCard extends StatefulWidget {
  const PlanCard({super.key, required this.item});
  final TranscriptItem item;

  @override
  State<PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<PlanCard> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final (:explanation, :steps) = parsePlan(widget.item.text);
    final done = steps.where((s) => s.status == 'completed').length;
    final muted = scheme.onSurfaceVariant;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: icon + "Plan" + progress, tap to collapse.
          InkWell(
            mouseCursor: clickable,
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(
                children: [
                  Icon(
                    AppIcons.checklist_rounded,
                    size: 17,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    l10n.toolPlan,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (steps.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      '$done/${steps.length}',
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                  ],
                  const Spacer(),
                  Icon(
                    _expanded ? AppIcons.expand_less : AppIcons.expand_more,
                    size: 18,
                    color: muted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            if (explanation.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: MarkdownView(data: explanation),
              ),
            if (steps.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [for (final s in steps) _stepRow(s)],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _stepRow(PlanStep s) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (s.status) {
      'completed' => (AppIcons.check_circle_rounded, additionColor(scheme)),
      'in_progress' => (AppIcons.timelapse_rounded, signalColor(scheme)),
      _ => (AppIcons.radio_button_unchecked, scheme.onSurfaceVariant),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1, right: 8),
            child: Icon(icon, size: 16, color: color),
          ),
          Expanded(
            child: linkifyText(
              context,
              s.text,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.35,
                color: s.status == 'completed'
                    ? scheme.onSurfaceVariant
                    : scheme.onSurface,
                fontWeight: s.status == 'in_progress'
                    ? FontWeight.w600
                    : FontWeight.normal,
                decoration: s.status == 'completed'
                    ? TextDecoration.lineThrough
                    : null,
                decorationColor: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
