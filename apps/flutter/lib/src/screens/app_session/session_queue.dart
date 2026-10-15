part of '../app_session_screen.dart';

extension _SessionQueue on _AppSessionState {
  // Messages composed while a turn was already in flight. They queue instead of
  // racing the running turn and each flushes as its own turn once the prior one
  // ends (codex-cli parity). Esc pops the most recent back into the composer.
  List<_Queued> get _queue => _draft.queue;

  /// The user's explicit Retry of a queued message whose send may already
  /// have reached the host. Nothing can prove it did not (the protocol has
  /// no request identity, and history is bounded and shared with other
  /// writers), so it is never resolved or sent by itself: this is the one
  /// way it is sent again, exactly as queued (text and attachments) and
  /// still first in line. Synchronous: it acts only on the head of the
  /// shown conversation's queue while nothing else is being sent.
  void _resendUncertain(_Queued entry) {
    if (!mounted ||
        _queue.isEmpty ||
        !identical(_queue.first, entry) ||
        !entry.uncertain ||
        entry.inFlight ||
        _sending ||
        _connectionLost ||
        _reconnecting) {
      return;
    }
    _updateState(() {
      entry.uncertain = false;
      _draft.queuePaused = false;
      _error = null;
      _retry = null;
    });
    _saveDraft();
    _maybeFlushQueue();
  }

  /// Carry out the plan the model just produced: leave plan mode and start a
  /// normal turn instructing the agent to implement it. The instruction is
  /// shown as a user message so the transcript stays honest about what was sent.
  Future<void> _implement() async {
    final prompt = AppLocalizations.of(context).implementPlanPrompt;
    _updateState(() {
      _plan = false;
      _implementDismissed = false;
    });
    await _send(overrideText: prompt);
  }

  Future<void> _interrupt() async {
    if (_threadId == null) return;
    // Arm the marker; the turn's end event renders it. Cleared if the request
    // itself fails (no turn was actually stopped).
    _updateState(() => _pendingInterrupt = true);
    try {
      await ref
          .read(bridgeApiProvider)
          .appTurnInterrupt(widget.serviceKey, _threadId!, turnId: _turnId);
    } catch (e) {
      if (mounted) {
        _updateState(() {
          _pendingInterrupt = false;
          _error = friendlyError(e);
        });
      }
    }
  }

  // ── Send / queue / Esc state machine (codex-cli parity) ──────────────────
  //
  // Composer submit routes through _submit: while a turn is in flight the
  // message QUEUES (fires as its own turn once the running one ends) instead of
  // racing it. Esc is context-sensitive (see _onEscape):
  //   • queue non-empty         → pop the most recent queued message to the box
  //   • running, no output yet  → undo the send (interrupt + restore the text)
  //   • running, output started → interrupt the turn (stopped marker)

  /// Composer send: queue while a turn is in flight (or a backlog is still
  /// draining), otherwise send now.
  void _submit() {
    if (_externalWriterMode ||
        _historySyncing ||
        _restoringSettings ||
        _showingCachedHistory ||
        _reconnecting ||
        _connectionLost ||
        // The draft stays in the composer until the model change is saved.
        _savingAgentConfig) {
      return;
    }
    if (_supplement && _streaming && _caps.steer) {
      unawaited(_sendSupplement());
      return;
    }
    if (_streaming || _sending || _awaitingTurnStart || _queue.isNotEmpty) {
      _enqueue();
      // Sending again is the user's go-ahead for a paused queue.
      _draft.queuePaused = false;
      // Idle with a residual backlog (e.g. a flush skipped during a reconnect):
      // drain it now so nothing stays stuck.
      if (!_streaming && !_sending) _maybeFlushQueue();
    } else {
      _send();
    }
  }

