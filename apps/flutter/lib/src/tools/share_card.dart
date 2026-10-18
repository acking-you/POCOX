/// A share wherever it appears: at the agent's tool call in a conversation,
/// under Shared with you, and in the galaxy's panel. Its facts come live from
/// the sharing device's catalog; the tool call only names it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/tools/planet_glyph.dart';
import 'package:pocket_codex/src/tools/tools_actions.dart';
import 'package:pocket_codex/src/tools/tools_providers.dart';
import 'package:pocket_codex/src/widgets/status_dots.dart';

/// The reference for a live [share].
ShareRef shareRefOf(ToolsShare share) => ShareRef(
  service: share.firstKey ?? '',
  path: share.path,
  title: share.title,
  ports: [for (final port in share.ports) port.port],
);

/// What a share is right now, as far as this device can tell.
({String status, ToolsDevice? device, ToolsShare? share}) liveShare(
  ToolsOverview overview,
  ShareRef ref,
) {
  final live = overview.shareOfKey(ref.service);
  if (live != null) {
    return (status: live.share.status, device: live.device, share: live.share);
  }
  ToolsDevice? device;
  for (final candidate in overview.devices) {
    if (candidate.name == ref.device) device = candidate;
  }
  final status = overview.thisDevice.isEmpty
      ? 'starting'
      : device == null || !device.online
      ? 'offline'
      // A device that reports shares and does not list this one ended it.
      : device.catalog
      ? 'ended'
      : 'online';
  return (status: status, device: device, share: null);
}

/// One share, with Open, Copy link and (while it lives) Stop or Keep.
class ShareCard extends ConsumerWidget {
  /// The card for [share].
  const ShareCard({super.key, required this.share, this.dense = false});

  /// Which share.
  final ShareRef share;

  /// Tighter spacing, for lists.
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final overview = ref.watch(toolsOverviewProvider);
    final now = liveShare(overview, share);
    final live = now.share;
    final title = live?.title ?? share.title ?? l10n.toolsPort('${share.port}');
    final ports = live != null
        ? [for (final port in live.ports) port.port]
        : share.ports.isNotEmpty
        ? share.ports
        : [?share.port];
    final device = share.device == overview.thisDevice
        ? l10n.toolsThisDevice
        : share.device;
    final owner = live?.owner;
    final facts = [
      device,
      l10n.toolsPort(ports.join(', ')),
      if (owner != null) l10n.toolsBy(ownerLabel(l10n, owner)),
    ].join(' · ');
    final color = now.status == 'ended'
        ? scheme.outline
        : statusColor(scheme, now.status);
    final label = now.status == 'ended'
        ? l10n.toolsEnded
        : statusLabel(l10n, now.status);
    final usable = now.status != 'ended' && now.status != 'offline';
    return Container(
      key: Key('share-card-${share.service}'),
      decoration: BoxDecoration(
        color: cardFill(scheme),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: EdgeInsets.fromLTRB(12, dense ? 10 : 12, 10, dense ? 6 : 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              PlanetGlyph(
                color: color,
                size: 40,
                orbit: owner?.isAgent ?? true,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      facts,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusChip(
                color: color,
                label: label,
                filled: true,
                pulsing: now.status == 'starting',
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const SizedBox(width: 50),
              FilledButton.tonalIcon(
                key: Key('share-open-${share.service}'),
                onPressed: usable
                    ? () => openShare(context, ref, share, title: title)
                    : null,
                icon: const Icon(AppIcons.open_in_new, size: 16),
                label: Text(l10n.toolsOpen),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: () => copyShareLink(context, share),
                child: Text(l10n.toolsCopyLink),
              ),
              const Spacer(),
              if (live != null && now.device != null)
                PopupMenuButton<String>(
                  key: Key('share-menu-${share.service}'),
                  icon: const Icon(AppIcons.more_horiz, size: 18),
                  tooltip: '',
                  onSelected: (choice) => choice == 'stop'
                      ? stopShare(context, ref, now.device!.name, live)
                      : keepShare(context, ref, now.device!.name, live),
                  itemBuilder: (context) => [
                    if (!live.kept)
                      PopupMenuItem(
                        value: 'keep',
                        child: Text(l10n.toolsKeepSharing),
                      ),
                    PopupMenuItem(
                      value: 'stop',
                      child: Text(l10n.toolsStopSharing),
                    ),
                  ],
                ),
            ],
          ),
          if (live != null && !dense)
            Padding(
              padding: const EdgeInsets.only(left: 50, top: 2),
              child: Text(
                endsLabel(l10n, live),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
