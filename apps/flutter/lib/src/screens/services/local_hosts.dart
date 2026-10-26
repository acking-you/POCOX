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
    final content = row == null
        ? _summary(context, scheme, chip)
        : _HostStatus(chip: healthy ? null : chip, child: row);
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
          child: host.boundElsewhere
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    content,
                    _BoundElsewhereLine(host: host),
                  ],
                )
              : content,
        ),
      ),
    );
  }

  /// Honest host health, and whether it answers. `host.alive` is only
  /// port-open (the listener bound), which stays true even when the embedded
  /// codex has wedged / gone half-open (still accept()ing but never answering
  /// RPC) — a false "hosting". So once the listener is up, the real signal is
  /// a protocol handshake (the bridge selects the owned loopback endpoint, no relay
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
    // A lifecycle operation holds it (an update restarting it in place,
    // say): it reads as what it is doing, never as not responding.
    if (host.busy case final busy?) {
      final label = switch (busy) {
        'starting' => l10n.localHostStarting,
        'stopping' => l10n.hostStopping,
        _ => l10n.hostRestarting,
      };
      return (
        StatusChip(
          color: scheme.tertiary,
          label: label,
          filled: true,
          pulsing: true,
        ),
        false,
      );
    }
    if (host.boundElsewhere) {
      // It answers only under the account or relay it started in; a probe
      // from this one could only call it unresponsive.
      final chip = StatusChip(
        key: const Key('local-host-restart-needed'),
        color: cautionColor(scheme),
        label: l10n.localHostRestartNeeded,
        filled: true,
      );
      return (chip, false);
    }
    // Null while starting.
    final answers = !host.alive
        ? null
        : ref
              .watch(appReachableProvider(host.appServiceKey))
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
                deviceLabel(host.device),
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

/// Why a running host cannot be used from this device, and its one fix. A
/// host keeps publishing under the account or relay it started in; only
/// this explicit Restart (an apply of its saved configuration, which starts
/// under the current one) moves it here. Nothing restarts it on its own.
class _BoundElsewhereLine extends StatefulWidget {
  const _BoundElsewhereLine({required this.host});

  final AppServeStatus host;

  @override
  State<_BoundElsewhereLine> createState() => _BoundElsewhereLineState();
}

class _BoundElsewhereLineState extends State<_BoundElsewhereLine> {
  bool _restarting = false;

  /// Restart exactly the incarnation shown, after the user agreed to the
  /// interruption; a replaced host is refused, never retargeted.
  Future<void> _restart() async {
    final host = widget.host;
    final l10n = AppLocalizations.of(context);
    final toast = ToastMessenger.of(context);
    // Captured now: this line leaves with the card's old state as soon as
    // the host list reports the restarted host.
    final container = ProviderScope.containerOf(context);
    final agreed = await confirmEditorAction(
      context,
      title: l10n.hostApplyConfirmTitle(host.name),
      body: l10n.hostApplyConfirmBody,
      action: l10n.localHostRestart,
      confirmKey: const Key('local-host-restart-confirm'),
    );
    if (!agreed || !mounted) return;
    setState(() => _restarting = true);
    try {
      final result = await container
          .read(bridgeApiProvider)
          .appServeApply(host.name, expectedIncarnation: host.incarnation);
      if (hostApplyProblem(l10n, result) case final problem?) {
        toast.error(problem);
      }
    } catch (e) {
      toast.error(friendlyError(e));
    } finally {
      // What runs now, whichever way it ended.
      container.invalidate(localServeListProvider);
      container.invalidate(servicesProvider);
      if (mounted) setState(() => _restarting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.localHostBoundElsewhere,
              style: helpTextStyle(theme).copyWith(color: cautionColor(scheme)),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: Key('local-host-restart-${widget.host.name}'),
            style: _restarting
                ? TextButton.styleFrom(disabledForegroundColor: scheme.primary)
                : null,
            // Another lifecycle operation (a stop, an editor's apply) holds
            // the host.
            onPressed: _restarting || widget.host.busy != null
                ? null
                : _restart,
            child: BusyLabel(
              busy: _restarting,
              icon: AppIcons.restart_alt,
              label: l10n.localHostRestart,
              busyLabel: l10n.hostRestarting,
            ),
          ),
        ],
      ),
    );
  }
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
