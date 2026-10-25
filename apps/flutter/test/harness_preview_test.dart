// Agents on a computer, on the services page with real fonts and themes:
// a managed computer with an update available, one up to date, one POCOX
// cannot update and a finished update's outcome, and this computer's own
// card, on a 390 phone and a 1440 desktop, light and dark, Chinese and
// English. Each scene must lay out without overflow.
//
// Set POCOX_UI_PREVIEW_DIR to also write each scene as a PNG for review.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/providers.dart';
import 'package:pocox/src/screens/services_screen.dart';
import 'package:pocox/src/theme.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';
import 'support/ui_preview.dart';

const _studio = 'pcx:studio:host:studio';

HarnessOverview _harnesses({required bool local}) => HarnessOverview(
  checkedAtMs: DateTime.now()
      .subtract(const Duration(minutes: 12))
      .millisecondsSinceEpoch,
  harnesses: [
    HarnessInfo(
      kind: 'codex',
      installed: true,
      version: '0.46.0',
      latest: '0.47.0',
      updateAvailable: true,
      method: 'npm',
      canUpdate: true,
      autoUpdate: true,
      services: local ? const ['default'] : const ['default', 'review-bot'],
    ),
    if (!local) ...[
      const HarnessInfo(
        kind: 'opencode',
        installed: true,
        version: '2.1.4',
        latest: '2.1.4',
        method: 'own',
        canUpdate: true,
        services: ['opencode'],
      ),
      const HarnessInfo(
        kind: 'claude',
        installed: true,
        version: '2.1.296',
        latest: '2.1.310',
        updateAvailable: true,
        problem: 'unmanaged',
      ),
      const HarnessInfo(
        kind: 'grok',
        installed: true,
        version: '1.0.62',
        latest: '1.0.62',
        method: 'own',
        canUpdate: true,
      ),
    ],
  ],
  job: local
      ? null
      : const HarnessJob(
          run: 3,
          kind: 'grok',
          state: 'done',
          fromVersion: '1.0.61',
          toVersion: '1.0.62',
          automatic: true,
          restarted: ['grok'],
          notRestarted: [HarnessSkip(name: 'grok-lab', reason: 'busy')],
        ),
);

FakeBridgeApi _api() {
  final api = FakeBridgeApi(
    services: const [
      ServiceEntry(
        device: 'studio',
        kind: 'host',
        name: 'studio',
        key: _studio,
      ),
      ServiceEntry(
        device: 'studio',
        kind: 'app',
        name: 'default',
        key: 'pcx:studio:app:default',
      ),
    ],
  );
  api.managedDevices[_studio] = const ManagedDevice(
    device: 'studio',
    os: 'linux',
    appVersion: '0.7.5',
  );
  api.harnessOverviews[_studio] = _harnesses(local: false);
  api.harnessOverviews[''] = _harnesses(local: true);
  return api;
}

Future<void> _scene(
  WidgetTester t, {
  required String name,
  required Size size,
  required TargetPlatform platform,
  Locale locale = const Locale('zh'),
  Brightness brightness = Brightness.light,
  required String open,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    await t.pumpWidget(
      ProviderScope(
        overrides: [bridgeApiProvider.overrideWithValue(_api())],
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: brightness == Brightness.light ? lightTheme() : darkTheme(),
          builder: (context, child) =>
              RepaintBoundary(key: previewKey, child: child),
          home: const ServicesScreen(),
        ),
      ),
    );
    await t.pumpAndSettle();
    await tapKey(t, 'device-$open');
    final card = find.byKey(
      Key(open == 'studio' ? 'harnesses-$_studio' : 'harnesses-local'),
    );
    await t.scrollUntilVisible(
      card,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await t.pumpAndSettle();
    expect(t.takeException(), isNull, reason: name);
    await capturePreview(t, name);
    await t.pumpWidget(const SizedBox());
  } finally {
    debugDefaultTargetPlatformOverride = null;
    t.view.reset();
  }
}

void main() {
  setUpAll(() => loadPreviewFonts(always: true));

  testWidgets('desktop: a managed computer and this one', (t) async {
    const desktop = Size(1440, 1100);
    await _scene(
      t,
      name: 'harnesses-desktop-remote',
      size: desktop,
      platform: TargetPlatform.macOS,
      open: 'studio',
    );
    await _scene(
      t,
      name: 'harnesses-desktop-remote-en-dark',
      size: desktop,
      platform: TargetPlatform.macOS,
      locale: const Locale('en'),
      brightness: Brightness.dark,
      open: 'studio',
    );
    await _scene(
      t,
      name: 'harnesses-desktop-local-en',
      size: desktop,
      platform: TargetPlatform.macOS,
      locale: const Locale('en'),
      open: '@local',
    );
  });

  testWidgets('phone: a managed computer', (t) async {
    const phone = Size(390, 844);
    await _scene(
      t,
      name: 'harnesses-phone-remote-en',
      size: phone,
      platform: TargetPlatform.android,
      locale: const Locale('en'),
      open: 'studio',
    );
    await _scene(
      t,
      name: 'harnesses-phone-remote-dark',
      size: phone,
      platform: TargetPlatform.iOS,
      brightness: Brightness.dark,
      open: 'studio',
    );
  });
}
