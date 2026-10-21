/// The galaxy as a list: what agents and the user shared, then every device
/// and its services. The way to scan, and the default with a screen reader.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/service_key.dart';
import 'package:pocox/src/tools/galaxy/galaxy_model.dart';
import 'package:pocox/src/tools/galaxy/galaxy_painter.dart';
import 'package:pocox/src/tools/galaxy/galaxy_panel.dart';
import 'package:pocox/src/tools/planet_glyph.dart';
import 'package:pocox/src/tools/share_card.dart';
import 'package:pocox/src/tools/tools_actions.dart';
import 'package:pocox/src/tools/tools_providers.dart';
import 'package:pocox/src/widgets/status_dots.dart';

/// Every share and service in [scene], as a list.
class GalaxyList extends ConsumerWidget {
  /// Lists [scene]; [onPick] opens a body's details.
  const GalaxyList({
    super.key,
    required this.top,
    required this.scene,
    required this.onPick,
  });

  /// Room above the first row, where the search bar floats over the list.
  final double top;

  /// What to list.
  final GalaxyScene scene;

  /// Open a body's details.
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shares = ref.watch(toolsSharesProvider);
    // The search and kind filter the scene; shares follow what it shows.
    final shown = {
      for (final system in scene.systems)
        for (final planet in system.planets) planet.service.key,
    };
    final listed = [
      for (final entry in shares)
        if (entry.share.ports.any((port) => shown.contains(port.key))) entry,
    ];
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
    return ListView(
      key: const Key('galaxy-list'),
      padding: EdgeInsets.fromLTRB(16, top, 16, 24),
      children: [
        if (shares.isEmpty) ...[
          heading(l10n.toolsSharedWithYou),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Text(
              l10n.toolsShareHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ] else if (listed.isNotEmpty) ...[
          heading(l10n.toolsSharedWithYou),
          for (final entry in listed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ShareCard(share: shareRefOf(entry.share), dense: true),
            ),
        ],
        for (final system in scene.systems) ...[
          heading(
            system.home
                ? '${deviceLabel(system.device.name)} · ${l10n.toolsThisDevice}'
                : deviceLabel(system.device.name),
          ),
          if (system.planets.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                system.device.online
                    ? l10n.servicesNoCapabilities
                    : l10n.toolsStatusOffline,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final planet in system.planets)
            ListTile(
              key: Key('galaxy-list-${planet.id}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: PlanetGlyph(
                color: statusColor(scheme, planet.service.status),
                size: 30,
                orbit: planet.share?.owner.isAgent ?? false,
              ),
              title: Text(
                planetLabel(l10n, planet),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  kindLabel(l10n, planet.kind),
                  if (planet.share?.owner case final owner?)
                    l10n.toolsBy(ownerLabel(l10n, owner))
                  else if (planet.service.owner case final owner?)
                    l10n.toolsBy(owner),
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: StatusChip(
                color: statusColor(scheme, planet.service.status),
                label: statusLabel(l10n, planet.service.status),
              ),
              onTap: () => onPick(planet.id),
            ),
        ],
      ],
    );
  }
}
