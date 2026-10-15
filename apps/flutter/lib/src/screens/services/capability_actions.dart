part of '../services_screen.dart';

/// Whether text is scaled past 1.5×, where a row's trailing pills, status
/// and actions no longer fit beside its text.
bool _largeText(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(14) > 14 * 1.5;

/// [leading], the expanded [body] and [trailing] on one row; with large text,
/// or where the row is narrower than [stackBelow] (scaled with the text),
/// [trailing] goes under them instead, end-aligned and wrapping, so the body
/// keeps its width and nothing overflows.
Widget _rowOrStacked(
  BuildContext context, {
  required List<Widget> leading,
  required Widget body,
  required List<Widget> trailing,
  double stackBelow = 0,
}) {
  Widget inline() => Row(
    children: [
      ...leading,
      Expanded(child: body),
      ...trailing,
    ],
  );
  Widget stacked() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          ...leading,
          Expanded(child: body),
        ],
      ),
      if (trailing.isNotEmpty) ...[
        const SizedBox(height: 4),
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 4,
          children: trailing,
        ),
      ],
    ],
  );
  if (_largeText(context)) return stacked();
  if (stackBelow <= 0) return inline();
  final threshold = MediaQuery.textScalerOf(context).scale(stackBelow);
  return LayoutBuilder(
    builder: (context, constraints) =>
        constraints.maxWidth < threshold ? stacked() : inline(),
  );
}

