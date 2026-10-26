part of '../services_screen.dart';

class _DeviceColumn extends StatelessWidget {
  const _DeviceColumn({
    required this.relay,
    required this.accountLogin,
    required this.accountId,
    required this.devices,
    required this.activeDevice,
    required this.localName,
    required this.capabilityCount,
    required this.onSelect,
    required this.filled,
    this.offlineDevices = const {},
    this.relayState = const _RelayOnline(),
  });

  final String relay;
  final String? accountLogin;
  final String? accountId;
  final List<String> devices;
  final String? activeDevice;

  /// This computer's name, for its own (independent) target.
  final String localName;
  final int Function(String device) capabilityCount;
  final Set<String> offlineDevices;
  final ValueChanged<String> onSelect;

  /// Whether to take the height it is given and scroll the device list inside.
  /// False sizes to the list instead, for a column that is the whole page.
  final bool filled;

  /// Whether the relay listed the devices.
  final _RelayState relayState;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    // Installations that share a name (two copies of one WSL distribution,
    // say) are told apart by their stable ID. The platform is in the header.
    final sameNamed = sameNamedDevices(devices.where((d) => d != _thisDevice));
    final tiles = <Widget>[
      for (final device in devices)
        _DeviceTile(
          key: Key('device-$device'),
          device: device == _thisDevice ? localName : deviceLabel(device),
          subtitle: [
            if (device == _thisDevice) l10n.servicesLocalDevice,
            if (sameNamed.contains(device)) ?deviceShortId(device),
            if (offlineDevices.contains(device)) l10n.toolsStatusOffline,
            l10n.servicesDeviceCapabilityCount(capabilityCount(device)),
          ].join(' · '),
          selected: device == activeDevice,
          onTap: () => onSelect(device),
        ),
    ];
    // The relay (or account) this list comes from, as a small raised card;
    // the devices below it are rows on the sheet itself, the chosen one
    // lifted into a card of its own — one level of plates, not a slab.
    final identity = _RelayCard(
      name: accountLogin == null ? relay : '@$accountLogin',
      relay: relay,
      account: accountLogin != null,
      accountId: accountId,
      state: relayState,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: filled ? MainAxisSize.max : MainAxisSize.min,
      children: [
        identity,
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 20, 14, 8),
          child: Text(
            l10n.servicesDevices.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (filled)
          Expanded(
            child: ListView(padding: EdgeInsets.zero, children: tiles),
          )
        else
          Column(children: tiles),
      ],
    );
  }
}

// The relay card's fixed parts.
const double _identityPadding = 12;
const double _avatarSize = 36;
const double _avatarGap = 10;
const double _chevronSize = 18;
const double _stateDotSize = 7;
const double _stateDotGap = 6;

/// The style of the relay card's state line.
TextStyle _stateStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodySmall!.copyWith(height: 1.3);

/// The width the relay card needs beside a detail pane at the current text
/// scale: at least three glyphs of its name, and every word of its states
/// whole under the name (a state wraps to a second line rather than break a
/// word). Measured over every state, so the layout never changes when only
/// the relay's answer does.
double _identityRowWidth(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  final scaler = MediaQuery.textScalerOf(context);
  final style = _stateStyle(context);
  var word = 0.0;
  for (final label in [
    l10n.statusOnline,
    l10n.statusChecking,
    l10n.statusUnreachable,
    l10n.statusSessionExpired,
  ]) {
    for (final part in label.split(' ')) {
      word = math.max(word, measureTextLine(context, part, style).width);
    }
  }
  return 2 * _identityPadding +
      _avatarSize +
      _avatarGap +
      math.max(scaler.scale(14) * 3, _stateDotSize + _stateDotGap + word) +
      _chevronSize;
}

/// The relay (or account) the device list comes from, and whether it
/// answers: a state line under its name, and, while it cannot list the
/// devices, what is wrong and the one action that helps. The relay's state
/// is said here only, beside the list it concerns, never as a banner over
/// this computer's own services, which work without it.
class _RelayCard extends StatelessWidget {
  const _RelayCard({
    required this.name,
    required this.relay,
    required this.account,
    required this.accountId,
    required this.state,
  });

  /// The account's login or the relay's address.
  final String name;

  /// The configured relay, for diagnosing a failure.
  final String relay;

  /// Signed in to an account rather than a self-hosted relay.
  final bool account;

  /// The account's GitHub ID, for its avatar.
  final String? accountId;

