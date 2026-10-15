part of '../app_session_screen.dart';

extension _SessionCapabilities on _AppSessionState {
  Set<String> get _answeredAsyncQuestions =>
      ref.read(answeredAsyncQuestionsProvider(widget.serviceKey));

  void _markAsyncQuestionAnswered(String threadId, String itemId) {
    ref.read(answeredAsyncQuestionsProvider(widget.serviceKey).notifier).state =
        {..._answeredAsyncQuestions, '$threadId:$itemId'};
  }

  AppCapabilities get _caps {
    final cached = _capsCache;
    if (_capsKey != widget.serviceKey ||
        cached == null ||
        (cached.hostAccess && !cached.negotiated)) {
      _capsKey = widget.serviceKey;
      _capsCache = ref
          .read(bridgeApiProvider)
          .appCapabilities(widget.serviceKey);
    }
    return _capsCache!;
  }

  /// Drop cached capabilities (host generation / phase changed, reconnect)
  /// and stop native microphone features the new connection does not have.
  void _invalidateCaps() {
    _capsEpoch++;
    final imageInputBefore = _capsCache?.imageInput;
    _capsCache = null;
    final caps = _caps;
    // An image granted before may not reach a host that no longer takes
    // images. (One refused before never becomes admissible by itself: an
    // admission never exceeds its grant.)
    if (imageInputBefore == true && !caps.imageInput) {
      _drafts.revokeAdmissions();
    }
    if (!caps.dictation) unawaited(_dictation.close());
    if (!caps.voice && _voice.busy) unawaited(_voice.stop());
  }

  /// The session an agent option change would apply to right now, or null
  /// when there is none. A change is bound to the target current when its
  /// menu opened and refused if any part moved (conversation, its load,
  /// capabilities/host generation, event connection).
  _AgentTarget? _agentTarget() {
    // The open conversation, the session opened ahead for its draft, or the
    // draft itself when it keeps its own options.
    final tid =
        _agentSessionThread ??
        (_editsDraftOptions ? _draftTargetId(_draft) : null);
    if (tid == null) return null;
    return (
      service: widget.serviceKey,
      thread: tid,
      load: _threadLoadGeneration,
      caps: _capsEpoch,
      link: _subscriptionEpoch,
    );
  }

  /// Whether the agent's per-session options can be changed now: a live,
  /// editable, idle conversation.
  bool get _agentControlsEnabled =>
      _caps.sessionConfig &&
      !_sending &&
      _draft.preparing == null &&
      !_streaming &&
      !(_agentSettings?.running ?? false) &&
      !_externalWriterMode &&
      !_guardianReadOnly &&
      !_reconnecting &&
      !_historySyncing &&
      !_showingCachedHistory &&
      !_connectionLost &&
      !_savingAgentConfig;

  /// Whether a change bound to [target] may still be sent.
  bool _agentTargetCurrent(_AgentTarget? target) =>
      mounted &&
      target != null &&
      target == _agentTarget() &&
      _agentControlsEnabled;

  void _refreshAgentSettings() {
    if (_readsNativeSettings) {
      _readNativeSettings();
      return;
    }
    final tid = _agentSessionThread;
    final next = !_caps.sessionConfig || tid == null || _isDeleted(tid)
        ? null
        : ref
              .read(bridgeApiProvider)
              .appSessionSettings(widget.serviceKey, tid);
    if (mounted) _updateState(() => _agentSettings = next);
  }

  Future<void> _decide(AppEvent prompt, String decision) async {
    _updateState(() => _approvals.remove(prompt));
    try {
      await ref
          .read(bridgeApiProvider)
          .appRespondApproval(widget.serviceKey, prompt.requestId!, decision);
    } catch (e) {
      // The host may have dropped between the prompt and the answer; swallow so a
      // dead connection can't surface an uncaught async error.
      debugPrint('appRespondApproval failed: $e');
    }
  }

  /// Answer an ACP permission with one of the options the agent offered. The
  /// card stays until the host accepts the answer: a failed send keeps it so
  /// the user can retry, and a request resolved elsewhere arrives as
  /// `serverRequest/resolved` and drops it.
  Future<void> _answerAgentPermission(AppEvent prompt, String optionId) async {
    try {
      await ref
          .read(bridgeApiProvider)
          .appRespondApproval(widget.serviceKey, prompt.requestId!, optionId);
      if (mounted) _updateState(() => _approvals.remove(prompt));
    } catch (e) {
      if (!mounted) return;
      final message = friendlyError(e);
      // Already answered / withdrawn on the host: the card is obsolete.
      if (message.contains('already resolved') ||
          message.contains('unknown permission')) {
        _updateState(() => _approvals.remove(prompt));
        return;
      }
      showToastError(
        context,
        AppLocalizations.of(context).permissionAnswerFailed,
      );
    }
  }

