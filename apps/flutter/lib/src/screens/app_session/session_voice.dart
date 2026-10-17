part of '../app_session_screen.dart';

extension _SessionVoice on _AppSessionState {
  void _onDictationChanged() {
    final d = _dictation;
    if (d.take != _dictationTake && mounted) {
      _updateState(() => _dictationTake = d.take);
    }
    final failure = d.failure;
    if (failure != null && mounted) {
      d.failure = null;
      final l10n = AppLocalizations.of(context);
      showToastError(context, switch (failure) {
        DictationFailure.permission => l10n.dictationPermission,
        DictationFailure.interrupted => l10n.dictationInterrupted,
        DictationFailure.unavailable =>
          d.error == null
              ? l10n.dictationUnavailable
              : '${l10n.dictationUnavailable}: ${d.error}',
      });
    }
  }

  /// Start a take where the cursor is.
  void _startDictation() {
    if (!_caps.dictation) return;
    if (_voice.busy) {
      showToastError(context, AppLocalizations.of(context).dictationVoiceBusy);
      return;
    }
    if (_dictation.taking) return;
    final value = _input.value;
    final sel = value.selection;
    final start = sel.isValid ? sel.start : value.text.length;
    final end = sel.isValid ? sel.end : value.text.length;
    // A selection is replaced by what is said, as typing would — but only
    // once something is said: a take that never starts (no microphone, no
    // line) must leave the draft exactly as it was.
    _dictationSpan = (draft: _draft, start: start, end: start);
    _dictationReplaces = start == end ? null : (start: start, end: end);
    _inputFocus.requestFocus();
    unawaited(_dictation.startTake());
  }

  /// Words arriving for the current take go in at the end of its span.
  void _onDictationDelta(int take, String delta) {
    final span = _dictationSpan;
    if (!mounted ||
        span == null ||
        take != _dictation.takeId ||
        !identical(span.draft, _draft)) {
      return;
    }
    var value = _input.value;
    // The first words replace the selection the take was started on; what
    // they replaced is kept so a discard can put it back.
    final replaces = _dictationReplaces;
    if (replaces != null && delta.trim().isNotEmpty) {
      _dictationReplaces = null;
      final start = replaces.start.clamp(0, value.text.length);
      final end = replaces.end.clamp(start, value.text.length);
      _dictationReplaced = value.text.substring(start, end);
      value = TextEditingValue(
        text: value.text.replaceRange(start, end, ''),
        selection: TextSelection.collapsed(offset: start),
      );
    }
    final text = value.text;
    // The user may have edited the draft meanwhile; keep the span inside it.
    final at = span.end.clamp(0, text.length);
    final before = text.substring(0, at);
    var piece = delta;
    if (at == span.start) {
      // First words of the take: no leading space at the start of a line,
      // one between two Latin words, none before CJK.
      piece = piece.trimLeft();
      final latinBefore = RegExp(r'[A-Za-z0-9.,!?;:)\]]$').hasMatch(before);
      final latinStart = RegExp(r'^[A-Za-z0-9(\[]').hasMatch(piece);
      if (latinBefore && latinStart) piece = ' $piece';
    }
    if (piece.isEmpty) return;
    final caretInSpan =
        !value.selection.isValid ||
        (value.selection.isCollapsed &&
            value.selection.baseOffset >= span.start &&
            value.selection.baseOffset <= at);
    _input.value = TextEditingValue(
      text: text.replaceRange(at, at, piece),
      selection: caretInSpan
          ? TextSelection.collapsed(offset: at + piece.length)
          : value.selection,
    );
    _dictationSpan = (
      draft: span.draft,
      start: span.start,
      end: at + piece.length,
    );
  }

  void _onDictationEnded(int take, {required bool cancelled}) {
    final span = _dictationSpan;
    final replaced = _dictationReplaced;
    _dictationSpan = null;
    _dictationReplaces = null;
    _dictationReplaced = '';
    if (!mounted || span == null || !cancelled) return;
    if (!identical(span.draft, _draft)) return;
    // Discard: take out exactly what this take put in, and put back the
    // selection it replaced. A take that heard nothing changed nothing.
    final text = _input.text;
    final start = span.start.clamp(0, text.length);
    final end = span.end.clamp(start, text.length);
    if (end > start || replaced.isNotEmpty) {
      _input.value = TextEditingValue(
        text: text.replaceRange(start, end, replaced),
        selection: replaced.isEmpty
            ? TextSelection.collapsed(offset: start)
            : TextSelection(
                baseOffset: start,
                extentOffset: start + replaced.length,
              ),
      );
    }
  }

  void _onVoiceForDictation() {
    final busy = _voice.busy;
    if (busy == _voiceWasBusy) return;
    _voiceWasBusy = busy;
    if (busy) {
      // A take in progress keeps what it heard; the line closes so the
      // call has the microphone and the realtime quota to itself.
      unawaited(_dictation.close());
    } else {
      _warmDictation();
    }
  }

  void _finishDictation() => unawaited(_dictation.finishTake());

  void _cancelDictation() => unawaited(_dictation.cancelTake());

  /// Open the line ahead of use, while the composer is in front and no call
  /// holds the microphone. Opening only negotiates the session; the
  /// microphone stays closed until a take.
  void _warmDictation() {
    if (!mounted ||
        !_foreground ||
        _voice.busy ||
        !_voiceAvailable ||
        !_caps.dictation) {
      return;
    }
    unawaited(_dictation.warm());
  }

