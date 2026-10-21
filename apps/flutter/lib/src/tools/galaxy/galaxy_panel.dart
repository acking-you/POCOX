/// The galaxy's detail panel for what the user picked: a device and its
/// services, a shared port (as its share card), an agent host or an API.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/error_format.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/service_key.dart';
import 'package:pocox/src/tools/galaxy/galaxy_model.dart';
import 'package:pocox/src/tools/galaxy/galaxy_painter.dart';
import 'package:pocox/src/tools/planet_glyph.dart';
import 'package:pocox/src/tools/share_card.dart';
import 'package:pocox/src/tools/tools_actions.dart';
import 'package:pocox/src/tools/tools_providers.dart';
import 'package:pocox/src/widgets/app_toast.dart';
import 'package:pocox/src/widgets/status_dots.dart';

/// The glyph of a device's platform.
IconData platformIcon(String? platform) => switch (platform) {
  'ios' || 'android' => AppIcons.smartphone,
  'linux' => AppIcons.server,
  _ => AppIcons.laptop,
};

/// What [kind] is called.
String kindLabel(AppLocalizations l10n, BodyKind kind) => switch (kind) {
  BodyKind.agent => l10n.galaxyKindAgent,
  BodyKind.api => l10n.galaxyKindApi,
  BodyKind.port => l10n.galaxyKindPort,
};

/// The panel for body [id] of [scene].
class GalaxyPanel extends ConsumerWidget {
  /// Shows [id]; [onPick] selects another body, [onClose] clears.
  const GalaxyPanel({
    super.key,
    required this.scene,
    required this.id,
    required this.onPick,
    required this.onClose,
  });

  /// The scene the body belongs to.
  final GalaxyScene scene;

  /// The selected body.
  final String id;

  /// Select another body.
  final ValueChanged<String> onPick;

  /// Close the panel.
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final system = scene.systemOf(id);
    final planet = scene.planetOf(id);
    final Widget body;
    if (system != null) {
      body = _SystemDetail(system: system, onPick: onPick);
    } else if (planet != null) {
      body = _PlanetDetail(system: planet.system, planet: planet.planet);
    } else {
      body = const SizedBox.shrink();
    }
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: body,
        ),
        PositionedDirectional(
          top: 4,
          end: 4,
          child: IconButton(
            key: const Key('galaxy-panel-close'),
            icon: const Icon(AppIcons.close, size: 17),
            onPressed: onClose,
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.leading, required this.title, this.subtitle});

  final Widget leading;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 32, bottom: 10),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SystemDetail extends ConsumerWidget {
  const _SystemDetail({required this.system, required this.onPick});

  final StarSystem system;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final device = system.device;
    final facts = [
      if (system.home) l10n.toolsThisDevice,
      if (device.platform case final platform?) osLabel(platform),
      if (device.toolsEnabled == false) l10n.toolsOffHere,
      if (!device.catalog) l10n.galaxyOlderPocox,
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Header(
          leading: Icon(platformIcon(device.platform), size: 26),
          title: deviceLabel(device.name),
          subtitle: facts.isEmpty ? null : facts,
        ),
        Row(
          children: [
            StatusChip(
              color: statusColor(scheme, device.online ? 'online' : 'offline'),
              label: device.online
                  ? l10n.toolsStatusOnline
                  : l10n.toolsStatusOffline,
              filled: true,
            ),
            const SizedBox(width: 8),
            Text(
              l10n.galaxyServices(system.planets.length),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              for (final planet in system.planets)
                ListTile(
                  key: Key('galaxy-row-${planet.id}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: PlanetGlyph(
                    color: statusColor(scheme, planet.service.status),
                    size: 26,
                    orbit: planet.share?.owner.isAgent ?? false,
                  ),
                  title: Text(
                    planetLabel(l10n, planet),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(kindLabel(l10n, planet.kind)),
                  onTap: () => onPick(planet.id),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: () => context.push('/manage'),
            icon: const Icon(AppIcons.dns_outlined, size: 16),
            label: Text(l10n.galaxyManageDevice),
          ),
        ),
      ],
    );
  }
}

class _PlanetDetail extends ConsumerWidget {
  const _PlanetDetail({required this.system, required this.planet});

  final StarSystem system;
  final Planet planet;

  Future<void> _toggle(
    BuildContext context,
    WidgetRef ref,
    bool connected,
  ) async {
    final api = ref.read(bridgeApiProvider);
    final messenger = ToastMessenger.of(context);
    try {
      if (connected) {
        await api.toolsDisconnect(planet.service.key);
      } else {
        await api.toolsConnect(planet.service.key);
      }
    } catch (error) {
      messenger.error(friendlyError(error));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final service = planet.service;
    final share = planet.share;
    if (planet.kind == BodyKind.port && share != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Header(
            leading: const Icon(AppIcons.share_port, size: 24),
            title: share.title,
            subtitle: kindLabel(l10n, planet.kind),
          ),
          ShareCard(share: shareRefOf(share)),
        ],
      );
    }
    final connection = ref
        .watch(toolsOverviewProvider)
        .connectionTo(service.key);
    final away =
        system.device.name != ref.watch(toolsOverviewProvider).thisDevice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Header(
          leading: PlanetGlyph(
            color: statusColor(scheme, service.status),
            size: 34,
          ),
          title: planetLabel(l10n, planet),
          subtitle:
              '${kindLabel(l10n, planet.kind)} · '
              '${system.home ? l10n.toolsThisDevice : deviceLabel(system.device.name)}',
        ),
        Row(
          children: [
            StatusChip(
              color: statusColor(scheme, service.status),
              label: statusLabel(l10n, service.status),
              filled: true,
            ),
          ],
        ),
        if (connection != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              l10n.galaxyConnected(connection.local),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (planet.kind == BodyKind.agent)
              FilledButton.tonalIcon(
                key: const Key('galaxy-open-conversations'),
                onPressed: () => context.push(
                  '/app/${Uri.encodeComponent(service.key)}/session',
                ),
                icon: const Icon(
                  AppIcons.chat_bubble_outline_rounded,
                  size: 16,
                ),
                label: Text(l10n.galaxyOpenConversations),
              ),
            if (planet.kind == BodyKind.api && away)
              FilledButton.tonalIcon(
                key: const Key('galaxy-connect'),
                onPressed: () => _toggle(context, ref, connection != null),
                icon: Icon(
                  connection != null
                      ? AppIcons.link_off_outlined
                      : AppIcons.plug,
                  size: 16,
                ),
                label: Text(
                  connection != null
                      ? l10n.galaxyDisconnect
                      : l10n.galaxyConnect,
                ),
              ),
          ],
        ),
      ],
    );
  }
}
