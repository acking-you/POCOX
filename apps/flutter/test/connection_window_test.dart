import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/network/connection_window.dart';
import 'package:pocox/src/widgets/host_switcher.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';

void main() {
  testWidgets(
    'window preferences persist and a failed save keeps the previous limit',
    (t) async {
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
          const Scaffold(body: ConnectionWindowSettings()),
          api,
          theme: ThemeData(brightness: Brightness.dark),
        ),
      );
      await t.pumpAndSettle();
      Future<void> edit() async {
        await t.tap(find.byKey(const Key('connection-window-settings')));
        await t.pumpAndSettle();
      }

      await edit();
      final field = find.byKey(const Key('connection-window-capacity'));
      final save = find.byKey(const Key('connection-window-save'));
      await t.enterText(field, '0');
      await t.tap(save);
      await t.pumpAndSettle();
      expect(api.savedConnectionWindow.capacity, 5);
      expect(find.byType(AlertDialog), findsOneWidget);
      await t.enterText(field, '8');
      final policy = find.byKey(const Key('connection-window-policy'));
      await t.ensureVisible(policy);
      await t.pumpAndSettle();
      await t.tap(policy);
      await t.pumpAndSettle();
      await t.tap(find.text(l10n.connectionWindowFifo).last);
      await t.pumpAndSettle();
      await t.tap(save);
      await t.pumpAndSettle();
      expect(api.savedConnectionWindow.capacity, 8);
      expect(api.savedConnectionWindow.eviction, 'fifo');
      await edit();
      expect(t.widget<TextFormField>(field).controller!.text, '8');
      api.connectionWindowSaveError = StateError('disk unavailable');
      await t.enterText(field, '2');
      await t.tap(save);
      await t.pumpAndSettle();
      expect(api.savedConnectionWindow.capacity, 8);
      expect(find.textContaining('disk unavailable'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );

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
