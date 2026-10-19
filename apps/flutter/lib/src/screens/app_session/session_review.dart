part of '../app_session_screen.dart';

extension _SessionReview on _AppSessionState {
  /// Refresh the diff-vs-main for the branch/changes badge. Keyed on the
  /// project cwd (what `gitDiffToRemote` needs); a no-op without one.
  Future<void> _loadGit() async {
    final cwd = _cwd?.trim();
    if (cwd == null || cwd.isEmpty || !_caps.gitDiff) return;
    // Reads overlap (turn events, the badge, a refresh): only the latest one,
    // for the folder still shown, may replace the diff.
    final read = ++_gitRead;
    final service = widget.serviceKey;
    try {
      final raw = await ref.read(bridgeApiProvider).appGitDiff(service, cwd);
      if (!mounted ||
          read != _gitRead ||
          widget.serviceKey != service ||
          _cwd?.trim() != cwd) {
        return;
      }
      _updateState(() => _diff = DiffModel.parse(raw));
    } catch (_) {
      // Not a git repo / no remote: leave the badge as branch-only.
    }
  }

  /// Abandon the in-flight diff fetch. The bridge call itself keeps running to
  /// completion — it can't be aborted — but bumping the token means its result
  /// is dropped and the review never opens.
  void _cancelDiff() {
    if (!_diffLoading) return;
    _diffFetch++;
    _updateState(() => _diffLoading = false);
  }

  /// Re-read the diff for an already-open review, showing (and allowing the
  /// cancellation of) the fetch. Unlike [_showDiff] this never opens anything.
  Future<void> _refreshDiff() async {
    if (_diffLoading) return;
    final token = ++_diffFetch;
    _updateState(() => _diffLoading = true);
    await _loadGit();
    if (!mounted || token != _diffFetch) return;
    _updateState(() => _diffLoading = false);
  }

  /// Whether the host can diff this conversation's project folder.
  bool get _workspaceReview =>
      _caps.gitDiff && (_cwd?.trim().isNotEmpty ?? false);

  /// Open the review on the project's working tree (or, where the host cannot
  /// diff it, on this conversation's edits).
  ///
  /// Opens on whatever diff is already in hand and refreshes behind the review,
  /// rather than making every press wait on a `gitDiffToRemote` round-trip. The
  /// badge only shows change counts once a diff has been read, so by the time
  /// this is reachable there is nearly always something to show — and it stays
  /// current anyway, since turn/diff/updated and turn/completed both refresh it.
  ///
  /// Only a cold open (no diff read yet) blocks, and that one shows the spinner
  /// and can be cancelled by pressing again.
  Future<void> _showDiff() async {
    if (_diffLoading) {
      _cancelDiff();
      return;
    }
    if (!_workspaceReview) {
      _openReview(target: const ReviewTarget(source: ReviewSource.session));
      return;
    }
    if (_diff != null) {
      _openReview(target: const ReviewTarget(source: ReviewSource.workspace));
      _refreshDiff();
      return;
    }
    final token = ++_diffFetch;
    _updateState(() => _diffLoading = true);
    await _loadGit();
    // Superseded or cancelled while the fetch was in flight: the newer caller
    // (or the cancel) owns the UI now, so this one must not touch it.
    if (!mounted || token != _diffFetch) return;
    _updateState(() => _diffLoading = false);
    _openReview(target: const ReviewTarget(source: ReviewSource.workspace));
  }

  /// Open the review on one edit of the conversation (a `fileChange` step).
  void _openChangeInReview(String itemId) =>
      _openReview(target: ReviewTarget(edit: itemId));

