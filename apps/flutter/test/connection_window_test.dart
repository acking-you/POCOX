import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/network/connection_window.dart';
import 'package:pocox/src/screens/app_session_screen.dart';
import 'package:pocox/src/widgets/host_switcher.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';

void main() {
  testWidgets(
    'window preferences save as they change and a failed save keeps the '
    'previous limit',
    (t) async {
      // A phone with large text: the rows stack and stay usable.
      t.view.physicalSize = const Size(320, 780);
      t.view.devicePixelRatio = 1;
      t.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      final api = FakeBridgeApi();
      final l10n = lookupAppLocalizations(const Locale('zh'));
      await t.pumpWidget(
        host(
          const Scaffold(
            body: SingleChildScrollView(child: ConnectionWindowSettings()),
          ),
          api,
          theme: ThemeData(brightness: Brightness.dark),
        ),
      );
      await t.pumpAndSettle();
      final increase = find.byKey(
        const Key('connection-window-capacity-increase'),
      );
      for (var i = 0; i < 3; i++) {
        await t.tap(increase);
        await t.pumpAndSettle();
      }
      expect(api.savedConnectionWindow.capacity, 8);
      await t.tap(find.byKey(const Key('connection-window-fifo')));
      await t.pumpAndSettle();
      expect(api.savedConnectionWindow.eviction, ConnectionEviction.fifo);
      expect(api.savedConnectionWindow.capacity, 8);

      api.connectionWindowSaveError = StateError('disk unavailable');
      await t.tap(find.byKey(const Key('connection-window-capacity-decrease')));
      await t.pumpAndSettle();
      expect(api.savedConnectionWindow.capacity, 8);
      expect(
        find.descendant(
          of: find.byKey(const Key('connection-window-capacity')),
          matching: find.text('8'),
        ),
        findsOneWidget,
        reason: 'the saved limit is shown again',
      );
      expect(find.text(l10n.connectionPathSaveFailed), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

  testWidgets('a conversation opened from elsewhere is admitted, so it '
      'connects although recovery alone is refused', (t) async {
    const service = 'pcx:studio:app:browser';
    final api = FakeBridgeApi(
      config: const ConfigInfo(relay: 'relay:7666', hasKey: true),
    )..appReconnectRefused.add(service);
    await t.pumpWidget(
      host(const AppSessionScreen(serviceKey: service, threadId: 't'), api),
    );
    // The health check notices the missing connection and recovers it.
    for (var i = 0; i < 30; i++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(api.appIsConnected(service), isTrue);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets(
    'same labels cannot merge accounts or mark unowned services local',
    (t) async {
      const services = [
        ServiceEntry(
          device: 'studio',
          kind: 'app',
          name: 'main',
          key: 'pcx:studio:app:main',
        ),
        ServiceEntry(
          device: 'studio',
          kind: 'acp',
          name: 'review',
          key: 'pcx:studio:acp:review',
        ),
        ServiceEntry(
          device: 'studio',
          kind: 'app',
          name: 'remote',
          key: 'pcxu:other:studio:app:remote',
        ),
        ServiceEntry(
          device: 'studio',
          kind: 'app',
          name: 'cli',
          key: 'pcx:studio:app:cli',
        ),
      ];
      String? selected;
      await t.pumpWidget(
        host(
          Scaffold(
            body: HostSwitcher(
              services: services,
              current: services.first.key,
              localKeys: {services[0].key, services[1].key},
              connectedKeys: {services.first.key},
              onPick: (key) => selected = key,
            ),
          ),
          FakeBridgeApi(),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('sidebar-service-switcher')));
      await t.pumpAndSettle();
      final local = find.byKey(const Key('host-switch-device-local')).last;
      expect(
        find.descendant(
          of: local,
          matching: find.byKey(Key('host-switch-item-${services[1].key}')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: local,
          matching: find.byKey(Key('host-switch-item-${services[3].key}')),
        ),
        findsNothing,
      );
      expect(
        find.byKey(const Key('host-switch-device-pcx:studio')),
        findsWidgets,
      );
      expect(
        find.byKey(const Key('host-switch-device-pcxu:other:studio')),
        findsWidgets,
      );
      await t.tap(find.byKey(Key('host-switch-item-${services[1].key}')).last);
      await t.pumpAndSettle();
      expect(selected, services[1].key);
      expect(t.takeException(), isNull);
    },
  );
}
