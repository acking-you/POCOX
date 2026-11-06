import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/app_icons.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/pairing/pairing_front.dart';
import 'package:pocox/src/pairing/pairing_session.dart';
import 'package:pocox/src/pairing/pairing_widgets.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/theme.dart';
import 'package:pocox/src/widgets/adaptive_sheet.dart';
import 'package:pocox/src/widgets/app_dialog.dart';
import 'package:pocox/src/widgets/app_toast.dart';
import 'package:pocox/src/widgets/group_card.dart';
import 'package:pocox/src/widgets/icon_badge.dart';
import 'package:pocox/src/widgets/setting_row.dart';

/// Settings › Account for a device signed in with its pairing code: who it is,
/// its group and the requests waiting on it, its code, and the ways to link
/// elsewhere, leave or go back to GitHub. Read again every minute while open.
class PairingAccountGroups extends ConsumerStatefulWidget {
  /// Creates the groups; [trailing] are the account's other rows (the relay,
  /// signing out), kept as they are.
  const PairingAccountGroups({super.key, this.trailing = const []});

  /// Rows after the account's identity.
  final List<Widget> trailing;

  @override
  ConsumerState<PairingAccountGroups> createState() => _PairingAccountState();
}

class _PairingAccountState extends ConsumerState<PairingAccountGroups> {
  List<PairingDevice> _devices = const [];
  List<PairingRecoveryAsk> _asks = const [];
  PairingCode? _code;
  String? _parked;
  String? _error;
  bool _loaded = false;
  Timer? _poll;

