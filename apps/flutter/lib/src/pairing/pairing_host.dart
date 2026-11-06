import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/desktop_tray.dart';
import 'package:pocox/src/pairing/pairing_front.dart';
import 'package:pocox/src/pairing/pairing_page.dart';
import 'package:pocox/src/pairing/pairing_platform.dart';
import 'package:pocox/src/pairing/pairing_session.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/router.dart';
import 'package:pocox/src/ui_prefs.dart';
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
  bool _checking = false;

  /// Changes under way already offered for review in this run.
  final _offeredPending = <String>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    PairingInvitations.listen(ref.read(bridgeApiProvider), (code) async {
      ref.read(pairingInvitationProvider.notifier).state = code;
      // A window hidden to the tray would open the preview out of sight.
      if (DesktopTray.supported) await DesktopTray.instance.show();
      pushRoute('/pair/join');
    });
    _poll = Timer.periodic(pairingPollInterval, (_) => _check());
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // An Android activity can start a second engine that takes the
    // process-wide store and dies with it: the engine in front owns it again.
    if (!kIsWeb && Platform.isAndroid) {
      unawaited(installPairingStore(ref.read(bridgeApiProvider)));
    }
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_checking) return;
    _checking = true;
    try {
      await _checkOnce();
    } finally {
      _checking = false;
    }
  }

  Future<void> _checkOnce() async {
    final ConfigInfo config;
    try {
      // A cold start reads config once; waiting for it beats waiting a minute.
      config = await ref.read(configProvider.future);
    } catch (_) {
      return;
    }
    if (!mounted || !config.pairing) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    final api = ref.read(bridgeApiProvider);
    final PairingDevices page;
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
    await _announce(config.accountId ?? '', page);
    if (mounted) await _followOperations(api);
  }

  /// Tell the user about each device that joined and each recovery request
  /// since this device last told them, while the app ran or not. Another
  /// account (a link, restore or start over) starts a fresh record silently.
  Future<void> _announce(String account, PairingDevices page) async {
    final prefs = ref.read(uiPrefsProvider.notifier);
    final UiPrefs saved;
    try {
      saved = await prefs.ready.timeout(const Duration(seconds: 2));
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final seen = saved.pairingSeen;
    prefs.setPairingSeen(
      PairingSeen(
        accountId: account,
        devices: [
          for (final device in page.devices)
            if (!device.isSelf) device.id,
        ],
        requests: [for (final ask in page.pendingRequests) ask.requestId],
      ),
    );
    if (seen == null || seen.accountId != account) return;
    final l10n = AppLocalizations.of(context);
    final toast = ToastMessenger.of(context);
    for (final device in page.devices) {
      if (device.isSelf || seen.devices.contains(device.id)) continue;
      toast.offer(
        l10n.pairingJoinedNotice(device.name),
        action: l10n.pairingReview,
        onAction: () => pushRoute('/settings/account'),
      );
    }
    for (final ask in page.pendingRequests) {
      if (seen.requests.contains(ask.requestId)) continue;
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

  /// A change no page waits for any more: one under way is offered for
  /// review, one that did not happen says why, once.
  Future<void> _followOperations(BridgeApi api) async {
    final PairingStatus status;
    try {
      status = await api.pairingStatus();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    explainFailedOperations(context, status.failed);
    if ((currentRoutePath() ?? '').startsWith('/pair/pending')) return;
    final l10n = AppLocalizations.of(context);
    final toast = ToastMessenger.of(context);
    for (final operation in status.pending) {
      if (!_offeredPending.add(operation.id)) continue;
      toast.offer(
        switch (operation.kind) {
          'link' => l10n.pairingPendingLink,
          'leave' => l10n.pairingPendingLeave,
          'remove' => l10n.pairingPendingRemove,
          'restore' || 'retake' => l10n.pairingPendingRestore,
          _ => l10n.pairingPendingTitle,
        },
        action: l10n.pairingReview,
        onAction: () => pushRoute('/pair/pending', extra: (operation, null)),
      );
    }
  }

  void _toSignIn() {
    // Sign-in and its pairing pages already say what happened; anywhere else,
    // including after signing in again, the device goes back to sign-in.
    final path = currentRoutePath() ?? '';
    if (path.startsWith('/onboarding') || path.startsWith('/pair')) return;
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
