part of '../app_session_screen.dart';

/// Session options of an unsent draft, for an engine whose options exist
/// before its session ([AppCapabilities.draftOptions], native OpenCode).
///
/// The service's defaults for a new session are read with an empty thread
/// id; the draft keeps its own choices over them ([_ComposerDraft.options]).
/// Nothing is sent for a choice until the draft's first send creates its
/// session: the choices are applied to that session, then the message is
/// sent. A host-wide default is never changed from here.
extension _SessionDraftOptions on _AppSessionState {
  /// Whether the shown view edits a draft's own options.
  bool get _editsDraftOptions =>
      _threadId == null && _caps.draftOptions && _caps.sessionConfig;

  /// The target of a draft's option menu: bound to that draft object, so a
  /// menu answered after the view moved to another draft changes nothing.
  String _draftTargetId(_ComposerDraft draft) =>
      '#draft:${identityHashCode(draft)}';

  /// After this frame, read the shown draft's options when what they depend
  /// on (the draft, the capabilities and their host generation) changed
  /// since they were last read. Such a draft opens no session ahead, so
  /// nothing else reads them when the view first shows it or when the
  /// capabilities are negotiated. Only reads: nothing is sent.
  void _scheduleDraftOptionsCheck() {
    if (!_editsDraftOptions) return;
    final caps = _caps;
    final key = (_draft, _capsEpoch, caps.negotiated, caps.generation);
    if (key == _draftOptionsKey) return;
    _draftOptionsKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _draftOptionsKey == key && _editsDraftOptions) {
        _refreshAgentSettings();
      }
    });
  }

  /// The service defaults with the shown draft's choices over them.
  SessionSettings? _draftSettings() {
    final base = _draftBase();
    if (base == null) return null;
    return draftSessionSettings(
      base,
      _draft.options,
      defaultName: AppLocalizations.of(context).draftOptionDefault,
    );
  }

  SessionSettings? _draftBase() =>
      ref.read(bridgeApiProvider).appSessionSettings(widget.serviceKey, '');

  /// Record [value] for option [configId] in the draft [target] names. What
  /// the draft shows is what its first send applies: choosing the value an
  /// option shows without a choice records none, and a model choice drops
  /// the variant choice (see [draftChoiceAfter]).
  void _setDraftOption(_AgentTarget? target, String configId, String value) {
    final draft = _draft;
    if (target == null ||
        target.thread != _draftTargetId(draft) ||
        !_editsDraftOptions ||
        !_agentControlsEnabled) {
      return;
    }
    final shown = _agentSettings?.configOptions
        .where((o) => o.id == configId)
        .firstOrNull;
    final base = _draftBase();
    if (base == null ||
        shown == null ||
        !shown.values.any((v) => v.value == value)) {
      return;
    }
    final next = draftChoiceAfter(base, draft.options, configId, value);
    _updateState(() {
      draft.options
        ..clear()
        ..addAll(next);
    });
    _drafts.save(draft, changed: true);
    _refreshAgentSettings();
  }

  /// Apply [draft]'s choices to [thread], the session its first send just
  /// created, before that message is sent. The model goes first: it decides
  /// the variants. A refusal stops the send before its message is put on
  /// the wire ([_DraftOptionsRefused]); the session exists and the message
  /// goes back to its draft.
  ///
  /// However it ends, the draft keeps no pending choices: from now on the
  /// view shows the session's own options, so anything not applied would
  /// otherwise be applied later without being shown.
  Future<void> _applyDraftOptions(
    _ComposerDraft draft,
    String service,
    String thread,
    bool Function() sameLink,
  ) async {
    if (draft.options.isEmpty) return;
    final base = ref.read(bridgeApiProvider).appSessionSettings(service, '');
    final categories = {
      for (final option in base?.configOptions ?? const <SessionConfigOption>[])
        option.id: option.category,
    };
    int rank(String id) => switch (categories[id]) {
      'model' => 0,
      'thought_level' => 1,
      _ => 2,
    };
    // Only what the draft shows is applied: a choice the current catalog no
    // longer offers (the host was replaced with another configuration) is
    // shown as the default, so it is dropped rather than applied.
    final shown = base == null
        ? null
        : {
            for (final o in draftSessionSettings(
              base,
              draft.options,
            ).configOptions)
              o.id: o.currentValue,
          };
    final choices =
        draft.options.entries
            .where((e) => shown == null || shown[e.key] == e.value)
            .toList()
          ..sort((a, b) => rank(a.key).compareTo(rank(b.key)));
    final api = ref.read(bridgeApiProvider);
    try {
      for (final MapEntry(key: id, value: value) in choices) {
        try {
          await api.appSetSessionConfig(service, thread, id, value);
        } catch (e) {
          if (!sameLink()) throw const _LinkMoved();
          throw _DraftOptionsRefused(friendlyError(e));
        }
        if (!sameLink()) throw const _LinkMoved();
      }
    } finally {
      draft.options.clear();
      _drafts.save(draft, changed: true);
    }
  }
}
