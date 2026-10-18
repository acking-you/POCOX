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
import 'package:pocket_codex/src/fonts.dart';
import 'package:pocket_codex/src/glass_recipe.dart';
import 'package:pocket_codex/src/motion.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/service_key.dart';
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

/// A new share the host is announcing.
class _Notice {
  const _Notice(this.device, this.id);
  final String device;
  final String id;
  String get key => '$device/$id';
}

String _consentKey(String device, String id) => '$device/$id';

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
  final List<_Notice> _notices = [];
  final Map<String, Timer> _expiry = {};

  /// Requests being answered here.
  final Set<String> _answering = {};

  /// Requests answered here: hidden until their device stops listing them,
  /// however late a stale overview drops them.
  final Set<String> _answered = {};

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
    final api = ref.read(bridgeApiProvider);
    final pending = {
      for (final entry in overview.consents)
        _consentKey(entry.device.name, entry.consent.id),
    };
    _answered.retainWhere(pending.contains);
    var changed = false;
    for (final added in update.added) {
      final found = _shareOf(overview, added.device, added.id);
      // The user's own shares made here need no announcement.
      final own =
          added.device == overview.thisDevice && found?.owner.isAgent != true;
      if (found == null || own) continue;
      final notice = _Notice(added.device, added.id);
      if (_notices.any((n) => n.key == notice.key)) continue;
      // A phone connects it right away, so Open is instant: at its own port
      // numbers when they are free here. A desktop connects on Open.
      if (!isDesktop && added.device != overview.thisDevice) {
        for (final port in found.ports) {
          if (overview.connectionTo(port.key) == null) {
            _autoConnect(api, added.device, port.key);
          }
        }
      }
      _notices.add(notice);
      _expiry[notice.key] = Timer(
        const Duration(seconds: 12),
        () => _dismiss(notice),
      );
      changed = true;
    }
    _endEnded(api, overview);
    if (changed) setState(() {});
  }

  void _autoConnect(BridgeApi api, String device, String key) {
    final connected = ref.read(shareConnectionsProvider);
    connected[key] = device;
    unawaited(
      api.toolsConnect(key).then((_) {
        // Its share ended while it connected.
        if (!connected.containsKey(key)) _disconnect(api, key);
      }, onError: (_) => connected.remove(key)),
    );
  }

  /// End the connections made for a share that ended: its device's catalog
  /// is here and lists it no more. A device whose catalog is missing (its
  /// stream dropped) keeps them.
  void _endEnded(BridgeApi api, ToolsOverview overview) {
    final connected = ref.read(shareConnectionsProvider);
    for (final MapEntry(:key, value: name) in [...connected.entries]) {
      final device = overview.devices.where((d) => d.name == name).firstOrNull;
      if (device == null || !device.catalog) continue;
      if (device.shares.any((s) => s.ports.any((p) => p.key == key))) continue;
      connected.remove(key);
      _disconnect(api, key);
    }
  }

  void _disconnect(BridgeApi api, String key) =>
      unawaited(api.toolsDisconnect(key).then((_) {}, onError: (_) {}));

  ToolsShare? _shareOf(ToolsOverview overview, String device, String id) =>
      overview.devices
          .where((d) => d.name == device)
          .expand((d) => d.shares)
          .where((s) => s.id == id)
          .firstOrNull;

  void _dismiss(_Notice notice) {
    _expiry.remove(notice.key)?.cancel();
    if (!mounted) return;
    setState(() => _notices.removeWhere((n) => n.key == notice.key));
  }

  Future<void> _answer(
    BuildContext context,
    String device,
    ToolsConsent consent,
    String decision,
  ) async {
    final key = _consentKey(device, consent.id);
    setState(() => _answering.add(key));
    final ok = await answerConsent(context, ref, device, consent, decision);
    if (!mounted) return;
    setState(() {
      _answering.remove(key);
      if (ok) _answered.add(key);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<ToolsUpdate>>(toolsUpdatesProvider, (_, next) {
      if (next.valueOrNull case final update?) _arrived(update);
    });
    final overview = ref.watch(toolsOverviewProvider);
    // Every pending request, whichever device holds it, oldest first; then
    // the new shares.
    final cards = <Widget>[
      for (final (:device, :consent) in overview.consents)
        if (_consentKey(device.name, consent.id) case final key
            when !_answered.contains(key))
          _ConsentCard(
            key: ValueKey('consent/$key'),
            device: device.name,
            thisDevice: overview.thisDevice,
            consent: consent,
            busy: _answering.contains(key),
            onAnswer: (decision) =>
                _answer(context, device.name, consent, decision),
          ),
      for (final notice in _notices)
        if (_shareOf(overview, notice.device, notice.id) case final share?)
          _ShareNotice(
            key: ValueKey('share/${notice.key}'),
            device: notice.device,
            thisDevice: overview.thisDevice,
            share: share,
            onClose: () => _dismiss(notice),
          ),
    ].take(3).toList();
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
    duration: Motion.of(context, Motion.medium),
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
    final where = device == thisDevice
        ? l10n.toolsThisDevice
        : deviceLabel(device);
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
    final where = device == thisDevice
        ? l10n.toolsThisDevice
        : deviceLabel(device);
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
