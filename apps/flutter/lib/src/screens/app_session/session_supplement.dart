part of '../app_session_screen.dart';

extension _SessionSupplement on _AppSessionState {
  Future<void> _sendSupplement() async {
    final tid = _threadId;
    if (tid == null ||
        _externalWriterMode ||
        !_streaming ||
        _restoringSettings ||
        _savingAgentConfig ||
        _sending ||
        _attachments.any((a) => !a.ready)) {
      return;
    }
    final sendingDraft = _draft;
    final draft = _input.text;
    final attachments = List<_Attachment>.of(_attachments);
    if (draft.trim().isEmpty && attachments.isEmpty) return;
    final text = appendFileRefs(draft.trim(), [
      for (final attachment in attachments)
        if (attachment.isFile) ?attachment.hostPath,
    ]);
    final images = <String>[
      for (final attachment in attachments)
        if (!attachment.isFile) ?attachment.processed?.dataUrl,
    ];
    final turnId = _turnId;
    // The answer belongs to what asked: this service and host connection
    // (capabilities move with every host change or reconnect), this thread
    // view and its draft, and this request (leaving the conversation drops
    // it, so returning to the same thread does not revive it).
    final serviceKey = widget.serviceKey;
    final link = _linkEpoch;
    final hostGeneration = _caps.generation;
    final historyGeneration = _historyGeneration;
    final request = Object();
    _supplementRequest = request;
    bool visible() =>
        mounted &&
        _threadId == tid &&
        identical(_draft, sendingDraft) &&
        identical(_supplementRequest, request);
    // Not [_capsEpoch]: a reload re-reading the agent's options moves it
    // without any change of host.
    _updateState(() => _holdSend(request));
    // This operation's place in the composer's history: anything begun
    // after it (finished or not) owns the view from then on.
    final op = _composerOp;
    bool owned() =>
        visible() &&
        _composerOp == op &&
        widget.serviceKey == serviceKey &&
        _linkEpoch == link &&
        _caps.generation == hostGeneration &&
        !_connectionLost &&
        !_reconnecting;
    try {
      final outcome = await ref
          .read(bridgeApiProvider)
          .appTurnSupplement(serviceKey, tid, turnId, text, images: images);
      // Decided before anything is changed: an answer that no longer owns
      // its input leaves the draft, its attachments and the queue alone.
      if (!owned()) {
        _supplementAnswerStale(
          op,
          tid,
          sendingDraft,
          injected: outcome.injected,
        );
        return;
      }
      if (!outcome.injected) {
        _supplementNotConsumed(sendingDraft, draft, attachments);
        return;
      }
      final acceptedTurnId = outcome.turnId ?? turnId ?? '';
      _takeSupplemented(sendingDraft, draft, attachments);
      // A history read since the request may already hold the input; a
      // reload then shows it once instead of adding a second copy.
      final reload =
          _historyGeneration != historyGeneration || _historyLoad != null;
      _updateState(() {
        final item = TranscriptItem(
          id: 'local-user-${_localSeq++}',
          type: 'userMessage',
          text: text,
          images: resolveImageUrls(images),
          imageUrls: images,
          turnId: acceptedTurnId,
        );
        if (!reload) {
          if (_streaming && _turnId == turnId) _turnId = acceptedTurnId;
          _itemIndex[item.id] = _items.length;
          _items.add(item);
        }
        _supplement = false;
        _error = null;
        _retry = null;
      });
      if (reload) {
        unawaited(_resumeAndLoad());
      } else {
        _scrollToEnd(force: true);
      }
    } catch (error) {
      // A failure seen after the connection moved (or after a newer
      // operation began) proves nothing about what the host consumed: it
      // gets the unknown-outcome notice when nothing newer owns the view,
      // never "the turn ended".
      if (!owned()) {
        _supplementAnswerStale(op, tid, sendingDraft, injected: false);
        return;
      }
      final message = friendlyError(error);
      _updateState(() {
        // An answer that leaves the outcome open says so; otherwise a turn
        // that moved on explains why the draft is kept.
        _error =
            !message.contains('may or may not') &&
                (!_streaming || _turnId != turnId)
            ? AppLocalizations.of(context).steerTurnEnded
            : message;
        _retry = null;
      });
    } finally {
      // Only a request that still owns its view and connection lets the
      // queue continue; an obsolete one releases its own hold and no more.
      final flush = owned();
      if (mounted) {
        _updateState(() {
          _releaseSend(request);
          if (identical(_supplementRequest, request)) {
            _supplementRequest = null;
          }
        });
      }
      if (flush) _maybeFlushQueue();
    }
  }

