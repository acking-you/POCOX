part of '../app_session_screen.dart';

extension _SessionTranscript on _AppSessionState {
  /// Read a host-side image so it can render as a thumbnail instead of a
  /// filename chip:
  ///
  ///  * the host IS this machine (locally hosted service) — read the file off
  ///    disk, no tunnel involved;
  ///  * a remote host — ask for it as a transcript-referenced image, which the
  ///    host authorises against user attachments and generated artifacts, so a pasted
  ///    screenshot in its temp directory is reachable without granting a
  ///    general file read;
  ///  * a host too old to serve that route — fall back to the root-confined
  ///    file read, which still covers an image that lives in a project folder.
  ///
  /// A file that is gone (the system clears its temp directory) is still
  /// served by the host, from the copy the model request carried; a local
  /// host is asked for it too once the disk read finds nothing.
  ///
  /// Null on any refusal, so the caller falls back to the chip.
  Future<Uint8List?> _loadHostImage(String path) async {
    final local = (ref.read(localServeListProvider).valueOrNull ?? const [])
        .any((h) => h.appServiceKey == widget.serviceKey);
    if (local) {
      final bytes = await readLocalImage(path);
      if (bytes != null) return bytes;
    }
    final api = ref.read(bridgeApiProvider);
    final threadId = _threadId;
    if (threadId != null) {
      final bytes = await _tryRead(
        () => api.metaReadThreadImage(widget.serviceKey, threadId, path),
      );
      if (bytes != null) return bytes;
    }
    if (local) return null;
    return _tryRead(() => api.metaReadFile(widget.serviceKey, path));
  }

  /// Run a host read, mapping every refusal — outside the roots, unreferenced,
  /// route missing on an older host, file gone — to null, plus the two byte
  /// counts that aren't worth drawing.
  Future<Uint8List?> _tryRead(Future<Uint8List> Function() read) async {
    try {
      final bytes = await read();
      if (bytes.isEmpty || bytes.length > kMaxInlineImageBytes) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Widget _transcriptRow(Object row) => HistoryArrival(
    revision: _historyArrivalRow == _rowKey(row)
        ? _historyArrivalRevision
        : null,
    child: _buildTranscriptRow(row),
  );

  Widget _buildTranscriptRow(Object row) {
    if (row is HistoryGap) {
      final l10n = AppLocalizations.of(context);
      final targeted =
          !_historyFromTop &&
          _navigatingTurn == null &&
          _historyTarget == (row.turnId, row.continuation);
      return SizedBox(
        height: 44,
        child: Center(
          child: _historyAction(
            key: Key('history-gap-${row.turnId}'),
            loading: _loadingOlder && targeted,
            failed: _historyError && targeted,
            icon: AppIcons.unfold_more_rounded,
            iconSize: 18,
            label: l10n.historyGap,
            onPressed: _loadingOlder ? null : () => _loadGap(row, reveal: true),
          ),
        ),
      );
    }
    // Group identity stays stable as streaming appends items, preserving the
    // measured row and its expanded state.
    if (row is TurnWork) {
      final activeTurn =
          _turnId ??
          _turnSummaries.lastOrNull?.turnId ??
          _items.lastOrNull?.turnId;
      return TurnWorkCard(
        key: _rowKey(row),
        work: row,
        active:
            (_streaming || _externalWriterRunning) &&
            identical(row, _lastWork) &&
            row.items.last.turnId == activeTurn &&
            _items.lastOrNull?.isUser == false,
      );
    }
    if (row is ActivityGroup) {
      return GroupedActivityCard(key: _rowKey(row), group: row);
    }
    // A merged reply renders through the same view as a single one, so the
    // two can't drift apart: it is presented as one item whose text is the
    // whole turn.
    final item = switch (row) {
      AgentTurn() => TranscriptItem(
        id: row.items.first.id,
        type: 'agentMessage',
        text: row.text,
        streaming: row.streaming,
        turnId: row.items.first.turnId,
        turnCompletedAt: row.completedAt,
      ),
      _ => row as TranscriptItem,
    };
    return MessageView(
      key: _rowKey(row),
      item: item,
      errorActions: item.type == 'modelError' ? _modelErrorActions(item) : null,
      hostImageLoader: _loadHostImage,
      imageCacheScope: '${widget.serviceKey}:$_threadId',
      onEdit: _externalWriterMode || _historySyncing || _showingCachedHistory
          ? null
          : _editMessage,
    );
  }

  /// Reserve [height] at the transcript's end for what floats over its foot,
  /// keeping the latest message in view when the reader was already there.
  void _setComposerOverlay(double height) {
    if (!mounted || (height - _composerOverlay).abs() < 0.5) return;
    final follow = _atBottom;
    _updateState(() => _composerOverlay = height);
    if (follow) _scrollToEnd();
  }

  /// Remember the composer block's own height, which the pending requests
  /// above it leave free.
  void _setComposerBlock(double height) {
    if (!mounted || (height - _composerBlock).abs() < 0.5) return;
    _updateState(() => _composerBlock = height);
  }

  /// The capsule over a turn the rail is reading: loading, or a retry, and
  /// a way to give up on it.
  Widget _navigationStatus(TurnMinimapItem target, AppLocalizations l10n) {
    final close = IconButton(
      tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
      visualDensity: VisualDensity.compact,
      icon: const Icon(AppIcons.close, size: 16),
      onPressed: () {
        _turnNavigation++;
        _updateState(() {
          _navigatingTurn = null;
          _navigationLoading = false;
        });
      },
    );
    if (_navigationLoading) {
      final turn = _turnMinimapItems(
        _rows,
      ).indexWhere((item) => item.turnId == target.turnId);
      return FloatingStatus(
        busy: true,
        label: l10n.loadingTurn(turn + 1),
        trailing: [close],
      );
    }
    return Glass(
      depth: GlassDepth.floating,
      borderRadius: BorderRadius.circular(999),
      lift: 0.6,
      padding: const EdgeInsets.only(left: 4, right: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: TextButton.icon(
              onPressed: () => _selectTurn(target),
              icon: const Icon(AppIcons.refresh, size: 16),
              label: Text(l10n.historyRetry),
            ),
          ),
          close,
        ],
      ),
    );
  }