  /// A queued message held by a failed send keeps its explicit recovery:
  /// when the banner that offered its Retry was cleared (a reload,
  /// reconnect or reopening clears the banner), it is offered again —
  /// unless another notice is shown. Nothing is sent from here. Otherwise a
  /// held unknown-outcome notice ([_heldNotice]) of this conversation is
  /// shown again, while no newer operation began.
  void _offerHeldQueue() {
    if (!mounted || _error != null) return;
    final head = _queue.firstOrNull;
    final failure = head?.failure;
    if (head == null ||
        failure == null ||
        head.inFlight ||
        !_draft.queuePaused) {
      final held = _heldNotice;
      if (held == null) return;
      if (held.op != _composerOp) {
        _heldNotice = null;
        return;
      }
      if (identical(held.draft, _draft) && held.threadId == _threadId) {
        _updateState(() {
          _error = held.text;
          _retry = null;
        });
      }
      return;
    }
    final l10n = AppLocalizations.of(context);
    _updateState(() {
      _error = head.uncertain
          ? '$failure\n${l10n.queuedUncertainRetry}'
          : failure;
      _retry = head.uncertain ? () => _resendUncertain(head) : _resumeQueue;
    });
  }

  /// Retry of a refused queued message: resume the queue from its head.
  void _resumeQueue() {
    _updateState(() {
      _draft.queuePaused = false;
      _error = null;
      _retry = null;
    });
    _maybeFlushQueue();
  }

  /// Snapshot the composer (text + its ready attachments) into the queue and
  /// clear it. A no-op for an empty draft or while an attachment is still
  /// processing (the message would ship without it).
  void _enqueue() {
    final atts = List<_Attachment>.from(_attachments);
    if (_input.text.trim().isEmpty && atts.isEmpty) return;
    if (atts.any((a) => !a.ready)) return;
    _updateState(() {
      _queue.add(
        _Queued(
          id: _drafts.nextQueueId++,
          text: _input.text,
          attachments: atts,
        ),
      );
      _attachments.clear();
      _input.clear();
      _saveDraft();
    });
  }

  /// Send the head of the queue as a new turn, if the session is idle. Called on
  /// every turn end (and after a reconnect). Send its captured attachments and
  /// text without replacing a newer draft still in the composer.
  void _maybeFlushQueue() {
    if (_externalWriterMode ||
        _queue.isEmpty ||
        _draft.queuePaused ||
        _queue.first.inFlight ||
        // Only the user's explicit Retry sends it again (see
        // [_resendUncertain]); nothing here asks the host about it.
        _queue.first.uncertain ||
        _streaming ||
        _sending ||
        _awaitingTurnStart ||
        _reconnecting ||
        _connectionLost ||
        _historySyncing ||
        _restoringSettings ||
        _showingCachedHistory ||
        _savingAgentConfig) {
      return;
    }
    unawaited(_send(queued: _queue.first));
  }

  /// Esc handling. Returns true when it acted (so the key is consumed).
  bool _onEscape() {
    // 1. A queued message is the most recent thing the user did — hand the last
    //    one back to the composer before touching the running turn.
    if (_queue.any((q) => !q.inFlight)) {
      _dequeueLast();
      return true;
    }
    // 2. A turn is running.
    if (_streaming) {
      if (_outputStarted) {
        unawaited(_interrupt()); // already replying → stop it (stopped marker)
      } else {
        _undoSend(); // nothing back yet → take the send back into the composer
      }
      return true;
    }
    // 3. Nothing to interrupt or dequeue — let the key through.
    return false;
  }

  /// Pop the most recently queued message back into the composer (Esc).
  void _dequeueLast() {
    final last = _queue.where((q) => !q.inFlight).lastOrNull;
    if (last != null) _restoreQueued(last);
  }

  /// Take a queued message out of the queue and back into the composer so the
  /// user can edit/resend it (Esc, or tapping its chip), preserving newer input.
  void _restoreQueued(_Queued q) {
    // One being sent belongs to its send now.
    if (q.inFlight) return;
    _updateState(() => _queue.removeWhere((e) => e.id == q.id));
    _restoreDraft(q.text, q.attachments);
  }

  void _restoreDraft(
    String text,
    List<_Attachment> attachments, {
    _ComposerDraft? into,
  }) {
    final draft = into ?? _draft;
    final current = draft.value.text;
    final restored = text.isEmpty
        ? current
        : current.isEmpty
        ? text
        : '$text\n\n$current';
    draft.value = TextEditingValue(
      text: restored,
      selection: TextSelection.collapsed(offset: restored.length),
    );
    final ids = draft.attachments.map((a) => a.id).toSet();
    draft.attachments.insertAll(
      0,
      attachments.where((a) => ids.add(a.id)).toList(),
    );
    _drafts.save(draft, changed: true);
    if (mounted && identical(_draft, draft)) {
      _input.value = draft.value;
      _inputFocus.requestFocus();
    }
  }