  BridgeApi get _api => ref.read(bridgeApiProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _poll = Timer.periodic(pairingPollInterval, (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final devices = <PairingDevice>[];
      List<PairingRecoveryAsk>? asks;
      String? cursor;
      do {
        final page = await _api.pairingDevices(cursor: cursor);
        devices.addAll(page.devices);
        // Every page repeats the requests; the first is enough.
        asks ??= page.pendingRequests;
        cursor = page.nextCursor;
      } while (cursor != null);
      final code = await _api.pairingCode();
      String? parked;
      try {
        parked = (await _api.pairingStatus()).parkedGithub;
      } catch (_) {
        parked = _parked;
      }
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _asks = asks ?? const [];
        _code = code;
        _parked = parked;
        _error = null;
        _loaded = true;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = pairingErrorText(AppLocalizations.of(context), error);
          _loaded = true;
        });
      }
    }
  }

  /// Run [work], then read the group again. A refusal says why, in
  /// [instead]'s words for the codes it names; one waiting on another change
  /// of this device opens that change's page.
  Future<void> _act(
    Future<void> Function() work, {
    Map<String, String> instead = const {},
  }) async {
    final l10n = AppLocalizations.of(context);
    try {
      await work();
    } catch (error) {
      if (!mounted) return;
      if (followTransitionPending(context, error)) return;
      final custom = error is PairingFailure ? instead[error.code] : null;
      showToastError(context, custom ?? pairingErrorText(l10n, error));
    }
    await _load();
  }

  /// What a device-targeted action's refusal means when the device is gone.
  Map<String, String> _gone(AppLocalizations l10n) => {
    'not_found': l10n.pairingErrDeviceGone,
  };

  Future<void> _showAdd() async {
    final code = _code;
    if (code == null) return;
    final l10n = AppLocalizations.of(context);
    await showAdaptivePanel<void>(
      context: context,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.pairingAddDevice,
              style: Theme.of(sheet).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            if (!code.paused)
              Center(child: PairingQr(uri: code.uri, size: 200)),
            const SizedBox(height: 16),
            PairingCodeCard(
              code: code,
              badge: code.paused ? PairingPill(l10n.pairingPaused) : null,
              size: 21,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(PairingDevice device) async {
    final l10n = AppLocalizations.of(context);
    // Captured first: leaving Settings before the answer must not skip it.
    final container = ProviderScope.containerOf(context);
    final controller = TextEditingController(text: device.name);
    final name = await showAppDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l10n.pairingRename),
        content: TextField(
          key: const Key('pairing-rename-field'),
          controller: controller,
          autofocus: true,
          // The backend counts bytes, not characters.
          inputFormatters: const [_Utf8Limit(pairingNameMaxBytes)],
          decoration: InputDecoration(labelText: l10n.pairingDeviceName),
          onSubmitted: (value) => Navigator.pop(dialog, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, controller.text),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == device.name || !mounted) return;
    await _act(() async {
      await _api.pairingRenameDevice(deviceId: device.id, name: trimmed);
      // This device's own name is the one sign-in and the pocket show.
      if (device.isSelf) container.invalidate(configProvider);
    }, instead: {..._gone(l10n), 'invalid_request': l10n.pairingErrName});
  }

  Future<void> _remove(PairingDevice device) async {
    final l10n = AppLocalizations.of(context);
    final yes = await confirmPairing(
      context,
      title: l10n.pairingRemoveTitle(device.name),
      body: l10n.pairingRemoveBody,
      yes: l10n.remove,
      danger: true,
    );
    if (!yes || !mounted) return;
    await _act(() async {
      final operation = await _api.pairingRemoveDevice(device.id);
      if (!mounted) return;
      switch (operation.status) {
        case 'completed':
          showToastOk(context, l10n.pairingRemoved(device.name));
        case 'pending':
          // Followed to its end on its own page, as every change is.
          await followPairingOperation(context, ref, operation);
        default:
          showToastError(
            context,
            pairingErrorText(
              l10n,
              PairingFailure(code: operation.error ?? 'failed', message: ''),
            ),
          );
      }
    }, instead: _gone(l10n));
  }

  Future<void> _decide(PairingRecoveryAsk ask, {required bool allow}) {
    final l10n = AppLocalizations.of(context);
    return _act(() async {
      await _api.pairingDecideRestore(
        deviceId: ask.targetDeviceId,
        requestId: ask.requestId,
        allow: allow,
      );
      if (mounted) {
        showToastOk(context, allow ? l10n.pairingAllowed : l10n.pairingDenied);
      }
    }, instead: _gone(l10n));
  }

  Future<void> _rotate() async {
    final l10n = AppLocalizations.of(context);
    final yes = await confirmPairing(
      context,
      title: l10n.pairingRotateTitle,
      body: l10n.pairingRotateBody,
      yes: l10n.pairingRotateYes,
    );
    if (!yes || !mounted) return;
    await _act(() async {
      await _api.pairingRotate();
      if (mounted) showToastOk(context, l10n.pairingRotated);
    });
  }

  Future<void> _leave(int peers) async {
    final l10n = AppLocalizations.of(context);
    final yes = await confirmPairing(
      context,
      title: l10n.pairingLeaveGroupTitle(peers),
      body: l10n.pairingLeaveGroupBody,
      yes: l10n.pairingLeaveYes,
      danger: true,
    );
    if (!yes || !mounted) return;
    await _act(() async {
      final operation = await _api.pairingLeave();
      if (mounted) await followPairingOperation(context, ref, operation);
    });
  }

  /// Back to a GitHub session set aside here, or to GitHub's sign-in.
  Future<void> _toGitHub() async {
    final l10n = AppLocalizations.of(context);
    final parked = _parked;
    final yes = await confirmPairing(
      context,
      title: parked == null
          ? l10n.pairingToGitHubTitle
          : l10n.pairingBackToGitHubTitle(parked),
      body: l10n.pairingToGitHubBody,
      yes: parked == null
          ? l10n.pairingToGitHubYes
          : l10n.pairingBackToGitHubYes,
    );
    if (!yes || !mounted) return;
    try {
      if (parked != null) {
        await _api.pairingResumeGithub();
        if (mounted) await landAfterSignIn(context, ref);
      } else {
        await _api.accountLogout();
        ref.invalidate(configProvider);
        if (mounted) context.go('/onboarding');
      }
    } catch (error) {
      if (mounted) showToastError(context, pairingErrorText(l10n, error));
    }
  }

  Widget _deviceMenu(PairingDevice device, AppLocalizations l10n) =>
      PopupMenuButton<String>(
        key: Key('pairing-device-menu-${device.id}'),
        tooltip: l10n.pairingMore,
        icon: const Icon(AppIcons.more_horiz, size: 18),
        onSelected: (choice) {
          if (choice == 'rename') unawaited(_rename(device));
          if (choice == 'remove') unawaited(_remove(device));
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'rename', child: Text(l10n.pairingRename)),
          if (!device.isSelf)
            PopupMenuItem(value: 'remove', child: Text(l10n.remove)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final config = ref.watch(configProvider).valueOrNull;
    final self = _devices.where((device) => device.isSelf).firstOrNull;
    final peers = _devices.where((device) => !device.isSelf).toList();
    final code = _code;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final waitHours = code == null || code.nextRotationAt <= now
        ? 0
        : ((code.nextRotationAt - now) / 3600).ceil();
    final identity = Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 12, 12),
      child: Row(
        children: [
          IconBadge(icon: pairingDeviceIcon(self?.platform), size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  self?.name ?? config?.accountLogin ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  !_loaded
                      ? l10n.pairingSignedInWithCode
                      : peers.isEmpty
                      ? l10n.pairingNoPeers
                      : l10n.pairingLinkedCount(_devices.length),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    // Every open request is its own row, keyed by the request, with its own
    // check number: a second request never takes the first one's place.
    Widget askRow(PairingDevice device, PairingRecoveryAsk ask) =>
        PairingDeviceRow(
          key: Key('pairing-ask-${ask.requestId}'),
          name: device.name,
          icon: pairingDeviceIcon(device.platform),
          line: l10n.pairingAsking(ask.matchingId),
          lineColor: cautionColor(scheme),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                key: Key('pairing-deny-${ask.requestId}'),
                onPressed: () => _decide(ask, allow: false),
                child: Text(l10n.pairingDeny),
              ),
              const SizedBox(width: 2),
              FilledButton(
                key: Key('pairing-allow-${ask.requestId}'),
                onPressed: () => _decide(ask, allow: true),
                child: Text(l10n.pairingAllow),
              ),
              const SizedBox(width: 4),
            ],
          ),
        );
    Widget deviceRow(PairingDevice device) {
      return PairingDeviceRow(
        key: Key('pairing-device-${device.id}'),
        name: device.name,
        icon: pairingDeviceIcon(device.platform),
        line: device.isSelf
            ? null
            : device.activated
            ? pairingLastActive(l10n, device.lastActiveDay)
            : l10n.pairingNotSetUp,
        trailing: device.isSelf
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PairingPill(l10n.pairingThisDevice),
                  _deviceMenu(device, l10n),
                ],
              )
            : _deviceMenu(device, l10n),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupCard(
          title: l10n.accountSection,
          children: [identity, ...widget.trailing],
        ),
        const SizedBox(height: 8),
        GroupCard(
          title: l10n.pairingMyDevices,
          trailing: TextButton.icon(
            key: const Key('pairing-add-device'),
            onPressed: code == null ? null : _showAdd,
            icon: const Icon(AppIcons.add, size: 16),
            label: Text(l10n.pairingAddDevice),
          ),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(14),
                child: Text(_error!, style: TextStyle(color: scheme.error)),
              )
            else if (!_loaded)
              const Padding(
                padding: EdgeInsets.all(16),
                child: PairingSpinner(),
              )
            else ...[
              for (final device in [?self, ...peers]) ...[
                deviceRow(device),
                for (final ask in _asks)
                  if (ask.targetDeviceId == device.id) askRow(device, ask),
              ],
            ],
          ],
        ),
        const SizedBox(height: 8),
        GroupCard(
          title: l10n.pairingCodeSection,
          children: [
            SettingRow(
              title: l10n.pairingAllowLinking,
              info: l10n.pairingAllowLinkingInfo,
              control: (_) => Switch(
                key: const Key('pairing-allow-linking'),
                value: code != null && !code.paused,
                onChanged: code == null
                    ? null
                    : (allow) => _act(() async {
                        await _api.pairingSetPaused(paused: !allow);
                      }),
              ),
            ),
            SettingValueRow(
              key: const Key('pairing-change-code'),
              label: l10n.pairingChangeCode,
              info: l10n.pairingChangeCodeInfo,
              value: Text(
                waitHours > 0
                    ? l10n.pairingAvailableIn(waitHours)
                    : l10n.pairingChange,
              ),
              onTap: code == null || waitHours > 0 ? null : _rotate,
            ),
          ],
        ),
        const SizedBox(height: 8),
        GroupCard(
          title: l10n.pairingLinking,
          children: [
            SettingValueRow(
              key: const Key('pairing-link-elsewhere'),
              label: peers.isEmpty
                  ? l10n.pairingLinkAnother
                  : l10n.pairingLinkInstead,
              onTap: () => context.push('/pair/join'),
            ),
            SettingValueRow(
              key: const Key('pairing-to-github'),
              label: _parked == null
                  ? l10n.pairingToGitHub
                  : l10n.pairingBackToGitHub(_parked!),
              onTap: _toGitHub,
            ),
            if (peers.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 9,
                ),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: OutlinedButton.icon(
                    key: const Key('pairing-leave'),
                    onPressed: () => _leave(peers.length),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.error,
                      side: BorderSide(color: scheme.error),
                    ),
                    icon: const Icon(AppIcons.link_off_outlined, size: 17),
                    label: Text(l10n.pairingLeaveGroup),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// The longest device name the backend takes, in UTF-8 bytes.
const pairingNameMaxBytes = 64;

/// Keeps a field's text within [maxBytes] UTF-8 bytes. An input method's
/// composition runs freely; once it is committed, the text is cut back to the
/// longest whole-character prefix that fits.
class _Utf8Limit extends TextInputFormatter {
  const _Utf8Limit(this.maxBytes);

  final int maxBytes;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final composing = newValue.composing;
    if (composing.isValid && !composing.isCollapsed) return newValue;
    if (utf8.encode(newValue.text).length <= maxBytes) return newValue;
    final kept = StringBuffer();
    var bytes = 0;
    for (final rune in newValue.text.runes) {
      final char = String.fromCharCode(rune);
      final size = utf8.encode(char).length;
      if (bytes + size > maxBytes) break;
      kept.write(char);
      bytes += size;
    }
    final text = kept.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