  /// Set the agent's option [configId] to [value] for [target]. Refused —
  /// nothing is sent — when [target] is no longer the open, editable
  /// conversation or the value is no longer advertised.
  Future<void> _setAgentConfig(
    _AgentTarget? target,
    String configId,
    String value,
  ) async {
    // A draft's own choice is kept, not sent (see [_applyDraftOptions]).
    if (target != null && target.thread.startsWith('#draft:')) {
      _setDraftOption(target, configId, value);
      return;
    }
    if (!_agentTargetCurrent(target)) return;
    final offered = _agentSettings?.configOptions
        .where((o) => o.id == configId)
        .firstOrNull;
    if (offered == null || !offered.values.any((v) => v.value == value)) {
      return;
    }
    // Until the host answers, a send would still run with the old value:
    // every send and this conversation's options wait (see
    // [_savingAgentConfig]). Only this save releases its own hold.
    final saving = target!;
    final hold = (target: saving, save: Object());
    _updateState(() => _configSaving = hold);
    try {
      await ref
          .read(bridgeApiProvider)
          .appSetSessionConfig(saving.service, saving.thread, configId, value);
    } catch (e) {
      // The agent kept its previous value; its option set is unchanged. A
      // failure for a conversation the user already left is not shown here.
      if (mounted && _agentTarget() == saving) {
        final reason = friendlyError(e);
        final l10n = AppLocalizations.of(context);
        _updateState(
          () => _error = offered.category == 'model'
              ? l10n.modelChangeFailed(reason)
              : reason,
        );
      }
    } finally {
      if (mounted && identical(_configSaving?.save, hold.save)) {
        _updateState(() => _configSaving = null);
      }
    }
    if (mounted && _agentTarget() == saving) _refreshAgentSettings();
  }

  /// A model or other option change of the shown conversation is still
  /// being saved (see [_setAgentConfig]).
  bool get _savingAgentConfig =>
      _configSaving != null && _configSaving!.target == _agentTarget();

  /// Switch the agent's legacy mode for [target]; refused like
  /// [_setAgentConfig].
  Future<void> _setAgentMode(_AgentTarget? target, String modeId) async {
    // Legacy modes exist only on a session, never on a draft.
    if (target?.thread.startsWith('#draft:') ?? false) return;
    if (!_agentTargetCurrent(target)) return;
    final settings = _agentSettings;
    if (settings == null ||
        !showsLegacyModes(settings) ||
        !settings.modes.any((m) => m.id == modeId)) {
      return;
    }
    try {
      await ref
          .read(bridgeApiProvider)
          .appSetSessionMode(target!.service, target.thread, modeId);
    } catch (e) {
      if (mounted && _agentTarget() == target) {
        _updateState(() => _error = friendlyError(e));
      }
    }
    if (mounted && _agentTarget() == target) _refreshAgentSettings();
  }

  /// Answer a `request_user_input` elicitation. `answers` maps each question id
  /// to the chosen answer string(s); an empty map cancels (the turn proceeds
  /// without an answer). Sends the codex `ToolRequestUserInputResponse` shape.
  Future<void> _answerUserInput(
    AppEvent prompt,
    Map<String, List<String>> answers,
  ) async {
    _updateState(() => _approvals.remove(prompt));
    try {
      await ref
          .read(bridgeApiProvider)
          .appRespondUserInput(
            widget.serviceKey,
            prompt.requestId!,
            jsonEncode(answers),
          );
    } catch (e) {
      // A dropped host between the elicitation and the answer must not surface an
      // uncaught async error.
      debugPrint('appRespondUserInput failed: $e');
    }
  }

  Future<void> _answerAsyncInput(
    AsyncQuestionPrompt prompt,
    Map<String, List<String>> answers,
  ) async {
    final threadId = _threadId;
    if (threadId == null || _sending || _reconnecting) return;
    if (answers.isEmpty) {
      _updateState(() {
        _asyncQuestions.remove(prompt.id);
        _markAsyncQuestionAnswered(threadId, prompt.id);
      });
      return;
    }
    final text = prompt.answerText(answers);
    final hold = Object();
    _updateState(() => _holdSend(hold));
    try {
      final api = ref.read(bridgeApiProvider);
      if (_streaming) {
        final turnId = _turnId;
        await api.appTurnSteer(widget.serviceKey, threadId, turnId, text);
      } else {
        await api.appTurnStart(widget.serviceKey, threadId, text);
      }
      if (!mounted || _threadId != threadId) return;
      _updateState(() {
        _asyncQuestions.remove(prompt.id);
        _markAsyncQuestionAnswered(threadId, prompt.id);
        _error = null;
      });
    } catch (e) {
      if (mounted && _threadId == threadId) {
        _updateState(() => _error = friendlyError(e));
      }
    } finally {
      if (mounted) _updateState(() => _releaseSend(hold));
    }
  }
}
