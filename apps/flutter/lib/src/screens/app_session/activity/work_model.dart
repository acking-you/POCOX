part of '../activity_cards.dart';

/// Everything the agent DID between two messages: a run of consecutive activity
/// items of any mix of types, folded behind one "已处理 {duration}" row.
///
/// The transcript used to show these inline, and only merged runs of the *same*
/// type — so a real turn, which alternates command / reasoning / search,
/// collapsed into nothing and buried the answer under a wall of tool rows. What
/// the reader wants by default is the answer and how long it took; the work is
/// there when they ask for it.
///
/// Two levels on purpose: this folds the whole turn's work, and inside it the
/// same-type sub-runs stay grouped as [ActivityGroup]s, so expanding gives
/// "思考 ×2" rather than four loose rows.
class TurnWork {
  /// Groups [items], the activity between two messages, in transcript order.
  TurnWork(this.items, {this.showDuration = true});

  /// Whether this segment reaches the turn's end and may show its full duration.
  final bool showDuration;

  /// The activity rows, in transcript order.
  final List<TranscriptItem> items;

  /// Item types that stay individual rows inside the fold even when several sit
  /// together, because "×N" would misdescribe them:
  ///
  /// * `contextCompaction` — an event, not a repeated call. Two compactions mean
  ///   the context was squeezed twice, not one thing done twice over.
  /// * `agentMessage` — prose. A "×2" header would hide what it says, which is
  ///   the one thing about a preamble worth reading.
  // A review is about the step it follows, so it stays next to that step
  // rather than merging with other reviews into a "×N" group.
  static const _neverGrouped = {
    'contextCompaction',
    'agentMessage',
    'autoApprovalReview',
  };

  /// Reviews the model made on the user's behalf in this run, and how many of
  /// them refused — surfaced on the fold header so a denial is not hidden.
  ({int total, int refused}) get reviews {
    var total = 0, refused = 0;
    for (final item in items) {
      if (item.type != 'autoApprovalReview') continue;
      total++;
      final status = AutoApprovalReview.parse(item.text)?.status;
      if (status == 'denied' || status == 'timedOut' || status == 'aborted') {
        refused++;
      }
    }
    return (total: total, refused: refused);
  }

  /// The sub-runs, same-type neighbours merged — the second level of the fold.
  ///
  /// A run of one stays a bare item rather than becoming a group of one, which
  /// would add a disclosure triangle that reveals a single row.
  List<Object> get groups {
    final out = <Object>[];
    var i = 0;
    while (i < items.length) {
      if (_neverGrouped.contains(items[i].type)) {
        out.add(items[i]);
        i++;
        continue;
      }
      var j = i + 1;
      while (j < items.length && items[j].type == items[i].type) {
        j++;
      }
      out.add(
        j - i >= 2
            ? ActivityGroup(items[i].type, items.sublist(i, j))
            : items[i],
      );
      i = j;
    }
    return out;
  }

  /// Whether any of this work is still arriving.
  bool get streaming => items.any((i) => i.streaming);

  /// The turn's duration in milliseconds, per the server, or null when it did
  /// not say — a turn still in flight, or an item read from a rollout with no
  /// turn stamp. Never inferred: a made-up number here would read as fact.
  int? get durationMs => !showDuration
      ? null
      : items
            .map((i) => i.turnDurationMs)
            .firstWhere((d) => d != null, orElse: () => null);
}

/// A run of ≥2 consecutive same-type activity items, collapsed into one row.
class ActivityGroup {
  ActivityGroup(this.type, this.items);
  final String type;
  final List<TranscriptItem> items;
}

