import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/error_format.dart';
import 'package:pocket_codex/src/hosting/editor_block.dart';
import 'package:pocket_codex/src/hosting/host_diagnostics.dart';
import 'package:pocket_codex/src/hosting/opencode_runtime_section.dart';
import 'package:pocket_codex/src/managed/default_project_tile.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/provider_badge.dart';
import 'package:pocket_codex/src/app_icons.dart';

/// A running native OpenCode host: its version, what OpenCode's own
/// configuration provides (providers, models, default model, agents) and the
/// default project folder; what a write here excludes, its gateway and its
/// executable are folded into diagnostics.
///
/// Only counts and names are shown; provider options and keys never leave
/// the host. Refresh asks the host to re-read OpenCode's catalog, since
/// models and sign-ins may change outside Pocket.
class OpenCodeHostDetails extends ConsumerStatefulWidget {
  /// Creates the details for [host].
  const OpenCodeHostDetails({super.key, required this.host});

  /// The OpenCode host.
  final AppServeStatus host;

  @override
  ConsumerState<OpenCodeHostDetails> createState() =>
      _OpenCodeHostDetailsState();
}

class _OpenCodeHostDetailsState extends ConsumerState<OpenCodeHostDetails> {
  /// The host name a refresh is running for, if any.
  String? _refreshing;

  /// Why the last refresh of the shown host failed to run.
  String? _refreshError;

  AppServeStatus get host => widget.host;

  @override
  void didUpdateWidget(OpenCodeHostDetails old) {
    super.didUpdateWidget(old);
    // Another host's page: a refresh still running belongs to the old one.
    if (old.host.name != widget.host.name) {
      _refreshing = null;
      _refreshError = null;
    }
  }

  Future<void> _refresh() async {
    final name = host.name;
    final api = ref.read(bridgeApiProvider);
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() {
      _refreshing = name;
      _refreshError = null;
    });
    String? error;
    try {
      await api.openCodeRefresh(name: name);
    } catch (e) {
      error = friendlyError(e);
    }
    // The host keeps a failed read as its status problem, so the list is
    // re-read either way, even when this page has gone.
    container.invalidate(localServeListProvider);
    if (!mounted || _refreshing != name) return;
    setState(() {
      _refreshing = null;
      _refreshError = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall;
    final muted = small?.copyWith(color: scheme.onSurfaceVariant);
    final status = host.opencode;
    // The host reports a diagnostic as text; a catalog without a connected
    // provider is not one, yet nothing can answer until a sign-in.
    final problem = switch (status) {
      OpenCodeHostStatus(problem: final p?) => openCodeProblemText(l10n, p),
      OpenCodeHostStatus(providersConnected: 0) => l10n.openCodeNoProvider,
      _ => null,
    };
    final ready = host.alive && problem == null;
    final refreshing = _refreshing == host.name;
    return Column(
      key: const Key('opencode-host-details'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        HostStateLine(
          badge: const ProviderBadge(provider: 'opencode'),
          label: host.alive
              ? l10n.openCodeRunning(status?.version ?? '')
              : l10n.acpPhaseStarting,
          labelKey: const Key('opencode-phase'),
          color: ready
              ? successColor(scheme)
              : problem != null
              ? cautionColor(scheme)
              : scheme.onSurfaceVariant,
        ),
        if (host.agentError case final error? when !host.alive) ...[
          const SizedBox(height: 6),
          SelectableText(
            error,
            key: const Key('opencode-error'),
            style: small?.copyWith(color: scheme.error),
          ),
        ],
        if (problem != null) ...[
          const SizedBox(height: 6),
          Text(
            problem,
            key: const Key('opencode-problem'),
            style: small?.copyWith(color: cautionColor(scheme)),
          ),
        ],
        if (host.alive) ...[
          const SizedBox(height: 4),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const Key('opencode-refresh'),
              onPressed: refreshing ? null : _refresh,
              icon: refreshing
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(AppIcons.refresh, size: 16),
              label: Text(l10n.refresh),
            ),
          ),
        ],
        if (_refreshError case final error?) ...[
          const SizedBox(height: 4),
          SelectableText(
            l10n.openCodeRefreshFailed(error),
            key: const Key('opencode-refresh-error'),
            style: small?.copyWith(color: scheme.error),
          ),
        ],
        if (status != null) ...[
          const SizedBox(height: 8),
          DetailRow(l10n.openCodeProviders, '${status.providersConnected}'),
          DetailRow(l10n.openCodeModels, '${status.models}'),
          DetailRow(
            l10n.openCodeDefaultModel,
            status.defaultModel ?? l10n.openCodeNone,
          ),
          DetailRow(
            l10n.openCodeAgents,
            status.agents.isEmpty
                ? l10n.openCodeNone
                : status.agents.join(', '),
          ),
        ],
        const SizedBox(height: 12),
        DefaultProjectTile(serviceKey: host.appServiceKey, local: true),
        const SizedBox(height: 4),
        HostDiagnostics(
          host: host,
          binaryLabel: l10n.openCodePath,
          notes: [
            Text(l10n.openCodeConfigNote, style: muted),
            // What a write through this host excludes, said once here rather
            // than as chrome in every conversation.
            Text(
              l10n.openCodeScopeNote,
              key: const Key('opencode-scope-note'),
              style: muted,
            ),
          ],
        ),
      ],
    );
  }
}
