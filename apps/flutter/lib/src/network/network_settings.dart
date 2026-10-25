import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/hosting/editor_block.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/widgets/app_dialog.dart';
import 'package:pocox/src/widgets/field_help.dart';

/// The setting is read separately from the ordinary, non-secret config view.
/// Each read looks at the system's proxy again.
final networkProxyProvider = FutureProvider<NetworkProxySetting>((ref) {
  return ref.watch(bridgeApiProvider).networkProxySetting();
});

/// `url` as `scheme://host:port`, without credentials or path.
String _bare(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasAuthority) return url;
  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  return '${uri.scheme}://$host${uri.hasPort ? ':${uri.port}' : ''}';
}

/// What the system offers now, in a line.
String _systemLine(AppLocalizations l10n, NetworkProxySetting setting) =>
    switch (setting.system) {
      final proxy? => l10n.networkProxySystemFound(_bare(proxy)),
      null => l10n.networkProxySystemNone,
    };

/// Application proxy entry shared by desktop and mobile settings.
class NetworkProxyRow extends ConsumerWidget {
  const NetworkProxyRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(networkProxyProvider);
    final setting = value.valueOrNull;
    final summary = switch (setting) {
      null => '',
      NetworkProxySetting(mode: ProxyMode.system) => _systemLine(l10n, setting),
      NetworkProxySetting(mode: ProxyMode.direct) =>
        l10n.networkProxyDirectSummary,
      NetworkProxySetting(:final custom) => _bare(custom ?? ''),
    };
    return ListTile(
      key: const Key('network-proxy-settings'),
      leading: const Icon(AppIcons.public),
      title: InfoTitle(
        title: Text(l10n.networkProxyTitle),
        info: l10n.networkProxyScope,
      ),
      subtitle: Text(
        value.hasError ? l10n.networkProxyReadFailed : summary,
        key: const Key('network-proxy-summary'),
      ),
      trailing: const Icon(AppIcons.edit_outlined),
      onTap: value.isLoading
          ? null
          : () async {
              if (value.hasError || setting == null) {
                ref.invalidate(networkProxyProvider);
                return;
              }
              // The system's proxy may have changed since the row was read.
              final NetworkProxySetting current;
              try {
                current = await ref.refresh(networkProxyProvider.future);
              } catch (_) {
                return;
              }
              if (!context.mounted) return;
              final saved = await showAppDialog<bool>(
                context: context,
                builder: (_) => _ProxyEditor(
                  api: ref.read(bridgeApiProvider),
                  initial: current,
                ),
              );
              if (saved == true && context.mounted) {
                ref.invalidate(networkProxyProvider);
              }
            },
    );
  }
}

class _ProxyEditor extends StatefulWidget {
  const _ProxyEditor({required this.api, required this.initial});
  final BridgeApi api;
  final NetworkProxySetting initial;

  @override
  State<_ProxyEditor> createState() => _ProxyEditorState();
}

class _ProxyEditorState extends State<_ProxyEditor> {
  late ProxyMode _mode = widget.initial.mode;
  late final _url = TextEditingController(text: widget.initial.custom ?? '');
  bool _busy = false;
  bool _visible = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final value = _url.text.trim();
    final uri = Uri.tryParse(value);
    if (_mode == ProxyMode.custom && value.isEmpty) {
      setState(() => _error = l10n.networkProxyCustomRequired);
      return;
    }
    // The custom URL is kept whatever the mode, so it is checked whenever
    // it is set.
    if (value.isNotEmpty &&
        (uri == null ||
            !const {
              'http',
              'https',
              'socks5',
              'socks5h',
            }.contains(uri.scheme) ||
            uri.host.isEmpty ||
            (uri.port == 0 || uri.port > 65535) ||
            uri.hasQuery ||
            uri.hasFragment ||
            (uri.path.isNotEmpty && uri.path != '/'))) {
      setState(() => _error = l10n.networkProxyInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.networkSetProxySetting(_mode, value);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      // The editor may contain credentials; never echo bridge errors here.
      if (mounted) setState(() => _error = l10n.networkProxySaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final labels = {
      ProxyMode.system: l10n.networkProxyModeSystem,
      ProxyMode.direct: l10n.networkProxyModeDirect,
      ProxyMode.custom: l10n.networkProxyModeCustom,
    };
    final note = switch (_mode) {
      ProxyMode.system => _systemLine(l10n, widget.initial),
      ProxyMode.direct => l10n.networkProxyDirectNote,
      ProxyMode.custom => null,
    };
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(l10n.networkProxyTitle),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) => SegmentedButton<ProxyMode>(
                    key: const Key('network-proxy-mode'),
                    direction:
                        segmentsFitAcross(
                          context,
                          constraints.maxWidth,
                          labels.values.toList(),
                        )
                        ? Axis.horizontal
                        : Axis.vertical,
                    showSelectedIcon: false,
                    segments: [
                      for (final MapEntry(:key, :value) in labels.entries)
                        ButtonSegment(
                          value: key,
                          label: Text(
                            value,
                            key: Key('network-proxy-mode-${key.name}'),
                          ),
                        ),
                    ],
                    selected: {_mode},
                    onSelectionChanged: _busy
                        ? null
                        : (selected) => setState(() {
                            _mode = selected.first;
                            _error = null;
                          }),
                  ),
                ),
                const SizedBox(height: 12),
                if (note != null)
                  InfoTitle(
                    key: const Key('network-proxy-note'),
                    title: Text(
                      note,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                    info: _mode == ProxyMode.system
                        ? l10n.networkProxySystemInfo
                        : null,
                  ),
                if (_mode == ProxyMode.custom)
                  FocusHelp(
                    help: l10n.networkProxyHint,
                    child: TextField(
                      key: const Key('network-proxy-url'),
                      controller: _url,
                      enabled: !_busy,
                      obscureText: !_visible,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.url,
                      decoration: InputDecoration(
                        labelText: l10n.networkProxyAddress,
                        errorText: _error,
                        errorMaxLines: 4,
                        suffixIcon: IconButton(
                          tooltip: _visible
                              ? l10n.networkProxyHide
                              : l10n.networkProxyShow,
                          icon: Icon(
                            _visible
                                ? AppIcons.visibility_off
                                : AppIcons.visibility,
                          ),
                          onPressed: () => setState(() => _visible = !_visible),
                        ),
                      ),
                      onSubmitted: (_) {
                        if (!_busy) _save();
                      },
                    ),
                  )
                else if (_error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      error,
                      key: const Key('network-proxy-error'),
                      style: TextStyle(color: scheme.error, fontSize: 12),
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
            key: const Key('network-proxy-save'),
            onPressed: _busy ? null : _save,
            child: Text(l10n.save),
          ),
        ],
      ),
    );
  }
}
