part of '../app_session_screen.dart';

/// Sessions this app handed back to other clients ([_releaseSession]), by
/// [_AppSessionState._threadKey]. Opening one of them only inspects it until
/// the user continues here: a release is never undone by the next click.
final Set<String> _releasedHereThreads = {};

/// How a host-access engine's session (ACP agents, native OpenCode) is
/// opened and followed.
///
/// The host decides [SessionAccess]; this view renders it. Opening a
/// session is one call ([BridgeApi.appSessionOpen]) that resumes the
/// original session when that is safe; otherwise the view follows it
/// read-only, says who holds it, and re-checks without side effects
/// ([BridgeApi.appSessionAccess]). Only when the host reports no other
/// writer does it open again, through a fresh admission. Drafts stay where
/// they are; queued messages are held while following and offered, never
/// sent, once writing is possible again.
extension _SessionAccess on _AppSessionState {
  /// Open [thread] through the host (the resume step of [_resumeAndLoad]);
  /// `true` when this view may write it.
  Future<bool> _openHostSession(String thread, bool Function() current) async {
    final api = ref.read(bridgeApiProvider);
    final changed = AppLocalizations.of(context).sessionAccessChanged;
    final released = _releasedHereThreads.contains(_threadKey(thread));
    final access = released
        ? await api.appSessionAccess(widget.serviceKey, thread)
        : await api.appSessionOpen(widget.serviceKey, thread);
    if (!current()) return false;
    if (access.sessionId != thread) {
      throw StateError(changed);
    }
    if (access.writable) {
      _releasedHereThreads.remove(_threadKey(thread));
      _updateState(() => _access = access);
      _offerQueueHeldByFollow();
      return true;
    }
    _enterAccessFollow(thread, access);
    return false;
  }

  /// Follow [thread] read-only as [access] says, re-checking while the host
  /// expects it to change.
  void _enterAccessFollow(String thread, SessionAccess access) {
    _enterExternalWriterMode(thread, follow: access.mode != 'blocked');
    final epoch = _externalWriterEpoch;
    _updateState(() {
      _access = access;
      _followSince = DateTime.now();
      // Another writer may change the conversation meanwhile: what was
      // queued here waits for the user's explicit go-ahead.
      if (_queue.isNotEmpty) _draft.queuePaused = true;
    });
    _scheduleAccessCheck(thread, epoch);
  }

  /// The reason this view shows: a session handed back here stays "handed
  /// back" while nobody else took it.
  String get _accessReason {
    final access = _access;
    if (access == null) return 'source_unknown';
    final thread = _threadId;
    final releasedHere =
        thread != null &&
        _releasedHereThreads.contains(_threadKey(thread)) &&
        (access.writer == 'none' || access.writer == 'this_host');
    return releasedHere ? 'released_here' : access.reason;
  }

  /// The host reports nobody writes [access]'s session (or this view may
  /// already), so a fresh open may admit this view. A session this host
  /// handed back, or one changing hands, is never taken by itself.
  bool _accessAdmissible(SessionAccess access) =>
      access.mode != 'blocked' &&
      access.reason != 'released_here' &&
      access.reason != 'transition' &&
      (access.writable || access.writer == 'none');

  bool _followCurrent(String thread, int epoch) =>
      mounted &&
      _externalWriterMode &&
      !_guardianReadOnly &&
      _threadId == thread &&
      epoch == _externalWriterEpoch;

  void _scheduleAccessCheck(String thread, int epoch) {
    _accessTimer?.cancel();
    _accessTimer = null;
    final access = _access;
    if (access == null || !access.recheck || !_followCurrent(thread, epoch)) {
      return;
    }
    // Quick while the state is fresh, then calmer; the host may also push
    // a change ([_onAccessChanged]).
    final since = _followSince ?? DateTime.now();
    final delay = DateTime.now().difference(since) < const Duration(minutes: 1)
        ? const Duration(seconds: 3)
        : const Duration(seconds: 15);
    _accessTimer = Timer(delay, () {
      _accessTimer = null;
      // Nothing is asked while the app is in the background or this view is
      // covered; the next tick (or Check now) asks again.
      final visible = ModalRoute.of(context)?.isCurrent ?? true;
      if (!_foreground || !visible) {
        _scheduleAccessCheck(thread, epoch);
        return;
      }
      unawaited(_checkAccess(thread, epoch));
    });
  }

  /// Ask the host again (a tick, a host event or Check now).
  Future<void> _checkAccess(String thread, int epoch) async {
    if (!_followCurrent(thread, epoch) || _accessChecking) return;
    _accessChecking = true;
    try {
      final access = await ref
          .read(bridgeApiProvider)
          .appSessionAccess(widget.serviceKey, thread);
      if (!_followCurrent(thread, epoch) || access.sessionId != thread) return;
      _updateState(() => _access = access);
      if (_accessAdmissible(access) && _accessReason != 'released_here') {
        await _openFromFollow(thread);
        return;
      }
    } catch (error) {
      if (_followCurrent(thread, epoch)) {
        _updateState(() => _error = friendlyError(error));
      }
    } finally {
      if (_followCurrent(thread, epoch)) {
        _accessChecking = false;
        _scheduleAccessCheck(thread, epoch);
      }
    }
  }

  /// The host announced that a session's access changed.
  void _onAccessChanged(String thread) {
    if (!_externalWriterMode || _threadId != thread) return;
    unawaited(_checkAccess(thread, _externalWriterEpoch));
  }

