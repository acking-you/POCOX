/// Rows for the agent *doing* something: tool calls, plans, and the turn
/// progress they roll up into.
///
/// Belongs here: a widget for a non-message `TranscriptItem`, and the plan
/// parsing those rows share. Messages live in `transcript_view.dart`.
///
/// Note the direction of the dependency: `transcript_view.dart` imports this,
/// because a message row can embed an activity card, and not the reverse.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'approval_review.dart';
import 'approval_review_card.dart';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/git_diff.dart';
import 'package:pocket_codex/src/screens/app_session/diff_view.dart';
import 'package:pocket_codex/src/screens/app_session/model_feedback.dart';
import 'package:pocket_codex/src/screens/app_session/step_body.dart';
import 'package:pocket_codex/src/screens/app_session/transcript_model.dart';
import 'package:pocket_codex/src/motion.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';
import 'package:pocket_codex/src/widgets/links.dart';
import 'package:pocket_codex/src/widgets/markdown_view.dart';
import 'package:pocket_codex/src/widgets/status_dots.dart';

part 'activity/file_changes.dart';
part 'activity/notices.dart';
part 'activity/plans.dart';
part 'activity/tool_cards.dart';
part 'activity/work_model.dart';
part 'activity/work_steps.dart';

/// Provider features the transcript rows below adapt to. Absent means the
/// Codex defaults: Guardian reviews recognised.
class SessionFeatureScope extends InheritedWidget {
  const SessionFeatureScope({
    super.key,
    this.guardianReviews = true,
    required super.child,
  });

  /// Whether Guardian review envelopes render as review cards.
  final bool guardianReviews;

  static SessionFeatureScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SessionFeatureScope>();

  @override
  bool updateShouldNotify(SessionFeatureScope oldWidget) =>
      guardianReviews != oldWidget.guardianReviews;
}

/// The widget for one non-message transcript row.
///
/// The single place an activity item's type picks its widget. Both the flat
/// transcript (via `MessageView`) and the turn-work fold render rows through
/// here, so a new item kind cannot be handled in one place and missed in the
/// other — a compaction shown as a bare tool row inside the fold is exactly how
/// that went wrong once.
Widget activityRow(TranscriptItem item) => switch (item.type) {
  'autoApprovalReview' => _autoApprovalReview(item),
  'fileChange' => FileChangeCard(key: ValueKey(item.id), item: item),
  'plan' => PlanCard(key: ValueKey(item.id), item: item),
  'contextCompaction' => _CompactionNotice(key: ValueKey(item.id), item: item),
  'interrupted' => _InterruptedNotice(key: ValueKey(item.id)),
  'modelError' => ModelErrorCard(key: ValueKey(item.id), body: item.text),
  'reasoningOutput' => ReasoningOutputView(
    key: ValueKey(item.id),
    text: item.text,
  ),
  // An ACP host retains bounded history: its missing beginning is shown as a
  // gap, never as the conversation's start.
  'historyGap' => _HistoryGapNotice(key: ValueKey(item.id)),
  // Content the host could not keep (an oversized image, diff or input) or
  // could not deliver: said where it happened, never silently dropped.
  'contentOmitted' => ContentOmittedNotice(
    key: ValueKey(item.id),
    reasons: item.text,
  ),
  // Prose the agent wrote on its way to the answer (a preamble before a tool
  // batch). It reads as prose, not as a one-line tool row — an `ActivityCard`
  // would show a truncated peek of a paragraph.
  'agentMessage' => _PreambleProse(key: ValueKey(item.id), item: item),
  _ => ActivityCard(key: ValueKey(item.id), item: item),
};

Widget _autoApprovalReview(TranscriptItem item) {
  final review = AutoApprovalReview.parse(item.text);
  if (review == null) return ActivityCard(key: ValueKey(item.id), item: item);
  return ApprovalReviewCard(
    key: ValueKey(item.id),
    raw: item.text,
    request: review.request,
    result: review.result,
    status: review.status,
    compact: true,
  );
}

/// Scroll the transcript (the nearest *vertical* scrollable) so [target] is
/// in view, without moving any horizontal scroller in between — a code block
/// or table scrolls sideways, and `Scrollable.ensureVisible` would otherwise
/// drive those too and assert when the target is wider than them.
void _revealInTranscript(BuildContext target, {double alignment = 0}) {
  final box = target.findRenderObject();
  if (box is! RenderBox || !box.attached) return;
  final position = _transcriptPosition(target);
  if (position == null) return;
  final viewport = RenderAbstractViewport.maybeOf(box);
  if (viewport == null) return;
  // A target taller than the viewport cannot be "made visible"; align its
  // top instead, which is where the reader wants to land anyway.
  final reveal = viewport.getOffsetToReveal(
    box,
    box.size.height > position.viewportDimension ? 0 : alignment,
  );
  _scrollTranscript(target, position, reveal.offset);
}

/// Scroll the transcript just far enough that [target]'s bottom edge is on
/// screen — the newest step of a followed page — and never backwards.
void _revealBottomInTranscript(BuildContext target, {bool animate = false}) {
  final position = _transcriptPosition(target);
  final below = _belowViewport(target);
  if (position == null || below == null || below <= 0) return;
  final offset = position.pixels + below;
  if (animate) {
    _scrollTranscript(target, position, offset);
  } else {
    position.jumpTo(
      offset.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
  }
}

/// How far [target]'s bottom edge lies below the transcript viewport's bottom
/// (negative when it is above it), or null when it is not laid out in one.
double? _belowViewport(BuildContext target) {
  final box = target.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  final position = _transcriptPosition(target);
  final viewport = RenderAbstractViewport.maybeOf(box);
  if (position == null || viewport == null) return null;
  final bottom = viewport.getOffsetToReveal(box, 1).offset;
  return bottom - position.pixels;
}

void _scrollTranscript(
  BuildContext target,
  ScrollPosition position,
  double to,
) {
  final offset = to.clamp(position.minScrollExtent, position.maxScrollExtent);
  final duration = Motion.of(target, Motion.fast);
  if (duration == Duration.zero) {
    position.jumpTo(offset);
  } else {
    position.animateTo(offset, duration: duration, curve: Motion.move);
  }
}

/// The nearest vertical scroll position above [target]: the transcript.
ScrollPosition? _transcriptPosition(BuildContext target) {
  ScrollableState? vertical;
  target.visitAncestorElements((element) {
    if (element is StatefulElement && element.state is ScrollableState) {
      final state = element.state as ScrollableState;
      if (state.axisDirection == AxisDirection.down ||
          state.axisDirection == AxisDirection.up) {
        vertical = state;
        return false;
      }
    }
    return true;
  });
  final scrollable = vertical;
  return scrollable != null && scrollable.position.hasPixels
      ? scrollable.position
      : null;
}
