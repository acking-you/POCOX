part of '../app_session_screen.dart';

extension _SessionLayout on _AppSessionState {
  /// Text another page added to this draft (the in-app browser's Send to
  /// agent) appears in the composer after this frame.
  void _showOutsideDraft() {
    final draft = _draft;
    if (draft.outside == _outsideSeen) return;
    _outsideSeen = draft.outside;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_draft, draft)) _input.value = draft.value;
    });
  }

  Widget _buildSession(BuildContext context) {
    ref.watch(_composerDraftsProvider(widget.serviceKey));
    _showOutsideDraft();
    // An open context panel is another route: tell it after this build.
    if (_context.panelOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _context.changes.value++;
      });
    }
    ref.listen(uiPrefsProvider, (_, next) => _restoreLayout(next.valueOrNull));
    final l10n = AppLocalizations.of(context);
    final width = MediaQuery.of(context).size.width;
    final needsCodexSetup = _codexNeedsSetup(watch: true);
    // A new ACP conversation opens its agent session by itself.
    if (_threadId == null && _caps.isAcp) _scheduleAgentSessionCheck();
    // A draft that keeps its own options reads them; it opens nothing.
    _scheduleDraftOptionsCheck();

    // Phones: the sessions list lies under the conversation, and the
    // conversation slides aside to uncover it (see LayeredNavigation).
    if (width < workspaceCompactWidth) {
      _context.cardShown = false;
      return LayeredNavigation(
        sidebarLabel: l10n.conversationsSection,
        closeLabel: l10n.backToConversation,
        ground: surfaceSidebar(Theme.of(context).colorScheme),
        onOpening: _revealOpenConversation,
        onOpenChanged: (open) {
          if (open) return;
          final generation = _newDraftFocusAfterDrawer;
          _newDraftFocusAfterDrawer = null;
          if (generation != null) _focusNewComposer(generation);
        },
        sidebar: _phoneSidebar(l10n),
        body: _phoneConversation(l10n, needsCodexSetup: needsCodexSetup),
      );
    }

    // The workspace: the title strip over the rail, the column and the
    // conversation with its context card. The column gives up width before the
    // chat goes under 480 px, so its rows stay readable at the default width.
    final canRight = width >= 1100; // inline review split
    final maxLeft = (width - workspaceRailWidth - 480).clamp(200.0, 520.0);
    final maxReview = (width - 360).clamp(400.0, 1200.0);
    final sidebarWidth = _leftWidth.clamp(200.0, maxLeft);
    // Measured room decides whether the card stands open; the review takes
    // its place while it is open.
    final room = width - workspaceRailWidth - (_leftOpen ? sidebarWidth : 0);
    _context.cardFits =
        room - _SessionContextCard.slotWidth >= _SessionContextCard.chatMinimum;
    _context.cardShown = _context.cardOpen && _context.cardFits && !_reviewOpen;
    return WorkspaceShell(
      section: '/',
      onOpen: (target) => openWorkspaceRoute(context, '/', target),
      title: _stripTitle(l10n),
      actions: _stripActions(l10n),
      column: _sidebar(l10n),
      columnOpen: _leftOpen,
      columnWidth: sidebarWidth,
      columnDragging: _paneDragging,
      columnHandle: _splitter(
        key: const Key('left-splitter'),
        line: false,
        onDragStart: () => _updateState(() => _paneDragging = true),
        onDrag: (dx) => _updateState(
          () => _leftWidth = (_leftWidth + dx).clamp(200, maxLeft),
        ),
        onDragEnd: () {
          _updateState(() => _paneDragging = false);
          ref.read(uiPrefsProvider.notifier).setSidebarWidth(_leftWidth);
        },
      ),
      onToggleColumn: () => _setLeftOpen(!_leftOpen),
      leading: [
        if (!_leftOpen)
          StripButton(
            key: const Key('sidebar-new-conversation-btn'),
            tooltip: withShortcut(l10n.newConversation, 'N'),
            icon: AppIcons.edit_square,
            onPressed: () => _newConversationInProject(_cwd, context),
          ),
      ],
      body: Column(
        children: [
          if (needsCodexSetup) _codexSetupBar(l10n),
          Expanded(
            child: _reviewLayer(
              canRight: canRight,
              width: _reviewWidth.clamp(400, maxReview),
              chat: _withContextCard(_dropWrap(_chatPane(l10n), l10n), l10n),
            ),
          ),
        ],
      ),
    );
  }

  /// The phone's conversation page: a plain app bar naming the conversation
  /// over the chat. It slides aside to uncover [_phoneSidebar].
  Widget _phoneConversation(
    AppLocalizations l10n, {
    required bool needsCodexSetup,
  }) {
    final page = _phoneChat(l10n, needsCodexSetup: needsCodexSetup);
    final duration = Motion.of(context, Motion.medium);
    // The review is a page of its own here, sliding in over the
    // conversation; back (or a swipe to the right) returns to it.
    return PopScope(
      canPop: !_reviewOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _reviewOpen) _closeReview();
      },
      child: Stack(
        children: [
          Positioned.fill(child: page),
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_reviewOpen,
              child: AnimatedSlide(
                offset: _reviewOpen ? Offset.zero : const Offset(1, 0),
                duration: duration,
                curve: Motion.move,
                onEnd: _reviewSettled,
                child: _reviewTarget == null
                    ? const SizedBox.shrink()
                    : GestureDetector(
                        onHorizontalDragEnd: (d) {
                          if ((d.primaryVelocity ?? 0) > 400) _closeReview();
                        },
                        child: Material(
                          color: sheetColor(Theme.of(context).colorScheme),
                          child: SafeArea(child: _reviewPanel(page: true)),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _phoneChat(AppLocalizations l10n, {required bool needsCodexSetup}) {
    final scaler = MediaQuery.textScalerOf(context);
    // The title and its state line, however large the text: the bar grows
    // rather than cutting them off.
    final height = math.max(
      kToolbarHeight,
      scaler.scale(16 * 1.25) + scaler.scale(12.5 * 1.3) + 10,
    );
    return Scaffold(
      appBar: WindowTitleBar(
        height: _inlineStatus || _editingTitle ? null : height,
        centerTitle: false,
        titleSpacing: 0,
        bottom: needsCodexSetup ? _codexSetupBar(l10n) : null,
        leading: Builder(
          builder: (ctx) => IconButton(
            key: const Key('sidebar-open-btn'),
            tooltip: l10n.conversationsSection,
            icon: const Icon(AppIcons.menu, size: 22),
            onPressed: () => LayeredNavigation.maybeOf(ctx)?.open(),
          ),
        ),
        title: _phoneTitle(l10n),
        actions: [
          IconButton(
            key: const Key('phone-new-conversation-btn'),
            tooltip: l10n.newConversation,
            icon: const Icon(AppIcons.edit_square, size: 22),
            onPressed: () => _newConversationInProject(_cwd, context),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _dropWrap(_chatPane(l10n), l10n),
    );
  }

  /// Open the galaxy on the service this conversation runs on, so its link
  /// shows how the conversation reaches it.
  void _showInGalaxy() => context.push(
    '/galaxy?focus=${Uri.encodeQueryComponent(widget.serviceKey)}',
  );

  /// A closed review, once it has slid away, stops being built.
  void _reviewSettled() {
    if (!_reviewOpen && _reviewTarget != null) {
      _updateState(() => _reviewTarget = null);
    }
  }

  /// The conversation and the review beside it. A wide window gives the
  /// review a resizable sidebar that slides open; a narrower one lays it
  /// over the conversation's right side, dimming the rest.
  Widget _reviewLayer({
    required bool canRight,
    required double width,
    required Widget chat,
  }) {
    final duration = _paneDragging
        ? Duration.zero
        : Motion.of(context, Motion.medium);
    if (canRight) {
      return Row(
        children: [
          Expanded(child: chat),
          // The sidebar is laid out at its full width throughout and only
          // revealed by the slide, so its rows never reflow mid-animation.
          TweenAnimationBuilder<double>(
            tween: Tween(end: _reviewOpen ? 1 : 0),
            duration: duration,
            curve: Motion.move,
            onEnd: _reviewSettled,
            builder: (context, shown, child) =>
                (shown == 0 && !_reviewOpen) || child == null
                ? const SizedBox.shrink()
                : ClipRect(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      widthFactor: shown,
                      child: child,
                    ),
                  ),
            child: _reviewTarget == null
                ? null
                : SizedBox(
                    width: width + 5,
                    child: Row(
                      children: [
                        _splitter(
                          key: const Key('review-splitter'),
                          // Dragging left widens a right-hand pane, hence
                          // the negation.
                          onDragStart: () =>
                              _updateState(() => _paneDragging = true),
                          onDrag: (dx) => _updateState(
                            () => _reviewWidth = (_reviewWidth - dx).clamp(
                              400,
                              1200,
                            ),
                          ),
                          onDragEnd: () =>
                              _updateState(() => _paneDragging = false),
                        ),
                        Expanded(child: _reviewPanel()),
                      ],
                    ),
                  ),
          ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final panel = math.min(560.0, box.maxWidth - 48);
        return Stack(
          children: [
            Positioned.fill(child: chat),
            // A tap beside the panel puts it away.
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_reviewOpen,
                child: GestureDetector(
                  onTap: _closeReview,
                  child: AnimatedOpacity(
                    opacity: _reviewOpen ? 1 : 0,
                    duration: duration,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.12),
                    ),
                  ),
                ),
              ),
            ),
            AnimatedPositioned(
              duration: duration,
              curve: Motion.move,
              onEnd: _reviewSettled,
              top: 8,
              bottom: 8,
              right: _reviewOpen ? 8 : -panel - 24,
              width: panel,
              child: _reviewTarget == null
                  ? const SizedBox.shrink()
                  : Glass(
                      depth: GlassDepth.overlay,
                      borderRadius: BorderRadius.circular(kPanelRadius),
                      child: _reviewPanel(),
                    ),
            ),
          ],
        );
      },
    );
  }

  /// The phone's sessions list, lying under the conversation.
  Widget _phoneSidebar(AppLocalizations l10n) => Material(
    key: const Key('phone-sidebar'),
    color: surfaceSidebar(Theme.of(context).colorScheme),
    child: SafeArea(child: _sessionsPane(l10n, inDrawer: true)),
  );

  /// The workspace's column on a chat.
  Widget _sidebar(AppLocalizations l10n) =>
      Material(type: MaterialType.transparency, child: _sessionsPane(l10n));

  /// Bring the open conversation's row into view as the drawer opens, unless
  /// a search is what the list shows or the row is already on screen.
  void _revealOpenConversation() {
    final index = _openConversationRow;
    if (index == null || !mounted || _convQuery.trim().isNotEmpty) return;
    if (!_convListCtl.isAttached || !_convScroll.hasClients) return;
    final visible = _convListCtl.visibleRange;
    if (visible != null && index >= visible.$1 && index <= visible.$2) return;
    _convListCtl.jumpToItem(
      index: index,
      scrollController: _convScroll,
      alignment: 0.33,
    );
  }

  /// Show or hide the column, remembering the choice.
  void _setLeftOpen(bool open) {
    _layoutRestored = true;
    _updateState(() => _leftOpen = open);
    ref.read(uiPrefsProvider.notifier).setSidebarOpen(open);
  }

  /// Adopt the saved sidebar layout once the prefs file has loaded, unless
  /// the user already changed it in this session.
  void _restoreLayout(UiPrefs? prefs) {
    if (_layoutRestored || prefs == null) return;
    _layoutRestored = true;
    final open = prefs.sidebarOpen ?? true;
    final width = prefs.sidebarWidth ?? _leftWidth;
    final card = prefs.contextCardOpen ?? true;
    if (open == _leftOpen && width == _leftWidth && card == _context.cardOpen) {
      return;
    }
    _updateState(() {
      _leftOpen = open;
      _leftWidth = width;
      _context.cardOpen = card;
    });
  }

  /// A pane divider you can drag. Reads as the same hairline as before until
  /// the pointer is over it: a wider invisible hit area (a 1 px target is
  /// unhittable) plus a resize cursor, so the affordance appears on hover the
  /// way a desktop splitter should.
  ///
  /// The hairline sits on the trailing edge of a 5 px target, so the seam
  /// reads as one line, not a gutter; without [line] the gap itself is the
  /// handle.
  Widget _splitter({
    required Key key,
    required ValueChanged<double> onDrag,
    VoidCallback? onDragStart,
    VoidCallback? onDragEnd,
    double width = 5,
    bool line = true,
  }) => MouseRegion(
    key: key,
    cursor: SystemMouseCursors.resizeLeftRight,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => onDragStart?.call(),
      onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
      onHorizontalDragEnd: (_) => onDragEnd?.call(),
      onHorizontalDragCancel: () => onDragEnd?.call(),
      child: Container(
        width: width,
        color: Colors.transparent,
        alignment: Alignment.centerRight,
        child: VerticalDivider(
          width: 1,
          color: line
              ? Theme.of(context).colorScheme.outlineVariant
              : Colors.transparent,
        ),
      ),
    ),
  );
}
