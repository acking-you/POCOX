part of '../app_session_screen.dart';

extension _SessionTitle on _AppSessionState {
  String _projectName() {
    final leaf = _leafOf(_cwd ?? '');
    return leaf.isEmpty ? AppLocalizations.of(context).defaultFolder : leaf;
  }

  /// Title-bar text: the current conversation, ChatGPT-desktop style. Falls
  /// back through the server-side thread preview, then the locally echoed
  /// last user message (a fresh thread's server preview stays empty until its
  /// first turn round-trips), then "new conversation".
  String _barTitle(AppLocalizations l10n) {
    final tid = _threadId;
    if (tid != null) {
      final match = _threads.where((t) => t.id == tid);
      final meta = match.isEmpty ? null : match.first;
      // A user-set name wins outright — that's the whole point of renaming.
      final named = meta?.title;
      if (named != null) return named;
      // Previews are the raw first user message, which may be wire text (an
      // attachment block); run them through the same cleaner the sidebar uses
      // so the two never disagree.
      final preview = meta == null
          ? ''
          : previewWithoutFileRefs(meta.preview, l10n.fileOnlyMessage);
      for (final candidate in [preview, _lastUserText ?? '']) {
        final line = candidate.trim().split('\n').first.trim();
        if (line.isNotEmpty) return line;
      }
    }
    return l10n.newConversation;
  }

  /// Commit a rename typed into the top bar. Empty clears the name (back to
  /// the preview). Applied locally first so the bar doesn't flicker back to
  /// the old title while the request is in flight.
  Future<void> _renameThread(String raw) async {
    final tid = _threadId;
    _updateState(() => _editingTitle = false);
    if (tid == null || !_caps.rename) return;
    final name = raw.trim();
    final idx = _threads.indexWhere((t) => t.id == tid);
    final before = idx < 0 ? null : _threads[idx];
    if (before != null && (before.title ?? '') == name) return;
    // Opening the field and committing it untouched must stay a no-op: the box
    // is seeded with the displayed title, and pinning an auto-preview as an
    // explicit name would silently stop it tracking the conversation.
    if (before?.title == null &&
        name == _barTitle(AppLocalizations.of(context)).trim()) {
      return;
    }
    final seq = ++_renameSeq;
    if (before != null) {
      _updateState(() {
        final next = [..._threads];
        next[idx] = before.withName(name.isEmpty ? null : name);
        _threads = next;
      });
    }
    try {
      await ref
          .read(bridgeApiProvider)
          .appSetThreadName(widget.serviceKey, tid, name);
    } catch (e) {
      // Put the old title back: the server is the source of truth, so a failed
      // rename must not leave the UI claiming it worked. Only when this is
      // still the newest attempt, though — a later rename has already replaced
      // what we'd be restoring, and its own request owns the outcome now.
      if (!mounted || seq != _renameSeq) return;
      if (before != null) {
        final at = _threads.indexWhere((t) => t.id == tid);
        if (at >= 0) {
          _updateState(() {
            final next = [..._threads];
            next[at] = before;
            _threads = next;
          });
        }
      }
      final l10n = AppLocalizations.of(context);
      showToastError(context, '${l10n.renameFailed}: ${friendlyError(e)}');
    }
  }

  /// Adopt a `thread/name/updated` notification: the server persists titles, so
  /// this is how a rename made on ANOTHER device (or in another window) reaches
  /// this list. The echo of our OWN rename carries the name we already applied
  /// optimistically, so the equality check below makes it a no-op.
  void _applyRemoteName(AppEvent e) {
    final tid = e.threadId ?? _threadIdFromRaw(e.raw);
    if (tid == null) return;
    final idx = _threads.indexWhere((t) => t.id == tid);
    if (idx < 0) return;
    final name = _nameFromRaw(e.raw);
    if ((_threads[idx].title ?? '') == (name ?? '')) return;
    _updateState(() {
      final next = [..._threads];
      next[idx] = next[idx].withName(name);
      _threads = next;
    });
  }

  /// `threadId` out of a notification's raw JSON, when the typed field is unset.
  String? _threadIdFromRaw(String raw) => _rawString(raw, 'threadId');

  /// The `name` a `thread/name/updated` carries; null when cleared or absent.
  String? _nameFromRaw(String raw) {
    final n = _rawString(raw, 'name')?.trim();
    return (n == null || n.isEmpty) ? null : n;
  }

