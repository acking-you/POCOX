part of '../app_session_screen.dart';

extension _SessionReview on _AppSessionState {
  /// Refresh the diff-vs-main for the branch/changes badge. Keyed on the
  /// project cwd (what `gitDiffToRemote` needs); a no-op without one.
  Future<void> _loadGit() async {
    final cwd = _cwd?.trim();
    if (cwd == null || cwd.isEmpty || !_caps.gitDiff) return;
    try {
      final raw = await ref
          .read(bridgeApiProvider)
          .appGitDiff(widget.serviceKey, cwd);
      if (!mounted) return;
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

  /// Open the diff viewer: the inline review split on desktop (≥1100px), a tall
  /// bottom sheet on narrower screens.
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
    final compact = MediaQuery.of(context).size.width < 1100;
    // The sheet takes a snapshot of the diff when it's built, so a refresh
    // behind it couldn't reach the open sheet — only the review split, which
    // rebuilds from state, gets the background update.
    if (_diff != null && !compact) {
      _openReview();
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
    if (compact) {
      await _showDiffSheet();
    } else {
      _openReview();
    }
  }

  /// The narrow-screen diff viewer.
  Future<void> _showDiffSheet() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => FractionallySizedBox(
      heightFactor: 0.9,
      child: EnvPanel(diff: _diff, branch: _branch, cwd: _cwd),
    ),
  );

  /// Read a reviewed file's current lines so the review can expand an elided
  /// gap. The gap lines are unchanged, so the working-tree file holds them
  /// verbatim; [relPath] is relative to the conversation's cwd. Best-effort:
  /// returns null when there's no cwd or the host won't serve the read (no meta
  /// tunnel, or the file sits outside a configured root), and the gap then
  /// simply stays collapsed.
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
    try {
      final bytes = await ref
          .read(bridgeApiProvider)
          .metaReadFile(widget.serviceKey, abs);
      return utf8.decode(bytes, allowMalformed: true).split(RegExp(r'\r?\n'));
    } catch (_) {
      return null;
    }
  }

  /// Open the desktop review split, defaulting the selected file to [path] (or
  /// the first changed file).
  ///
  /// Deliberately does NOT fetch: every caller either just awaited a fetch or is
  /// opening on data it already has. Refreshing here as well meant one press
  /// paid for two round-trips of the same `gitDiffToRemote`, the second of which
  /// nobody was waiting on but which still had to finish.
  void _openReview({String? path}) {
    _updateState(() {
      _reviewOpen = true;
      final files = _diff?.files ?? const [];
      _reviewFile =
          path ??
          (files.any((f) => f.path == _reviewFile)
              ? _reviewFile
              : files.firstOrNull?.path);
    });
  }

  /// The app-bar environment button + its popover: a floating summary card
  /// (changes, host, branch) and the changed-file list. Picking a file — or
  /// "review all" — opens the desktop review split.
  Widget _envButton(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final d = _diff;
    final files = d?.files ?? const <DiffFile>[];
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
                Icons.difference_outlined,
                l10n.changesTitle,
                trailing: (d != null && !d.isEmpty)
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '+${d.added}',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: additionColor(scheme),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '−${d.removed}',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: scheme.error,
                            ),
                          ),
                        ],
                      )
                    : Text(
                        l10n.noChanges,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
              ),
              line(Icons.computer, _hostLabel(l10n)),
              if (_branch != null) line(Icons.account_tree_outlined, _branch!),
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
                          _openReview();
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
                              _openReview(path: f.path);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 6,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.description_outlined,
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
                                  Text(
                                    '+${f.added}',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: additionColor(scheme),
                                    ),
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    '−${f.removed}',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: scheme.error,
                                    ),
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
        icon: _reviewOpen ? Icons.difference : Icons.difference_outlined,
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

  /// The desktop review split: the selected file's diff beside the changed-file
  /// tree, with a draggable divider between them and a close button.
  Widget _reviewSplit(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final files = _diff?.files ?? const <DiffFile>[];
    final selected =
        files.where((f) => f.path == _reviewFile).firstOrNull ??
        files.firstOrNull;
    return Column(
      children: [
        // Review header: title + refresh + close.
        Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: scheme.outlineVariant, width: 1),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(
            children: [
              Icon(Icons.rate_review_outlined, size: 16, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.reviewTitle,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              // Refreshing in place: the same cancellable fetch as the badge, so
              // a slow re-read spins here and can be called off, rather than
              // leaving the tree looking current while it isn't.
              if (_diffLoading)
                IconButton(
                  key: const Key('review-refresh-cancel'),
                  icon: SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: signalColor(scheme),
                    ),
                  ),
                  tooltip: l10n.cancelDiffLoad,
                  visualDensity: VisualDensity.compact,
                  onPressed: _cancelDiff,
                )
              else
                IconButton(
                  icon: const Icon(Icons.refresh, size: 17),
                  tooltip: l10n.envRefresh,
                  visualDensity: VisualDensity.compact,
                  onPressed: _refreshDiff,
                ),
              IconButton(
                key: const Key('review-close'),
                icon: const Icon(Icons.close, size: 18),
                tooltip: l10n.cancel,
                visualDensity: VisualDensity.compact,
                onPressed: () => _updateState(() => _reviewOpen = false),
              ),
            ],
          ),
        ),
        Expanded(
          child: files.isEmpty
              ? Center(
                  child: Text(
                    l10n.reviewNoFiles,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : Row(
                  children: [
                    Expanded(
                      child: selected == null
                          ? Center(
                              child: Text(
                                l10n.reviewPickFile,
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            )
                          : DiffReviewView(
                              key: ValueKey(selected.path),
                              file: selected,
                              branch: _branch,
                              onLoadFile: _loadReviewFile,
                            ),
                    ),
                    _splitter(
                      key: const Key('review-tree-splitter'),
                      onDrag: (dx) => _updateState(
                        () => _treeWidth = (_treeWidth - dx).clamp(180, 420),
                      ),
                    ),
                    SizedBox(
                      width: _treeWidth.clamp(180, 420),
                      child: ChangedFileTree(
                        files: files,
                        selected: selected?.path,
                        onSelect: (p) => _updateState(() => _reviewFile = p),
                      ),
                    ),
                  ],
                ),
        ),
      ],
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
            Icons.checklist_rtl,
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
    if (caps.authRequired) return l10n.agentAuthHint;
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
                icon: const Icon(Icons.close, size: 18),
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
