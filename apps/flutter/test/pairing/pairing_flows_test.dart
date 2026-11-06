/// Pairing-code login as the screens drive it: what each state offers, and
/// that nothing changes membership or the active account without the user's
/// confirmation.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/pairing/pairing_account.dart';
import 'package:pocox/src/pairing/pairing_front.dart';
import 'package:pocox/src/pairing/pairing_host.dart';
import 'package:pocox/src/pairing/pairing_join_screen.dart';
import 'package:pocox/src/pairing/pairing_page.dart';
import 'package:pocox/src/pairing/pairing_restore_screen.dart';
import 'package:pocox/src/pairing/pairing_session.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/router.dart';
import 'package:pocox/src/screens/account_onboarding_screen.dart';
import 'package:pocox/src/ui_prefs.dart';
import 'package:pocox/src/widgets/setting_row.dart';

import '../fake_bridge_api.dart';
import '../support/screen_harness.dart';

class _SeenPrefs extends UiPrefsStore {
  @override
  Future<UiPrefs> load() async => const UiPrefs(guideSeen: true);

  @override
  Future<void> save(UiPrefs prefs) async {}
}

const _unconfigured = ConfigInfo(relay: '', hasKey: false);

List<GoRoute> _routes() => [
  GoRoute(
    path: '/onboarding',
    builder: (_, _) => const AccountOnboardingScreen(),
  ),
  GoRoute(
    path: '/pair/join',
    builder: (_, s) => PairingJoinScreen(code: s.extra as String?),
  ),
  GoRoute(
    path: '/pair/restore',
    builder: (_, s) => PairingRestoreScreen(retake: s.extra as bool? ?? false),
  ),
  GoRoute(
    path: '/pair/pending',
    builder: (_, s) {
      final (operation, backend) =
          s.extra as (PairingOperation?, String?)? ?? (null, null);
      return PairingPendingPage(operation: operation, backend: backend);
    },
  ),
  stub('/', 'HOME-ROUTE'),
  stub('/welcome', 'WELCOME-ROUTE'),
  stub('/blank', 'BLANK'),
];

Future<void> _mount(
  WidgetTester t,
  FakeBridgeApi api, {
  String initial = '/onboarding',
  Object? extra,
}) async {
  t.view.physicalSize = const Size(1200, 2400);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    routerHost(
      api,
      initial: extra == null ? initial : '/blank',
      routes: _routes(),
      overrides: [uiPrefsProvider.overrideWith(_SeenPrefs.new)],
    ),
  );
  await t.pumpAndSettle();
  if (extra != null) {
    GoRouter.of(t.element(find.text('BLANK'))).go(initial, extra: extra);
    await t.pumpAndSettle();
  }
}

Future<void> _tapKey(WidgetTester t, String key) async {
  final finder = find.byKey(Key(key));
  await t.ensureVisible(finder);
  await t.tap(finder);
  await t.pumpAndSettle();
}

Future<void> _otherWays(WidgetTester t) => _tapKey(t, 'pairing-other-ways');

Future<void> _closePanel(WidgetTester t) async {
  Navigator.of(t.element(find.byKey(const Key('account-device-code')))).pop();
  await t.pumpAndSettle();
}

bool _enabled(WidgetTester t, String key) {
  final widget = t.widget(find.byKey(Key(key)));
  return switch (widget) {
    ButtonStyleButton() => widget.onPressed != null,
    _ => throw StateError('not a button: $key'),
  };
}

int _today() => DateTime.now().toUtc().millisecondsSinceEpoch ~/ 86400000;

