part of '../app_session_screen.dart';

extension _SessionConversations on _AppSessionState {
  /// Where a conversation row's title starts. Rows under a project heading
  /// line up with its name, so the folder reads as their parent; the fold
  /// control of a parent row sits in that gutter.
  double _conversationInset({required bool showProject}) =>
      widget.home && !showProject ? 28 : _SessionConversationRows._rowInset;

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
    // A spawned agent sits under its parent, and a fork under its source.
    String? parentOf(ThreadMeta t) => t.parentThreadId ?? _originOf(t);
    final allTree = SessionTree(
      conversations,
      (ThreadMeta t) => t.id,
      parentOf,
    );
    final matchingIds = allTree.withAncestors(matches.map((t) => t.id));
    final tree = SessionTree(
      conversations.where((t) => matchingIds.contains(t.id)),
      (ThreadMeta t) => t.id,
      parentOf,
    );
    // A family moves with its newest member, so a fork in use today does not
    // lie folded under an old source.
    final familyAt = <String, int>{};
    int newestOf(ThreadMeta t) => familyAt[t.id] ??= [
      t.updatedAt,
      for (final child in tree.children[t.id] ?? const <ThreadMeta>[])
        newestOf(child),
    ].reduce(math.max);
    final filtered = [...tree.roots]
      ..sort((a, b) => newestOf(b).compareTo(newestOf(a)));
    final activeParents = tree.withAncestors(running);
    final reveal = tree.withAncestors([?_threadId])..remove(_threadId);
    // Running state controls the group, not whether children are expanded.
    final expandedParents = {
      ..._expandedSessionParents,
      ...reveal,
      if (q.isNotEmpty) ...matchingIds,
      // Forks stand open by default: finding them is the point of nesting them.
      for (final t in conversations)
        if (t.parentThreadId == null) ?_originOf(t),
    }..removeAll(_collapsedSessionParents);
    final now = DateTime.now();
    final active = <ThreadMeta>[];
    final today = <ThreadMeta>[];
    final earlier = <ThreadMeta>[];
    for (final t in filtered) {
      if (activeParents.contains(t.id)) {
        active.add(t);
      } else if (_isSameDay(newestOf(t), now)) {
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
          project: showProject && _leafOf(t.cwd).isNotEmpty
              ? _leafOf(t.cwd)
              : null,
          onTap: () {
            closeDrawerIfOpen(ctx);
            if (t.id != _threadId) _openThread(t.id, t.cwd);
          },
        );
        // The activity view's taller row: name over a summary of where the
        // conversation got to.
        Widget activityTile(ThreadMeta t, double inset) => _activityTile(
          thread: t,
          titleInset: inset,
          running: running.contains(t.id),
          selected: t.id == _threadId,
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
                ? _SessionConversationRows._rowInset
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
        // Index in [rows] of the open conversation, to reveal it.
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

        // The list's first heading carries the control that regroups it.
        void heading(String label) {
          final first = rows.isEmpty;
          rows.add(
            () => first ? _firstHeading(l10n, label) : _sectionLabel(label),
          );
        }

        void group(
          String label,
          List<ThreadMeta> items, {
          bool showProject = false,
        }) {
          if (items.isEmpty) return;
          heading(label);
          appendThreads(items, showProject: showProject);
        }

        // Running threads always lead, whatever project they belong to — they
        // are the only rows the user may need to reach urgently.
        group(l10n.groupActive, active, showProject: widget.home);
        if (_activityView) {
          // "When was I working on this", grouped by the day it last moved.
          // Each row carries a one-line summary of the newest agent reply, so
          // the list answers "what happened" without opening anything.
          final days = _byDay(
            <ThreadMeta>[...today, ...earlier],
            now,
            at: newestOf,
          );
          for (final d in days) {
            group(d.label, d.threads);
          }
        } else if (widget.home) {
          if (rows.isEmpty && filtered.isNotEmpty) {
            heading(l10n.conversationsSection);
          }
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
        _openConversationRow = selectedRow;
        final account = inDrawer ? _accountRow(ctx) : null;

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
            if (inDrawer) ...[
              // A phone's drawer: which host this chat runs on as capsules,
              // then the search and, beside it, the new conversation.
              if (widget.home)
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 10),
                  child: _serviceSwitcher(l10n, capsules: true),
                ),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 8, 0),
                child: Row(
                  children: [
                    Expanded(child: _conversationSearch(l10n, scheme)),
                    const SizedBox(width: 8),
                    _roundNewConversation(l10n, ctx),
                  ],
                ),
              ),
            ] else ...[
              // The workspace's column: the host and a search control, then
              // the new conversation as the first row of the list it creates
              // into.
              SizedBox(
                height: 50,
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(8, 0, 8, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: widget.home
                            ? _serviceSwitcher(l10n)
                            : Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  start: 6,
                                ),
                                child: Text(
                                  _projectName(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                      ),
                      StripButton(
                        key: const Key('conv-search-toggle'),
                        tooltip: withShortcut(l10n.searchConversations, 'K'),
                        icon: AppIcons.search,
                        selected: _convSearchOpen,
                        onPressed: _toggleConversationSearch,
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
                child: _sidebarAction(
                  key: const Key('new-conversation-btn'),
                  icon: AppIcons.edit_square,
                  label: l10n.newConversation,
                  onTap: () => _newConversationInProject(_cwd, ctx),
                ),
              ),
              _conversationSearch(l10n, scheme),
            ],
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
            ?account,
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

  /// Open the column's search field, focused, or close it and clear it.
  void _toggleConversationSearch() {
    final open = !_convSearchOpen;
    _updateState(() {
      _convSearchOpen = open;
      if (!open) _convQuery = '';
    });
    if (!open) {
      _convSearchCtrl.clear();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _convSearchFocus.requestFocus();
    });
  }

  /// The quick filter. A phone's drawer shows it once there are enough
  /// conversations to scan, opening as the listing arrives rather than jolting
  /// the list down; the workspace's column opens it under its search control.
  Widget _conversationSearch(AppLocalizations l10n, ColorScheme scheme) {
    final touch = !isDesktop;
    final inColumn = MediaQuery.sizeOf(context).width >= workspaceCompactWidth;
    final shown = inColumn
        ? _convSearchOpen
        : _threads.length > 6 || _convQuery.isNotEmpty;
    final radius = BorderRadius.circular(touch ? kRowRadius : kRowRadius + 1);
    return Motion.resize(
      context,
      alignment: Alignment.topCenter,
      child: !shown
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: inColumn
                  ? const EdgeInsets.fromLTRB(8, 2, 8, 2)
                  : EdgeInsets.zero,
              child: SizedBox(
                height: touch ? 44 : 32,
                child: TextField(
                  key: const Key('conv-search'),
                  controller: _convSearchCtrl,
                  focusNode: _convSearchFocus,
                  onChanged: (v) => _updateState(() => _convQuery = v),
                  style: TextStyle(fontSize: touch ? 15 : 13),
                  // The well fills its box: a finger's target under a finger.
                  expands: true,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.center,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(
                      AppIcons.search,
                      size: touch ? 20 : 16,
                      color: scheme.onSurfaceVariant,
                    ),
                    prefixIconConstraints: BoxConstraints(
                      minWidth: touch ? 44 : 32,
                      minHeight: 32,
                    ),
                    hintText: l10n.searchConversations,
                    hintStyle: TextStyle(
                      fontSize: touch ? 15 : 13,
                      color: scheme.onSurfaceVariant,
                    ),
                    filled: true,
                    fillColor: touch && !inColumn
                        ? scheme.surfaceContainer
                        : backdropFieldFill(scheme),
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

  /// The drawer's compact new conversation, which keeps its place whether or
  /// not the search beside it shows.
  Widget _roundNewConversation(AppLocalizations l10n, BuildContext ctx) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      key: const Key('new-conversation-btn'),
      tooltip: l10n.newConversation,
      style: IconButton.styleFrom(
        minimumSize: const Size.square(44),
        backgroundColor: scheme.surfaceContainerHighest,
        foregroundColor: scheme.onSurface,
      ),
      icon: const Icon(AppIcons.edit_square, size: 20),
      onPressed: () => _newConversationInProject(_cwd, ctx),
    );
  }

  /// The list's first heading: its label, and the control that switches what
  /// the list groups by. An ellipsis in a pointer's column, its current choice
  /// in words in a phone's drawer.
  Widget _firstHeading(AppLocalizations l10n, String label) {
    final scheme = Theme.of(context).colorScheme;
    final inColumn = MediaQuery.sizeOf(context).width >= workspaceCompactWidth;
    final style = TextStyle(
      fontSize: isDesktop ? 12.5 : 13,
      fontWeight: inColumn ? FontWeight.w600 : FontWeight.w500,
      color: scheme.onSurfaceVariant,
    );
    final byTime = _activityView;
    return Padding(
      padding: isDesktop
          ? const EdgeInsetsDirectional.fromSTEB(8, 6, 0, 2)
          : const EdgeInsetsDirectional.fromSTEB(12, 6, 0, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          PopupMenuButton<bool>(
            key: const Key('activity-view-btn'),
            tooltip: l10n.conversationGroupBy,
            position: PopupMenuPosition.under,
            padding: EdgeInsets.zero,
            onSelected: (time) => _updateState(() => _timeGrouping = time),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                key: const Key('group-by-project'),
                value: false,
                checked: !byTime,
                child: Text(l10n.groupByProject),
              ),
              CheckedPopupMenuItem(
                key: const Key('group-by-time'),
                value: true,
                checked: byTime,
                child: Text(l10n.groupByTime),
              ),
            ],
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: isDesktop ? 26 : 44,
                minHeight: isDesktop ? 26 : 44,
              ),
              child: Center(
                child: inColumn
                    ? Icon(
                        AppIcons.more_horiz,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              byTime ? l10n.groupByTime : l10n.groupByProject,
                              style: style,
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              AppIcons.expand_more,
                              size: 14,
                              color: scheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The drawer's foot: the account or relay, which opens the Pocket.
  Widget _accountRow(BuildContext ctx) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Semantics(
        button: true,
        label: l10n.pocketOpen,
        child: InkWell(
          key: const Key('drawer-account-row'),
          mouseCursor: clickable,
          onTap: () => showPocket(ctx, section: '/'),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(14, 4, 12, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: PocketIdentity(size: 30, subtitle: false),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    AppIcons.layout_grid,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
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
                // SuperListView so the open row can be revealed before it has
                // ever been built (a long list lays rows out lazily).
                : SuperListView.builder(
                    listController: _convListCtl,
                    controller: _convScroll,
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                    itemCount: rows.length,
                    itemBuilder: (_, i) => rows[i](),
                  ),
          ),
  );
}
