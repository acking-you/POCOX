/// The agent tools' app-wide presence: it keeps the live catalog of every
/// device subscribed, asks the user about agents' share requests, and says
/// when a share appears, above whatever page is open.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/glass_recipe.dart';
import 'package:pocket_codex/src/motion.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/tools/planet_glyph.dart';
import 'package:pocket_codex/src/tools/share_card.dart';
import 'package:pocket_codex/src/tools/tools_actions.dart';
import 'package:pocket_codex/src/tools/tools_providers.dart';
import 'package:pocket_codex/src/widgets/agent_icon.dart';
import 'package:pocket_codex/src/widgets/glass.dart';
import 'package:pocket_codex/src/widgets/links.dart';

/// The mark of the harness behind [owner].
Widget ownerMark(ToolsOwner owner, {double size = 18}) {
  if (!owner.isAgent) return Icon(AppIcons.person_outline, size: size);
  final kind = switch (owner.harness) {
    'codex' => AgentKind.codex,
    'claude' => AgentKind.claude,
    'opencode' => AgentKind.opencode,
    _ => AgentKind.other,
  };
  return AgentIcon(kind: kind, name: owner.label, size: size);
}

/// One thing the host is showing.
sealed class _Prompt {
  const _Prompt(this.device, this.id);
  final String device;
  final String id;
  String get key => '$runtimeType/$device/$id';
}

final class _Consent extends _Prompt {
  const _Consent(super.device, super.id);
}

final class _NewShare extends _Prompt {
  const _NewShare(super.device, super.id);
}

/// Wraps the app's pages with the agent tools' prompts.
class ToolsHost extends ConsumerStatefulWidget {
  /// Hosts the prompts above [child].
  const ToolsHost({super.key, required this.child});

  /// The pages.
  final Widget child;

  @override
  ConsumerState<ToolsHost> createState() => _ToolsHostState();
}

class _ToolsHostState extends ConsumerState<ToolsHost> {
  final List<_Prompt> _prompts = [];
  final Map<String, Timer> _expiry = {};
  final Set<String> _answering = {};

  @override
  void initState() {
    super.initState();
    pocoxLinkHandler = _openLink;
  }

  @override
  void dispose() {
    if (pocoxLinkHandler == _openLink) pocoxLinkHandler = null;
    for (final timer in _expiry.values) {
      timer.cancel();
    }
    super.dispose();
  }

  Future<bool> _openLink(BuildContext context, String url) async {
    final share = parseOpenLink(url);
    if (share == null) return false;
    await openShare(context, ref, share);
    return true;
  }

  void _arrived(ToolsUpdate update) {
    final overview = update.overview;
    var changed = false;
    for (final added in update.consentsAdded) {
      final prompt = _Consent(added.device, added.id);
      if (_prompts.every((p) => p.key != prompt.key)) {
        _prompts.add(prompt);
        changed = true;
      }
    }
    for (final added in update.added) {
      final found = overview.devices
          .where((d) => d.name == added.device)
          .expand((d) => d.shares)
          .where((s) => s.id == added.id)
          .firstOrNull;
      // The user's own shares made here need no announcement.
      final own =
          added.device == overview.thisDevice && found?.owner.isAgent != true;
      if (found == null || own) continue;
      final prompt = _NewShare(added.device, added.id);
      if (_prompts.any((p) => p.key == prompt.key)) continue;
      // Connected right away, so Open is instant: at its own port numbers
      // when they are free here.
      if (added.device != overview.thisDevice) {
        final api = ref.read(bridgeApiProvider);
        for (final port in found.ports) {
          if (overview.connectionTo(port.key) == null) {
            unawaited(api.toolsConnect(port.key).then((_) {}, onError: (_) {}));
          }
        }
      }
      _prompts.add(prompt);
      _expiry[prompt.key] = Timer(
        const Duration(seconds: 12),
        () => _dismiss(prompt),
      );
      changed = true;
    }
    // Requests answered elsewhere, or lapsed, leave on their own.
    final before = _prompts.length;
    _prompts.removeWhere(
      (p) => p is _Consent && _consentOf(overview, p) == null,
    );
    if (changed || before != _prompts.length) setState(() {});
  }

  ToolsConsent? _consentOf(ToolsOverview overview, _Prompt prompt) => overview
      .devices
      .where((d) => d.name == prompt.device)
      .expand((d) => d.consents)
      .where((c) => c.id == prompt.id)
      .firstOrNull;

  ToolsShare? _shareOf(ToolsOverview overview, _Prompt prompt) => overview
      .devices
      .where((d) => d.name == prompt.device)
      .expand((d) => d.shares)
      .where((s) => s.id == prompt.id)
      .firstOrNull;

  void _dismiss(_Prompt prompt) {
    _expiry.remove(prompt.key)?.cancel();
    if (!mounted) return;
    setState(() => _prompts.removeWhere((p) => p.key == prompt.key));
  }

