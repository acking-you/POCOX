part of '../settings_screen.dart';

// What a root row reports. Each watches only what it shows, so a polled list
// rebuilds its own value and never the page.

/// Which way this device reaches others.
class _ConnectionPathValue extends ConsumerWidget {
  const _ConnectionPathValue();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final path = ref.watch(relayPreferencesProvider).valueOrNull?.path;
    return Text(switch (path) {
      null => '',
      ConnectionPath.relayOnly => l10n.connectionPathRelayOnly,
      _ => l10n.connectionPathAuto,
    });
  }
}

/// How many conversation services stay connected.
class _ConnectionWindowValue extends ConsumerWidget {
  const _ConnectionWindowValue();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final capacity = ref
        .watch(connectionWindowPreferencesProvider)
        .valueOrNull
        ?.capacity;
    return Text(
      capacity == null
          ? ''
          : AppLocalizations.of(context).connectionWindowServices(capacity),
    );
  }
}

/// The proxy in use.
class _NetworkProxyValue extends ConsumerWidget {
  const _NetworkProxyValue();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setting = ref.watch(networkProxyProvider).valueOrNull;
    return Text(
      setting == null
          ? ''
          : networkProxyShort(AppLocalizations.of(context), setting),
    );
  }
}

/// How many subscriptions there are.
class _SubscriptionCount extends ConsumerWidget {
  const _SubscriptionCount();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(
      liveSubscriptionsProvider.select((subs) => subs.valueOrNull?.length),
    );
    return Text(
      count == null ? '' : '$count',
      style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
    );
  }
}

/// The running version and, while one is on offer, the newer release.
class _UpdateValueRow extends ConsumerWidget {
  const _UpdateValueRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state =
        ref.watch(updateStateProvider).valueOrNull ??
        ref.read(updateApiProvider).updateState();
    return SettingValueRow(
      key: const Key('settings-about-row'),
      label: l10n.updateVersion(state.current),
      value: state.newer
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StatusDot(
                  color: Theme.of(context).colorScheme.onSurface,
                  size: 7,
                ),
                const SizedBox(width: 6),
                Flexible(child: Text(l10n.pocketUpdateAvailable)),
              ],
            )
          : null,
      onTap: onTap,
    );
  }
}

/// Each subscription with its live path; a row opens its details. Watching the
/// polled list here rebuilds this group, never the whole page.
class _SubscriptionsGroup extends ConsumerWidget {
  const _SubscriptionsGroup();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final subs =
        ref.watch(liveSubscriptionsProvider).valueOrNull ?? const <SubInfo>[];
    // The section's name, then one group per device it reaches.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (subs.isEmpty)
          GroupCard(
            title: l10n.activeSubscriptions,
            children: [SettingValueRow(label: l10n.none, chevron: false)],
          ),
        for (final (:device, :subs) in subscriptionsByDevice(subs))
          GroupCard(
            key: ValueKey('subscriptions-$device'),
            title: '${l10n.activeSubscriptions} · ${deviceLabel(device)}',
            children: [
              for (final sub in subs)
                SettingValueRow(
                  key: ValueKey('subscription-${sub.key}'),
                  label: subscriptionTitle(sub.key),
                  value: TunnelPathChip(sub),
                  onTap: () => showTunnelDetails(context, sub.key),
                ),
            ],
          ),
      ],
    );
  }
}

class _DangerRow extends StatelessWidget {
  const _DangerRow({required this.onPressed, required this.title});

  final VoidCallback onPressed;
  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
      child: Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton.icon(
          key: const Key('sign-out-btn'),
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: scheme.error,
            side: BorderSide(color: scheme.error),
          ),
          icon: const Icon(AppIcons.logout, size: 17),
          label: Text(title),
        ),
      ),
    );
  }
}