void main() {
  testWidgets(
    'a computer prepares its code and is set up only on Get started',
    (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        final api = FakeBridgeApi(config: _unconfigured);
        await _mount(t, api);

        expect(api.pairingState, 'inactive', reason: 'the code was prepared');
        expect(find.text('K7M2-F9QX-3RTB'), findsOneWidget);
        expect(api.pairingCalls, isNot(contains('activate')));
        // The page keeps three actions; restoring and GitHub wait in Other
        // ways.
        expect(find.byKey(const Key('pairing-restore')), findsNothing);
        expect(find.byKey(const Key('account-device-code')), findsNothing);
        await _otherWays(t);
        expect(find.byKey(const Key('pairing-restore')), findsOneWidget);
        expect(find.byKey(const Key('account-device-code')), findsOneWidget);
        await _closePanel(t);

        await _tapKey(t, 'pairing-get-started');
        expect(api.pairingCalls, contains('activate'));
        expect(find.text('HOME-ROUTE'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('a removed device says so and continues only when asked', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final api = FakeBridgeApi(config: _unconfigured)
        ..pairingState = 'removed';
      await _mount(t, api);

      expect(find.byKey(const Key('pairing-removed')), findsOneWidget);
      await _otherWays(t);
      expect(find.byKey(const Key('pairing-restore')), findsNothing);
      await _closePanel(t);
      expect(api.pairingCalls, isEmpty);
      await _tapKey(t, 'pairing-get-started');
      expect(api.pairingCalls, ['activate']);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a replaced identity is taken back through a new device', (
    t,
  ) async {
    final api = FakeBridgeApi(config: _unconfigured)
      ..pairingState = 'superseded';
    await _mount(t, api);

    expect(find.byKey(const Key('pairing-superseded')), findsOneWidget);
    expect(find.byKey(const Key('pairing-own-code')), findsNothing);
    await _tapKey(t, 'pairing-take-back');
    expect(api.pairingCalls, contains('start-over'));
    expect(find.byKey(const Key('pairing-ask')), findsOneWidget);
  });

  testWidgets('a phone links to a typed code only after the preview', (
    t,
  ) async {
    final api = FakeBridgeApi(config: _unconfigured);
    await _mount(t, api);

    expect(_enabled(t, 'pairing-next'), isFalse);
    await t.enterText(
      find.byKey(const Key('pairing-code-field')),
      'k7m2f9qx3rt',
    );
    await t.pump();
    expect(_enabled(t, 'pairing-next'), isFalse);
    await t.enterText(
      find.byKey(const Key('pairing-code-field')),
      'k7m2-f9qx-3rtb',
    );
    await t.pump();
    await _tapKey(t, 'pairing-next');

    expect(api.pairingCalls, ['preview']);
    expect(find.byKey(const Key('pairing-link')), findsOneWidget);
    await _tapKey(t, 'pairing-link');
    expect(api.pairingCalls, ['preview', 'link']);
    expect(api.pairingLastLeaveCurrent, isFalse);
    expect(find.text('HOME-ROUTE'), findsOneWidget);
  });

  testWidgets('an opened invitation only previews its group', (t) async {
    final api = FakeBridgeApi(config: _unconfigured);
    await _mount(t, api, initial: '/blank');
    final container = ProviderScope.containerOf(t.element(find.text('BLANK')));
    container.read(pairingInvitationProvider.notifier).state = 'K7M2-F9QX-3RTB';
    GoRouter.of(t.element(find.text('BLANK'))).push('/pair/join');
    await t.pumpAndSettle();

    expect(t.takeException(), isNull);
    expect(find.byKey(const Key('pairing-link')), findsOneWidget);
    expect(api.pairingCalls, ['preview']);
    expect(container.read(pairingInvitationProvider), isNull);
  });

  testWidgets('a code that is not right stays to be corrected', (t) async {
    final api = FakeBridgeApi(config: _unconfigured)
      ..pairingPreviewRefusals.add(
        const PairingFailure(code: 'code_unknown', message: ''),
      );
    await _mount(t, api, initial: '/pair/join', extra: 'K7M2-F9QX-3RTB');

    final field = t.widget<TextField>(
      find.byKey(const Key('pairing-code-field')),
    );
    expect(field.decoration?.errorText, isNotNull);
    expect(field.controller?.text, 'K7M2-F9QX-3RTB');
    expect(find.byKey(const Key('pairing-link')), findsNothing);
  });

  testWidgets('linking over a GitHub sign-in asks first', (t) async {
    final api = FakeBridgeApi(
      config: const ConfigInfo(
        relay: '',
        hasKey: false,
        mode: 'account',
        accountLogin: 'octocat',
        accountProvider: 'github',
      ),
    );
    await _mount(t, api, initial: '/pair/join', extra: 'K7M2-F9QX-3RTB');

    await _tapKey(t, 'pairing-link');
    expect(find.byKey(const Key('pairing-confirm-yes')), findsOneWidget);
    await _tapKey(t, 'pairing-confirm-no');
    expect(api.pairingCalls, ['preview'], reason: 'nothing changed');
    await _tapKey(t, 'pairing-link');
    await _tapKey(t, 'pairing-confirm-yes');
    expect(api.pairingCalls, ['preview', 'link']);
    expect(api.pairingLastLeaveCurrent, isFalse);
  });

  testWidgets('linking away from peers confirms leaving them', (t) async {
    final api =
        FakeBridgeApi(
            config: const ConfigInfo(
              relay: '',
              hasKey: false,
              mode: 'account',
              accountLogin: 'Laptop',
              accountProvider: 'device_code',
            ),
          )
          ..pairingGroup = const [
            PairingDevice(
              id: 'device-self',
              name: 'Laptop',
              joinedAt: 0,
              lastActiveDay: 0,
              activated: true,
              isSelf: true,
            ),
            PairingDevice(
              id: 'device-old',
              name: 'Old peer',
              joinedAt: 0,
              lastActiveDay: 0,
              activated: true,
              isSelf: false,
            ),
          ];
    await _mount(t, api, initial: '/pair/join', extra: 'K7M2-F9QX-3RTB');

    await _tapKey(t, 'pairing-link');
    await _tapKey(t, 'pairing-confirm-yes');
    expect(api.pairingLastLeaveCurrent, isTrue);
  });

  testWidgets('a group that changed since its preview is shown again', (
    t,
  ) async {
    final api = FakeBridgeApi(config: _unconfigured);
    await _mount(t, api, initial: '/pair/join', extra: 'K7M2-F9QX-3RTB');

    api.pairingRefusal = const PairingFailure(
      code: 'preview_stale',
      message: '',
    );
    await _tapKey(t, 'pairing-link');
    expect(api.pairingCalls, ['preview', 'preview'], reason: 'never linked');
    expect(find.byKey(const Key('pairing-link')), findsOneWidget);
  });

  testWidgets('a change under way waits and lands when it completes', (
    t,
  ) async {
    final api = FakeBridgeApi(config: _unconfigured)
      ..pairingOutcome = 'pending';
    await _mount(t, api, initial: '/pair/join', extra: 'K7M2-F9QX-3RTB');

    await _tapKey(t, 'pairing-link');
    expect(find.byKey(const Key('pairing-check-status')), findsOneWidget);
    expect(api.pairingCalls.where((call) => call == 'link'), hasLength(1));

    api.pairingSettled = const [
      PairingOperation(id: 'op-link', kind: 'link', status: 'completed'),
    ];
    await _tapKey(t, 'pairing-check-status');
    expect(find.text('HOME-ROUTE'), findsOneWidget);
    expect(
      api.pairingCalls.where((call) => call == 'link'),
      hasLength(1),
      reason: 'read, never sent again',
    );
  });

  testWidgets('a change that never happened leaves the waiting page', (
    t,
  ) async {
    final api = FakeBridgeApi(config: _unconfigured)
      ..pairingOutcome = 'pending';
    await _mount(t, api, initial: '/pair/join', extra: 'K7M2-F9QX-3RTB');
    await _tapKey(t, 'pairing-link');

    api.pairingSettled = const [
      PairingOperation(
        id: 'op-link',
        kind: 'link',
        status: 'failed',
        error: 'operation_unknown',
      ),
    ];
    await _tapKey(t, 'pairing-check-status');
    expect(find.byKey(const Key('pairing-check-status')), findsNothing);
    expect(find.byType(AccountOnboardingScreen), findsOneWidget);
    expect(api.pairingCalls.where((call) => call == 'link'), hasLength(1));
  });

  testWidgets('restoring onto a device active today asks again', (t) async {
    final api = FakeBridgeApi(config: _unconfigured)
      ..pairingPreviewDevices = [
        PairingPreviewDevice(
          id: 'device-busy',
          name: 'Busy',
          lastActiveDay: _today(),
        ),
      ];
    await _mount(t, api, initial: '/pair/restore');

    await t.enterText(
      find.byKey(const Key('pairing-code-field')),
      'K7M2-F9QX-3RTB',
    );
    await t.pump();
    await _tapKey(t, 'pairing-restore-next');
    expect(_enabled(t, 'pairing-restore-confirm'), isFalse);
    await _tapKey(t, 'pairing-pick-device-busy');
    await _tapKey(t, 'pairing-restore-confirm');
    await _tapKey(t, 'pairing-confirm-no');
    expect(api.pairingCalls, isNot(contains('restore')));

    await _tapKey(t, 'pairing-restore-confirm');
    await _tapKey(t, 'pairing-confirm-yes');
    expect(api.pairingCalls, contains('restore'));
    expect(api.pairingLastRestoreTarget, 'device-busy');
  });

  testWidgets(
    'asking a linked device shows only a check number until approved',
    (t) async {
      final api = FakeBridgeApi(config: _unconfigured);
      await _mount(t, api, initial: '/pair/restore');

      await _tapKey(t, 'pairing-ask');
      expect(find.byKey(const Key('pairing-check-number')), findsOneWidget);
      expect(find.text('4827'), findsOneWidget);
      expect(find.byKey(const Key('pairing-approved-restore')), findsNothing);

      api.pairingRestoreAnswer = const PairingRestoreRequest(
        requestId: 'request',
        status: 'approved',
        targetDeviceId: 'device-peer',
        devices: [
          PairingPreviewDevice(
            id: 'device-peer',
            name: 'Peer',
            lastActiveDay: 0,
          ),
        ],
      );
      await t.pump(const Duration(seconds: 6));
      await t.pumpAndSettle();
      await _tapKey(t, 'pairing-approved-restore');
      expect(api.pairingLastRestoreTarget, 'request');
    },
  );

  testWidgets('a device back from sign-in is sent there again when it loses '
      'its identity', (t) async {
    final api =
        FakeBridgeApi(
            config: const ConfigInfo(
              relay: '',
              hasKey: false,
              mode: 'account',
              accountProvider: 'device_code',
            ),
          )
          ..pairingRefusal = const PairingFailure(
            code: 'device_superseded',
            message: '',
          );
    final router = GoRouter(
      initialLocation: '/',
      routes: [stub('/', 'HOME-ROUTE'), stub('/onboarding', 'SIGN-IN')],
    );
    debugSetAppRouterForTesting(router);
    addTearDown(debugSetAppRouterForTesting);
    await t.pumpWidget(
      ProviderScope(
        overrides: [bridgeApiProvider.overrideWithValue(api)],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
          builder: (_, child) => PairingHost(child: child!),
        ),
      ),
    );
    // The first check finds config still loading; the next one acts.
    await t.pump(pairingPollInterval);
    await t.pumpAndSettle();
    expect(find.text('SIGN-IN'), findsOneWidget);

    // Signed in again, then replaced again.
    router.go('/');
    await t.pumpAndSettle();
    api.pairingRefusal = const PairingFailure(
      code: 'device_superseded',
      message: '',
    );
    await t.pump(pairingPollInterval);
    await t.pumpAndSettle();
    expect(find.text('SIGN-IN'), findsOneWidget);

    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a member answers the exact request and manages its group', (
    t,
  ) async {
    final api = FakeBridgeApi(config: _unconfigured)
      ..pairingNextRotationAt =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600
      ..pairingGroup = const [
        PairingDevice(
          id: 'device-self',
          name: 'Studio',
          joinedAt: 0,
          lastActiveDay: 0,
          activated: true,
          isSelf: true,
        ),
        PairingDevice(
          id: 'device-phone',
          name: 'Phone',
          joinedAt: 0,
          lastActiveDay: 0,
          activated: true,
          isSelf: false,
        ),
        PairingDevice(
          id: 'device-asked',
          name: 'Old laptop',
          joinedAt: 0,
          lastActiveDay: 0,
          activated: true,
          isSelf: false,
        ),
      ]
      ..pairingAsks = const [
        PairingRecoveryAsk(
          requestId: 'request-1',
          targetDeviceId: 'device-asked',
          requesterName: 'New laptop',
          matchingId: '4729',
          expiresAt: 0,
        ),
      ];
    t.view.physicalSize = const Size(1200, 2600);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(
        const Scaffold(
          body: SingleChildScrollView(child: PairingAccountGroups()),
        ),
        api,
      ),
    );
    await t.pumpAndSettle();

    await _tapKey(t, 'pairing-allow-request-1');
    expect(api.pairingCalls, ['allow']);
    expect(find.byKey(const Key('pairing-allow-request-1')), findsNothing);

    // A code changed within the day waits: the row takes no tap.
    final change = t.widget<SettingValueRow>(
      find.byKey(const Key('pairing-change-code')),
    );
    expect(change.onTap, isNull);

    await _tapKey(t, 'pairing-allow-linking');
    expect(api.pairingPaused, isTrue);

    await _tapKey(t, 'pairing-device-menu-device-phone');
    await t.tap(find.byType(PopupMenuItem<String>).last);
    await t.pumpAndSettle();
    await _tapKey(t, 'pairing-confirm-yes');
    expect(api.pairingCalls, contains('remove'));
  });
}