  /// A supplement answer that no longer owns its input (the host or
  /// connection changed, the conversation was left, or a newer request took
  /// over): the draft, its attachments, the composer's mode and the queue
  /// stay exactly as they are, and nothing is sent in its place. Only when
  /// the same conversation shows the same draft and nothing newer (another
  /// supplement or send) owns that view does a notice say so; when the host
  /// reported the input added, a display-only refresh then shows what
  /// arrived — keeping the notice, settling no admission, draining nothing.
  void _supplementAnswerStale(
    int op,
    String threadId,
    _ComposerDraft sendingDraft, {
    required bool injected,
  }) {
    // Any operation begun after this one — pending or already finished —
    // owns the view: its mode, notice, Retry and lock stay as they are.
    if (!mounted ||
        _composerOp != op ||
        _threadId != threadId ||
        !identical(_draft, sendingDraft) ||
        sendingDraft.sendPending) {
      return;
    }
    final text = AppLocalizations.of(context).steerAnswerStale;
    _updateState(() {
      _error = text;
      _retry = null;
      _heldNotice = (
        draft: sendingDraft,
        threadId: threadId,
        op: op,
        text: text,
      );
    });
    // A reload already running, or a reconnect's, shows it anyway.
    if (injected && !_historySyncing && !_reconnecting && !_connectionLost) {
      unawaited(_resumeAndLoad(displayOnly: true));
    }
  }

  /// The input reached the host: take exactly what was sent out of its
  /// draft (the shown one) — the text only if it is unchanged, and the sent
  /// attachments — leaving anything added or edited since in place.
  void _takeSupplemented(
    _ComposerDraft sendingDraft,
    String draft,
    List<_Attachment> attachments,
  ) {
    if (_input.text == draft) {
      sendingDraft.value = TextEditingValue.empty;
      _input.value = sendingDraft.value;
    }
    sendingDraft.attachments.removeWhere(
      (a) => attachments.any((sent) => sent.id == a.id),
    );
    _drafts.save(sendingDraft, changed: true);
  }

  /// The turn ended before the supplement reached it, and nothing was
  /// consumed: the input becomes the next turn, ahead of anything already
  /// queued, and is sent once that turn's end is confirmed. Called only for
  /// an owned answer (see [_sendSupplement]); only an exactly unchanged
  /// input — the same text and the same attachments, none added, removed or
  /// replaced — is queued; anything else stays in the composer, untouched.
  void _supplementNotConsumed(
    _ComposerDraft sendingDraft,
    String draft,
    List<_Attachment> attachments,
  ) {
    final unchanged =
        _input.text == draft &&
        sendingDraft.attachments.length == attachments.length &&
        attachments.every(sendingDraft.attachments.contains);
    if (!unchanged) {
      _updateState(() {
        _supplement = false;
        _error = AppLocalizations.of(context).steerTurnEnded;
        _retry = null;
      });
      return;
    }
    sendingDraft.queue.insert(
      0,
      _Queued(id: _drafts.nextQueueId++, text: draft, attachments: attachments),
    );
    sendingDraft.value = TextEditingValue.empty;
    sendingDraft.attachments.removeWhere(attachments.contains);
    _drafts.save(sendingDraft, changed: true);
    _input.value = sendingDraft.value;
    _updateState(() => _supplement = false);
    showToast(context, AppLocalizations.of(context).steerQueuedAfterEnd);
  }
}
