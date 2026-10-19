part of '../app_session_screen.dart';

extension _SessionSend on _AppSessionState {
  bool get _localSending => _localSendOwner != null;

  /// Take the send lock for [owner]; a new operation begins.
  void _holdSend(Object owner) {
    _localSendOwner = owner;
    _composerOp++;
  }

  /// Release the send lock if [owner] still holds it.
  void _releaseSend(Object owner) {
    if (identical(_localSendOwner, owner)) _localSendOwner = null;
  }

  bool get _awaitingTurnStart => _awaitedStart != null;
  // Navigation clears local operations, but cannot unlock a draft's send.
  bool get _sending => _localSending || _draft.sendPending;

  Future<void> _send({
    bool retry = false,
    String? overrideText,
    _Queued? queued,
    _Resend? resend,
    _Resend? failedTurn,
  }) async {
    // A retry re-sends exactly what its failed send put on the wire (its own
    // captured copy; the last-sent fields move with every later send). A
    // [failedTurn] is the input of a turn the host recorded and the model
    // failed: sent again as a new turn, exactly as recorded.
    final resent = retry ? (resend ?? _lastSent) : null;
    final typed = retry
        ? (resent?.text ?? '')
        : (failedTurn?.text ??
              queued?.text.trim() ??
              overrideText ??
              _input.text.trim());
    // Attachments ride an ordinary composer send only: a programmatic send
    // (e.g. "implement the plan") must not consume them, and a retry re-sends
    // the snapshot taken at the original send.
    final ordinary = !retry && overrideText == null && failedTurn == null;
    final sendAttachments = List<_Attachment>.of(
      queued?.attachments ?? _attachments,
    );
    final images = retry
        ? (resent?.images ?? const <String>[])
        : failedTurn != null
        ? failedTurn.images
        : !ordinary
        ? const <String>[]
        : [
            for (final a in sendAttachments)
              if (!a.isFile) ?a.processed?.dataUrl,
          ];
    // File attachments were already uploaded to the host at pick time; they
    // travel as a path-reference block appended to the text (codex's native
    // document workflow). On retry `typed` already contains the block, so no
    // re-upload and no double-append.
    final filePaths = ordinary
        ? [
            for (final a in sendAttachments)
              if (a.isFile) ?a.hostPath,
          ]
        : const <String>[];
    // Built-in tools ride an ordinary send too, named for the agent at the
    // end of the text. A message sent again (a retry, a failed turn) carries
    // that block in its own text: the tools it names are granted again.
    final sendTools = ordinary
        ? List<String>.of(queued?.tools ?? _tools)
        : retry || failedTurn != null
        ? splitBuiltinTools(typed).ids
        : const <String>[];
    final text = appendBuiltinTools(
      appendFileRefs(typed, filePaths),
      ordinary ? sendTools : const [],
      summaries: _hostToolSummaries(),
    );
    // The message's name for its host (see [_sender]): a retry keeps its
    // first send's, so it shows in that copy.
    final clientId = resent?.clientId ?? _newClientId();
    final again = _Resend(text: text, images: images, clientId: clientId);
    // Block sends while reconnecting — a reconnect reloads history and would
    // wipe an optimistic message added mid-flight.
    if (_externalWriterMode ||
        (text.isEmpty && images.isEmpty) ||
        _sending ||
        (queued != null && (queued.inFlight || queued.uncertain)) ||
        _reconnecting ||
        _historySyncing ||
        _restoringSettings ||
        _showingCachedHistory ||
        _savingAgentConfig) {
      return;
    }
    // If this host is THIS machine's codex and it can't make model calls yet
    // (no login AND no custom provider), a turn would silently fail. Steer the
    // user to the setup wizard instead of starting an invalid conversation.
    if (_codexNeedsSetup(watch: false)) {
      _openCodexSetup();
      return;
    }
    // Never send while an attachment is still processing/uploading — the
    // message would silently ship without it. (The send button is disabled
    // too; this also guards the Enter-to-send path.)
    if (ordinary && sendAttachments.any((a) => !a.ready)) {
      return;
    }
    // No session can be created without its project folder: nothing is
    // sent and nothing is shown as sent. The composer's own send asks for
    // the folder and continues there; anything else says what is missing.
    if (_needsProjectToSend) {
      if (ordinary && queued == null) {
        unawaited(_chooseProjectThenSend());
      } else {
        final l10n = AppLocalizations.of(context);
        _updateState(() {
          _error = l10n.agentWelcomeNeedsProject(_caps.providerName);
          _retry = null;
        });
      }
      return;
    }
    // Take the send lock up front, before the retry probe's await below, so the
    // composer can't start a second send during that round-trip (re-entrancy).
    final api = ref.read(bridgeApiProvider);
    final sendingDraft = _draft;
    final request = Object();
    _sendRequest = request;
    // The whole send goes to the service and host connection it began on:
    // nothing is dispatched once that connection was lost or replaced, and
    // an answer arriving after that is not adopted (see [_LinkMoved]).
    final service = widget.serviceKey;
    final link = _linkEpoch;
    bool sameLink() => _linkEpoch == link;
    // This view still shows the request's draft (navigation and a newer
    // send replace the request).
    bool shown() =>
        mounted &&
        identical(_sendRequest, request) &&
        identical(_draft, sendingDraft);
    bool current() => shown() && sameLink();
    var targetThread = _threadId;
    final targetCwd = _cwd;
    // Where the host will create a conversation sent without a folder; only
    // labels the optimistic list entry until the host's list answers.
    final automaticCwd = targetCwd == null ? _automaticProject : null;
    final catalogProject = _catalogProject;
    final isNewThread = targetThread == null;
    final l10n = AppLocalizations.of(context);
    final preview = typed.isNotEmpty
        ? typed
        : filePaths.isNotEmpty
        ? l10n.fileOnlyMessage
        : l10n.imageOnlyMessage;
    _settingsRevision++;
    final mode = _mode;
    // Providers without these controls keep their own configuration: send
    // nothing rather than a Codex preset they would have to interpret.
    final presets = _caps.permissionPresets;
    final tier = _caps.fast ? _requestedServiceTier : null;
    // A queued message keeps its place until the host admits it.
    _updateState(() {
      _holdSend(request);
      queued?.inFlight = true;
    });
    // Leaving before the send starts releases only what this request holds.
    void abandon() {
      queued?.inFlight = false;
      if (!mounted) return;
      _updateState(() => _releaseSend(request));
    }

    // Retry safety: a send can commit server-side just before the socket drops
    // (we reconnect with reload:false to keep the optimistic bubble for a
    // one-tap retry). Re-sending a committed turn records the prompt twice —
    // which both shows a duplicate user bubble and leaves a trailing duplicate
    // that hides the plan-implement choice. So on retry, ask the server first;
    // if this prompt is already the latest user turn, just reload its (possibly
    // in-progress) history instead of sending again. An unreadable history
    // decides nothing: the retry stays offered and nothing is sent.
    if (retry) {
      // An answer of a connection that changed meanwhile is null (unverified).
      final committed = await _turnAlreadyCommitted(text, images);
      if (!shown()) {
        abandon();
        return;
      }
      if (committed != false) {
        abandon();
        if (committed == null) {
          _updateState(() {
            _error = l10n.retryUnverified;
            _retry = () => _send(retry: true, resend: again);
          });
          return;
        }
        await _resumeAndLoad();
        return;
      }
    }
    String? bubble;
    _updateState(() {
      _error = null;
      _retry = null;
      _lastSent = again;
      if (!retry) {
        final id = 'local-user-$clientId';
        bubble = id;
        _itemIndex[id] = _items.length;
        _items.add(
          TranscriptItem(
            id: id,
            type: 'userMessage',
            text: text,
            images: resolveImageUrls(images),
            imageUrls: images,
            clientId: clientId,
          ),
        );
        // Remember the just-sent draft so an Esc "undo" (before any output)
        // can restore it to the composer. Only for an ordinary send — a
        // programmatic prompt (e.g. "implement the plan") has no user draft to
        // hand back.
        _undoableDraft = ordinary
            ? (
                text: typed,
                attachments: List<_Attachment>.of(sendAttachments),
                tools: sendTools,
              )
            : null;
        // Don't clear the composer for a programmatic send (e.g. "implement
        // the plan") — the user may have text in progress there.
        if (ordinary && queued == null) {
          _attachments.clear();
          _tools.clear();
          _input.clear();
        }
        _saveDraft();
      }
    });
    _scrollToEnd(force: true);
    var dropped = false;
    var sent = false;
    // Whether turn/start was put on the wire: an error before it admitted
    // nothing.
    var dispatched = false;
    // A failed queued message keeps its text and attachments at the head of
    // its queue, which pauses until the user acts: it is never replayed by
    // itself. A proven refusal (nothing was admitted) may simply be retried;
    // an [uncertain] one is sent again only by the user's explicit Retry
    // (see [_resendUncertain]).
    var requeued = false;
    void holdQueued(String message, {required bool uncertain}) {
      final entry = queued;
      if (entry == null) return;
      requeued = true;
      entry.inFlight = false;
      entry.uncertain = uncertain;
      entry.failure = message;
      sendingDraft.queuePaused = true;
      if (!mounted || !identical(_draft, sendingDraft)) return;
      _updateState(() {
        final index = bubble == null ? -1 : _itemIndex[bubble] ?? -1;
        if (index >= 0 && index < _items.length && _items[index].id == bubble) {
          _items.removeAt(index);
          _rebuildItemIndex();
          _cachedRows = null;
        }
        _undoableDraft = null;
        // The banner belongs to this request's view; otherwise the next
        // reload or reconnect of the conversation offers it (see
        // [_offerHeldQueue]).
        if (shown()) {
          _error = uncertain
              ? '$message\n${l10n.queuedUncertainRetry}'
              : message;
          _retry = uncertain ? () => _resendUncertain(entry) : _resumeQueue;
        }
      });
    }

    // The host connection moved before this send could complete. Its input
    // goes back to its own draft with the reason — nothing is resent on the
    // user's behalf — and its optimistic copy is withdrawn (the reconnect's
    // reload shows what the host holds).
    void returnToDraft(String message) {
      _restoreDraft(
        typed,
        sendAttachments,
        tools: sendTools,
        into: sendingDraft,
      );
      if (!mounted || !identical(_draft, sendingDraft)) return;
      _updateState(() {
        final index = bubble == null ? -1 : _itemIndex[bubble] ?? -1;
        if (index >= 0 && index < _items.length && _items[index].id == bubble) {
          _items.removeAt(index);
          _rebuildItemIndex();
          _cachedRows = null;
        }
        _undoableDraft = null;
      });
      showToast(context, '$message ${l10n.sendReturnedToDraft}');
    }

    sendingDraft.sendPending = true;
    _drafts.save(sendingDraft, changed: true);
    try {
      // Collaboration mode for this turn. Send it when the user explicitly
      // toggled the plan chip (so an explicit on/off is always honored, even if
      // our view of the server mode is stale), or when the desired toggle
      // differs from the known mode; otherwise leave it unchanged (null) so
      // ordinary turns don't force a model.
      // None of the model menu's settings go out where the session's own
      // options replace it (see [_usesModelMenu]).
      final menu = _usesModelMenu;
      final collab = menu && (_planToggledByUser || _plan != _planActive)
          ? (_plan ? 'plan' : 'default')
          : null;
      // The effort this turn runs with: a pending pick, else the thread's
      // current effort (re-asserted so a plan/permission turn can't drop it).
      final effort = menu ? _effectiveEffort : null;
      // A model picked from a list the current connection has not confirmed
      // yet (read before a reconnect) is checked against this host's own
      // list first: a host replaced with another configuration may no longer
      // offer it. Then nothing is sent and the message returns to its draft;
      // an unreadable list decides nothing (the host validates as before).
      // Only the list of this message's project decides: one read after the
      // view moved to another project decides nothing for it.
      var modelId = menu ? _model?.id : null;
      if (modelId != null &&
          !_modelsCurrent &&
          _catalogProject == catalogProject) {
        final changes = _catalogChanges;
        final modelsKey = _modelsLinkKey;
        await _ensureModels();
        if (!sameLink()) throw const _LinkMoved();
        if (_modelsKey == modelsKey &&
            _catalogChanges != changes &&
            !_models.any((m) => m.id == modelId)) {
          throw _ModelWithdrawn(l10n.modelWithdrawn);
        }
      }
      // Both plan and default collaboration settings require a concrete model
      // id; resolve one (and reflect it in the chip) if left on "default".
      if (collab != null && modelId == null) {
        final models = await api.appModelListForProject(
          service,
          catalogProject,
        );
        // An answer of a connection that moved names nothing for this one,
        // and nothing more is asked of whichever host answers now.
        if (!sameLink()) throw const _LinkMoved();
        if (models.isNotEmpty) {
          modelId = models.first.id;
          if (current()) _updateState(() => _model = models.first);
        }
      }
      // The server silently ignores collaborationMode without a concrete model,
      // which would leave the thread in its previous mode while we optimistically
      // flip _planActive below — a silent UI/server divergence. Refuse instead so
      // the switch (enter/leave plan mode) never appears to succeed when it can't.
      if (collab != null && modelId == null) {
        if (queued != null) {
          holdQueued(l10n.noModelForMode, uncertain: false);
        } else if (shown()) {
          _updateState(() {
            _error = l10n.noModelForMode;
            _retry = () => _send(retry: true, resend: again);
          });
        } else if (ordinary) {
          _restoreDraft(
            typed,
            sendAttachments,
            tools: sendTools,
            into: sendingDraft,
          );
        }
        return;
      }
      if (targetThread == null) {
        // The agent session being opened for this draft is this message's
        // session: wait for that attempt rather than open a second one. A
        // connection that moved meanwhile sends nothing (as below).
        final opening = sendingDraft.preparing;
        if (opening != null) {
          await opening;
          if (!sameLink()) throw const _LinkMoved();
        }
        // Opened ahead for this draft's project on this host generation.
        // An unknown opening result may leave an empty session on the host.
        // This explicit send can open another; no payload was sent before.
        if (mounted && sendingDraft.project == targetCwd) {
          targetThread = _preparedFor(sendingDraft);
        }
      }
      targetThread ??= await api.appThreadStart(
        service,
        model: modelId,
        cwd: targetCwd,
        approvalPolicy: presets ? mode.approval : null,
        approvalsReviewer: presets ? mode.reviewer : null,
        serviceTier: tier,
        sandbox: presets ? mode.sandbox : null,
      );
      // A session created through a connection that moved since (lost,
      // replaced, another generation or source) is not known to be the
      // current host's: nothing adopts or records it, and the input stays
      // in its own unsent draft.
      if (!sameLink()) throw const _LinkMoved();
      if (isNewThread) {
        // The session exists for its draft even if the view moved on within
        // the same connection; only that draft adopts it.
        _drafts.adoptThread(sendingDraft, targetThread);
        // The user may have reopened this same draft while thread/start waited.
        if (mounted && identical(_draft, sendingDraft)) {
          _threadId = targetThread;
          // Created where the host chose; the host's list names the folder.
          _automaticThread = automaticCwd == null
              ? null
              : (key: service, thread: targetThread);
          ref
              .read(uiPrefsProvider.notifier)
              .setLastThread(service, targetThread);
          // A new ACP session reports its own options (if any).
          if (_caps.sessionConfig) _refreshAgentSettings();
          // Its access was never read here (see [_refreshWriteAccess]).
          unawaited(_refreshWriteAccess(targetThread));
        }
        // Surface the new session in the left pane immediately. `thread/list`
        // can lag `thread/start`, so optimistically insert it now (newest
        // first) and let _loadThreads reconcile once the server catches up.
        final tid = targetThread;
        if (mounted && !_threads.any((t) => t.id == tid)) {
          _updateState(() {
            _threads = [
              ThreadMeta(
                id: tid,
                // Preview the TYPED text (never the appended file-reference
                // block); an attachment-only first message gets a placeholder.
                preview: preview,
                cwd: targetCwd ?? automaticCwd ?? '',
                updatedAt: 0,
              ),
              ..._threads,
            ];
          });
        }
        if (mounted) _loadThreads();
        // Persist this new thread's config now that it has a server-side id, so
        // it's stored even if the first turn/start below fails.
        if (current()) _persistThreadConfig();
      }
      // A draft's own option choices belong to the session its first send
      // created: they apply before that message is sent (again on a retry
      // after they could not be applied).
      if (_caps.draftOptions && sendingDraft.options.isNotEmpty) {
        await _applyDraftOptions(sendingDraft, service, targetThread, sameLink);
        if (mounted && identical(_draft, sendingDraft)) {
          _refreshAgentSettings();
        }
      }
      // Record what this turn puts on the wire BEFORE sending: turn/started
      // (and the stamp it takes) can arrive while the await below is still in
      // flight. Turn params override thread defaults, so on servers that never
      // notify settings these ARE the effective values.
      if (current()) {
        _sentModel = modelId;
        _sentEffort = effort?.wire;
      }
      // Pass the current model + permission + collaboration mode every turn:
      // turn/start overrides apply to this and subsequent turns, so switching
      // works mid-conversation.
      final turnRevision = _turnStateRevision;
      // Built-in tools picked for this message: a gated one is allowed for
      // this conversation before its agent could ask.
      await _grantBuiltinTools(service, targetThread, sendTools);
      // The model list or thread start above may have outlived the
      // connection: nothing goes to whichever host answers now.
      if (!sameLink()) throw const _LinkMoved();
      dispatched = true;
      await api.appTurnStart(
        service,
        targetThread,
        text,
        images: images,
        model: modelId,
        approvalPolicy: presets ? mode.approval : null,
        approvalsReviewer: presets ? mode.reviewer : null,
        serviceTier: tier,
        sandbox: presets ? mode.sandbox : null,
        collaborationMode: collab,
        // Re-assert the effective effort every turn. The bridge puts it on the
        // top-level `effort` field AND (when a collaborationMode is sent) into
        // collaborationMode.settings, so toggling plan/permission never wipes the
        // thread's sticky effort. null only when no effort has ever been set.
        reasoningEffort: effort?.wire,
        clientId: clientId,
      );
      // Accepted by a connection that is gone now: whether the turn lives on
      // is open, so nothing is adopted (no queue removal, no admission).
      if (!sameLink()) throw const _LinkMoved();
      sent = true;
      if (queued != null) sendingDraft.queue.remove(queued);
      // Admitted, but its start may not have arrived: until it does the
      // session is busy and the queue must not send the next message.
      if (current() && !_streaming && _turnStateRevision == turnRevision) {
        _expectTurnStart(sendingDraft, targetThread, clientId);
      }
      if (current()) {
        _updateState(() {
          _planActive = _plan;
          _planToggledByUser = false;
          // The user's model pick (if any) is now on the wire; server
          // confirmations may sync the pill again.
          _modelPickPending = false;
          if (_mode == mode) _modePickPending = false;
          if (_serviceTier == tier) _serviceTierPickPending = false;
          // The effort this turn ran with is now the thread's active effort.
          _effortActive = effort;
          // Clear the pending pick ONLY if the user hasn't chosen a NEWER effort
          // while this turn was being sent. A mid-send `_pickEffort` sets
          // `_effort` (and persists it) for the next turn; blindly nulling it
          // here would silently revert that change (R4).
          if (_effort == effort) _effort = null;
        });
        // Remember this thread's mode + effort so resuming/switching restores it.
        if (_threadId != null) {
          _AppSessionState._planByThread[_threadKey(_threadId!)] = _plan;
          _AppSessionState._effortByThread[_threadKey(_threadId!)] = effort;
        }
        // Persist the config now that the thread has an id — covers a brand-new
        // conversation whose settings were chosen before its first turn.
        _persistThreadConfig();
        // Adopt the bridge's cached runtime config: for a brand-new thread the
        // start response reported the effective model/permissions, and any
        // settings notification that raced the send is folded in too.
        _refreshRuntimeFromCache();
      }
    } catch (e) {
      final moved = e is _LinkMoved;
      final msg = e is _DraftOptionsRefused
          ? e.message
          : !moved
          ? friendlyError(e)
          : dispatched
          ? l10n.sendAnswerStale
          : l10n.sendHostChanged;
      final refused =
          !sent && (!dispatched || (!moved && _definitelyRefused(msg)));
      if (queued != null && !sent) {
        // Its text and attachments stay queued either way; only a proven
        // refusal may be retried without asking the host first.
        holdQueued(msg, uncertain: !refused);
      } else if (moved && ordinary) {
        returnToDraft(msg);
      } else if (ordinary &&
          (e is _DraftOptionsRefused ||
              (isNewThread && !dispatched && !_looksDisconnected(msg)))) {
        // Nothing of the message was sent (its session could not be
        // created or prepared, so no turn was dispatched): it goes back to
        // its draft (before anything typed since), its optimistic copy is
        // withdrawn, and the session shows the options it really has.
        // Sending again is the user's ordinary send, from the composer.
        final sendAgain = e is _DraftOptionsRefused ? null : _submit;
        _restoreDraft(
          typed,
          sendAttachments,
          tools: sendTools,
          into: sendingDraft,
        );
        if (mounted && identical(_draft, sendingDraft)) {
          _updateState(() {
            final index = bubble == null ? -1 : _itemIndex[bubble] ?? -1;
            if (index >= 0 &&
                index < _items.length &&
                _items[index].id == bubble) {
              _items.removeAt(index);
              _rebuildItemIndex();
              _cachedRows = null;
            }
            _undoableDraft = null;
            if (shown()) {
              _error = msg;
              _retry = sendAgain;
            }
          });
        }
      } else {
        if (shown()) {
          _updateState(() {
            _error = msg;
            _retry = () => _send(retry: true, resend: again);
          });
        } else if (ordinary) {
          // This view moved on: the input goes back to its own draft (it is
          // never sent from there by itself).
          _restoreDraft(
            typed,
            sendAttachments,
            tools: sendTools,
            into: sendingDraft,
          );
        }
        if (shown() && !moved && _looksDisconnected(msg)) dropped = true;
      }
    } finally {
      if (queued != null && !requeued) queued.inFlight = false;
      sendingDraft.sendPending = false;
      _drafts.save(sendingDraft, changed: true);
      if (mounted) _updateState(() => _releaseSend(request));
      // Only an idle session drains; an admitted turn ends first (see
      // [_awaitingTurnStart]).
      if (sent &&
          mounted &&
          sameLink() &&
          identical(_draft, sendingDraft) &&
          _error == null &&
          !dropped) {
        _maybeFlushQueue();
      }
    }
    // The connection dropped mid-send: recover it in the background so a retry
    // (or the next message) succeeds. We do NOT auto-resend — the turn may have
    // committed server-side before the socket dropped, and resending would
    // duplicate it; the user retries with one tap instead. `reload: false`
    // keeps the optimistic message visible (and the plan toggle) for that retry.
    if (dropped && shown()) {
      await _autoReconnect(reload: false);
      // _autoReconnect cleared the error; re-offer the retry now that the
      // connection is back (retry re-sends this send's copy into the existing
      // bubble).
      if (shown() && !_connectionLost) {
        _updateState(() {
          _error = AppLocalizations.of(context).turnFailed;
          _retry = () => _send(retry: true, resend: again);
        });
      }
    }
  }

