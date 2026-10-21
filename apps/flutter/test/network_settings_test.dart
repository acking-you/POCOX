import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_codex/src/network/network_settings.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';

void main() {
  testWidgets(
    'proxy edits persist, cancel preserves and clearing restores default',
    (t) async {
      final api = FakeBridgeApi();
      await t.pumpWidget(host(const Scaffold(body: NetworkProxyRow()), api));
      await t.pumpAndSettle();
      Future<void> open() async {
        await t.tap(find.byKey(const Key('network-proxy-settings')));
        await t.pumpAndSettle();
      }

      final field = find.byKey(const Key('network-proxy-url'));
      final save = find.byKey(const Key('network-proxy-save'));
      await open();
      expect(t.widget<TextField>(field).obscureText, isTrue);
      await t.enterText(field, 'http://alice:secret@127.0.0.1:7890');
      await t.tap(save);
      await t.pumpAndSettle();
      expect(api.savedNetworkProxy, 'http://alice:secret@127.0.0.1:7890');
      expect(find.text('http://127.0.0.1:7890'), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);

      await open();
      await t.enterText(field, 'socks5://127.0.0.1:1080');
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(api.savedNetworkProxy, 'http://alice:secret@127.0.0.1:7890');

      await open();
      await t.enterText(field, 'socks5://127.0.0.1:1080');
      await t.tap(save);
      await t.pumpAndSettle();
      expect(api.savedNetworkProxy, 'socks5://127.0.0.1:1080');
      await open();
      await t.enterText(field, '');
      await t.tap(save);
      await t.pumpAndSettle();
      expect(api.savedNetworkProxy, isNull);
      expect(t.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'invalid input and a failed save keep the draft and saved proxy',
    (t) async {
      final api = FakeBridgeApi()..savedNetworkProxy = 'http://127.0.0.1:7890';
      await t.pumpWidget(host(const Scaffold(body: NetworkProxyRow()), api));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('network-proxy-settings')));
      await t.pumpAndSettle();
      final field = find.byKey(const Key('network-proxy-url'));
      final save = find.byKey(const Key('network-proxy-save'));
      await t.enterText(field, 'file:///tmp/wrong');
      await t.tap(save);
      await t.pumpAndSettle();
      expect(t.widget<TextField>(field).decoration!.errorText, isNotNull);
      expect(api.savedNetworkProxy, 'http://127.0.0.1:7890');

      api.networkSaveError = StateError('disk failure with secret');
      await t.enterText(field, 'socks5://alice:secret@localhost:1080');
      await t.tap(save);
      await t.pumpAndSettle();
      expect(
        t.widget<TextField>(field).controller!.text,
        'socks5://alice:secret@localhost:1080',
      );
      expect(
        t.widget<TextField>(field).decoration!.errorText,
        isNot(contains('secret')),
      );
      expect(api.savedNetworkProxy, 'http://127.0.0.1:7890');
      expect(t.takeException(), isNull);
    },
  );
}
