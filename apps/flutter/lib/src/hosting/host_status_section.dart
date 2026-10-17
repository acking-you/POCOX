import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/hosting/acp_host_details.dart';
import 'package:pocket_codex/src/hosting/editor_block.dart';
import 'package:pocket_codex/src/hosting/opencode_host_details.dart';
import 'package:pocket_codex/src/widgets/group_card.dart';
import 'package:pocket_codex/src/hosting/host_diagnostics.dart';
import 'package:pocket_codex/src/managed/default_project_tile.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/provider_badge.dart';

/// What a running host is, most important first: its state, the default
/// project folder and the key actions, with tunnels, keys and executables
/// folded into diagnostics. For native Codex shown here; for an ACP host the agent's
/// details ([AcpHostDetails]); for OpenCode its server ([OpenCodeHostDetails]).
class HostStatusSection extends StatelessWidget {
  /// Creates the section for [host].
  const HostStatusSection({super.key, required this.host});

  /// The running host.
  final AppServeStatus host;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return GroupCard(
      key: const Key('host-status-section'),
      title: l10n.hostSectionStatus,
      children: [
        EditorBlock(
          child: host.isOpenCode
              ? OpenCodeHostDetails(host: host)
              : host.isAcp
              ? AcpHostDetails(host: host)
              : _codex(context, l10n),
        ),
      ],
    );
  }

  Widget _codex(BuildContext context, AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    final muted = small?.copyWith(color: scheme.onSurfaceVariant);
    final online = host.appRegistered;
    return Column(
      key: const Key('codex-host-details'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        HostStateLine(
          badge: const ProviderBadge(provider: 'codex'),
          label: online ? l10n.managedStateRunning : l10n.tunnelOffline,
          color: online ? successColor(scheme) : scheme.onSurfaceVariant,
        ),
        const SizedBox(height: 6),
        Text(
          '${l10n.hostProxyLabel}: ${host.proxy ?? l10n.hostProxyInherit}',
          style: muted,
        ),
        const SizedBox(height: 12),
        DefaultProjectTile(serviceKey: host.appServiceKey, local: true),
        const SizedBox(height: 4),
        HostDiagnostics(
          host: host,
          notes: [
            Text(l10n.localHostHint, style: muted),
            EditorNote(l10n.hostCodexRuntimeFixed),
          ],
        ),
      ],
    );
  }
}
