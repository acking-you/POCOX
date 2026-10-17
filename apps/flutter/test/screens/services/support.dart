part of '../services_test.dart';

FakeBridgeApi accountFake() => FakeBridgeApi(
  config: const ConfigInfo(
    relay: '',
    hasKey: false,
    mode: 'account',
    accountLogin: 'acking-you',
  ),
  services: const [],
);

/// Hosting is desktop-only: tests that host run on a desktop target.
final desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

/// Mount the services screen over [api] and open its device.
Future<void> showServices(WidgetTester t, FakeBridgeApi api) async {
  await t.pumpWidget(host(const ServicesScreen(), api));
  await t.pumpAndSettle();
  await openDevice(t);
}

/// Add a local host from the device's add card and start it as offered.
Future<void> addLocalHost(WidgetTester t) async {
  await t.tap(find.byKey(const Key('add-local-host-card')));
  await t.pumpAndSettle();
  await t.tap(find.byKey(const Key('start-hosting-btn')));
  await t.pumpAndSettle();
}

// The agent chooser sits above the Codex form, so its controls may start
// below the dialog's fold: scroll them in and require a real hit first.
Future<void> tapRevealed(WidgetTester t, Finder control) async {
  await t.ensureVisible(control);
  await t.pumpAndSettle();
  expect(control.hitTestable(), findsOneWidget, reason: '$control');
  await t.tap(control);
  await t.pumpAndSettle();
}
