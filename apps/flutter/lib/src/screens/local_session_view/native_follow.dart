part of '../local_session_view_screen.dart';

extension _NativeFollow on _LocalSessionViewState {
  /// Follow the native source through the bridge: a revision on every live
  /// change (a Grok terminal client's session through Grok's leader) and at
  /// least every few seconds.
  void _startNativeFollow() {
    unawaited(_follow?.cancel());
    _follow = ref
        .read(bridgeApiProvider)
        .appNativeSessionFollow(
          _source.provider,
          widget.threadId,
          sourceId: _native.sourceId,
        )
        .listen(_onNativeRevision, onError: _onNativeFollowError);
  }

  /// Follow only while this view is in the foreground and the visible
  /// route: a hidden view reads nothing and, for Grok, keeps no leader
  /// connection open. Visible again, it follows again.
  void _syncNativeFollow() {
    if (!_source.isNative) return;
    final visible = _foreground && _onTop;
    if (visible && _follow == null) {
      _startNativeFollow();
    } else if (!visible && _follow != null) {
      unawaited(_follow!.cancel());
      _follow = null;
      _pendingRevision = null;
    }
  }

  void _onNativeRevision(NativeSessionRevision revision) {
    if (!mounted || !_foreground || !_onTop) return;
    // A change during a read is applied right after it.
    if (_reading) {
      _pendingRevision = revision;
      return;
    }
    _loadNative(initial: false, known: revision);
  }

  void _onNativeFollowError(Object e) {
    if (!mounted || _reading) return;
    _update(() {
      _loading = false;
      _error = friendlyError(e);
    });
  }

  Future<void> _loadNative({
    required bool initial,
    NativeSessionRevision? known,
  }) async {
    if (_reading && !initial) return;
    _reading = true;
    final epoch = ++_loadEpoch;
    final provider = _source.provider;
    final thread = widget.threadId;
    final api = ref.read(bridgeApiProvider);
    bool current() => mounted && epoch == _loadEpoch;
    if (initial) {
      _native.clear();
      _loadingOlder = false;
      _update(() {
        _loading = true;
        _error = null;
        _items = const [];
      });
    }
    try {
      final revision =
          known ??
          await api.appNativeSessionRevision(
            provider,
            thread,
            sourceId: _native.sourceId,
          );
      if (!current()) return;
      final changed =
          revision.generation != _native.generation ||
          revision.revision != _native.revision ||
          revision.sourceId != _native.sourceId;
      final page = changed
          ? await api.appNativeSessionPage(
              provider,
              thread,
              sourceId: revision.sourceId,
            )
          : null;
      if (!current()) return;
      final atBottom = _atBottom;
      _update(() {
        if (page != null) {
          _native.tail(page);
          _showNative();
        }
        _live = revision.liveness;
        _loading = false;
        _error = null;
      });
      if (page != null && atBottom) _followTail(current);
    } catch (e) {
      if (current()) {
        _update(() {
          _loading = false;
          _error = friendlyError(e);
        });
      }
    } finally {
      if (epoch == _loadEpoch) {
        _reading = false;
        _applyPending();
      }
    }
  }

  Future<void> _loadOlder() async {
    if (_reading || _native.nextBefore == null) return;
    final epoch = ++_loadEpoch;
    final before = _native.nextBefore;
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    final extent = _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
    _reading = true;
    _update(() {
      _loadingOlder = true;
      _error = null;
    });
    bool current() => mounted && epoch == _loadEpoch;
    try {
      final page = await ref
          .read(bridgeApiProvider)
          .appNativeSessionPage(
            _source.provider,
            widget.threadId,
            before: before,
            sourceId: _native.sourceId,
          );
      if (!current()) return;
      if (page.nextBefore == before || !_native.prepend(page)) {
        throw StateError(
          'Local history changed; refresh before loading older messages',
        );
      }
      _update(_showNative);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (current() && _scroll.hasClients) {
          _scroll.jumpTo(
            (offset + _scroll.position.maxScrollExtent - extent).clamp(
              0.0,
              _scroll.position.maxScrollExtent,
            ),
          );
        }
      });
    } catch (e) {
      if (current()) _update(() => _error = friendlyError(e));
    } finally {
      if (current()) {
        _update(() {
          _reading = false;
          _loadingOlder = false;
        });
        _applyPending();
      }
    }
  }

  /// Apply a revision that arrived during the read that just ended.
  void _applyPending() {
    final pending = _pendingRevision;
    _pendingRevision = null;
    if (pending != null) _onNativeRevision(pending);
  }

  /// Show the native window's items, keeping only their resolved images.
  void _showNative() {
    _items = _native.items;
    final retained = _items.map((i) => i.id).toSet();
    _imageCache.removeWhere((id, _) => !retained.contains(id));
  }

  Widget _nativeControls(AppLocalizations l10n) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_live?.heldOpen != true)
          Text(
            l10n.nativeHistoryReadOnly,
            style: helpTextStyle(Theme.of(context)),
          ),
        if (_native.truncated)
          Text(
            l10n.nativeHistoryWindowHint,
            style: helpTextStyle(Theme.of(context)),
          ),
        if (_error != null && _items.isNotEmpty)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_native.nextBefore != null)
          TextButton.icon(
            key: const Key('native-history-older'),
            onPressed: _reading ? null : _loadOlder,
            icon: _loadingOlder
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(AppIcons.expand_less),
            label: Text(l10n.nativeHistoryLoadOlder),
          ),
      ],
    ),
  );
}
