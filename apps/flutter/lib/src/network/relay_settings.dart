import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/fonts.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/widgets/app_dialog.dart';

final relayPreferencesProvider = FutureProvider.autoDispose<RelayPreferences>(
  (ref) => ref.watch(bridgeApiProvider).relayPreferences(),
);

/// Poll local SDK observations only while the settings page is visible.
final relaySubscriptionsProvider = FutureProvider.autoDispose<List<SubInfo>>((
  ref,
) async {
  Timer? refresh;
  var active = true;
  var finished = false;
  void schedule() {
    refresh?.cancel();
    if (active && finished) {
      refresh = Timer(const Duration(seconds: 3), ref.invalidateSelf);
    }
  }

  ref.onCancel(() {
    active = false;
    refresh?.cancel();
  });
  ref.onResume(() {
    active = true;
    schedule();
  });
  ref.onDispose(() {
    active = false;
    refresh?.cancel();
  });
  try {
    return await ref.watch(bridgeApiProvider).subscriptions();
  } finally {
    finished = true;
    schedule();
  }
});

String relayPathLabel(AppLocalizations l10n, SubInfo sub) {
  if (!sub.alive) return l10n.subscribedDead;
  final path = switch (sub.path) {
    'relay_only' => l10n.relayPathRelayOnly,
    'direct' => l10n.relayPathDirect,
    'relay' => l10n.relayPathRelayed,
    'mixed' => l10n.relayPathMixed(sub.activeDirect, sub.activeRelay),
    'idle' => l10n.relayPathIdle,
    _ => l10n.relayPathUnknown,
  };
  return sub.fallbacks > 0
      ? '$path · ${l10n.relayPathFallbacks(sub.fallbacks)}'
      : path;
}

class RelaySettingsRow extends ConsumerWidget {
  const RelaySettingsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(relayPreferencesProvider);
    return ListTile(
      key: const Key('relay-path-settings'),
      leading: const Icon(AppIcons.link_outlined),
      title: Text(l10n.relayPathTitle),
      subtitle: Text(
        settings.hasError
            ? l10n.relayPathReadFailed
            : settings.valueOrNull == null
            ? l10n.relayPathUnknown
            : settings.valueOrNull!.path == 'auto'
            ? l10n.relayPathAuto
            : l10n.relayPathRelayOnly,
      ),
      trailing: const Icon(AppIcons.edit_outlined),
      onTap: settings.isLoading
          ? null
          : () async {
              if (settings.hasError) {
                ref.invalidate(relayPreferencesProvider);
                return;
              }
              final saved = await showAppDialog<bool>(
                context: context,
                builder: (_) => _RelayEditor(
                  api: ref.read(bridgeApiProvider),
                  initial: settings.requireValue,
                ),
              );
              if (saved == true && context.mounted) {
                ref.invalidate(relayPreferencesProvider);
              }
            },
    );
  }
}

class _RelayEditor extends StatefulWidget {
  const _RelayEditor({required this.api, required this.initial});
  final BridgeApi api;
  final RelayPreferences initial;
  @override
  State<_RelayEditor> createState() => _RelayEditorState();
}

class _RelayEditorState extends State<_RelayEditor> {
  late String _path = widget.initial.path;
  late bool _allowDirect = widget.initial.allowDirect;
  bool _busy = false;
  bool _failed = false;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await widget.api.relaySetPreferences(
        RelayPreferences(path: _path, allowDirect: _allowDirect),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(l10n.relayPathTitle),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  key: const Key('relay-path-policy'),
                  initialValue: _path,
                  isExpanded: true,
                  items: [
                    DropdownMenuItem(
                      value: 'relay_only',
                      child: Text(l10n.relayPathRelayOnly),
                    ),
                    DropdownMenuItem(
                      value: 'auto',
                      child: Text(l10n.relayPathAuto),
                    ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _path = value!),
                ),
                const SizedBox(height: 16),
                Text(l10n.relayPathExplanation),
                if (isDesktop)
                  SwitchListTile.adaptive(
                    key: const Key('relay-allow-direct'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.relayAllowDirect),
                    subtitle: Text(l10n.relayAllowDirectHint),
                    value: _allowDirect,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _allowDirect = value),
                  ),
                const SizedBox(height: 16),
                Text(l10n.relayPathApplyHint),
                if (_failed)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      l10n.relayPathSaveFailed,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('relay-path-save'),
            onPressed: _busy ? null : _save,
            child: Text(l10n.save),
          ),
        ],
      ),
    );
  }
}
