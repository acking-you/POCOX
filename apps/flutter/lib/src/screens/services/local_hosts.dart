part of '../services_screen.dart';

/// Local hosting spawns a local `codex` binary + child processes — desktop only.
bool get _hostingSupported => isDesktop;

/// One locally-hosted host: a codex app-server + an in-app API proxy. The card
/// carries codex's liveness; each tunnel's publish state and its 注销 / 重新注册
/// live on the capability row it belongs to. Tapping this opens
/// [LocalHostDialog] for 停止托管 + details.
class _LocalHostCard extends ConsumerWidget {
  const _LocalHostCard({super.key, required this.host, this.row});

  final AppServeStatus host;

  /// The host's published chat service row, once it has one: the card then
  /// is that row (open, status, overflow) and no capability row repeats it.
  final Widget? row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final (chip, healthy) = _health(ref, AppLocalizations.of(context), scheme);
    final row = this.row;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      // A row of its card, not a plate inside it: the hover finds it. The
      // whole row opens the host editor (stop + details); the per-tunnel
      // buttons inside absorb their own taps.
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(kRowRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          mouseCursor: clickable,
          borderRadius: BorderRadius.circular(kRowRadius),
          onTap: () => showHostingEditor(context, existing: host),
          child: row == null
              ? _summary(context, scheme, chip)
              : _HostStatus(chip: healthy ? null : chip, child: row),
        ),
      ),
    );
  }

  /// Honest host health, and whether it answers. `host.alive` is only
  /// port-open (the listener bound), which stays true even when the embedded
  /// codex has wedged / gone half-open (still accept()ing but never answering
  /// RPC) — a false "hosting". So once the listener is up, the real signal is
  /// a loopback `initialize` handshake (appReachableLocalProvider, no relay
  /// hop): answers → 托管中, listening but silent → 无响应. Before the port is
  /// even open it is genuinely starting.
  (StatusChip, bool) _health(
    WidgetRef ref,
    AppLocalizations l10n,
    ColorScheme scheme,
  ) {
    if (host.isCodex && host.agentError != null) {
      // A codex this host owned did not exit when it was stopped: say so,
      // so the card (and its Stop) stays the way to try again.
      final chip = StatusChip(
        key: const Key('local-host-stop-failed'),
        color: scheme.error,
        label: l10n.localHostStopFailed,
        filled: true,
      );
      return (chip, false);
    }
    // Null while starting.
    final answers = !host.alive
        ? null
        : ref
              .watch(
                host.isCodex
                    ? appReachableLocalProvider(host.appListenAddr)
                    : appReachableProvider(host.appServiceKey),
              )
              .when(
                data: (ok) => ok,
                loading: () => null,
                error: (_, _) => false,
              );
    final (color, label) = switch (answers) {
      null => (scheme.tertiary, l10n.localHostStarting),
      true => (successColor(scheme), l10n.localHostRunning),
      false => (scheme.error, l10n.localHostUnresponsive),
    };
    return (
      StatusChip(color: color, label: label, filled: true),
      answers ?? false,
    );
  }

  /// The host before it publishes a chat service: its mark, name, device
  /// and health.
  Widget _summary(BuildContext context, ColorScheme scheme, Widget chip) =>
      Padding(
        padding: const EdgeInsets.all(12),
        child: _rowOrStacked(
          context,
          leading: [
            // The agent's own mark, from the host's explicit provider +
            // profile (never from its instance name).
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              child: AgentIcon.of(
                key: Key('local-host-icon-${host.name}'),
                provider: host.provider,
                profileId: host.profileId,
                name: host.providerName,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
          ],
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      host.name,
                      style: Theme.of(context).textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
                  ProviderBadge(
                    provider: host.provider,
                    name: host.providerName,
                    profileId: host.profileId,
                    showIcon: false,
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                host.device,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          trailing: [
            const SizedBox(width: 8),
            chip,
            const SizedBox(width: 2),
            Icon(AppIcons.chevron_right, color: scheme.outline),
          ],
        ),
      );
}

/// The "+ host another" entry that opens [LocalHostDialog] in new-host mode.
class _AddLocalHostCard extends StatelessWidget {
  const _AddLocalHostCard();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      // A quiet row in the list it extends; the page's primary action is
      // the loud one.
      child: TextButton.icon(
        key: const Key('add-local-host-card'),
        onPressed: () => showHostingEditor(context),
        icon: const Icon(AppIcons.add, size: 18),
        label: Text(l10n.addLocalHost),
        style: TextButton.styleFrom(
          minimumSize: const Size.fromHeight(44),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
