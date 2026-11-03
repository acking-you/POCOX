import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/router.dart';
import 'package:pocox/src/screens/account_onboarding_screen.dart';
import 'package:pocox/src/screens/onboarding_screen.dart';
import 'package:pocox/src/theme.dart';

import 'fake_bridge_api.dart';

const _config = ConfigInfo(relay: '', hasKey: false);
const _backend = 'https://backend.example';
const _back = Key('self-host-back');

void main() {
  selfHostNavigationTests();

  testWidgets(
    'relay import holds the setup route and success clears onboarding',
    (tester) async {
      final api = _HeldRelayImport();
      final router = await _mount(tester, api, '/onboarding/self-host');
      await tester.enterText(find.byType(TextField).first, 'pcx1:fixture');
      await tester.tap(find.byKey(const Key('import-btn')));
      await tester.pump();
      await tester.tap(find.byKey(_back));
      await tester.dragFrom(const Offset(1, 400), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingScreen), findsOneWidget);

      api.complete.complete();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(router.routerDelegate.currentConfiguration.uri.path, '/');
      expect(router.canPop(), isFalse);
      expect(
        find.byType(AccountOnboardingScreen, skipOffstage: false),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      // Let the home page's bounded preference read finish after disposal.
      await tester.pump(const Duration(seconds: 2));
    },
  );

  testWidgets(
    'setup abandons a device code after the in-flight poll finishes',
    (tester) async {
      final api = _HeldLoginPoll();
      final router = await _mount(tester, api, '/onboarding');
      await tester.tap(find.text('Advanced / self-hosted'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use a device code instead'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(api.calls, 1);
      final setup = find.widgetWithText(
        TextButton,
        'Use a self-hosted relay instead',
      );
      expect(tester.widget<TextButton>(setup).onPressed, isNull);

      api.poll.complete(const AccountPoll(status: 'pending'));
      await tester.pump();
      await tester.tap(setup);
      await tester.pumpAndSettle();
      expect(find.byType(OnboardingScreen), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      expect(api.calls, 1, reason: 'the hidden Welcome must not keep polling');

      await tester.tap(find.byKey(_back));
      await tester.pumpAndSettle();
      expect(router.canPop(), isFalse);
      expect(find.text('Use a device code instead'), findsOneWidget);
      expect(find.text('ABCD-1234'), findsNothing);
    },
  );
}

class _HeldRelayImport extends FakeBridgeApi {
  _HeldRelayImport() : super(config: _config);

  final complete = Completer<void>();

  @override
  Future<String> importConfig(String text) async {
    await complete.future;
    return super.importConfig(text);
  }
}

class _HeldLoginPoll extends FakeBridgeApi {
  _HeldLoginPoll() : super(config: _config);

  final poll = Completer<AccountPoll>();
  int calls = 0;

  @override
  Future<AccountPoll> accountLoginPoll(String pollHandle, String backend) {
    calls++;
    return poll.future;
  }
}

Future<GoRouter> _mount(
  WidgetTester tester,
  FakeBridgeApi api,
  String location,
) async {
  await tester.binding.setSurfaceSize(const Size(393, 852));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final router = buildRouter(initialLocation: location);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [bridgeApiProvider.overrideWithValue(api)],
      child: MaterialApp.router(
        theme: lightTheme().copyWith(platform: TargetPlatform.iOS),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

/// Exercises the production router with the same iOS theme in widget and
/// Simulator tests.
void selfHostNavigationTests() {
  for (final entry in ['welcome', 'direct link', 'edge gesture']) {
    testWidgets('iOS self-host back: $entry', (tester) async {
      final direct = entry == 'direct link';
      final router = await _mount(
        tester,
        FakeBridgeApi(config: _config),
        direct ? '/onboarding/self-host?reason=session-expired' : '/onboarding',
      );
      final welcome = find.byType(AccountOnboardingScreen, skipOffstage: false);
      final originalWelcome = tester.state(welcome);
      final setup = find.byType(OnboardingScreen);
      if (!direct) {
        await tester.tap(find.text('Advanced / self-hosted'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), _backend);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Use a self-hosted relay instead'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        expect(tester.getTopLeft(setup).dx, greaterThan(0));
        await tester.pumpAndSettle();
      }
      expect(router.canPop(), isTrue);
      expect(tester.state(welcome), same(originalWelcome));
      if (entry == 'edge gesture') {
        await tester.dragFrom(const Offset(1, 400), const Offset(300, 0));
      } else {
        final restingX = tester.getTopLeft(setup).dx;
        await tester.tap(find.byKey(_back));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 140));
        final firstX = tester.getTopLeft(setup).dx;
        expect(firstX, greaterThan(restingX), reason: 'setup must exit right');
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.getTopLeft(setup).dx, greaterThan(firstX));
      }
      await tester.pumpAndSettle();
      expect(setup, findsNothing);
      expect(tester.state(welcome), same(originalWelcome));
      expect(router.canPop(), isFalse);
      if (direct) {
        expect(
          find.byKey(const Key('account-session-expired')),
          findsOneWidget,
        );
      }
      if (!direct) {
        expect(find.text('Advanced / self-hosted'), findsNothing);
        expect(find.text(_backend), findsOneWidget);
        await tester.tap(find.text('Use a self-hosted relay instead'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(_back));
        await tester.pumpAndSettle();
        expect(find.text(_backend), findsOneWidget);
        expect(router.canPop(), isFalse);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
