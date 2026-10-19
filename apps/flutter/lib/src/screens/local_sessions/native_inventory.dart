part of '../local_sessions_screen.dart';

extension _NativeInventory on _LocalSessionsState {
  Widget _providerBar(AppLocalizations l10n) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final provider in const [
              'codex',
              'claude',
              'grok',
              'opencode',
            ])
              ChoiceChip(
                key: Key('local-provider-$provider'),
                label: Text(nativeProviderName(provider)),
                selected: _provider == provider,
                onSelected: (_) {
                  if (_provider == provider) return;
                  _update(() {
                    _provider = provider;
                    _filter = _SessionViewFilter.all;
                    _expandedParents.clear();
                    _collapsedParents.clear();
                  });
                  _load();
                },
              ),
            // That native history is read directly, and read-only.
            if (_source.isNative)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: InfoTip(l10n.nativeLocalHistoryHint),
              ),
          ],
        ),
        if (_source.isNative && _location != null) ...[
          const SizedBox(height: 8),
          SelectableText(
            _location!,
            maxLines: 1,
            style: TextStyle(
              fontFamily: monoFontFamily,
              fontFamilyFallback: monoCjkFallback,
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    ),
  );

  Widget _inventoryFooter(AppLocalizations l10n) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_moreError != null)
          Text(
            _moreError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_nextCursor != null)
          TextButton.icon(
            key: const Key('native-inventory-more'),
            onPressed: _loadingMore ? null : _loadMore,
            icon: _loadingMore
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(AppIcons.expand_more),
            label: Text(l10n.nativeHistoryLoadMore),
          ),
      ],
    ),
  );

  Future<void> _loadMore() async {
    if (_loadingMore || _nextCursor == null) return;
    final epoch = _loadEpoch;
    final source = _source;
    final cursor = _nextCursor;
    final id = _sourceId;
    _update(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final page = await ref
          .read(bridgeApiProvider)
          .appNativeSessions(source.provider, cursor: cursor, sourceId: id);
      if (!mounted || epoch != _loadEpoch) return;
      if (page.sourceId != id || page.nextCursor == cursor) {
        throw StateError(
          'Local history source or cursor changed; refresh the list',
        );
      }
      final seen = _sessions.map((s) => s.threadId).toSet();
      _update(() {
        _sessions = [
          ..._sessions,
          ...page.sessions.where((s) => seen.add(s.threadId)),
        ];
        _nextCursor = page.nextCursor;
      });
    } catch (e) {
      if (mounted && epoch == _loadEpoch) {
        _update(() => _moreError = friendlyError(e));
      }
    } finally {
      if (mounted && epoch == _loadEpoch) _update(() => _loadingMore = false);
    }
  }
}