  /// Read a reviewed file's current lines, for the whole-file view and to
  /// expand an elided gap (unchanged lines, so the working tree holds them
  /// verbatim); [relPath] is relative to the conversation's cwd.
  ///
  /// Through the session's own file route, which serves what lies in its
  /// working directory, so a project outside the host's shared roots still
  /// reads; a host too old for it gets the root-confined read. Null when
  /// neither serves the whole file: the gap stays collapsed and the view says
  /// it cannot be read.
  Future<List<String>?> _loadReviewFile(String relPath) async {
    final cwd = _cwd?.trim();
    if (cwd == null || cwd.isEmpty) return null;
    // Join with the host's own separator; leave an already-absolute path alone.
    final abs =
        (relPath.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(relPath))
        ? relPath
        : cwd.contains('\\')
        ? '$cwd\\${relPath.replaceAll('/', '\\')}'
        : '$cwd/$relPath';
    final api = ref.read(bridgeApiProvider);
    Uint8List? bytes;
    try {
      final preview = await api.metaFilePreview(
        widget.serviceKey,
        _threadId,
        abs,
      );
      // Part of a file would misplace every line after the cut.
      if (preview.truncated) return null;
      bytes = preview.bytes;
    } catch (_) {
      try {
        bytes = await api.metaReadFile(widget.serviceKey, abs);
      } catch (_) {
        return null;
      }
    }
    return utf8.decode(bytes, allowMalformed: true).split(RegExp(r'\r?\n'));
  }

  /// Show the review: a sidebar beside the conversation on a wide window, a
  /// panel over it on a narrower one, a page of its own on a phone. Opening
  /// it again with a new [target] moves it there.
  ///
  /// Deliberately does NOT fetch: every caller either just awaited a fetch or is
  /// opening on data it already has. Refreshing here as well meant one press
  /// paid for two round-trips of the same `gitDiffToRemote`, the second of which
  /// nobody was waiting on but which still had to finish.
  void _openReview({ReviewTarget? target}) {
    _updateState(() {
      _reviewOpen = true;
      _reviewTarget = target == null
          ? _reviewTarget ?? const ReviewTarget()
          : ReviewTarget.of(target);
    });
  }

  void _closeReview() => _updateState(() => _reviewOpen = false);

  /// The review, live: what the conversation and the working tree changed.
  Widget _reviewPanel({bool page = false}) => ReviewPanel(
    key: const Key('review-panel'),
    session: SessionChanges.of(_items),
    workspace: _diff,
    workspaceAvailable: _workspaceReview,
    workspaceLoading: _diffLoading,
    onRefreshWorkspace: _refreshDiff,
    onCancelRefresh: _cancelDiff,
    branch: _branch,
    root: _cwd,
    target: _reviewTarget,
    onLoadFile: _loadReviewFile,
    onClose: _closeReview,
    page: page,
  );

