part of '../app_session_screen.dart';

/// Opening an ACP agent's session ahead of the first message, without a
/// setup step: a new conversation with a project gets its session as soon as
/// the view can open one, so the agent's own model, effort and mode are real
/// before anything is sent. The draft owns the attempt and its result
/// (see [_ComposerDraft.preparing]): one attempt per draft, reused when the
/// draft is shown again, adopted only by the draft it was opened for and
/// only through the connection and host generation it was opened on.
extension _SessionAgentPrepare on _AppSessionState {
  /// The agent session this view's options and settings belong to: the open
  /// conversation, or the session opened ahead for the shown draft while it
  /// is valid for the current host generation.
  String? get _agentSessionThread {
    final tid = _threadId;
    if (tid != null) return tid;
    // A draft that keeps its own options has no session to point at.
    if (_caps.draftOptions) return null;
    return _preparedFor(_draft);
  }

  /// [draft]'s session opened ahead, when it may still be used.
  String? _preparedFor(_ComposerDraft draft) {
    final id = draft.preparedThread;
    if (id == null || draft.threadId != null) return null;
    final caps = _caps;
    if (!caps.isAcp || !caps.negotiated) return null;
    return caps.generation == draft.preparedGeneration ? id : null;
  }

  /// Where the shown new conversation's session stands.
  AgentSessionPhase get _agentPhase {
    final caps = _caps;
    if (_threadId != null || !caps.hostAccess) return AgentSessionPhase.idle;
    final draft = _draft;
    // ACP agents and native OpenCode create a session only in a project
    // folder (see [_needsProjectToSend]).
    // The host's automatic default counts once the first message creates
    // the session there; nothing is opened (or created) ahead of it.
    if (draft.project == null) {
      return _automaticProject == null
          ? AgentSessionPhase.needsProject
          : AgentSessionPhase.idle;
    }
    // OpenCode creates its session on the first send, never ahead of it.
    if (!caps.isAcp) return AgentSessionPhase.idle;
    if (!caps.negotiated || !caps.sessionConfig) return AgentSessionPhase.idle;
    if (draft.preparing != null) return AgentSessionPhase.opening;
    if (_preparedFor(draft) != null) return AgentSessionPhase.ready;
    final failure = draft.prepareFailure;
    if (failure != null && failure.generation == caps.generation) {
      return AgentSessionPhase.failed;
    }
    return AgentSessionPhase.idle;
  }

