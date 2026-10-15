import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/hosting/claude_preparation_progress.dart';
import 'package:pocket_codex/src/managed/managed_device_panel.dart';
import 'package:pocket_codex/src/managed/managed_host_editor.dart';
import 'package:pocket_codex/src/managed/managed_providers.dart';
import 'package:pocket_codex/src/managed/management_failure.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/adaptive_sheet.dart';
import 'package:pocket_codex/src/widgets/agent_icon.dart';

/// Pick a runtime installed on the remote computer behind [serviceKey], then
/// open its editor for a new service. Only what the computer reports is
/// offered; nothing is installed or signed in by looking.
Future<void> showManagedAddService(
  BuildContext context, {
  required String serviceKey,
  required String device,
  required List<ManagedHost> hosts,
}) async {
  final kind = await showAdaptivePanel<String>(
    context: context,
    builder: (_) => _AddServicePanel(serviceKey: serviceKey, hosts: hosts),
  );
  if (kind == null || !context.mounted) return;
  await showManagedHostEditor(
    context,
    serviceKey: serviceKey,
    device: device,
    kind: kind,
    takenNames: {for (final h in hosts) h.name},
  );
}

class _AddServicePanel extends ConsumerStatefulWidget {
  const _AddServicePanel({required this.serviceKey, required this.hosts});

  final String serviceKey;
  final List<ManagedHost> hosts;

  @override
  ConsumerState<_AddServicePanel> createState() => _AddServicePanelState();
}

class _AddServicePanelState extends ConsumerState<_AddServicePanel> {
  AcpClaudeSetup? _claude;
  String? _claudeError;
  Timer? _poll;
  bool _starting = false;

  @override
  void dispose() {
    // Stops only this panel's waiting; the host's preparation goes on.
    _poll?.cancel();
    super.dispose();
  }

