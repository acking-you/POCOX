import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/pairing/pairing_front.dart';
import 'package:pocox/src/pairing/pairing_page.dart';
import 'package:pocox/src/pairing/pairing_platform.dart';
import 'package:pocox/src/pairing/pairing_session.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/router.dart';
import 'package:pocox/src/widgets/app_toast.dart';

/// Pairing above every page: a `pocox://pair` invitation opens its preview,
/// and while this installation is a pairing device, its group is read every
/// minute so a device that joined or asks to be restored is told about at
/// once, and a removal or a replaced identity leads back to sign-in. The
/// engine stops hosting on its own; this only shows it.
class PairingHost extends ConsumerStatefulWidget {
  /// Wraps [child].
  const PairingHost({super.key, required this.child});

  /// The app.
  final Widget child;

  @override
  ConsumerState<PairingHost> createState() => _PairingHostState();
}

class _PairingHostState extends ConsumerState<PairingHost>
    with WidgetsBindingObserver {
  Timer? _poll;
  Set<String>? _devices;
  Set<String>? _asks;
  bool _sentToSignIn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PairingInvitations.listen(ref.read(bridgeApiProvider), (code) {
      ref.read(pairingInvitationProvider.notifier).state = code;
      pushRoute('/pair/join');
    });
    _poll = Timer.periodic(pairingPollInterval, (_) => _check());
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    final config = ref.read(configProvider).valueOrNull;
    if (config == null || !config.pairing) {
      _devices = null;
      _asks = null;
      _sentToSignIn = false;
      return;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    final api = ref.read(bridgeApiProvider);
    PairingDevices page;
    try {
      page = await api.pairingDevices();
    } on PairingFailure catch (error) {
      if (const {
        'device_superseded',
        'device_unknown',
        'grace_restricted',
        'signed_out',
      }.contains(error.code)) {
        _toSignIn();
      }
      return;
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final self = page.devices.where((device) => device.isSelf).firstOrNull;
    if (self != null && !self.activated) {
      // Removed by a peer: this device is on its own now and hosts nothing.
      _toSignIn();
      return;
    }
    _sentToSignIn = false;
    final l10n = AppLocalizations.of(context);
    final toast = ToastMessenger.of(context);
    final devices = {
      for (final device in page.devices)
        if (!device.isSelf) device.id,
    };
    final asks = {for (final ask in page.pendingRequests) ask.requestId};
    final knownDevices = _devices;
    final knownAsks = _asks;
    _devices = devices;
    _asks = asks;
    if (knownDevices == null || knownAsks == null) return;
    for (final device in page.devices) {
      if (device.isSelf || knownDevices.contains(device.id)) continue;
      toast.offer(
        l10n.pairingJoinedNotice(device.name),
        action: l10n.pairingReview,
        onAction: () => pushRoute('/settings/account'),
      );
    }
    for (final ask in page.pendingRequests) {
      if (knownAsks.contains(ask.requestId)) continue;
      final target = page.devices
          .where((device) => device.id == ask.targetDeviceId)
          .map((device) => device.name)
          .firstOrNull;
      toast.offer(
        l10n.pairingAskNotice(target ?? ask.requesterName),
        action: l10n.pairingReview,
        onAction: () => pushRoute('/settings/account'),
      );
    }
  }

  void _toSignIn() {
    if (_sentToSignIn) return;
    _sentToSignIn = true;
    ref.invalidate(configProvider);
    goRoute('/onboarding');
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Pairing for an installation on GitHub or a self-hosted relay, from
/// Settings: the same paths sign-in offers, with nothing else. Getting started
/// sets the GitHub session aside, ready to come back.
class PairingStartPage extends StatelessWidget {
  /// Creates the page.
  const PairingStartPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PairingPageFrame(
      title: l10n.pairingUseCode,
      logo: true,
      children: const [PairingFront()],
    );
  }
}
