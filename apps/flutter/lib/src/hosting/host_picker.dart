import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/hosting/host_editor_page.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/widgets/agent_icon.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/widgets/app_dialog.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';

/// Open the hosting editor from a place that is not about one host (Settings,
/// Codex setup): with no local host, the editor for a new one (nothing starts
/// until its Start); otherwise the user picks a running host by its own
/// identity, or a new one. Choosing saves, starts, stops and signs in nothing;
/// the editor is pushed from [context], so leaving it returns there.
///
/// One entry at a time per originating page: another activation while this
/// one reads the hosts, shows the picker or has the editor open does nothing.
/// Nothing opens once the page is no longer on top (another page was pushed
/// over it, or it is leaving) or no longer mounted.
Future<void> configureHosting(BuildContext context, WidgetRef ref) async {
  final route = ModalRoute.of(context);
  final Object origin = route ?? context;
  // The page still owns navigation: it is on top, not leaving.
  bool onTop() => route?.isCurrent ?? true;
  if (_entering[origin] != null || !context.mounted || !onTop()) return;
  _entering[origin] = true;
  try {
    var hosts = const <AppServeStatus>[];
    var failed = false;
    try {
      hosts = await ref.read(localServeListProvider.future);
    } catch (_) {
      failed = true;
      // The provider keeps its error; the next entry reads again.
      if (context.mounted) ref.invalidate(localServeListProvider);
    }
    if (!context.mounted || !onTop()) return;
    var pick = const _Pick(null);
    if (hosts.isNotEmpty || failed) {
      final picked = await showAppDialog<_Pick>(
        context: context,
        builder: (_) => _HostPicker(hosts: hosts, failed: failed),
      );
      if (picked == null || !context.mounted || !onTop()) return;
      pick = picked;
    }
    await showHostingEditor(context, existing: pick.host);
  } finally {
    _entering[origin] = null;
  }
}

/// The pages (routes) with a [configureHosting] entry in progress.
final _entering = Expando<bool>('configureHosting');

/// The picked host; a null [host] is a new one.
class _Pick {
  const _Pick(this.host);

  final AppServeStatus? host;
}

class _HostPicker extends StatelessWidget {
  const _HostPicker({required this.hosts, required this.failed});

  final List<AppServeStatus> hosts;

  /// The running hosts could not be read; only a new host is offered.
  final bool failed;

  /// Close with [pick] while the picker is still on top: a second
  /// activation during its exit closes nothing beneath it.
  static void _close(BuildContext context, [_Pick? pick]) {
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      Navigator.of(context).pop(pick);
    }
  }

  static String _agent(AppServeStatus host) => host.providerName.isNotEmpty
      ? host.providerName
      : host.isCodex
      ? 'Codex'
      : host.isOpenCode
      ? 'OpenCode'
      : host.profileId ?? host.provider;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AlertDialog(
      key: const Key('host-picker'),
      scrollable: true,
      // What picking (and saving) does is behind the title's info mark.
      title: InfoTitle(
        title: Text(l10n.hostPickTitle),
        info: l10n.hostPickHint,
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (failed) ...[
              Text(
                l10n.hostPickLoadFailed,
                key: const Key('host-pick-failed'),
                style: helpTextStyle(theme).copyWith(color: scheme.error),
              ),
              const SizedBox(height: 8),
            ],
            for (final host in hosts)
              ListTile(
                key: Key('host-pick-${host.appServiceKey}'),
                contentPadding: EdgeInsets.zero,
                leading: AgentIcon.of(
                  provider: host.provider,
                  profileId: host.profileId,
                  name: host.providerName,
                  size: 20,
                ),
                title: Text(host.name),
                subtitle: Text(_agent(host)),
                trailing: const Icon(AppIcons.chevron_right),
                onTap: () => _close(context, _Pick(host)),
              ),
            ListTile(
              key: const Key('host-pick-new'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.add),
              title: Text(l10n.hostPickNew),
              onTap: () => _close(context, const _Pick(null)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('host-pick-cancel'),
          onPressed: () => _close(context),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
      ],
    );
  }
}