  /// One string field out of an event's raw JSON params, or null on any shape
  /// surprise (a malformed notification must not take the screen down).
  String? _rawString(String raw, String key) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final v = decoded[key];
      return v is String ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// [label] followed by its window shortcut in the platform's notation
  /// (`⌘B` on macOS, `Ctrl+B` elsewhere), for a tooltip.
  String _withShortcut(String label, String key) {
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    return '$label  ${mac ? '⌘$key' : 'Ctrl+$key'}';
  }

  /// A quiet 30 px icon button for the window strips, sized to sit on the
  /// traffic lights' centre line.
  Widget _chromeButton({
    Key? key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size(30, 30),
        fixedSize: const Size(30, 30),
        padding: EdgeInsets.zero,
        foregroundColor: scheme.onSurfaceVariant,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRowRadius),
        ),
      ),
      icon: Icon(icon, size: 18),
    );
  }

  /// The content pane's slim header (the desktop window has no full-width app
  /// bar): the conversation title and the few session actions, over a
  /// drag-to-move area. When the sidebar is collapsed it also carries the
  /// expand control and — on macOS — the traffic-light inset; on frameless
  /// Windows it draws the caption buttons at the trailing edge.
  Widget _contentTopBar(AppLocalizations l10n, double width) {
    final isMac = isMacDesktop;
    final scheme = Theme.of(context).colorScheme;
    // No rule under the header: the status line below it continues the same
    // block (title, then its facts) and carries the one hairline.
    // The bar heads the sheet: transparent on it, and centred on the traffic
    // lights' line.
    return SizedBox(
      height: WindowChrome.sheetBarHeight,
      child: Stack(
        // Centre the row on the strip, so every control shares the traffic
        // lights' centre line.
        alignment: Alignment.centerLeft,
        children: [
          const Positioned.fill(child: WindowDragArea()),
          Row(
            children: [
              // With the sidebar hidden this strip owns the leading corner, so
              // it clears the traffic lights itself.
              SizedBox(width: _leftOpen ? 10 : WindowChrome.leadingInset),
              if (!_leftOpen) ...[
                _chromeButton(
                  key: const Key('sidebar-expand-btn'),
                  tooltip: _withShortcut(l10n.showSidebar, 'B'),
                  icon: AppIcons.panel_left_open,
                  onPressed: () => _setLeftOpen(true),
                ),
                _chromeButton(
                  tooltip: _withShortcut(l10n.newConversation, 'N'),
                  icon: AppIcons.edit_square,
                  onPressed: () => _newConversationInProject(_cwd, context),
                ),
                const SizedBox(width: 4),
              ],
              if (!widget.home)
                _chromeButton(
                  tooltip: l10n.backToSessions,
                  icon: AppIcons.arrow_back,
                  onPressed: _backToSessions,
                ),
              const SizedBox(width: 6),
              // The title is a label, not a banner: cap it well short of the
              // bar so a long conversation preview truncates and the rest of
              // the strip stays empty (and draggable).
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: _barTitleWidget(l10n),
                  ),
                ),
              ),
              // With the sidebar hidden, the call's status and hang-up move
              // into the window strip rather than disappearing with it.
              if (!_leftOpen) ...[
                _voiceStatus(l10n, compact: true),
                const SizedBox(width: 6),
              ],
              if (_ctx != null)
                ContextGauge(
                  status: _ctx!,
                  onTap: _showContextDetail,
                  tooltip: _contextTooltip(l10n),
                ),
              // Environment info lives in a popover off this button — a
              // desktop affordance, hidden when the window can't host it.
              if (width >= 900) _envButton(l10n),
              // Appearance sits with the window's own controls rather than in
              // the sidebar footer: it acts on the whole window, and it was the
              // one frequently-used control that moved (or vanished) with the
              // sidebar.
              const ThemeToggle(),
              if (_threadId != null && _moreActions)
                PopupMenuButton<String>(
                  tooltip: l10n.moreActions,
                  icon: Icon(
                    AppIcons.more_horiz,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  style: IconButton.styleFrom(
                    minimumSize: const Size(30, 30),
                    fixedSize: const Size(30, 30),
                    padding: EdgeInsets.zero,
                  ),
                  onSelected: (v) {
                    if (v == 'compact') _compact();
                    if (v == 'rename') _beginTitleEdit();
                    if (v == 'session-release') unawaited(_releaseSession());
                  },
                  itemBuilder: (c) => [
                    if (_canReleaseSession)
                      PopupMenuItem(
                        key: const Key('session-release'),
                        value: 'session-release',
                        child: Text(l10n.sessionHandBack),
                      ),
                    if (_caps.rename)
                      PopupMenuItem(
                        value: 'rename',
                        child: Text(l10n.renameConversation),
                      ),
                    if (_canCompact)
                      PopupMenuItem(
                        value: 'compact',
                        child: Text(l10n.compact),
                      ),
                  ],
                ),
              if (isFramelessDesktop && !isMac) ...[
                const SizedBox(width: 6),
                const WindowCaptionButtons(),
              ] else
                const SizedBox(width: 10),
            ],
          ),
        ],
      ),
    );
  }

  /// Enter title-edit mode, seeded with the current title and fully selected
  /// (so typing replaces it, the way a rename should).
  void _beginTitleEdit() {
    if (_threadId == null || !_caps.rename) return;
    final l10n = AppLocalizations.of(context);
    _titleCtrl.text = _barTitle(l10n);
    _titleCtrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _titleCtrl.text.length,
    );
    _updateState(() => _editingTitle = true);
    _titleFocus.requestFocus();
  }

  /// The top bar's conversation title: a compact label that becomes a text
  /// field on click (codex-app style). Enter commits, Esc cancels, and losing
  /// focus commits too — a click elsewhere reads as "done", not "undo".
  Widget _barTitleWidget(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    const style = TextStyle(fontSize: 14, fontWeight: FontWeight.w600);
    if (_editingTitle) {
      return Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): _CancelTitleEditIntent(),
        },
        child: Actions(
          actions: {
            _CancelTitleEditIntent: CallbackAction<_CancelTitleEditIntent>(
              onInvoke: (_) {
                _updateState(() => _editingTitle = false);
                return null;
              },
            ),
          },
          child: TextField(
            key: const Key('bar-title-field'),
            controller: _titleCtrl,
            focusNode: _titleFocus,
            style: style,
            maxLines: 1,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              isDense: true,
              hintText: l10n.renameConversationHint,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 6,
              ),
            ),
            onSubmitted: _renameThread,
            onTapOutside: (_) {
              if (_editingTitle) _renameThread(_titleCtrl.text);
            },
          ),
        ),
      );
    }
    // A title too long for the bar fades out at its trailing edge instead of
    // ending in an ellipsis, so it reads as text continuing past the cap
    // rather than as a short label. Only when it actually overflows: fading a
    // title that fits would just look like the text was dimming for no reason.
    final text = _barTitle(l10n);
    final title = LayoutBuilder(
      key: const Key('bar-title'),
      builder: (ctx, box) {
        final label = Text(
          text,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: style,
        );
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: Directionality.of(ctx),
        )..layout();
        if (painter.width <= box.maxWidth) return label;
        // A fixed-width fade, so the ramp looks the same however long the
        // title is (a percentage would stretch with the text).
        final fade = (24 / box.maxWidth).clamp(0.0, 1.0);
        return ShaderMask(
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: const [Colors.black, Colors.black, Colors.transparent],
            stops: [0, 1 - fade, 1],
          ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: label,
        );
      },
    );
    // Only a real conversation can be renamed; a fresh one has no id yet.
    if (_threadId == null) return title;
    return Tooltip(
      // A clipped label can't be read in full, so hovering reveals the whole
      // title with the rename hint underneath it.
      richMessage: TextSpan(
        children: [
          TextSpan(text: text),
          TextSpan(
            text: '\n${l10n.renameHint}',
            style: TextStyle(
              color: scheme.onInverseSurface.withValues(alpha: 0.7),
              fontSize: 11,
            ),
          ),
        ],
      ),
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          key: const Key('bar-title-tap'),
          borderRadius: BorderRadius.circular(7),
          // A single click edits, so the label needs to look clickable on
          // hover: a soft plate plus a text cursor, since the strip behind it
          // drags the window and would otherwise claim the whole area. A text
          // cursor rather than the hand every other target gets — clicking
          // here puts a caret in the title, it isn't a button.
          hoverColor: scheme.onSurface.withValues(alpha: 0.06),
          mouseCursor: SystemMouseCursors.text,
          onTap: _beginTitleEdit,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: title,
          ),
        ),
      ),
    );
  }
}
