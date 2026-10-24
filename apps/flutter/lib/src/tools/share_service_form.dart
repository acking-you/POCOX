/// A person shares a running service directly, with a saved mapping and the
/// same opening path on every device.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/error_format.dart';
import 'package:pocox/src/file_links.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/service_key.dart';
import 'package:pocox/src/widgets/adaptive_sheet.dart';
import 'package:pocox/src/widgets/app_toast.dart';
import 'package:pocox/src/widgets/busy_label.dart';
import 'package:pocox/src/widgets/field_help.dart';

/// Normalize a port or host-local HTTP(S) URL, preserving query and fragment.
Uri? parseShareAddress(String input) {
  var value = input.trim();
  if (RegExp(r'^\d+$').hasMatch(value)) value = 'http://localhost:$value/';
  if (!value.contains('://')) value = 'http://$value';
  try {
    final uri = Uri.parse(value);
    if (!isHostLocalWebUrl(uri) ||
        uri.userInfo.isNotEmpty ||
        uri.port < 1 ||
        uri.port > 65535) {
      return null;
    }
    return uri.replace(path: uri.path.isEmpty ? '/' : uri.path);
  } on FormatException {
    return null;
  }
}

/// Open the sharing form for this exact device from its service list.
Future<void> showShareServiceForm(BuildContext context, String device) =>
    showAdaptivePanel<void>(
      context: context,
      anchored: true,
      maxWidth: 480,
      builder: (_) => ShareServiceForm(device: device),
    );

/// Fields and inline feedback for adding a saved service.
class ShareServiceForm extends ConsumerStatefulWidget {
  /// Share a service of [device], never the controller's own port by inference.
  const ShareServiceForm({super.key, required this.device});
  final String device;

  @override
  ConsumerState<ShareServiceForm> createState() => _ShareServiceFormState();
}

class _ShareServiceFormState extends ConsumerState<ShareServiceForm> {
  final _form = GlobalKey<FormState>();
  final _address = TextEditingController();
  final _title = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _address.dispose();
    _title.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    final uri = parseShareAddress(_address.text)!;
    final path =
        '${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}${uri.hasFragment ? '#${uri.fragment}' : ''}';
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(bridgeApiProvider)
          .toolsShareOn(
            widget.device,
            [uri.port],
            title: _title.text.trim().isEmpty ? null : _title.text.trim(),
            path: path,
            secure: uri.scheme == 'https',
          );
      if (!mounted) return;
      ToastMessenger.of(
        context,
      ).ok(AppLocalizations.of(context).toolsKeptToast);
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        8,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InfoTitle(
              title: Text(
                l10n.toolsAddShare,
                style: theme.textTheme.titleLarge,
              ),
              info: l10n.toolsSavedShareHelp,
            ),
            const SizedBox(height: 4),
            Text(
              l10n.toolsShareOnDevice(deviceLabel(widget.device)),
              style: helpTextStyle(theme),
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('share-address'),
              controller: _address,
              enabled: !_busy,
              autofocus: true,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: l10n.toolsShareAddress,
                hintText: 'http://localhost:5555/static/',
              ),
              validator: (value) => parseShareAddress(value ?? '') == null
                  ? l10n.toolsShareAddressInvalid
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('share-title'),
              controller: _title,
              enabled: !_busy,
              maxLength: 80,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: l10n.toolsShareName,
                counterText: '',
              ),
              onFieldSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 16),
            // The outcome sits above the action that caused it.
            if (_error != null) ...[
              Text(
                _error!,
                key: const Key('share-error'),
                style: helpTextStyle(
                  theme,
                ).copyWith(color: theme.colorScheme.error),
              ),
              const SizedBox(height: 12),
            ],
            FilledButton(
              key: const Key('share-submit'),
              // Its working colours while it saves, not greyed out.
              style: _busy
                  ? FilledButton.styleFrom(
                      disabledBackgroundColor: theme.colorScheme.primary,
                      disabledForegroundColor: theme.colorScheme.onPrimary,
                    )
                  : null,
              onPressed: _busy ? null : _submit,
              child: BusyLabel(
                busy: _busy,
                label: l10n.toolsShareAndSave,
                busyLabel: l10n.toolsSaving,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
