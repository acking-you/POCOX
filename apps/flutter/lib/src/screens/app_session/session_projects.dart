part of '../app_session_screen.dart';

extension _SessionProjects on _AppSessionState {
  /// Keep the empty view focused on the project and the composer below it.
  Widget _newSessionGuidance(AppLocalizations l10n) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The mark anchors the empty view so the switcher below reads
              // as "where this conversation runs", not a stray dropdown.
              const BrandLogo(size: 36),
              const SizedBox(height: 14),
              _projectSwitcher(
                l10n,
                label: _newProjectLabel(l10n, l10n.workOutsideProject),
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w500),
              ),
              if ((_cwd?.trim().isNotEmpty ?? false)
                      ? _cwd!.trim()
                      : _automaticProject
                  case final shown?) ...[
                const SizedBox(height: 4),
                Text(
                  shown,
                  key: const Key('new-session-cwd'),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: monoFontFamily,
                    fontFamilyFallback: monoCjkFallback,
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _focusNewComposer(int generation) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _threadLoadGeneration && _threadId == null) {
        _inputFocus.requestFocus();
      }
    });
  }

  void _newConversationInProject(String? cwd, BuildContext paneContext) {
    if (!mounted || !paneContext.mounted) return;
    if (_threadId != null || _cwd != cwd) {
      _openThread(null, cwd);
    } else if (!_sending && _queue.isEmpty && _error != null) {
      // Already this new conversation: a banner left by a send that was
      // refused before anything was created belongs to that attempt. The
      // draft it returned stays in the composer.
      _updateState(() {
        _error = null;
        _retry = null;
      });
    }
    final nav = LayeredNavigation.maybeOf(paneContext);
    if (nav?.isOpen ?? false) {
      _newDraftFocusAfterDrawer = _threadLoadGeneration;
      nav!.close();
    } else {
      _focusNewComposer(_threadLoadGeneration);
    }
  }

  void _selectProject(String? cwd) {
    if (_threadId != null) return;
    _projectSelectionGeneration++;
    _openLoadDone(_kCwdSeed);
    if (_cwd == cwd) return;
    _openThread(null, cwd);
    _focusNewComposer(_threadLoadGeneration);
  }

  Future<void> _browseDraftProject() async {
    final generation = _threadLoadGeneration;
    final picked = await showFolderPicker(
      context,
      serviceKey: widget.serviceKey,
      initialPath: _cwd,
      // Projects of this host's sessions, offered even when the chosen
      // folder has no history of its own.
      recent: _knownProjects(),
    );
    if (mounted && generation == _threadLoadGeneration && picked != null) {
      _selectProject(picked);
    }
  }

  /// A new conversation of an engine that creates its session only in a
  /// project folder (ACP agents, native OpenCode), with none chosen yet:
  /// nothing could be created, so nothing may be sent. Codex works outside
  /// a project.
  bool get _needsProjectToSend =>
      _caps.hostAccess &&
      _threadId == null &&
      (_cwd?.trim().isEmpty ?? true) &&
      _automaticProject == null;

  /// The host's automatic default folder, while the shown new conversation
  /// has no folder of its own: it is where the conversation will be
  /// created. Display only — never [_cwd], so a send passes no folder and
  /// the host creates it then; any folder the user picks wins.
  String? get _automaticProject {
    final known = _hostDefault;
    if (known == null || known.key != widget.serviceKey) return null;
    if (_threadId != null || (_cwd?.trim().isNotEmpty ?? false)) return null;
    return known.path.isEmpty ? null : known.path;
  }

  /// The shown new conversation's project label: its chosen folder, the
  /// host's automatic default, or [fallback].
  String _newProjectLabel(AppLocalizations l10n, String fallback) {
    if (_cwd?.trim().isNotEmpty ?? false) return _projectName();
    final automatic = _automaticProject;
    if (automatic == null) return fallback;
    return l10n.defaultProjectLabel(_AppSessionState._leafOf(automatic));
  }

  /// A send without the project it needs: ask for the folder first. The
  /// draft stays as it is until a folder is chosen (cancelling changes
  /// nothing); then its text and attachments move to that project's new
  /// conversation, which is sent once, as the user asked. When that project
  /// already holds an unsent draft, both stay in the composer unsent.
  Future<void> _chooseProjectThenSend() async {
    final from = _draft;
    final generation = _threadLoadGeneration;
    final picked = await showFolderPicker(
      context,
      serviceKey: widget.serviceKey,
      recent: _knownProjects(),
    );
    final project = picked?.trim();
    if (!mounted ||
        project == null ||
        project.isEmpty ||
        generation != _threadLoadGeneration ||
        !identical(_draft, from) ||
        !_needsProjectToSend ||
        from.sendPending) {
      return;
    }
    final value = from.value;
    final attachments = List<_Attachment>.of(from.attachments);
    final options = Map<String, String>.of(from.options);
    _selectProject(project);
    final into = _draft;
    if (!mounted || _cwd != project || identical(into, from)) return;
    // That project's own unsent draft is kept, never sent on its behalf:
    // the input joins it and the user sends the result.
    final merging = into.hasDraft || into.queue.isNotEmpty;
    // The draft left behind is emptied, so its input lives in one place.
    from
      ..value = TextEditingValue.empty
      ..attachments.clear()
      ..options.clear();
    _drafts.save(from, changed: true);
    // Options chosen for this message go with it, unless the project's
    // draft already holds its own.
    if (into.options.isEmpty) into.options.addAll(options);
    _restoreDraft(value.text, attachments);
    if (!merging) _submit();
  }

  /// The project name rendered as a dropdown trigger, wired to [ProjectMenu].
  Widget _projectSwitcher(
    AppLocalizations l10n, {
    required String label,
    TextStyle? style,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ProjectMenu(
      projects: _knownProjects(),
      current: _cwd?.trim().isEmpty ?? true ? null : _cwd!.trim(),
      onPick: _selectProject,
      onBrowse: _browseDraftProject,
      onClear: () => _selectProject(null),
      builder: (ctx, ctrl) => Tooltip(
        message: _cwd ?? l10n.workOutsideProject,
        triggerMode: TooltipTriggerMode.manual,
        child: InkWell(
          mouseCursor: clickable,
          key: const Key('project-switcher-btn'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => ctrl.isOpen ? ctrl.close() : ctrl.open(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        style ??
                        TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.expand_more,
                  size: style == null ? 16 : 20,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Projects this host is known to have: every distinct working directory
  /// across ALL its conversations, most recently used first, with the open
  /// project pinned to the top. That is the list the user actually works in —
  /// anything else is reachable via "new project".
  List<String> _knownProjects() {
    final seen = <String>{};
    final out = <String>[];
    void add(String? raw) {
      final p = raw?.trim();
      if (p == null || p.isEmpty) return;
      if (seen.add(p)) out.add(p);
    }

    add(_cwd);
    for (final p in _allProjects) {
      add(p);
    }
    for (final p in _drafts.projects) {
      add(p);
    }
    return out;
  }

  /// Sidebar footer: flip the app between light and dark without a trip to
  /// settings — appearance is the one setting people change on a whim (and by
  /// time of day), so it earns a one-tap control next to the other shortcuts.
  ///
  /// Two states, not three. It used to cycle system → light → dark to keep
  /// "follow the OS" reachable, but a control whose next state you can't
  /// predict from its icon is a worse trade than losing one-tap access to a
  /// default that Settings still offers. The icon shows what is in effect now;
  /// tapping shows the other one.
  /// One sidebar-footer shortcut: closes the phone sidebar, then pushes.
  Widget _paneShortcut({
    required String key,
    required IconData icon,
    required String tooltip,
    required BuildContext ctx,
    required String route,
  }) => IconButton(
    key: Key(key),
    icon: Icon(icon, size: isDesktop ? 18 : 20),
    tooltip: tooltip,
    style: IconButton.styleFrom(
      minimumSize: isDesktop ? const Size(32, 32) : const Size(44, 44),
      foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRowRadius),
      ),
    ),
    onPressed: () {
      final nav = LayeredNavigation.maybeOf(ctx);
      if (nav?.isOpen ?? false) nav!.close();
      context.push(route);
    },
  );

  /// A labelled action row in the sidebar, drawn like a conversation row so
  /// the list reads as one column. Touch layouts grow it to a 44 px target.
  Widget _sidebarAction({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    // Touch: the list's primary action is a full-width tonal pill in the
    // brand blue — the one accent of the sidebar besides live work.
    final touch = !isDesktop;
    final ink = touch ? scheme.onTertiaryContainer : scheme.onSurface;
    final radius = BorderRadius.circular(touch ? 28 : kRowRadius);
    return Material(
      color: touch ? scheme.tertiaryContainer : Colors.transparent,
      borderRadius: radius,
      child: InkWell(
        key: key,
        mouseCursor: clickable,
        borderRadius: radius,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: touch ? 52 : 32),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: touch ? 18 : 8),
            child: Row(
              children: [
                Icon(icon, size: touch ? 20 : 16, color: ink),
                SizedBox(width: touch ? 14 : 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: touch ? 15 : 13,
                      fontWeight: touch ? FontWeight.w600 : FontWeight.w500,
                      color: ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Home-pane header row: the host currently serving this chat, and the way
  /// to change it. While a switch runs it names the host being reached, so
  /// the user always sees WHERE the conversation runs and what is changing.
  Widget _serviceSwitcher(AppLocalizations l10n) => HostSwitcher(
    services: widget.services,
    current: widget.serviceKey,
    pending: widget.hostSwitch,
    identities: _hostIdentities(),
    onPick: (key) => widget.onSwitchService?.call(key),
    onManage: () => context.push('/manage'),
    // Re-discover: a host another device just started appears in this list
    // (home watches discovery); the conversation and its draft stay.
    onRefresh: () async {
      ref.invalidate(appReachableProvider);
      ref.invalidate(servicesProvider);
      await ref.read(servicesProvider.future);
    },
  );

  /// Preserve project recency when opening another project's draft.
  List<({String cwd, List<ThreadMeta> threads})> _byProject(
    List<ThreadMeta> threads,
  ) {
    final buckets = <String, List<ThreadMeta>>{};
    for (final t in threads) {
      buckets.putIfAbsent(t.cwd, () => <ThreadMeta>[]).add(t);
    }
    return [
      for (final entry in buckets.entries)
        (cwd: entry.key, threads: entry.value),
    ];
  }

  /// Drops the cached activity-view summary for [threadId], so the next build
  /// re-reads it. Called when a turn ends: the summary is the newest agent
  /// reply, and that is exactly what just changed.
  void _invalidateSummary(String? threadId) {
    if (threadId == null || threadId.isEmpty) return;
    ref.invalidate(
      threadSummaryProvider(threadSummaryKey(widget.serviceKey, threadId)),
    );
    // A finished turn also moves the thread's `updatedAt`, which the activity
    // view groups BY — so a conversation resumed from an older day would keep
    // sitting under that old day, with a stale relative time and sort position,
    // until something else happened to re-list.
    _scheduleThreadsRefresh();
  }

  /// Re-list threads shortly, coalescing bursts into one request.
  ///
  /// Debounced because several threads can finish within moments of each other
  /// (queued sends, parallel conversations) and each end would otherwise issue
  /// its own `thread/list`. The delay also lets the server commit the turn
  /// before we ask for the timestamps it just changed.
  void _scheduleThreadsRefresh() {
    _threadsRefreshTimer?.cancel();
    _threadsRefreshTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _loadThreads();
    });
  }

  /// Buckets threads by the calendar day they last moved, newest day first —
  /// the activity view's spine.
  ///
  /// Labels lean on the calendar rather than elapsed time: "Today" /
  /// "Yesterday", then the weekday name for the rest of the past week (a date
  /// that recent reads better as "Thursday"), and a plain date beyond that.
  /// Threads with no timestamp land in one trailing "Earlier" bucket instead of
  /// claiming the epoch as their day.
  List<({String label, List<ThreadMeta> threads})> _byDay(
    List<ThreadMeta> threads,
    DateTime now,
  ) {
    final l10n = AppLocalizations.of(context);
    final locale = l10n.localeName;
    final today = DateTime(now.year, now.month, now.day);
    // Insertion order IS the output order: the input arrives newest-first, so
    // each new day appends after the days already seen.
    final buckets = <String, List<ThreadMeta>>{};
    final undated = <ThreadMeta>[];
    for (final t in threads) {
      if (t.updatedAt <= 0) {
        undated.add(t);
        continue;
      }
      final at = DateTime.fromMillisecondsSinceEpoch(t.updatedAt * 1000);
      final day = DateTime(at.year, at.month, at.day);
      final label = switch (today.difference(day).inDays) {
        <= 0 => l10n.groupToday,
        1 => l10n.groupYesterday,
        // Weekday names only stay unambiguous inside one week — past that
        // "Thursday" could be any Thursday, so switch to a date.
        < 7 => DateFormat.EEEE(locale).format(day),
        _ => DateFormat.yMMMd(locale).format(day),
      };
      buckets.putIfAbsent(label, () => <ThreadMeta>[]).add(t);
    }
    return [
      for (final e in buckets.entries) (label: e.key, threads: e.value),
      // Undated rows can't claim a day, and they sort nowhere in particular in
      // the source order — so they go last under one catch-all heading rather
      // than splitting the timeline wherever the first one happened to appear.
      if (undated.isNotEmpty) (label: l10n.groupEarlier, threads: undated),
    ];
  }

  Widget _projectSectionLabel(
    String cwd, {
    required int count,
    required VoidCallback onNew,
  }) {
    final leaf = _AppSessionState._leafOf(cwd);
    return ProjectSectionHeader(
      key: ValueKey('project-section-$cwd'),
      path: cwd,
      name: leaf.isEmpty ? AppLocalizations.of(context).defaultFolder : leaf,
      collapsed: _collapsedProjects.contains(cwd),
      count: count,
      onToggle: () => _updateState(() {
        if (!_collapsedProjects.remove(cwd)) _collapsedProjects.add(cwd);
      }),
      onNewConversation: onNew,
    );
  }

  /// The "show N more" / "show less" row that ends a partially-shown project
  /// group. A quiet text link, not a button: it's navigation within a list,
  /// and the rows above it are what the eye should land on.
  Widget _projectPeekToggle({
    required String cwd,
    required int hidden,
    required bool expanded,
    required AppLocalizations l10n,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      // Its text starts on the title column of the rows above.
      padding: EdgeInsetsDirectional.only(
        start: _conversationInset(showProject: false) - 6,
        bottom: 2,
      ),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(kRowRadius),
          child: InkWell(
            mouseCursor: clickable,
            key: Key('project-peek-$cwd'),
            borderRadius: BorderRadius.circular(kRowRadius),
            onTap: () => _updateState(() {
              if (!_expandedProjects.remove(cwd)) _expandedProjects.add(cwd);
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(
                expanded ? l10n.showLess : l10n.showMoreCount(hidden),
                style: TextStyle(
                  fontSize: 11.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A muted section header for the conversations pane (Active / Today / …).
  Widget _sectionLabel(String text) => Padding(
    padding: isDesktop
        ? const EdgeInsets.fromLTRB(8, 12, 8, 4)
        : const EdgeInsets.fromLTRB(12, 18, 12, 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: isDesktop ? 11.5 : 13,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  /// Whether [unixSeconds] falls on the same calendar day as [now]. A 0/absent
  /// timestamp is treated as not-today (bucketed under "Earlier").
  bool _isSameDay(int unixSeconds, DateTime now) {
    if (unixSeconds <= 0) return false;
    final d = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  /// A short localized "time ago" for a thread's last-updated timestamp;
  /// empty when the timestamp is missing (0).
  String _relativeTime(int unixSeconds, DateTime now, AppLocalizations l10n) {
    if (unixSeconds <= 0) return '';
    final then = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    final diff = now.difference(then);
    if (diff.inMinutes < 1) return l10n.timeJustNow;
    if (diff.inMinutes < 60) return l10n.timeMinutesAgo(diff.inMinutes);
    if (_isSameDay(unixSeconds, now)) return l10n.timeHoursAgo(diff.inHours);
    final yesterday = now.subtract(const Duration(days: 1));
    if (then.year == yesterday.year &&
        then.month == yesterday.month &&
        then.day == yesterday.day) {
      return l10n.timeYesterday;
    }
    return l10n.timeDaysAgo(diff.inDays);
  }
}