  bool get _isVoiceThread =>
      _threads.any((t) => t.id == _threadId && t.isVoice);
  // Native realtime voice and dictation exist only where the connection says
  // so (Codex app-server); ACP audio prompts are not live voice.
  bool get _voiceAvailable =>
      _caps.voice &&
      !_externalWriterMode &&
      !_loading &&
      !_historySyncing &&
      !_showingCachedHistory &&
      !_connectionLost;
  bool get _canStartVoice =>
      _voiceAvailable &&
      !_voiceStarting &&
      !_voice.busy &&
      _voice.phase != VoicePhase.stopping;

  Future<void> _startVoice() async {
    if (!_canStartVoice) return;
    final generation = _threadLoadGeneration;
    final intent = ++_voiceIntentGeneration;
    bool current() =>
        mounted &&
        intent == _voiceIntentGeneration &&
        generation == _threadLoadGeneration &&
        _voiceAvailable;
    _updateState(() => _voiceStarting = true);
    try {
      final api = ref.read(bridgeApiProvider);
      final settings = await showAppDialog<VoiceSettings>(
        context: context,
        builder: (_) =>
            VoiceSetupDialog(api: api, serviceKey: widget.serviceKey),
      );
      if (!current() || settings == null) return;
      var id = _isVoiceThread ? _threadId : null;
      if (id == null) {
        final result = await _voice.request('thread/start', {
          'threadSource': 'pocket-codex-voice',
          if (_cwd != null) 'cwd': _cwd,
          if (_model != null) 'model': _model!.id,
          'approvalPolicy': _mode.approval,
          'approvalsReviewer': _mode.reviewer,
          'sandbox': _mode.sandbox,
        });
        final thread = result['thread'] as Map;
        final newId = thread['id'] as String;
        id = newId;
        if (!current()) return;
        final cwd = thread['cwd'] as String? ?? _cwd;
        // Adopt the new thread in place, the way a first text send does. It
        // has no rollout until the first user turn lands, so the app-server
        // rejects `thread/resume` and `thread/read` for it ("no rollout found
        // for thread id …"); going through `_openThread` would fire exactly
        // those and surface the refusal as an error banner.
        _drafts.adoptThread(_draft, newId);
        ref
            .read(uiPrefsProvider.notifier)
            .setLastThread(widget.serviceKey, newId);
        unawaited(
          api.appHistoryFocus(widget.serviceKey, newId).catchError((_) {}),
        );
        _updateState(() {
          _threads = [
            ThreadMeta(
              id: newId,
              preview: '',
              cwd: cwd ?? '',
              updatedAt: 0,
              threadSource: 'pocket-codex-voice',
            ),
            ..._threads,
          ];
          _threadId = newId;
          _cwd = cwd;
        });
        _persistThreadConfig();
      }
      await _voice.start(id, model: settings.model, voice: settings.voice);
      if (mounted) unawaited(_loadThreads());
    } catch (e) {
      if (mounted) {
        showToastError(
          context,
          '${AppLocalizations.of(context).voiceUnavailable}: $e',
        );
      }
    } finally {
      if (mounted) _updateState(() => _voiceStarting = false);
    }
  }

  void _voiceHistory() {
    final id = _threadId;
    if (id == null) return;
    showAppDialog<void>(
      context: context,
      builder: (_) => VoiceHistoryDialog(
        api: ref.read(bridgeApiProvider),
        serviceKey: widget.serviceKey,
        threadId: id,
      ),
    );
  }

  /// The live call's pinned status entry (sidebar, or the window strip when
  /// the sidebar is collapsed). Names the conversation the call belongs to
  /// and, when that is not the one on screen, taps through to it.
  Widget _voiceStatus(AppLocalizations l10n, {bool compact = false}) {
    final id = _voice.threadId;
    final thread = id == null
        ? null
        : _threads.where((t) => t.id == id).firstOrNull ??
              _discoveredThreads[id];
    final title = thread == null
        ? null
        : (thread.title?.trim().isNotEmpty ?? false)
        ? thread.title!.trim()
        : thread.preview.trim().isNotEmpty
        ? thread.preview.trim().split('\n').first
        : l10n.voiceLive;
    return VoiceStatusEntry(
      controller: _voice,
      compact: compact,
      title: title,
      onOpen: id == null || id == _threadId
          ? null
          : () => _openThread(id, thread?.cwd ?? _cwd),
    );
  }

  Widget _voiceBar(AppLocalizations l10n) => AnimatedBuilder(
    animation: _voice,
    builder: (context, _) => _voice.threadId == _threadId
        ? VoicePanel(
            controller: _voice,
            onHistory: _voiceHistory,
            onRetry: _canStartVoice ? _startVoice : null,
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Icon(AppIcons.graphic_eq),
                const SizedBox(width: 8),
                Expanded(child: Text(l10n.voiceLive)),
                IconButton(
                  tooltip: l10n.voiceHistory,
                  onPressed: _voiceHistory,
                  icon: const Icon(AppIcons.history),
                ),
                IconButton(
                  tooltip: l10n.voiceStart,
                  onPressed: _canStartVoice ? _startVoice : null,
                  icon: const Icon(AppIcons.play_arrow),
                ),
              ],
            ),
          ),
  );
}
