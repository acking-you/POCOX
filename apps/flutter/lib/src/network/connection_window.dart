import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/error_format.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/widgets/app_dialog.dart';
import 'package:pocox/src/widgets/group_card.dart';

/// The same persisted retention policy on phone and desktop.
class ConnectionWindowSettings extends ConsumerStatefulWidget {
  const ConnectionWindowSettings({super.key});

  @override
  ConsumerState<ConnectionWindowSettings> createState() => _SettingsState();
}

class _SettingsState extends ConsumerState<ConnectionWindowSettings> {
  ConnectionWindowPreferences? _value;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await ref
          .read(bridgeApiProvider)
          .connectionWindowPreferences();
      if (mounted) {
        setState(() {
          _value = value;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    }
  }

  Future<void> _edit() async {
    final current = _value;
    if (current == null || _saving) return;
    final l10n = AppLocalizations.of(context);
    final capacity = TextEditingController(text: '${current.capacity}');
    final form = GlobalKey<FormState>();
    var eviction = current.eviction;
    final result = await showAppDialog<ConnectionWindowPreferences>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.connectionWindowTitle),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.connectionWindowDescription),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('connection-window-capacity'),
                  controller: capacity,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.connectionWindowCapacity,
                  ),
                  validator: (text) {
                    final number = int.tryParse(text ?? '');
                    return number == null || number < 1 || number > 32
                        ? l10n.connectionWindowInvalid
                        : null;
                  },
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: const Key('connection-window-policy'),
                  initialValue: eviction,
                  isExpanded: true,
                  itemHeight: null,
                  decoration: InputDecoration(
                    labelText: l10n.connectionWindowPolicy,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'lru',
                      child: Text(l10n.connectionWindowLru),
                    ),
                    DropdownMenuItem(
                      value: 'fifo',
                      child: Text(l10n.connectionWindowFifo),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) eviction = value;
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const Key('connection-window-save'),
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(
                  context,
                  ConnectionWindowPreferences(
                    capacity: int.parse(capacity.text),
                    eviction: eviction,
                  ),
                );
              }
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => capacity.dispose());
    if (result == null || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(bridgeApiProvider).setConnectionWindowPreferences(result);
      if (mounted) setState(() => _value = result);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final value = _value;
    return GroupCard(
      title: l10n.connectionWindowTitle,
      info: l10n.connectionWindowDescription,
      children: [
        ListTile(
          key: const Key('connection-window-settings'),
          title: Text(l10n.connectionWindowCapacity),
          subtitle: _error != null
              ? Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                )
              : value == null
              ? null
              : Text(
                  '${value.capacity} · ${value.eviction == 'fifo' ? l10n.connectionWindowFifo : l10n.connectionWindowLru}',
                ),
          trailing: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(AppIcons.edit_outlined),
          onTap: _saving
              ? null
              : value == null
              ? _load
              : _edit,
        ),
      ],
    );
  }
}
