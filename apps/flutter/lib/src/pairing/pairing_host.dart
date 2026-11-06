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
    final api = ref.read(bridgeApiProvider);
    final ConfigInfo config;
    try {
      // Read fresh, not the cached provider: the engine changes the account
      // (a link finishing in the background) without telling it.
      config = await api.getConfig();
    } catch (_) {
      return;
    }
    if (!mounted || !config.pairing) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    final PairingDevices page;
    try {
      page = await api.pairingDevices();
    } on PairingFailure catch (error) {
      if (error.code == 'transition_pending') {
        // This device's own link or leave is under way: offer its page.
        await _followOperations(api, quiet: false);
      } else if (const {
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
    final ConfigInfo after;
    try {
      after = await api.getConfig();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    if (after.accountId != config.accountId) {
      // The group read may be either account's: the next check reads one.
      ref.invalidate(configProvider);
      return;
    }
    final told = await _announce(config.accountId ?? '', page);
    if (mounted) await _followOperations(api, quiet: told);
  }

  /// Tell the user, in one notice, about every device that joined and every
  /// recovery request since they were last told, while the app ran or not.
  /// Another account (a link, restore or start over) starts a fresh record
  /// silently. True when a notice went up.
  Future<bool> _announce(String account, PairingDevices page) async {
    final prefs = ref.read(uiPrefsProvider.notifier);
    final UiPrefs saved;
    try {
      saved = await prefs.ready.timeout(const Duration(seconds: 2));
    } catch (_) {
      return false;
    }
    if (!mounted) return false;
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
    if (seen == null || seen.accountId != account) return false;
    final joined = [
      for (final device in page.devices)
        if (!device.isSelf && !seen.devices.contains(device.id)) device,
    ];
    final asks = [
      for (final ask in page.pendingRequests)
        if (!seen.requests.contains(ask.requestId)) ask,
    ];
    final l10n = AppLocalizations.of(context);
    String target(PairingRecoveryAsk ask) =>
        page.devices
            .where((device) => device.id == ask.targetDeviceId)
            .map((device) => device.name)
            .firstOrNull ??
        ask.requesterName;
    // One notice for all of it: a second would hide the first.
    final message = switch ((joined.length, asks.length)) {
      (0, 0) => null,
      (1, 0) => l10n.pairingJoinedNotice(joined.single.name),
      (_, 0) => l10n.pairingJoinedManyNotice(joined.length),
      (0, 1) => l10n.pairingAskNotice(target(asks.single)),
      (0, _) => l10n.pairingAskManyNotice(asks.length),
      _ => l10n.pairingNewsNotice(joined.length + asks.length),
    };
    if (message == null) return false;
    ToastMessenger.of(context).offer(
      message,
      action: l10n.pairingReview,
      onAction: () => pushRoute('/settings/account'),
    );
    return true;
  }

  /// A change no page waits for any more: one that did not happen says why,
  /// once, and one under way is offered for review. One notice per check;
  /// when [quiet], another already went up and these wait for the next.
  Future<void> _followOperations(BridgeApi api, {required bool quiet}) async {
    if (quiet) return;
    final PairingStatus status;
    try {
      status = await api.pairingStatus();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    if (explainFailedOperations(context, ref, status.failed)) return;
    if ((currentRoutePath() ?? '').startsWith('/pair/pending')) return;
    final operation = status.pending
        .where((operation) => !_offeredPending.contains(operation.id))
        .firstOrNull;
    if (operation == null) return;
    _offeredPending.add(operation.id);
    final l10n = AppLocalizations.of(context);
    ToastMessenger.of(context).offer(
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
