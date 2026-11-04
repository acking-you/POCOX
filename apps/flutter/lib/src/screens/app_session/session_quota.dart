part of '../app_session_screen.dart';

extension _SessionQuota on _AppSessionState {
  /// Read the account quota into [_rate]. Called once per connection (see
  /// [_subscribe]) so the numbers are already there whenever the user looks;
  /// `account/rateLimits/updated` keeps them current afterwards.
  Future<void> _loadQuota() async {
    if (!_caps.rateLimits) return;
    try {
      final raw = await ref
          .read(bridgeApiProvider)
          .appRateLimits(widget.serviceKey)
          // Bounded: this runs on the open path, and an app-server that never
          // answers must not be able to wedge a surface waiting on it.
          .timeout(const Duration(seconds: 8));
      final r = RateLimits.fromRaw(raw);
      if (r != null && mounted) {
        _updateState(() => _rate = r);
        _quotaRev.value++;
      }
    } catch (_) {
      // Quota is optional (a custom provider may not report one, and an
      // unreachable host times out); every surface that shows it degrades to
      // "unavailable" rather than blocking. No retry of its own is needed: a
      // successful listing re-fetches it (see `_loadThreads`), and that listing
      // now retries — so the quota rides along.
    }
  }

  /// Open the context/quota detail sheet (tap on desktop and mobile). Opens
  /// immediately and fills in: the quota is normally already warm, and when it
  /// isn't, a panel that appears now and updates beats a tap that hangs.
  Future<void> _showContextDetail() async {
    if (_rate == null) unawaited(_loadQuota());
    await showAdaptivePanel<void>(
      context: context,
      anchored: true,
      // Rebuilt on every quota change, so a fetch that lands while the panel
      // is open fills the bars in place.
      builder: (c) => ValueListenableBuilder<int>(
        valueListenable: _quotaRev,
        builder: (c2, _, _) => _usageDetail(AppLocalizations.of(c2)),
      ),
    );
  }

  /// Detail-sheet body: context occupancy + 5h / weekly quota bars.
  Widget _usageDetail(AppLocalizations l10n) {
    final text = Theme.of(context).textTheme;
    final ctx = _ctx;
    return SafeArea(
      // Token counts and reset times are numbers people copy into notes.
      child: SelectionArea(
        child: Padding(
          // The panel owns the top inset (a drag handle on a sheet, breathing
          // room in a dialog), so this only sets the sides and the base.
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.contextUsageTitle, style: text.titleMedium),
              const SizedBox(height: 16),
              if (ctx != null)
                _quotaRow(
                  l10n.contextLabel,
                  ctx.fraction,
                  '${formatTokenCount(ctx.tokensUsed)} / ${formatTokenCount(ctx.contextWindow)}',
                ),
              if (_rate?.primary != null)
                _quotaRow(
                  l10n.quota5h,
                  _rate!.primary!.fraction,
                  '${_rate!.primary!.usedPercent.round()}%',
                  reset: _resetText(_rate!.primary!, l10n),
                ),
              if (_rate?.secondary != null)
                _quotaRow(
                  l10n.quotaWeekly,
                  _rate!.secondary!.fraction,
                  '${_rate!.secondary!.usedPercent.round()}%',
                  reset: _resetText(_rate!.secondary!, l10n),
                ),
              if (_rate == null && _caps.rateLimits)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    l10n.quotaUnavailable,
                    style: text.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// One labelled progress row: label + value on top, a bar, optional reset.
  Widget _quotaRow(
    String label,
    double fraction,
    String value, {
    String? reset,
  }) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: text.bodyMedium)),
              Text(value, style: text.bodySmall),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 7,
              backgroundColor: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest,
            ),
          ),
          if (reset != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                reset,
                style: text.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Human "resets in 2h 15m" text for a quota window, or empty if unknown.
  String _resetText(RateLimitWindow w, AppLocalizations l10n) {
    Duration? remaining;
    if (w.resetsInSeconds != null) {
      remaining = Duration(seconds: w.resetsInSeconds!);
    } else if (w.resetsAtEpochMs != null) {
      final ms = w.resetsAtEpochMs! - DateTime.now().millisecondsSinceEpoch;
      if (ms > 0) remaining = Duration(milliseconds: ms);
    }
    if (remaining == null) return '';
    final h = remaining.inHours, m = remaining.inMinutes % 60;
    final span = h > 0 ? '${h}h ${m}m' : '${m}m';
    return l10n.resetsIn(span);
  }

  /// How much account quota is left, on the window closest to running out:
  /// whichever is furthest along is the one that will actually stop the user.
  /// Null when the host reports no quota at all (a custom provider).
  ({String label, RateLimitWindow window, int left})? _tightestQuota(
    AppLocalizations l10n,
  ) {
    final r = _rate;
    if (r == null) return null;
    final windows = [
      if (r.primary != null) (l10n.quota5h, r.primary!),
      if (r.secondary != null) (l10n.quotaWeekly, r.secondary!),
    ]..sort((a, b) => b.$2.usedPercent.compareTo(a.$2.usedPercent));
    if (windows.isEmpty) return null;
    final (label, window) = windows.first;
    return (
      label: label,
      window: window,
      left: (100 - window.usedPercent).clamp(0, 100).round(),
    );
  }
}
