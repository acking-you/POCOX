import 'package:flutter/material.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/relay_diagnosis.dart';
import 'package:pocox/src/widgets/error_details.dart';

/// The relay could not be reached, as a page's whole body: what is wrong in
/// words, a retry beside the page's other ways forward, and the raw error
/// folded away, whole and copyable.
class RelayProblem extends StatelessWidget {
  /// Creates the problem for [detail], a failed request to [relay].
  const RelayProblem({
    super.key,
    required this.detail,
    required this.onRetry,
    this.relay,
    this.actions = const [],
  });

  /// The error, as the bridge reported it.
  final String detail;

  /// The configured relay `host:port`, when known.
  final String? relay;

  /// Ask the relay again.
  final VoidCallback onRetry;

  /// The page's other ways forward, beside the retry.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Center(
      key: const Key('relay-problem'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(AppIcons.cloud_off, size: 28, color: muted),
              const SizedBox(height: 12),
              Text(
                l10n.discoverFailed,
                key: const Key('services-error'),
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              RelayCause(
                detail: detail,
                relay: relay,
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const Key('relay-problem-retry'),
                    onPressed: onRetry,
                    icon: const Icon(AppIcons.refresh, size: 16),
                    label: Text(l10n.retry),
                  ),
                  ...actions,
                ],
              ),
              const SizedBox(height: 8),
              ErrorDetails(
                detail: detail,
                tileKey: const Key('relay-problem-details'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Why the relay could not be reached, in words: what the error says at
/// once, and what the relay's name resolves to when that says more.
class RelayCause extends StatefulWidget {
  /// Creates the cause of [detail], a failed request to [relay].
  const RelayCause({
    super.key,
    required this.detail,
    this.relay,
    this.style,
    this.textAlign,
  });

  /// The error, as the bridge reported it.
  final String detail;

  /// The configured relay `host:port`, when known.
  final String? relay;

  /// The text's style.
  final TextStyle? style;

  /// The text's alignment.
  final TextAlign? textAlign;

  @override
  State<RelayCause> createState() => _RelayCauseState();
}

class _RelayCauseState extends State<RelayCause> {
  RelayDiagnosis? _diagnosis;
  int _lookup = 0; // only the latest name lookup may change the diagnosis

  @override
  void initState() {
    super.initState();
    _diagnose();
  }

  @override
  void didUpdateWidget(RelayCause old) {
    super.didUpdateWidget(old);
    if (old.detail != widget.detail || old.relay != widget.relay) {
      _diagnose();
    }
  }

  Future<void> _diagnose() async {
    final lookup = ++_lookup;
    final detail = widget.detail;
    final relay = relayAddressOf(widget.relay, detail);
    // What the error says at once; the relay's name, resolved, may say why.
    _diagnosis = relayFailureOf(relay, detail);
    final virtual = await relayVirtualAddressOf(relay);
    if (virtual == null || !mounted || lookup != _lookup) return;
    setState(() => _diagnosis = virtual);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Text(
      switch (_diagnosis) {
        RelayVirtualAddress(:final host, :final address) =>
          l10n.relayVirtualAddress(host, address),
        RelayNoAnswer(:final relay) => l10n.relayNoAnswer(relay),
        // The first line is the bridge's own summary of what it was doing.
        null => widget.detail.split('\n').first.trim(),
      },
      key: const Key('relay-problem-cause'),
      style: widget.style,
      textAlign: widget.textAlign,
    );
  }
}
