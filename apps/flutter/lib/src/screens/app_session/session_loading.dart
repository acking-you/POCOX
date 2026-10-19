part of '../app_session_screen.dart';

extension _SessionLoading on _AppSessionState {
  /// Load the conversations for the left sessions pane. As the home screen the
  /// pane lists EVERY conversation on the service (the user asked for "all
  /// sessions in the sidebar"); the classic pushed route keeps its
  /// project-scoped view (the project tree it was opened from already gives
  /// the full picture there).
  Future<void> _loadThreads() async {
    final key = widget.serviceKey;
    final epoch = _linkEpoch;
    try {
      final all = await ref.read(bridgeApiProvider).appThreadList(key);
      _adoptAutomaticFolder(key, epoch, all);
      // Every project this service has ever been used in, newest first. Taken
      // from the UNFILTERED list on purpose: the project switcher has to offer
      // the projects you're not in, which is exactly what `mine` drops below.
      _projects = ProjectIndex(all);
      final projects = <String>[];
      final seenProjects = <String>{};
      for (final t in all) {
        final p = _projects.of(t.cwd);
        if (p.isNotEmpty && seenProjects.add(p)) projects.add(p);
      }
      _allProjects = projects;
      final cwd = _cwd?.trim();
      var mine = (widget.home || cwd == null || cwd.isEmpty)
          ? all
          : all.where((t) => _projects.of(t.cwd) == _projects.of(cwd)).toList();
      // A session the host deleted stays out, even from a stale listing.
      if (_deletedThreads.isNotEmpty) {
        mine = [
          for (final t in mine)
            if (!_isDeleted(t.id)) t,
        ];
      }
      // Keep the freshly-started conversation visible even if `thread/list`
      // hasn't caught up with `thread/start` yet, so it doesn't flicker out of
      // the pane after the optimistic insert in [_send].
      final tid = _threadId;
      if (tid != null && !_isDeleted(tid) && !mine.any((t) => t.id == tid)) {
        ThreadMeta? local;
        for (final t in _threads) {
          if (t.id == tid) {
            local = t;
            break;
          }
        }
        mine = [
          local ??
              ThreadMeta(
                id: tid,
                preview: _lastSent?.text ?? '',
                cwd: cwd ?? '',
                updatedAt: 0,
              ),
          ...mine,
        ];
      }
      // Prefer a non-empty local/optimistic preview over an empty server one: a
      // freshly-started thread's server preview stays empty until its first turn
      // commits, and a blind replace would flip the tile to "(untitled)".
      final localPreview = {for (final t in _threads) t.id: t.preview};
      mine = [
        for (final t in mine)
          (t.preview.isEmpty && (localPreview[t.id]?.isNotEmpty ?? false))
              ? ThreadMeta(
                  id: t.id,
                  preview: localPreview[t.id]!,
                  name: t.name,
                  threadSource: t.threadSource,
                  parentThreadId: t.parentThreadId,
                  cwd: t.cwd,
                  originUrl: t.originUrl,
                  updatedAt: t.updatedAt,
                )
              : t,
      ];
      // A session opened ahead for an unsent draft is that draft's: it is
      // listed once the draft's first message adopts it.
      final ahead = _drafts.preparedIds;
      if (ahead.isNotEmpty) {
        mine = [
          for (final t in mine)
            if (!ahead.contains(t.id) || t.id == _threadId) t,
        ];
      }
      if (mounted) {
        _updateState(() {
          _threads = mine;
          _threadsListed = true;
        });
      }
      _openLoadDone(_kThreadsLoad);
      // Reaching here proves the service answers, which the subscribe-time
      // quota fetch can't assume on a cold open (it races the connection).
      // A brand-new conversation never reads a thread, so this is the only
      // retry it gets.
      if (_rate == null) _loadQuota();
    } catch (_) {
      // Listing is best-effort for the CONTENT — a failure leaves whatever the
      // pane already had. But a cold open racing the connection (or a host that
      // isn't up yet) must not strand the pane empty: nothing else re-lists
      // except a reconnect or a sent message, so retry a few times here.
      if (mounted) _retryOpenLoad(_kThreadsLoad);
    }
  }

