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

    // Phones: classic Scaffold — the sessions list is a slide-in drawer, the
    // bar is a plain AppBar naming the conversation.
    if (width < 720) {
      return Scaffold(
        onDrawerChanged: (open) {
          if (open) return;
          final generation = _newDraftFocusAfterDrawer;
          _newDraftFocusAfterDrawer = null;
          if (generation != null) _focusNewComposer(generation);
        },
        drawer: Drawer(
          // The same ground as the desktop sidebar, so the list looks like one
          // component on every form factor. Composited onto the page surface
          // so it stays opaque over the scrim whatever the scheme's alpha.
          backgroundColor: Color.alphaBlend(
            surfaceSidebar(scheme),
            scheme.surface,
          ),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.horizontal(
              right: Radius.circular(kDialogRadius),
            ),
          ),
          surfaceTintColor: Colors.transparent,
          child: SafeArea(
            child: Column(
              children: [
                _voiceStatus(l10n),
                Expanded(child: _sessionsPane(l10n, inDrawer: true)),
              ],
            ),
          ),
        ),
        // Widen the edge-swipe-to-open zone (default ~20px). The narrow
        // default sits under Android's system back-gesture strip, so a
        // left-edge swipe almost always triggered "back" instead of the
        // drawer; a 56px zone lets the swipe start just inside that strip.
        drawerEdgeDragWidth: 56,
        appBar: WindowTitleBar(
          bottom: needsCodexSetup ? _codexSetupBar(l10n) : null,
          leading: Builder(
            builder: (ctx) => IconButton(
              tooltip: l10n.conversationsSection,
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(ctx).openDrawer(),
            ),
          ),
          title: Text(
            _barTitle(l10n),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          actions: [
            if (_ctx != null)
              ContextGauge(
                status: _ctx!,
                onTap: _showContextDetail,
                tooltip: _contextTooltip(l10n),
              ),
            // Same place as on desktop. It has to be here rather than in the
            // sessions pane, which on a phone lives behind the drawer.
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

    // Desktop / tablet: no full-width app bar. The sidebar is a full-height
    // tinted column reaching the window's top edge (the macOS traffic lights
    // float over its top strip); the content column carries its own slim
    // header with the conversation title and the session actions.
    final canRight = width >= 1100; // inline review split
    // Keep the transcript from being squeezed out when the window is narrow:
    // the panes give up width before the chat does.
    final maxLeft = ((width - 420) / 2).clamp(200.0, 520.0);
    final maxReview = (width - 360).clamp(400.0, 1200.0);
    final sidebarWidth = _leftWidth.clamp(200.0, maxLeft);
    return Scaffold(
      body: Row(
        children: [
          // The sidebar slides rather than snapping: the chat column visibly
          // takes over the space, so the user sees where the list went. The
          // content keeps its open width and is clipped while it slides, so
          // rows never reflow mid-animation. A drag resizes without easing.
          ClipRect(
            child: AnimatedContainer(
              duration: _paneDragging
                  ? Duration.zero
                  : Motion.of(context, Motion.medium),
              curve: Motion.move,
              width: _leftOpen ? sidebarWidth + 5 : 0,
              onEnd: () {
                if (_sidebarClosing && mounted) {
                  _updateState(() => _sidebarClosing = false);
                }
              },
              child: OverflowBox(
                alignment: Alignment.centerRight,
                minWidth: sidebarWidth + 5,
                maxWidth: sidebarWidth + 5,
                child: _leftOpen || _sidebarClosing
                    ? Row(
                        children: [
                          SizedBox(width: sidebarWidth, child: _sidebar(l10n)),
                          _splitter(
                            key: const Key('left-splitter'),
                            ground: surfaceSidebar(scheme),
                            onDragStart: () =>
                                _updateState(() => _paneDragging = true),
                            onDrag: (dx) => _updateState(
                              () => _leftWidth = (_leftWidth + dx).clamp(
                                200,
                                maxLeft,
                              ),
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
          ),
          Expanded(
            child: Column(
              children: [
                _contentTopBar(l10n, width),
                if (needsCodexSetup) _codexSetupBar(l10n),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(child: _dropWrap(_chatPane(l10n), l10n)),
                      if (canRight && _reviewOpen) ...[
                        _splitter(
                          key: const Key('review-splitter'),
                          // Dragging left widens a right-hand pane, hence the
                          // negation.
                          onDrag: (dx) => _updateState(
                            () => _reviewWidth = (_reviewWidth - dx).clamp(
                              400,
                              1200,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: _reviewWidth.clamp(400, maxReview),
                          child: _reviewSplit(l10n),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The full-height left sidebar: a tinted column that reaches the window's
  /// top edge, ChatGPT-desktop style. Its top strip hosts — once, quietly —
  /// everything the old title bar duplicated: the macOS traffic lights float
  /// over its leading inset, then the brand, then the collapse control. The
  /// strip also drags the window.
  Widget _sidebar(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
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
                icon: Icons.view_sidebar_outlined,
                onPressed: () => _setLeftOpen(false),
              ),
              _chromeButton(
                key: const Key('sidebar-new-conversation-btn'),
                tooltip: _withShortcut(l10n.newConversation, 'N'),
                icon: Icons.edit_square,
                onPressed: () => _newConversationInProject(_cwd, context),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ],
      ),
    );
    return Material(
      // A step off the page, like a macOS source list; the splitter's hairline
      // carries the actual edge.
      color: surfaceSidebar(scheme),
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
  /// The hairline sits on the trailing edge of a 5 px target painted in the
  /// left neighbour's ground, so the seam reads as one line, not a gutter.
  Widget _splitter({
    required Key key,
    required ValueChanged<double> onDrag,
    VoidCallback? onDragStart,
    VoidCallback? onDragEnd,
    Color? ground,
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
        width: 5,
        color: ground,
        alignment: Alignment.centerRight,
        child: VerticalDivider(
          width: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
    ),
  );
}
