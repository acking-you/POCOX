import 'package:flutter/material.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/relay_diagnosis.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/error_details.dart';

/// The relay could not be reached: what is wrong in words, a retry, and the
/// raw error folded away, whole and copyable.
///
/// [compact] heads a page that still has something to show (this computer's
/// own services); otherwise it is the page's whole body.
class RelayProblem extends StatefulWidget {
  /// Creates the problem for [detail], a failed request to [relay].
  const RelayProblem({
    super.key,
    required this.detail,
    required this.onRetry,
    this.relay,
    this.compact = false,
    this.actions = const [],
  });

  /// The error, as the bridge reported it.
  final String detail;

  /// The configured relay `host:port`, when known.
  final String? relay;

  /// Ask the relay again.
  final VoidCallback onRetry;

  /// A banner over other content rather than the page's body.
  final bool compact;

  /// The page's other ways forward, beside the retry (page body only).
  final List<Widget> actions;

  @override
  State<RelayProblem> createState() => _RelayProblemState();
}

class _RelayProblemState extends State<RelayProblem> {
  RelayDiagnosis? _diagnosis;
  int _lookup = 0; // only the latest name lookup may change the diagnosis

  @override
  void initState() {
    super.initState();
    _diagnose();
  }

  @override
  void didUpdateWidget(RelayProblem old) {
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

  String _cause(AppLocalizations l10n) => switch (_diagnosis) {
    RelayVirtualAddress(:final host, :final address) =>
      l10n.relayVirtualAddress(host, address),
    RelayNoAnswer(:final relay) => l10n.relayNoAnswer(relay),
    // The first line is the bridge's own summary of what it was doing.
    null => widget.detail.split('\n').first.trim(),
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final title = Text(
      l10n.discoverFailed,
      key: const Key('services-error'),
      style: widget.compact
          ? theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)
          : theme.textTheme.titleMedium,
      textAlign: widget.compact ? TextAlign.start : TextAlign.center,
    );
    final cause = Text(
      _cause(l10n),
      key: const Key('relay-problem-cause'),
      style: theme.textTheme.bodyMedium?.copyWith(color: muted),
      textAlign: widget.compact ? TextAlign.start : TextAlign.center,
    );
    final details = ErrorDetails(
      detail: widget.detail,
      tileKey: const Key('relay-problem-details'),
    );
    if (widget.compact) {
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(kCardRadius),
          boxShadow: raisedCardShadows(theme.colorScheme),
        ),
        child: Card(
          key: const Key('relay-problem'),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(AppIcons.cloud_off, size: 18, color: muted),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [title, const SizedBox(height: 2), cause],
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      key: const Key('relay-problem-retry'),
                      onPressed: widget.onRetry,
                      icon: const Icon(AppIcons.refresh, size: 16),
                      label: Text(l10n.retry),
                    ),
                  ],
                ),
                details,
              ],
            ),
          ),
        ),
      );
    }
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
              title,
              const SizedBox(height: 6),
              cause,
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 10,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    key: const Key('relay-problem-retry'),
                    onPressed: widget.onRetry,
                    icon: const Icon(AppIcons.refresh, size: 16),
                    label: Text(l10n.retry),
                  ),
                  ...widget.actions,
                ],
              ),
              const SizedBox(height: 8),
              details,
            ],
          ),
        ),
      ),
    );
  }
}