  final _RelayState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (label, color, attention) = switch (state) {
      _RelayOnline() => (l10n.statusOnline, successColor(scheme), false),
      _RelayChecking() => (l10n.statusChecking, scheme.outline, false),
      _RelayDown() => (l10n.statusUnreachable, scheme.error, true),
      _RelaySignedOut() => (
        l10n.statusSessionExpired,
        cautionColor(scheme),
        true,
      ),
    };
    final style = _stateStyle(context);
    final header = Padding(
      padding: const EdgeInsets.all(_identityPadding),
      child: Row(
        children: [
          GitHubAvatar(
            accountId: accountId,
            fallbackIcon: account
                ? AppIcons.person_outline
                : AppIcons.lan_outlined,
            size: _avatarSize,
          ),
          const SizedBox(width: _avatarGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Row(
                  key: const Key('relay-state'),
                  children: [
                    if (state is _RelayChecking)
                      PulsingDot(color: color, size: _stateDotSize)
                    else
                      StatusDot(color: color, size: _stateDotSize),
                    const SizedBox(width: _stateDotGap),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: style.copyWith(
                          color: attention ? color : scheme.onSurfaceVariant,
                          fontWeight: attention ? FontWeight.w600 : null,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Icon(
            AppIcons.chevron_right,
            size: _chevronSize,
            color: scheme.outline,
          ),
        ],
      ),
    );
    // Under the name, so the card reads as one statement.
    const inset = _identityPadding + _avatarSize + _avatarGap;
    final problem = switch (state) {
      _RelayDown(:final detail, :final onRetry, :final retrying) => Column(
        key: const Key('relay-problem'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RelayCause(
            detail: detail,
            relay: relay,
            style: style.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton(
              key: const Key('relay-problem-retry'),
              // Kept legible while it runs, with its spinner.
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 13),
                disabledForegroundColor: scheme.onSurface,
              ),
              onPressed: retrying ? null : onRetry,
              child: BusyLabel(
                busy: retrying,
                icon: AppIcons.refresh,
                label: l10n.retry,
                busyLabel: l10n.statusChecking,
              ),
            ),
          ),
          ErrorDetails(
            detail: detail,
            tileKey: const Key('relay-problem-details'),
          ),
        ],
      ),
      _RelaySignedOut(:final onSignIn) => Padding(
        key: const Key('services-session-expired'),
        padding: const EdgeInsets.only(bottom: _identityPadding),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.icon(
            key: const Key('services-sign-in-again'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 13),
            ),
            onPressed: onSignIn,
            icon: const Icon(AppIcons.login, size: 16),
            label: Text(l10n.accountSignInAgain),
          ),
        ),
      ),
      _RelayOnline() || _RelayChecking() => null,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(kCardRadius),
        boxShadow: raisedCardShadows(scheme),
      ),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: AnimatedSize(
          duration: Motion.of(context, Motion.medium),
          curve: Motion.move,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Tooltip(
                message: l10n.settingsTitle,
                child: InkWell(
                  key: const Key('identity-open-settings'),
                  mouseCursor: clickable,
                  onTap: () => context.push('/settings'),
                  child: header,
                ),
              ),
              if (problem != null)
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: inset,
                    end: _identityPadding,
                  ),
                  child: problem,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    super.key,
    required this.device,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String device;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        // The chosen device is lifted into a card of its own; the rest are
        // rows on the sheet.
        color: selected ? raisedCardColor(scheme) : Colors.transparent,
        elevation: selected ? 1 : 0,
        shadowColor: sidebarSelectionShadow(scheme),
        animationDuration: Motion.of(context, Motion.fast),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRowRadius),
          side: selected
              ? BorderSide(color: raisedCardEdge(scheme))
              : BorderSide.none,
        ),
        child: InkWell(
          mouseCursor: clickable,
          onTap: onTap,
          borderRadius: BorderRadius.circular(kRowRadius),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: softWash(scheme),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    AppIcons.computer,
                    size: 17,
                    color: selected
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DeviceDetailHeader extends StatelessWidget {
  const _DeviceDetailHeader({
    required this.device,
    required this.platform,
    required this.local,
    required this.isDefault,
    required this.onClean,
  });

  final String? device;

  /// What the device's publisher reports it runs on; null while loading.
  final String? platform;
  final bool local;
  final bool isDefault;
  final VoidCallback? onClean;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _rowOrStacked(
        context,
        // The device list beside it already carries the device's glyph;
        // the heading is its name alone.
        leading: const [SizedBox(width: 4)],
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              device ?? l10n.servicesDevices,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (platform case final platform?)
              Text(
                platform,
                key: const Key('device-detail-platform'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        trailing: [
          if (local) _CountPill(label: l10n.servicesLocalDevice),
          if (local && isDefault) const SizedBox(width: 8),
          if (isDefault) _CountPill(label: l10n.servicesDefault, accent: true),
          if (onClean != null) ...[
            const SizedBox(width: 8),
            TextButton.icon(
              key: const Key('device-clean-unreachable'),
              onPressed: onClean,
              icon: const Icon(AppIcons.cleaning_services_outlined, size: 17),
              label: Text(l10n.batchRemoveEnter),
            ),
          ],
        ],
      ),
    );
  }
}
