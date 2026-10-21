import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/hosting/editor_block.dart';
import 'package:pocox/src/managed/managed_providers.dart';
import 'package:pocox/src/managed/management_failure.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/field_help.dart';
import 'package:pocox/src/app_icons.dart';

/// This computer's own remote-management switch, plus its automatic-restore
/// warnings. Only this computer can turn it on or off; managing services
/// and running them are separate, so switching it never starts or stops a
/// service.
class DeviceManagementSwitch extends ConsumerStatefulWidget {
  /// Creates the switch.
  const DeviceManagementSwitch({super.key});

  @override
  ConsumerState<DeviceManagementSwitch> createState() =>
      _DeviceManagementSwitchState();
}

class _DeviceManagementSwitchState
    extends ConsumerState<DeviceManagementSwitch> {
  bool _busy = false;
  String? _error;

  Future<void> _set(bool enabled) async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    // The container outlives this widget: the switch is re-read even if the
    // page was left meanwhile.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await ref.read(bridgeApiProvider).deviceManagementSetEnabled(enabled);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = managedFailureText(l10n, ManagementFailure.of(e)),
        );
      }
    }
    // Whatever the answer, show what the switch is now.
    container.invalidate(deviceManagementProvider);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final status = ref.watch(deviceManagementProvider);
    final value = status.valueOrNull;
    final blocked = ref.watch(hostRestoreBlockedProvider);
    final restoreProblem = ref.watch(hostRestoreProblemProvider(null));
    if (value != null && !value.supported) return const SizedBox.shrink();
    final subtitle = switch (value) {
      null when status.hasError => l10n.managedSwitchUnavailable,
      null => l10n.statusChecking,
      final v when !v.enabled => l10n.managedSwitchOff,
      final v when v.registered => l10n.managedSwitchOn,
      final v => v.problem ?? l10n.managedSwitchConnecting,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SwitchListTile(
          key: const Key('device-management-switch'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          secondary: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(AppIcons.devices_outlined, color: scheme.primary),
          // What the switch allows is behind the info mark; the subtitle
          // is only its state.
          title: Align(
            alignment: AlignmentDirectional.centerStart,
            child: InfoTitle(
              title: Text(l10n.managedSwitchTitle),
              info: l10n.managedSwitchInfo,
            ),
          ),
          subtitle: Text(subtitle),
          value: value?.enabled ?? false,
          onChanged: value == null || _busy ? null : _set,
        ),
        if (_error case final error?)
          EditorNote(
            error,
            key: const Key('device-management-error'),
            color: scheme.error,
          ),
        if (blocked case final problem?)
          EditorNote(
            l10n.hostRestoreBlocked(problem),
            key: const Key('host-restore-blocked'),
            color: cautionColor(scheme),
          )
        else if (restoreProblem.valueOrNull case final problem?)
          EditorNote(
            l10n.managedRestoreProblem(problem),
            key: const Key('host-restore-problem'),
            color: cautionColor(scheme),
          ),
      ],
    );
  }
}