/// Visual identity for every app-server v2 activity item PocketCodex exposes.
/// Keeping this in one place prevents grouped and individual rows from drifting
/// as upstream adds richer thread-item variants.
({IconData icon, String label}) activityMeta(
  String type,
  AppLocalizations l10n,
) {
  return switch (type) {
    'webSearch' => (icon: AppIcons.travel_explore, label: l10n.toolSearched),
    'commandExecution' => (icon: AppIcons.terminal, label: l10n.toolRan),
    'fileChange' => (icon: AppIcons.edit_document, label: l10n.toolEdited),
    'mcpToolCall' ||
    'dynamicToolCall' => (icon: AppIcons.extension, label: l10n.toolCalled),
    'collabAgentToolCall' => (
      icon: AppIcons.groups_outlined,
      label: l10n.toolCollaborated,
    ),
    'subAgentActivity' => (
      icon: AppIcons.account_tree_outlined,
      label: l10n.toolSubAgent,
    ),
    'imageView' => (
      icon: AppIcons.image_search_outlined,
      label: l10n.toolViewedImage,
    ),
    'imageGeneration' => (
      icon: AppIcons.auto_awesome_outlined,
      label: l10n.toolGeneratedImage,
    ),
    'sleep' => (icon: AppIcons.hourglass_empty, label: l10n.toolWaited),
    'hookPrompt' => (icon: AppIcons.webhook_outlined, label: l10n.toolHook),
    'enteredReviewMode' => (
      icon: AppIcons.fact_check_outlined,
      label: l10n.toolEnteredReview,
    ),
    'exitedReviewMode' => (
      icon: AppIcons.fact_check_outlined,
      label: l10n.toolExitedReview,
    ),
    'reasoning' => (icon: AppIcons.lightbulb_outline, label: l10n.toolThinking),
    'plan' => (icon: AppIcons.checklist, label: l10n.toolPlan),
    _ => (icon: AppIcons.bolt, label: l10n.toolActivity),
  };
}

/// The icon hue for an activity [type]: one per kind of work, so a run of
/// steps can be scanned by colour (commands blue, thinking amber, searches
/// teal, edits green, tool calls rose) before any label is read. Kinds with
/// nothing to tell apart stay the quiet secondary ink.
Color activityTint(String type, ColorScheme scheme) {
  final light = scheme.brightness == Brightness.light;
  return switch (type) {
    'commandExecution' => scheme.tertiary,
    'reasoning' || 'plan' => cautionColor(scheme),
    'webSearch' || 'imageView' || 'imageGeneration' =>
      light ? const Color(0xFF0E7C86) : const Color(0xFF4FC4CC),
    'fileChange' => additionColor(scheme),
    'mcpToolCall' ||
    'dynamicToolCall' ||
    'collabAgentToolCall' ||
    'subAgentActivity' =>
      light ? const Color(0xFFA63D55) : const Color(0xFFEE8FA2),
    _ => scheme.onSurfaceVariant,
  };
}

/// The frame every step row shares: a soft card, the same on a phone and a
/// desktop, so a run of steps reads as a list of things rather than a
/// timeline hung off decorative rules.
BoxDecoration stepCardDecoration(ColorScheme scheme) => BoxDecoration(
  color: scheme.brightness == Brightness.light
      ? scheme.surfaceContainerLowest
      : scheme.surfaceContainerLow,
  border: Border.all(color: scheme.outlineVariant),
  borderRadius: BorderRadius.circular(12),
);

/// A run of ≥2 consecutive `agentMessage` items — one turn's reply, split
/// across several server items — rendered as a single block.
class AgentTurn {
  AgentTurn(this.items);
  final List<TranscriptItem> items;

  /// Still producing text: the block keeps its actions hidden until the whole
  /// reply has settled, not just its first part.
  bool get streaming => items.any((i) => i.streaming);

  /// When the turn finished, per the server.
  int? get completedAt => items.first.turnCompletedAt;

  /// The reply as one document. Blank parts are dropped so a placeholder item
  /// can't open the block with an empty paragraph.
  String get text =>
      items.map((i) => i.text.trim()).where((t) => t.isNotEmpty).join('\n\n');
}