class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({
    super.key,
    required this.icon,
    required this.title,
    required this.protocol,
    required this.actionLabel,
    required this.onAction,
    this.provider,
    this.providerName,
    this.profileId,
    this.status,
    this.reason,
    this.localAddr,
    this.menuKey,
    this.isDefault = false,
    this.onSetDefault,
    this.onDeregister,
    this.onReregister,
  });

  final IconData icon;
  final String title;
  final String protocol;
  final String actionLabel;
  final VoidCallback onAction;

  /// The session provider (`codex` / `acp`) to badge, or null for rows
  /// that are not a chat host.
  final String? provider;

  /// Agent name for ACP badges, when this device hosts the service.
  final String? providerName;

  /// ACP profile id of a local host, for its mark.
  final String? profileId;
  final Widget? status;

  /// Why this capability is unavailable, when it is. A bare "unreachable" leaves
  /// the user guessing whether the relay or the backend is at fault, so the
  /// status pill is followed by the explanation.
  final String? reason;

  /// Where this capability listens on this machine, for a device we host. Shown
  /// because it is what a user copies into another tool's config.
  final String? localAddr;

  /// Identifies THIS row's overflow. The title bar's page menu carries the same
  /// glyph, so a test reaching for "the overflow" has to say which row's.
  final Key? menuKey;

  final bool isDefault;
  final VoidCallback? onSetDefault;
  final VoidCallback? onDeregister;

  /// Publish a tunnel that was taken off the relay. Without this a deregistered
  /// capability would have no way back, which is why the tunnel list it replaces
  /// offered both.
  final VoidCallback? onReregister;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.fromLTRB(12, 8, 7, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: _rowOrStacked(
        context,
        // Default, status, the action and the overflow take ~260 px; below
        // this the title and provider would be squeezed to a fragment
        // beside them (every phone width).
        stackBelow: 440,
        leading: [
          IconBadge(icon: icon, size: 36, accent: true),
          const SizedBox(width: 11),
        ],
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // The provider badge follows the title, or goes under it where
            // both do not fit, so neither is cut to a fragment.
            Wrap(
              spacing: 6,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (provider != null)
                  ProviderBadge(
                    provider: provider!,
                    name: providerName,
                    profileId: profileId,
                  ),
              ],
            ),
            // One rich line rather than a Row, so a long address ellipsises
            // with the protocol instead of overflowing the row.
            Text.rich(
              TextSpan(
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                children: [
                  TextSpan(text: protocol),
                  if (localAddr != null) ...[
                    TextSpan(
                      text: '  ·  ',
                      style: TextStyle(color: onSurfaceMuted(scheme)),
                    ),
                    TextSpan(
                      text: localAddr,
                      style: const TextStyle(
                        fontFamily: monoFontFamily,
                        fontFamilyFallback: monoCjkFallback,
                      ),
                    ),
                  ],
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (reason != null) ...[
              const SizedBox(height: 3),
              Text(
                reason!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.error,
                  height: 1.35,
                ),
              ),
            ],
          ],
        ),
        trailing: [
          // Two trailing columns — status, then one action — so the rows line up
          // instead of each ending at a different place. Everything occasional
          // (set default, deregister, re-register) lives in the overflow.
          if (isDefault) ...[
            _CountPill(label: l10n.servicesDefault, accent: true),
            const SizedBox(width: 8),
          ],
          if (status != null) ...[status!, const SizedBox(width: 6)],
          // The action and its overflow wrap together, never apart.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(onPressed: onAction, child: Text(actionLabel)),
              if (_overflow.isNotEmpty)
                PopupMenuButton<VoidCallback>(
                  key: menuKey,
                  tooltip: l10n.moreActions,
                  icon: const Icon(Icons.more_horiz),
                  onSelected: (action) => action(),
                  itemBuilder: (_) => [
                    for (final item in _overflow)
                      PopupMenuItem<VoidCallback>(
                        value: item.action,
                        child: Text(
                          item.label(l10n),
                          style: item.danger
                              ? TextStyle(color: scheme.error)
                              : null,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// The occasional actions, in the order they belong: make this the default,
  /// bring a dropped tunnel back, take one off the relay.
  List<_RowAction> get _overflow => [
    if (!isDefault && onSetDefault != null)
      _RowAction((l) => l.servicesSetDefault, onSetDefault!),
    if (onReregister != null) _RowAction((l) => l.reregister, onReregister!),
    if (onDeregister != null)
      _RowAction((l) => l.deregister, onDeregister!, danger: true),
  ];
}

/// One entry of a capability row's overflow menu. The label is resolved late so
/// the list can be built where no `l10n` is in hand.
class _RowAction {
  const _RowAction(this.label, this.action, {this.danger = false});

  final String Function(AppLocalizations) label;
  final VoidCallback action;
  final bool danger;
}

class _CountPill extends StatelessWidget {
  const _CountPill({required this.label, this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: accent ? scheme.primaryContainer : scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: accent ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          fontWeight: accent ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
    );
  }
}

/// The Sessions tab: pick a connected host, then browse that host's CODEX_HOME
/// sessions over its meta tunnel (loopback when this app hosts it, broker when
/// remote). Read-only transcripts + force-resume per session, via an embedded
/// [LocalSessionsScreen] in remote mode.
Future<void> _batchRemove(
  BuildContext context,
  WidgetRef ref,
  List<ServiceEntry> entries,
) async {
  final l10n = AppLocalizations.of(context);
  final scheme = Theme.of(context).colorScheme;
  if (entries.isEmpty) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      key: const Key('batch-remove-dialog'),
      title: Text(l10n.batchRemoveTitle),
      content: Text(l10n.batchRemoveWarning(entries.length)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('batch-remove-confirm-btn'),
          style: FilledButton.styleFrom(backgroundColor: scheme.error),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.remove),
        ),
      ],
    ),
  );
  if (ok != true) return;
  final dismiss = ref.read(dismissedServicesProvider.notifier);
  final bridge = ref.read(bridgeApiProvider);
  var removed = 0;
  for (final s in entries) {
    // Re-check reachability at confirm time (probes refresh every 15s): a key
    // that recovered while the dialog was open must not be dismissed — that
    // would strand a live service off the list.
    final reachableNow =
        (isSessionKind(s.kind)
                ? ref.read(appReachableProvider(s.key))
                : ref.read(apiReachableProvider(s.key)))
            .valueOrNull ==
        true;
    if (reachableNow) continue;
    dismiss.dismiss(s.key);
    removed++;
    try {
      await bridge.accountDeregisterService(
        device: s.device,
        kind: s.kind,
        name: s.name,
      );
    } catch (_) {
      // Best-effort — the entry is already hidden from the list.
    }
  }
  // Refresh discovery so the list reflects the removals.
  ref.invalidate(servicesProvider);
  if (context.mounted && removed > 0) {
    showToastOk(context, l10n.batchRemovedSnack(removed));
  }
}

/// Point the chat at [serviceKey] and return to it.
///
/// Replaces the `/app/:key` project picker this used to push. That page listed
/// the service's projects and conversations — exactly what the chat's sidebar
/// already shows, one level deeper and without the conversation beside it. The
/// request is handed over through [requestedServiceProvider] because the switch
/// happens on the other side of the route change.
void _openInChat(BuildContext context, WidgetRef ref, String serviceKey) {
  ref.read(requestedServiceProvider.notifier).state = serviceKey;
  // `go`, not `pop`: this page may have been opened directly (deep link, page
  // menu) with no chat underneath to return to.
  context.go('/');
}

/// Publish one of a hosted server's tunnels back onto the relay after it was
/// taken off. Reached from the capability row's overflow, which is the only
/// route back for a tunnel the user deregistered.
Future<void> _reregisterTunnel(
  BuildContext context,
  WidgetRef ref, {
  required String hostName,
  required String kind,
}) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ToastMessenger.of(context);
  try {
    await ref
        .read(bridgeApiProvider)
        .appServeReregister(name: hostName, kind: kind);
  } catch (e) {
    // Surfaces a duplicate-name refusal (another live instance took the name
    // while this tunnel was down) as guidance instead of silence.
    final raw = friendlyError(e);
    messenger.error(isHostNameConflict(raw) ? l10n.hostNameConflict : raw);
    return;
  }
  ref.invalidate(localServeListProvider);
  ref.invalidate(servicesProvider);
}