  /// The host withdrew this view's write admission (a release by any
  /// controller, or another writer): follow at once, keeping the draft and
  /// queue in their slot, and ask the host where the session stands.
  void _onWriteWithdrawn(String thread) {
    if (_externalWriterMode || _threadId != thread || _guardianReadOnly) {
      return;
    }
    _enterExternalWriterMode(thread);
    final epoch = _externalWriterEpoch;
    _updateState(() {
      _followSince = DateTime.now();
      if (_queue.isNotEmpty) _draft.queuePaused = true;
    });
    unawaited(_checkAccess(thread, epoch));
  }

  /// Leave following and open [thread] again through a fresh admission; a
  /// refused open follows again.
  Future<void> _openFromFollow(String thread) async {
    if (!mounted || _threadId != thread || !_externalWriterMode) return;
    _cancelExternalWriterSubscription();
    _updateState(() {
      _externalWriterMode = false;
      _externalWriterLiveness = null;
      _takingOver = true;
    });
    try {
      await _resumeAndLoad();
    } finally {
      if (mounted && _threadId == thread) {
        _updateState(() => _takingOver = false);
      }
    }
  }

  /// Continue a session this view handed back.
  Future<void> _continueHere() async {
    final thread = _threadId;
    if (thread == null || _takingOver) return;
    _releasedHereThreads.remove(_threadKey(thread));
    await _openFromFollow(thread);
  }

  /// Check now, from the access panel.
  void _checkAccessNow() {
    final thread = _threadId;
    if (thread == null) return;
    _accessTimer?.cancel();
    _accessTimer = null;
    _followSince = DateTime.now();
    unawaited(_checkAccess(thread, _externalWriterEpoch));
  }

  /// Hand this host's idle writer back to other clients. Admissions freeze
  /// first (the draft and queue stay in their slot); the view then follows
  /// and does not take the session again until Continue here.
  Future<void> _releaseSession() async {
    final thread = _threadId;
    final access = _access;
    if (thread == null ||
        access == null ||
        !access.canRelease ||
        _externalWriterMode ||
        _streaming ||
        _sending ||
        _takingOver) {
      return;
    }
    final service = widget.serviceKey;
    _enterExternalWriterMode(thread);
    final epoch = _externalWriterEpoch;
    _updateState(() {
      _takingOver = true;
      if (_queue.isNotEmpty) _draft.queuePaused = true;
    });
    try {
      final answer = await ref
          .read(bridgeApiProvider)
          .appSessionRelease(service, access);
      if (!_followCurrent(thread, epoch) || widget.serviceKey != service) {
        return;
      }
      _releasedHereThreads.add(_threadKey(thread));
      _updateState(() {
        _access = answer;
        _followSince = DateTime.now();
        _takingOver = false;
      });
      _scheduleAccessCheck(thread, epoch);
    } catch (error) {
      if (!_followCurrent(thread, epoch)) return;
      // Nothing was handed back: write here again, as before.
      _updateState(() => _takingOver = false);
      await _openFromFollow(thread);
      if (mounted && _threadId == thread) {
        _updateState(() => _error = friendlyError(error));
      }
    }
  }

  /// Whether "Hand back to other clients" is offered: this view writes an
  /// idle session the host can release.
  bool get _canReleaseSession =>
      _caps.hostAccess &&
      !_guardianReadOnly &&
      !_externalWriterMode &&
      !_streaming &&
      !_takingOver &&
      (_access?.canRelease ?? false);

  /// After following, messages queued here wait; say so and let Retry send
  /// them. A failed queued message keeps its own recovery
  /// ([_offerHeldQueue]).
  void _offerQueueHeldByFollow() {
    final head = _queue.firstOrNull;
    if (head == null || !_draft.queuePaused || head.failure != null) return;
    final l10n = AppLocalizations.of(context);
    _updateState(() {
      _error = l10n.accessQueueHeld(_queue.length);
      _retry = _resumeQueue;
    });
  }

  /// What a write here excludes, said on the status line rather than as
  /// chrome in the conversation; null unless this view writes.
  String? _accessScopeNote(AppLocalizations l10n) {
    final access = _access;
    if (!_caps.hostAccess ||
        access == null ||
        !access.writable ||
        _externalWriterMode) {
      return null;
    }
    return switch (access.exclusion) {
      'engine' => l10n.accessScopeEngine(_caps.providerName),
      'pocket' => l10n.accessScopePocket,
      _ => l10n.accessScopeNone,
    };
  }

  /// [label] with the access scope as its tooltip, when there is one.
  Widget _withAccessScope(AppLocalizations l10n, Widget label) {
    final note = _accessScopeNote(l10n);
    if (note == null) return label;
    return Tooltip(
      key: const Key('chat-access-scope'),
      message: note,
      triggerMode: TooltipTriggerMode.tap,
      child: label,
    );
  }

  /// The access panel shown in place of the composer.
  Widget _accessPanel(AppLocalizations l10n) {
    final access = _access;
    final holderKey = access?.holder?.serviceKey;
    final thread = _threadId;
    final host = _localHost(watch: false);
    final reason = _accessReason;
    return SessionAccessPanel(
      access: access,
      reason: reason,
      providerName: _caps.providerName,
      busy: _takingOver || _accessChecking,
      // Asking again is real wherever the state can change outside this
      // view; a handed-back, unsupported or missing session it cannot.
      onCheck:
          const {'released_here', 'unsupported', 'not_found'}.contains(reason)
          ? null
          : _checkAccessNow,
      onContinue: reason == 'released_here' ? _continueHere : null,
      onOpenHolder: holderKey == null || holderKey.isEmpty || thread == null
          ? null
          : () => context.push(conversationRoute(holderKey, thread, cwd: _cwd)),
      onStartHost: reason == 'host_stopped' && host != null
          ? () => showHostingEditor(context, existing: host)
          : null,
    );
  }
}
