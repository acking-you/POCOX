import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocox/l10n/gen/app_localizations.dart';
import 'package:pocox/src/bridge_api.dart';
import 'package:pocox/src/network/network_settings.dart';

import 'fake_bridge_api.dart';
import 'support/screen_harness.dart';

final _zh = lookupAppLocalizations(const Locale('zh'));

void main() {
  testWidgets(
    'the system proxy is the default; none and a custom proxy can be chosen',
    (t) async {
      final api = FakeBridgeApi()..systemProxy = 'http://127.0.0.1:7890';
      await t.pumpWidget(host(const Scaffold(body: NetworkProxyRow()), api));
      await t.pumpAndSettle();
      final summary = find.byKey(const Key('network-proxy-summary'));
      String shown() => t.widget<Text>(summary).data!;
      Future<void> open() async {
        await t.tap(find.byKey(const Key('network-proxy-settings')));
        await t.pumpAndSettle();
      }

      Future<void> choose(ProxyMode mode) async {
        await t.tap(find.byKey(Key('network-proxy-mode-${mode.name}')));
        await t.pumpAndSettle();
      }

      final field = find.byKey(const Key('network-proxy-url'));
      final save = find.byKey(const Key('network-proxy-save'));
      expect(shown(), _zh.networkProxySystemFound('http://127.0.0.1:7890'));

      await open();
      expect(field, findsNothing);
      await choose(ProxyMode.direct);
      await t.tap(save);
      await t.pumpAndSettle();
      expect(api.savedProxyMode, ProxyMode.direct);
      expect(shown(), _zh.networkProxyDirectSummary);

      await open();
      await choose(ProxyMode.custom);
      expect(t.widget<TextField>(field).obscureText, isTrue);
      await t.enterText(field, 'http://alice:secret@127.0.0.1:7891');
      await t.tap(save);
      await t.pumpAndSettle();
      expect(api.savedProxyMode, ProxyMode.custom);
      expect(api.savedNetworkProxy, 'http://alice:secret@127.0.0.1:7891');
      expect(shown(), 'http://127.0.0.1:7891');
      expect(find.textContaining('secret'), findsNothing);

      await open();
      await t.enterText(field, 'socks5://127.0.0.1:1080');
      await t.tap(find.text('取消'));
      await t.pumpAndSettle();
      expect(api.savedNetworkProxy, 'http://alice:secret@127.0.0.1:7891');

      // Back to the system: the custom URL stays for a later switch.
      await open();
      await choose(ProxyMode.system);
      await t.tap(save);
      await t.pumpAndSettle();
      expect(api.savedProxyMode, ProxyMode.system);
      expect(api.savedNetworkProxy, 'http://alice:secret@127.0.0.1:7891');
      // Opening reads the system's proxy again.
      api.systemProxy = null;
      await open();
      expect(
        find.descendant(
          of: find.byKey(const Key('network-proxy-note')),
          matching: find.text(_zh.networkProxySystemNone),
        ),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'invalid or missing URLs and a failed save keep the draft and the setting',
    (t) async {
      final api = FakeBridgeApi()
        ..savedProxyMode = ProxyMode.custom
        ..savedNetworkProxy = 'http://127.0.0.1:7890';
      await t.pumpWidget(host(const Scaffold(body: NetworkProxyRow()), api));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('network-proxy-settings')));
      await t.pumpAndSettle();
      final field = find.byKey(const Key('network-proxy-url'));
      final save = find.byKey(const Key('network-proxy-save'));
      String? error() => t.widget<TextField>(field).decoration!.errorText;
      await t.enterText(field, 'file:///tmp/wrong');
      await t.tap(save);
      await t.pumpAndSettle();
      expect(error(), _zh.networkProxyInvalid);
      await t.enterText(field, '');
      await t.tap(save);
      await t.pumpAndSettle();
      expect(error(), _zh.networkProxyCustomRequired);
      expect(api.savedNetworkProxy, 'http://127.0.0.1:7890');

      api.networkSaveError = StateError('disk failure with secret');
      await t.enterText(field, 'socks5://alice:secret@localhost:1080');
      await t.tap(save);
      await t.pumpAndSettle();
      expect(
        t.widget<TextField>(field).controller!.text,
        'socks5://alice:secret@localhost:1080',
      );
      expect(error(), isNot(contains('secret')));
      expect(api.savedProxyMode, ProxyMode.custom);
      expect(api.savedNetworkProxy, 'http://127.0.0.1:7890');
      expect(t.takeException(), isNull);
    },
  );
}
