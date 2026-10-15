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
  /// Null on any refusal, so the caller falls back to the chip.
  Future<Uint8List?> _loadHostImage(String path) async {
    final local = (ref.read(localServeListProvider).valueOrNull ?? const [])
        .any((h) => h.appServiceKey == widget.serviceKey);
    if (local) return readLocalImage(path);
    final api = ref.read(bridgeApiProvider);
    final threadId = _threadId;
    if (threadId != null) {
      final bytes = await _tryRead(
        () => api.metaReadThreadImage(widget.serviceKey, threadId, path),
      );
      if (bytes != null) return bytes;
    }
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
      final loading = _loadingOlder && targeted;
      final failed = _historyError && targeted;
      return SizedBox(
        height: 44,
        child: Center(
          child: TextButton.icon(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
              textStyle: Theme.of(context).textTheme.labelSmall,
            ),
            key: Key('history-gap-${row.turnId}'),
            onPressed: _loadingOlder ? null : () => _loadGap(row, reveal: true),
            icon: loading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    failed ? Icons.refresh_rounded : Icons.unfold_more_rounded,
                    size: 18,
                  ),
            label: Text(
              loading
                  ? l10n.historyLoading
                  : failed
                  ? l10n.historyRetry
                  : l10n.historyGap,
            ),
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
    // A merged reply renders through the
    // same view as a single one, so the two
    // can't drift apart: it is presented as
    // one item whose text is the whole turn.
    if (row is AgentTurn) {
      return MessageView(
        key: _rowKey(row),
        item: TranscriptItem(
          id: row.items.first.id,
          type: 'agentMessage',
          text: row.text,
          streaming: row.streaming,
          turnId: row.items.first.turnId,
          turnCompletedAt: row.completedAt,
        ),
        hostImageLoader: _loadHostImage,
      );
    }
    final item = row as TranscriptItem;
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

  /// The center column: conversation (kept centered with a max width) +
  /// approvals + implement bar + error + composer.
  Widget _chatPane(AppLocalizations l10n) {
    final runningPlan = _runningPlan;
    final hostSwitch = _hostSwitchBanner();
    final transcript = NotificationListener<ScrollNotification>(
      onNotification: (event) {
        if (event.depth != 0) return false;
        if ((event is UserScrollNotification &&
                event.direction != ScrollDirection.idle) ||
            (event is ScrollUpdateNotification && event.dragDetails != null) ||
            (event is OverscrollNotification && event.dragDetails != null)) {
          _scrollIntent++;
          _settlingToEnd = false;
        }
        // Short pages cannot move their scroll offset. An overscroll is
        // still a deliberate request to reach history beyond the edge.
        if (event is OverscrollNotification &&
            event.dragDetails != null &&
            !_settlingToEnd &&
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
      },
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
                        child: _items.isEmpty && !_showTyping
                            // A brand-new conversation (no thread yet) gets a richer
                            // guidance view with tappable starter prompts; an empty
                            // resumed thread keeps the plain hint.
                            ? (_threadId == null
                                  ? (_caps.hostAccess
                                        ? _agentWelcome(l10n)
                                        : _newSessionGuidance(l10n))
                                  : Center(
                                      child: Text(
                                        l10n.emptyConversation,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.outline,
                                            ),
                                      ),
                                    ))
                            // One SelectionArea over the whole conversation so text can be
                            // drag-selected and copied on desktop. Mobile messages open
                            // their own long-press actions and text-selection page. The
                            // list is centered with a max width so it reads well even when
                            // both side panes are collapsed on a wide screen.
                            : Stack(
                                children: [
                                  // Full-width scroll area so the scrollbar sits at
                                  // the window's right edge instead of floating at
                                  // the centred column's edge; the conversation
                                  // column itself stays centred via horizontal
                                  // padding computed from the available width.
                                  SelectionArea(
                                    child: LayoutBuilder(
                                      builder: (context, constraints) {
                                        // The same gutter the turn rail sits
                                        // in, so the two never disagree about
                                        // where the column ends.
                                        final side = _gutterWidth(
                                          constraints.maxWidth,
                                        );
                                        final pad = side < 16 ? 16.0 : side;
                                        // Reuse the memoized row topology across
                                        // builders and scroll notifications.
                                        final rows = _rows;
                                        final indices = <Key, int>{
                                          const ValueKey('history-header'): 0,
                                          for (var i = 0; i < rows.length; i++)
                                            _anchorKey(rows[i]): i + 1,
                                        };
                                        // SuperListView (super_sliver_list) replaces
                                        // ListView.builder to stabilize the scrollbar:
                                        // it derives scroll extent from per-item
                                        // estimates reconciled against real heights as
                                        // rows pass through the cache area, instead of
                                        // the single running-average estimate that
                                        // makes a plain ListView's thumb jump with the
                                        // wide row-height variance here. Same lazy
                                        // virtualization, same ScrollController — only
                                        // visible rows build, so streaming stays cheap.
                                        return SuperListView.builder(
                                          physics:
                                              const AlwaysScrollableScrollPhysics(),
                                          controller: _scroll,
                                          listController: _listCtl,
                                          findChildIndexCallback: (key) =>
                                              indices[key],
                                          delayPopulatingCacheArea: true,
                                          padding: EdgeInsets.fromLTRB(
                                            pad,
                                            12,
                                            pad,
                                            12,
                                          ),
                                          // A leading row when history
                                          // continues above, so a long
                                          // conversation says so instead of
                                          // looking like it starts there.
                                          itemCount:
                                              rows.length +
                                              1 +
                                              (_showTyping ? 1 : 0),
                                          itemBuilder: (c, i) {
                                            if (i == 0) {
                                              return _olderHistoryHeader(l10n);
                                            }
                                            i -= 1;
                                            if (i >= rows.length) {
                                              return TypingIndicator(
                                                key: _externalWriterRunning
                                                    ? const Key(
                                                        'chat-external-output-indicator',
                                                      )
                                                    : null,
                                                elapsed: _fmtElapsed(
                                                  _elapsedSecs,
                                                ),
                                              );
                                            }
                                            final row = rows[i];
                                            return KeyedSubtree(
                                              key: _anchorKey(row),
                                              child: _transcriptRow(row),
                                            );
                                          },
                                        );
                                      },
                                    ),
                                  ),
                                  // Turn navigation. On a window wide enough
                                  // to leave a gutter this is the tick rail
                                  // beside the conversation — hover a turn to
                                  // preview it, click to jump. Narrower, and
                                  // on touch, it stays the bottom-right
                                  // cluster, which also carries jump-to-latest
                                  // in both cases.
                                  Positioned.fill(child: _turnNavOverlay()),
                                ],
                              ),
                      ),
              ),
            ),
            if (_navigatingTurn case final target?)
              Positioned(
                top: 8,
                left: 16,
                right: 16,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Material(
                    color: surfacePanel(Theme.of(context).colorScheme),
                    borderRadius: BorderRadius.circular(kControlRadius),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        key: const Key('history-navigation-status'),
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: _navigationLoading
                                ? Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 10,
                                    ),
                                    child: Text(
                                      l10n.loadingTurn(
                                        _turnMinimapItems(_rows).indexWhere(
                                              (item) =>
                                                  item.turnId == target.turnId,
                                            ) +
                                            1,
                                      ),
                                    ),
                                  )
                                : TextButton.icon(
                                    onPressed: () => _selectTurn(target),
                                    icon: const Icon(Icons.refresh, size: 16),
                                    label: Text(l10n.historyRetry),
                                  ),
                          ),
                          IconButton(
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).closeButtonTooltip,
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () {
                              _turnNavigation++;
                              _updateState(() {
                                _navigatingTurn = null;
                                _navigationLoading = false;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            if (runningPlan != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 8,
                child: _turnProgress(runningPlan, l10n),
              ),
          ],
        ),
      ),
    );
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
        if (_historySyncing || _showingCachedHistory)
          Padding(
            key: const Key('history-sync-status'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              _historySyncing ? l10n.historySyncing : l10n.historyCachedOffline,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        Expanded(
          // Pending requests come first, up to 45% of the screen and never
          // more than the room left after the composer and keyboard minus a
          // sliver of transcript; the transcript takes whatever remains.
          child: LayoutBuilder(
            builder: (context, room) {
              final groups = [
                _approvals.any((a) => a.kind != agentPermissionKind),
                _approvals.any((a) => a.kind == agentPermissionKind),
                _asyncQuestions.isNotEmpty,
              ].where((g) => g && !_externalWriterMode).length;
              final share = groups == 0
                  ? 0.0
                  : math.max(
                          0.0,
                          math.min(
                            MediaQuery.sizeOf(context).height * 0.45,
                            room.maxHeight - 48,
                          ),
                        ) /
                        groups;
              return Column(
                children: [
                  Expanded(child: transcript),
                  // Inline server requests: a `request_user_input`
                  // elicitation renders as an interactive question card (the
                  // model is asking the user, not requesting permission);
                  // everything else is a command/file/permission approval.
                  // Keyed by request id so State follows the right prompt if
                  // several are pending and one is answered out of order.
                  if (!_externalWriterMode &&
                      _approvals.any((a) => a.kind != agentPermissionKind))
                    ConstrainedBox(
                      key: const Key('server-request-list'),
                      constraints: BoxConstraints(maxHeight: share),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
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
                          ],
                        ),
                      ),
                    ),
                  // An ACP agent's requests carry their own options: render
                  // them as offered and answer with the chosen option id
                  // verbatim. An agent can ask several at once.
                  if (!_externalWriterMode &&
                      _approvals.any((a) => a.kind == agentPermissionKind))
                    ConstrainedBox(
                      key: const Key('agent-permission-list'),
                      constraints: BoxConstraints(maxHeight: share),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final a in _approvals)
                              if (a.kind == agentPermissionKind)
                                AgentPermissionCard(
                                  key: ValueKey(a.requestId),
                                  prompt: a,
                                  agentName: _caps.providerName,
                                  onAnswer: _answerAgentPermission,
                                ),
                          ],
                        ),
                      ),
                    ),
                  if (!_externalWriterMode && _asyncQuestions.isNotEmpty)
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: share),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final prompt in _asyncQuestions.values)
                              UserInputCard(
                                key: ValueKey('async-${prompt.id}'),
                                prompt: prompt.cardEvent,
                                onAnswer: (_, answers) =>
                                    _answerAsyncInput(prompt, answers),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
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
        if (_externalWriterMode)
          _externalWriterAction(l10n)
        else
          Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: _AppSessionState._kColumnWidth + 48,
              ),
              child: _composer(l10n),
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