  /// A conversation created in the host's automatic default folder takes
  /// its folder from [listed], the host's own answer (never guessed), so
  /// its project label and catalog follow it. Only for the conversation
  /// still shown, on the host and connection the list was read from, while
  /// it has no folder of its own.
  void _adoptAutomaticFolder(String key, int epoch, List<ThreadMeta> listed) {
    final created = _automaticThread;
    if (!mounted ||
        created == null ||
        key != widget.serviceKey ||
        epoch != _linkEpoch ||
        created.key != key ||
        created.thread != _threadId ||
        (_cwd?.trim().isNotEmpty ?? false)) {
      return;
    }
    final cwd = listed
        .where((t) => t.id == created.thread)
        .firstOrNull
        ?.cwd
        .trim();
    if (cwd == null || cwd.isEmpty) return; // not listed yet: a later list
    _updateState(() {
      _cwd = cwd;
      _automaticThread = null;
    });
  }

  /// Re-attempt a cold-open load that failed, with a widening backoff.
  ///
  /// Every load kicked off in `initState` races the connection: the screen
  /// mounts and fires immediately, while the socket may still be handshaking —
  /// and on desktop the host itself can be a CHILD PROCESS THIS APP IS STILL
  /// SPAWNING (auto-host restore takes ~30s, far longer than the first
  /// attempt). Those loads all `catch (_)` because none of them is worth an
  /// error banner, which meant one lost race stranded the surface for the whole
  /// session: an empty conversation list, or a new chat silently rooted in the
  /// wrong folder.
  ///
  /// [key] identifies the load, so each retries on its own schedule and a
  /// success stops only its own chain. Retries stop once the load succeeds
  /// (the loader clears the key) or the budget runs out; a later failure with
  /// data already in hand is left alone, since something is on screen and the
  /// reconnect path will refresh it.
  void _retryOpenLoad(String key) {
    final attempt = _openLoadRetries[key] ?? 0;
    if (attempt >= _kOpenLoadMaxRetries) {
      // Out of retries: the sessions pane stops waiting and shows what it
      // has (the reconnect path lists again).
      if (key == _kThreadsLoad && !_threadsListed) {
        _updateState(() => _threadsListed = true);
      }
      return;
    }
    _openLoadRetries[key] = attempt + 1;
    _openLoadTimers[key]?.cancel();
    _openLoadTimers[key] = Timer(Duration(seconds: 1 << attempt), () {
      // 1/2/4/8/16s
      if (!mounted || !_openLoadRetries.containsKey(key)) return;
      switch (key) {
        case _kThreadsLoad:
          _loadThreads();
        case _kCwdSeed:
          _seedDefaultCwd();
        case _kModelsLoad:
          unawaited(_ensureModels());
      }
    });
  }

  /// Mark a cold-open load as settled, so its retry chain stops.
  void _openLoadDone(String key) {
    _openLoadRetries.remove(key);
    _openLoadTimers.remove(key)?.cancel();
  }

  /// Switch the screen to another conversation (or a new one when [tid] is
  /// null) in place, resetting per-thread state. Used by the left sessions pane.
  /// Remember [settings]' automatic default for [key] (an empty path when
  /// the host has none), from read [read]: an older read's late answer never
  /// replaces a newer one.
  void _noteHostDefault(String key, ProjectSettings settings, int read) {
    if (!mounted || key != widget.serviceKey || read != _hostDefaultRead) {
      return;
    }
    final automatic =
        !settings.legacy &&
        settings.defaultProject == null &&
        settings.automatic;
    final path = automatic ? settings.effectiveDefault?.trim() ?? '' : '';
    _updateState(() => _hostDefault = (key: key, path: path));
  }

