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
      final meta =
          _threads.where((t) => t.id == tid).firstOrNull ??
          _discoveredThreads[tid];
      // A user-set name wins outright — that's the whole point of renaming.
      final named = meta?.title;
      if (named != null) return named;
      // Previews are the raw first user message, which may be wire text (an
      // attachment block); run them through the same cleaner the sidebar uses
      // so the two never disagree.
      final preview = meta == null
          ? ''
          : previewWithoutFileRefs(meta.preview, l10n.fileOnlyMessage);
      for (final candidate in [preview, _lastSent?.text ?? '']) {
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

  /// What the title strip names: the folder mark and the conversation, whose
  /// title a click renames, then the running turn's state while nothing else
  /// on screen shows it.
  Widget _stripTitle(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final title = Row(
      children: [
        if (!widget.home) ...[
          StripButton(
            tooltip: l10n.backToSessions,
            icon: AppIcons.arrow_back,
            onPressed: _backToSessions,
          ),
          const SizedBox(width: 6),
        ],
        if (_fork.source == null)
          Icon(
            AppIcons.folder_outlined,
            size: 16,
            color: scheme.onSurfaceVariant,
          )
        else
          _forkBadge(l10n, key: const Key('strip-fork-mark'), size: 20),
        const SizedBox(width: 6),
        // The title is a label, not a banner: cap it well short of the strip
        // so a long conversation preview truncates and the rest of the strip
        // stays empty (and draggable).
        Flexible(
          flex: 2,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: _barTitleWidget(l10n),
          ),
        ),
        if (_fork.source case final source?)
          Flexible(child: _stripForkOrigin(l10n, source)),
        if (!_statusStripShown(l10n) && !_inlineStatus) ?_runningState(l10n),
      ],
    );
    return _inlineStatus ? _titleWithStatus(l10n, title) : title;
  }

  /// The running turn's state and clock, for the title strip.
  Widget? _runningState(AppLocalizations l10n) {
    if (!_streaming && !_externalWriterRunning) return null;
    final st = _sessionState(l10n);
    final style = TextStyle(
      fontSize: 12,
      color: st.color,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      key: const Key('strip-running-state'),
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PulsingDot(color: st.color, size: 7),
          const SizedBox(width: 6),
          Text(st.label, style: style),
          const SizedBox(width: 6),
          ValueListenableBuilder<int>(
            valueListenable: _elapsed,
            builder: (context, secs, _) =>
                Text(_fmtElapsed(secs), style: style),
          ),
        ],
      ),
    );
  }

  /// The strip's end: the conversation's menu and the context card's toggle.
  List<Widget> _stripActions(AppLocalizations l10n) => [
    _conversationMenu(l10n),
    const SizedBox(width: 2),
    StripButton(
      key: const Key('context-card-toggle'),
      selected: _context.cardShown,
      tooltip: _context.cardShown ? l10n.contextCardHide : l10n.contextCardShow,
      icon: AppIcons.panel_right,
      onPressed: _toggleContextCard,
    ),
  ];

  /// The conversation's `···`: what can be done with it, by capability.
  Widget _conversationMenu(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final actions = _contextActions(l10n);
    return PopupMenuButton<_ContextAction>(
      key: const Key('conversation-menu'),
      tooltip: l10n.moreActions,
      position: PopupMenuPosition.under,
      icon: Icon(AppIcons.more_horiz, size: 18, color: scheme.onSurfaceVariant),
      style: IconButton.styleFrom(
        minimumSize: Size.square(StripButton.size),
        fixedSize: Size.square(StripButton.size),
        padding: EdgeInsets.zero,
      ),
      onSelected: (action) => action.onTap(),
      itemBuilder: (_) => [
        for (final action in actions)
          PopupMenuItem(
            key: action.key,
            value: action,
            enabled: !action.busy,
            child: Text(action.menuLabel),
          ),
      ],
    );
  }

  /// The phone's top bar title: the conversation with a chevron and its state
  /// line under it, opening the context sheet. While the link is down it opens
  /// the connection sheet directly, so Retry now stays one tap away.
  Widget _phoneTitle(AppLocalizations l10n) {
    if (_editingTitle) return _barTitleWidget(l10n);
    final scheme = Theme.of(context).colorScheme;
    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_fork.source != null) ...[
          _forkBadge(l10n, key: const Key('strip-fork-mark')),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            _barTitle(l10n),
            key: const Key('bar-title'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 16,
              height: 1.25,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Icon(AppIcons.expand_more, size: 14, color: scheme.onSurfaceVariant),
      ],
    );
    final linkDown = _reconnecting || _connectionLost;
    return Semantics(
      button: true,
      label: _barTitle(l10n),
      hint: linkDown ? l10n.linkSheetTitle : l10n.contextCardShow,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const Key('session-context-btn'),
          mouseCursor: clickable,
          borderRadius: BorderRadius.circular(kControlRadius),
          onTap: linkDown ? _showLink : _showContextPanel,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _inlineStatus
                  ? _titleWithStatus(l10n, title, phone: true)
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [title, _stateLine(l10n)],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// A short window's title row: [title], cut well short, then the status
  /// line taking the rest, which shortens itself as it does on its strip.
  Widget _titleWithStatus(
    AppLocalizations l10n,
    Widget title, {
    bool phone = false,
  }) => LayoutBuilder(
    builder: (context, box) => Row(
      key: const Key('title-with-status'),
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: math.min(320, box.maxWidth * 0.45),
          ),
          child: title,
        ),
        const SizedBox(width: 12),
        Expanded(child: phone ? _stateLine(l10n) : _statusLine(l10n)),
      ],
    ),
  );

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
    const style = TextStyle(fontSize: 14, fontWeight: FontWeight.w500);
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