  /// The center column: the status bar, then the conversation (kept centred
  /// with a max width) with the pending requests and the composer floating
  /// over its foot.
  Widget _chatPane(AppLocalizations l10n) {
    final sheet = sheetColor(Theme.of(context).colorScheme);
    final hostSwitch = _hostSwitchBanner();
    final pane = Column(
      children: [
        _statusBar(l10n),
        // Where the reader is looking: the switch announces itself above the
        // conversation, which stays put until the new host has answered.
        Motion.resize(
          context,
          duration: Motion.of(context, Motion.medium),
          curve: Motion.move,
          alignment: Alignment.topCenter,
          child: hostSwitch ?? const SizedBox(width: double.infinity),
        ),
        Expanded(
          // The transcript fills the pane and scrolls on beneath what floats
          // over its foot: the composer — a pane of glass that blurs the
          // conversation passing under it — and, above it, any pending
          // requests.
          child: LayoutBuilder(
            builder: (context, room) => Stack(
              children: [
                Positioned.fill(child: _transcriptLayer(l10n, sheet)),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _transcriptFoot(l10n, sheet, room.maxHeight),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    // The keyboard in landscape (or very large text) can leave less height
    // than the status bar and composer need. Then the pane keeps a usable
    // height and scrolls, anchored at the composer, instead of cutting off
    // its bottom; the status bar stays one scroll away. The scroll view is
    // always there on touch, so the keyboard opening never rebuilds the
    // field it is typing into.
    if (isDesktop) return pane;
    return LayoutBuilder(
      builder: (context, box) {
        if (!box.maxHeight.isFinite) return pane;
        final usable = MediaQuery.textScalerOf(context).scale(170) + 130;
        return SingleChildScrollView(
          key: const Key('chat-short-scroll'),
          primary: false,
          reverse: true,
          child: SizedBox(height: math.max(box.maxHeight, usable), child: pane),
        );
      },
    );
  }

  /// Follow the reader's scrolling: intent, letting go of and returning to
  /// the end, and an overscroll past either edge asking for more history.
  bool _onTranscriptScroll(ScrollNotification event) {
    if (event.depth != 0) return false;
    if ((event is UserScrollNotification &&
            event.direction != ScrollDirection.idle) ||
        (event is ScrollUpdateNotification && event.dragDetails != null) ||
        (event is OverscrollNotification && event.dragDetails != null)) {
      _scrollIntent++;
    }
    // Coming to rest at the end follows the conversation again.
    if (event is ScrollEndNotification &&
        event.metrics.pixels >= event.metrics.maxScrollExtent - 1) {
      _scroll.stickToEnd = true;
    }
    // Short pages cannot move their scroll offset. An overscroll is
    // still a deliberate request to reach history beyond the edge.
    if (event is OverscrollNotification &&
        event.dragDetails != null &&
        !_historyError &&
        !_loadingOlder) {
      if (event.overscroll < 0) {
        _loadAtTop();
      } else if (event.overscroll > 0) {
        final gap = _rows.lastOrNull;
        if (gap is HistoryGap) _loadGap(gap);
      }
    }
    return false;
  }

  /// The conversation itself, with what floats over it: the turn
  /// navigation, the fade under the header, the transcript's status and the
  /// running plan.
  Widget _transcriptLayer(AppLocalizations l10n, Color sheet) {
    final runningPlan = _runningPlan;
    return NotificationListener<ScrollNotification>(
      onNotification: _onTranscriptScroll,
      child: MiddleClickScroll(
        key: ValueKey(_threadId),
        controller: _scroll,
        child: Stack(
          key: const Key('chat-conversation-layer'),
          children: [
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: Duration.zero,
                child: _loading
                    ? const ChatLoadingSkeleton(key: ValueKey('chat-loading'))
                    : KeyedSubtree(
                        key: const ValueKey('chat-content'),
                        child: _transcriptContent(l10n),
                      ),
              ),
            ),
            // Text scrolling up under the header fades out instead of
            // being cut at a hard line.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 18,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [sheet, sheet.withValues(alpha: 0)],
                    ),
                  ),
                ),
              ),
            ),
            // What the transcript is doing floats over its top: arriving and
            // leaving moves nothing beneath it.
            Positioned(
              top: 8,
              left: 16,
              right: 16,
              child: _transcriptStatus(l10n),
            ),
            if (runningPlan != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 8 + _composerOverlay,
                child: _turnProgress(runningPlan, l10n),
              ),
          ],
        ),
      ),
    );
  }

  /// The loaded conversation, or what stands in for an empty one.
  Widget _transcriptContent(AppLocalizations l10n) {
    if (_items.isEmpty && !_showTyping) {
      // A brand-new conversation (no thread yet) opens on its agent, project
      // and readiness; an empty resumed thread keeps the plain hint. Either
      // sits in the room the composer leaves, never beneath it.
      final theme = Theme.of(context);
      return Padding(
        padding: EdgeInsets.only(bottom: _composerOverlay),
        child: _threadId == null
            ? _agentWelcome(l10n)
            : Center(
                child: Text(
                  l10n.emptyConversation,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
      );
    }
    // One SelectionArea over the whole conversation so text can be
    // drag-selected and copied on desktop. Mobile messages open their own
    // long-press actions and text-selection page. The list is centered with
    // a max width so it reads well even when both side panes are collapsed
    // on a wide screen.
    return Stack(
      children: [
        // Full-width scroll area so the scrollbar sits at the window's right
        // edge; the column centres itself as it is laid out.
        Listener(
          // Touching the conversation (opening a step, selecting text) lets
          // go of the end: what it unfolds unfolds in place. New output
          // follows again on its own.
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _scroll.stickToEnd = false,
          child: SelectionArea(child: _transcriptList(l10n)),
        ),
        // Turn navigation. On a window wide enough to leave a gutter this is
        // the tick rail beside the conversation — hover a turn to preview
        // it, click to jump. Narrower, and on touch, it stays the
        // bottom-right cluster, which also carries jump-to-latest in both
        // cases.
        Positioned.fill(bottom: _composerOverlay, child: _turnNavOverlay()),
      ],
    );
  }

  /// History syncing or shown from the cache, and a turn the rail is
  /// reading, floating over the transcript's top.
  Widget _transcriptStatus(AppLocalizations l10n) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      IgnorePointer(
        child: FloatingStatusSwitcher(
          child: _historySyncing || _showingCachedHistory
              ? FloatingStatus(
                  key: const Key('history-sync-status'),
                  busy: _historySyncing,
                  icon: AppIcons.cloud_off,
                  label: _historySyncing
                      ? l10n.historySyncing
                      : l10n.historyCachedOffline,
                )
              : null,
        ),
      ),
      FloatingStatusSwitcher(
        child: switch (_navigatingTurn) {
          final target? => Padding(
            key: const Key('history-navigation-status'),
            padding: const EdgeInsets.only(top: 6),
            child: _navigationStatus(target, l10n),
          ),
          null => null,
        },
      ),
    ],
  );

  /// What floats over the transcript's foot, measured so the transcript
  /// keeps its end clear of it: the pending requests, then the composer.
  ///
  /// The requests come first, up to 45% of the screen and never more than
  /// the [room] left after the composer and keyboard minus a sliver of
  /// transcript. Each card is keyed by request id so State follows the
  /// right prompt if several are pending and one is answered out of order.
  Widget _transcriptFoot(AppLocalizations l10n, Color sheet, double room) {
    final writable = !_externalWriterMode;
    // Inline server requests: a `request_user_input` elicitation renders as
    // an interactive question card (the model is asking the user, not
    // requesting permission); everything else is a command/file/permission
    // approval.
    final server = <Widget>[
      if (writable)
        for (final a in _approvals)
          if (a.kind == 'item/tool/requestUserInput')
            UserInputCard(
              key: ValueKey(a.requestId),
              prompt: a,
              onAnswer: _answerUserInput,
            )
          // ACP agent requests are listed together below.
          else if (a.kind != agentPermissionKind)
            ApprovalCard(
              key: ValueKey(a.requestId),
              prompt: a,
              onDecide: _decide,
            ),
    ];
    // An ACP agent's requests carry their own options: render them as
    // offered and answer with the chosen option id verbatim. An agent can
    // ask several at once.
    final agent = <Widget>[
      if (writable)
        for (final a in _approvals)
          if (a.kind == agentPermissionKind)
            AgentPermissionCard(
              key: ValueKey(a.requestId),
              prompt: a,
              agentName: _caps.providerName,
              onAnswer: _answerAgentPermission,
            ),
    ];
    final questions = <Widget>[
      if (writable)
        for (final prompt in _asyncQuestions.values)
          UserInputCard(
            key: ValueKey('async-${prompt.id}'),
            prompt: prompt.cardEvent,
            onAnswer: (_, answers) => _answerAsyncInput(prompt, answers),
          ),
    ];
    final groups = [server, agent, questions].where((g) => g.isNotEmpty);
    final share = groups.isEmpty
        ? 0.0
        : math.max(
                0.0,
                math.min(
                  MediaQuery.sizeOf(context).height * 0.45,
                  room - 48 - _composerBlock,
                ),
              ) /
              groups.length;
    Widget requests(Key? key, List<Widget> cards) => ConstrainedBox(
      key: key,
      constraints: BoxConstraints(maxHeight: share),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: cards),
      ),
    );
    return HeightReporter(
      onHeight: _setComposerOverlay,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (server.isNotEmpty)
            requests(const Key('server-request-list'), server),
          if (agent.isNotEmpty)
            requests(const Key('agent-permission-list'), agent),
          if (questions.isNotEmpty) requests(null, questions),
          // Measured on its own so the requests above know how much room is
          // theirs.
          HeightReporter(
            onHeight: _setComposerBlock,
            child: _composerWithBars(l10n, sheet),
          ),
        ],
      ),
    );
  }

  /// The composer (or what stands in for it while this view only reads) and
  /// the bars that travel with it.
  Widget _composerWithBars(AppLocalizations l10n, Color sheet) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      // After a plan-mode turn, offer to implement the plan (persists across
      // restart since it's derived from the trailing plan item).
      if (!_externalWriterMode && _planReady) _implementBar(l10n),
      if (_error != null) _errorBanner(l10n),
      if (_isVoiceThread)
        _voiceBar(l10n)
      // A call running in another conversation stays reachable from here in
      // the narrow layout, where the sidebar is a closed drawer.
      else if (MediaQuery.sizeOf(context).width < 720 &&
          _voice.threadId != _threadId)
        _voiceStatus(l10n),
      DecoratedBox(
        // What scrolls under the glass fades into the sheet below it, so the
        // line under the card never sits on a sentence.
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              sheet.withValues(alpha: 0),
              sheet.withValues(alpha: 0.9),
              sheet,
            ],
            stops: const [0, 0.42, 0.62],
          ),
        ),
        child: _externalWriterMode
            ? _externalWriterAction(l10n)
            : Align(
                alignment: Alignment.bottomCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: _AppSessionState._kColumnWidth + 48,
                  ),
                  child: _composer(l10n),
                ),
              ),
      ),
    ],
  );

  /// Float the current checklist above the composer while work is in progress.
  /// The timeline still owns the durable plan card; this compact tracker is
  /// only the live, glanceable view and disappears with the turn.
  Widget _turnProgress(TranscriptItem plan, AppLocalizations l10n) {
    final parsed = parsePlan(plan.text);
    final diff = _diff;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 500;
        final avoidNavigation = constraints.maxWidth < 620;
        return Padding(
          padding: EdgeInsets.fromLTRB(12, 4, avoidNavigation ? 64 : 12, 2),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: TurnProgressTracker(
                key: ValueKey('turn-progress-${plan.id}'),
                steps: parsed.steps,
                changedFiles: diff?.files.length ?? 0,
                added: diff?.added ?? 0,
                removed: diff?.removed ?? 0,
                compact: compact,
                onViewDiff: diff != null && !diff.isEmpty ? _showDiff : null,
              ),
            ),
          ),
        );
      },
    );
  }
}