  void _openThread(String? tid, String? cwd) {
    _automaticThread = null;
    // Leaving the call's conversation ends the call: capture never outlives
    // the conversation it was started in (AGENTS.md, live voice controls).
    if (_voice.threadId != null && _voice.threadId != tid) {
      unawaited(_voice.stop());
    }
    unawaited(
      ref
          .read(bridgeApiProvider)
          .appHistoryFocus(widget.serviceKey, tid)
          .catchError((_) {}),
    );
    // Keep the "last conversation" record fresh for the chat-first home. A
    // new (id-less) conversation records nothing until its first send — an
    // abandoned draft shouldn't cost the user their restore target.
    if (tid != null) {
      ref.read(uiPrefsProvider.notifier).setLastThread(widget.serviceKey, tid);
    }
    _cancelExternalWriterSubscription();
    // A take belongs to the draft it was started in. Leaving that draft ends
    // the take; what it heard stays there (the span is tied to that draft,
    // so no later words land in the new one).
    if (_dictation.taking) unawaited(_dictation.finishTake());
    _dictationSpan = null;
    _dictationReplaces = null;
    _dictationReplaced = '';
    _threadLoadGeneration++;
    _historyLiveItems = null;
    _historyPartialItems = null;
    _updateState(() {
      _threadId = tid;
      _historySyncing = false;
      _showingCachedHistory = false;
      _historyEpoch = null;
      _cwd = cwd;
      _externalWriterMode = false;
      _guardianReadOnly = false;
      _parentThreadId = null;
      _externalWriterLiveness = null;
      _access = null;
      _takingOver = false;
      // An open rename belongs to the thread being left, so drop it rather
      // than let it commit the old title onto the new conversation.
      _editingTitle = false;
      _items.clear();
      _itemIndex.clear();
      _rowAnchors.clear();
      _list.reset();
      // A conversation opens at its end.
      _scroll.stickToEnd = true;
      // The previous thread's turns and pagination say nothing about this one.
      _turnSummaries = const [];
      _hasOlder = false;
      _historyError = false;
      _fetchedTurns.clear();
      _turnWindows.clear();
      _sequentialHistoryIds.clear();
      _firstTurnId = null;
      _cachedRows = null;
      _navigatingTurn = null;
      _navigationLoading = false;
      _historyLoad = null;
      _historyGeneration++;
      _historyArrivalRow = null;
      _approvals.clear();
      _asyncQuestions.clear();
      _ctx = null;
      _diff = null;
      _branch = null;
      _reviewOpen = false;
      _reviewTarget = null;
      _streaming = false;
      // Drop the previous thread's turn id; the engine tracks the active turn
      // per thread, so interrupt still works for a thread that's already
      // running when we open it (a stale id here would target the wrong turn).
      _turnId = null;
      _pendingInterrupt = false;
      // Show the loading skeleton while the opened thread's history loads (no-op
      // for a brand-new conversation, which has nothing to fetch).
      _loading = tid != null;
      _restoringSettings = false;
      _error = null;
      _retry = null;
      _planActive = false;
      // Reset the per-thread settings to neutral defaults too: an existing
      // thread restores model / permission / plan / effort from its persisted
      // config (+ server) in _resumeAndLoad, and a new one re-seeds below.
      // Without this, switching to a thread with no (or unreachable) persisted
      // config would inherit — and then re-persist — the previous thread's
      // model + permission mode (which the server never restores).
      _model = null;
      _modelPickPending = false;
      _mode = PermissionMode.autoReview;
      _serviceTier = null;
      _serviceTierPickPending = false;
      _modePickPending = false;
      _supplement = false;
      _sendRequest = null;
      _supplementRequest = null;
      _localSendOwner = null;
      _turnStartSeen();
      _endedTurns.clear();
      _plan = false;
      _planToggledByUser = false;
      // Drop the previous thread's effort (pending pick + active) so an unsent
      // pick on the old thread can't leak into this one; _resumeAndLoad re-seeds
      // _effortActive from the server / per-thread memory.
      _effort = null;
      _effortActive = null;
      // The runtime config and turn stamps describe the previous thread.
      _runtime = null;
      // So do the agent's options: offering (and validating a change
      // against) the previous session's catalog would apply its values to
      // this one. Reopening the session reads its own.
      _agentSettings = null;
      _runtimeAt = null;
      _turnStampModel = null;
      _turnStampEffort = null;
      _turnStampConfirmed = false;
      _turnRerouted = false;
      _sentModel = null;
      _sentEffort = null;
      _implementDismissed = false;
      _draft = _drafts.forThread(tid, cwd: cwd);
      _input.value = _draft.value.copyWith(composing: TextRange.empty);
      // Undo and retry snapshots belong to the previous conversation.
      _outputStarted = false;
      _undoableDraft = null;
      _suppressStopMarker = false;
      _lastSent = null;
      // A brand-new conversation inherits the user's last-chosen settings; an
      // existing one is restored from the server by _resumeAndLoad below.
      if (tid == null) _seedDefaults();
    });
    if (tid != null) {
      _resumeAndLoad();
    } else if (_caps.sessionConfig) {
      // A draft shown again keeps the session opened ahead for it.
      _refreshAgentSettings();
    }
    // Every new conversation reads the host's current default (it may have
    // changed since this screen opened): a chosen one seeds the folder, an
    // automatic one is shown.
    if (tid == null && (cwd?.trim().isEmpty ?? true)) {
      unawaited(_seedDefaultCwd());
    }
  }

