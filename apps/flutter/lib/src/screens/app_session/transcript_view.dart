/// The transcript's message rows: a user or agent message and the footnotes,
/// notices, and file-change cards that hang off one.
///
/// Belongs here: a widget that renders a `TranscriptItem` the user *said* or the
/// agent *replied*. A row representing the agent using a tool is activity, and
/// lives in `activity_cards.dart`.
library;

import 'package:flutter/material.dart';
import 'package:pocket_codex/src/automation_prompt.dart';
import 'package:pocket_codex/src/screens/app_session/automation_prompt_card.dart';
import 'approval_review.dart';
import 'async_questions.dart';
import 'generated_image_card.dart';
import 'message_actions.dart';
import 'model_feedback.dart';
import 'approval_review_card.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/app_modes.dart';
import 'package:pocket_codex/src/attachment_refs.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/ide_context.dart';
import 'package:pocket_codex/src/screens/app_session/activity_cards.dart';
import 'package:pocket_codex/src/screens/app_session/transcript_model.dart';
import 'package:pocket_codex/src/realtime_delegation.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/tools/share_card.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';
import 'package:pocket_codex/src/widgets/markdown_view.dart';
import 'package:pocket_codex/src/widgets/message_images.dart';
import 'package:pocket_codex/src/widgets/realtime_handoff_card.dart';
import 'package:pocket_codex/src/app_icons.dart';

/// The "this reply is a plan" marker.
Widget _planBadge(BuildContext context, ColorScheme scheme) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    Icon(AppIcons.checklist_rounded, size: 16, color: scheme.primary),
    const SizedBox(width: 6),
    Text(
      AppLocalizations.of(context).toolPlan,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: scheme.primary,
      ),
    ),
  ],
);

/// Renders one timeline entry. Messages render Gemini-style (user = soft
/// right bubble, agent = full-width Markdown); tool/activity items render as a
/// collapsible [ActivityCard]. Message copy fades in on hover (desktop);
/// mobile long-press opens a menu with a dedicated text-selection surface.
class MessageView extends StatefulWidget {
  const MessageView({
    super.key,
    required this.item,
    this.hostImageLoader,
    this.imageCacheScope,
    this.onEdit,
    this.errorActions,
  });
  final TranscriptItem item;

  /// What a `modelError` row offers; null for a failure that is history.
  final ModelErrorActions? errorActions;

  /// Reads a host-side image so a mentioned file renders as a picture.
  final HostImageLoader? hostImageLoader;
  final Object? imageCacheScope;

  /// Reuses the visible user prompt in the conversation's draft editor.
  final ValueChanged<String>? onEdit;

  @override
  State<MessageView> createState() => _MessageViewState();
}

class _MessageViewState extends State<MessageView> {
  String? _reviewText;
  ApprovalReviewRequest? _reviewRequest;
  ApprovalReviewResult? _reviewResult;
  // Hover drives only the copy-button fade. Held in a notifier (not setState)
  // so a hover repaint doesn't rebuild the message content: its Markdown,
  // highlighted code and link recognizers.
  final ValueNotifier<bool> _hover = ValueNotifier(false);

  @override
  void dispose() {
    _hover.dispose();
    super.dispose();
  }

  /// A turn's completion time, from `Turn.completedAt` (Unix seconds).
  ///
  /// Today's turns show only the clock — the date would be noise in a
  /// conversation you are still having. Anything older leads with the weekday
  /// (this week) or the date, so scrolling back through a long thread tells you
  /// when each answer happened.
  String _fmtTurnTime(int unixSeconds) {
    final at = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    final now = DateTime.now();
    final locale = Localizations.localeOf(context).toLanguageTag();
    final clock = DateFormat.Hm(locale).format(at);
    final sameDay =
        at.year == now.year && at.month == now.month && at.day == now.day;
    if (sameDay) return clock;
    final age = now.difference(at);
    if (age.inDays < 7) return '${DateFormat.EEEE(locale).format(at)} $clock';
    return '${DateFormat.Md(locale).format(at)} $clock';
  }

