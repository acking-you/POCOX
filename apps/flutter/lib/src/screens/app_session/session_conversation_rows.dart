part of '../app_session_screen.dart';

extension _SessionConversationRows on _AppSessionState {
  /// A row's inset from its plate edge to its content.
  static const double _rowInset = 10;

  /// What is waiting in a conversation: its live call, its draft and what is
  /// queued.
  List<String> _rowFacts(ThreadMeta thread, AppLocalizations l10n) => [
    if (thread.isVoice) l10n.voiceLive,
    if (_drafts.hasDraft(thread.id)) l10n.draft,
    if (_drafts.queuedCount(thread.id) > 0)
      l10n.queuedCount(_drafts.queuedCount(thread.id)),
  ];

  /// What a row calls a conversation. Server previews are the first user
  /// message verbatim, which may be wire text (an attachment block) or codex's
  /// own machinery (a context fragment): both resolve through the cleaner. A
  /// user-set name wins over the preview, matching the top bar.
  String _threadName(ThreadMeta thread, AppLocalizations l10n) {
    final cleaned = previewWithoutFileRefs(
      thread.preview,
      l10n.fileOnlyMessage,
    ).trim();
    return thread.title ?? (cleaned.isEmpty ? l10n.untitledThread : cleaned);
  }

  /// One conversation row: a soft rounded tile with a leading icon, the preview
  /// as title, and a relative-time (or "running") subtitle — the same card
  /// language used by the guidance/option cards across the app.
  Widget _conversationTile({
    required ThreadMeta thread,
    required bool running,
    required bool selected,
    required DateTime now,
    required AppLocalizations l10n,
    required VoidCallback onTap,
    required double titleInset,
    String? project,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fg = scheme.onSurface;
    final muted = scheme.onSurfaceVariant;
    final when = running
        ? l10n.running
        : _relativeTime(thread.updatedAt, now, l10n);
    // Server previews are the first user message verbatim, which may be wire
    // text (an attachment block) or codex's own machinery (a context
    // fragment). Both resolve through the cleaner; nothing left means there is
    // no title to show.
    final title = _threadName(thread, l10n);
    // Cross-project pane rows show "project · time" so the user always knows
    // where a conversation lives.
    // Facts about the row, ahead of the time: what is waiting in it, and where
    // it lives when no project heading above says so.
    final facts = [..._rowFacts(thread, l10n), ?project];
    final signal = signalColor(scheme);
    // Rows are one line — title, then the time at the trailing edge — the way
    // a source list sits: twice as many conversations per screen, and the eye
    // scans titles without a second line breaking the column. A finger's row
    // keeps a target's height around that line.
    final dense = isDesktop;
    final titleText = _withForkBadge(
      thread,
      Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: dense ? 13 : 15,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: fg,
        ),
      ),
      l10n,
    );
    final factsText = facts.isEmpty
        ? null
        : Text(
            facts.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11.5, color: muted),
          );
    final trailing = running
        ? _runningMark(l10n, scheme)
        : when.isEmpty
        ? null
        : Text(
            when,
            maxLines: 1,
            style: TextStyle(
              fontSize: 11.5,
              color: muted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          );
    final content = Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        titleInset,
        dense ? 6 : 12,
        _rowInset,
        dense ? 6 : 12,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Preserve the title when large text or a narrow sidebar would let
          // metadata consume its entire line.
          final stacked =
              constraints.maxWidth < 220 ||
              MediaQuery.textScalerOf(context).scale(13) > 18;
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                titleText,
                if (factsText != null || trailing != null) ...[
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: 8,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ?factsText,
                      if (running)
                        _runningMark(
                          l10n,
                          scheme,
                          maxLabelWidth: (constraints.maxWidth - 17).clamp(
                            0,
                            double.infinity,
                          ),
                          wrap: true,
                        )
                      else
                        ?trailing,
                    ],
                  ),
                ],
              ],
            );
          }
          return Row(
            children: [
              if (thread.isVoice) ...[
                Icon(AppIcons.graphic_eq, size: 15, color: muted),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Row(
                  children: [
                    Flexible(child: titleText),
                    if (factsText != null) ...[
                      const SizedBox(width: 6),
                      Flexible(child: factsText),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing],
            ],
          );
        },
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 0.5),
      child: _rowPlate(
        key: Key('conv-tile-${thread.id}'),
        selected: selected,
        radius: kRowRadius,
        child: InkWell(
          mouseCursor: clickable,
          borderRadius: BorderRadius.circular(kRowRadius),
          hoverColor: backdropHover(Theme.of(context).colorScheme),
          onTap: onTap,
          child: running
              ? RunningSheen(color: signal, child: content)
              : content,
        ),
      ),
    );
  }

  /// A sidebar row's ground. The open conversation is a neutral plate raised
  /// out of the source list, found by its lift rather than by a second
  /// accent, so the blue stays the signal for live work alone.
  Widget _rowPlate({
    required Key key,
    required bool selected,
    required double radius,
    required Widget child,
  }) {
    final scheme = Theme.of(context).colorScheme;
    // Touch: a soft tonal plate without edge or shadow — on a full-screen
    // list the lift reads as clutter, the tone alone finds the row.
    final touch = !isDesktop;
    return Material(
      key: key,
      color: selected
          ? (touch ? surfaceSelection(scheme) : sidebarSelection(scheme))
          : Colors.transparent,
      elevation: selected && !touch ? 1 : 0,
      shadowColor: sidebarSelectionShadow(scheme),
      surfaceTintColor: Colors.transparent,
      animationDuration: Motion.of(context, Motion.fast),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(touch ? kRowRadius : radius),
        side: selected && !touch
            ? BorderSide(color: sidebarSelectionEdge(scheme))
            : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: Semantics(container: true, selected: selected, child: child),
    );
  }

  /// The trailing mark of a running row: a turning orbit where the time
  /// would be. With reduced motion the orbit holds still, so the word is
  /// shown beside it and the state never depends on movement.
  Widget _runningMark(
    AppLocalizations l10n,
    ColorScheme scheme, {
    double maxLabelWidth = 96,
    bool wrap = false,
  }) {
    final signal = signalColor(scheme);
    return Semantics(
      label: l10n.running,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!Motion.ambientAllowed(context)) ...[
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxLabelWidth),
              child: ExcludeSemantics(
                child: Text(
                  l10n.running,
                  key: const Key('conv-running-label'),
                  maxLines: wrap ? null : 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: signal,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          PulsingDot.orbit(color: signal, size: 11),
        ],
      ),
    );
  }

  /// One activity-view row: the conversation's name, its project at the line's
  /// end and a status mark, over a two-line summary of where it got to.
  ///
  /// The summary needs a `thread/read` per row, which is far too much to fetch
  /// for a whole sidebar up front — so it loads when the row is first built
  /// (i.e. when it scrolls into range) and Riverpod keeps it cached for the rest
  /// of the session. Until it arrives the row shows the first user message,
  /// which is already in hand: the layout never jumps, and a row is readable
  /// immediately rather than blank behind a spinner.
  Widget _activityTile({
    required ThreadMeta thread,
    required bool running,
    required bool selected,
    required AppLocalizations l10n,
    required VoidCallback onTap,
    required double titleInset,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fg = scheme.onSurface;
    final muted = onSurfaceMuted(scheme);
    final cleaned = previewWithoutFileRefs(
      thread.preview,
      l10n.fileOnlyMessage,
    ).trim();
    final title =
        thread.title ?? (cleaned.isEmpty ? l10n.untitledThread : cleaned);
    final summary =
        ref
            .watch(
              threadSummaryProvider(
                threadSummaryKey(widget.serviceKey, thread.id),
              ),
            )
            .valueOrNull ??
        // Fall back to the preview — unless the title already IS the preview,
        // in which case repeating it twice tells the user nothing.
        (thread.title == null ? '' : cleaned);
    // What waits in it, then, since the home pane spans projects, where it
    // lives; a project-scoped pane has only one, and a fork under its source
    // shares that row's, so repeating it is noise.
    final leaf = _leafOf(thread.cwd);
    final origin = _originOf(thread);
    final besideSource =
        origin != null &&
        _threads.any((t) => t.id == origin && _leafOf(t.cwd) == leaf);
    final project = [
      ..._rowFacts(thread, l10n),
      if (widget.home && leaf.isNotEmpty && !besideSource) leaf,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: _rowPlate(
        key: Key('activity-tile-${thread.id}'),
        selected: selected,
        radius: kControlRadius + 2,
        child: InkWell(
          mouseCursor: clickable,
          borderRadius: BorderRadius.circular(kControlRadius + 2),
          onTap: onTap,
          child: _activitySheen(
            running: running,
            child: Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                titleInset,
                7,
                _rowInset,
                8,
              ),
              child: LayoutBuilder(
                builder: (context, box) {
                  // Preserve the title when large text or a narrow column would
                  // let its marks consume the line: they move under it.
                  final stacked =
                      box.maxWidth < 220 ||
                      MediaQuery.textScalerOf(context).scale(13) > 18;
                  final name = _withForkBadge(
                    thread,
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.35,
                        // Bold only for the open conversation.
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: fg,
                      ),
                    ),
                    l10n,
                  );
                  final where = Text(
                    project,
                    key: Key('activity-project-${thread.id}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: muted),
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (stacked) ...[
                        name,
                        if (project.isNotEmpty || running)
                          Row(
                            children: [
                              if (project.isNotEmpty) Flexible(child: where),
                              if (running) ...[
                                const SizedBox(width: 6),
                                Flexible(child: _runningMark(l10n, scheme)),
                              ],
                            ],
                          ),
                      ] else
                        Row(
                          children: [
                            Expanded(child: name),
                            if (project.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 120,
                                ),
                                child: where,
                              ),
                            ],
                            if (running) ...[
                              const SizedBox(width: 6),
                              _runningMark(l10n, scheme),
                            ],
                          ],
                        ),
                      if (summary.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          summary,
                          key: Key('activity-summary-${thread.id}'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: muted,
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _activitySheen({required bool running, required Widget child}) =>
      running
      ? RunningSheen(
          color: signalColor(Theme.of(context).colorScheme),
          child: child,
        )
      : child;
}
