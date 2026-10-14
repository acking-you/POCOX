import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/hosting/acp_host_details.dart';
import 'package:pocket_codex/src/hosting/editor_block.dart';
import 'package:pocket_codex/src/hosting/opencode_host_details.dart';
import 'package:pocket_codex/src/widgets/group_card.dart';
import 'package:pocket_codex/src/widgets/project_folders_editor.dart';

/// What a running host is: for native Codex its tunnels (listen address and
/// relay key each), runtime and project folders; for an ACP host the agent's
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.localHostHint),
        const SizedBox(height: 12),
        // Two tunnels under one name: each kind's listen address + relay key.
        Text(l10n.tunnelAppLabel, style: small),
        Text(l10n.localHostListening(host.appListenAddr), style: small),
        SelectableText(host.appServiceKey, style: muted),
        const SizedBox(height: 8),
        Text(l10n.tunnelApiLabel, style: small),
        Text(l10n.localHostListening(host.apiListenAddr), style: small),
        SelectableText(host.apiServiceKey, style: muted),
        const Divider(height: 24),
        Text(
          l10n.hostRuntimeInfo,
          style: small?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          '${l10n.hostRuntimeMode}: ${l10n.codexSourceExternal}',
          style: small,
        ),
        SelectableText(
          '${l10n.hostCodexPath}: ${host.codexBinary ?? '—'}',
          style: muted,
        ),
        Text(
          '${l10n.hostProxyLabel}: ${host.proxy ?? l10n.hostProxyInherit}',
          style: small,
        ),
        const SizedBox(height: 4),
        EditorNote(l10n.hostCodexRuntimeFixed),
        // The roots a phone's folder browser is confined to, and the default
        // new conversations open in. Configured on the host.
        const Divider(height: 24),
        ProjectFoldersEditor(serviceKey: host.appServiceKey),
      ],
    );
  }
}