  Future<void> _answer(
    BuildContext context,
    _Consent prompt,
    ToolsConsent consent,
    String decision,
  ) async {
    setState(() => _answering.add(prompt.key));
    final ok = await answerConsent(
      context,
      ref,
      prompt.device,
      consent,
      decision,
    );
    if (!mounted) return;
    setState(() => _answering.remove(prompt.key));
    if (ok) _dismiss(prompt);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<ToolsUpdate>>(toolsUpdatesProvider, (_, next) {
      if (next.valueOrNull case final update?) _arrived(update);
    });
    final overview = ref.watch(toolsOverviewProvider);
    final cards = <Widget>[
      for (final prompt in _prompts.take(3))
        switch (prompt) {
          _Consent() => switch (_consentOf(overview, prompt)) {
            final consent? => _ConsentCard(
              key: ValueKey(prompt.key),
              device: prompt.device,
              thisDevice: overview.thisDevice,
              consent: consent,
              busy: _answering.contains(prompt.key),
              onAnswer: (decision) =>
                  _answer(context, prompt, consent, decision),
            ),
            null => const SizedBox.shrink(),
          },
          _NewShare() => switch (_shareOf(overview, prompt)) {
            final share? => _ShareNotice(
              key: ValueKey(prompt.key),
              device: prompt.device,
              thisDevice: overview.thisDevice,
              share: share,
              onClose: () => _dismiss(prompt),
            ),
            null => const SizedBox.shrink(),
          },
        },
    ];
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 720;
    final top = MediaQuery.paddingOf(context).top + (wide ? 64 : 8);
    return Stack(
      children: [
        widget.child,
        if (cards.isNotEmpty)
          Positioned(
            top: top,
            right: 12,
            left: wide ? null : 12,
            width: wide ? 400 : null,
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final card in cards)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: card,
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// An entrance for a prompt: a short rise and fade.
class _Arrive extends StatelessWidget {
  const _Arrive({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: Motion.medium,
    curve: Motion.emphasized,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.translate(
        offset: Offset(0, (1 - t) * -10),
        child: child,
      ),
    ),
    child: child,
  );
}

class _ConsentCard extends StatelessWidget {
  const _ConsentCard({
    super.key,
    required this.device,
    required this.thisDevice,
    required this.consent,
    required this.busy,
    required this.onAnswer,
  });

  final String device;
  final String thisDevice;
  final ToolsConsent consent;
  final bool busy;
  final void Function(String decision) onAnswer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final where = device == thisDevice ? l10n.toolsThisDevice : device;
    final known = consent.owner.conversation != null;
    return _Arrive(
      child: Glass(
        depth: GlassDepth.overlay,
        borderRadius: BorderRadius.circular(18),
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
        child: Column(
          key: Key('consent-${consent.id}'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                ownerMark(consent.owner),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.toolsRequestTitle(ownerLabel(l10n, consent.owner)),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              l10n.toolsRequestDetail(
                consent.title,
                consent.ports.join(', '),
                where,
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 6,
              runSpacing: 6,
              children: [
                TextButton(
                  key: Key('consent-deny-${consent.id}'),
                  onPressed: busy ? null : () => onAnswer('deny'),
                  child: Text(l10n.toolsDeny),
                ),
                if (known)
                  OutlinedButton(
                    key: Key('consent-conversation-${consent.id}'),
                    onPressed: busy
                        ? null
                        : () => onAnswer('allow_conversation'),
                    child: Text(l10n.toolsAllowConversation),
                  ),
                FilledButton(
                  key: Key('consent-allow-${consent.id}'),
                  onPressed: busy ? null : () => onAnswer('allow_once'),
                  child: Text(l10n.toolsAllowOnce),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareNotice extends ConsumerWidget {
  const _ShareNotice({
    super.key,
    required this.device,
    required this.thisDevice,
    required this.share,
    required this.onClose,
  });

  final String device;
  final String thisDevice;
  final ToolsShare share;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final where = device == thisDevice ? l10n.toolsThisDevice : device;
    return _Arrive(
      child: Glass(
        depth: GlassDepth.overlay,
        borderRadius: BorderRadius.circular(18),
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        child: Row(
          key: Key('share-notice-${share.id}'),
          children: [
            PlanetGlyph(
              color: statusColor(scheme, share.status),
              size: 34,
              orbit: share.owner.isAgent,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l10n.toolsNewShare(where, share.title),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    l10n.toolsBy(ownerLabel(l10n, share.owner)),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            FilledButton.tonal(
              key: Key('share-notice-open-${share.id}'),
              onPressed: () {
                onClose();
                openShare(context, ref, shareRefOf(share));
              },
              child: Text(l10n.toolsOpen),
            ),
            IconButton(
              onPressed: onClose,
              icon: const Icon(AppIcons.close, size: 16),
            ),
          ],
        ),
      ),
    );
  }
}
