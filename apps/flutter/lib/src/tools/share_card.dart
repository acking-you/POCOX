/// A share wherever it appears: at the agent's tool call in a conversation,
/// under Shared with you, and in the galaxy's panel. Its facts come live from
/// the sharing device's catalog; the tool call only names it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/service_key.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/tools/planet_glyph.dart';
import 'package:pocox/src/tools/tools_actions.dart';
import 'package:pocox/src/tools/tools_providers.dart';
import 'package:pocox/src/widgets/busy_label.dart';
import 'package:pocox/src/widgets/field_help.dart';
import 'package:pocox/src/widgets/status_dots.dart';

/// The reference for a live [share].
ShareRef shareRefOf(ToolsShare share) => ShareRef(
  service: share.firstKey ?? '',
  path: share.path,
  title: share.title,
  ports: [for (final port in share.ports) port.port],
  secure: share.secure,
  shareId: share.id,
);

/// What a share is right now, as far as this device can tell.
({String status, ToolsDevice? device, ToolsShare? share}) liveShare(
  ToolsOverview overview,
  ShareRef ref,
) {
  final live = overview.shareOfKey(ref.service);
  // A card names one share: a later share of the same port is not it, and
  // its owner's actions are not this card's.
  if (live != null && ref.shareId != null && live.share.id != ref.shareId) {
    return (status: 'ended', device: live.device, share: null);
  }
  if (live != null) {
    return (
      status: live.device.online ? live.share.status : 'offline',
      device: live.device,
      share: live.share,
    );
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

/// The card width, at default text, below which its status and actions
/// stack under the title instead of beside and below it.
const double _inlineWidth = 300;

/// One share, with Open, Save share while it is temporary, and Copy link and
/// (while it lives) Stop sharing in its menu.
class ShareCard extends ConsumerStatefulWidget {
  /// The card for [share].
  const ShareCard({super.key, required this.share, this.dense = false});

  /// Which share.
  final ShareRef share;

  /// Tighter spacing, for lists.
  final bool dense;

  @override
  ConsumerState<ShareCard> createState() => _ShareCardState();
}

class _ShareCardState extends ConsumerState<ShareCard> {
  bool _saving = false;

  Future<void> _save(String device, ToolsShare share) async {
    setState(() => _saving = true);
    try {
      await keepShare(context, ref, device, share);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final share = widget.share;
    final dense = widget.dense;
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
        : deviceLabel(share.device);
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
    final usable = now.status == 'online';
    final opening = ref.watch(shareOpeningProvider).contains(share.service);
    // Saving and stopping ask the sharing device, so only while it answers.
    final answers = now.device?.online == true && now.device?.catalog == true;
    final savable = live != null && !live.kept && answers;
    final stoppable = live != null && answers;
    final waiting = switch (now.status) {
      'offline' => l10n.toolsDeviceOfflineDetail(device),
      'unreachable' => l10n.toolsServerStoppedDetail(device),
      _ => null,
    };
    final note = helpTextStyle(theme);
    // The status rides beside the title, and the actions line up under the
    // text, only where they fit; a phone with large text stacks them.
    final roomy = MediaQuery.textScalerOf(context).scale(_inlineWidth);
    return Container(
      key: Key('share-card-${share.service}'),
      decoration: BoxDecoration(
        color: cardFill(scheme),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: EdgeInsets.fromLTRB(12, dense ? 10 : 12, 10, dense ? 6 : 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final inline = constraints.maxWidth >= roomy;
          final indent = inline ? 50.0 : 0.0;
          final chip = StatusChip(
            color: color,
            label: label,
            filled: true,
            wrap: !inline,
            pulsing: now.status == 'starting',
          );
          return Column(
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
                        if (!inline) ...[const SizedBox(height: 6), chip],
                      ],
                    ),
                  ),
                  if (inline) ...[const SizedBox(width: 8), chip],
                ],
              ),
              const SizedBox(height: 6),
              // Open and, for a temporary share, Save share: the two things
              // done here. Copying the link and stopping wait in the menu, so
              // the row stays one line on a phone with large text.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: indent),
                  Expanded(
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.tonal(
                          key: Key('share-open-${share.service}'),
                          // Its working colours while it opens, not greyed.
                          style: opening
                              ? FilledButton.styleFrom(
                                  disabledBackgroundColor:
                                      scheme.secondaryContainer,
                                  disabledForegroundColor:
                                      scheme.onSecondaryContainer,
                                )
                              : null,
                          onPressed: usable && !opening
                              ? () =>
                                    openShare(context, ref, share, title: title)
                              : null,
                          child: BusyLabel(
                            busy: opening,
                            icon: AppIcons.open_in_new,
                            label: l10n.toolsOpen,
                            busyLabel: l10n.toolsOpening,
                          ),
                        ),
                        if (savable)
                          TextButton(
                            key: Key('share-keep-${share.service}'),
                            style: _saving
                                ? TextButton.styleFrom(
                                    disabledForegroundColor: scheme.primary,
                                  )
                                : null,
                            onPressed: _saving
                                ? null
                                : () => _save(now.device!.name, live),
                            child: BusyLabel(
                              busy: _saving,
                              label: l10n.toolsKeepSharing,
                              busyLabel: l10n.toolsSaving,
                            ),
                          ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    key: Key('share-menu-${share.service}'),
                    icon: const Icon(AppIcons.more_horiz, size: 18),
                    tooltip: '',
                    onSelected: (choice) => choice == 'stop'
                        ? stopShare(context, ref, now.device!.name, live!)
                        : copyShareLink(
                            context,
                            live == null ? share : shareRefOf(live),
                          ),
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        key: Key('share-copy-${share.service}'),
                        value: 'copy',
                        child: Text(l10n.toolsCopyLink),
                      ),
                      if (stoppable)
                        PopupMenuItem(
                          key: Key('share-stop-${share.service}'),
                          value: 'stop',
                          child: Text(l10n.toolsStopSharing),
                        ),
                    ],
                  ),
                ],
              ),
              // How long it lasts, then what it waits for: state lines only,
              // their explanation behind the mark.
              if (live != null)
                Padding(
                  padding: EdgeInsets.only(left: indent, top: 2),
                  child: InfoTitle(
                    title: Text(endsLabel(l10n, live), style: note),
                    info: live.kept
                        ? l10n.toolsSavedShareHelp
                        : l10n.toolsTemporaryShareHelp,
                  ),
                ),
              if (waiting != null)
                Padding(
                  padding: EdgeInsets.only(left: indent, top: 2),
                  child: Text(waiting, style: note),
                ),
            ],
          );
        },
      ),
    );
  }
}