  /// Leave a pushed conversation for the list it came from — the session
  /// browser, now the only route that pushes this screen. Falls back to the
  /// chat home when there is nothing beneath (a deep link), since the
  /// `/app/:key` project picker this used to target is gone: its project tree
  /// is the home sidebar's.
  void _backToSessions() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  /// Seed a brand-new conversation's working folder from the host's configured
  /// default project. Best-effort + guarded: only sets `_cwd` while it is still
  /// empty and the thread is still new, so it never overrides a folder the user
  /// picked or a resumed thread's cwd.
  ///
  /// A host's automatic default is only noted for display
  /// ([_automaticProject]): the send then passes no folder, and the host
  /// creates that folder when the conversation is created, not before.
  Future<void> _seedDefaultCwd() async {
    final generation = _threadLoadGeneration;
    final selectionGeneration = _projectSelectionGeneration;
    final draft = _draft;
    final key = widget.serviceKey;
    final read = ++_hostDefaultRead;
    try {
      final settings = await ref
          .read(bridgeApiProvider)
          .metaProjectSettings(key);
      // Answered, so there is nothing left to retry — whether or not a default
      // is configured. Settling here (not only on the happy path) stops a host
      // that legitimately has no default from being asked five times.
      _openLoadDone(_kCwdSeed);
      _noteHostDefault(key, settings, read);
      final def = settings.defaultProject?.trim();
      if (!mounted || def == null || def.isEmpty) return;
      if (generation == _threadLoadGeneration &&
          selectionGeneration == _projectSelectionGeneration &&
          identical(draft, _draft) &&
          !draft.sendPending &&
          _threadId == null &&
          (_cwd == null || _cwd!.trim().isEmpty)) {
        final resolved = _drafts.resolveProject(draft, def);
        if (resolved == null) return;
        _updateState(() {
          _cwd = def;
          if (!identical(_draft, resolved)) {
            _draft = resolved;
            _input.value = resolved.value.copyWith(composing: TextRange.empty);
          }
        });
      }
    } catch (_) {
      // No reachable meta → keep the codex default for now, but retry: this
      // runs at mount, so on a cold open it can lose the race against the
      // connection. Failing silently and permanently would leave a NEW
      // conversation rooted in the wrong folder — the agent would then read and
      // edit files somewhere the user never chose, which is worse than a slow
      // seed. The guard above keeps a folder the user picked meanwhile.
      if (mounted &&
          selectionGeneration == _projectSelectionGeneration &&
          generation == _threadLoadGeneration) {
        _retryOpenLoad(_kCwdSeed);
      }
    }
  }

  Future<void> _pickProject() async {
    final generation = _threadLoadGeneration;
    final l10n = AppLocalizations.of(context);
    // Does the host offer a project-folder tree to browse? Best-effort — a
    // failure just means the manual path field (the fallback that always works,
    // e.g. self-host with no roots configured).
    var hasRoots = false;
    try {
      final cfg = await ref
          .read(bridgeApiProvider)
          .metaProjectConfig(widget.serviceKey);
      hasRoots = cfg.hasRoots;
    } catch (_) {
      // No reachable meta / no config → manual entry only.
    }
    if (!mounted) return;
    final ctrl = TextEditingController(text: _cwd ?? '');
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(l10n.newProject),
        content: StatefulBuilder(
          builder: (c, setInner) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Visual tree browse — the primary way on a phone. Confined to
              // the host's configured project roots.
              if (hasRoots) ...[
                FilledButton.tonalIcon(
                  key: const Key('browse-project-btn'),
                  onPressed: () async {
                    final picked = await showFolderPicker(
                      c,
                      serviceKey: widget.serviceKey,
                      initialPath: ctrl.text.trim().isEmpty
                          ? null
                          : ctrl.text.trim(),
                    );
                    if (picked != null) setInner(() => ctrl.text = picked);
                  },
                  icon: const Icon(AppIcons.folder_open, size: 18),
                  label: Text(l10n.browseProjectFolder),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.orEnterPathManually,
                  style: Theme.of(c).textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
              ],
              TextField(
                controller: ctrl,
                autofocus: !hasRoots,
                decoration: InputDecoration(
                  labelText: l10n.remotePathLabel,
                  hintText: l10n.remotePathHint,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    if (mounted && generation == _threadLoadGeneration && ok == true) {
      _selectProject(ctrl.text.trim());
    }
  }
}