  /// Discard a specific queued message (the ✕ on its chip). Unlike Esc, this
  /// drops it rather than restoring it — the user explicitly removed it.
  void _discardQueued(int id) {
    _updateState(() => _queue.removeWhere((q) => q.id == id && !q.inFlight));
    _saveDraft();
  }

  /// Esc "undo" for a turn that hasn't produced output yet: interrupt it and
  /// drop the just-sent text back into the composer, taking the send back. The
  /// server may still record an aborted turn (accepted — it surfaces on reload),
  /// but live the optimistic bubble is removed so it reads as un-sent.
  void _undoSend() {
    final restore = _undoableDraft;
    _updateState(() {
      _undoableDraft = null;
      _removeLastLocalUserBubble();
      // This interrupt is an undo: suppress the "stopped" marker its turn-end
      // would otherwise add.
      _suppressStopMarker = true;
    });
    unawaited(_interrupt());
    if (restore != null) _restoreDraft(restore.text, restore.attachments);
    _inputFocus.requestFocus();
  }

  /// Remove the newest optimistic user bubble (id `local-user-*`) — the one the
  /// undone send added. Call inside a _updateState; rebuilds the id→index map.
  void _removeLastLocalUserBubble() {
    for (var i = _items.length - 1; i >= 0; i--) {
      if (_items[i].type == 'userMessage' &&
          _items[i].id.startsWith('local-user-')) {
        _items.removeAt(i);
        _rebuildItemIndex();
        return;
      }
    }
  }

  /// Rebuild `_itemIndex` from `_items` after a mid-list removal.
  void _rebuildItemIndex() {
    _itemIndex.clear();
    for (var i = 0; i < _items.length; i++) {
      _itemIndex[_items[i].id] = i;
    }
  }

  /// Append a local "stopped" marker so an interrupted turn is visible in the
  /// transcript. Local-only (not persisted); call inside a `_updateState`. An Esc
  /// "undo" interrupt suppresses the marker — the send is being taken back into
  /// the composer, not shown as a stopped turn.
  /// A host that reports the stop itself (an `interrupted` item of [turn])
  /// gets no second marker.
  void _addStoppedMarker(String turn) {
    _pendingInterrupt = false;
    if (_suppressStopMarker) {
      _suppressStopMarker = false;
      return;
    }
    if (turn.isNotEmpty &&
        _items.any((i) => i.type == 'interrupted' && i.turnId == turn)) {
      return;
    }
    final id = 'local-stopped-${_localSeq++}';
    _itemIndex[id] = _items.length;
    _items.add(
      TranscriptItem(id: id, type: 'interrupted', text: '', turnId: turn),
    );
    _historyLiveItems?[id] = _items.last;
  }

  /// Horizontal strip of pending attachments above the composer input: a
  /// thumbnail (or a spinner while processing) with a remove button each.
  /// The pending-queue strip above the composer: messages the user sent while a
  /// turn was running, each shown as a chip (with a ✕ to discard). A caption
  /// explains they'll send next and that Esc pulls the last one back.
  Widget _queuedStrip(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.schedule, size: 13, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                '${l10n.queuedCount(_queue.length)} · '
                '${_draft.queuePaused ? l10n.queuedPausedHint : l10n.queuedHint}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final q in _queue)
              Container(
                key: Key('queued-${q.id}'),
                constraints: const BoxConstraints(maxWidth: 260),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(kPanelRadius),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (q.uncertain)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Tooltip(
                          message: l10n.queuedUncertain,
                          child: Icon(
                            Icons.help_outline,
                            key: Key('queued-uncertain-${q.id}'),
                            size: 14,
                            color: scheme.onSurfaceVariant,
                            semanticLabel: l10n.queuedUncertain,
                          ),
                        ),
                      ),
                    Flexible(
                      // Tapping a chip pulls it back into the composer to edit —
                      // the recover path on mobile, where there's no Esc.
                      child: InkWell(
                        mouseCursor: clickable,
                        onTap: () => _restoreQueued(q),
                        child: Text(
                          q.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Tooltip(
                      message: l10n.removeQueued,
                      child: InkWell(
                        mouseCursor: clickable,
                        key: Key('queued-remove-${q.id}'),
                        onTap: () => _discardQueued(q.id),
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            Icons.close,
                            size: 15,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}