  /// After this frame, open the shown draft's session if it needs one. At
  /// most one check is pending; the check itself only reads state.
  void _scheduleAgentSessionCheck() {
    if (_agentCheckScheduled) return;
    _agentCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _agentCheckScheduled = false;
      if (mounted) unawaited(_ensureAgentSession());
    });
  }

  /// Whether the shown draft may open its session now. [retry] is the
  /// user's explicit retry, which also overrides this generation's failure.
  bool _agentOpenAllowed(_ComposerDraft draft, {required bool retry}) {
    if (!mounted || _threadId != null || !identical(draft, _draft)) {
      return false;
    }
    final caps = _caps;
    final failure = draft.prepareFailure;
    return caps.isAcp &&
        caps.negotiated &&
        caps.sessionConfig &&
        draft.threadId == null &&
        draft.project != null &&
        _cwd == draft.project &&
        draft.preparing == null &&
        _preparedFor(draft) == null &&
        (retry || failure == null || failure.generation != caps.generation) &&
        !draft.sendPending &&
        !_sending &&
        !_loading &&
        !_externalWriterMode &&
        !_guardianReadOnly &&
        !_reconnecting &&
        !_connectionLost &&
        !_historySyncing &&
        !_showingCachedHistory;
  }

  /// The user's retry after a failed opening.
  void _retryAgentSession() => unawaited(_ensureAgentSession(retry: true));

  /// Open the shown draft's session for its project. Nothing is sent; the
  /// draft's text, attachments and queue stay as they are. A send started
  /// meanwhile waits for this attempt and uses its session (see `_send`).
  ///
  /// The result is the draft's, not the view's: it is kept only while this
  /// screen is alive, its connection ([_linkEpoch]) and host generation are
  /// unchanged, and the draft is still unsent in the same project. Anything
  /// else leaves the session an empty entry on the host and this view alone.
  Future<void> _ensureAgentSession({bool retry = false}) async {
    final draft = _draft;
    if (!_agentOpenAllowed(draft, retry: retry)) return;
    final service = widget.serviceKey;
    final project = draft.project!;
    final link = _linkEpoch;
    final generation = _caps.generation;
    final api = ref.read(bridgeApiProvider);
    final done = Completer<void>();
    draft
      ..preparing = done.future
      ..prepareFailure = null;
    _drafts.save(draft, changed: true);
    bool owned() =>
        mounted &&
        _linkEpoch == link &&
        _caps.generation == generation &&
        draft.threadId == null &&
        draft.project == project;
    try {
      final id = await api.appThreadStart(service, cwd: project);
      if (owned()) {
        draft
          ..preparedThread = id
          ..preparedGeneration = generation;
      }
    } catch (e) {
      if (owned()) {
        draft.prepareFailure = (
          message: friendlyError(e),
          generation: generation,
        );
      }
    } finally {
      // Only this attempt's own mark is cleared.
      if (identical(draft.preparing, done.future)) draft.preparing = null;
      done.complete();
      _drafts.save(draft, changed: true);
      if (mounted && identical(_draft, draft) && _threadId == null) {
        _refreshAgentSettings();
      }
    }
  }

  /// This device hosts the agent and can edit that host (desktop only):
  /// the way to its model service and environment overrides.
  bool _canOpenAgentHost({required bool watch}) =>
      isDesktop && _localHost(watch: watch) != null;

  /// Open this host in the hosting editor. Opening saves and restarts
  /// nothing; the host list is re-read on return.
  void _openAgentHostSettings() {
    final host = _localHost(watch: false);
    if (host == null || !isDesktop) return;
    unawaited(
      showHostingEditor(context, existing: host).then((_) {
        if (mounted) ref.invalidate(localServeListProvider);
      }),
    );
  }

  /// The label of the model the open session reports, if it reports one.
  String? get _agentModelLabel => _agentSettings?.configOptions
      .where((o) => o.category == 'model')
      .firstOrNull
      ?.currentLabel;

  /// The opening view of a conversation that has sent nothing yet, the same
  /// for every engine: the agent's own mark, the project and where the
  /// session stands.
  Widget _agentWelcome(AppLocalizations l10n) {
    final caps = _caps;
    final phase = _agentPhase;
    final hasProject = _cwd?.trim().isNotEmpty ?? false;
    // Codex creates its thread with the first message, in a project or not.
    final codex = !caps.hostAccess;
    return AgentWelcome(
      agentKind: codex
          ? AgentKind.codex
          : agentKindOf(
              provider: caps.isOpenCode ? 'opencode' : 'acp',
              profileId: caps.profileId,
            ),
      agentName: caps.providerName,
      project: _projectSwitcher(
        l10n,
        // ACP agents and OpenCode cannot work outside a project.
        label: _newProjectLabel(
          l10n,
          codex ? l10n.workOutsideProject : l10n.chooseFolder,
        ),
      ),
      cwd: hasProject ? _cwd : _automaticProject,
      phase: phase,
      failure: _draft.prepareFailure?.message,
      modelLabel: _agentModelLabel,
      recent: _knownProjects(),
      onPickRecent: _selectProject,
      onChooseFolder: _browseDraftProject,
      onRetry: _retryAgentSession,
      onHostSettings: _canOpenAgentHost(watch: true)
          ? _openAgentHostSettings
          : null,
      connecting:
          _reconnecting || _connectionLost || (!codex && !caps.negotiated),
      // Codex and OpenCode create their session on the first message; the
      // latter's options are the draft's own until then.
      opensOnFirstMessage:
          codex ||
          caps.negotiated &&
              (!caps.sessionConfig ||
                  caps.draftOptions ||
                  (!hasProject && _automaticProject != null)),
    );
  }
}
