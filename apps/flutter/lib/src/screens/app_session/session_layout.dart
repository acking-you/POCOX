part of '../app_session_screen.dart';

extension _SessionLayout on _AppSessionState {
  Widget _buildSession(BuildContext context) {
    ref.watch(_composerDraftsProvider(widget.serviceKey));
    ref.listen(uiPrefsProvider, (_, next) => _restoreLayout(next.valueOrNull));
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final width = MediaQuery.of(context).size.width;
    final needsCodexSetup = _codexNeedsSetup(watch: true);
    // A new ACP conversation opens its agent session by itself.
    if (_threadId == null && _caps.isAcp) _scheduleAgentSessionCheck();
    // A draft that keeps its own options reads them; it opens nothing.
    _scheduleDraftOptionsCheck();

    // Phones: the sessions list lies under the conversation, full screen,
    // and the conversation slides aside to uncover it (see LayeredNavigation).
    if (width < 720) {
      return LayeredNavigation(
        sidebarLabel: l10n.conversationsSection,
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

    // Desktop / tablet: no full-width app bar. The sidebar is a full-height
    // tinted column reaching the window's top edge (the macOS traffic lights
    // float over its top strip); the content column carries its own slim
    // header with the conversation title and the session actions.
    final canRight = width >= 1100; // inline review split
    // Keep the transcript from being squeezed out when the window is narrow:
    // the panes give up width before the chat does. A touch tablet keeps a
    // 480 px chat and lets the sidebar have the rest, so its finger-sized
    // rows and pill stay readable at the default width (an 834 px portrait
    // tablet shows the full 280 px instead of the desktop rule's 207 px).
    final maxLeft = isDesktop
        ? ((width - 420) / 2).clamp(200.0, 520.0)
        : (width - 480).clamp(200.0, 520.0);
    final maxReview = (width - 360).clamp(400.0, 1200.0);
    final sidebarWidth = _leftWidth.clamp(200.0, maxLeft);
    final slide = _paneDragging
        ? Duration.zero
        : Motion.of(context, Motion.medium);
    // The window in its layers: the backdrop, the sidebar drawn straight on
    // it, and the conversation on a rounded sheet beside it.
    return Scaffold(
      backgroundColor: backdropBase(scheme),
      body: AppBackdrop(
        child: Stack(
          children: [
            SafeArea(
              child: Row(
                children: [
                  _sidebarSlot(
                    l10n,
                    width: sidebarWidth,
                    maxWidth: maxLeft,
                    slide: slide,
                  ),
                  Expanded(
                    child: AnimatedPadding(
                      duration: slide,
                      curve: Motion.move,
                      padding: EdgeInsets.fromLTRB(
                        _leftOpen ? 0 : kSheetInset,
                        kSheetInset,
                        kSheetInset,
                        kSheetInset,
                      ),
                      child: ContentSheet(
                        child: Column(
                          children: [
                            _contentTopBar(l10n, width),
                            if (needsCodexSetup) _codexSetupBar(l10n),
                            Expanded(
                              child: _reviewLayer(
                                canRight: canRight,
                                width: _reviewWidth.clamp(400, maxReview),
                                chat: _dropWrap(_chatPane(l10n), l10n),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // The gap above the sheet is window chrome too: it drags.
            if (isFramelessDesktop)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: kSheetInset,
                child: WindowDragArea(),
              ),
          ],
        ),
      ),
    );
  }

  /// The desktop sidebar and the gap beside it, which is its resize handle.
  ///
  /// The sidebar slides rather than snapping: the sheet visibly takes over
  /// the space, so the user sees where the list went. The content keeps its
  /// open [width] and is clipped while it slides, so rows never reflow
  /// mid-animation. A drag resizes (up to [maxWidth]) without easing.
  Widget _sidebarSlot(
    AppLocalizations l10n, {
    required double width,
    required double maxWidth,
    required Duration slide,
  }) => ClipRect(
    child: AnimatedContainer(
      duration: slide,
      curve: Motion.move,
      width: _leftOpen ? width + kSheetInset : 0,
      onEnd: () {
        if (_sidebarClosing && mounted) {
          _updateState(() => _sidebarClosing = false);
        }
      },
      child: OverflowBox(
        alignment: Alignment.centerRight,
        minWidth: width + kSheetInset,
        maxWidth: width + kSheetInset,
        child: _leftOpen || _sidebarClosing
            ? Row(
                children: [
                  SizedBox(width: width, child: _sidebar(l10n)),
                  // The gap before the sheet is the handle.
                  _splitter(
                    key: const Key('left-splitter'),
                    width: kSheetInset,
                    line: false,
                    onDragStart: () => _updateState(() => _paneDragging = true),
                    onDrag: (dx) => _updateState(
                      () => _leftWidth = (_leftWidth + dx).clamp(200, maxWidth),
                    ),
                    onDragEnd: () {
                      _updateState(() => _paneDragging = false);
                      ref
                          .read(uiPrefsProvider.notifier)
                          .setSidebarWidth(_leftWidth);
                    },
                  ),
                ],
              )
            : const SizedBox.shrink(),
      ),
    ),
  );

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
    return Scaffold(
      appBar: WindowTitleBar(
        bottom: needsCodexSetup ? _codexSetupBar(l10n) : null,
        leading: Builder(
          builder: (ctx) => IconButton(
            key: const Key('sidebar-open-btn'),
            tooltip: l10n.conversationsSection,
            icon: const Icon(AppIcons.menu),
            onPressed: () => LayeredNavigation.maybeOf(ctx)?.open(),
          ),
        ),
        title: Text(
          _barTitle(l10n),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        actions: [
          if (_ctx != null)
            ContextGauge(
              status: _ctx!,
              onTap: _showContextDetail,
              tooltip: _contextTooltip(l10n),
            ),
          // Same place as on desktop. It has to be here rather than in the
          // sessions pane, which on a phone lies under the conversation.
          const ThemeToggle(),
          if (_threadId != null)
            PopupMenuButton<String>(
              tooltip: l10n.moreActions,
              onSelected: (v) {
                if (v == 'compact') _compact();
                if (v == 'session-release') unawaited(_releaseSession());
              },
              itemBuilder: (c) => [
                if (_canReleaseSession)
                  PopupMenuItem(
                    key: const Key('session-release'),
                    value: 'session-release',
                    child: Text(l10n.sessionHandBack),
                  ),
                PopupMenuItem(value: 'compact', child: Text(l10n.compact)),
              ],
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: _dropWrap(_chatPane(l10n), l10n),
    );
  }

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

  /// The phone's full-screen sessions list, lying under the conversation:
  /// the brand and a close control on top, then the same pane the desktop
  /// sidebar shows.
  Widget _phoneSidebar(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      key: const Key('phone-sidebar'),
      // The window's backdrop: the list lies on the same lit ground as the
      // desktop sidebar, under the conversation that slides aside.
      color: backdropBase(scheme),
      child: AppBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
                child: Row(
                  children: [
                    const BrandLogo(size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l10n.appTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Builder(
                      builder: (ctx) => IconButton(
                        key: const Key('sidebar-close-btn'),
                        tooltip: l10n.hideSidebar,
                        icon: const Icon(AppIcons.close),
                        onPressed: () =>
                            LayeredNavigation.maybeOf(ctx)?.close(),
                      ),
                    ),
                  ],
                ),
              ),
              _voiceStatus(l10n),
              Expanded(child: _sessionsPane(l10n, inDrawer: true)),
            ],
          ),
        ),
      ),
    );
  }

  /// The full-height left sidebar: a tinted column that reaches the window's
  /// top edge, ChatGPT-desktop style. Its top strip hosts — once, quietly —
  /// everything the old title bar duplicated: the macOS traffic lights float
  /// over its leading inset, then the brand, then the collapse control. The
  /// strip also drags the window.
  Widget _sidebar(AppLocalizations l10n) {
    final mac = isFramelessDesktop && isMacDesktop;
    // The strip shares the content header's height, so the collapse control,
    // the traffic lights and the title all sit on one centre line. On macOS
    // the lights own the leading corner, so the brand moves out of the strip
    // (the window title already names the app) and only the controls remain,
    // pushed to the trailing edge the way Finder and Mail lay out a sidebar.
    final strip = SizedBox(
      height: WindowChrome.barHeight,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          const Positioned.fill(child: WindowDragArea()),
          Row(
            children: [
              if (mac)
                const SizedBox(width: WindowChrome.trafficLightsWidth)
              else ...[
                const SizedBox(width: 14),
                const BrandLogo(size: 18),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    l10n.appTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
              const Spacer(),
              _chromeButton(
                key: const Key('sidebar-collapse-btn'),
                tooltip: _withShortcut(l10n.hideSidebar, 'B'),
                icon: AppIcons.view_sidebar_outlined,
                onPressed: () => _setLeftOpen(false),
              ),
              _chromeButton(
                key: const Key('sidebar-new-conversation-btn'),
                tooltip: _withShortcut(l10n.newConversation, 'N'),
                icon: AppIcons.edit_square,
                onPressed: () => _newConversationInProject(_cwd, context),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ],
      ),
    );
    return Material(
      // Drawn straight on the backdrop: the sheet beside it is the page.
      type: MaterialType.transparency,
      child: Column(
        children: [
          strip,
          // Pinned above the list, outside its scroll and its search filter:
          // a live call is always one glance and one tap away.
          _voiceStatus(l10n),
          Expanded(child: _sessionsPane(l10n)),
        ],
      ),
    );
  }

  /// Scroll the conversation list so row [index] — the open conversation —
  /// sits a third of the way down, where the eye lands first.
  void _revealConversationRow(int index) {
    if (!_convListCtl.isAttached || !_convScroll.hasClients) return;
    final duration = Motion.of(context, Motion.medium);
    if (duration == Duration.zero) {
      _convListCtl.jumpToItem(
        index: index,
        scrollController: _convScroll,
        alignment: 0.33,
      );
      return;
    }
    _convListCtl.animateToItem(
      index: index,
      scrollController: _convScroll,
      alignment: 0.33,
      duration: (_) => duration,
      curve: (_) => Motion.move,
    );
  }

  /// Show or hide the desktop sidebar, remembering the choice.
  void _setLeftOpen(bool open) {
    _layoutRestored = true;
    _updateState(() {
      // Keep the list built while it slides out; the animation's end drops
      // it. With reduced motion there is no slide, so nothing to keep.
      _sidebarClosing =
          !open && Motion.of(context, Motion.medium) > Duration.zero;
      _leftOpen = open;
    });
    ref.read(uiPrefsProvider.notifier).setSidebarOpen(open);
  }

  /// Adopt the saved sidebar layout once the prefs file has loaded, unless
  /// the user already changed it in this session.
  void _restoreLayout(UiPrefs? prefs) {
    if (_layoutRestored || prefs == null) return;
    _layoutRestored = true;
    final open = prefs.sidebarOpen ?? true;
    final width = prefs.sidebarWidth ?? _leftWidth;
    if (open == _leftOpen && width == _leftWidth) return;
    _updateState(() {
      _leftOpen = open;
      _leftWidth = width;
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
