part of '../app_session_screen.dart';

extension _SessionConversations on _AppSessionState {
  /// A row's inset from its plate edge to its content.
  static const double _rowInset = 10;

  /// Where a conversation row's title starts. Rows under a project heading
  /// line up with its name, so the folder reads as their parent; the fold
  /// control of a parent row sits in that gutter.
  double _conversationInset({required bool showProject}) =>
      widget.home && !showProject ? 28 : _rowInset;

  Widget _sessionsPane(AppLocalizations l10n, {bool inDrawer = false}) {
    final scheme = Theme.of(context).colorScheme;
    // Live set of running threads for this service, so other sessions show a
    // pulsing badge here too (not just the open one's status bar).
    final running = <String>{
      ...?ref.watch(runningThreadsProvider(widget.serviceKey)).valueOrNull,
      if (_externalWriterRunning && _threadId != null) _threadId!,
    };
    // Close the phone's sidebar if this pane is inside an open one.
    void closeDrawerIfOpen(BuildContext ctx) {
      final nav = LayeredNavigation.maybeOf(ctx);
      if (nav?.isOpen ?? false) nav!.close();
    }

    // Filter by the search query, then bucket by recency: running threads go to
    // "Active", today's to "Today", and the rest to "Earlier".
    final q = _convQuery.trim().toLowerCase();
    final known = {for (final thread in _threads) thread.id: thread};
    for (final thread in _discoveredThreads.values) {
      if (widget.home ||
          _cwd == null ||
          _cwd!.isEmpty ||
          _projects.of(thread.cwd) == _projects.of(_cwd!)) {
        known.putIfAbsent(thread.id, () => thread);
      }
    }
    final conversations = known.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final matches = q.isEmpty
        ? conversations
        : conversations
              .where(
                (t) =>
                    // A renamed conversation must be findable by the name the
                    // user gave it — that's the text the row actually shows,
                    // and searching the preview alone would miss it entirely.
                    (t.title?.toLowerCase().contains(q) ?? false) ||
                    t.preview.toLowerCase().contains(q) ||
                    // The home pane spans projects, so let the filter reach
                    // the project path too (mirrors the project tree's search).
                    (widget.home && t.cwd.toLowerCase().contains(q)),
              )
              .toList(growable: false);
    final allTree = SessionTree(
      conversations,
      (ThreadMeta t) => t.id,
      (t) => t.parentThreadId,
    );
    final matchingIds = allTree.withAncestors(matches.map((t) => t.id));
    final tree = SessionTree(
      conversations.where((t) => matchingIds.contains(t.id)),
      (ThreadMeta t) => t.id,
      (t) => t.parentThreadId,
    );
    final filtered = tree.roots;
    final activeParents = tree.withAncestors(running);
    final reveal = tree.withAncestors([?_threadId])..remove(_threadId);
    // Running state controls the group, not whether children are expanded.
    final expandedParents = {
      ..._expandedSessionParents,
      ...reveal,
      if (q.isNotEmpty) ...matchingIds,
    }..removeAll(_collapsedSessionParents);
    final now = DateTime.now();
    final active = <ThreadMeta>[];
    final today = <ThreadMeta>[];
    final earlier = <ThreadMeta>[];
    for (final t in filtered) {
      if (activeParents.contains(t.id)) {
        active.add(t);
      } else if (_isSameDay(t.updatedAt, now)) {
        today.add(t);
      } else {
        earlier.add(t);
      }
    }

    return Builder(
      builder: (ctx) {
        Widget tile(
          ThreadMeta t, {
          required bool showProject,
          required double inset,
        }) => _conversationTile(
          thread: t,
          titleInset: inset,
          running: running.contains(t.id),
          selected: t.id == _threadId,
          now: now,
          l10n: l10n,
          // Only rows NOT already sitting under a project heading carry
          // their own project name — under one it's just noise.
          project: showProject ? _leafOf(t.cwd) : null,
          onTap: () {
            closeDrawerIfOpen(ctx);
            if (t.id != _threadId) _openThread(t.id, t.cwd);
          },
        );
        // The activity view's taller row: name in bold over a one-line summary
        // of where the conversation got to.
        Widget activityTile(ThreadMeta t, double inset) => _activityTile(
          thread: t,
          titleInset: inset,
          running: running.contains(t.id),
          selected: t.id == _threadId,
          now: now,
          l10n: l10n,
          onTap: () {
            closeDrawerIfOpen(ctx);
            if (t.id != _threadId) _openThread(t.id, t.cwd);
          },
        );
        Widget hierarchyRow(
          ({ThreadMeta item, int depth}) row, {
          bool showProject = false,
        }) {
          final t = row.item;
          return SessionTreeRow(
            id: t.id,
            depth: row.depth,
            leadingInset: _activityView
                ? _rowInset
                : _conversationInset(showProject: showProject),
            childCount: tree.children[t.id]?.length ?? 0,
            childSession: t.parentThreadId != null,
            guardian: t.isGuardian,
            expanded: expandedParents.contains(t.id),
            onToggle: () => _updateState(() {
              if (expandedParents.contains(t.id)) {
                _expandedSessionParents.remove(t.id);
                _collapsedSessionParents.add(t.id);
              } else {
                _collapsedSessionParents.remove(t.id);
                _expandedSessionParents.add(t.id);
              }
            }),
            builder: (inset) => _activityView
                ? activityTile(t, inset)
                : tile(t, showProject: showProject, inset: inset),
          );
        }

        // Row BUILDERS, not built rows. The activity view's tiles each read a
        // thread summary (a full `thread/read` server-side) while building, so a
        // pre-built list would fire one per conversation the moment the view is
        // toggled — 500 transcripts across a relay tunnel to fill one viewport.
        // Deferring construction lets `ListView.builder` create only the rows it
        // actually shows, which is what makes the lazy fetch lazy.
        final rows = <Widget Function()>[];
        // The thread rows in display order, for Ctrl+Tab. A plain field, not
        // state: it only has to be current by the time a key is pressed.
        final order = <ThreadMeta>[];
        // Index in [rows] of the open conversation, for the locate button.
        int? selectedRow;
        void appendThreads(
          Iterable<ThreadMeta> items, {
          bool showProject = false,
        }) {
          for (final row in items.expand(
            (t) => tree.visible(t, expandedParents),
          )) {
            if (row.item.id == _threadId) selectedRow = rows.length;
            order.add(row.item);
            rows.add(() => hierarchyRow(row, showProject: showProject));
          }
        }

        void group(
          String label,
          List<ThreadMeta> items, {
          bool showProject = false,
        }) {
          if (items.isEmpty) return;
          rows.add(() => _sectionLabel(label));
          appendThreads(items, showProject: showProject);
        }

        // Running threads always lead, whatever project they belong to — they
        // are the only rows the user may need to reach urgently.
        group(l10n.groupActive, active, showProject: widget.home);
        if (_activityView) {
          // "When was I working on this", grouped by the day it last moved.
          // Each row carries a one-line summary of the newest agent reply, so
          // the list answers "what happened" without opening anything.
          for (final d in _byDay(<ThreadMeta>[...today, ...earlier], now)) {
            group(d.label, d.threads);
          }
        } else if (widget.home) {
          // The home pane spans every project, so the rest reads as a tree:
          // project → its conversations, newest project first. Switching the
          // open draft must not move these headings. Each shows its newest few
          // rows unless expanded, so many projects stay scannable at a glance.
          // A live search is the one case that shows everything: the user is
          // looking for a specific row, so hiding matches behind "show more"
          // would be actively unhelpful.
          final searching = q.isNotEmpty;
          for (final p in _byProject(filtered)) {
            final idle = p.threads
                .where((t) => !activeParents.contains(t.id))
                .toList();
            rows.add(
              () => _projectSectionLabel(
                p.cwd,
                count: p.threads.length,
                onNew: () => _newConversationInProject(p.cwd, ctx),
              ),
            );
            // A search overrides a collapsed project: these rows already
            // matched the query, so hiding them would answer "no results" to a
            // search that DID find something.
            if (!searching && _collapsedProjects.contains(p.cwd)) continue;
            final expanded = searching || _expandedProjects.contains(p.cwd);
            var shown = expanded
                ? idle
                : idle
                      .take(_AppSessionState._projectPeek)
                      .toList(growable: false);
            // Never truncate away the conversation that's actually open: the
            // sidebar would show no selection at all, and the user loses where
            // they are. It's the newest rows that are worth previewing, so keep
            // them and append the open one rather than reordering.
            if (!expanded &&
                !shown.any((t) => t.id == _threadId || reveal.contains(t.id))) {
              final open = idle.where(
                (t) => t.id == _threadId || reveal.contains(t.id),
              );
              if (open.isNotEmpty) shown = [...shown, open.first];
            }
            appendThreads(shown);
            final hidden = idle.length - shown.length;
            if (!searching && (hidden > 0 || expanded)) {
              rows.add(
                () => _projectPeekToggle(
                  cwd: p.cwd,
                  hidden: hidden,
                  expanded: expanded,
                  l10n: l10n,
                ),
              );
            }
          }
        } else {
          // A project-scoped pane already has one project, so recency is the
          // only axis left worth splitting on.
          group(l10n.groupToday, today);
          group(l10n.groupEarlier, earlier);
        }
        _visibleConversationOrder = order;

        final pane = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // In the phone sidebar, "back to projects" lives here (the AppBar's
            // leading button opens the sidebar instead). Desktop shows it as the
            // AppBar leading, so the inline pane omits it. The home has no back
            // destination at all.
            if (inDrawer && !widget.home) ...[
              ListTile(
                key: const Key('drawer-back-to-sessions'),
                dense: true,
                leading: const Icon(AppIcons.arrow_back),
                title: Text(l10n.backToSessions),
                onTap: () {
                  closeDrawerIfOpen(ctx);
                  _backToSessions();
                },
              ),
              const Divider(height: 1),
            ],
            // Home only: which host this chat runs on, switchable when several
            // app services are available.
            if (widget.home) _serviceSwitcher(l10n),
            // The primary action of a conversation list, as a row rather than
            // a coloured disc: it reads as the first entry of the list it
            // creates into. On touch it is a full-width tonal pill.
            Padding(
              padding: isDesktop
                  ? const EdgeInsets.fromLTRB(8, 4, 8, 0)
                  : const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: _sidebarAction(
                key: const Key('new-conversation-btn'),
                icon: AppIcons.edit_square,
                label: l10n.newConversation,
                onTap: () => _newConversationInProject(_cwd, ctx),
              ),
            ),
            _conversationSearch(l10n, scheme),
            _conversationHeading(l10n, scheme, selectedRow),
            // A project-scoped pane names its one project; the home pane lists
            // every project as headings instead.
            if (!widget.home)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Row(
                  children: [
                    Icon(
                      AppIcons.folder_outlined,
                      size: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        _projectName(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            // Until the host first lists its conversations the pane is
            // loading, not empty: a skeleton, cross-fading into the list. The
            // open conversation's own metadata (or a running one discovered
            // meanwhile) is no listing; a conversation sent from here is.
            Expanded(
              child: _conversationList(
                l10n,
                scheme,
                rows,
                searching: q.isNotEmpty,
                empty: filtered.isEmpty,
              ),
            ),
            // Account quota, always visible rather than buried behind the
            // gauge: it is warm from connect (see _loadQuota), so this row
            // costs nothing and answers "how much have I got left" at a glance.
            ?_quotaStrip(l10n),
            // Home only: everything that used to require navigating away from
            // the chat — management, the host's session browser (incl. force
            // takeover), logs, settings — one tap from the sidebar.
            if (widget.home) _paneShortcuts(l10n, ctx),
          ],
        );
        return _shortPane(pane);
      },
    );
  }

  /// [pane], which on a touch screen too short for its fixed rows and a
  /// usable list (a phone in landscape, the keyboard up) keeps a usable
  /// height inside a scroll view, so no row is cut off; taller screens keep
  /// the pinned footer. The scroll view is always there on touch, so the
  /// keyboard opening never rebuilds the search field it is typing into.
  Widget _shortPane(Widget pane) {
    if (isDesktop) return pane;
    return LayoutBuilder(
      builder: (context, box) {
        if (!box.maxHeight.isFinite) return pane;
        return SingleChildScrollView(
          key: const Key('sidebar-short-scroll'),
          primary: false,
          child: SizedBox(
            height: box.maxHeight >= 480 ? box.maxHeight : 600,
            child: pane,
          ),
        );
      },
    );
  }

  /// The quick filter — shown once there are enough conversations to scan,
  /// opening as the listing arrives rather than jolting the list down.
  Widget _conversationSearch(AppLocalizations l10n, ColorScheme scheme) {
    final radius = BorderRadius.circular(
      isDesktop ? kRowRadius + 1 : kTouchRowRadius,
    );
    return Motion.resize(
      context,
      alignment: Alignment.topCenter,
      child: _threads.length <= 6
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: isDesktop
                  ? const EdgeInsets.fromLTRB(8, 4, 8, 0)
                  : const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: SizedBox(
                height: isDesktop ? 32 : 44,
                child: TextField(
                  key: const Key('conv-search'),
                  focusNode: _convSearchFocus,
                  onChanged: (v) => _updateState(() => _convQuery = v),
                  style: TextStyle(fontSize: isDesktop ? 13 : 15),
                  textAlignVertical: TextAlignVertical.center,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(
                      AppIcons.search,
                      size: isDesktop ? 16 : 20,
                      color: scheme.onSurfaceVariant,
                    ),
                    prefixIconConstraints: BoxConstraints(
                      minWidth: isDesktop ? 32 : 44,
                      minHeight: 32,
                    ),
                    hintText: l10n.searchConversations,
                    hintStyle: TextStyle(
                      fontSize: isDesktop ? 13 : 15,
                      color: scheme.onSurfaceVariant,
                    ),
                    filled: true,
                    fillColor: backdropFieldFill(scheme),
                    contentPadding: EdgeInsets.zero,
                    border: FieldBorder(borderRadius: radius),
                    enabledBorder: FieldBorder(borderRadius: radius),
                    focusedBorder: FieldBorder(
                      borderRadius: radius,
                      borderSide: BorderSide(
                        color: scheme.onSurface.withValues(alpha: 0.35),
                      ),
                      glow: scheme.tertiary.withValues(alpha: 0.16),
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  /// The list heading: what the list is grouped by, with the toggle that
  /// regroups it. Group by project, or by when it happened — two ways of
  /// asking "what was I doing", so it's a toggle rather than a replacement.
  /// While the open conversation has a row ([selectedRow]), a second control
  /// scrolls back to it, wherever the user has wandered off to.
  Widget _conversationHeading(
    AppLocalizations l10n,
    ColorScheme scheme,
    int? selectedRow,
  ) {
    // 44 px on touch: these are the only controls on the list heading.
    final target = isDesktop ? 26.0 : 44.0;
    Widget button({
      required Key key,
      required IconData icon,
      required Color color,
      required String tooltip,
      required VoidCallback onPressed,
    }) => SizedBox(
      width: target,
      height: target,
      child: IconButton(
        key: key,
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          minimumSize: Size.square(target),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(kRowRadius),
          ),
        ),
        icon: Icon(icon, size: 15, color: color),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _activityView ? l10n.activityView : l10n.conversationsSection,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: isDesktop ? 12 : 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (selectedRow != null)
            button(
              key: const Key('locate-conversation-btn'),
              icon: AppIcons.my_location_rounded,
              color: signalColor(scheme),
              tooltip: l10n.locateConversation,
              onPressed: () => _revealConversationRow(selectedRow),
            ),
          button(
            key: const Key('activity-view-btn'),
            icon: _activityView
                ? AppIcons.folder_outlined
                : AppIcons.history_toggle_off,
            color: scheme.onSurfaceVariant,
            tooltip: _activityView
                ? l10n.conversationsSection
                : l10n.activityView,
            onPressed: () => _updateState(() => _activityView = !_activityView),
          ),
        ],
      ),
    );
  }

  /// The conversation rows built lazily from [rows], or a note when there
  /// are none ([empty]) — a skeleton until the host first lists them.
  Widget _conversationList(
    AppLocalizations l10n,
    ColorScheme scheme,
    List<Widget Function()> rows, {
    required bool searching,
    required bool empty,
  }) => AnimatedSwitcher(
    duration: Motion.of(context, Motion.slow),
    switchInCurve: Motion.enter,
    switchOutCurve: Curves.easeIn,
    layoutBuilder: (current, previous) =>
        Stack(fit: StackFit.expand, children: [...previous, ?current]),
    child: !_threadsListed && _threads.isEmpty
        ? ConversationListSkeleton(
            key: const ValueKey('conv-loading'),
            touch: !isDesktop,
          )
        : KeyedSubtree(
            key: const ValueKey('conv-content'),
            child: empty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        searching ? l10n.noMatchingThreads : l10n.noThreads,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  )
                // SuperListView so the locate button can reach a row that has
                // never been built (a long list lays rows out lazily).
                : SuperListView.builder(
                    listController: _convListCtl,
                    controller: _convScroll,
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                    itemCount: rows.length,
                    itemBuilder: (_, i) => rows[i](),
                  ),
          ),
  );

  /// The home pane's footer row of shortcuts. Each button keeps its own
  /// share of the row instead of its intrinsic width: the sidebar drags down
  /// to 200 px, where a fixed-width row of five (manage / sessions / logs /
  /// theme / settings) would overflow rather than tighten.
  Widget _paneShortcuts(AppLocalizations l10n, BuildContext ctx) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 2, 6, 6),
    child: Row(
      children: [
        Expanded(
          child: _paneShortcut(
            key: 'sidebar-manage-btn',
            icon: AppIcons.dns_outlined,
            tooltip: l10n.manageServices,
            ctx: ctx,
            route: '/manage',
          ),
        ),
        // The host session browser rides the meta tunnel, which is an
        // account-mode feature (mirrors the manage page's Sessions tab gate).
        if (_caps.localSessions &&
            ref.watch(configProvider).valueOrNull?.mode == 'account')
          Expanded(
            child: _paneShortcut(
              key: 'sidebar-history-btn',
              icon: AppIcons.history,
              tooltip: l10n.hostSessions,
              ctx: ctx,
              route: Uri(
                path: '/sessions',
                queryParameters: {'svc': widget.serviceKey},
              ).toString(),
            ),
          ),
        Expanded(
          child: _paneShortcut(
            key: 'sidebar-logs-btn',
            icon: AppIcons.article_outlined,
            tooltip: l10n.logsTitle,
            ctx: ctx,
            route: '/logs',
          ),
        ),
        Expanded(
          child: _paneShortcut(
            key: 'sidebar-settings-btn',
            icon: AppIcons.settings_outlined,
            tooltip: l10n.settingsTitle,
            ctx: ctx,
            route: '/settings',
          ),
        ),
      ],
    ),
  );

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
    final cleaned = previewWithoutFileRefs(
      thread.preview,
      l10n.fileOnlyMessage,
    ).trim();
    // A user-set name wins over the preview, matching the top bar.
    final title =
        thread.title ?? (cleaned.isEmpty ? l10n.untitledThread : cleaned);
    // Cross-project pane rows show "project · time" so the user always knows
    // where a conversation lives.
    // Facts about the row, ahead of the time: what is waiting in it, and where
    // it lives when no project heading above says so.
    final facts = [
      if (thread.isVoice) l10n.voiceLive,
      if (_drafts.hasDraft(thread.id)) l10n.draft,
      if (_drafts.queuedCount(thread.id) > 0)
        l10n.queuedCount(_drafts.queuedCount(thread.id)),
      if (project != null && project.isNotEmpty) project,
    ];
    final signal = signalColor(scheme);
    // Desktop rows are one line — title, then the time at the trailing edge —
    // the way a source list sits: twice as many conversations per screen, and
    // the eye scans titles without a second line breaking the column. Touch
    // keeps two lines, where the row height is a target and not a cost.
    final dense = isDesktop;
    final titleText = Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: dense ? 13 : 15,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        color: fg,
      ),
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
        dense ? 6 : 10,
        _rowInset,
        dense ? 6 : 10,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Preserve the title when large text or a narrow sidebar would let
          // metadata consume its entire line.
          final stacked =
              !dense ||
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
        borderRadius: BorderRadius.circular(touch ? kTouchRowRadius : radius),
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

