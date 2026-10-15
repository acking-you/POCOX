import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/managed/managed_device_panel.dart';

/// The technical side of a running host, folded away under the status:
/// listen addresses, relay keys, the executable and the longer
/// explanations. Every value stays whole, selectable and copyable.
class HostDiagnostics extends StatelessWidget {
  /// Creates the diagnostics of [host]; [notes] are shown first.
  const HostDiagnostics({
    super.key,
    required this.host,
    this.notes = const [],
    this.binaryLabel,
  });

  /// The running host.
  final AppServeStatus host;

  /// Longer explanations of how this host behaves.
  final List<Widget> notes;

  /// The label of the executable line (Codex path, OpenCode path, ACP
  /// program).
  final String? binaryLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final codex = host.isCodex;
    return Material(
      // An own ink layer: a coloured ancestor would hide the tile's.
      type: MaterialType.transparency,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const Key('host-diagnostics'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          title: Text(l10n.managedDiagnostics),
          children: [
            for (final note in notes) ...[note, const SizedBox(height: 8)],
            DiagnosticLine(
              label:
                  '${codex ? l10n.tunnelAppLabel : l10n.acpGatewayLabel} · '
                  '${host.appListenAddr}',
              value: host.appServiceKey,
            ),
            if (codex && host.apiServiceKey.isNotEmpty)
              DiagnosticLine(
                label: '${l10n.tunnelApiLabel} · ${host.apiListenAddr}',
                value: host.apiServiceKey,
              ),
            if (host.metaServiceKey.isNotEmpty)
              DiagnosticLine(
                label: '${l10n.hostMetaLabel} · ${host.metaListenAddr}',
                value: host.metaServiceKey,
              ),
            if (host.codexBinary case final binary?)
              DiagnosticLine(
                label: binaryLabel ?? l10n.hostCodexPath,
                value: binary,
              ),
          ],
        ),
      ),
    );
  }
}
