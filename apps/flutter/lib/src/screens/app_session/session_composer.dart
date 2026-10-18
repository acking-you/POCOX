part of '../app_session_screen.dart';

extension _SessionComposer on _AppSessionState {
  /// Keep the tail of the conversation visible when the soft keyboard opens.
  /// Only when the user was already at the bottom — pulling someone back down
  /// while they're reading history would be worse than the keyboard.
  void _onComposerFocus() {
    _repinForKeyboard();
    // Someone about to type may well dictate instead: have the line ready.
    if (_inputFocus.hasFocus) _warmDictation();
  }

  void _saveDraft() {
    _draft.value = _input.value;
    _drafts.save(_draft);
  }

  bool _composerSizeChanged(SizeChangedLayoutNotification notification) {
    if (_atBottom) {
      final intent = _scrollIntent;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && intent == _scrollIntent) _scrollToEnd(force: true);
      });
    }
    return false;
  }

  Future<void> _expandComposer() async {
    if (_editorOpen) return;
    final selection = _input.selection;
    _updateState(() => _editorOpen = true);
    _inputFocus.unfocus();
    _input.selection = selection;
    await showAppDialog<void>(
      context: context,
      fullscreen: true,
      builder: (_) =>
          ExpandedComposer(controller: _input, focusNode: _expandedInputFocus),
    );
    if (!mounted) return;
    _updateState(() => _editorOpen = false);
    _inputFocus.requestFocus();
  }

  Future<void> _editMessage(String text) async {
    if (_editorOpen ||
        _externalWriterMode ||
        _historySyncing ||
        _showingCachedHistory) {
      return;
    }
    final draft = _draft;
    _updateState(() => _editorOpen = true);
    _inputFocus.unfocus();
    final edited = await showAppDialog<String>(
      context: context,
      fullscreen: true,
      builder: (_) => MessageEditor(
        text: text,
        hasDraft: draft.value.text.isNotEmpty || draft.attachments.isNotEmpty,
      ),
    );
    if (!mounted) return;
    _updateState(() => _editorOpen = false);
    if (edited != null && edited.trim().isNotEmpty) {
      // Read the latest draft: a queued send or upload may finish while the
      // editor is open. Keep its attachments and any newer text intact.
      final previous = draft.value.text;
      final combined = previous.isEmpty ? edited : '$previous\n\n$edited';
      draft.value = TextEditingValue(
        text: combined,
        selection: TextSelection.collapsed(offset: combined.length),
      );
      _drafts.save(draft, changed: true);
      if (identical(_draft, draft)) _input.value = draft.value;
    }
    if (identical(_draft, draft)) _inputFocus.requestFocus();
  }

  Widget _composer(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final prefs = ref.watch(uiPrefsProvider).valueOrNull;
    final media = MediaQuery.of(context);
    final inputStyle = theme.textTheme.bodyLarge!;
    final line = TextPainter(
      text: TextSpan(text: ' ', style: inputStyle),
      textDirection: Directionality.of(context),
      textScaler: media.textScaler,
      locale: Localizations.localeOf(context),
    );
    // Keep one complete line and its caret visible at any system text scale.
    final minHeight = math.max(
      28.0,
      line.preferredLineHeight.ceilToDouble() + 2,
    );
    line.dispose();
    final defaultHeight = math.max(32.0, minHeight);
    final maxHeight = math.max(
      minHeight,
      math.min(280.0, (media.size.height - media.viewInsets.bottom) * 0.35),
    );
    final inputHeight =
        (_composerHeight ?? prefs?.composerHeight ?? defaultHeight).clamp(
          minHeight,
          maxHeight,
        );
    void resize(double value, {bool save = false}) {
      _updateState(() => _composerHeight = value.clamp(minHeight, maxHeight));
      if (save) {
        ref.read(uiPrefsProvider.notifier).setComposerHeight(_composerHeight!);
      }
    }

    final doc = MediaQuery.sizeOf(context).width >= docLayoutWidth;
    final touch = !isDesktop;
    final grown =
        (_composerHeight ?? prefs?.composerHeight ?? defaultHeight) >
        defaultHeight;

    // Fast and Supplement change how THIS turn is sent, so they sit with the
    // other per-turn controls. FilterChips, compact, and only while relevant.
    Widget turnChip({
      required Key key,
      required String tooltip,
      required String label,
      required bool selected,
      required ValueChanged<bool>? onSelected,
      IconData? icon,
    }) => Tooltip(
      message: tooltip,
      child: FilterChip(
        key: key,
        avatar: icon == null ? null : Icon(icon, size: 15),
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: touch
            ? MaterialTapTargetSize.padded
            : MaterialTapTargetSize.shrinkWrap,
        labelStyle: TextStyle(
          fontSize: 12.5,
          color: selected
              ? scheme.onTertiaryContainer
              : scheme.onSurfaceVariant,
        ),
        onSelected: onSelected,
      ),
    );
    final agentTarget = _agentTarget();
    final supplementAgent = _caps.providerName;
    final modeChips = [
      if (_fastAvailable)
        turnChip(
          key: const Key('fast-mode-btn'),
          tooltip: l10n.fastModeHint,
          label: l10n.fastMode,
          icon: AppIcons.bolt,
          selected: _effectiveServiceTier == 'priority',
          onSelected: _sending
              ? null
              : (enabled) {
                  _updateState(() {
                    _serviceTier = enabled ? 'priority' : 'default';
                    _serviceTierPickPending = true;
                  });
                  _rememberDefaults();
                  _persistThreadConfig();
                },
        ),
      if (_streaming && _caps.steer)
        turnChip(
          key: const Key('supplement-toggle'),
          tooltip: l10n.steerMessageHint,
          label: l10n.steerMessage,
          selected: _supplement,
          onSelected: _sending
              ? null
              : (selected) => _updateState(() => _supplement = selected),
        ),
      if (_streaming && !_caps.steer && _caps.hostAccess)
        Tooltip(
          message: l10n.steerUnavailableHint,
          child: ActionChip(
            key: const Key('supplement-unavailable'),
            avatar: const Icon(AppIcons.info_outline, size: 15),
            label: Text(l10n.steerQueueOnly),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: touch
                ? MaterialTapTargetSize.padded
                : MaterialTapTargetSize.shrinkWrap,
            labelStyle: TextStyle(
              fontSize: 12.5,
              color: scheme.onSurfaceVariant,
            ),
            onPressed: () => showInfoPanel(
              context: context,
              title: l10n.steerUnavailableTitle,
              body: l10n.steerUnavailableDetails(supplementAgent),
            ),
          ),
        ),
    ];

    // The top edge of the card is the resize handle: a desktop user finds it
    // by the cursor, the way a pane edge is found; touch gets a visible grip.
    // Double-click / double-tap returns to the compact height.
    final resizeEdge = Semantics(
      label: l10n.resizeComposer,
      value: '${inputHeight.round()}',
      increasedValue:
          '${(inputHeight + 24).clamp(minHeight, maxHeight).round()}',
      decreasedValue:
          '${(inputHeight - 24).clamp(minHeight, maxHeight).round()}',
      onIncrease: () => resize(inputHeight + 24, save: true),
      onDecrease: () => resize(inputHeight - 24, save: true),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        child: GestureDetector(
          key: const Key('composer-resize-handle'),
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (_) => _composerDragHeight.value = inputHeight,
          onVerticalDragUpdate: (details) => _composerDragHeight.value =
              ((_composerDragHeight.value ?? inputHeight) - details.delta.dy)
                  .clamp(minHeight, maxHeight),
          onVerticalDragEnd: (_) {
            final dragged = _composerDragHeight.value;
            _composerDragHeight.value = null;
            if (dragged != null) resize(dragged, save: true);
          },
          onVerticalDragCancel: () {
            final dragged = _composerDragHeight.value;
            _composerDragHeight.value = null;
            if (dragged != null) resize(dragged, save: true);
          },
          onDoubleTap: () => resize(defaultHeight, save: true),
          child: Tooltip(
            message: l10n.resizeComposer,
            waitDuration: const Duration(milliseconds: 900),
            child: SizedBox(
              height: touch ? 18 : 12,
              width: double.infinity,
              child: touch
                  ? Center(
                      child: Container(
                        width: 32,
                        height: 4,
                        decoration: BoxDecoration(
                          color: scheme.outlineVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    )
                  : null,
            ),
          ),
        ),
      ),
    );

    // Small square tools beside the field: expand to the full editor, and
    // return to the compact height once the user has grown it.
    Widget fieldTool({
      required Key key,
      required String tooltip,
      required IconData icon,
      required VoidCallback onPressed,
    }) => IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      style: IconButton.styleFrom(
        minimumSize: touch ? const Size(44, 44) : const Size(28, 28),
        fixedSize: touch ? null : const Size(28, 28),
        padding: EdgeInsets.zero,
        foregroundColor: scheme.onSurfaceVariant,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRowRadius),
        ),
      ),
    );

    final field = NotificationListener<SizeChangedLayoutNotification>(
      onNotification: _composerSizeChanged,
      child: SizeChangedLayoutNotifier(
        child: ValueListenableBuilder<double?>(
          valueListenable: _composerDragHeight,
          builder: (context, dragged, input) => ConstrainedBox(
            key: const Key('composer-input-area'),
            constraints: BoxConstraints(
              minHeight: dragged ?? inputHeight,
              maxHeight: math.max(dragged ?? 0, maxHeight),
            ),
            child: input,
          ),
          child: TextField(
            key: const Key('composer-input'),
            controller: _input,
            focusNode: _inputFocus,
            readOnly: _editorOpen,
            minLines: 1,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            onSubmitted: _isDesktop
                ? (_) {
                    if (!_input.value.composing.isValid ||
                        _input.value.composing.isCollapsed) {
                      _submit();
                    }
                  }
                : null,
            style: inputStyle,
            cursorColor: scheme.onSurface,
            decoration: InputDecoration(
              filled: false,
              hintText: _dictationTake != DictationTake.idle
                  ? l10n.dictationListening
                  : _streaming
                  ? (_supplement ? l10n.steerMessage : l10n.queueNextTurn)
                  : l10n.messageHint,
              hintStyle: inputStyle.copyWith(color: scheme.onSurfaceVariant),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              isCollapsed: true,
              // Override the shared form-field padding inside this compact card.
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ),
    );

    // The turn-mode chips ride in the toolbar only where the card has room for
    // them beside the permission and model pills (~180 px each); narrower
    // cards give them their own line above.
    Widget composerBody(bool inlineModes) {
      final toolbar = _composerToolbar(
        l10n,
        inlineModes: inlineModes,
        modeChips: modeChips,
        agentTarget: agentTarget,
      );

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          resizeEdge,
          Padding(
            padding: EdgeInsets.fromLTRB(
              touch ? 14 : 18,
              touch ? 0 : 4,
              touch ? 10 : 12,
              touch ? 8 : 10,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_queue.isNotEmpty) ...[
                  _queuedStrip(l10n),
                  const SizedBox(height: 8),
                ],
                if (_attachments.isNotEmpty) ...[
                  _attachmentStrip(l10n),
                  const SizedBox(height: 8),
                ],
                if (_tools.isNotEmpty) ...[
                  _builtinToolsStrip(),
                  const SizedBox(height: 8),
                ],
                // A take's strip: the field stays editable below it, and the
                // words appear in the field itself as they are spoken.
                Motion.resize(
                  context,
                  duration: Motion.of(context, Motion.fast),
                  curve: Motion.move,
                  alignment: Alignment.topCenter,
                  child: _dictationTake == DictationTake.idle
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: DictationBar(
                            line: _dictation,
                            onFinish: _finishDictation,
                            onCancel: _cancelDictation,
                            showKeys: _isDesktop,
                          ),
                        ),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          left: touch ? 4 : 2,
                          top: touch ? 2 : 0,
                        ),
                        child: field,
                      ),
                    ),
                    const SizedBox(width: 4),
                    // Pinned to the field's first line, so it never moves as
                    // the draft grows.
                    Transform.translate(
                      offset: Offset(0, touch ? -10 : -4),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          fieldTool(
                            key: const Key('composer-expand'),
                            tooltip: l10n.expandComposer,
                            icon: AppIcons.open_in_full,
                            onPressed: _expandComposer,
                          ),
                          if (grown)
                            fieldTool(
                              key: const Key('composer-reset-height'),
                              tooltip: l10n.resetComposerHeight,
                              icon: AppIcons.unfold_less,
                              onPressed: () =>
                                  resize(defaultHeight, save: true),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                // The turn modes that do not ride in the toolbar head its
                // line above (see [_composerToolbar]).
                SizedBox(height: touch ? 4 : 8),
                toolbar,
              ],
            ),
          ),
        ],
      );
    }

    final card = ListenableBuilder(
      listenable: _inputFocus,
      builder: (context, child) {
        // The card is a pane of glass over the transcript's foot: what
        // scrolls beneath shows through it, blurred. Its edge says what the
        // composer is doing — the live signal while the agent answers
        // (anything sent now queues), the voice colour during a take — and
        // focus lifts it a little further off the page.
        final edge = _dictationTake != DictationTake.idle
            ? dictationColor(scheme).withValues(alpha: 0.7)
            : _streaming
            ? signalColor(scheme).withValues(alpha: 0.5)
            : _inputFocus.hasFocus
            ? scheme.onSurface.withValues(alpha: 0.16)
            : null;
        return Glass(
          depth: GlassDepth.floating,
          borderRadius: BorderRadius.circular(
            touch ? kTouchComposerRadius : kComposerRadius,
          ),
          lift: _inputFocus.hasFocus ? 1 : 0.7,
          edge: edge,
          child: child!,
        );
      },
      child: LayoutBuilder(
        builder: (context, box) =>
            composerBody(doc && modeChips.isNotEmpty && box.maxWidth >= 640),
      ),
    );

    return SafeArea(
      top: false,
      child: Padding(
        padding: doc
            ? const EdgeInsets.fromLTRB(16, 4, 16, 10)
            : const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _commandPalette(),
            // The card IS the input, so all of it takes a text cursor and
            // focuses the field on click — the padding beside a short line
            // shouldn't behave like dead chrome. The buttons inside sit deeper
            // in the tree, so they keep their own click cursor and taps.
            MouseRegion(
              cursor: SystemMouseCursors.text,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => _inputFocus.requestFocus(),
                child: card,
              ),
            ),
            // Desktop: where this turn will land — host, branch — as a
            // footnote under the card rather than chrome inside it; the facts
            // ellipsize rather than overflow. A phone shows them in the
            // status bar.
            if (doc)
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 7, 6, 0),
                child: _composerContext(l10n),
              ),
          ],
        ),
      ),
    );
  }

  /// Interrupt the running turn. An ink square, the shape every player and
  /// recorder uses for stop, so it can't be mistaken for send beside it.
  Widget _stopButton(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final touch = !isDesktop;
    return IconButton.filled(
      key: const Key('stop-btn'),
      onPressed: _interrupt,
      tooltip: l10n.stop,
      style: IconButton.styleFrom(
        minimumSize: touch ? const Size(40, 40) : const Size(32, 32),
        fixedSize: touch ? const Size(40, 40) : const Size(32, 32),
        padding: EdgeInsets.zero,
        backgroundColor: scheme.surfaceContainerHighest,
        foregroundColor: scheme.onSurface,
        shape: const CircleBorder(),
      ),
      icon: const Icon(AppIcons.stop_rounded, size: 18),
    );
  }

  /// The composer's context line: which project, which host, which branch this
  /// turn will run against. Read-only facts except the project, which is still
  /// changeable up until the thread exists.
  Widget _composerContext(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    Widget chip(
      String label, {
      IconData? icon,
      VoidCallback? onTap,
      Key? key,
      String? tip,
      bool busy = false,
    }) {
      final row = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: scheme.onSurfaceVariant,
              ),
            )
          else if (icon != null)
            Icon(icon, size: 13, color: scheme.onSurfaceVariant),
          if (busy || icon != null) const SizedBox(width: 5),
          // Flexible, not a bare ConstrainedBox: when the review split narrows
          // the chat, the label must be able to shrink below its natural width
          // and ellipsize rather than overflow the row.
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
            ),
          ),
        ],
      );
      final padded = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: row,
      );
      // Static chips still explain themselves on hover — a phone user reads
      // the same fact in the status bar, so this is the desktop affordance.
      return Tooltip(
        key: onTap == null ? key : null,
        message: tip ?? label,
        child: onTap == null
            ? padded
            : InkWell(
                mouseCursor: clickable,
                key: key,
                onTap: onTap,
                borderRadius: BorderRadius.circular(6),
                child: padded,
              ),
      );
    }

    // An ACP agent names itself and the project the turn runs in, so the
    // line reads "Claude · host · project" for every agent alike.
    final caps = _caps;
    final project = _cwd?.trim() ?? '';
    // Facts are told apart by position and a quiet separator, not by a row
    // of look-alike glyphs.
    final dot = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text('·', style: muted.copyWith(color: onSurfaceMuted(scheme))),
    );
    return Row(
      children: [
        if (caps.hostAccess && caps.providerName.isNotEmpty) ...[
          Flexible(
            child: Tooltip(
              message: caps.providerName,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                child: Row(
                  key: const Key('composer-agent-chip'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AgentIcon.of(
                      provider: caps.isOpenCode ? 'opencode' : 'acp',
                      profileId: caps.profileId,
                      name: caps.providerName,
                      size: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        caps.providerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          dot,
        ],
        Flexible(
          child: chip(_hostLabel(l10n), key: const Key('composer-host-chip')),
        ),
        if (caps.hostAccess && project.isNotEmpty) ...[
          dot,
          Flexible(child: chip(_projectName(), tip: project)),
        ],
        if (_branch != null) ...[
          dot,
          Flexible(
            child: chip(
              _branch!,
              icon: AppIcons.account_tree_outlined,
              key: const Key('composer-branch-chip'),
              tip: _diffLoading ? l10n.cancelDiffLoad : l10n.viewDiff,
              busy: _diffLoading,
              // The branch is the entry point to what has changed on it.
              onTap: _showDiff,
            ),
          ),
        ],
      ],
    );
  }

  /// Where the turn runs: "Local" when this service is hosted by this machine,
  /// else the remote device's own label.
  String _hostLabel(AppLocalizations l10n) {
    final locals = ref.watch(localServeListProvider).valueOrNull;
    final isLocal = (locals ?? const <AppServeStatus>[]).any(
      (h) => h.appServiceKey == widget.serviceKey,
    );
    if (isLocal) return l10n.envLocal;
    return switch (widget.services
        .where((s) => s.key == widget.serviceKey)
        .firstOrNull) {
      final service? => deviceLabel(service.device),
      null => serviceKeyLabel(widget.serviceKey),
    };
  }

  /// The `+` attachment menu. One button instead of three icons: on a phone the
  /// three used to crowd the row, and two of them are rare enough to live a tap
  /// away.
  // The host's tools are followed while the composer shows, so the menu
  // offers what the host offers now.
  Widget _attachMenu(AppLocalizations l10n) => KeyedSubtree(
    key: _attachAnchor,
    child: _attachMenuButton(l10n, tools: _hostTools(watch: true).isNotEmpty),
  );

  Widget _attachMenuButton(
    AppLocalizations l10n, {
    required bool tools,
  }) => PopupMenuButton<void>(
    key: const Key('attach-menu-btn'),
    tooltip: l10n.addAttachment,
    enabled: !_sending,
    style: isDesktop
        ? IconButton.styleFrom(
            minimumSize: const Size(30, 30),
            fixedSize: const Size(30, 30),
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(kControlRadius),
            ),
          )
        : null,
    icon: Icon(
      AppIcons.add,
      size: isDesktop ? 19 : 22,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
    // `_` on purpose: an item's `onTap` fires *after* `Navigator.pop`, so the
    // menu route's context is already on its way out. Everything below uses
    // the State's context, which outlives the menu.
    itemBuilder: (_) => [
      // Only where prompts can carry images (an ACP agent must advertise it).
      if (_caps.imageInput)
        PopupMenuItem<void>(
          key: const Key('attach-btn'),
          onTap: _pickImages,
          child: _menuRow(
            AppIcons.add_photo_alternate_outlined,
            l10n.attachImage,
          ),
        ),
      PopupMenuItem<void>(
        key: const Key('attach-file-btn'),
        onTap: _pickFiles,
        child: _menuRow(AppIcons.attach_file, l10n.attachFile),
      ),
      // Browsing / transferring host files uses the desktop save/open dialogs,
      // so it is gated the same way saving is.
      if (canSaveImages)
        PopupMenuItem<void>(
          key: const Key('host-files-btn'),
          onTap: () => showFileBrowser(context, serviceKey: widget.serviceKey),
          child: _menuRow(AppIcons.folder_open_outlined, l10n.hostFiles),
        ),
      // Always here too (where dictation exists), so a card too narrow for
      // the inline microphone still has it.
      if (_caps.dictation)
        PopupMenuItem<void>(
          key: const Key('dictate-menu'),
          enabled: !_voice.busy && !_dictation.taking && !_externalWriterMode,
          onTap: _startDictation,
          child: _menuRow(AppIcons.mic_none_rounded, l10n.dictate),
        ),
      // POCOX's own tools for the next message, where its host offers them.
      if (tools)
        PopupMenuItem<void>(
          key: const Key('builtin-tools-btn'),
          onTap: _pickBuiltinTools,
          child: _menuRow(AppIcons.extension, l10n.builtinTools),
        ),
    ],
  );

  Widget _sendButton() => ValueListenableBuilder<TextEditingValue>(
    valueListenable: _input,
    builder: (context, value, _) {
      final l10n = AppLocalizations.of(context);
      final hasDraft = value.text.trim().isNotEmpty || _attachments.isNotEmpty;
      final canSend =
          !_sending &&
          !_reconnecting &&
          !_connectionLost &&
          !_historySyncing &&
          !_restoringSettings &&
          !_showingCachedHistory &&
          !_savingAgentConfig &&
          !_attachments.any((a) => !a.ready) &&
          hasDraft;
      final scheme = Theme.of(context).colorScheme;
      final touch = !isDesktop;
      final side = touch ? 40.0 : 32.0;
      // Ink on the panel when there is something to send; a quiet plate
      // otherwise, so an empty composer doesn't hold a loud button.
      return AnimatedScale(
        scale: hasDraft ? 1 : 0.94,
        duration: Motion.of(context, Motion.fast),
        curve: Motion.enter,
        child: PressScale(
          scale: 0.9,
          enabled: canSend,
          child: IconButton.filled(
            key: const Key('send-btn'),
            onPressed: canSend ? _submit : null,
            tooltip: _restoringSettings
                ? l10n.restoringSessionSettings
                : _streaming
                ? (_supplement ? l10n.steerMessage : l10n.queueNextTurn)
                : _awaitingTurnStart
                ? l10n.queueNextTurn
                : l10n.send,
            style:
                IconButton.styleFrom(
                  minimumSize: Size(side, side),
                  fixedSize: Size(side, side),
                  padding: EdgeInsets.zero,
                  backgroundColor: scheme.onSurface,
                  foregroundColor: scheme.surface,
                  disabledBackgroundColor: scheme.onSurface.withValues(
                    alpha: 0.08,
                  ),
                  disabledForegroundColor: onSurfaceDisabled(scheme),
                  shape: const CircleBorder(),
                  elevation: canSend ? 2 : 0,
                  shadowColor: Colors.black.withValues(alpha: 0.5),
                ).copyWith(
                  // The send action is the one lit control in the composer.
                  backgroundBuilder: (context, states, child) =>
                      LitFace(states: states, child: child),
                ),
            icon: Icon(
              (_streaming && !_supplement) || _awaitingTurnStart
                  ? AppIcons.playlist_add
                  : AppIcons.arrow_upward_rounded,
              size: touch ? 20 : 18,
            ),
          ),
        ),
      );
    },
  );
}
