import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/desktop_theme.dart';
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/relay_diagnosis.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';

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
    final details = _Details(detail: widget.detail);
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

/// The raw error, folded: whole, selectable and copyable once opened.
class _Details extends StatelessWidget {
  const _Details({required this.detail});

  final String detail;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Material(
      // An own ink layer: a coloured ancestor would hide the tile's.
      type: MaterialType.transparency,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const Key('relay-problem-details'),
          tilePadding: EdgeInsets.zero,
          dense: true,
          childrenPadding: const EdgeInsets.only(bottom: 10),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          title: Text(
            l10n.errorDetails,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          children: [
            SelectableText(
              detail,
              style: TextStyle(
                fontFamily: monoFontFamily,
                fontFamilyFallback: monoCjkFallback,
                fontSize: 12,
                height: 1.45,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: detail));
                  if (context.mounted) showToast(context, l10n.copied);
                },
                icon: const Icon(AppIcons.copy, size: 16),
                label: Text(l10n.copy),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
