import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/error_format.dart';
import 'package:pocket_codex/src/hosting/editor_block.dart';
import 'package:pocket_codex/src/hosting/host_diagnostics.dart';
import 'package:pocket_codex/src/managed/default_project_tile.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/provider_badge.dart';
import 'package:pocket_codex/src/app_icons.dart';

/// A running ACP host: its agent's state (starting, running, not running and
/// why, sign-in needed), a restart action, what the agent negotiated and the
/// default project folder; the gateway, meta service and program are folded
/// into diagnostics.
///
/// Feature rows are shown only from a live negotiation; before it they say
/// so instead of guessing.
class AcpHostDetails extends ConsumerStatefulWidget {
  /// Creates the details for [host].
  const AcpHostDetails({super.key, required this.host});

  /// The ACP host.
  final AppServeStatus host;

  @override
  ConsumerState<AcpHostDetails> createState() => _AcpHostDetailsState();
}

class _AcpHostDetailsState extends ConsumerState<AcpHostDetails> {
  bool _restarting = false;
  String? _error;

  Future<void> _restart() async {
    setState(() {
      _restarting = true;
      _error = null;
    });
    // The restart can finish after this view closed or its scope went away.
    final container = ProviderScope.containerOf(context);
    final api = container.read(bridgeApiProvider);
    final life = container.read(scopeLifeProvider);
    try {
      await api.appServeRestartAcp(widget.host.name);
      if (life.alive) container.invalidate(localServeListProvider);
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _restarting = false);
    }
  }

  String _phaseLabel(AppLocalizations l10n, String? phase) => switch (phase) {
    'ready' => l10n.acpPhaseReady,
    'failed' => l10n.acpPhaseFailed,
    'stopped' => l10n.acpPhaseStopped,
    _ => l10n.acpPhaseStarting,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    final muted = small?.copyWith(color: scheme.onSurfaceVariant);
    final host = widget.host;
    final phase = host.agentPhase;
    final ready = phase == 'ready';
    final caps = ref
        .read(bridgeApiProvider)
        .appCapabilities(host.appServiceKey);
    final negotiated = ready && caps.negotiated;
    String supported(bool value) =>
        value ? l10n.acpFeatureSupported : l10n.acpFeatureNotSupported;
    final reopen = switch (caps.sessionReopen) {
      'load' => l10n.acpFeatureReopenLoad,
      'resume' => l10n.acpFeatureReopenResume,
      _ => l10n.acpFeatureNotSupported,
    };
    return Column(
      key: const Key('acp-host-details'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        HostStateLine(
          badge: ProviderBadge(
            provider: 'acp',
            name: host.providerName,
            profileId: host.profileId,
          ),
          label: _phaseLabel(l10n, phase),
          labelKey: const Key('acp-phase'),
          color: switch (phase) {
            'ready' => successColor(scheme),
            'failed' => scheme.error,
            _ => scheme.onSurfaceVariant,
          },
        ),
        if (host.agentError != null && !ready) ...[
          const SizedBox(height: 6),
          SelectableText(
            host.agentError!,
            key: const Key('acp-agent-error'),
            style: small?.copyWith(color: scheme.error),
          ),
        ],
        if (host.authRequired) ...[
          const SizedBox(height: 6),
          Text(
            l10n.acpAuthRequired,
            key: const Key('acp-auth-required'),
            style: small?.copyWith(color: cautionColor(scheme)),
          ),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            key: const Key('acp-restart'),
            onPressed: _restarting ? null : _restart,
            icon: const Icon(AppIcons.restart_alt),
            label: Text(l10n.acpRestart),
          ),
        ),
        if (_error != null)
          Text(_error!, style: small?.copyWith(color: scheme.error)),
        const SizedBox(height: 8),
        if (!negotiated)
          Text(
            l10n.acpFeatureUnknown,
            key: const Key('acp-features-unknown'),
            style: muted,
          )
        else ...[
          DetailRow(l10n.acpFeatureReopen, reopen),
          DetailRow(
            l10n.acpFeatureList,
            supported(caps.sessionList == 'agent'),
          ),
          DetailRow(l10n.acpFeatureImages, supported(caps.imageInput)),
        ],
        const SizedBox(height: 12),
        DefaultProjectTile(serviceKey: host.appServiceKey, local: true),
        const SizedBox(height: 4),
        HostDiagnostics(
          host: host,
          binaryLabel: l10n.acpProgram,
          notes: [Text(l10n.acpStopNote, style: muted)],
        ),
      ],
    );
  }
}
