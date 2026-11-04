part of '../app_session_screen.dart';

/// What the context card and panel hold beyond the session's own state.
class _ContextView {
  /// The user's choice to show the card.
  bool cardOpen = true;

  /// Whether the window has room for the card. Set while the layout is decided
  /// and read further down the same build, as is [cardShown].
  bool cardFits = false;

  /// Whether the card stands open this build; the review takes its place.
  bool cardShown = false;

  /// What background commands the open conversation runs; empty until read
  /// and where the host has none or cannot say.
  List<BackgroundTerminal> terminals = const [];

  /// The connection and conversation that supplied [terminals].
  _TerminalTarget? terminalsTarget;

  /// The latest read of [terminals]; older answers apply nothing.
  int terminalsRead = 0;

  /// The host could not list them: the section stays hidden, unasked, until
  /// the connection or the conversation changes.
  bool terminalsUnavailable = false;

  /// Whether the context sheet or panel is open.
  bool panelOpen = false;

  /// Told after each build while [panelOpen]: the panel is another route,
  /// which a build here cannot reach.
  final changes = ValueNotifier<int>(0);

  void dispose() => changes.dispose();
}

/// One thing that can be done with the open conversation.
@immutable
class _ContextAction {
  const _ContextAction({
    required this.key,
    required this.icon,
    required this.label,
    required this.menuLabel,
    required this.onTap,
    this.busy = false,
  });

  final Key key;
  final IconData icon;

  /// Its short name, for a tile.
  final String label;

  /// Its full name, for a menu.
  final String menuLabel;
  final VoidCallback onTap;

  /// It is under way: not offered again until it answers.
  final bool busy;
}

/// One fact about the open conversation: its mark, its name, what it is now
/// and where it leads.
@immutable
class _ContextRow {
  const _ContextRow({
    required this.key,
    required this.leading,
    required this.label,
    required this.onTap,
    this.value,
  });

  final Key key;
  final Widget leading;
  final String label;
  final Widget? value;
  final VoidCallback? onTap;
}

/// What the desktop card and the phone sheet both show: the same facts, drawn
/// twice. Built from the session's state on every build of either.
@immutable
class _SessionContext {
  const _SessionContext({
    required this.title,
    required this.project,
    required this.projectPath,
    required this.branch,
    required this.changes,
    required this.terminals,
    required this.connection,
    required this.model,
    required this.lineage,
    required this.forks,
    required this.usage,
    required this.actions,
  });

  final String title;
  final String project;
  final String? projectPath;
  final String? branch;
  final _ContextRow changes;
  final List<BackgroundTerminal> terminals;
  final _ContextRow connection;
  final _ContextRow? model;

  /// A fork under way, and the conversation this one branched from. They say
  /// what the conversation is, so they lead every renderer's facts.
  final List<_ContextRow> lineage;

  /// The conversations branched from this one.
  final List<_ContextRow> forks;
  final List<_ContextRow> usage;
  final List<_ContextAction> actions;
}

/// The context card's geometry: its slot beside the conversation, margins
/// included, and the chat room below which it folds.
abstract final class _SessionContextCard {
  static const double slotWidth = 296;
  static const double chatMinimum = 520;
}

extension _SessionContextView on _AppSessionState {
  /// What can be done with the open conversation, by capability.
  List<_ContextAction> _contextActions(AppLocalizations l10n) => [
    if (_threadId != null && _caps.rename)
      _ContextAction(
        key: const Key('session-rename'),
        icon: AppIcons.edit_outlined,
        label: l10n.renameConversation,
        menuLabel: l10n.renameConversation,
        onTap: _beginTitleEdit,
      ),
    if (_threadId != null && _canFork)
      _ContextAction(
        key: const Key('session-fork'),
        icon: AppIcons.account_tree_outlined,
        label: l10n.forkConfirm,
        menuLabel: l10n.forkConversation,
        busy: _fork.pending,
        onTap: () => unawaited(_forkConversation()),
      ),
    if (_threadId != null && _canCompact)
      _ContextAction(
        key: const Key('session-compact'),
        icon: AppIcons.fold_vertical,
        label: l10n.compactShort,
        menuLabel: l10n.compact,
        onTap: _compact,
      ),
    _ContextAction(
      key: const Key('session-show-in-galaxy'),
      icon: AppIcons.orbit,
      label: l10n.galaxyTitle,
      menuLabel: l10n.sessionShowInGalaxy,
      onTap: _showInGalaxy,
    ),
    if (_threadId != null && _canReleaseSession)
      _ContextAction(
        key: const Key('session-release'),
        icon: AppIcons.hand_back,
        label: l10n.sessionHandBackShort,
        menuLabel: l10n.sessionHandBack,
        onTap: () => unawaited(_releaseSession()),
      ),
  ];

