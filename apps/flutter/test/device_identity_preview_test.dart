// Same-name installations on the services page, with real fonts and themes
// (desktop scenes use macOS: the Windows UI face is not bundled for tests):
// this computer beside two copies of one WSL distribution, a Linux
// server named by its generated segment and an older hostname-only host, on a
// 390 phone and a 1440 desktop, light and dark, Chinese and English. Each
// scene must lay out without overflow.
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

const _ubuntu = 'wsl-ubuntu.studio.2222aaaa123441238123123456789abc';
const _ubuntuCopy = 'wsl-ubuntu.studio.4444bbbb123441238123123456789abc';
const _server =
    'linux-debian-gnu-linux-12.build-server.5555cccc123441238123123456789abc';

FakeBridgeApi _api() {
  final api =
      FakeBridgeApi(
          services: [
            for (final device in [_ubuntu, _ubuntuCopy])
              ServiceEntry(
                device: device,
                kind: 'host',
                name: 'pocox',
                key: 'pcx:$device:host:pocox',
              ),
            const ServiceEntry(
              device: _server,
              kind: 'app',
              name: 'default',
              key: 'pcx:$_server:app:default',
            ),
            const ServiceEntry(
              device: 'lb7666',
              kind: 'app',
              name: 'default',
              key: 'pcx:lb7666:app:default',
            ),
          ],
        )
        ..localMetadata = const DeviceMetadata(
          os: 'windows',
          arch: 'x86_64',
          hostname: 'studio',
          hostId: '1111dddd-1234-4123-8123-123456789abc',
          instanceId: 'desktop',
        )
        ..serveHosts.add(
          const AppServeStatus(
            name: 'default',
            device: 'windows.studio.1111dddd123441238123123456789abc',
            alive: true,
            appServiceKey:
                'pcx:windows.studio.1111dddd123441238123123456789abc:app:default',
          ),
        );
  for (final (device, id) in [
    (_ubuntu, '2222aaaa-1234-4123-8123-123456789abc'),
    (_ubuntuCopy, '4444bbbb-1234-4123-8123-123456789abc'),
  ]) {
    api.managedDevices['pcx:$device:host:pocox'] = ManagedDevice(
      device: device,
      os: 'linux',
      metadata: DeviceMetadata(
        os: 'linux',
        arch: 'x86_64',
        environment: 'wsl',
        sourceName: 'Ubuntu',
        hostname: 'studio',
        hostId: id,
        instanceId: 'cli-$device',
      ),
      appVersion: '0.4.0',
    );
  }
  return api;
}

Future<void> _scene(
  WidgetTester t, {
  required String name,
  required Size size,
  required TargetPlatform platform,
  Locale locale = const Locale('zh'),
  Brightness brightness = Brightness.light,
  String? open,
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
    if (open != null) await tapKey(t, 'device-$open');
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

  testWidgets('desktop: this computer beside same-name installations', (
    t,
  ) async {
    const desktop = Size(1440, 900);
    await _scene(
      t,
      name: 'identity-desktop-local',
      size: desktop,
      platform: TargetPlatform.macOS,
    );
    await _scene(
      t,
      name: 'identity-desktop-wsl-dark',
      size: desktop,
      platform: TargetPlatform.macOS,
      brightness: Brightness.dark,
      open: _ubuntuCopy,
    );
    await _scene(
      t,
      name: 'identity-desktop-wsl-en',
      size: desktop,
      platform: TargetPlatform.macOS,
      locale: const Locale('en'),
      open: _ubuntu,
    );
  });

  testWidgets('phone: the device list and one installation', (t) async {
    const phone = Size(390, 844);
    await _scene(
      t,
      name: 'identity-phone-list',
      size: phone,
      platform: TargetPlatform.iOS,
    );
    await _scene(
      t,
      name: 'identity-phone-wsl-en',
      size: phone,
      platform: TargetPlatform.android,
      locale: const Locale('en'),
      brightness: Brightness.dark,
      open: _ubuntu,
    );
    await _scene(
      t,
      name: 'identity-phone-server',
      size: phone,
      platform: TargetPlatform.android,
      open: _server,
    );
  });
}