  /// One activity-view row: the conversation's name in bold over a one-line
  /// summary of where it got to, plus its project and time.
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
    required DateTime now,
    required AppLocalizations l10n,
    required VoidCallback onTap,
    required double titleInset,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fg = scheme.onSurface;
    final muted = scheme.onSurfaceVariant;
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
    final when = running
        ? l10n.running
        : _relativeTime(thread.updatedAt, now, l10n);
    // The home pane spans projects, so its rows say where they live; a
    // project-scoped pane has only one, and repeating it per row is noise.
    final meta = [
      if (widget.home) _leafOf(thread.cwd),
      if (when.isNotEmpty) when,
    ].where((s) => s.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: _rowPlate(
        key: Key('activity-tile-${thread.id}'),
        selected: selected,
        radius: kControlRadius,
        child: InkWell(
          mouseCursor: clickable,
          borderRadius: BorderRadius.circular(kControlRadius),
          onTap: onTap,
          child: _activitySheen(
            running: running,
            child: Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                titleInset,
                8,
                _rowInset,
                8,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.35,
                            // A step above the project tree's rows (the title
                            // has a summary under it to stand apart from), and
                            // bold only for the open conversation.
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: fg,
                          ),
                        ),
                        if (summary.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            summary,
                            key: Key('activity-summary-${thread.id}'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: muted,
                            ),
                          ),
                        ],
                        if (meta.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              height: 1.35,
                              color: running
                                  ? signalColor(scheme)
                                  : onSurfaceMuted(scheme),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (running) ...[
                    const SizedBox(width: 8),
                    // The meta line already says "running" in words.
                    PulsingDot.orbit(color: signalColor(scheme), size: 11),
                  ],
                ],
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