  /// The explicit Prepare action: the only call that may start an install.
  Future<void> _prepare() async {
    // One explicit start at a time: a second tap never starts another.
    if (_starting || (_claude?.running ?? false)) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _starting = true;
      _claudeError = null;
    });
    try {
      final setup = await ref
          .read(bridgeApiProvider)
          .managedClaudePrepare(widget.serviceKey, start: true);
      if (!mounted) return;
      _show(setup);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _claudeError = managedFailureText(l10n, ManagementFailure.of(e)),
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _show(AcpClaudeSetup setup) {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _claude = setup;
      _claudeError = switch (setup.state) {
        'failed' => l10n.claudePrepareFailed(setup.error ?? ''),
        'cancelled' => l10n.claudePrepareStageCancelled,
        _ => null,
      };
    });
    _poll?.cancel();
    if (setup.running) {
      _poll = Timer(const Duration(seconds: 1), _read);
    } else if (setup.state == 'done') {
      ref.invalidate(managedRuntimesProvider(widget.serviceKey));
    }
  }

  Future<void> _read() async {
    try {
      final setup = await ref
          .read(bridgeApiProvider)
          .managedClaudePrepare(widget.serviceKey, start: false);
      if (mounted) _show(setup);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _claudeError = managedFailureText(
          AppLocalizations.of(context),
          ManagementFailure.of(e),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final runtimes = ref.watch(managedRuntimesProvider(widget.serviceKey));
    final openCodeTaken = widget.hosts.any(
      (h) => h.engine == 'opencode' && h.running,
    );
    // The adaptive panel adds no side insets; the body brings the same 20 px
    // the other panels use.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        key: const Key('managed-add-panel'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.managedAddService, style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            l10n.managedAddHint,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          ...runtimes.when(
            loading: () => [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
            ],
            error: (e, _) => [
              Text(
                managedFailureText(l10n, ManagementFailure.of(e)),
                key: const Key('managed-runtimes-error'),
                style: TextStyle(color: scheme.error),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.tonal(
                  key: const Key('managed-runtimes-retry'),
                  onPressed: () => ref.invalidate(
                    managedRuntimesProvider(widget.serviceKey),
                  ),
                  child: Text(l10n.retry),
                ),
              ),
            ],
            data: (list) => [
              if (list.isEmpty)
                Text(
                  l10n.managedNoRuntimes,
                  key: const Key('managed-no-runtimes'),
                  style: theme.textTheme.bodyMedium,
                ),
              for (final (i, runtime) in list.indexed) ...[
                if (i > 0) const SizedBox(height: 8),
                _RuntimeRow(
                  runtime: runtime,
                  blocked: runtime.kind == 'opencode' && openCodeTaken,
                  claude: runtime.kind == 'claude' ? _claude : null,
                  claudeError: runtime.kind == 'claude' ? _claudeError : null,
                  onPrepare: _starting || (_claude?.running ?? false)
                      ? null
                      : _prepare,
                  onChoose: () => Navigator.of(context).pop(runtime.kind),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// One installed runtime: its name and a short availability line first;
/// paths, versions and longer explanations behind an explicit Details
/// button (a tap target, so it works on touch too).
class _RuntimeRow extends StatelessWidget {
  const _RuntimeRow({
    required this.runtime,
    required this.onChoose,
    this.blocked = false,
    this.claude,
    this.claudeError,
    this.onPrepare,
  });

  final ManagedRuntimeAvailability runtime;

  /// OpenCode already runs on that computer (one per computer).
  final bool blocked;
  final AcpClaudeSetup? claude;
  final String? claudeError;
  final VoidCallback? onPrepare;
  final VoidCallback onChoose;

  bool get _ready => runtime.ready && !blocked;

  /// The short availability line and whether it is a caution.
  (String, bool) _status(AppLocalizations l10n) {
    if (blocked) return (l10n.managedOpenCodeRunning, true);
    if (!runtime.ready) {
      return runtime.canPrepare
          ? (l10n.managedRuntimeNeedsSetup, true)
          : (l10n.managedRuntimeUnavailable, true);
    }
    if (runtime.needsHostLogin) return (l10n.managedRuntimeSignInThere, false);
    return ([l10n.managedRuntimeReady, ?runtime.version].join(' · '), false);
  }

  /// The longer explanations, shown under Details.
  List<String> _notes(AppLocalizations l10n) => [
    if (blocked) l10n.managedOpenCodeTaken,
    if (!runtime.ready) ?runtime.problem,
    if (runtime.ready && runtime.needsHostLogin) l10n.managedNeedsHostLogin,
  ];

  Future<void> _details(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final name = managedKindLabel(l10n, runtime.kind);
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        key: Key('managed-runtime-details-dialog-${runtime.kind}'),
        // Phone-width room for long paths, and a title that stays a title
        // at large text sizes.
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        titleTextStyle: Theme.of(context).textTheme.titleLarge,
        title: Text(l10n.managedRuntimeDetailsTitle(name)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final note in _notes(l10n)) ...[
                Text(note),
                const SizedBox(height: 12),
              ],
              if (runtime.version case final version?)
                DiagnosticLine(
                  label: l10n.managedRuntimeVersion,
                  value: version,
                ),
              if (runtime.path case final path?)
                DiagnosticLine(label: l10n.managedRuntimePath, value: path),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.done),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (status, caution) = _status(l10n);
    final hasDetails =
        runtime.path != null ||
        runtime.version != null ||
        _notes(l10n).isNotEmpty;
    return Card.outlined(
      key: Key('managed-runtime-${runtime.kind}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _ready ? onChoose : null,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 4, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  AgentIcon.of(
                    provider: runtime.kind == 'claude' ? 'acp' : runtime.kind,
                    profileId: runtime.kind == 'claude' ? 'claude' : null,
                    size: 24,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          managedKindLabel(l10n, runtime.kind),
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          status,
                          key: Key('managed-runtime-status-${runtime.kind}'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: caution
                                ? cautionColor(scheme)
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (hasDetails)
                    IconButton(
                      key: Key('managed-runtime-details-${runtime.kind}'),
                      tooltip: l10n.managedRuntimeDetails,
                      icon: Icon(Icons.info_outline, color: scheme.tertiary),
                      onPressed: () => _details(context),
                    ),
                  if (_ready)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: Icon(Icons.chevron_right, color: scheme.tertiary),
                    ),
                ],
              ),
              if (!runtime.ready && runtime.canPrepare) ...[
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 38, end: 12),
                  child: claude?.running ?? false
                      ? ClaudePreparationProgress(
                          key: const Key('managed-claude-progress'),
                          setup: claude!,
                        )
                      : Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: FilledButton.tonal(
                            key: const Key('managed-claude-prepare'),
                            onPressed: onPrepare,
                            child: Text(l10n.claudePrepareEnvironment),
                          ),
                        ),
                ),
              ],
              if (claudeError case final error?)
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(38, 8, 12, 0),
                  child: Text(
                    error,
                    key: const Key('managed-claude-error'),
                    style: TextStyle(color: cautionColor(scheme)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