  void _copy() {
    final l10n = AppLocalizations.of(context);
    // Copy what's shown — without the <proposed_plan> wrapper tags.
    Clipboard.setData(
      ClipboardData(text: readProposedPlan(widget.item.text).text),
    );
    showToastOk(context, l10n.copied);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    if (item.type == 'modelError') {
      return ModelErrorCard(body: item.text, actions: widget.errorActions);
    }
    if (item.type == 'reasoningOutput') {
      return ReasoningOutputView(text: item.text);
    }
    if (item.share case final share?) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ShareCard(share: share),
          ),
        ),
      );
    }
    if (item.type == 'imageGeneration') {
      return GeneratedImageCard(
        item: item,
        hostImageLoader: widget.hostImageLoader,
        imageCacheScope: widget.imageCacheScope,
      );
    }
    // Tool / activity items get specialised rendering: plans → checklist, file
    // changes → reviewable diff, compaction → a system notice; everything else →
    // a subtle single-line activity row. Dispatched through [activityRow], which
    // the turn-work fold also uses, so a kind cannot be handled in one and missed
    // in the other. The turn footnote stays here: it is not activity, and the
    // fold never contains one.
    if (!item.isMessage) {
      final Widget child = item.type == 'turnDuration'
          ? TurnDurationFooter(
              duration: item.title,
              completedAt: item.text,
              model: item.model,
              effortWire: item.effortWire,
              confirmed: item.modelConfirmed,
              rerouted: item.modelRerouted,
            )
          : activityRow(item);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: child,
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final isUser = item.isUser;
    if (!identical(_reviewText, item.text)) {
      _reviewText = item.text;
      _reviewRequest = isUser ? ApprovalReviewRequest.parse(item.text) : null;
      _reviewResult = isUser ? null : ApprovalReviewResult.parse(item.text);
    }
    final guardian =
        SessionFeatureScope.maybeOf(context)?.guardianReviews ?? true;
    if (guardian && (_reviewRequest != null || _reviewResult != null)) {
      return ApprovalReviewCard(
        raw: item.text,
        request: _reviewRequest,
        result: _reviewResult,
      );
    }
    // An automation's run is not something the user typed: it names the
    // automation and keeps its instructions a tap away.
    final automation = isUser ? AutomationPrompt.parse(item.text) : null;
    if (automation != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: AutomationPromptCard(prompt: automation),
      );
    }
    // A Live voice handoff is a different kind of turn: a stretch of spoken
    // back-and-forth, not one typed message. It gets its own card.
    final handoff = isUser ? parseRealtimeDelegation(item.text) : null;
    if (handoff != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: RealtimeHandoffCard(handoff: handoff),
      );
    }
    // A plan-mode proposal streams in wrapped in `<proposed_plan>…</proposed_plan>`
    // tags that codex doesn't strip. Remove them at the display layer and badge
    // the message as a plan, so the UI perceives it as a plan instead of leaking
    // the raw markup. The stored item text is untouched (display-only).
    final proposal = readProposedPlan(item.text);
    // Document attachments ride the text as a trailing path-reference block
    // (wire format); render them as chips and show only the typed text —
    // display-only, the stored item text (and the copy action) keep the block.
    // A message from a client with editor context (IDE extension, desktop app,
    // codex TUI) arrives with that context serialized ahead of the request;
    // upstream expects every transcript renderer to strip back to the request
    // and we surface the files it named as attachments. Display-only — the
    // stored text, and the copy action, keep the message verbatim.
    final ide = isUser
        ? splitIdeContext(displayAsyncQuestionReply(item.text))
        : plainIdeSplit(item.text);
    final refs = isUser
        ? splitFileRefs(ide.text)
        : (text: ide.text, paths: const <String>[]);
    // Reply passages the user annotated read as quotes ahead of the request.
    final shown = ideDisplayText(refs.text, ide.annotations);
    final images = [
      ...item.images,
      for (final path in unattachedImageMentions(ide.files, item.images))
        ResolvedImage.hostFile(path),
    ];
    final paths = [
      for (final f in ide.files)
        if (!looksLikeImagePath(f.path)) f.path,
      ...refs.paths,
    ];
    // Desktop reads as a document, not as a chat: a coding agent's transcript
    // is something you scan and scroll back through, so turns are blocks with
    // a role label and an accent rail rather than iOS bubbles. Narrow windows
    // keep the bubbles, which is the right idiom for a thumb.
    final doc = MediaQuery.sizeOf(context).width >= docLayoutWidth;
    // The reference desktop app keeps the user's turn as a right-aligned
    // bubble and leaves the reply as plain prose — same shapes as the phone,
    // just tighter: a smaller radius and less padding, because a 20 px pill is
    // a touch-target look that reads as oversized under a pointer.
    // Attachments sit ABOVE the bubble, not inside it. An image wrapped in the
    // text bubble made the bubble a container for two unlike things — the
    // picture picked up the bubble's padding and background, and a
    // picture-only message rendered as a mostly-empty bubble. Separating them
    // also keeps the thumbnail identical to the one staged in the composer.
    final Widget? attachments = images.isEmpty && paths.isEmpty
        ? null
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (images.isNotEmpty)
                MessageImagesView(
                  images: images,
                  hostImageLoader: widget.hostImageLoader,
                  cacheScope: widget.imageCacheScope,
                ),
              if (images.isNotEmpty && paths.isNotEmpty)
                const SizedBox(height: 6),
              if (paths.isNotEmpty) FileRefChips(paths: paths),
            ],
          );
    final Widget content = isUser
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (attachments != null) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: attachments,
                ),
                // Only when text follows: a bare attachment shouldn't leave
                // trailing space under the last row.
                if (shown.isNotEmpty) const SizedBox(height: 6),
              ],
              // A message with no text at all is just its attachments — an
              // empty bubble under them would be a visible artifact.
              if (shown.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxWidth: 640),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 11,
                  ),
                  // A soft neutral bubble with a tucked corner on the
                  // speaker's side, so the user's turns read as theirs
                  // without a colour of their own.
                  decoration: BoxDecoration(
                    color: userBubbleColor(scheme),
                    borderRadius: kUserBubbleShape,
                  ),
                  // Typed Markdown renders as Markdown — a pasted snippet in
                  // backticks or a short list reads the way it was written
                  // — while every line break the user typed is kept.
                  child: MarkdownView(
                    data: shown,
                    dense: true,
                    keepLineBreaks: true,
                  ),
                ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (proposal.isPlan) ...[
                _planBadge(context, scheme),
                const SizedBox(height: 6),
              ],
              SizedBox(
                width: double.infinity,
                child: MarkdownView(data: proposal.text),
              ),
            ],
          );

    // No copy for an image-only message (empty text) — it would clobber the
    // clipboard with an empty string while confirming "copied".
    final showActions = !item.streaming && item.text.trim().isNotEmpty;
    final onEdit = widget.onEdit;
    final mobile = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    // Only this subtree rebuilds on hover; `content` above is built once.
    final actions = SizedBox(
      height: 30,
      child: ValueListenableBuilder<bool>(
        valueListenable: _hover,
        builder: (context, hover, _) {
          final visible = hover && showActions;
          return AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 120),
            child: IgnorePointer(
              ignoring: !visible,
              child: Align(
                // Document layout runs left-aligned for both roles, so the
                // copy affordance follows the text rather than the bubble.
                alignment: isUser
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MessageAction(
                      icon: AppIcons.content_copy_outlined,
                      tooltip: AppLocalizations.of(context).copy,
                      onPressed: _copy,
                    ),
                    // The turn's completion time, from the server's own
                    // `Turn.completedAt` — so it survives a reload, unlike the
                    // locally-observed duration marker.
                    if (item.turnCompletedAt != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        _fmtTurnTime(item.turnCompletedAt!),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: onSurfaceMuted(scheme),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );

    return MouseRegion(
      onEnter: (_) => _hover.value = true,
      onExit: (_) => _hover.value = false,
      child: Padding(
        padding: EdgeInsets.only(top: doc ? 14 : 8),
        child: Column(
          crossAxisAlignment: isUser
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (mobile &&
                showActions &&
                (!isUser || refs.text.trim().isNotEmpty))
              MessageActions(
                text: isUser ? refs.text : proposal.text,
                isUser: isUser,
                completedAtLabel: item.turnCompletedAt == null
                    ? null
                    : AppLocalizations.of(
                        context,
                      ).completedAt(_fmtTurnTime(item.turnCompletedAt!)),
                onEdit: isUser && refs.text.trim().isNotEmpty && onEdit != null
                    ? () => onEdit(refs.text)
                    : null,
                child: content,
              )
            else
              content,
            actions,
          ],
        ),
      ),
    );
  }
}

/// A per-turn footnote dropped in after a turn ends: a subtle `用时 m:ss` tag
/// plus the model (and effort) that actually handled the turn, so a mid-chat
/// model switch is verifiable per response. The tooltip (hover on desktop,
/// long-press on mobile) reveals the wall-clock completion time and the
/// stamp's provenance — server-confirmed vs as-sent-by-the-app — and flags a
/// mid-turn server reroute.
class TurnDurationFooter extends StatelessWidget {
  const TurnDurationFooter({
    super.key,
    required this.duration,
    required this.completedAt,
    this.model,
    this.effortWire,
    this.confirmed = false,
    this.rerouted = false,
  });

  final String duration;
  final String completedAt;
  final String? model;
  final String? effortWire;
  final bool confirmed;
  final bool rerouted;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    final effort = ReasoningEffort.fromWire(effortWire);
    final modelText = model == null
        ? null
        : effort == null
        ? model!
        : '$model · ${effort.label(l10n)}';
    final tooltip = [
      l10n.completedAt(completedAt),
      if (model != null) l10n.turnHandledBy(model!),
      if (rerouted)
        l10n.modelReroutedNote
      else if (model != null)
        confirmed ? l10n.runtimeConfirmed : l10n.runtimeUnconfirmed,
    ].join('\n');
    return Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message: tooltip,
        child: Padding(
          padding: const EdgeInsets.only(left: 6, top: 2, bottom: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.schedule, size: 12, color: muted),
              const SizedBox(width: 4),
              Text(
                l10n.turnElapsed(duration),
                style: TextStyle(
                  fontSize: 11.5,
                  color: muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (modelText != null) ...[
                const SizedBox(width: 8),
                Icon(AppIcons.auto_awesome, size: 11, color: muted),
                const SizedBox(width: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Text(
                    modelText,
                    key: const Key('turn-model-stamp'),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: muted),
                  ),
                ),
                if (rerouted) ...[
                  const SizedBox(width: 3),
                  Icon(
                    AppIcons.sync_problem,
                    size: 11,
                    color: cautionColor(scheme),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
