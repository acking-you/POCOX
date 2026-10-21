import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocket_codex/l10n/gen/app_localizations.dart';
import 'package:pocket_codex/src/app_icons.dart';
import 'package:pocket_codex/src/bridge_api.dart';
import 'package:pocket_codex/src/providers.dart';
import 'package:pocket_codex/src/widgets/app_dialog.dart';
import 'package:pocket_codex/src/widgets/field_help.dart';

/// The setting is read separately from the ordinary, non-secret config view.
final networkProxyProvider = FutureProvider<String?>((ref) {
  return ref.watch(bridgeApiProvider).networkProxy();
});

/// Application proxy entry shared by desktop and mobile settings.
class NetworkProxyRow extends ConsumerWidget {
  const NetworkProxyRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(networkProxyProvider);
    final url = Uri.tryParse(value.valueOrNull ?? '');
    final summary = url != null && url.hasAuthority
        ? '${url.scheme}://${url.host.contains(':') ? '[${url.host}]' : url.host}'
              '${url.hasPort ? ':${url.port}' : ''}'
        : l10n.networkProxyDefault;
    return ListTile(
      key: const Key('network-proxy-settings'),
      leading: const Icon(AppIcons.public),
      title: InfoTitle(
        title: Text(l10n.networkProxyTitle),
        info: l10n.networkProxyScope,
      ),
      subtitle: Text(value.hasError ? l10n.networkProxyReadFailed : summary),
      trailing: const Icon(AppIcons.edit_outlined),
      onTap: value.isLoading
          ? null
          : () async {
              if (value.hasError) {
                ref.invalidate(networkProxyProvider);
                return;
              }
              final saved = await showAppDialog<bool>(
                context: context,
                builder: (_) => _ProxyEditor(
                  api: ref.read(bridgeApiProvider),
                  initial: value.valueOrNull ?? '',
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
  final String initial;

  @override
  State<_ProxyEditor> createState() => _ProxyEditorState();
}

class _ProxyEditorState extends State<_ProxyEditor> {
  late final _url = TextEditingController(text: widget.initial);
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
      await widget.api.networkSetProxy(value);
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
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(l10n.networkProxyTitle),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: FocusHelp(
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
                      _visible ? AppIcons.visibility_off : AppIcons.visibility,
                    ),
                    onPressed: () => setState(() => _visible = !_visible),
                  ),
                ),
                onSubmitted: (_) {
                  if (!_busy) _save();
                },
              ),
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