  /// Whether the server already recorded [text] as the latest user turn — i.e.
  /// a send committed before the socket dropped — so the user's explicit
  /// Retry reloads instead of recording it twice. This only avoids the common
  /// duplicate: a missing match is no proof that the send never arrived
  /// (another writer, a bounded tail), which is why only the user's own Retry
  /// acts on it. Returns null when the answer cannot be trusted: the history
  /// was unreadable, or the conversation, connection or host changed while
  /// it was read; the caller then keeps the message and sends nothing.
  ///
  /// Idempotency compares the full message content — text AND the image URL
  /// list (history echoes the data URLs we sent verbatim): if the user
  /// deliberately re-asks an identical prompt and *that* send drops before
  /// committing, the latest committed user turn still matches, so the retry
  /// reloads instead of resending. Comparing URLs (not just a count) matters
  /// for image-only messages, which ALL have empty text — a count-only match
  /// would swallow a retry of a *different* photo. Accepted edge — avoiding a
  /// duplicate (costly) turn is preferred over re-sending a rare identical
  /// consecutive prompt.
  Future<bool?> _turnAlreadyCommitted(String text, List<String> images) async {
    final tid = _threadId;
    if (tid == null) return false;
    // The answer counts only for the conversation, connection and host it
    // was asked of.
    final service = widget.serviceKey;
    final link = _linkEpoch;
    final hostGeneration = _caps.generation;
    bool unchanged() =>
        mounted &&
        _threadId == tid &&
        _linkEpoch == link &&
        _caps.generation == hostGeneration;
    try {
      final api = ref.read(bridgeApiProvider);
      await api.appThreadResume(service, tid);
      if (!unchanged()) return null;
      final history = await api.appThreadRead(service, tid);
      if (!unchanged()) return null;
      final want = text.trim();
      for (final i in history.items.reversed) {
        if (i.itemType == 'userMessage') {
          return i.text.trim() == want && listEquals(i.images, images);
        }
      }
      return false;
    } catch (_) {
      return null;
    }
  }

