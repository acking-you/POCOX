import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/network/relay_settings.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';

class _ObservedBridge extends FakeBridgeApi {
  List<SubInfo> observed = [];
  int reads = 0;
  @override
  Future<List<SubInfo>> subscriptions() async {
    reads++;
    return observed;
  }
}

void main() {
  testWidgets(
    'preferences save, cancel and failed save preserve current values',
    (t) async {
      final api = FakeBridgeApi();
      await t.pumpWidget(host(const Scaffold(body: RelaySettingsRow()), api));
      await t.pumpAndSettle();
      Future<void> open() async {
        await t.tap(find.byKey(const Key('relay-path-settings')));
        await t.pumpAndSettle();
      }

      Future<void> chooseAuto() async {
        await t.tap(find.byKey(const Key('relay-path-policy')));
        await t.pumpAndSettle();
        await t.tap(find.text('优先 P2P 直连').last);
        await t.pumpAndSettle();
      }

      await open();
      await chooseAuto();
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(api.savedRelayPreferences.path, 'relay_only');
      await open();
      await chooseAuto();
      final incoming = find.byKey(const Key('relay-allow-direct'));
      final canHost = incoming.evaluate().isNotEmpty;
      if (canHost) await t.tap(incoming);
      api.relaySaveError = StateError('write failed');
      await t.tap(find.byKey(const Key('relay-path-save')));
      await t.pumpAndSettle();
      expect(api.savedRelayPreferences.path, 'relay_only');
      expect(find.text('无法保存连接偏好，请重试。'), findsOneWidget);
      api.relaySaveError = null;
      await t.tap(find.byKey(const Key('relay-path-save')));
      await t.pumpAndSettle();
      expect(api.savedRelayPreferences.path, 'auto');
      expect(api.savedRelayPreferences.allowDirect, canHost);
      expect(t.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'path display follows active observations and stops polling when unmounted',
    (t) async {
      final api = _ObservedBridge()
        ..savedRelayPreferences = const RelayPreferences(path: 'auto');
      SubInfo snapshot(
        String path, {
        int direct = 0,
        int relay = 0,
        int fallbacks = 0,
      }) => SubInfo(
        key: 'pcx:test:app:default',
        localAddr: '127.0.0.1:1',
        alive: true,
        path: path,
        activeDirect: direct,
        activeRelay: relay,
        fallbacks: fallbacks,
      );
      api.observed = [snapshot('idle')];
      await t.pumpWidget(
        host(
          Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                final values =
                    ref.watch(relaySubscriptionsProvider).valueOrNull ?? [];
                return Column(
                  children: [
                    for (final value in values)
                      Text(relayPathLabel(AppLocalizations.of(context), value)),
                  ],
                );
              },
            ),
          ),
          api,
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('等待数据连接'), findsOneWidget);
      expect(find.text('P2P 直连'), findsNothing);
      api.observed = [snapshot('mixed', direct: 1, relay: 2, fallbacks: 2)];
      await t.pump(const Duration(seconds: 3));
      await t.pumpAndSettle();
      expect(find.text('直连：1 · 中继：2 · 已回退中继 2 次'), findsOneWidget);
      api.observed = [snapshot('direct', direct: 1)];
      await t.pump(const Duration(seconds: 3));
      await t.pumpAndSettle();
      expect(find.text('P2P 直连'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      final reads = api.reads;
      await t.pump(const Duration(seconds: 10));
      expect(api.reads, reads);
      expect(t.takeException(), isNull);
    },
  );

  for (final width in [390.0, 834.0, 1280.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('relay editor fits $width $brightness', (t) async {
        await t.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => t.binding.setSurfaceSize(null));
        await t.pumpWidget(
          host(
            const Scaffold(body: RelaySettingsRow()),
            FakeBridgeApi(),
            theme: ThemeData(brightness: brightness),
          ),
        );
        await t.pumpAndSettle();
        await t.tap(find.byKey(const Key('relay-path-settings')));
        await t.pumpAndSettle();
        expect(
          find.byKey(const Key('relay-path-save')).hitTestable(),
          findsOneWidget,
        );
        expect(t.takeException(), isNull);
      });
    }
  }
}
