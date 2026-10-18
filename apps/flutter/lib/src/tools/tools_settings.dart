/// Settings › Agent tools: the switch, asking first, the endpoint, adding the
/// tools to agents POCOX does not start, and the tokens issued for them.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/error_format.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/theme.dart';
import 'package:pocket_codex/src/tools/tools_providers.dart';
import 'package:pocket_codex/src/widgets/app_toast.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';
import 'package:pocket_codex/src/widgets/group_card.dart';
import 'package:pocket_codex/src/widgets/icon_badge.dart';

/// The Agent tools settings group (desktops: phones do not serve the tools).
class AgentToolsSettings extends ConsumerStatefulWidget {
  /// Creates the group.
  const AgentToolsSettings({super.key});

  @override
  ConsumerState<AgentToolsSettings> createState() => _AgentToolsSettingsState();
}

class _AgentToolsSettingsState extends ConsumerState<AgentToolsSettings> {
  bool _busy = false;

  Future<void> _set(Future<AgentToolsStatus> Function(BridgeApi) change) async {
    setState(() => _busy = true);
    final messenger = ToastMessenger.of(context);
    try {
      final status = await change(ref.read(bridgeApiProvider));
      if (mounted) ref.read(toolsStatusProvider.notifier).state = status;
    } catch (error) {
      messenger.error(friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyConfig(String harness) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ToastMessenger.of(context);
    try {
      final text = await ref
          .read(bridgeApiProvider)
          .toolsHarnessConfig(harness);
      await Clipboard.setData(ClipboardData(text: text));
      messenger.ok(l10n.toolsConfigCopied);
      if (mounted) setState(() {});
    } catch (error) {
      messenger.error(friendlyError(error));
    }
  }

  Future<void> _revoke(ToolsToken token) async {
    if (_busy) return;
    setState(() => _busy = true);
    final l10n = AppLocalizations.of(context);
    final messenger = ToastMessenger.of(context);
    try {
      await ref.read(bridgeApiProvider).toolsRevoke(token.id);
      messenger.ok(l10n.toolsRevoked);
    } catch (error) {
      messenger.error(friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = ref.watch(toolsStatusProvider);
    final tokens = [
      for (final token in ref.read(bridgeApiProvider).toolsTokens())
        if (token.kind == 'installed') token,
    ];
    Widget row({
      required IconData icon,
      required String title,
      String? info,
      String? value,
      Widget? trailing,
      Key? key,
    }) => Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(13, 8, 10, 8),
      child: Row(
        children: [
          IconBadge(icon: icon),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InfoTitle(
                  title: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  info: info,
                ),
                if (value != null)
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: helpTextStyle(theme),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
    return GroupCard(
      title: l10n.toolsTitle,
      children: [
        row(
          key: const Key('tools-switch-row'),
          icon: AppIcons.orbit,
          title: l10n.toolsSwitch,
          info: l10n.toolsSwitchInfo,
          trailing: Switch(
            key: const Key('tools-switch'),
            value: status.enabled,
            onChanged: _busy
                ? null
                : (on) => _set((api) => api.toolsSetEnabled(on)),
          ),
        ),
        row(
          icon: AppIcons.shield_outlined,
          title: l10n.toolsAsk,
          trailing: Switch(
            key: const Key('tools-ask'),
            value: status.askBeforeSharing,
            onChanged: _busy || !status.enabled
                ? null
                : (ask) => _set((api) => api.toolsSetAskBeforeSharing(ask)),
          ),
        ),
        row(
          icon: AppIcons.link_outlined,
          title: l10n.toolsEndpoint,
          value: status.endpoint ?? l10n.toolsNotServing,
          trailing: status.endpoint == null
              ? null
              : IconButton(
                  tooltip: l10n.copy,
                  icon: const Icon(AppIcons.copy, size: 17),
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: status.endpoint!),
                    );
                    if (context.mounted) showToastOk(context, l10n.copied);
                  },
                ),
        ),
        if (status.problem case final problem?)
          Padding(
            padding: const EdgeInsets.fromLTRB(58, 0, 14, 8),
            child: Text(
              problem,
              style: helpTextStyle(theme).copyWith(color: cautionColor(scheme)),
            ),
          ),
        row(
          icon: AppIcons.add,
          title: l10n.toolsAddToHarness,
          info: l10n.toolsAddToHarnessInfo,
          trailing: PopupMenuButton<String>(
            key: const Key('tools-copy-config'),
            enabled: status.endpoint != null,
            onSelected: _copyConfig,
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'claude', child: Text('Claude Code')),
              const PopupMenuItem(value: 'codex', child: Text('Codex')),
              const PopupMenuItem(value: 'opencode', child: Text('OpenCode')),
              PopupMenuItem(
                value: 'generic',
                child: Text(l10n.toolsHarnessGeneric),
              ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(
                l10n.copy,
                style: TextStyle(
                  color: status.endpoint == null
                      ? scheme.onSurface.withValues(alpha: 0.38)
                      : scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
        for (final token in tokens)
          row(
            key: Key('tools-token-${token.id}'),
            icon: AppIcons.key_outlined,
            title: token.label,
            value: l10n.toolsTokens,
            trailing: TextButton(
              onPressed: _busy ? null : () => _revoke(token),
              child: Text(l10n.toolsRevoke),
            ),
          ),
      ],
    );
  }
}