  /// What a `modelError` card offers: only the conversation's current
  /// failure (its last row) in a view that may write and is idle. Older
  /// failures in the history are shown, never acted on. Retry needs the
  /// failed prompt's own message complete here and waits for a model change
  /// still being saved; changing the model stays offered either way.
  ModelErrorActions? _modelErrorActions(TranscriptItem error) {
    if (!_isCurrentFailure(error)) return null;
    final prompt = _failedPrompt(error);
    final change = _failureModelOption != null
        ? _changeModelAfterFailure
        : null;
    if (prompt == null || !_resendable(prompt)) {
      return ModelErrorActions(onChangeModel: change, incomplete: true);
    }
    return ModelErrorActions(
      onRetry: () => _retryFailedTurn(error),
      onChangeModel: change,
      saving: _savingAgentConfig,
    );
  }

  bool _isCurrentFailure(TranscriptItem error) {
    final thread = _threadId;
    if (error.type != 'modelError' ||
        thread == null ||
        _isDeleted(thread) ||
        _externalWriterMode ||
        _guardianReadOnly ||
        _historySyncing ||
        _showingCachedHistory ||
        _restoringSettings ||
        _reconnecting ||
        _connectionLost ||
        _streaming ||
        _sending ||
        _awaitingTurnStart) {
      return false;
    }
    final last = _items.where((i) => i.type != 'turnDuration').lastOrNull;
    return identical(last, error);
  }