  /// The app-bar environment button + its popover: a floating summary card
  /// (changes, host, branch) and the changed-file list. Picking a file — or
  /// "review all" — opens the desktop review split.
  Widget _envButton(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final d = _diff;
    // Each file once, counting all of its records (staged and unstaged).
    final files = [
      for (final MapEntry(key: path, value: records) in workspaceFiles(
        d,
      ).entries)
        (
          path: path,
          added: records.fold(0, (n, f) => n + f.added),
          removed: records.fold(0, (n, f) => n + f.removed),
        ),
    ];
    Widget line(IconData icon, String label, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Row(
        children: [
          Icon(icon, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          ?trailing,
        ],
      ),
    );
    return MenuAnchor(
      controller: _envMenu,
      alignmentOffset: const Offset(0, 6),
      style: const MenuStyle(alignment: Alignment.bottomRight),
      menuChildren: [
        SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                child: Text(
                  l10n.envTitle,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.7,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              line(
                AppIcons.difference_outlined,
                l10n.changesTitle,
                trailing: (d != null && !d.isEmpty)
                    ? ChangeCounts(
                        added: d.added,
                        removed: d.removed,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        gap: 6,
                      )
                    : Text(
                        l10n.noChanges,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
              ),
              line(AppIcons.computer, _hostLabel(l10n)),
              if (_branch != null)
                line(AppIcons.account_tree_outlined, _branch!),
              if (files.isNotEmpty) ...[
                const Divider(height: 9),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          l10n.envSource,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.7,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      TextButton(
                        key: const Key('env-review-all'),
                        onPressed: () {
                          _envMenu.close();
                          _openReview(
                            target: const ReviewTarget(
                              source: ReviewSource.workspace,
                            ),
                          );
                        },
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(l10n.reviewTitle),
                      ),
                    ],
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: SingleChildScrollView(
                    primary: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final f in files)
                          InkWell(
                            mouseCursor: clickable,
                            key: Key('env-file-${f.path}'),
                            onTap: () {
                              _envMenu.close();
                              _openReview(
                                target: ReviewTarget(
                                  source: ReviewSource.workspace,
                                  path: f.path,
                                ),
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 6,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    AppIcons.description_outlined,
                                    size: 14,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      f.path,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.left,
                                      style: const TextStyle(
                                        fontFamily: monoFontFamily,
                                        fontFamilyFallback: monoCjkFallback,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  ChangeCounts(
                                    added: f.added,
                                    removed: f.removed,
                                    fontSize: 10.5,
                                    gap: 3,
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 6),
            ],
          ),
        ),
      ],
      builder: (ctx, ctrl, _) => _chromeButton(
        key: const Key('env-panel-btn'),
        tooltip: l10n.envTitle,
        icon: _reviewOpen ? AppIcons.difference : AppIcons.difference_outlined,
        onPressed: () {
          if (ctrl.isOpen) {
            ctrl.close();
          } else {
            _loadGit();
            ctrl.open();
          }
        },
      ),
    );
  }

  /// The "plan ready — implement?" choice bar shown under a finished plan-mode
  /// turn. Keep planning (dismiss) or implement (start a normal turn).
  Widget _implementBar(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(kPanelRadius),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(
        children: [
          Icon(
            AppIcons.checklist_rtl,
            size: 18,
            color: scheme.onTertiaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.planReadyTitle,
              style: TextStyle(
                color: scheme.onTertiaryContainer,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: () => _updateState(() => _implementDismissed = true),
            child: Text(l10n.keepPlanning),
          ),
          const SizedBox(width: 4),
          FilledButton(
            key: const Key('implement-btn'),
            onPressed: _implement,
            child: Text(l10n.implementPlan),
          ),
        ],
      ),
    );
  }

  /// What to check after the ACP agent itself refused or could not run a
  /// request: its host's model service and environment (credentials come
  /// from there — never from a sign-in here). Null for other failures.
  String? _agentErrorHint(AppLocalizations l10n, String error) {
    final caps = _caps;
    if (!caps.hostAccess) return null;
    if (caps.authRequired) {
      return caps.profileId == 'grok' ? l10n.grokAuthHint : l10n.agentAuthHint;
    }
    final m = error.toLowerCase();
    return m.startsWith('the agent rejected the request') ||
            m.startsWith('the agent is not running')
        ? l10n.agentErrorHint
        : null;
  }

  Widget _errorBanner(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final agentHint = _agentErrorHint(l10n, _error!);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(kPanelRadius),
      ),
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    KeyedSubtree(
                      key: const Key('session-error'),
                      child: linkifyText(
                        context,
                        _error!,
                        style: TextStyle(color: scheme.onErrorContainer),
                      ),
                    ),
                    if (agentHint != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          agentHint,
                          key: const Key('session-error-agent-hint'),
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onErrorContainer.withValues(
                              alpha: 0.85,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                key: const Key('session-error-dismiss'),
                icon: const Icon(AppIcons.close, size: 18),
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => _updateState(() {
                  _error = null;
                  // Dismissing a held notice ends it.
                  _heldNotice = null;
                }),
              ),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              if (agentHint != null && _canOpenAgentHost(watch: true))
                TextButton(
                  key: const Key('session-error-host-settings'),
                  onPressed: _openAgentHostSettings,
                  child: Text(l10n.agentHostSettings),
                ),
              if (_connectionLost)
                TextButton(
                  onPressed: _autoReconnect,
                  child: Text(l10n.reconnect),
                )
              else if (_retry != null)
                TextButton(onPressed: _retry, child: Text(l10n.retry)),
            ],
          ),
        ],
      ),
    );
  }
}