  /// The session's context as it stands.
  _SessionContext _contextModel(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final d = _diff;
    final path = _cwd?.trim();
    final activeModel = _activeModelStatus();
    final ctx = _ctx;
    final quota = _tightestQuota(l10n);
    const iconSize = 16.0;
    final muted = TextStyle(color: scheme.onSurfaceVariant);
    final source = _fork.source;
    final origin = source == null ? null : _forkOrigin(l10n, source);
    Widget spinner() => SizedBox.square(
      dimension: iconSize - 2,
      child: CircularProgressIndicator(
        strokeWidth: 1.6,
        color: signalColor(scheme),
      ),
    );
    return _SessionContext(
      lineage: [
        if (_fork.pending)
          _ContextRow(
            key: const Key('context-fork-pending'),
            leading: spinner(),
            label: l10n.forkPending,
            onTap: null,
          ),
        if (origin != null)
          _ContextRow(
            key: const Key('context-fork-source'),
            leading: const Icon(AppIcons.account_tree_outlined, size: iconSize),
            label: origin.label,
            onTap: origin.open,
          ),
      ],
      forks: [
        if (_threadId case final open?)
          for (final fork in _forksOf(open))
            _ContextRow(
              key: Key('context-fork-${fork.id}'),
              leading: const Icon(
                AppIcons.account_tree_outlined,
                size: iconSize,
              ),
              label: _threadName(fork, l10n),
              value: Text(
                _relativeTime(fork.updatedAt, DateTime.now(), l10n),
                style: muted,
              ),
              onTap: () => _openThread(fork.id, fork.cwd),
            ),
      ],
      title: _barTitle(l10n),
      project: _newProjectLabel(l10n, _projectName()),
      projectPath: path == null || path.isEmpty ? null : path,
      branch: _branch,
      terminals: _context.terminals,
      changes: _ContextRow(
        key: const Key('context-changes'),
        leading: _diffLoading
            ? spinner()
            : const Icon(AppIcons.git_compare, size: iconSize),
        label: l10n.changesTitle,
        value: d != null && !d.isEmpty
            ? ChangeCounts(added: d.added, removed: d.removed, gap: 6)
            : null,
        onTap: _showDiff,
      ),
      connection: _ContextRow(
        key: const Key('context-connection'),
        leading: LinkPathMark(
          serviceKey: widget.serviceKey,
          onTap: _showLink,
          size: iconSize,
        ),
        label: _hostLabel(l10n),
        value: LinkPathLabel(serviceKey: widget.serviceKey, style: muted),
        onTap: _showLink,
      ),
      model: activeModel == null
          ? null
          : _ContextRow(
              key: const Key('context-model'),
              leading: const Icon(
                AppIcons.auto_awesome_outlined,
                size: iconSize,
              ),
              label: _modelDisplayLabel(activeModel.id)!,
              onTap: _showRuntimeSheet,
            ),
      usage: [
        if (ctx != null)
          _ContextRow(
            key: const Key('context-usage'),
            leading: UsageRing(fraction: ctx.fraction, size: iconSize),
            label: l10n.contextLabel,
            value: Text('${ctx.percent}%', style: muted),
            onTap: _showContextDetail,
          ),
        if (quota != null)
          _ContextRow(
            key: const Key('context-quota'),
            leading: UsageRing(fraction: quota.window.fraction, size: iconSize),
            label: '${l10n.quotaRemaining} · ${quota.label}',
            value: Text(
              '${quota.left}%',
              style: TextStyle(
                color: UsageRing.colorOf(scheme, quota.window.fraction),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            onTap: _showContextDetail,
          ),
      ],
      actions: _contextActions(l10n),
    );
  }

  /// The strip's toggle: show or hide the card, remembering the choice. A
  /// window without the room opens the same facts in a panel instead.
  void _toggleContextCard() {
    if (!_context.cardFits || _reviewOpen) {
      unawaited(_showContextPanel());
      return;
    }
    final open = !_context.cardOpen;
    _layoutRestored = true;
    _updateState(() => _context.cardOpen = open);
    ref.read(uiPrefsProvider.notifier).setContextCardOpen(open);
    if (open) unawaited(_loadTerminals());
  }

  /// [chat] with the context card standing beside it, sliding away when the
  /// user hides it, the room runs out or the review takes its place.
  Widget _withContextCard(Widget chat, AppLocalizations l10n) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(child: chat),
      TweenAnimationBuilder<double>(
        tween: Tween(end: _context.cardShown ? 1 : 0),
        duration: _paneDragging
            ? Duration.zero
            : Motion.of(context, Motion.medium),
        curve: Motion.move,
        // Built afresh from the state, so its facts are always current.
        builder: (context, shown, _) => shown == 0
            ? const SizedBox.shrink()
            : ClipRect(
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  widthFactor: shown,
                  child: SizedBox(
                    width: _SessionContextCard.slotWidth,
                    child: _contextCard(_contextModel(l10n), l10n),
                  ),
                ),
              ),
      ),
    ],
  );

  /// The desktop renderer: a floating card of quiet rows under headings.
  Widget _contextCard(_SessionContext model, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    Widget rule() => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Divider(height: 1, color: scheme.outlineVariant),
    );
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: onSurfaceMuted(scheme),
        ),
      ),
    );
    final path = model.projectPath;
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        key: const Key('context-card'),
        padding: const EdgeInsets.fromLTRB(0, 10, 12, 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: floatingSurface(scheme),
            borderRadius: BorderRadius.circular(kPanelRadius + 2),
            border: Border.all(color: floatingEdge(scheme)),
            boxShadow: floatingShadows(scheme, lift: 0.6),
          ),
          child: SingleChildScrollView(
            primary: false,
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        model.project,
                        key: const Key('context-project'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    PopupMenuButton<VoidCallback>(
                      key: const Key('context-project-menu'),
                      tooltip: l10n.moreActions,
                      position: PopupMenuPosition.under,
                      icon: Icon(
                        AppIcons.more_horiz,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      style: IconButton.styleFrom(
                        minimumSize: const Size.square(28),
                        fixedSize: const Size.square(28),
                        padding: EdgeInsets.zero,
                      ),
                      onSelected: (action) => action(),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: () => _newConversationInProject(_cwd, context),
                          child: Text(l10n.newConversation),
                        ),
                        if (path != null)
                          PopupMenuItem(
                            value: () async {
                              await Clipboard.setData(
                                ClipboardData(text: path),
                              );
                              if (mounted) showToastOk(context, l10n.copied);
                            },
                            child: Text(l10n.copyProjectPath),
                          ),
                      ],
                    ),
                  ],
                ),
                for (final row in model.lineage) _cardRow(row),
                _cardRow(model.changes),
                if (model.branch case final branch?)
                  _cardRow(
                    _ContextRow(
                      key: const Key('context-branch'),
                      leading: const Icon(AppIcons.git_branch, size: 16),
                      label: branch,
                      onTap: null,
                    ),
                  ),
                if (model.model case final row?) _cardRow(row),
                if (model.forks.isNotEmpty) ...[
                  rule(),
                  heading(l10n.forksSection),
                  for (final row in model.forks) _cardRow(row),
                ],
                if (model.terminals.isNotEmpty) ...[
                  rule(),
                  heading(l10n.backgroundProcesses),
                  for (final terminal in model.terminals)
                    _cardRow(_terminalRow(terminal)),
                ],
                rule(),
                heading(l10n.linkSheetTitle),
                _cardRow(model.connection),
                if (model.usage.isNotEmpty) ...[
                  rule(),
                  heading(l10n.usageSection),
                  for (final row in model.usage) _cardRow(row),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// One of the card's rows.
  Widget _cardRow(_ContextRow row) {
    final scheme = Theme.of(context).colorScheme;
    final content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: isDesktop ? 32 : 44),
      child: Padding(
        padding: const EdgeInsetsDirectional.only(end: 6),
        child: IconTheme.merge(
          data: IconThemeData(color: scheme.onSurfaceVariant),
          child: Row(
            children: [
              SizedBox.square(dimension: 18, child: Center(child: row.leading)),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  row.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5),
                ),
              ),
              if (row.value case final value?) ...[
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 110),
                  child: DefaultTextStyle.merge(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                    child: value,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return Material(
      key: row.key,
      type: MaterialType.transparency,
      child: row.onTap == null
          ? content
          : InkWell(
              mouseCursor: clickable,
              borderRadius: BorderRadius.circular(kControlRadius),
              hoverColor: softWash(scheme),
              onTap: row.onTap,
              child: content,
            ),
    );
  }

  /// Open the context's facts over the page: a sheet on a phone, a popover
  /// from the pressed control on a window too narrow for the card.
  Future<void> _showContextPanel() async {
    _updateState(() => _context.panelOpen = true);
    unawaited(_loadTerminals());
    if (_rate == null) unawaited(_loadQuota());
    try {
      await showAdaptivePanel<void>(
        context: context,
        anchored: true,
        maxWidth: 380,
        insetTop: false,
        // Rebuilt after each build of the session: the panel is another route.
        builder: (panel) => ValueListenableBuilder<int>(
          valueListenable: _context.changes,
          builder: (panel, _, _) {
            final l10n = AppLocalizations.of(panel);
            return _contextFacts(
              _contextModel(l10n),
              l10n,
              close: () => Navigator.of(panel).pop(),
            );
          },
        ),
      );
    } finally {
      if (mounted) _updateState(() => _context.panelOpen = false);
    }
  }

  /// The phone renderer: the title and where it lives, the actions as tiles,
  /// then one row per fact.
  Widget _contextFacts(
    _SessionContext model,
    AppLocalizations l10n, {
    required VoidCallback close,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    void closeThen(VoidCallback? action) {
      close();
      action?.call();
    }

    Widget row(_ContextRow row) {
      final onTap = row.onTap;
      return Material(
        key: row.key,
        type: MaterialType.transparency,
        child: InkWell(
          mouseCursor: clickable,
          borderRadius: BorderRadius.circular(kRowRadius),
          onTap: onTap == null ? null : () => closeThen(onTap),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 50),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 2, 8),
              child: IconTheme.merge(
                data: IconThemeData(color: scheme.onSurfaceVariant),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: 24,
                      child: Center(child: row.leading),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        row.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                    if (row.value case final value?) ...[
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 140),
                        child: DefaultTextStyle.merge(
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14),
                          child: value,
                        ),
                      ),
                    ],
                    const SizedBox(width: 6),
                    Icon(
                      AppIcons.chevron_right,
                      size: 18,
                      color: onTap == null
                          ? Colors.transparent
                          : onSurfaceMuted(scheme),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final where = [model.project, ?model.branch].join(' · ');
    return Padding(
      key: const Key('context-sheet'),
      // A sheet's grab handle stands above it; a popover has none.
      padding: EdgeInsets.fromLTRB(16, isDesktop ? 16 : 0, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  model.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 2),
                Text(
                  where,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          _contextActionTiles(model.actions, closeThen),
          const SizedBox(height: 12),
          for (final fact in model.lineage) row(fact),
          for (final fork in model.forks) row(fork),
          row(model.changes),
          if (model.terminals.isNotEmpty)
            row(
              _ContextRow(
                key: const Key('context-terminals'),
                leading: const Icon(AppIcons.terminal_prompt, size: 20),
                label: l10n.backgroundProcesses,
                value: Text('${model.terminals.length}'),
                onTap: _showTerminals,
              ),
            ),
          row(model.connection),
          if (model.model case final model?) row(model),
          for (final usage in model.usage) row(usage),
        ],
      ),
    );
  }

  /// The actions as tiles, four to a row, or fewer when large text would not
  /// fit them.
  Widget _contextActionTiles(
    List<_ContextAction> actions,
    void Function(VoidCallback?) closeThen,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        final perRow = (box.maxWidth / (82 * scale)).floor().clamp(2, 4);
        const gap = 8.0;
        final width = (box.maxWidth - gap * (perRow - 1)) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final action in actions)
              SizedBox(
                width: width,
                child: Material(
                  color: floatingTile(scheme),
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    key: action.key,
                    mouseCursor: clickable,
                    borderRadius: BorderRadius.circular(16),
                    onTap: action.busy ? null : () => closeThen(action.onTap),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 72),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 8,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox.square(
                              dimension: 20,
                              child: action.busy
                                  ? const Padding(
                                      padding: EdgeInsets.all(2),
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(action.icon, size: 20),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              action.label,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                color: scheme.onSurface,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