  /// The message of the exact prompt [error] answered: the host's message
  /// with that ID, else the optimistic copy sent here that opened that turn
  /// (a supplement sent here has no such copy, so it is not guessed).
  TranscriptItem? _failedPrompt(TranscriptItem error) {
    final failure = ModelFailure.parse(error.text);
    final prompt = failure.turnId.isNotEmpty ? failure.turnId : error.turnId;
    if (prompt.isEmpty) return null;
    return _items.where((i) => i.isUser && i.id == prompt).firstOrNull ??
        _items
            .where(
              (i) =>
                  i.isUser &&
                  i.id.startsWith('local-user-') &&
                  i.turnId == prompt,
            )
            .firstOrNull;
  }

  /// Whether [prompt] is here exactly as it was sent: the host marked
  /// nothing of it omitted (`#input:<id>` truncated text,
  /// `#attachments:<id>` dropped files) and every image is inline data.
  bool _resendable(TranscriptItem prompt) =>
      !_items.any(
        (i) =>
            i.type == 'contentOmitted' &&
            (i.id == '#input:${prompt.id}' ||
                i.id == '#attachments:${prompt.id}'),
      ) &&
      prompt.imageUrls.every((url) => url.startsWith('data:image/'));

  /// Send a failed turn's message again as a new turn, with whatever model
  /// is selected now. The composer's draft and attachments are untouched,
  /// and the user's Retry is the go-ahead for a queue the failure paused.
  void _retryFailedTurn(TranscriptItem error) {
    if (_savingAgentConfig || !_isCurrentFailure(error)) return;
    final prompt = _failedPrompt(error);
    if (prompt == null || !_resendable(prompt)) return;
    _updateState(() => _draft.queuePaused = false);
    unawaited(
      _send(
        failedTurn: _Resend(text: prompt.text, images: prompt.imageUrls),
      ),
    );
  }