/// Confirm, then take a service's tunnel off the relay. For one of *our* local
/// hosts ([localTunnel] set) this is a reversible unpublish — the codex / API
/// proxy keep running and the 本地托管 card can re-register it. For someone
/// else's service it asks the backend to force-drop the relay key (best-effort —
/// a still-running host re-registers). The key is hidden at once via
/// [pendingRemovalProvider].
///
/// [unreachable] marks a non-local entry whose backend isn't responding — an
/// orphaned/hollow registration lingering on the relay. The backend can't drop
/// such a key (nothing live holds it to cancel), so we ALSO durably dismiss it
/// via [dismissedServicesProvider], making "注销" actually remove it from this
/// device's list and keep it gone across restarts.
Future<void> _confirmDeregister(
  BuildContext context,
  WidgetRef ref,
  ServiceEntry s, {
  ({String name, String kind})? localTunnel,
  bool unreachable = false,
}) async {
  final l10n = AppLocalizations.of(context);
  final scheme = Theme.of(context).colorScheme;
  final isLocal = localTunnel != null;
  // A non-local entry that isn't responding is orphaned: use the honest
  // "remove from your list" wording instead of the "stop that host" wording,
  // which doesn't apply when no reachable host exists.
  final isOrphan = unreachable && !isLocal;
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      key: const Key('deregister-dialog'),
      title: Text(isOrphan ? l10n.deregisterOrphanTitle : l10n.deregisterTitle),
      content: Text(
        isLocal
            ? l10n.deregisterLocalWarning(s.name)
            : isOrphan
            ? l10n.deregisterOrphanWarning(s.name)
            : l10n.deregisterWarning(s.name),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('deregister-confirm-btn'),
          style: FilledButton.styleFrom(backgroundColor: scheme.error),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(isOrphan ? l10n.remove : l10n.deregister),
        ),
      ],
    ),
  );
  if (ok != true) return;
  try {
    if (localTunnel != null) {
      // Reversible: stop this tunnel's register task (codex/proxy keep running);
      // serve_deregister also best-effort force-drops the relay key. The row
      // must NOT be hidden — it is the only place the tunnel can be published
      // again. Refreshing the host list flips it to 已下架 on its own.
      await ref
          .read(bridgeApiProvider)
          .appServeDeregister(name: localTunnel.name, kind: localTunnel.kind);
      ref.invalidate(localServeListProvider);
    } else if (isOrphan) {
      // Orphaned/hollow: nothing live holds the relay key, so the backend can't
      // drop it. Durably dismiss it so it leaves this device's list and stays
      // gone; still best-effort ask the backend to drop it (swallow errors — the
      // dismissal already achieved the user-visible removal).
      //
      // Re-check reachability at confirm time: it may have recovered while the
      // dialog was open. If it's live again, don't hide it — only best-effort
      // drop — so a now-working service isn't stranded off the list.
      final reachableNow =
          (isSessionKind(s.kind)
                  ? ref.read(appReachableProvider(s.key))
                  : ref.read(apiReachableProvider(s.key)))
              .valueOrNull ==
          true;
      if (!reachableNow) {
        ref.read(dismissedServicesProvider.notifier).dismiss(s.key);
      }
      try {
        await ref
            .read(bridgeApiProvider)
            .accountDeregisterService(
              device: s.device,
              kind: s.kind,
              name: s.name,
            );
      } catch (_) {
        // Best-effort — the entry is already hidden from the list.
      }
    } else {
      // Someone else's LIVE service: best-effort ask the backend to drop the
      // relay key. Do NOT durably hide it — a still-running host re-registers
      // within seconds, and hiding would strand a live service off the list.
      await ref
          .read(bridgeApiProvider)
          .accountDeregisterService(
            device: s.device,
            kind: s.kind,
            name: s.name,
          );
    }
    ref.invalidate(servicesProvider);
  } catch (e) {
    if (context.mounted) {
      showToastError(context, '${l10n.deregisterFailed}: ${friendlyError(e)}');
    }
  }
}