  /// The session's model option, where the agent's options replace the
  /// model menu and may be changed now.
  SessionConfigOption? get _failureModelOption => _agentControlsEnabled
      ? _agentSettings?.configOptions
            .where((o) => o.category == 'model' && o.values.isNotEmpty)
            .firstOrNull
      : null;

  /// Open the session's own model selection; choosing sends nothing.
  Future<void> _changeModelAfterFailure() async {
    final option = _failureModelOption;
    // Bound now, like the composer's chip: a choice answers to the
    // conversation it was opened for.
    final target = _agentTarget();
    if (option == null) return;
    final value = await showOptionPicker(context, option);
    if (value == null || value == option.currentValue || !mounted) return;
    await _setAgentConfig(target, option.id, value);
  }

  /// Whether a dispatched turn/start failed with one of the agent host's own
  /// refusals, each given before a turn is admitted. Every other failure —
  /// a lost request or answer, a timeout, any phrasing not listed here —
  /// leaves open whether the turn was admitted.
  bool _definitelyRefused(String msg) {
    final m = msg.toLowerCase();
    return const [
      'the agent is not running',
      'the agent host changed',
      'unknown session',
      'a turn is already running in this session',
      'the session is still loading',
      'too many sessions are busy',
      'too many pending operations',
      'invalid request:',
    ].any(m.startsWith);
  }

  /// Whether an error message looks like the app-server connection dropped, so
  /// the banner can offer "reconnect" (which re-establishes the session) rather
  /// than a plain retry that would hit the same dead connection.
  bool _looksDisconnected(String msg) {
    final m = msg.toLowerCase();
    return m.contains('connection closed') ||
        m.contains('closed connection') ||
        m.contains('not connected');
  }
}
